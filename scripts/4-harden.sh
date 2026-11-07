#!/bin/sh
# README step 6: tighten the machine around the server. Safe to re-run.
#
#     sudo sh scripts/4-harden.sh
set -eu
LLM_REPO=$(cd "$(dirname "$0")/.." && pwd)
# shellcheck source=scripts/lib.sh
. "$LLM_REPO/scripts/lib.sh"
need_root
check_user

# The battery watchdog and the pf job log here. Root's, so that no ordinary
# account can swap a log root writes for a link to somewhere else.
mkdir -p "$LLM_LOGS"
chown root:wheel "$LLM_LOGS"
chmod 755 "$LLM_LOGS"
mkdir -p "$LLM_ETC" "$LLM_SBIN"

step "FileVault"
# Turning it on asks for the account password and prints a recovery key, so it
# is a step for a person, not this script.
if fdesetup status 2>/dev/null | grep -q 'is On'; then
	ok "on"
else
	warn "off: anyone holding the Mac can read its disk. Turn it on:"
	warn "    sudo fdesetup enable"
	warn "and keep the recovery key it prints somewhere other than this Mac."
fi

step "SSH"
DROPIN=/etc/ssh/sshd_config.d/200-llm-server.conf
# The backup lives outside sshd_config.d, which sshd_config includes whole.
PREVIOUS=/etc/ssh/200-llm-server.conf.previous
if nc -z -G 2 127.0.0.1 22 >/dev/null 2>&1; then
	keys=$(grep -cE '^(ssh-|ecdsa-|sk-)' "$LLM_HOME/.ssh/authorized_keys" 2>/dev/null) || keys=0
	[ "$keys" -gt 0 ] || die "Remote Login is on, but $LLM_USER has no key in ~/.ssh/authorized_keys.
Disabling passwords now would lock you out. Add a public key there first, then re-run."
	[ -f "$DROPIN" ] && cp -p "$DROPIN" "$PREVIOUS"
	render sshd-tailnet-only.conf "$DROPIN" 644 root:wheel
	if ! /usr/sbin/sshd -t; then
		if [ -f "$PREVIOUS" ]; then mv -f "$PREVIOUS" "$DROPIN"; else rm -f "$DROPIN"; fi
		die "sshd rejected the new configuration; SSH was left as it was"
	fi
	rm -f "$PREVIOUS"
	# No restart needed: launchd starts a fresh sshd for every connection.
	# sshd keeps the first value it reads, so an earlier drop-in, or a macOS
	# whose sshd_config does not include the drop-in directory, would quietly
	# override this one. Check what sshd will actually apply.
	for opt in passwordauthentication kbdinteractiveauthentication; do
		v=$(/usr/sbin/sshd -T 2>/dev/null | awk -v o="$opt" 'tolower($1) == o {print $2}')
		[ -n "$v" ] || die "could not read sshd's effective settings (sshd -T)"
		[ "$v" = no ] || die "sshd still allows $opt: another setting in /etc/ssh overrides $DROPIN"
	done
	ok "keys only, and only from the tailnet ($keys authorized key(s) for $LLM_USER)"
else
	ok "Remote Login is off"
fi

step "Power"
if is_laptop; then
	pmset -c sleep 0
	ok "never sleeps on mains power with the lid open"
	if [ "$LLM_DISABLE_SLEEP" = yes ]; then
		pmset -a disablesleep 1
		ok "disablesleep 1: keeps serving with the lid shut, on battery too (README, step 6)"
		# Never sleeping on battery, it would run flat and lose what is in memory.
		render llm-battery-watchdog.sh "$LLM_SBIN/llm-battery-watchdog.sh" 755 root:wheel
		render com.llmserver.batterywatchdog.plist "$P_WATCHDOG" 644 root:wheel
		start_job system "$L_WATCHDOG" "$P_WATCHDOG" || die "battery watchdog did not start"
		ok "battery watchdog: clean shutdown at ${LLM_BATTERY_SHUTDOWN_PCT}% on battery"
	else
		pmset -a disablesleep 0
		stop_job "system/$L_WATCHDOG" || :
		rm -f "$P_WATCHDOG" "$LLM_SBIN/llm-battery-watchdog.sh"
		ok "closing the lid sleeps the Mac, and the server with it"
	fi
else
	pmset -a sleep 0
	ok "never sleeps"
fi

step "Screen Sharing: tailnet only"
# Installed whether or not Screen Sharing is on, so turning it on later is safe.
render pf-screensharing.conf "$LLM_ETC/pf-screensharing.conf" 644 root:wheel
render com.llmserver.pf.plist "$P_PF" 644 root:wheel
# A one-shot job: restarting it reloads the rules.
start_job system "$L_PF" "$P_PF" || die "the pf job did not start"
n=0
until pf_loaded; do
	n=$((n + 1))
	if [ $n -ge 10 ]; then
		tail -5 "$LLM_LOGS/pf.err.log" 2>/dev/null | sed 's/^/        pf: /'
		die "the firewall rules did not load. Screen Sharing, if on, is reachable from the local network. Turn it off (System Settings > General > Sharing) until this passes."
	fi
	sleep 1
done
if lsof -nP -iTCP:5900 -sTCP:LISTEN >/dev/null 2>&1; then
	ok "Screen Sharing is on, reachable from the tailnet only"
else
	ok "rules loaded; Screen Sharing is off (README, step 6, to turn it on)"
fi

step "In the Tailscale admin console (cannot be checked from here)"
info "- the policy from config/tailscale-policy.hujson is applied"
info "- Device approval is on"

printf '\nNext:\n    sudo sh scripts/verify.sh\n'
