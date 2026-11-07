#!/bin/sh
# README step 4: run Tailscale as a system daemon and join the tailnet as a tagged
# server. Apply config/tailscale-policy.hujson in the admin console first.
#
#     sudo sh scripts/2-tailscale.sh
set -eu
LLM_REPO=$(cd "$(dirname "$0")/.." && pwd)
# shellcheck source=scripts/lib.sh
. "$LLM_REPO/scripts/lib.sh"
need_root
check_user

backend() { tailscale status --json 2>/dev/null | plutil -extract BackendState raw -o - - 2>/dev/null; }

step "Tailscale daemon"
# tailscaled runs as root, at boot once FileVault has unlocked the disk, so the
# tailnet is up at the login window: Screen Sharing and SSH work over it after
# a restart. It runs from a root-owned copy, not Homebrew's prefix, which the
# user owns: there, anything running as the user could swap the binary and
# become root at its next start.
[ -x "$BREW_PREFIX/bin/tailscaled" ] || die "no tailscaled in $BREW_PREFIX/bin: run scripts/1-install.sh first"
[ "$BREW_PREFIX" != /usr/local ] || die "Homebrew is in /usr/local, where it would own $TAILSCALED. Use Homebrew in /opt/homebrew."
mkdir -p "$(dirname "$TAILSCALED")"
root_only /usr/local "$(dirname "$TAILSCALED")" || die "/usr/local or $(dirname "$TAILSCALED") is not root's alone, so another account could replace tailscaled. Fix it with:
    sudo chown root:wheel /usr/local $(dirname "$TAILSCALED") && sudo chmod go-w /usr/local $(dirname "$TAILSCALED")"
if [ -f "$P_BREW_TAILSCALED" ] || job_loaded "system/$L_BREW_TAILSCALED" \
	|| ! job_loaded "system/$L_TAILSCALED" \
	|| [ -L "$TAILSCALED" ] || ! cmp -s "$BREW_PREFIX/bin/tailscaled" "$TAILSCALED" \
	|| ! cmp -s "$LLM_REPO/config/$L_TAILSCALED.plist" "$P_TAILSCALED"; then
	# The tailnet is down until the new daemon answers. Ignore the hangup of an
	# SSH session that drops with it, so the script finishes the switch.
	trap '' HUP
	SWITCHING=yes
	trap '[ "${SWITCHING:-}" != yes ] || printf "\nThe tailnet is down: tailscaled did not come back. Re-run this script, or bring back the Homebrew daemon:\n    sudo brew services start tailscale\n" >&2' EXIT
	if [ -f "$P_BREW_TAILSCALED" ] || job_loaded "system/$L_BREW_TAILSCALED"; then
		stop_job "system/$L_BREW_TAILSCALED" || :
		rm -f "$P_BREW_TAILSCALED"
		# `sudo brew services` left these root-owned, which blocks brew cleanup.
		chown -R -h "$LLM_USER:admin" "$BREW_PREFIX/Cellar/tailscale" "$BREW_PREFIX/opt/tailscale" "$BREW_PREFIX/var/log/tailscaled.log" 2>/dev/null || :
	fi
	stop_job "system/$L_TAILSCALED" || :
	n=0
	while pgrep -x tailscaled >/dev/null && [ $n -lt 40 ]; do sleep 0.5; n=$((n + 1)); done
	! pgrep -x tailscaled >/dev/null || die "the old tailscaled did not stop"
	install -S -o root -g wheel -m 755 "$BREW_PREFIX/bin/tailscaled" "$TAILSCALED" || die "could not copy tailscaled to $TAILSCALED"
	render "$L_TAILSCALED.plist" "$P_TAILSCALED" 644 root:wheel
	start_job system "$L_TAILSCALED" "$P_TAILSCALED" || die "tailscaled did not start"
fi
n=0
until case $(backend) in Running | NeedsLogin | NeedsMachineAuth | Stopped) true ;; *) false ;; esac; do
	n=$((n + 1))
	[ $n -lt 30 ] || die "tailscaled did not answer. Check: sudo launchctl print system/$L_TAILSCALED"
	sleep 1
done
[ "$(tailscaled_paths)" = "$TAILSCALED" ] || die "tailscaled runs from $(tailscaled_paths | tr '\n' ' '), not only $TAILSCALED"
SWITCHING=no
ok "tailscaled runs from $TAILSCALED and restarts if it exits (state: $(backend))"

step "Tailnet membership"
if [ "$(backend)" != Running ]; then
	info "Logging in. Open the URL it prints. If device approval is on, approve"
	info "the machine in the admin console as well."
	tailscale up --advertise-tags="$LLM_TAG" --operator="$LLM_USER"
fi
# --operator lets $LLM_USER run `tailscale serve` and friends without sudo.
tailscale set --operator="$LLM_USER"
tagged=no
count=$(tailscale status --json | plutil -extract Self.Tags raw -o - - 2>/dev/null) || count=0
i=0
while [ "$i" -lt "$count" ]; do
	[ "$(tailscale status --json | plutil -extract "Self.Tags.$i" raw -o - -)" = "$LLM_TAG" ] && tagged=yes
	i=$((i + 1))
done
if [ $tagged = yes ]; then
	ok "joined as $(endpoint_host), tagged $LLM_TAG (tagged devices do not expire)"
else
	die "joined as $(endpoint_host) but NOT tagged $LLM_TAG, so the tailnet policy will not grant access to it.
Check the policy's tagOwners, then:
    sudo tailscale up --advertise-tags=$LLM_TAG --operator=$LLM_USER --force-reauth"
fi

step "HTTPS certificates"
domain=$(tailscale status --json | plutil -extract CertDomains.0 raw -o - - 2>/dev/null) || domain=
[ -n "$domain" ] || die "HTTPS certificates are not enabled for this tailnet.
Enable MagicDNS and HTTPS Certificates at https://login.tailscale.com/admin/dns, then re-run."
ok "certificates available for $domain"

printf '\nNext, as yourself (not sudo):\n    sh scripts/3-services.sh\n'
