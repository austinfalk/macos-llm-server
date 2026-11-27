# shellcheck shell=sh disable=SC2034
#
# Everything this setup downloads, pinned. lib.sh sources this file after it
# sets LLM_HOME. To move a pin, change it here and run scripts/1-install.sh,
# which rebuilds or reconverts only what the change touches.

# --- mlx-serve ----------------------------------------------------------------
# Built from upstream's source at this tag, the way upstream's release workflow
# builds it (.github/workflows/release.yml), with patches/inkling2-m1.patch
# and then patches/inkling2-m1-speed.patch applied to src/. The commit is checked after the fetch, so a moved tag fails
# the install instead of building something else.
MLX_SERVE_GIT=https://github.com/ddalcu/mlx-serve.git
MLX_SERVE_TAG=v26.11.4-pre-release.1
MLX_SERVE_COMMIT=2fe9be834a601c70ef1a597563026340f0e722fe
# patches/inkling2-m1.patch is namp/mlx-serve-inkling2-m1's change to src/,
# `git diff 83865a4a ab16dcb3 -- src`: its base commit carries the same src/
# tree as this tag. patches/inkling2-m1-speed.patch is this repo's change on
# top of it (docs/findings.md, "This repo's patch").

# Zig, which upstream's scripts/fetch-zig.sh downloads without a checksum.
# 1-install.sh downloads and checks it first, so fetch-zig.sh finds it staged.
ZIG_VERSION=0.17.0
ZIG_SHA256=b607e9b9234790a008116ae5bdb71c6243b84b9fb42a53a9e70fde41c06c536a
# llama.cpp's prebuilt libllama, which upstream's scripts/fetch-llama.sh
# downloads (tag b12110) and thins without a checksum. This is the SHA-256 of
# the library it stages, checked after it runs.
LLAMA_DYLIB_SHA256=01e5a4a3746bb25f1a817c1fa609448a3171f6cfb5f56a9122407d4c2c920c88

# --- the model ----------------------------------------------------------------
# Thinking Machines' Inkling 2 Mini, the release itself (NVFP4 and MXFP8
# experts, the rest BF16). config/model-source.sha256 lists the files
# 1-install.sh downloads at this revision, with their sizes and checksums.
LLM_SOURCE_REPO=thinkingmachines/Inkling-2-Mini
LLM_SOURCE_REVISION=c9d028302cd0f035fdf8e7e91f089a4ce94d2195

# AtomicChat's uncensoring of it: a rank-1 LoRA, one unit direction a layer,
# which scripts/merge-uncensoring.py applies to the converted pack's weights
# (docs/findings.md, "The pack"). Its one file is in config/adapter-source.sha256.
LLM_ADAPTER_REPO=AtomicChat/Inkling-2-Mini-Uncensored-GGUF
LLM_ADAPTER_REVISION=c311009ce2b34e35c07a0f374b7eeff24a8d95c6

# Inco's DFlash 2 draft model for Inkling 2 Mini, which namp's patch drafts with
# on M1 and M2. config/draft-source.sha256 lists its files with their checksums.
LLM_DRAFT_REPO=incoai/Inkling-2-Mini-DFlash2
LLM_DRAFT_REVISION=4f9088ea66c21f2b99ed657d1941c306b03e84d2
