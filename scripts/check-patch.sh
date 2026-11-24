#!/bin/sh
# Check that patches/inkling2-m1.patch applies to the mlx-serve commit
# scripts/pins.sh pins, as scripts/1-install.sh applies it. Downloads that one
# commit's tree, without submodules, into a temporary folder.
#
#     sh scripts/check-patch.sh
#
# POSIX sh, and it sources only pins.sh, so it also runs on Linux.
set -eu
cd "$(dirname "$0")/.."
# shellcheck source=scripts/pins.sh
. scripts/pins.sh
tmp=$(mktemp -d)
trap 'rm -rf "$tmp"' EXIT
git -C "$tmp" init -q
git -C "$tmp" fetch -q --depth 1 "$MLX_SERVE_GIT" "$MLX_SERVE_COMMIT"
git -C "$tmp" checkout -q FETCH_HEAD
git -C "$tmp" apply --check "$PWD/patches/inkling2-m1.patch"
printf 'ok   patches/inkling2-m1.patch applies to %s (%s)\n' "$MLX_SERVE_TAG" "$MLX_SERVE_COMMIT"
