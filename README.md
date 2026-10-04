# macos-llm-server

**A private AI server on a Mac.**

Turn an Apple Silicon Mac — desktop or laptop — into a model server that your
other devices can use from anywhere, privately, with the model running on the
Mac's GPU. It runs [TensorFold](https://github.com/ashhart/TensorFold), which
serves OpenAI- and Anthropic-compatible APIs, so agents and other tools can
point at it.

```
  your laptop, phone, CI ──Tailscale (WireGuard)──▶ tailscale serve :443    TLS, tailnet only
                                                        │
                                                        ▼
                                                    TensorFold 127.0.0.1:8080   checks the API key,
                                                                                runs the model on the GPU
```

When you are done:

- The model server runs **as a TensorFold service in your login session**,
  set up exactly as TensorFold documents it. After a restart, you log in once —
  over Screen Sharing, from anywhere on your tailnet — and it starts.
- It is reachable **only over your tailnet**, and **only with an API key**.
  Nothing listens on the local network.
- One command, `scripts/verify.sh`, checks all of it.

This guide takes TensorFold's defaults and recipes as they ship, and defers to
TensorFold's own published measurements. What was measured on this guide's
machine is in [`docs/findings.md`](docs/findings.md).

---

## Before you start

**Hardware.** An Apple Silicon Mac. Memory decides which models you can run:
TensorFold gives itself 70% of RAM by default and checks at startup that the
model fits. The model used here needs a 64 GB Mac.

