#!/bin/sh
# README step 3: install the software, build mlx-serve, and download and
# convert the model. Run as your normal user -- Homebrew refuses root.
#
#     sh scripts/1-install.sh
#
# Safe to re-run: each part is skipped when it is already in place, and an
# interrupted download resumes.
set -eu
LLM_REPO=$(cd "$(dirname "$0")/.." && pwd)
# shellcheck source=scripts/lib.sh
. "$LLM_REPO/scripts/lib.sh"
need_user
check_user
[ "$(id -un)" = "$LLM_USER" ] || die "run this as $LLM_USER (LLM_USER), who owns the server and its model"

step "This machine"
# hw.optional.arm64, not uname: a shell under Rosetta reports x86_64.
[ "$(sysctl -n hw.optional.arm64 2>/dev/null)" = 1 ] || die "this guide needs Apple Silicon: mlx-serve runs the model on its GPU"
os=$(sw_vers -productVersion)
major=${os%%.*}; minor=$(printf '%s' "$os" | cut -d. -f2)
[ "$major" -gt 26 ] || { [ "$major" -eq 26 ] && [ "${minor:-0}" -ge 2 ]; } || die "mlx-serve needs macOS 26.2 or later; this Mac runs $os"
# The server's settings are sized for, and measured on, 64 GB: the model takes
# about 17 GB and its prefix cache up to 24 GB.
[ "$(ram_gib)" -ge 64 ] || die "this setup needs 64 GB of memory; this Mac has $(ram_gib) GB"
command -v brew >/dev/null 2>&1 || die "Homebrew is not installed: https://brew.sh"
# MLX's Metal kernels are compiled here, which needs Xcode and its Metal
# toolchain, not only the Command Line Tools.
xcrun -sdk macosx metal --version >/dev/null 2>&1 \
	|| die "no Metal compiler: install Xcode 26.2 or later from the App Store, open it once, then run
    xcodebuild -downloadComponent MetalToolchain"
ok "$(sysctl -n machdep.cpu.brand_string 2>/dev/null), macOS $os, $(ram_gib) GiB unified memory, $(is_laptop && echo laptop || echo desktop), Xcode SDK $(xcrun --sdk macosx --show-sdk-version)"

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
# tailscale for the tailnet; cmake and webp from upstream mlx-serve's
# Brewfile, to build it; Python to convert the model.
for f in tailscale cmake webp python@3.12; do
	brew list --formula "$f" >/dev/null 2>&1 || brew install "$f"
	ok "$(brew list --versions "$f")"
done

mkdir -p "$MLX_SERVE_HOME"
# Models and builds are large and can be made again: keep them out of Time Machine.
tmutil addexclusion "$LLM_HOME/.mlx-serve" 2>/dev/null || true

step "mlx-serve"
if [ "$(mlx_serve_version)" = "$MLX_SERVE_BUILD" ]; then
	ok "mlx-serve $MLX_SERVE_BUILD ($MLX_SERVE_BIN)"
