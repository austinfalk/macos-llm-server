#!/bin/sh
# Build a candidate mlx-serve beside the live one: the pinned tag, this
# repo's two patches, then each DIFF given, in order.
#
#   sh bench/build.sh NAME [DIFF...]     # -> ~/.mlx-serve/builds/dev-NAME/mlx-serve
#   sh bench/build.sh --mlx NAME DIFF... # a DIFF changes MLX (lib/mlx-src): rebuild MLX too
#
# Point a config's "bin" at the result. A DIFF is a git diff against the
# patched tree (paths a/src/...). The build runs in its own source tree,
# ~/.mlx-serve/dev-src, a copy-on-write clone of 1-install.sh's tree, so it
# leaves the live build and its source alone. It loads every core: never run
# it during a window. 1-install.sh must have built the live setup first.
set -eu
LLM_REPO=$(cd "$(dirname "$0")/.." && pwd)
. "$LLM_REPO/scripts/lib.sh"
need_user

mlx=no
if [ "${1:-}" = --mlx ]; then
	mlx=yes
	shift
fi
[ $# -ge 1 ] || die "usage: sh bench/build.sh [--mlx] NAME [DIFF...]"
name=$1
shift
for d in "$@"; do [ -f "$d" ] || die "no such diff: $d"; done
D=$LLM_HOME/.mlx-serve/dev-src
out=$MLX_SERVE_HOME/dev-$name
log=$MLX_SERVE_HOME/dev-$name.log
version=${MLX_SERVE_TAG#v}-dev-$name
[ -x "$MLX_SERVE_BIN" ] || die "build the live setup first: sh scripts/1-install.sh"

if [ ! -d "$D/.git" ]; then
	info "cloning $MLX_SERVE_SRC to $D (copy-on-write: only its build outputs take space, about 5 GB)"
	cp -Rc "$MLX_SERVE_SRC" "$D" || die "could not clone $MLX_SERVE_SRC"
fi
{ git -C "$D" checkout -q -f "$MLX_SERVE_COMMIT" && git -C "$D" clean -q -f -d; } || die "could not reset $D to $MLX_SERVE_TAG"
git -C "$D" submodule foreach -q 'git checkout -q -f . && git clean -q -f -d' || die "could not reset the submodules in $D"
git -C "$D" apply "$PATCH" || die "patches/inkling2-m1.patch does not apply"
git -C "$D" apply "$SPEED_PATCH" || die "patches/inkling2-m1-speed.patch does not apply"
for d in "$@"; do
	git -C "$D" apply "$(cd "$(dirname "$d")" && pwd)/$(basename "$d")" || die "$d does not apply on top of the patches"
done

: >"$log"
info "building $version: a few minutes, more with --mlx (log: $log)"
if [ $mlx = yes ]; then
	rm -f "$D/lib/mlx/.version"
	(cd "$D" && bash scripts/build-mlx.sh) >>"$log" 2>&1 || die "building MLX failed: see $log"
fi
(cd "$D" && PATH="$D/.zig-toolchain:$PATH" zig build -Doptimize=ReleaseFast -Dstrip \
	-Dversion="$version" -Dgit-sha="$MLX_SERVE_COMMIT") >>"$log" 2>&1 || die "building mlx-serve failed: see $log"
rm -rf "$out"
lay_out_build "$D" "$out" "$version" "$log"
ok "built $out/mlx-serve"
echo "In a config: \"bin\": \"~/.mlx-serve/builds/dev-$name/mlx-serve\""
