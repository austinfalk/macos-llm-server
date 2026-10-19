# shellcheck shell=sh disable=SC2034
#
# Shared by everything in scripts/. Callers set LLM_REPO first:
#
#     LLM_REPO=$(cd "$(dirname "$0")/.." && pwd)
#     . "$LLM_REPO/scripts/lib.sh"

: "${LLM_REPO:?set LLM_REPO before sourcing lib.sh}"

# --- PATH -------------------------------------------------------------------
# sudo does not reliably carry Homebrew's bin directory, so set it explicitly.
BREW_PREFIX=
for _p in /opt/homebrew /usr/local; do
	if [ -x "$_p/bin/brew" ]; then BREW_PREFIX=$_p; break; fi
done
: "${BREW_PREFIX:=/opt/homebrew}"
PATH="$BREW_PREFIX/bin:/usr/bin:/bin:/usr/sbin:/sbin"
export PATH

# --- configuration ------------------------------------------------------------
if [ -f "$LLM_REPO/config.env" ]; then
	# shellcheck source=/dev/null
	. "$LLM_REPO/config.env"
fi
: "${LLM_USER:=${SUDO_USER:-$(id -un)}}"
: "${LLM_MODEL:=mlx-community/Qwen3.8-27B-4bit}"
: "${LLM_TAG:=tag:llm-server}"
: "${LLM_SSH_TAILNET_ONLY:=yes}"
: "${LLM_BATTERY_SHUTDOWN_PCT:=15}"
: "${LLM_DISABLE_SLEEP:=no}"

LLM_HOME=$(dscl . -read "/Users/$LLM_USER" NFSHomeDirectory 2>/dev/null | sed -n 's/^NFSHomeDirectory: //p')
LLM_UID=$(id -u "$LLM_USER" 2>/dev/null)
KEY_FILE=$LLM_HOME/.config/llm-server/api-key
# shellcheck source=scripts/variant.sh
. "$LLM_REPO/scripts/variant.sh"
CPU_BRAND=$(sysctl -n machdep.cpu.brand_string 2>/dev/null) || CPU_BRAND=
SPLASH_VARIANT=$(detect_variant "$CPU_BRAND") || SPLASH_VARIANT=
variant_values "$SPLASH_VARIANT"
SPLASH_LABEL=com.llmserver.splash
SPLASH_PLIST=$LLM_HOME/Library/LaunchAgents/$SPLASH_LABEL.plist
SPLASH_LOG=$LLM_HOME/Library/Logs/llm-server/splash.log
# Splash's default port: the LaunchAgent passes no --port.
LLM_PORT=8000

# Installed by 4-harden.sh. Services never point into this git checkout.
LLM_SBIN=/usr/local/sbin
LLM_ETC=/usr/local/etc/llm-server
LLM_LOGS=/Library/Logs/llm-server
L_WATCHDOG=com.llmserver.batterywatchdog
L_PF=com.llmserver.pf
P_WATCHDOG=/Library/LaunchDaemons/$L_WATCHDOG.plist
P_PF=/Library/LaunchDaemons/$L_PF.plist
# pf rules for Screen Sharing and Sunshine live in an anchor under com.apple/,
# which the stock /etc/pf.conf already evaluates.
PF_ANCHOR=com.apple/250.llm-server

# --- output -----------------------------------------------------------------
step() { printf '\n== %s\n' "$*"; }
ok()   { printf '  ok    %s\n' "$*"; }
info() { printf '        %s\n' "$*"; }
warn() { printf '  WARN  %s\n' "$*" >&2; }
bad()  { printf '  FAIL  %s\n' "$*" >&2; }
die()  { printf '\nERROR: %s\n' "$*" >&2; exit 1; }

need_root() { [ "$(id -u)" = 0 ] || die "run with sudo: sudo sh $0"; }
need_user() { [ "$(id -u)" != 0 ] || die "run as your normal user, without sudo"; }

check_user() {
	[ "$LLM_USER" != root ] || die "LLM_USER resolved to root. Run via sudo from your own account, or set LLM_USER in config.env."
	[ -n "$LLM_HOME" ] && [ -d "$LLM_HOME" ] || die "no home directory found for user '$LLM_USER'"
}

# --- machine facts ------------------------------------------------------------
is_laptop() { pmset -g batt 2>/dev/null | grep -q InternalBattery; }
ram_gib()   { sysctl -n hw.memsize | awk '{printf "%.0f", $1/1073741824}'; }

# --- endpoint -----------------------------------------------------------------
endpoint_host() {
	tailscale status --json 2>/dev/null \
		| plutil -extract Self.DNSName raw -o - - 2>/dev/null | sed 's/\.$//'
}
endpoint_url() {
	_h=$(endpoint_host)
	[ -n "$_h" ] && printf 'https://%s' "$_h"
}
key() { head -1 "$KEY_FILE" 2>/dev/null; }

