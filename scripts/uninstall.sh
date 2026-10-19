#!/bin/sh
# Remove everything scripts 3 and 4 installed.
#
#     sudo sh scripts/uninstall.sh
#
# Deliberately leaves the model files, the API key file, the logs, the Homebrew
# packages, the tailnet membership and the power settings. The list is printed
# at the end.
set -u
LLM_REPO=$(cd "$(dirname "$0")/.." && pwd)
# shellcheck source=scripts/lib.sh
. "$LLM_REPO/scripts/lib.sh"
need_root
check_user

step "Model server"
if tailscale serve status 2>/dev/null | grep -q "127.0.0.1:$LLM_PORT"; then
	if tailscale serve --https=443 off >/dev/null 2>&1; then
		ok "tailscale serve off"
	else
		warn "could not stop tailscale serve: run 'tailscale serve --https=443 off'"
	fi
fi
stop_job "gui/$LLM_UID/$SPLASH_LABEL"
rm -f "$SPLASH_PLIST"
ok "Splash server $SPLASH_LABEL removed"

step "Hardening"
stop_job "system/$L_WATCHDOG"
stop_job "system/$L_PF"
rm -f "$P_WATCHDOG" "$P_PF" "$LLM_SBIN/llm-battery-watchdog.sh"
rm -rf "$LLM_ETC"
ok "battery watchdog and firewall jobs"
# Only this anchor's rules: pf itself stays as macOS left it.
if pfctl -a "$PF_ANCHOR" -F rules 2>/dev/null; then
	ok "firewall rules (Screen Sharing and Sunshine, if on, are reachable from every network again)"
else
	warn "could not flush pf anchor $PF_ANCHOR: run 'sudo pfctl -a $PF_ANCHOR -F rules'"
fi

DROPIN=/etc/ssh/sshd_config.d/200-llm-server.conf
# Set aside outside sshd_config.d: sshd_config includes every file in it, so a
# renamed copy there would still be read by the check below.
ASIDE=/etc/ssh/200-llm-server.conf.removed
if [ -f "$DROPIN" ]; then
	mv "$DROPIN" "$ASIDE"
	if /usr/sbin/sshd -t; then
		rm -f "$ASIDE"
		ok "SSH hardening (passwords are allowed again, per macOS defaults)"
	else
		mv "$ASIDE" "$DROPIN"
		warn "sshd rejected its config without the drop-in; left it in place"
	fi
fi

cat <<LEFT

== Left in place, on purpose
  models           ~/.cache/huggingface/hub    (hf cache delete, or delete the folder)
  API key          $KEY_FILE
  logs             $SPLASH_LOG, $LLM_LOGS
  Splash           $SPLASH_HOME, $SPLASH_BIN, $LLM_HOME/Library/Application Support/Splash
  packages         brew uninstall tailscale
  tailnet          sudo tailscale logout
  power settings   pmset -g custom   (these are ordinary macOS settings)
  automatic login  stays off
LEFT
