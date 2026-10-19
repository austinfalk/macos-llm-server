#!/bin/sh
# README step 5: serve the model with Splash, behind an API key, on the
# tailnet.
# Run as yourself: Splash runs in your login session, where macOS gives it the
# GPU and the Neural Engine.
#
#     sh scripts/3-services.sh
#
# Safe to re-run: it restarts the server only when its settings differ, and
# checks the endpoint again.
set -eu
LLM_REPO=$(cd "$(dirname "$0")/.." && pwd)
# shellcheck source=scripts/lib.sh
. "$LLM_REPO/scripts/lib.sh"
need_user
check_user
[ "$(id -un)" = "$LLM_USER" ] || die "run this as $LLM_USER (LLM_USER), who owns the server"

step "Prerequisites"
[ -x "$SPLASH_BIN" ] || die "Splash is not installed: run scripts/1-install.sh"
version=$("$SPLASH_BIN" --version 2>/dev/null) || version=
[ "$version" = "Splash $SPLASH_VERSION" ] || die "$SPLASH_BIN is '$version', not Splash $SPLASH_VERSION: run scripts/1-install.sh"
EP=$(endpoint_url) || EP=
[ -n "$EP" ] || die "Tailscale is not up: run sudo sh scripts/2-tailscale.sh"
tailscale status --json | plutil -extract CertDomains.0 raw -o - - >/dev/null 2>&1 \
	|| die "HTTPS certificates are off for this tailnet: see scripts/2-tailscale.sh"
ENDPOINT_HOST=$(endpoint_host)
ok "$version; endpoint will be $EP"

step "API key"
new_key=no
if [ ! -s "$KEY_FILE" ]; then
	new_key=yes
	mkdir -p "$(dirname "$KEY_FILE")"
	( umask 077; LC_ALL=C tr -dc 'A-Za-z0-9' </dev/urandom | head -c 48 >"$KEY_FILE"; echo >>"$KEY_FILE" )
	ok "generated $KEY_FILE"
else
	ok "using existing $KEY_FILE"
fi
chmod 600 "$KEY_FILE"
key | grep -Eqx '[A-Za-z0-9]{32,}' \
	|| die "$KEY_FILE does not hold a key of 32+ letters and digits. Delete it and re-run to make a new one."

step "Server"
mkdir -p "$(dirname "$SPLASH_PLIST")" "$(dirname "$SPLASH_LOG")"
new=$SPLASH_PLIST.new.$$
render com.llmserver.splash.plist "$new" 600 "$LLM_USER:staff"
# Splash reads the key once, at start, so a new key needs a restart too.
if [ $new_key = no ] && [ -f "$SPLASH_PLIST" ] && cmp -s "$new" "$SPLASH_PLIST" && job_loaded "gui/$LLM_UID/$SPLASH_LABEL"; then
	rm -f "$new"
	ok "already running with these settings"
else
	if lsof -nP -iTCP:"$LLM_PORT" -sTCP:LISTEN >/dev/null 2>&1 && ! job_loaded "gui/$LLM_UID/$SPLASH_LABEL"; then
		rm -f "$new"
		die "something else listens on port $LLM_PORT: $(lsof -nP -iTCP:"$LLM_PORT" -sTCP:LISTEN | awk 'NR == 2 {print $1, "pid", $2}'). Stop it, then re-run this script."
	fi
	job_loaded "gui/$LLM_UID/$SPLASH_LABEL" && info "restarting with new settings: the endpoint is down until it is back"
	mv -f "$new" "$SPLASH_PLIST"
	start_job "gui/$LLM_UID" "$SPLASH_LABEL" "$SPLASH_PLIST" \
		|| die "the server did not start, so the endpoint is down. Read $SPLASH_LOG, fix the cause, then re-run sh scripts/3-services.sh"
	ok "started $SPLASH_LABEL"
fi

info "waiting for the model (the first start can take half an hour)"
runs() { launchctl print "gui/$LLM_UID/$SPLASH_LABEL" 2>/dev/null | awk '$1 == "runs" {print $3; exit}'; }
runs0=$(runs)
crash_looping() { [ "$(runs)" -ge $((${runs0:-1} + 2)) ]; }
n=0
until curl -s -o /dev/null -m 5 -w '%{http_code}' "http://127.0.0.1:$LLM_PORT/ready" 2>/dev/null | grep -qx 200; do
	n=$((n + 1))
	if [ $n -ge 720 ] || crash_looping || ! job_loaded "gui/$LLM_UID/$SPLASH_LABEL"; then
		tail -15 "$SPLASH_LOG" 2>/dev/null | sed 's/^/        log: /'
		die "the server did not come up, so the endpoint is down. Read $SPLASH_LOG, fix the cause, then re-run sh scripts/3-services.sh"
	fi
	sleep 5
done
ok "ready"

step "Tailnet HTTPS"
# As the Tailscale operator (scripts/2-tailscale.sh), no sudo needed.
tailscale serve --bg "$LLM_PORT" >/dev/null
if tailscale serve status 2>/dev/null | grep -q "127.0.0.1:$LLM_PORT"; then
	ok "tailscale serve: $EP -> 127.0.0.1:$LLM_PORT"
else
	die "tailscale serve did not take. See: tailscale serve status"
fi

step "Checking"
code=$(http_code "$EP/v1/models" "$(key)")
unauth=$(http_code "$EP/v1/models")
if [ "$code" = 200 ]; then ok "with the key    -> 200"; else bad "with the key    -> $code (want 200)"; fi
if [ "$unauth" = 401 ]; then ok "without the key -> 401"; else bad "without the key -> $unauth (want 401)"; fi
[ "$code" = 200 ] && [ "$unauth" = 401 ] \
	|| die "the endpoint is not healthy. See: $SPLASH_LOG"

printf '\nEndpoint: %s/v1   model: %s\nKey:      %s\n\nNext:\n' "$EP" "$LLM_MODEL" "$KEY_FILE"
if [ -f /etc/ssh/sshd_config.d/200-llm-server.conf ] || launchctl print "system/$L_PF" >/dev/null 2>&1; then
	printf '    sudo sh scripts/verify.sh\n'
else
	printf '    sudo sh scripts/4-harden.sh\n'
fi
