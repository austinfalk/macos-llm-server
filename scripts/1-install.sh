#!/bin/sh
# README step 3: install the software. Run as your normal user -- Homebrew
# refuses root.
#
#     sh scripts/1-install.sh
set -eu
LLM_REPO=$(cd "$(dirname "$0")/.." && pwd)
# shellcheck source=scripts/lib.sh
. "$LLM_REPO/scripts/lib.sh"
need_user
check_user

step "This machine"
# hw.optional.arm64, not uname: a shell under Rosetta reports x86_64.
[ "$(sysctl -n hw.optional.arm64 2>/dev/null)" = 1 ] || die "this guide needs Apple Silicon: Splash runs on its GPU and Neural Engine"
[ -n "$SPLASH_VARIANT" ] || die "this is ${CPU_BRAND:-a chip with no name}: Splash needs Apple Silicon, an M1 or later"
os=$(sw_vers -productVersion)
major=${os%%.*}; minor=$(printf '%s' "$os" | cut -d. -f2)
[ "$major" -gt 26 ] || { [ "$major" -eq 26 ] && [ "${minor:-0}" -ge 4 ]; } || die "Splash needs macOS 26.4 or later; this Mac runs $os"
command -v brew >/dev/null 2>&1 || die "Homebrew is not installed: https://brew.sh"
ok "$CPU_BRAND (Splash variant: $SPLASH_VARIANT), macOS $(sw_vers -productVersion), $(ram_gib) GiB unified memory, $(is_laptop && echo laptop || echo desktop)"

step "Conflicts"
# This setup runs Homebrew's tailscaled. Tailscale documents that its own app
# variants conflict with each other; running an app beside tailscaled is not
# something this guide has tested.
if [ -d /Applications/Tailscale.app ]; then
	warn "the Tailscale app is installed. This setup runs Homebrew's tailscaled"
	warn "instead; running both is untested. Quit the app and remove it before scripts/2-tailscale.sh."
fi
ok "checked"

step "Packages"
if brew list --formula tailscale >/dev/null 2>&1; then
	ok "$(brew list --versions tailscale)"
else
	brew install tailscale
	ok "$(brew list --versions tailscale) installed"
fi

if [ "$("$SPLASH_BIN" --version 2>/dev/null)" = "Splash $SPLASH_VERSION" ]; then
	ok "Splash $SPLASH_VERSION ($SPLASH_BIN)"
else
	case $SPLASH_VARIANT in
		port)
			# The port ships as a release archive and an installer that checks
			# the archive's SHA-256.
			tmp=$(mktemp -d)
			trap 'rm -rf "$tmp"' EXIT
			curl -fsSL "$SPLASH_INSTALLER_URL" -o "$tmp/install-m1.sh" || die "could not download $SPLASH_INSTALLER_URL"
			got=$(shasum -a 256 "$tmp/install-m1.sh" | awk '{print $1}')
			[ "$got" = "$SPLASH_INSTALLER_SHA256" ] || die "install-m1.sh has SHA-256 $got, not the pinned $SPLASH_INSTALLER_SHA256"
			SPLASH_M1_VERSION=$SPLASH_VERSION SPLASH_BIN_DIR=$(dirname "$SPLASH_BIN") sh "$tmp/install-m1.sh" >/dev/null \
				|| die "the Splash installer failed"
			;;
		upstream)
			install_upstream_splash
			;;
	esac
	[ "$("$SPLASH_BIN" --version 2>/dev/null)" = "Splash $SPLASH_VERSION" ] || die "$SPLASH_BIN does not run Splash $SPLASH_VERSION after installing"
	ok "Splash $SPLASH_VERSION installed ($SPLASH_BIN)"
fi

step "Hugging Face"
# Models download from Hugging Face. Anonymous downloads work, with lower rate
# limits; a read-only token in the file `hf auth login` writes lifts them.
if [ -s "$LLM_HOME/.cache/huggingface/token" ]; then
	ok "token present (~/.cache/huggingface/token)"
else
	info "No Hugging Face token: downloads run anonymously, which works but is"
	info "rate-limited. Optional: README, step 3."
fi

step "Backups"
# Models are large, re-downloadable, and churn -- keep them out of Time Machine.
mkdir -p "$LLM_HOME/.cache/huggingface/hub"
tmutil addexclusion "$LLM_HOME/.cache/huggingface/hub" 2>/dev/null || true
if tmutil isexcluded "$LLM_HOME/.cache/huggingface/hub" 2>/dev/null | grep -q '\[Excluded\]'; then
	ok "$LLM_HOME/.cache/huggingface/hub excluded from Time Machine"
else
	warn "could not exclude $LLM_HOME/.cache/huggingface/hub from Time Machine (harmless)"
fi

printf '\nNext: apply the tailnet policy (README step 2), then\n    sudo sh scripts/2-tailscale.sh\n'