# curl_hdr HEADER CURL-ARGS...
# The header, which usually carries the key, reaches curl on stdin rather than
# its command line: any local account can read command lines with ps.
curl_hdr() {
	_h=$1; shift
	printf 'header = "%s"\n' "$_h" | curl -K - "$@"
}

# http_code URL [KEY]
http_code() {
	if [ -n "${2:-}" ]; then
		curl_hdr "Authorization: Bearer $2" -s -o /dev/null -m 20 -w '%{http_code}' "$1"
	else
		curl -s -o /dev/null -m 20 -w '%{http_code}' "$1"
	fi
}

# --- launchd ------------------------------------------------------------------
# `launchctl bootout` returns before the job is gone. An immediate `bootstrap`
# of the same label then fails with the unhelpful
# "Bootstrap failed: 5: Input/output error". So wait, then retry.
job_loaded() { launchctl print "$1" >/dev/null 2>&1; }

stop_job() {  # domain/label
	launchctl bootout "$1" 2>/dev/null
	_n=0
	while job_loaded "$1" && [ $_n -lt 40 ]; do sleep 0.5; _n=$((_n + 1)); done
}

start_job() {  # domain label plist
	stop_job "$1/$2"
	_n=0
	while [ $_n -lt 5 ]; do
		launchctl bootstrap "$1" "$3" 2>/dev/null && return 0
		_n=$((_n + 1)); sleep 2
	done
	launchctl bootstrap "$1" "$3"   # once more, unmuted, to show the error
	return 1
}

json_value() { printf '%s' "$1" | plutil -extract "$2" raw -o - - 2>/dev/null || :; }

# Every bottle must match, not only one for this macOS: Homebrew pours a bottle
# built for an earlier macOS when there is none for this one. Auto-update is off
# for the install, so the tap cannot move after the check.
install_upstream_splash() {
	brew tap incoai/tap || die "could not add the Homebrew tap incoai/tap"
	_json=$(brew info --json=v2 incoai/tap/splash) || die "could not read the formula incoai/tap/splash"
	_version=$(json_value "$_json" formulae.0.versions.stable)
	_archive=$(json_value "$_json" formulae.0.urls.stable.checksum)
	_bottles=$(for _t in $(json_value "$_json" formulae.0.bottle.stable.files); do
		json_value "$_json" "formulae.0.bottle.stable.files.$_t.sha256"
	done | paste -s -d ' ' -)
	[ "$_version $_archive $_bottles" = "$SPLASH_VERSION $SPLASH_ARCHIVE_SHA256 $SPLASH_BOTTLE_SHA256" ] \
		|| die "incoai/tap/splash is not the Splash this repo pins:
    version  ${_version:-none} (pinned $SPLASH_VERSION)
    tarball  ${_archive:-none} (pinned $SPLASH_ARCHIVE_SHA256)
    bottles  ${_bottles:-none} (pinned $SPLASH_BOTTLE_SHA256)
Upstream moved. Read its release notes, then bump SPLASH_VERSION and the
checksums in scripts/variant.sh."
	HOMEBREW_NO_AUTO_UPDATE=1 brew install incoai/tap/splash || die "brew install incoai/tap/splash failed"
	brew pin splash || die "could not pin splash in Homebrew"
}

# --- templates ----------------------------------------------------------------
# render TEMPLATE DEST MODE OWNER:GROUP
# Fills @PLACEHOLDERS@ in config/TEMPLATE and installs it atomically. Refuses
# to install anything with a placeholder left unfilled, and lints plists.
render() {
	_src=$LLM_REPO/config/$1
	_tmp=$2.tmp.$$
	[ -f "$_src" ] || die "missing template $_src"
	( umask 077
	  sed -e "s|@LLM_BATTERY_SHUTDOWN_PCT@|$LLM_BATTERY_SHUTDOWN_PCT|g" \
	      -e "s|@LLM_MODEL@|$LLM_MODEL|g" \
	      -e "s|@ENDPOINT_HOST@|${ENDPOINT_HOST:-}|g" \
	      -e "s|@KEY_FILE@|$KEY_FILE|g" \
	      -e "s|@SPLASH_BIN@|$SPLASH_BIN|g" \
	      -e "s|@SPLASH_VERSION@|$SPLASH_VERSION|g" \
	      -e "s|@SPLASH_LABEL@|$SPLASH_LABEL|g" \
	      -e "s|@SPLASH_LOG@|$SPLASH_LOG|g" \
	      "$_src" > "$_tmp" ) || die "could not render $1"
	if grep -q '@[A-Z_]*@' "$_tmp"; then
		_left=$(grep -o '@[A-Z_]*@' "$_tmp" | head -1)
		rm -f "$_tmp"
		die "template $1 still contains $_left after rendering"
	fi
	if ! { chown "$4" "$_tmp" && chmod "$3" "$_tmp" && mv -f "$_tmp" "$2"; }; then
		rm -f "$_tmp"
		die "could not install $2"
	fi
	case $2 in
		*.plist) plutil -lint "$2" >/dev/null || die "$2 is not a valid plist" ;;
	esac
}
