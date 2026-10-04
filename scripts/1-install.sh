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
[ "$(sysctl -n hw.optional.arm64 2>/dev/null)" = 1 ] || die "this guide needs Apple Silicon: TensorFold runs on MLX, Apple's framework for its unified-memory GPU"
# TensorFold's Homebrew formula needs macOS 14 (Sonoma).
[ "$(sw_vers -productVersion | cut -d. -f1)" -ge 14 ] || die "this guide needs macOS 14 or later"
command -v brew >/dev/null 2>&1 || die "Homebrew is not installed: https://brew.sh"
ok "macOS $(sw_vers -productVersion), $(ram_gib) GiB unified memory, $(is_laptop && echo laptop || echo desktop)"

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
# TensorFold's own tap is its documented Homebrew install; the formula builds a
# private Python environment with the MLX versions TensorFold pins.
for f in tailscale ashhart/tensorfold/tensorfold; do
	if brew list --formula "$f" >/dev/null 2>&1; then
		ok "$(brew list --versions "$f")"
	else
		brew install "$f"
		ok "$(brew list --versions "$f") installed"
	fi
done

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