else
	info "building $MLX_SERVE_TAG with patches/inkling2-m1.patch and inkling2-m1-speed.patch: about 10 minutes the first time"
	S=$MLX_SERVE_SRC
	if [ ! -d "$S/.git" ]; then
		git -c advice.detachedHead=false clone -q --depth 1 --branch "$MLX_SERVE_TAG" "$MLX_SERVE_GIT" "$S" || die "could not clone $MLX_SERVE_GIT"
	else
		# --force: a tag upstream moved replaces the local one, so the commit
		# check below reports the move instead of the fetch failing.
		git -C "$S" fetch -q --force --depth 1 origin tag "$MLX_SERVE_TAG" || die "could not fetch $MLX_SERVE_TAG"
	fi
	# Back to the tag as committed: drops last build's patch, keeps the build
	# outputs, which git ignores.
	{ git -C "$S" checkout -q -f "$MLX_SERVE_TAG" && git -C "$S" clean -q -f -d; } || die "could not check out $MLX_SERVE_TAG in $S"
	[ "$(git -C "$S" rev-parse HEAD)" = "$MLX_SERVE_COMMIT" ] \
		|| die "$MLX_SERVE_TAG is commit $(git -C "$S" rev-parse HEAD), not the pinned $MLX_SERVE_COMMIT. Upstream moved the tag: read what changed before you bump the pin in scripts/pins.sh"
	git -C "$S" submodule update -q --init --depth 1 --jobs 8 || die "could not fetch mlx-serve's submodules"

	# Zig, checked, where upstream's fetch-zig.sh would stage it.
	if [ "$(cat "$S/.zig-toolchain/.version" 2>/dev/null)" != "$ZIG_VERSION" ]; then
		tmp=$(mktemp -d)
		trap 'rm -rf "$tmp"' EXIT
		curl -fsSL --retry 3 -o "$tmp/zig.tar.xz" "https://ziglang.org/download/$ZIG_VERSION/zig-aarch64-macos-$ZIG_VERSION.tar.xz" \
			|| die "could not download Zig $ZIG_VERSION"
		got=$(shasum -a 256 "$tmp/zig.tar.xz" | awk '{print $1}')
		[ "$got" = "$ZIG_SHA256" ] || die "the Zig $ZIG_VERSION tarball has SHA-256 $got, not the pinned $ZIG_SHA256"
		tar -xf "$tmp/zig.tar.xz" -C "$tmp" || die "could not unpack Zig"
		rm -rf "$S/.zig-toolchain" "$S/.zig-cache"
		mv "$tmp/zig-aarch64-macos-$ZIG_VERSION" "$S/.zig-toolchain"
		echo "$ZIG_VERSION" > "$S/.zig-toolchain/.version"
	fi
	( cd "$S" && bash scripts/build-mlx.sh ) >"$MLX_SERVE_HOME/build.log" 2>&1 \
		|| die "building MLX failed: see $MLX_SERVE_HOME/build.log"
	( cd "$S" && bash scripts/fetch-llama.sh ) >>"$MLX_SERVE_HOME/build.log" 2>&1 \
		|| die "fetching libllama failed: see $MLX_SERVE_HOME/build.log"
	got=$(shasum -a 256 "$S/lib/llama/lib/libllama.dylib" | awk '{print $1}')
	[ "$got" = "$LLAMA_DYLIB_SHA256" ] || die "the staged libllama.dylib has SHA-256 $got, not the pinned $LLAMA_DYLIB_SHA256"
	git -C "$S" apply "$PATCH" || die "patches/inkling2-m1.patch does not apply to $MLX_SERVE_TAG"
	git -C "$S" apply "$SPEED_PATCH" || die "patches/inkling2-m1-speed.patch does not apply on top of patches/inkling2-m1.patch"
	( cd "$S" && PATH="$S/.zig-toolchain:$PATH" zig build -Doptimize=ReleaseFast -Dstrip \
		-Dversion="$MLX_SERVE_BUILD" -Dgit-sha="$MLX_SERVE_COMMIT" ) >>"$MLX_SERVE_HOME/build.log" 2>&1 \
		|| die "building mlx-serve failed: see $MLX_SERVE_HOME/build.log"

	# Laid out and signed as upstream's release workflow packages the command
	# line build: the binary, with its libraries in lib/ beside it.
	rm -rf "$MLX_SERVE_HOME"/.staging.*
	out=$MLX_SERVE_HOME/.staging.$$
	trap 'rm -rf "${tmp:-}" "$out"' EXIT
	b=$out/mlx-serve
	webp=$(brew --prefix webp)/lib
	# Each install_name_tool change voids a signature, with a warning on
	# stderr; everything is signed again after.
	{
		mkdir -p "$out/lib" &&
		cp "$S/zig-out/bin/mlx-serve" "$S/LICENSE" "$S/LICENSE-APACHE-2.0" "$S/NOTICE" "$out/" &&
		cp "$S"/lib/mlx/lib/*.dylib "$S/lib/mlx/lib/mlx.metallib" "$S/lib/llama/lib/libllama.dylib" \
			"$webp/libwebp.dylib" "$webp/libsharpyuv.dylib" "$out/lib/" &&
		install_name_tool -change @rpath/libmlxc.dylib @executable_path/lib/libmlxc.dylib \
			-change @rpath/libmlx.dylib @executable_path/lib/libmlx.dylib \
			-change @rpath/libllama.dylib @executable_path/lib/libllama.dylib \
			-change "$(otool -L "$b" | awk '/libwebp/ {print $1}')" @executable_path/lib/libwebp.dylib "$b" &&
		install_name_tool -change @rpath/libmlx.dylib @loader_path/libmlx.dylib "$out/lib/libmlxc.dylib" &&
		install_name_tool -change "$(otool -L "$out/lib/libwebp.dylib" | awk '/libsharpyuv/ {print $1}')" \
			@loader_path/libsharpyuv.dylib "$out/lib/libwebp.dylib"
	} 2>>"$MLX_SERVE_HOME/build.log" || die "could not lay out the build: see $MLX_SERVE_HOME/build.log"
	# The build's own search paths point back into the source tree, which from
	# here resolve outside the build folder. Keep only the folder's lib/.
	otool -l "$b" | awk '$1 == "path" {print $2}' | grep -v -x '@executable_path/lib' | while read -r r; do
		install_name_tool -delete_rpath "$r" "$b" 2>/dev/null || die "could not remove the search path $r"
	done
	install_name_tool -add_rpath @loader_path "$out/lib/libmlx.dylib" 2>/dev/null || :
	for l in "$out"/lib/*.dylib; do codesign --force --sign - "$l" 2>/dev/null || die "could not sign $l"; done
	codesign --force --sign - --entitlements "$S/app/mlx-serve.entitlements" "$b" 2>/dev/null || die "could not sign mlx-serve"
	stray=$(otool -L "$b" | awk 'NR > 1 {print $1}' | grep -v -E '^(/usr/lib/|/System/|@executable_path/lib/)') || :
	[ -z "$stray" ] || die "the build links a library it does not carry: $stray"
	[ "$("$b" --version 2>/dev/null | awk 'NR == 1 {print $2}')" = "$MLX_SERVE_BUILD" ] || die "the staged mlx-serve does not report $MLX_SERVE_BUILD"
	rm -rf "${MLX_SERVE_HOME:?}/$MLX_SERVE_BUILD"
	mv "$out" "$MLX_SERVE_HOME/$MLX_SERVE_BUILD"
	trap - EXIT
	ok "mlx-serve $MLX_SERVE_BUILD built ($MLX_SERVE_BIN)"
fi

step "Model download"
# The release format, at the pinned revision. A Hugging Face token, if there is
# one, lifts the anonymous rate limit; it reaches curl on stdin.
token=$LLM_HOME/.cache/huggingface/token
base=https://huggingface.co/$LLM_SOURCE_REPO/resolve/$LLM_SOURCE_REVISION
fetch() {  # PATH [RANGE]
	if [ -s "$token" ]; then
		curl_hdr "Authorization: Bearer $(head -1 "$token")" -fsSL --retry 5 ${2:+-r "$2"} "$base/$1"
	else
		curl -fsSL --retry 5 ${2:+-r "$2"} "$base/$1"
	fi
}
size_of() { stat -f %z "$1" 2>/dev/null || echo 0; }
mkdir -p "$LLM_SOURCE_DIR"
converted=$LLM_MODEL_DIR/.converted-$LLM_MODEL_PIN
stamp=$LLM_SOURCE_DIR/.verified-$LLM_SOURCE_REVISION
all_there() {
	grep -v '^#' "$LLM_REPO/config/model-source.sha256" | while read -r sum size f; do
		[ "$(size_of "$LLM_SOURCE_DIR/$f")" = "$size" ] || return 1
	done
}
if [ -f "$converted" ]; then
	ok "not needed: the model is converted. The release can be deleted; an mlx-serve update downloads it again to convert"
elif [ -f "$stamp" ] && all_there; then
	ok "$LLM_SOURCE_REPO at ${LLM_SOURCE_REVISION%"${LLM_SOURCE_REVISION#????????}"}, checked before"
else
	info "$LLM_SOURCE_REPO: about 20 GB"
	grep -v '^#' "$LLM_REPO/config/model-source.sha256" | while read -r sum size f; do
		dest=$LLM_SOURCE_DIR/$f
		[ "$(size_of "$dest")" = "$size" ] && continue
		if [ "$size" -lt 104857600 ]; then
			{ fetch "$f" > "$dest.part" && mv "$dest.part" "$dest"; } || die "could not download $f. Run this script again to resume"
			continue
		fi
		# A big file comes down as 8 ranges at once, each kept once it is whole,
		# so a rerun fetches only the ranges it is missing.
		part=$(( (size + 7) / 8 )); pids=
		trap 'kill $pids 2>/dev/null' INT TERM
		i=0
		while [ $i -lt 8 ]; do
			a=$((i * part)); z=$((a + part - 1)); [ $z -lt "$size" ] || z=$((size - 1))
			if [ "$(size_of "$dest.part$i")" != $((z - a + 1)) ]; then
				fetch "$f" "$a-$z" > "$dest.part$i" &
				pids="$pids $!"
			fi
			i=$((i + 1))
		done
		wait
		trap - INT TERM
		# Every range whole before they are joined; a short one is fetched
		# again on the next run, and the others are kept.
		set --
		i=0
		while [ $i -lt 8 ]; do
			a=$((i * part)); z=$((a + part - 1)); [ $z -lt "$size" ] || z=$((size - 1))
			if [ "$(size_of "$dest.part$i")" != $((z - a + 1)) ]; then
				rm -f "$dest.part$i"
				die "part $i of $f did not download whole. Run this script again to resume"
			fi
			set -- "$@" "$dest.part$i"
			i=$((i + 1))
		done
		cat "$@" > "$dest" && rm -f "$@"
		[ "$(size_of "$dest")" = "$size" ] || { rm -f "$dest"; die "$f did not join whole. Run this script again"; }
	done
	info "checking SHA-256 of every file"
	grep -v '^#' "$LLM_REPO/config/model-source.sha256" | while read -r sum size f; do
		got=$(shasum -a 256 "$LLM_SOURCE_DIR/$f" | awk '{print $1}')
		[ "$got" = "$sum" ] || { rm -f "$LLM_SOURCE_DIR/$f"; die "$f has SHA-256 $got, not the pinned $sum. Deleted it: run this script again"; }
	done
	touch "$stamp"
	ok "$LLM_SOURCE_REPO downloaded and checked"
fi

step "Draft model"
# Inco's DFlash 2 drafter, as released, at the pinned revision: two files.
base=https://huggingface.co/$LLM_DRAFT_REPO/resolve/$LLM_DRAFT_REVISION
mkdir -p "$LLM_DRAFT_DIR"
dstamp=$LLM_DRAFT_DIR/.verified-$LLM_DRAFT_REVISION
if [ -f "$dstamp" ]; then
	ok "$LLM_DRAFT_REPO at ${LLM_DRAFT_REVISION%"${LLM_DRAFT_REVISION#????????}"}, checked before"
else
	info "$LLM_DRAFT_REPO: about 1 GB"
	grep -v '^#' "$LLM_REPO/config/draft-source.sha256" | while read -r sum size f; do
		dest=$LLM_DRAFT_DIR/$f
		if [ "$(size_of "$dest")" != "$size" ]; then
			{ fetch "$f" > "$dest.part" && mv "$dest.part" "$dest"; } || die "could not download $f of $LLM_DRAFT_REPO. Run this script again"
		fi
		got=$(shasum -a 256 "$dest" | awk '{print $1}')
		[ "$got" = "$sum" ] || { rm -f "$dest"; die "$f of $LLM_DRAFT_REPO has SHA-256 $got, not the pinned $sum. Deleted it: run this script again"; }
	done
	touch "$dstamp"
	ok "$LLM_DRAFT_REPO downloaded and checked"
fi

step "Model conversion"
# mlx-serve reads MLX packs. Upstream's own converter writes one from the
# release: the routed experts keep the release's bytes; the attention goes
# 4-bit, the embedding and head 6-bit (docs/findings.md, "The pack").
if [ -f "$converted" ]; then
	ok "$LLM_MODEL_ID ($LLM_MODEL_DIR)"
else
	venv=$MLX_SERVE_HOME/venv
	if [ ! -x "$venv/bin/python" ]; then
		"$(brew --prefix python@3.12)/bin/python3.12" -m venv "$venv" || die "could not make a Python environment at $venv"
	fi
	"$venv/bin/pip" install -q --disable-pip-version-check --require-hashes -r "$LLM_REPO/config/convert-requirements.txt" \
		|| die "could not install the converter's dependencies"
	tmpdir=$LLM_MODEL_DIR.converting
	rm -rf "$tmpdir"
	"$venv/bin/python" -I "$MLX_SERVE_SRC/tests/convert_inkling2.py" --src "$LLM_SOURCE_DIR" --dst "$tmpdir" \
		--bits 4 --embed-bits 6 --head-bits 6 >"$MLX_SERVE_HOME/convert.log" 2>&1 \
		|| die "the conversion failed: see $MLX_SERVE_HOME/convert.log"
	grep -v '^#' "$LLM_REPO/config/model-pack.sha256" | while read -r sum f; do
		got=$(shasum -a 256 "$tmpdir/$f" | awk '{print $1}')
		[ "$got" = "$sum" ] || die "the converted $f has SHA-256 $got, not the pinned $sum: see $MLX_SERVE_HOME/convert.log"
	done
	rm -rf "$LLM_MODEL_DIR"
	mv "$tmpdir" "$LLM_MODEL_DIR"
	touch "$converted"
	ok "$LLM_MODEL_ID converted ($LLM_MODEL_DIR)"
fi

printf '\nNext: apply the tailnet policy (README step 2), then\n    sudo sh scripts/2-tailscale.sh\n'
