#!/bin/sh
# Check the whole setup. Changes nothing. Exit status is the number of failures.
#
#     sudo sh scripts/verify.sh
#
# Root, for the firewall and sshd checks. The model server runs in your login
# session, so log in on the Mac first (over Screen Sharing after a restart).
set -u
LLM_REPO=$(cd "$(dirname "$0")/.." && pwd)
# shellcheck source=scripts/lib.sh
. "$LLM_REPO/scripts/lib.sh"
need_root
check_user

FAILS=0
WARNS=0
pass() { ok "$*"; }
fail() { bad "$*"; FAILS=$((FAILS + 1)); }
note() { warn "$*"; WARNS=$((WARNS + 1)); }
expect() {  # description actual wanted
	if [ "$2" = "$3" ]; then pass "$1: $2"; else fail "$1: $2 (want $3)"; fi
}

EP=$(endpoint_url) || EP=
KEY=$(key)

step "Tailnet"
if [ -n "$EP" ]; then pass "$EP"; else fail "Tailscale is not up"; fi
serve=$(tailscale serve status 2>/dev/null)
if printf '%s\n' "$serve" | grep -q "127.0.0.1:$LLM_PORT"; then
	pass "tailscale serve -> 127.0.0.1:$LLM_PORT"
else
	fail "tailscale serve is not forwarding to 127.0.0.1:$LLM_PORT (re-run scripts/3-services.sh)"
fi
# Funnel would publish the endpoint to the whole internet.
if printf '%s\n' "$serve" | grep -qi 'funnel on' || ! printf '%s\n' "$serve" | grep -q '(tailnet only)'; then
	fail "tailscale serve is not tailnet-only: Funnel may be on. Turn it off, then re-run scripts/3-services.sh"
else
	pass "tailnet only (no Funnel)"
fi

step "TensorFold"
pass "$(sudo -u "$LLM_USER" "$TF_BIN" --version 2>/dev/null || echo "tensorfold: not installed")"
if job_loaded "gui/$LLM_UID/$TF_LABEL"; then
	pass "service $LLM_SERVICE loaded in $LLM_USER's login session"
elif [ "$(stat -f %Su /dev/console)" != "$LLM_USER" ]; then
	fail "service $LLM_SERVICE is not running: $LLM_USER is not logged in. Log in (over Screen Sharing), then re-run"
else
	fail "service $LLM_SERVICE is not loaded (re-run scripts/3-services.sh)"
fi
if [ -f "$TF_PLIST" ] && grep -q Cellar "$TF_PLIST"; then
	fail "$TF_PLIST points into Homebrew's Cellar: brew upgrade would break it (re-run scripts/3-services.sh)"
fi
# The server is `python -m tensorfold serve ...`; its supervisor,
# `-m tensorfold.control.runner`, must not count.
server_user=$(ps -axo user=,command= | awk '/ -m tensorfold serve / && !/awk/ {print $1; exit}')
if [ -z "$server_user" ]; then
	fail "no TensorFold server process"
elif [ "$server_user" = root ]; then
	fail "the TensorFold server runs as root"
else
	pass "server runs as $server_user, not root"
fi
expect "key file permissions" "$(stat -f %Sp:%Su "$KEY_FILE" 2>/dev/null)" "-rw-------:$LLM_USER"

step "Nothing listens beyond loopback"
addrs=$(lsof -nP -iTCP:"$LLM_PORT" -sTCP:LISTEN 2>/dev/null | awk 'NR > 1 {print $9}' | sort -u)
shown=$(printf '%s' "$addrs" | tr '\n' ' ')
if [ -z "$addrs" ]; then
	fail "nothing is listening on port $LLM_PORT"
elif printf '%s\n' "$addrs" | grep -qvE '^(127\.0\.0\.1|\[::1\]):'; then
	fail "port $LLM_PORT is exposed beyond loopback: $shown"
else
	pass "port $LLM_PORT: $shown"
fi

step "Endpoint"
code_hdr() { curl_hdr "$1" -s -o /dev/null -m 20 -w '%{http_code}' "$2"; }
expect "with the key" "$(http_code "$EP/v1/models" "$KEY")" 200
expect "without a key" "$(http_code "$EP/v1/models")" 401
expect "with a wrong key" "$(http_code "$EP/v1/models" wrong-key)" 401
expect "with the key as X-Api-Key" "$(code_hdr "X-Api-Key: $KEY" "$EP/v1/models")" 200
expect "with a wrong X-Api-Key" "$(code_hdr "X-Api-Key: wrong-key" "$EP/v1/models")" 401
# "Name;" is curl for an empty header; "Name:" would not send it at all.
expect "with an empty X-Api-Key" "$(code_hdr "X-Api-Key;" "$EP/v1/models")" 401
expect "metrics without a key" "$(http_code "$EP/metrics")" 401
# With keys configured, /health stays open but says nothing else.
expect "health without a key" "$(curl -s -m 10 "$EP/health")" '{"status": "ok"}'
expect "model ID clients see" \
	"$(curl_hdr "Authorization: Bearer $KEY" -s -m 20 "$EP/v1/models" | plutil -extract data.0.id raw -o - - 2>/dev/null)" "$LLM_SERVICE"

