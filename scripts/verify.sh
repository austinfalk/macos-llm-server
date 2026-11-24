#!/bin/sh
# Check the whole setup. Changes nothing. Exit status is the number of failures.
#
#     sudo sh scripts/verify.sh
#
# Root, for the FileVault, firewall and sshd checks. The model server runs in your login
# session, so log in on the Mac first (over Screen Sharing after a restart).
set -u
LLM_REPO=$(cd "$(dirname "$0")/.." && pwd)
# shellcheck source=scripts/lib.sh
. "$LLM_REPO/scripts/lib.sh"
need_root
check_user

FAILS=0
pass() { ok "$*"; }
fail() { bad "$*"; FAILS=$((FAILS + 1)); }
expect() {  # description actual wanted
	if [ "$2" = "$3" ]; then pass "$1: $2"; else fail "$1: $2 (want $3)"; fi
}

EP=$(endpoint_url) || EP=
KEY=$(key)

step "Tailnet"
if [ -n "$EP" ]; then pass "$EP"; else fail "Tailscale is not up"; fi
serve=$(serve_block "$EP")
if printf '%s\n' "$serve" | grep -q " proxy http://127.0.0.1:$LLM_PORT\$"; then
	pass "tailscale serve -> 127.0.0.1:$LLM_PORT"
else
	fail "tailscale serve is not forwarding $EP to 127.0.0.1:$LLM_PORT (re-run scripts/3-services.sh)"
fi
for url in $(serve_urls_to "http://127.0.0.1:$LLM_PORT"); do
	[ "$url" = "$EP" ] || fail "tailscale serve also forwards $url to the server (re-run scripts/3-services.sh)"
done
# Funnel would publish the endpoint to the whole internet.
if printf '%s\n' "$serve" | grep -qi 'funnel on' || ! printf '%s\n' "$serve" | grep -q '(tailnet only)'; then
	fail "tailscale serve is not tailnet-only: Funnel may be on. Turn it off, then re-run scripts/3-services.sh"
else
	pass "tailnet only (no Funnel)"
fi
# Root runs tailscaled, so no other account may be able to change it.
ts_paths=$(tailscaled_paths)
if [ "$ts_paths" = "$TAILSCALED" ] && [ ! -L "$TAILSCALED" ] \
	&& root_only /usr/local "$(dirname "$TAILSCALED")" "$TAILSCALED" && [ ! -f "$P_BREW_TAILSCALED" ]; then
	pass "tailscaled runs from $TAILSCALED, which only root can change"
else
	fail "tailscaled runs from $(printf '%s' "${ts_paths:-nowhere}" | tr '\n' ' '), not only a root-owned $TAILSCALED (re-run scripts/2-tailscale.sh)"
fi
if cmp -s "$LLM_REPO/config/$L_TAILSCALED.plist" "$P_TAILSCALED"; then
	pass "tailscaled restarts if it exits ($P_TAILSCALED)"
else
	fail "$P_TAILSCALED is not this repo's, which restarts tailscaled if it exits (re-run scripts/2-tailscale.sh)"
fi

step "mlx-serve"
if job_loaded "gui/$LLM_UID/$MLX_SERVE_LABEL"; then
	pass "server $MLX_SERVE_LABEL loaded in $LLM_USER's login session"
elif [ "$(stat -f %Su /dev/console)" != "$LLM_USER" ]; then
	fail "server $MLX_SERVE_LABEL is not running: $LLM_USER is not logged in. Log in (over Screen Sharing), then re-run"
else
	fail "server $MLX_SERVE_LABEL is not loaded (re-run scripts/3-services.sh)"
fi
expect "mlx-serve build" "$(mlx_serve_version)" "$MLX_SERVE_BUILD"
# The LaunchAgent's shell execs mlx-serve, so launchd's pid is the server's.
pid=$(launchctl print "gui/$LLM_UID/$MLX_SERVE_LABEL" 2>/dev/null | awk '$1 == "pid" {print $3; exit}')
if [ -z "$pid" ]; then
	fail "no mlx-serve process"
else
	expect "mlx-serve runs as" "$(ps -o user= -p "$pid")" "$LLM_USER"
fi
expect "key file permissions" "$(stat -f %Sp:%Su "$KEY_FILE" 2>/dev/null)" "-rw-------:$LLM_USER"
if cmp -s "$LLM_REPO/config/generation-settings.json" "$MLX_SERVE_GEN_SETTINGS"; then
	pass "reasoning effort medium unless a request names one ($MLX_SERVE_GEN_SETTINGS)"
else
	fail "$MLX_SERVE_GEN_SETTINGS is not this repo's, so requests that name no effort think at high (re-run scripts/3-services.sh)"
fi

step "Nothing listens beyond loopback"
# Every socket mlx-serve listens on, since by default it listens on every
# interface.
addrs=$([ -z "$pid" ] || lsof -nP -a -p "$pid" -iTCP -sTCP:LISTEN 2>/dev/null | awk 'NR > 1 {print $9}' | sort -u)
shown=$(printf '%s' "$addrs" | tr '\n' ' ')
if [ -z "$addrs" ]; then
	fail "mlx-serve is not listening"
