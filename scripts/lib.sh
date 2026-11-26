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
: "${LLM_TAG:=}"
: "${LLM_HTTPS_PORT:=443}"
: "${LLM_BATTERY_SHUTDOWN_PCT:=15}"
: "${LLM_DISABLE_SLEEP:=no}"

LLM_HOME=$(dscl . -read "/Users/$LLM_USER" NFSHomeDirectory 2>/dev/null | sed -n 's/^NFSHomeDirectory: //p')
LLM_UID=$(id -u "$LLM_USER" 2>/dev/null)
KEY_FILE=$LLM_HOME/.config/llm-server/api-key
# shellcheck source=scripts/pins.sh
. "$LLM_REPO/scripts/pins.sh"

# mlx-serve, built by 1-install.sh. Each build gets its own folder, named for
# the tag and the patches, so a new pin or patch builds beside the running one,
# and the LaunchAgent changes to the new folder. namp's M1/M2 patch applies
# first, then this repo's changes on top of it.
PATCH=$LLM_REPO/patches/inkling2-m1.patch
SPEED_PATCH=$LLM_REPO/patches/inkling2-m1-speed.patch
MLX_SERVE_HOME=$LLM_HOME/.mlx-serve/builds
MLX_SERVE_SRC=$MLX_SERVE_HOME/src
MLX_SERVE_BUILD=${MLX_SERVE_TAG#v}-inkling2-m1-$(cat "$PATCH" "$SPEED_PATCH" 2>/dev/null | shasum -a 256 | cut -c1-8)
MLX_SERVE_BIN=$MLX_SERVE_HOME/$MLX_SERVE_BUILD/mlx-serve
MLX_SERVE_LABEL=com.llmserver.mlx-serve
MLX_SERVE_PLIST=$LLM_HOME/Library/LaunchAgents/$MLX_SERVE_LABEL.plist
MLX_SERVE_LOG=$LLM_HOME/Library/Logs/llm-server/mlx-serve.log
# Rules for the request fields a client leaves out. mlx-serve reads the file
# again whenever it changes.
MLX_SERVE_GEN_SETTINGS=$LLM_HOME/.mlx-serve/generation-settings.json
# The release as downloaded, and the pack 1-install.sh converts from it.
# mlx-serve names a model after its folder: clients see LLM_MODEL_ID.
LLM_SOURCE_DIR=$LLM_HOME/.mlx-serve/models/$LLM_SOURCE_REPO
LLM_MODEL_ID=Inkling-2-Mini-Uncensored-q4attn
LLM_MODEL_DIR=$LLM_HOME/.mlx-serve/models/local/$LLM_MODEL_ID
# What the pack was converted from and with. The LaunchAgent carries it, so a
# reconverted pack restarts the server.
LLM_MODEL_PIN=$LLM_SOURCE_REVISION-$MLX_SERVE_COMMIT
# The LaunchAgent's --port, and what `tailscale serve` proxies to.
LLM_PORT=8000

# Installed by 2-tailscale.sh, at the paths Tailscale's own installer uses.
TAILSCALED=/usr/local/bin/tailscaled
L_TAILSCALED=com.tailscale.tailscaled
P_TAILSCALED=/Library/LaunchDaemons/$L_TAILSCALED.plist
L_BREW_TAILSCALED=sh.brew.tailscale
P_BREW_TAILSCALED=/Library/LaunchDaemons/$L_BREW_TAILSCALED.plist

# Installed by 4-harden.sh. Services never point into this git checkout.
LLM_SBIN=/usr/local/sbin
LLM_ETC=/usr/local/etc/llm-server
LLM_LOGS=/Library/Logs/llm-server
L_WATCHDOG=com.llmserver.batterywatchdog
L_PF=com.llmserver.pf
P_WATCHDOG=/Library/LaunchDaemons/$L_WATCHDOG.plist
P_PF=/Library/LaunchDaemons/$L_PF.plist
# pf rules for Screen Sharing live in an anchor under com.apple/, which the
# stock /etc/pf.conf already evaluates.
PF_ANCHOR=com.apple/250.llm-server

# --- output -----------------------------------------------------------------
# A terminal that went away, such as an SSH session dropped while 2-tailscale.sh
# restarts the tailnet, must not stop a script halfway under set -e.
step() { printf '\n== %s\n' "$*" || :; }
ok()   { printf '  ok    %s\n' "$*" || :; }
info() { printf '        %s\n' "$*" || :; }
warn() { printf '  WARN  %s\n' "$*" >&2 || :; }
bad()  { printf '  FAIL  %s\n' "$*" >&2 || :; }
die()  { printf '\nERROR: %s\n' "$*" >&2; exit 1; }

need_root() { [ "$(id -u)" = 0 ] || die "run with sudo: sudo sh $0"; }
need_user() { [ "$(id -u)" != 0 ] || die "run as your normal user, without sudo"; }

check_user() {
	[ "$LLM_USER" != root ] || die "LLM_USER resolved to root. Run via sudo from your own account, or set LLM_USER in config.env."
	[ -n "$LLM_HOME" ] && [ -d "$LLM_HOME" ] || die "no home directory found for user '$LLM_USER'"
}

# The executable of every tailscaled process, one per line.
tailscaled_paths() {
	for _p in $(pgrep -x tailscaled); do ps -o command= -p "$_p" | awk '{print $1}'; done | sort -u
}

# root_only PATH...: each is owned by root and writable by nobody else, so no
# other account can swap what root runs or reads from it.
root_only() {
	for _d in "$@"; do
		[ -e "$_d" ] || continue
		[ "$(stat -f %Su "$_d")" = root ] && [ -z "$(find "$_d" -maxdepth 0 \( -perm -020 -o -perm -002 \))" ] \
			|| return 1
	done
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
	[ -n "$_h" ] || return 1
	if [ "$LLM_HTTPS_PORT" = 443 ]; then
		printf 'https://%s' "$_h"
	else
		printf 'https://%s:%s' "$_h" "$LLM_HTTPS_PORT"
	fi
}
# serve_block URL: the lines of `tailscale serve status` for URL, which heads
# its own block, as `https://HOST` for port 443 and `https://HOST:PORT` for
# any other port.
serve_block() {
	tailscale serve status 2>/dev/null | awk -v url="$1" '/^https?:\/\// { on = ($1 == url) } on'
}
# serve_urls_to TARGET: every URL whose root `tailscale serve` proxies to
# TARGET, such as http://127.0.0.1:8000.
serve_urls_to() {
	tailscale serve status 2>/dev/null \
		| awk -v t="$1" '/^https?:\/\// { url = $1 } $2 == "/" && $3 == "proxy" && $4 == t { print url }'
}
# url_port URL: the HTTPS port of a URL from serve_urls_to.
url_port() {
	case ${1##*:} in
		*[!0-9]* | '') printf 443 ;;
		*) printf '%s' "${1##*:}" ;;
	esac
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

# pf expands the port list into one rule per port, and drops nothing unless pf
# itself is enabled.
pf_loaded() {
	_r=$(pfctl -a "$PF_ANCHOR" -sr 2>/dev/null)
	printf '%s\n' "$_r" | grep -q 'block drop in quick proto tcp.*port = 5900$' \
		&& printf '%s\n' "$_r" | grep -q 'block drop in quick proto tcp.*port = 88$' \
		&& pfctl -s info 2>/dev/null | grep -q 'Status: Enabled'
}

json_value() { printf '%s' "$1" | plutil -extract "$2" raw -o - - 2>/dev/null || :; }

# The version line the installed mlx-serve prints, asked as LLM_USER, who runs
# the server: `mlx-serve VERSION (BUILD MODE)`.
mlx_serve_version() {
	if [ "$(id -u)" = 0 ]; then
		sudo -u "$LLM_USER" "$MLX_SERVE_BIN" --version
	else
		"$MLX_SERVE_BIN" --version
	fi 2>/dev/null | awk 'NR == 1 && $1 == "mlx-serve" {print $2}'
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
	      -e "s|@LLM_MODEL_DIR@|$LLM_MODEL_DIR|g" \
	      -e "s|@LLM_MODEL_PIN@|$LLM_MODEL_PIN|g" \
	      -e "s|@LLM_PORT@|$LLM_PORT|g" \
	      -e "s|@KEY_FILE@|$KEY_FILE|g" \
	      -e "s|@MLX_SERVE_BIN@|$MLX_SERVE_BIN|g" \
	      -e "s|@MLX_SERVE_LABEL@|$MLX_SERVE_LABEL|g" \
	      -e "s|@MLX_SERVE_LOG@|$MLX_SERVE_LOG|g" \
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
