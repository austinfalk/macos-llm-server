# Working in this repo

A guide and scripts for running a private model server on an Apple Silicon Mac
with [Splash](https://github.com/incoai/splash), behind `tailscale serve`. An
M3 or later runs Splash. An M1 or M2 runs its port,
[paperniuk/splash](https://github.com/paperniuk/splash).

**Read `NEXT.md` first if it exists.** It is untracked and holds the state of
the machine this checkout runs on and the work left on it.

**On a client machine**, follow `docs/clients.md` step by step. The server's
scripts do not run there.

## Where things are

- `README.md` is the setup guide, including "Update Splash".
- `docs/findings.md` holds the measurements behind each setting and upgrade.
- `docs/clients.md` is the guide for connecting a client.
- `scripts/` holds the numbered setup steps, `verify.sh` and `uninstall.sh`.
  Every script sources `lib.sh`, which sources `variant.sh`.
- `scripts/variant.sh` holds each build's version, checksums and
  `SPLASH_SERVE_ARGS`.
- `config/` holds the tailnet policy and the templates that the setup steps
  install. `render()` in `lib.sh` fills their `@PLACEHOLDERS@`. `config.env`
  is untracked and overrides the defaults in `lib.sh`.
- Every file describes the current setup. Removed engines and tools stay in
  git history only.

## How the server is meant to run

Run the Splash build for the chip as it ships: its checkpoint, the draft it
pairs with that checkpoint, its API key and its defaults. This repo adds only
what Splash lacks or what a measurement justifies:

- a LaunchAgent, because Splash ships no service manager
- the hardening step: pf, sshd and a battery watchdog
- the flags in `config/com.llmserver.splash.plist` and `SPLASH_SERVE_ARGS`,
  each with its reason in `docs/findings.md`

To change a setting, use Splash's or the port's published numbers when they
cover the case. When they do not, measure on this machine. Keep the change
only if the measurement supports it, and record it in `docs/findings.md`.

When a client does not work, check Splash's and the port's docs and issues
first. Do not work around the problem with request rewriting or a proxy.
Record the behaviour and wait for a release.

A new Splash release is a deliberate bump of the build's block in
`variant.sh`. Follow "Update Splash" in `README.md`, and run `verify.sh`
before you keep it.

## Rules

- **Never print the API key or put it on a command line.** A session once
  printed it, and the key had to be replaced. Pass it to curl on stdin with
  `curl_hdr` from `lib.sh`. Splash gets it in `SPLASH_API_KEY`, which the
  LaunchAgent reads from the key file at start.
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

## Scripts

- Write POSIX `sh`. Before you commit, run what CI runs:

  ```sh
  shellcheck -x -s sh scripts/*.sh config/*.sh
  sh scripts/test-variant.sh
  sh scripts/check-public.sh
  ```

- Make setup scripts idempotent, and have each one check its own result
  before it reports success. A script that stops the endpoint must say so and
  print how to recover.
- `1-install.sh` and `3-services.sh` run as the user. Homebrew refuses root,
  and macOS gives Splash the GPU and the Neural Engine only in the user's login
  session. `2-tailscale.sh`, `4-harden.sh`, `verify.sh` and `uninstall.sh` need
  sudo.
- Install root-owned files outside the checkout, under `/usr/local/etc/llm-server`,
  `/usr/local/sbin` or `/Library`. Nothing reads this repo at run time.
- Call Splash by `SPLASH_BIN`, never by a version's folder.
- Only `lib.sh` sets `SPLASH_VARIANT`, from the chip. A build chosen by hand
  can install a Splash that refuses the GPU.
- Restart launchd jobs with `start_job` and `stop_job` from `lib.sh`.
  `launchctl bootout` returns before the job is gone, so an immediate
  `bootstrap` fails.
