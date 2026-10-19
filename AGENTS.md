# Working in this repo

A guide and scripts for running a private model server on an Apple Silicon Mac
with [Splash](https://github.com/incoai/splash), behind `tailscale serve`. An
M3 or later runs Splash itself, and an M1 or M2 runs its port,
[paperniuk/splash](https://github.com/paperniuk/splash). `README.md` is the
guide, and `docs/findings.md` the measurements behind it. **`NEXT.md`, if
present, is the state of the machine this checkout runs on and what is left to
do. Read it first.** It is local to that machine and not tracked.

**On a client machine** (not the server), such as the Omarchy machine that
uses it, the task is to connect it. Follow `docs/omarchy-client.md` step by
step. The server's scripts do not run there.

## Principle

Use the Splash build for the chip as it ships: Splash's Homebrew formula on an
M3 or later, or the port's release installer on an M1 or M2, pinned by
checksum; the checkpoint the build's documentation names and the draft Splash
pairs with it automatically; its API key; and its defaults for everything
else. The departures are this repo's LaunchAgent, because Splash ships no
service manager, and one setting: reasoning effort defaults to medium
(`docs/findings.md` has why). Defer to the published measurements of Splash
and the port rather than benchmarking. When a client does not work, find out
whether Splash or the port documents the behaviour before changing anything
here, and do not work around it with request rewriting or proxies; record it
and wait for a release.

## Layout

- `scripts/` holds the numbered setup steps, `verify.sh`, `uninstall.sh`, and
  the checks CI runs, `test-variant.sh` and `check-public.sh`. Everything
  sources `lib.sh`, which sources `variant.sh` for each build's values.
- `config/` holds the tailnet policy, and templates that `3-services.sh`
  (Splash's LaunchAgent) and the hardening step (pf, sshd, battery watchdog)
  install, with `@PLACEHOLDERS@` filled by `render()` in `lib.sh`. `config.env`
  (gitignored) overrides the defaults in `lib.sh`.
- `docs/` holds `findings.md`, the measurements and their history;
  `omarchy-client.md`, the client guide; and `omarchy-desktop.md`, the Mac's
  desktop and SSH from the client.

## Conventions

- Scripts are POSIX `sh` and must pass `shellcheck -x -s sh` from the repo root.
- Setup scripts are idempotent and **verify their own result before reporting
  success**. A script that changes services must never leave the endpoint down
  without saying so and printing how to recover.
- `1-install.sh` and `3-services.sh` run as the user (Homebrew refuses root,
  and Splash runs in the user's login session, where macOS gives it the GPU
  and the Neural Engine); `2-tailscale.sh`, `4-harden.sh`, `verify.sh` and
  `uninstall.sh` need sudo.
- Root-installed files live outside the checkout (`/usr/local/etc/llm-server`,
  `/usr/local/sbin`, `/Library/...`); Splash, its LaunchAgent and its log live
  under the user's `~/Library`. Nothing reads files from this repo at run time.
- Each build's pins live in `scripts/variant.sh`. On an M3 or later, Splash
  comes from the Homebrew formula `incoai/tap/splash`, pinned by
  `SPLASH_VERSION`, `SPLASH_ARCHIVE_SHA256` and `SPLASH_BOTTLE_SHA256`.
  `1-install.sh` refuses a formula whose version or checksums differ, and runs
  `brew pin splash` after installing, so `brew upgrade` does not move it. On an
  M1 or M2, Splash comes from the port's release installer, `install-m1.sh`,
  pinned by `SPLASH_VERSION` and `SPLASH_INSTALLER_SHA256`. `1-install.sh`
  refuses an installer whose SHA-256 differs. The installer keeps each version
  under `~/Library/Application Support/Splash-M1` and points `current` and the
  command at the newest. Call Splash by path, `SPLASH_BIN`
  (`$(brew --prefix)/bin/splash` or `splash-m1`), never a version's folder. A
  new release is a deliberate bump of the build's values, never a side effect
  of `brew upgrade`.
- Only `scripts/lib.sh` sets `SPLASH_VARIANT`, from the chip, with a plain
  assignment that neither `config.env` nor the environment can override. A
  build chosen by hand could install a Splash that refuses the Mac's GPU.
  `scripts/test-variant.sh` checks both in CI.
- Restart launchd jobs with `start_job`/`stop_job` from `lib.sh`: `launchctl
  bootout` is asynchronous and an immediate `bootstrap` fails.
- Claude has no sudo here (`sudo -n` fails). Test what can run unprivileged;
  hand root commands to the user with the expected output, and say plainly which
  paths have not been run.
- Never print the API key or put it on a command line: pass it to curl on stdin
  (`curl_hdr` in `lib.sh`), and to Splash in `SPLASH_API_KEY`, which the
  LaunchAgent's shell reads from the key file at start.
- Record results in `docs/findings.md` with what they changed.
- Only `docs/findings.md` names engines this server no longer runs. Everything
  else describes the current setup.
- The repository is public, so nothing personal enters any file, commit
  message or PR text: no usernames, real hostnames or tailnet names, the
  machines' IP addresses, home directory paths, or email addresses other than
  noreply and `example.com` ones. Use the placeholders, such as
  `<machine>.<tailnet>.ts.net` and `100.64.0.0/10`. `scripts/check-public.sh`
  checks tracked files in CI.
- Commits are signed with the maintainer's SSH signing key through 1Password.
  If signing fails, say so and ask; do not fall back to unsigned commits.
