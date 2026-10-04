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

step "Automatic login"
# Off. The model server starts when you log in; after a restart, log in at the
# login window over Screen Sharing (README, step 6). Auto-login would bring it
# back unattended, but leaves the account password in /etc/kcpassword,
# obfuscated with a published key -- Apple advises against it for
# administrator accounts.
if defaults read /Library/Preferences/com.apple.loginwindow autoLoginUser >/dev/null 2>&1; then
	defaults delete /Library/Preferences/com.apple.loginwindow autoLoginUser
	ok "turned off"
else
	ok "off"
fi
if [ -e /etc/kcpassword ]; then
	rm -f /etc/kcpassword
	ok "removed /etc/kcpassword"
fi

step "FileVault"
case $(fdesetup status 2>/dev/null) in
	*"is On"*)
		info "On. After an unplanned restart the Mac waits at FileVault's unlock"
		info "screen, with no network: someone has to type the password at the"
		info "machine. For a planned restart, 'sudo fdesetup authrestart' unlocks"
		info "the next boot once." ;;
	*)
		info "Off. After any restart the Mac reaches the login window on its own,"
		info "where you can log in over Screen Sharing; anyone holding the machine"
		info "can read the disk. See README, step 6." ;;
esac

step "SSH"
DROPIN=/etc/ssh/sshd_config.d/200-llm-server.conf
# The backup lives outside sshd_config.d, which sshd_config includes whole.
PREVIOUS=/etc/ssh/200-llm-server.conf.previous
if nc -z -G 2 127.0.0.1 22 >/dev/null 2>&1; then
	keys=$(grep -cE '^(ssh-|ecdsa-|sk-)' "$LLM_HOME/.ssh/authorized_keys" 2>/dev/null) || keys=0
	[ "$keys" -gt 0 ] || die "Remote Login is on, but $LLM_USER has no key in ~/.ssh/authorized_keys.
Disabling passwords now would lock you out. Add a public key there first, then re-run."
	if [ "$LLM_SSH_TAILNET_ONLY" = yes ]; then tmpl=sshd-tailnet-only.conf; else tmpl=sshd-key-only.conf; fi
	[ -f "$DROPIN" ] && cp -p "$DROPIN" "$PREVIOUS"
	render "$tmpl" "$DROPIN" 644 root:wheel
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
		v=$(/usr/sbin/sshd -T 2>/dev/null | awk -v o="$opt" '$1 == o {print $2}')
		[ -n "$v" ] || die "could not read sshd's effective settings (sshd -T)"
		[ "$v" = no ] || die "sshd still allows $opt: another setting in /etc/ssh overrides $DROPIN"
	done
	if [ "$LLM_SSH_TAILNET_ONLY" = yes ]; then
		ok "keys only, and only from the tailnet ($keys authorized key(s) for $LLM_USER)"
	else
		ok "keys only, from any network ($keys authorized key(s) for $LLM_USER)"
	fi
else
	ok "Remote Login is off -- nothing to harden"
fi

step "Power"
if is_laptop; then
	pmset -c sleep 0 disksleep 0 powernap 0 standby 0 womp 1
	# If it ever does sleep on battery, write memory to disk so a dead battery
	# does not lose it.
	pmset -b hibernatemode 3
	ok "on mains: never sleeps. On battery: hibernatemode 3"
	if [ "$LLM_DISABLE_SLEEP" = yes ]; then
		pmset -a disablesleep 1
		ok "disablesleep 1: keeps serving with the lid shut (system-wide; see README)"
	else
		pmset -a disablesleep 0
		ok "disablesleep 0: closing the lid sleeps the machine"
	fi
	render llm-battery-watchdog.sh "$LLM_SBIN/llm-battery-watchdog.sh" 755 root:wheel
	render com.llmserver.batterywatchdog.plist "$P_WATCHDOG" 644 root:wheel
	if start_job system "$L_WATCHDOG" "$P_WATCHDOG"; then
		ok "battery watchdog: clean shutdown at ${LLM_BATTERY_SHUTDOWN_PCT}% on battery"
	else
		die "battery watchdog did not start"
	fi
else
	pmset -a sleep 0 disksleep 0 powernap 0 womp 1
	ok "never sleeps"
	if pmset -g cap | grep -qw autorestart; then
		pmset -a autorestart 1
		ok "restarts by itself after a power failure"
	fi
fi

step "Screen Sharing, Kerberos and Sunshine: tailnet only"
# Screen Sharing, the Kerberos KDC its sign-in can use, and Sunshine listen on
# every network and cannot be told otherwise, so pf drops their ports unless the
# connection comes from the tailnet. Installed whether or not any of them is
# on, so turning one on later is safe.
render pf-screensharing.conf "$LLM_ETC/pf-screensharing.conf" 644 root:wheel
render com.llmserver.pf.plist "$P_PF" 644 root:wheel
# A one-shot job: restarting it reloads the rules.
start_job system "$L_PF" "$P_PF" || die "the pf job did not start"
n=0
until pfctl -a "$PF_ANCHOR" -sr 2>/dev/null | grep -q 'block drop in quick proto tcp.*port = 88$' \
	&& pfctl -a "$PF_ANCHOR" -sr 2>/dev/null | grep -q 'block drop in quick proto tcp.*port = 5900' \
	&& pfctl -a "$PF_ANCHOR" -sr 2>/dev/null | grep -q 'block drop in quick proto tcp.*port = 47989'; do
	n=$((n + 1))
	if [ $n -ge 10 ]; then
		tail -5 "$LLM_LOGS/pf.err.log" 2>/dev/null | sed 's/^/        pf: /'
		die "the firewall rules did not load into pf anchor $PF_ANCHOR. Screen Sharing, if on, is reachable from the local network. Turn it off (System Settings > General > Sharing) until this passes."
	fi
	sleep 1
done
pfctl -s info 2>/dev/null | grep -q 'Status: Enabled' || die "pf is not enabled, so the Screen Sharing rules do nothing"
if lsof -nP -iTCP:5900 -sTCP:LISTEN >/dev/null 2>&1; then
	ok "Screen Sharing is on, reachable from the tailnet only"
else
	ok "rules loaded; Screen Sharing is off (README, step 6, to turn it on)"
fi
if lsof -nP -iTCP:47989 -sTCP:LISTEN >/dev/null 2>&1; then
	ok "Sunshine is on, reachable from the tailnet only"
fi

step "AirPlay Receiver"
if lsof -nP -iTCP:7000 -sTCP:LISTEN >/dev/null 2>&1 || lsof -nP -iTCP:5000 -sTCP:LISTEN >/dev/null 2>&1; then
	warn "listening on ports 5000 and 7000 on every network. If you do not use it:"
	warn "System Settings > General > AirDrop & Handoff > AirPlay Receiver: off"
else
	ok "off"
fi

step "In the Tailscale admin console (cannot be checked from here)"
info "- the policy from config/tailscale-policy.hujson is applied"
info "- Device approval is on"

printf '\nNext:\n    sudo sh scripts/verify.sh\n'