step "Machine"
if defaults read /Library/Preferences/com.apple.loginwindow autoLoginUser >/dev/null 2>&1; then
	fail "automatic login is on (run scripts/4-harden.sh)"
else
	pass "automatic login off"
fi
if [ -e /etc/kcpassword ]; then fail "/etc/kcpassword exists"; else pass "no /etc/kcpassword"; fi

if nc -z -G 2 127.0.0.1 22 >/dev/null 2>&1; then
	expect "SSH password authentication" "$(/usr/sbin/sshd -T 2>/dev/null | awk '$1 == "passwordauthentication" {print $2}')" no
	expect "SSH keyboard-interactive authentication" "$(/usr/sbin/sshd -T 2>/dev/null | awk '$1 == "kbdinteractiveauthentication" {print $2}')" no
	if [ "$LLM_SSH_TAILNET_ONLY" = yes ]; then
		# A client cannot tell a DenyUsers refusal from a key rejection, so ask
		# sshd what it would apply to a connection from each address.
		denied() { /usr/sbin/sshd -T -C "user=$LLM_USER,host=verify,addr=$1" 2>/dev/null | grep -qi '^denyusers'; }
		if denied 192.0.2.10; then pass "SSH from outside the tailnet refused"; else fail "SSH from outside the tailnet is allowed"; fi
		for a in $(tailscale ip -4 2>/dev/null) $(tailscale ip -6 2>/dev/null); do
			if denied "$a"; then fail "SSH from tailnet address $a is refused"; else pass "SSH from tailnet address $a allowed"; fi
		done
	fi
else
	pass "Remote Login is off"
fi

rules=$(pfctl -a "$PF_ANCHOR" -sr 2>/dev/null)
if printf '%s' "$rules" | grep -q 'block drop in quick proto tcp.*port = 5900' \
	&& printf '%s' "$rules" | grep -q 'block drop in quick proto tcp.*port = 88$' \
	&& printf '%s' "$rules" | grep -q 'block drop in quick proto tcp.*port = 47989' \
	&& pfctl -s info 2>/dev/null | grep -q 'Status: Enabled'; then
	pass "firewall loaded: Screen Sharing (5900), Kerberos (88) and Sunshine from the tailnet only"
	# From this machine to its own addresses: the local-network one must be
	# dropped, the tailnet one let through. Only for ports something listens on.
	lan=$(ipconfig getifaddr en0 2>/dev/null || ipconfig getifaddr en1 2>/dev/null)
	ts=$(tailscale ip -4 2>/dev/null | head -1)
	# Sunshine's web UI is reached on the Mac itself, or through an SSH tunnel.
	if lsof -nP -iTCP:47990 -sTCP:LISTEN >/dev/null 2>&1; then
		if nc -z -G 3 127.0.0.1 47990 >/dev/null 2>&1; then pass "Sunshine web UI from this Mac allowed"; else fail "Sunshine web UI from this Mac (127.0.0.1:47990) is blocked"; fi
	fi
	for pn in "5900 Screen Sharing" "88 Kerberos" "47989 Sunshine"; do
		port=${pn%% *}; name=${pn#* }
		lsof -nP -iTCP:"$port" -sTCP:LISTEN >/dev/null 2>&1 || continue
		if [ -n "$lan" ]; then
			if nc -z -G 3 "$lan" "$port" >/dev/null 2>&1; then fail "$name reachable on the local network ($lan)"; else pass "$name from the local network ($lan) dropped"; fi
		fi
		if [ -n "$ts" ]; then
			if nc -z -G 3 "$ts" "$port" >/dev/null 2>&1; then pass "$name from the tailnet ($ts) allowed"; else fail "$name from the tailnet ($ts) is blocked"; fi
		fi
	done
else
	fail "firewall for Screen Sharing, Kerberos and Sunshine not loaded (run scripts/4-harden.sh)"
fi

if is_laptop; then
	expect "hibernatemode on battery" "$(pmset -g custom | awk '/^Battery Power:/ {f = 1} f && $1 == "hibernatemode" {print $2; exit}')" 3
	if job_loaded "system/$L_WATCHDOG"; then pass "battery watchdog loaded"; else fail "battery watchdog is not loaded (run scripts/4-harden.sh)"; fi
fi

if lsof -nP -iTCP:7000 -sTCP:LISTEN >/dev/null 2>&1; then
	note "AirPlay Receiver is listening on 5000/7000 (System Settings > General > AirDrop & Handoff)"
fi

printf '\n%d failure(s), %d warning(s)\n' "$FAILS" "$WARNS"
exit "$FAILS"
