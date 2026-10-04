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
# The Homebrew formula's tailscaled is a system LaunchDaemon, so the tailnet is
# up at boot before anyone logs in: Screen Sharing at the login window, and SSH,
# work over it after a restart.
if [ -z "$(backend)" ]; then
	"$BREW_PREFIX/bin/brew" services start tailscale
	n=0
	while [ -z "$(backend)" ] && [ $n -lt 30 ]; do sleep 1; n=$((n + 1)); done
	[ -n "$(backend)" ] || die "tailscaled did not start. Check: sudo brew services info tailscale"
fi
ok "tailscaled answering (state: $(backend))"

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