elif printf '%s\n' "$addrs" | grep -qvE '^(127\.0\.0\.1|\[::1\]):'; then
	fail "mlx-serve listens beyond loopback: $shown"
elif ! printf '%s\n' "$addrs" | grep -qx "127.0.0.1:$LLM_PORT"; then
	fail "mlx-serve does not listen on 127.0.0.1:$LLM_PORT, where tailscale serve sends requests: $shown"
else
	pass "mlx-serve listens on $shown"
fi

step "Endpoint"
code_hdr() { curl_hdr "$1" -s -o /dev/null -m 20 -w '%{http_code}' "$2"; }
expect "with the key" "$(http_code "$EP/v1/models" "$KEY")" 200
# tailscale serve connects from loopback, which mlx-serve lets in without the
# key unless --api-key-strict is on.
expect "without a key" "$(http_code "$EP/v1/models")" 401
expect "with a wrong key" "$(http_code "$EP/v1/models" wrong-key)" 401
expect "with the key as X-Api-Key" "$(code_hdr "X-Api-Key: $KEY" "$EP/v1/models")" 200
expect "with a wrong X-Api-Key" "$(code_hdr "X-Api-Key: wrong-key" "$EP/v1/models")" 401
# "Name;" is curl for an empty header; "Name:" would not send it at all.
expect "with an empty X-Api-Key" "$(code_hdr "X-Api-Key;" "$EP/v1/models")" 401
expect "metrics without a key" "$(http_code "$EP/metrics")" 401
# /health stays open without the key, and says nothing else.
expect "health without a key" "$(curl -s -m 10 "$EP/health")" '{"status":"ok"}'
expect "model ID clients see" \
	"$(curl_hdr "Authorization: Bearer $KEY" -s -m 20 "$EP/v1/models" | plutil -extract data.0.id raw -o - - 2>/dev/null)" "$LLM_MODEL_ID"
# A build can answer 200 and still write nonsense, so ask a follow-up whose
# answer is known.
answer=$(curl_hdr "Authorization: Bearer $KEY" -s -m 120 -H 'Content-Type: application/json' \
	-d "{\"model\":\"$LLM_MODEL_ID\",\"max_tokens\":2048,\"messages\":[{\"role\":\"user\",\"content\":\"What is 2+2?\"},{\"role\":\"assistant\",\"content\":\"4\"},{\"role\":\"user\",\"content\":\"And 3+3? Digits only.\"}]}" \
	"$EP/v1/chat/completions" | plutil -extract choices.0.message.content raw -o - - 2>/dev/null)
expect "a follow-up's answer" "$(printf '%s' "$answer" | tr -d '[:space:].')" 6

step "Machine"
if fdesetup status 2>/dev/null | grep -q 'is On'; then
	pass "FileVault on"
else
	fail "FileVault is off: anyone holding the Mac can read its disk (sudo fdesetup enable)"
fi

if nc -z -G 2 127.0.0.1 22 >/dev/null 2>&1; then
	expect "SSH password authentication" "$(/usr/sbin/sshd -T 2>/dev/null | awk 'tolower($1) == "passwordauthentication" {print $2}')" no
	expect "SSH keyboard-interactive authentication" "$(/usr/sbin/sshd -T 2>/dev/null | awk 'tolower($1) == "kbdinteractiveauthentication" {print $2}')" no
	# A client cannot tell a DenyUsers refusal from a key rejection, so ask
	# sshd what it would apply to a connection from each address.
	denied() { /usr/sbin/sshd -T -C "user=$LLM_USER,host=verify,addr=$1" 2>/dev/null | grep -qi '^denyusers'; }
	if denied 192.0.2.10; then pass "SSH from outside the tailnet refused"; else fail "SSH from outside the tailnet is allowed"; fi
	for a in $(tailscale ip -4 2>/dev/null) $(tailscale ip -6 2>/dev/null); do
		if denied "$a"; then fail "SSH from tailnet address $a is refused"; else pass "SSH from tailnet address $a allowed"; fi
	done
else
	pass "Remote Login is off"
fi

if pf_loaded; then
	pass "firewall loaded: Screen Sharing (5900) and Kerberos (88) from the tailnet only"
	# From this machine to its own addresses: the local-network one must be
	# dropped, the tailnet one let through. Only for ports something listens on.
	lan=$(ipconfig getifaddr en0 2>/dev/null || ipconfig getifaddr en1 2>/dev/null)
	ts=$(tailscale ip -4 2>/dev/null | head -1)
	for pn in "5900 Screen Sharing" "88 Kerberos"; do
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
	fail "firewall for Screen Sharing and Kerberos not loaded (run scripts/4-harden.sh)"
fi

if is_laptop && [ "$LLM_DISABLE_SLEEP" = yes ]; then
	if job_loaded "system/$L_WATCHDOG"; then pass "battery watchdog loaded"; else fail "battery watchdog is not loaded (run scripts/4-harden.sh)"; fi
fi

printf '\n%d failure(s)\n' "$FAILS"
exit "$FAILS"
