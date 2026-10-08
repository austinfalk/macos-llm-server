#!/bin/sh
# README step 5: serve the model with TensorFold, behind an API key, on the
# tailnet.
# Run as yourself: TensorFold's service lives in your login session and refuses
# root.
#
#     sh scripts/3-services.sh
#
# Safe to re-run: it reinstalls the service only when its settings differ, and
# checks the endpoint again.
set -eu
LLM_REPO=$(cd "$(dirname "$0")/.." && pwd)
# shellcheck source=scripts/lib.sh
. "$LLM_REPO/scripts/lib.sh"
need_user
check_user
[ "$(id -un)" = "$LLM_USER" ] || die "run this as $LLM_USER (LLM_USER), who owns the service"

step "Prerequisites"
[ -x "$TF_BIN" ] || die "TensorFold ($TF_FORMULA) is not installed: run scripts/1-install.sh"
[ -x "$TF_PYTHON" ] || die "$TF_PYTHON is missing: reinstall with brew reinstall $TF_FORMULA"
EP=$(endpoint_url) || EP=
[ -n "$EP" ] || die "Tailscale is not up: run sudo sh scripts/2-tailscale.sh"
tailscale status --json | plutil -extract CertDomains.0 raw -o - - >/dev/null 2>&1 \
	|| die "HTTPS certificates are off for this tailnet: see scripts/2-tailscale.sh"
ok "$("$TF_BIN" --version); endpoint will be $EP"

step "API key"
# TensorFold's key file: one "label: key" a line, mode 0600 or it refuses to
# start. The "clients" key is the one every client uses.
if [ ! -s "$KEY_FILE" ]; then
	mkdir -p "$(dirname "$KEY_FILE")"
	( umask 077; printf 'clients: %s\n' "$(LC_ALL=C tr -dc 'A-Za-z0-9' </dev/urandom | head -c 48)" >"$KEY_FILE" )
	ok "generated $KEY_FILE"
else
	ok "using existing $KEY_FILE"
fi
chmod 600 "$KEY_FILE"
key | grep -Eqx '[A-Za-z0-9]{32,}' \
	|| die "$KEY_FILE has no 'clients: <key>' line of 32+ letters and digits. Delete it and re-run to make a new one."

step "Model"
# `pull` returns at once when the files are already in the Hugging Face cache.
# TensorFold uses the recipe's drafter automatically once it is there. The
# first download is about 20 GB.
if ! pulled=$("$TF_BIN" pull "$LLM_MODEL" ${LLM_DRAFTER:+"$LLM_DRAFTER"} 2>&1); then
	printf '%s\n' "$pulled" | grep -v -e 'Fetching' -e '^$' | tail -10 | sed 's/^/        /'
	die "the download failed; nothing was changed. Re-run this when the network is back"
fi
printf '%s\n' "$pulled" | grep -v -e 'Fetching' -e '^$' | sed 's/^/        /'
ok "$LLM_MODEL${LLM_DRAFTER:+ with $LLM_DRAFTER}"

step "Service"
# Everything not named here is TensorFold's default: context, drafting,
# thinking, sampling, concurrency.
profile="$LLM_HOME/Library/Application Support/TensorFold/control/profiles/$LLM_SERVICE.json"
same=no
if [ -f "$profile" ]; then
	field() { plutil -extract "$1" raw -o - "$profile" 2>/dev/null; }
	want=$(printf '%s|' "$LLM_MODEL" "$LLM_PORT" "$KEY_FILE" "$TF_PYTHON" 127.0.0.1 false 2)
	have=$(printf '%s|' "$(field model)" "$(field port)" "$(field api_key_file)" "$(field python)" \
		"$(field host)" "$(field allow_network)" "$(field args)")
	[ "$want" = "$have" ] && same=yes
fi
if [ $same = yes ]; then
	ok "$LLM_SERVICE already installed with these settings"
	"$TF_BIN" service status "$LLM_SERVICE" 2>/dev/null | grep -q 'state: running' \
		|| "$TF_BIN" service start "$LLM_SERVICE" >/dev/null \
		|| die "the service did not start. See: $TF_BIN service doctor $LLM_SERVICE"
else
	if [ -f "$profile" ]; then
		"$TF_BIN" service stop "$LLM_SERVICE" >/dev/null 2>&1 || true
		info "stopped $LLM_SERVICE to reinstall it with new settings: the endpoint is down until it is back"
	fi
	"$TF_BIN" service install "$LLM_MODEL" --name "$LLM_SERVICE" --port "$LLM_PORT" \
		--api-key-file "$KEY_FILE" --python "$TF_PYTHON" --replace >/dev/null \
		|| die "the service install failed, and the service is stopped. See: $TF_BIN service doctor $LLM_SERVICE
       To bring the previous settings back: $TF_BIN service start $LLM_SERVICE"
	"$TF_BIN" service start "$LLM_SERVICE" >/dev/null \
		|| die "the service did not start, so the endpoint is down. See: $TF_BIN service doctor $LLM_SERVICE"
	ok "installed $LLM_SERVICE and started it"
fi
grep -q Cellar "$TF_PLIST" && die "$TF_PLIST points into Homebrew's Cellar, which brew upgrade deletes"

# Loading a 27B model and measuring this Mac's kernels takes a few minutes.
info "waiting for the model to load (a few minutes)"
n=0
until curl -s -m 5 "http://127.0.0.1:$LLM_PORT/health" 2>/dev/null | grep -q '"ok"'; do
	n=$((n + 1))
	if [ $n -ge 120 ] || ! "$TF_BIN" service status "$LLM_SERVICE" 2>/dev/null | grep -q 'loaded: True'; then
		tail -15 "$TF_LOG" 2>/dev/null | sed 's/^/        log: /'
		die "the server did not come up. See: $TF_BIN service logs $LLM_SERVICE"
	fi
	sleep 5
done
grep -E '\[tensorfold\] (serving|context window)' "$TF_LOG" 2>/dev/null | tail -2 | sed 's/^[0-9:]* \[tensorfold\] /        /'

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
	|| die "the endpoint is not healthy. See: $TF_BIN service logs $LLM_SERVICE"

printf '\nEndpoint: %s/v1   model: %s\nKey:      the "clients" line of %s\n\nNext:\n' "$EP" "$LLM_SERVICE" "$KEY_FILE"
if [ -f /etc/ssh/sshd_config.d/200-llm-server.conf ] || launchctl print "system/$L_PF" >/dev/null 2>&1; then
	printf '    sudo sh scripts/verify.sh\n'
else
	printf '    sudo sh scripts/4-harden.sh\n'
fi