**Set expectations.** A local model is private, not fast. On an M1 Max, the
model used here reads a prompt at about 100 tokens a second and writes at
15-20; an agent's first turn takes 1½-2½ minutes, and later turns are fast
because the server keeps the conversation cached. Hosted models run far faster,
for a few dollars a month. Local is the right tool for code that cannot leave
the building, batch and overnight jobs, and a private endpoint for your own
scripts — see [findings](docs/findings.md#context-is-local-worth-it-sourced).

**You need** macOS 14 or later, an administrator account on the Mac, [Homebrew](https://brew.sh),
a [Tailscale](https://tailscale.com) account, about an hour, and room for the
model download (about 20 GB).

**Get this repository onto the Mac**, anywhere you like. Optionally copy
`config.env.example` to `config.env` and change settings; every setting has a
working default, and the file explains each one.

---

## 1. Choose a model

Pick one of [TensorFold's recipes](https://github.com/ashhart/TensorFold/blob/v0.6.5/docs/recipes/README.md):
each names a checkpoint, and often a draft model that makes it write faster.
`tensorfold models` lists them, and `tensorfold info MODEL` checks one without
downloading it.

The default here is **Qwen3.8-27B** (`TensorFold/Qwen3.8-27B-MLX-4bit`, with
the `z-lab/Qwen3.8-27B-DFlash2` drafter): of the recipes that fit 64 GB, it
scores highest on independent benchmarks. It is a dense model, so it reads
prompts slowly on older chips; a mixture-of-experts recipe (Qwen3.6-35B-A3B,
Gemma 4, Nemotron) reads them several times faster at a large cost in quality.

**TensorFold's recipes** (October 2026). Index: [Artificial Analysis
Intelligence Index](https://artificialanalysis.ai/) v4.3.2, which changes over
time:

| Model | Checkpoint | Type | Mac memory | Index | Claude Code |
|---|---|---|---|---|---|
| GLM-5.3-Flash | `TensorFold/GLM-5.3-Flash-MLX-4bit-MTP` | mixture of experts | 256 GB (~151 GiB resident) | 42 | accepted |
| Qwen3.8 Flash Next | `TensorFold/Qwen3.8-Flash-Next-MLX-4bit-MTP` | mixture of experts | 128 GB (~76 GiB resident) | 40 | refused |
| **Qwen3.8-27B** (default) | `TensorFold/Qwen3.8-27B-MLX-4bit` + `z-lab/Qwen3.8-27B-DFlash2` | dense | 64 GB (~16 GiB weights, 144K context) | 34 | refused |
| DeepSeek-V4-Flash | `mlx-community/DeepSeek-V4-Flash-4bit` | mixture of experts | 256 GB (~151 GiB resident) | 34 | accepted |
| Ternary Bonsai 2 27B | `prism-ml/Ternary-Bonsai-2-27B-mlx-2bit` | dense, 2-bit (the 27B compressed) | 32 GB class (~14 GiB on M1-M4) | not rated (Prism: 98% of the 27B) | refused |
| Qwen3.6-35B-A3B | `TensorFold/Qwen3.6-35B-A3B-MLX-4bit-MTP` | mixture of experts, 3B active | 64 GB (~19 GiB weights, 262K context) | 18 | refused |
| Gemma 4 26B-A4B | `mlx-community/gemma-4-26b-a4b-it-4bit` | mixture of experts, 4B active | 64 GB (measured on one by TensorFold) | 17 (estimated) | accepted |
| Nemotron 3.5 Lightning | `TensorFold/NVIDIA-Nemotron-3.5-Lightning-30B-A3B-MLX-4bit` | mixture of experts, ~3.6B active | 64 GB (262K context) | 13 | accepted |

"Claude Code" is TensorFold's own check of the model's chat template, run on
each one: whether it accepts the mid-conversation system messages Claude Code
sends (step 8). Accepted is necessary, not proven sufficient: Claude Code was
not run against those models here. Mixture-of-experts models do several times
less work per token than dense ones, so they run much faster on the same Mac:
on an M1 Max, the 35B-A3B's one-token step measured 14.5 ms against the 27B's
64 ms. Memory
figures are from TensorFold's recipes and this setup's startup logs;
[findings](docs/findings.md#the-server-tensorfold-and-qwen38-27b) has
the reasoning behind the default.

**Check your clients before you choose.** A model's chat template decides
which clients work: Claude Code needs one that accepts mid-conversation system
messages, which the Qwen templates do not. See step 8.

Set your choice as `LLM_MODEL` and `LLM_DRAFTER` in `config.env`.

---

## 2. Prepare the tailnet

In the [Tailscale admin console](https://login.tailscale.com/admin):

1. **DNS** → turn on **MagicDNS** and **HTTPS Certificates**. The server's TLS
   comes from these. (Certificates are public record: the machine's tailnet name
   appears in Certificate Transparency logs.)
2. **Access controls** → edit [`config/tailscale-policy.hujson`](config/tailscale-policy.hujson),
   replacing `YOUR-LOGIN` with your login from the Users page, and paste it in.
   Pasting **replaces** your tailnet's whole policy. This does two things: it lets the machine carry the `tag:llm-server` tag,
   and it makes the tailnet **default-deny**, allowing you in on the ports the
   template lists only. If other devices on your tailnet need to reach each
   other, add grants for them.
3. **Settings → Device management** → turn on **Device approval**, so a leaked
   auth key is not enough to join.

---

## 3. Install the software

As your normal user:

```sh
sh scripts/1-install.sh
```

Installs `tailscale` from Homebrew and TensorFold from [its own Homebrew tap](https://github.com/ashhart/homebrew-tensorfold),
and keeps the model cache out of Time Machine. If the Tailscale app is
installed, the script warns you: this setup runs Homebrew's `tailscaled`
instead, and running both has not been tested.

**Optional: a Hugging Face token.** Models download from Hugging Face, which
rate-limits anonymous downloads. Create a **read** token (Settings → Access
Tokens), keep it in your password manager, and put it where Hugging Face's
tools look — for example from 1Password, without it touching the screen:

```sh
( umask 077; mkdir -p ~/.cache/huggingface && op read "op://Private/<item>/<field>" > ~/.cache/huggingface/token )
```

---

## 4. Join the tailnet

```sh
sudo sh scripts/2-tailscale.sh
```

Runs Tailscale as a system daemon, so the tailnet is up at boot before anyone
logs in — which is what lets you reach the login window remotely. The first
time, it prints a login URL; open it, and approve the machine in the admin
console. It joins with the `tag:llm-server` tag — tagged devices never have
their keys expire — makes your account Tailscale's operator (so step 5 needs no
sudo), and checks that HTTPS certificates are available.

---

## 5. Start the server

As yourself, not sudo:

```sh
sh scripts/3-services.sh
```

It generates an API key, downloads the model, installs it as a TensorFold
service named `local-model` — TensorFold's defaults for everything else — and
publishes it on your tailnet. Then it **checks the endpoint**: a request with
the key must get 200, one without must get 401. The first run downloads about
20 GB, and loading the model takes a few minutes after that. It is safe to
re-run at any time.

Your endpoint is `https://<machine>.<tailnet>.ts.net/v1`, and the model ID
clients use is `local-model`. The key is the `clients:` line of
`~/.config/tensorfold/api-keys`.

**Why it is built this way**, briefly:

- **TensorFold's own service.** `tensorfold service` installs a LaunchAgent in
  your login session, which starts at login and stops at logout; it refuses
  root. The one setting changed from its defaults is the interpreter path:
  the default points into Homebrew's versioned folder, which the next
  `brew upgrade tensorfold` deletes, so the script uses Homebrew's stable
  `opt` link instead.
- **The key is TensorFold's.** It checks `Authorization: Bearer` and
  `x-api-key` itself, on every route except `/health`, which then says only
  `ok`. Its HTTP API has no model management, so the key opens the model and
  nothing else. Models are downloaded from the command line, on the Mac.
- **TensorFold listens only on 127.0.0.1.** `tailscale serve` is the only way
  in, and it adds TLS and limits it to your tailnet; TensorFold's docs ask for
  a proxy in front of anything beyond loopback.
- **The key guards the network, not the machine.** Anything running on the Mac
  can read your key file as you.

---

## 6. Harden the machine

```sh
sudo sh scripts/4-harden.sh
```

- **Turns off automatic login** and removes `/etc/kcpassword`, which stores the
  login password with a published, reversible obfuscation. You log in yourself
  after a restart, over Screen Sharing (below).
- **SSH**, if Remote Login is on: keys only, and — unless you set
  `LLM_SSH_TAILNET_ONLY=no` — only from the tailnet. Tailscale's access rules do
  not cover your local network, so without this your SSH password is open to
  anything on the LAN. If Remote Login is on and your account has no SSH key
  installed, the script stops before changing anything, rather than lock you
  out: add a key to `~/.ssh/authorized_keys` and re-run.
- **Power.** Desktops: never sleep, and restart after a power failure where the
  hardware supports it. Laptops: never sleep on mains power, and a watchdog
  **shuts down cleanly at 15% battery** instead of dying and losing memory.
  On battery a laptop still sleeps when idle, and the server with it, unless
  you set `LLM_DISABLE_SLEEP=yes` (below). Apple documents that Apple Silicon
  laptops power back on when mains returns; this guide has not tested it yet.
- **AirPlay Receiver**: if it is on, the script tells you. It listens on ports
  5000 and 7000 on every network; turn it off in System Settings → General →
  AirDrop & Handoff unless you use it.
- **Screen Sharing, tailnet only.** macOS's Screen Sharing (VNC, port 5900)
  listens on every network and has no setting to change that, so the script
  installs a small pf rule set that drops port 5900 — and 88, the Kerberos
  service its sign-in can use, and Sunshine's ports — unless the connection
  comes from the tailnet, reloaded at every boot. It is installed whether or
  not Screen Sharing is on. To use it: System Settings → General → Sharing →
  Screen Sharing on, **Allow access for: Only these users** (your account), and
  leave **"VNC viewers may control screen with password" off** — that is an
  old 8-character scheme that can be cracked from one captured login. Clients
  then sign in with your Mac username and password: Screens on iPhone and
  iPad, Remmina (with `libvncserver`) on Linux — TigerVNC cannot. It works at
  the login window, which is how you **log in after a restart** and so start
  the model server. For smoother video, Sunshine and Moonlight
  ([docs/omarchy-client.md](docs/omarchy-client.md), 7b) work once you are
  logged in; keep Screen Sharing on as the way in.

**FileVault is your decision.** With it **off**, after any restart the Mac
reaches the login window by itself, and you log in over Screen Sharing — but
anyone holding the machine can read the disk. With it **on**, the disk is
protected, but after an unplanned restart the Mac waits at FileVault's unlock
screen, with no network, until someone types the password at the machine. For
planned restarts, `sudo fdesetup authrestart` unlocks the next boot once. A
desktop in a locked room and a laptop that travels deserve different answers.

**Laptops with the lid shut.** Closing the lid normally sleeps a laptop.
Setting `LLM_DISABLE_SLEEP=yes` applies `pmset -a disablesleep 1`, which is
meant to keep it awake (the default, `no`, sets it back to `0`) — but the setting is system-wide (battery too) and
undocumented. **Verified on mains power:** with `disablesleep 1` and the lid
shut, this guide's Mac served requests for hours with no sleep in its power log
([findings](docs/findings.md#unattended-operation)). On battery it has not been
tested.

---

## 7. Verify

Logged in on the Mac:

```sh
sudo sh scripts/verify.sh
```

Checks the tailnet (and that Funnel is off), that the TensorFold service is
running in your session, not as root, and will survive an upgrade, that nothing
listens beyond loopback, the API key with both headers (and wrong, empty and
missing keys), what `/health` reveals, the model ID clients see, and the
hardening. It exits non-zero if anything fails.

---

## 8. Connect your tools

**On each device that will use it:**

1. **Join the tailnet** with the Tailscale login your policy names (step 2).
   Another login, or a device shared in from another tailnet, gets nothing
   until you add it to the policy.
2. **Copy the key** — the part after `clients: ` in
   `~/.config/tensorfold/api-keys` on the server — through a password manager,
   or over SSH on the tailnet. Keep it where only you can read it, not in shell
   history or a repository.
3. **Check it:**

   With the key saved, alone, in a file only you can read (here
   `~/.config/llm-server/api-key`), so it reaches curl on stdin rather than its
   command line or your shell history:

   ```sh
   printf 'header = "Authorization: Bearer %s"\n' "$(cat ~/.config/llm-server/api-key)" \
     | curl -sf -K - https://<machine>.<tailnet>.ts.net/v1/models
   ```

   `"id": "local-model"` means the tailnet, TLS, the key and TensorFold all work.

Base URL `https://<machine>.<tailnet>.ts.net/v1`, model `local-model`, API key
as above. TensorFold applies the model's own sampling settings when a client
sends none, and thinks before answering: allow 16K+ output tokens, or a reply
that runs out while thinking comes back empty. **Tell clients the context
window** TensorFold reports at startup — 144,384 tokens for the 27B here
(`tensorfold service logs local-model`) — so they compact before reaching it.

**Which tools work** (TensorFold 0.6.5, Qwen3.8-27B):

| Client | API it uses | |
|---|---|---|
| Hermes Agent, OpenCode, and other OpenAI chat-completions clients | `/v1/chat/completions` | **work** |
| Claude Code | Anthropic Messages | refused: needs a model whose template accepts mid-conversation system messages (Gemma 4, Nemotron, GLM-5.3, DeepSeek-V4; step 1) |
| Codex | Responses | refused: it always asks for encrypted reasoning, which TensorFold does not do |

Both refusals are documented TensorFold behaviour, not configuration
([findings](docs/findings.md#the-server-tensorfold-and-qwen38-27b)).
Step-by-step configurations for all four, with checks, and what to watch for in
TensorFold's releases: [docs/omarchy-client.md](docs/omarchy-client.md).

---

## 9. Running it

| | |
|---|---|
| Service | `tensorfold service status\|logs\|restart\|stop\|start local-model` |
| Settings | `~/Library/Application Support/TensorFold/control/profiles/local-model.json` (TensorFold's; change them by re-running `3-services.sh`) |
| Job | `~/Library/LaunchAgents/dev.tensorfold.local-model.plist` |
| Log | `~/Library/Logs/TensorFold/local-model/server.log` (rotated by TensorFold at 8 MiB, four older files kept) |
| API key | `~/.config/tensorfold/api-keys` |
| Models | `~/.cache/huggingface/hub` |
| Dashboard | `tensorfold tui` |

**After a restart**, connect with Screen Sharing and log in: the service starts
with your session. `tensorfold service status local-model` says when it is
running; loading takes a few minutes.

**Update.** Upgrade with Homebrew as usual — `brew upgrade tensorfold
tailscale`, or a routine `brew upgrade` of everything. Then, for each that was
upgraded (`brew upgrade` prints a line such as `tensorfold 0.6.5 -> 0.6.6`):

- **TensorFold:** restart the service right away.

  ```sh
  tensorfold service restart local-model
  ```

  The service survives the upgrade — it starts through Homebrew's stable `opt`
  link, not a version's folder — but the running server keeps using the old
  version's files until it restarts, and `brew upgrade` itself deletes them:
  Homebrew removes an upgraded formula's old version at once (unless
  `HOMEBREW_NO_INSTALL_CLEANUP` is set). Loading takes a few minutes:
  `tensorfold service status local-model` says when it is running, and
  `tensorfold --version` which version is installed. Then skim
  TensorFold's [changelog](https://github.com/ashhart/TensorFold/blob/main/CHANGELOG.md),
  especially for client support (step 8; the client guide's "When TensorFold
  updates" lists what to look for). Clients need no change.
- **Tailscale:** `sudo brew services restart tailscale`.

`sudo brew services` makes root own the running Tailscale's `bin/`, so the
cleanup after a Tailscale upgrade fails with "Could not cleanup old kegs".
Once the restart above has moved the service to the new version, hand the old
one back and remove it:

```bash
sudo chown -R "$(whoami):admin" "$(brew --cellar tailscale)/OLD_VERSION"
brew cleanup tailscale
```

Leave the running version owned by root: the daemon runs as root, and a
binary your account owns is one it could replace.

**Change the model.** Set `LLM_MODEL` (and `LLM_DRAFTER`) in `config.env` and
re-run `3-services.sh`; clients keep asking for `local-model`, but check the
context window it reports and which clients the new template supports.

**Rotate the key.** Delete `~/.config/tensorfold/api-keys`, re-run
`3-services.sh`, and update your clients. TensorFold rereads the key file within
a second, so the server needs no restart.

**Remove it.** `sudo sh scripts/uninstall.sh` turns off `tailscale serve`,
removes the TensorFold service, the hardening jobs and the SSH hardening (so
SSH accepts passwords again, the macOS default). It prints what it deliberately
left: models, key, logs, packages, tailnet membership, power settings.

---

## Troubleshooting

| Symptom | Likely cause | Fix |
|---|---|---|
| `401` | Missing or wrong key | Check the header; the key is the `clients:` line of `~/.config/tensorfold/api-keys` |
| `502` from the endpoint | TensorFold is not running: after a restart, nobody has logged in | Log in over Screen Sharing; `tensorfold service status local-model` |
| `400` "does not support mid-conversation system messages" | Claude Code, against a model whose template refuses them | Step 8 |
| `400` "include is not supported" | Codex | Step 8 |
| Empty answers | Output budget too small for a thinking model | Allow 16K+ output tokens (step 8) |
| Service will not start after `brew upgrade` | Its interpreter path points at a deleted version | Re-run `3-services.sh` |
| `Bootstrap failed: 5: Input/output error` | A launchd job was restarted too quickly | Re-run the script; it waits and retries |
