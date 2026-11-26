#!/bin/sh
# README step 5: serve the model with mlx-serve, behind an API key, on the
# tailnet.
# Run as yourself: mlx-serve runs in your login session, where macOS gives it
# the GPU.
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
case $LLM_HTTPS_PORT in
	'' | *[!0-9]*) die "LLM_HTTPS_PORT is '$LLM_HTTPS_PORT', not a port number: fix it in config.env" ;;
esac
[ -x "$MLX_SERVE_BIN" ] || die "mlx-serve is not installed: run scripts/1-install.sh"
version=$(mlx_serve_version)
[ "$version" = "$MLX_SERVE_BUILD" ] || die "$MLX_SERVE_BIN is '${version:-unknown}', not mlx-serve $MLX_SERVE_BUILD: run scripts/1-install.sh"
[ -f "$LLM_MODEL_DIR/config.json" ] || die "$LLM_MODEL_ID is not converted: run scripts/1-install.sh"
EP=$(endpoint_url) || EP=
[ -n "$EP" ] || die "Tailscale is not up: run sudo sh scripts/2-tailscale.sh"
tailscale status --json | plutil -extract CertDomains.0 raw -o - - >/dev/null 2>&1 \
	|| die "HTTPS certificates are off for this tailnet: see scripts/2-tailscale.sh"
ok "mlx-serve $version; endpoint will be $EP"

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

step "Generation defaults"
# A request that names no reasoning effort gets the chat template's default,
# high, as Thinking Machines ship it. An earlier version of this repo installed
# a rule giving "medium"; remove it. mlx-serve reads the file at each request,
# so this needs no restart.
if [ "$(cat "$MLX_SERVE_GEN_SETTINGS" 2>/dev/null)" = '{"reasoning_effort": {"value": "medium"}}' ]; then
	rm -f "$MLX_SERVE_GEN_SETTINGS"
fi
if [ -e "$MLX_SERVE_GEN_SETTINGS" ]; then
	warn "$MLX_SERVE_GEN_SETTINGS holds rules this repo did not write; left in place"
else
	ok "reasoning effort high unless a request names one (the template's default)"
fi

step "Server"
mkdir -p "$(dirname "$MLX_SERVE_PLIST")" "$(dirname "$MLX_SERVE_LOG")"
new=$MLX_SERVE_PLIST.new.$$
render com.llmserver.mlx-serve.plist "$new" 600 "$LLM_USER:staff"
# mlx-serve reads the key once, at start, so a new key needs a restart too.
if [ $new_key = no ] && [ -f "$MLX_SERVE_PLIST" ] && cmp -s "$new" "$MLX_SERVE_PLIST" && job_loaded "gui/$LLM_UID/$MLX_SERVE_LABEL"; then
	rm -f "$new"
	ok "already running with these settings"
else
	if lsof -nP -iTCP:"$LLM_PORT" -sTCP:LISTEN >/dev/null 2>&1 && ! job_loaded "gui/$LLM_UID/$MLX_SERVE_LABEL"; then
		rm -f "$new"
		die "something else listens on port $LLM_PORT: $(lsof -nP -iTCP:"$LLM_PORT" -sTCP:LISTEN | awk 'NR == 2 {print $1, "pid", $2}'). Stop it, then re-run this script."
	fi
	job_loaded "gui/$LLM_UID/$MLX_SERVE_LABEL" && info "restarting with new settings: the endpoint is down until it is back"
	mv -f "$new" "$MLX_SERVE_PLIST"
	start_job "gui/$LLM_UID" "$MLX_SERVE_LABEL" "$MLX_SERVE_PLIST" \
		|| die "the server did not start, so the endpoint is down. Read $MLX_SERVE_LOG, fix the cause, then re-run sh scripts/3-services.sh"
	ok "started $MLX_SERVE_LABEL"
fi

info "waiting for the model to load"
runs() { launchctl print "gui/$LLM_UID/$MLX_SERVE_LABEL" 2>/dev/null | awk '$1 == "runs" {print $3; exit}'; }
runs0=$(runs)
crash_looping() { [ "$(runs)" -ge $((${runs0:-1} + 2)) ]; }
# /health needs no key. It answers 503 while the model loads and 200 once
# mlx-serve can serve it.
n=0
until curl -s -o /dev/null -m 5 -w '%{http_code}' "http://127.0.0.1:$LLM_PORT/health" 2>/dev/null | grep -qx 200; do
	n=$((n + 1))
	if [ $n -ge 120 ] || crash_looping || ! job_loaded "gui/$LLM_UID/$MLX_SERVE_LABEL"; then
		tail -15 "$MLX_SERVE_LOG" 2>/dev/null | sed 's/^/        log: /'
		die "the server did not come up, so the endpoint is down. Read $MLX_SERVE_LOG, fix the cause, then re-run sh scripts/3-services.sh"
	fi
	sleep 5
done
ok "ready"

step "Tailnet HTTPS"
# As the Tailscale operator (scripts/2-tailscale.sh), no sudo needed.
# Serve configures each HTTPS port separately, so after LLM_HTTPS_PORT changes,
# the old port would keep serving the endpoint, and keep it from anything else.
tailscale serve --bg --https="$LLM_HTTPS_PORT" "$LLM_PORT" >/dev/null
if serve_block "$EP" | grep -q " proxy http://127.0.0.1:$LLM_PORT\$"; then
	ok "tailscale serve: $EP -> 127.0.0.1:$LLM_PORT"
else
	die "tailscale serve did not take. See: tailscale serve status"
fi
for url in $(serve_urls_to "http://127.0.0.1:$LLM_PORT"); do
	[ "$url" != "$EP" ] || continue
	tailscale serve --https="$(url_port "$url")" off >/dev/null \
		|| die "could not stop serving the endpoint at $url as well: run 'tailscale serve --https=$(url_port "$url") off'"
	ok "no longer served at $url"
done

step "Checking"
# tailscale serve connects from loopback, which mlx-serve exempts from the key
# unless --api-key-strict is on. The 401 shows that it is.
code=$(http_code "$EP/v1/models" "$(key)")
unauth=$(http_code "$EP/v1/models")
if [ "$code" = 200 ]; then ok "with the key    -> 200"; else bad "with the key    -> $code (want 200)"; fi
if [ "$unauth" = 401 ]; then ok "without the key -> 401"; else bad "without the key -> $unauth (want 401)"; fi
[ "$code" = 200 ] && [ "$unauth" = 401 ] \
	|| die "the endpoint is not healthy. See: $MLX_SERVE_LOG"

printf '\nEndpoint: %s/v1   model: %s\nKey:      %s\n\nNext:\n' "$EP" "$LLM_MODEL_ID" "$KEY_FILE"
if [ -f /etc/ssh/sshd_config.d/200-llm-server.conf ] || launchctl print "system/$L_PF" >/dev/null 2>&1; then
	printf '    sudo sh scripts/verify.sh\n'
else
	printf '    sudo sh scripts/4-harden.sh\n'
fi
