# Working in this repo

A guide and scripts for running a private model server on an Apple Silicon Mac,
with [TensorFold](https://github.com/ashhart/TensorFold) behind `tailscale serve`.
`README.md` is the guide, and `docs/findings.md` the measurements behind it.
**`NEXT.md`, if present, is the state of the machine this checkout runs on and
what is left to do — read it first.** It is local to that machine and not
tracked.

**On a client machine** (not the server) — for example, the Omarchy machine
that uses it — the task is to connect it: follow `docs/omarchy-client.md`
step by step. The server's scripts do not run there.

## Principle

Use TensorFold as it ships: its Homebrew tap, its recipes' checkpoints and
drafters, `tensorfold service`, its API keys, and its defaults for everything
else. Defer to its published measurements rather than benchmarking. When a
client does not work, find out whether TensorFold documents the behaviour
before changing anything here, and do not work around it with request
rewriting or proxies; record it and wait for a release.

## Layout

- `scripts/` — numbered setup steps, `verify.sh`, `uninstall.sh`, and
  `lib.sh`, which everything sources.
- `config/` — the tailnet policy, and templates the hardening step installs
  (pf, sshd, battery watchdog), with `@PLACEHOLDERS@` filled by `render()` in
  `lib.sh`. `config.env` (gitignored) overrides the defaults in `lib.sh`.

## Conventions

- Scripts are POSIX `sh` and must pass `shellcheck -x -s sh` from the repo root.
- Setup scripts are idempotent and **verify their own result before reporting
  success**. A script that changes services must never leave the endpoint down
  without saying so and printing how to recover.
- `1-install.sh` and `3-services.sh` run as the user (Homebrew and TensorFold
  refuse root); `2-tailscale.sh`, `4-harden.sh`, `verify.sh` and
  `uninstall.sh` need sudo.
- Root-installed files live outside the checkout (`/usr/local/etc/llm-server`,
  `/usr/local/sbin`, `/Library/...`); TensorFold's live under the user's
  `~/Library`. Nothing reads files from this repo at run time.
- The TensorFold service's interpreter is `$(brew --prefix)/opt/tensorfold/libexec/bin/python`,
  never a Cellar path: `brew upgrade` deletes the old Cellar folder.
- Restart launchd jobs with `start_job`/`stop_job` from `lib.sh`: `launchctl
  bootout` is asynchronous and an immediate `bootstrap` fails.
- Claude has no sudo here (`sudo -n` fails). Test what can run unprivileged;
  hand root commands to the user with the expected output, and say plainly which
  paths have not been run.
- Never print the API key or put it on a command line: pass it to curl on stdin
  (`curl_hdr` in `lib.sh`).
- Record results in `docs/findings.md` with what they changed.
- Commits are signed with the maintainer's SSH signing key through 1Password.
  If signing fails, say so and ask; do not fall back to unsigned commits.
