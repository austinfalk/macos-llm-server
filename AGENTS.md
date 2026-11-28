# Working in this repo

A guide and scripts for running a private model server on an Apple Silicon Mac
with 64 GB: [mlx-serve](https://github.com/ddalcu/mlx-serve) serving
Inkling 2 Mini Uncensored, behind `tailscale serve`. mlx-serve is built from
upstream's source with two patches for M1 and M2 GPUs.

## The goal

Inkling 2 Mini, in MLX weights, decoding on this M1 Max (64 GB) as fast as its
memory bandwidth and KV cache allow, with speculative decoding on. Every
choice serves that goal and none is fixed: the engine (mlx-serve, Splash or
one of our own), the patches (namp's, paperniuk's, ours or none), and the
model (stock or uncensored) can each change when a measurement shows the
change gets closer. Use anyone's work, ours included, or none of it. MLX
weights only: convert a model that ships in another format, never serve a
GGUF. `docs/findings.md`, "How close to the limit", gives the ceiling and how
far the current setup is from it.

**Read `NEXT.md` first if it exists.** It is untracked and holds the state of
the machine this checkout runs on and the work left on it.

**On a client machine**, follow `docs/clients.md` step by step. The server's
scripts do not run there.

## Where things are

- `README.md` is the setup guide, including "Update mlx-serve".
- `docs/findings.md` holds the measurements behind the engine, the patch, the
  model pack and each flag.
- `docs/clients.md` is the guide for connecting a client.
- `bench/` is the measuring harness: the speed workloads, the KLD score
  against the release, the gates and the refusal check, run in a window that
  stops production and restores it. `bench/README.md` lists the sources to
  watch and the path a candidate takes.
- `scripts/` holds the numbered setup steps, `verify.sh` and `uninstall.sh`.
  Every script sources `lib.sh`, which sources `pins.sh`.
- `scripts/pins.sh` pins everything downloaded: the mlx-serve tag and commit,
  Zig, libllama, and the repository and revision of the model, its
  uncensoring adapter and its draft model.
  `config/model-source.sha256`, `config/adapter-source.sha256` and
  `config/draft-source.sha256` list their files with checksums,
  and `config/convert-requirements.txt` the converter's Python packages.
- `patches/inkling2-m1.patch` is namp's M1/M2 patch, and
  `patches/inkling2-m1-speed.patch` this repo's changes on top of it. Both are
  applied to upstream's `src/` at build time, in that order. `check-patch.sh`
  checks that they still apply.
- `config/` holds the tailnet policy and the templates that the setup steps
  install. `render()` in `lib.sh` fills their `@PLACEHOLDERS@`. `config.env`
  is untracked and overrides the defaults in `lib.sh`.
- Every file describes the current setup. Removed engines, models and tools
  stay in git history only.

## How the server is meant to run

This is the setup measured closest to the goal so far. Run upstream mlx-serve
at the pinned tag, built the way its release workflow
builds it, with only the two patches in `patches/` on top. Convert the model
with upstream's own converter. This repo adds only what upstream lacks or
what a measurement justifies:

- the patch, from [namp/mlx-serve-inkling2-m1](https://github.com/namp/mlx-serve-inkling2-m1),
  kept as a diff against upstream so it can be dropped once upstream ships
  the same speed on an M1, or carried by this repo if the fork goes quiet
- the speed patch, this repo's own changes to namp's code, each measured in
  `docs/findings.md`, dropped part by part as the fork ships the same
- a LaunchAgent, because the command-line build ships no service manager
- the hardening step: pf, sshd and a battery watchdog
- the flags in `config/com.llmserver.mlx-serve.plist`, each with its reason
  in `docs/findings.md`

To change a setting, use upstream's published numbers when they cover this
Mac. When they do not, measure here: one change at a time, the current setup
run before and after it, and the gates in `docs/findings.md` passed. Keep the
change only if the measurement supports it, and record it there.

When a client does not work, check upstream's docs and issues first. Do not
work around the problem with request rewriting or a proxy. Record the
behaviour and wait for a release, or carry a fix in the patch.

A new mlx-serve release is a deliberate bump in `pins.sh`. Follow "Update
mlx-serve" in `README.md`: rebase the patch first, and drop each part of it
upstream now ships.

## Rules

- **Never print the API key or put it on a command line.** A session once
  printed it, and the key had to be replaced. Pass it to curl on stdin with
  `curl_hdr` from `lib.sh`. mlx-serve gets it in `MLX_SERVE_API_KEY`, which
  the LaunchAgent reads from the key file at start. The Hugging Face token in
  `~/.cache/huggingface/token` gets the same care.
- **The repository is public.** Keep usernames, real hostnames, tailnet names,
  IP addresses, home directory paths and email addresses out of every file,
  commit message and PR text. Use the placeholders `<machine>.<tailnet>.ts.net`
  and `100.64.0.0/10`, and `noreply` or `example.com` addresses.
  `check-public.sh` scans tracked files only, so check commit messages and PR
  text yourself.
- **You have no sudo** (`sudo -n` fails). Run what you can unprivileged. Give
  the user each root command with its expected output, and say which steps
  you did not run.
- **Commits are unsigned.** Agents work unattended, so nothing waits on a
  1Password signature. GitHub signs each squash merge, so `main` keeps a
  verified history.
- **Branch and open a PR.** Never push to `main`; the user merges on GitHub.

## Scripts

- Write POSIX `sh`. Before you commit, run what CI runs:

  ```sh
  shellcheck -x -s sh scripts/*.sh config/*.sh
  sh scripts/check-patch.sh
  sh scripts/check-public.sh
  ```

- Make setup scripts idempotent, and have each one check its own result
  before it reports success. A script that stops the endpoint must say so and
  print how to recover.
- Check every download against a pin before using it. Upstream's
  `fetch-zig.sh` and `fetch-llama.sh` check nothing, so `1-install.sh` stages
  Zig itself and checks the library `fetch-llama.sh` stages.
- `1-install.sh` and `3-services.sh` run as the user. Homebrew refuses root,
  and macOS gives mlx-serve the GPU only in the user's login session.
  `2-tailscale.sh`, `4-harden.sh`, `verify.sh` and `uninstall.sh` need sudo.
- Install root-owned files outside the checkout, under `/usr/local/etc/llm-server`,
  `/usr/local/sbin` or `/Library`. Nothing reads this repo at run time.
- Call mlx-serve by `MLX_SERVE_BIN`. Its folder is named for the tag and the
  patch's checksum, so a new pin or patch builds beside the running one.
- Restart launchd jobs with `start_job` and `stop_job` from `lib.sh`.
  `launchctl bootout` returns before the job is gone, so an immediate
  `bootstrap` fails.

## Measuring

Measure with `bench/`, so every number comes from the same prompts, corpus
and timing. Change the harness only in its own PR, and run the current
setup again after the change before you compare against older numbers.

- Stop the server first and run one GPU job at a time. A second job, a model
  download or a build skews every number.
- Run the candidate between two runs of the current setup, and keep it only
  if it beats both on its metric and loses nothing elsewhere by more than
  about 3%.
- Score a new model pack against the release with upstream's
  `tests/inkling2_kld.py` before measuring its speed.
- Speed alone is not enough: check the long-context needle, the follow-up
  set and the OpenCode-shaped follow-ups in `docs/findings.md` before a
  change ships.
