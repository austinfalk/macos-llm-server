# macos-llm-server

**A private AI server on a Mac.**

Turn an M1 or M2 Mac, desktop or laptop, into a model server that your other
devices can use from anywhere, privately, with the model running on the Mac's
GPU and Neural Engine. It runs [Splash](https://github.com/incoai/splash)
through [its community port for M1 and M2](https://github.com/paperniuk/splash).
Splash serves OpenAI- and Anthropic-compatible APIs, so agents and other tools
can point at it.

```
  your laptop, phone, CI ──Tailscale (WireGuard)──▶ tailscale serve :443    TLS, tailnet only
                                                        │
                                                        ▼
                                                    Splash 127.0.0.1:8000   checks the API key,
                                                                            runs the model on the GPU
```

When you are done:

- The model server runs **in your login session**, as a LaunchAgent this
  repository installs, because Splash ships no service manager. After a
  restart, you log in once, over Screen Sharing from anywhere on your tailnet,
  and it starts.
- It is reachable **only over your tailnet**, and **only with an API key**.
  Nothing listens on the local network.
- One command, `scripts/verify.sh`, checks all of it.

This guide takes Splash's defaults as they ship, and defers to the published
measurements of Splash and of its M1/M2 port. What was measured on this
guide's machine is in [`docs/findings.md`](docs/findings.md).

---

## Before you start

**Hardware.** A Mac with an M1 or M2 chip. Splash itself runs on M3 and newer
only. [paperniuk/splash](https://github.com/paperniuk/splash) is an unofficial
community port that adds Metal kernels for M1 and M2 GPUs; its author tested it
on an M1 Max and not on an M2 *(sourced)*. On an M3 or newer, use official
Splash instead (`brew install incoai/tap/splash`): `1-install.sh` refuses any
chip but an M1 or M2. Memory decides which models you can run. Splash sizes its
memory and context at startup, and stops if the model does not fit. The model
used here needs at least 36 GB of unified memory, 48 GB recommended
*(sourced)*; this guide has measured only a 64 GB Mac.

**Set expectations.** A local model is private, not fast. On an M1 Max, the
model used here reads a new prompt at 150-185 tokens a second and writes at
23-38, slower as a conversation grows. An agent's first turn takes one to two
minutes: Claude Code's first prompt, 21,200 tokens, took 114.5 s. Later turns
start in 1-2 s, because the server keeps the conversation cached. Hosted models
run far faster, for a few dollars a month. Local is the right tool for code
that cannot leave the building, batch and overnight jobs, and a private
endpoint for your own scripts. See
[findings](docs/findings.md#context-is-local-worth-it-sourced).

**You need** macOS 26.4 or later, an administrator account on the Mac, [Homebrew](https://brew.sh),
a [Tailscale](https://tailscale.com) account, about an hour, and room for the
model download (about 20 GB).

**Get this repository onto the Mac**, anywhere you like. Optionally copy
`config.env.example` to `config.env` and change settings; every setting has a
working default, and the file explains each one.

---

## 1. Choose a model

Splash serves two model families, Qwen3.8-27B and Qwen3.6-35B-A3B, in several
quantizations: MLX checkpoints of 2 to 8 bits, Unsloth's GGUF variants of 1 to
8 bits, NVFP4, and Prism ML's 2-bit Ternary Bonsai 2 (7.2 GB) *(sourced)*. For
each, it picks the DFlash2 draft model trained for that family, which makes it
write faster, by itself.

The default here is **Qwen3.8-27B** in MLX 4-bit,
`mlx-community/Qwen3.8-27B-4bit`, the checkpoint the port's release notes name.
It scores 34 on the [Artificial Analysis Intelligence
Index](https://artificialanalysis.ai/) v4.3.2, which changes over time, against
18 for Qwen3.6-35B-A3B *(sourced)*. The 35B-A3B is a mixture of experts with 3B
parameters active per token, so it writes faster: the port measured it at
127 tok/s on an M1 Max, and the 27B at 61.5 on a code prompt *(sourced)*. It
costs a large drop in quality.

To serve another, set `LLM_MODEL` in `config.env` to what Splash's `--model`
takes: an MLX repository, such as `mlx-community/Qwen3.6-35B-A3B-4bit`, or a
GGUF repository and variant, `OWNER/REPO:VARIANT`, such as
`unsloth/Qwen3.8-27B-GGUF:UD-Q4_K_M`. [Splash's model
list](https://github.com/incoai/splash#models) links the variants. Smaller ones
fit Macs with less memory; none was measured here.

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

Checks for an M1 or M2 and macOS 26.4 or later, installs `tailscale` from
Homebrew and Splash's M1/M2 port from its release, and keeps the model cache
out of Time Machine.

**Which Splash.** The port publishes each release as an archive and an
installer, `install-m1.sh`, which checks the archive's SHA-256. `1-install.sh`
downloads the installer of the release pinned in `scripts/lib.sh`
(`SPLASH_VERSION`, now 1.3.2-m1.1), and runs it only if its SHA-256 is
`SPLASH_INSTALLER_SHA256`. The installer unpacks the release under
`~/Library/Application Support/Splash-M1/<version>`, points `current` at it,
and writes the `splash-m1` command into Homebrew's `bin`. It leaves an official
`splash` alone. Because of the pin, `brew upgrade` never changes Splash; a new
release is a step you take (step 9). If the Tailscale app is installed, the
script warns you: this setup runs Homebrew's `tailscaled` instead, and running
both has not been tested.

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

It generates an API key, installs a LaunchAgent that runs Splash, waits for the
model, and publishes it on your tailnet. Then it **checks the endpoint**: a
request with the key must get 200, one without must get 401. The first start
downloads the model and its draft, about 20 GB, prepares the weights, and times
this Mac's Neural Engine against its GPU, which can take half an hour; the
script waits up to an hour. Later starts take a minute or two. It is safe to
re-run at any time: it restarts the server only when its settings change.

Your endpoint is `https://<machine>.<tailnet>.ts.net/v1`, and the model ID
clients use is `mlx-community/Qwen3.8-27B-4bit`. The key is the one line of
`~/.config/llm-server/api-key`.

**How it runs**, briefly:

- **A LaunchAgent of this repository's.** Splash ships no service manager:
  `splash serve` runs in the foreground until you stop it. So `3-services.sh`
  fills in `config/com.llmserver.splash.plist` and installs it as
  `~/Library/LaunchAgents/com.llmserver.splash.plist`, in your login session,
  where macOS gives Splash the GPU and the Neural Engine. launchd starts it at
  login, stops it at logout, and starts it again if it fails. Its output goes
  to `~/Library/Logs/llm-server/splash.log`, which nothing rotates.
- **Three flags.** The LaunchAgent runs `splash-m1 serve` with:
  - `--model mlx-community/Qwen3.8-27B-4bit` (`LLM_MODEL`), the model, and the
    ID clients use, which Splash reports in its responses and `/v1/models`.
    Splash pairs it with its DFlash2 draft, `incoai/Qwen3.8-27B-DFlash2`, by
    itself.
  - `--allowed-host <machine>.<tailnet>.ts.net`, the name `tailscale serve`
    passes on. Splash answers 403 to a Host name it was not started with, to
    keep out web pages that point a DNS name at the Mac. With this flag,
    requests through the tailnet get in; the server has not been run without
    it. The script reads the name from Tailscale.
  - `--default-reasoning-effort medium`: requests that name no effort get
    `medium` instead of the template's `xhigh`. At `xhigh`, answers took about
    twice as long for a small gain in quality, and about a fifth came back
    empty ([findings](docs/findings.md)).

  Splash listens on its default port, 8000, which `tailscale serve` forwards
  to.
- **Everything else is Splash's default.** On this Mac that means a context of
  262,144 tokens, the model's native window; an INT8 KV cache; Neural Engine
  prefill; an SSD prompt cache of up to 32 GiB in `$TMPDIR`, gone when the
  engine exits; the weights released after 10 idle minutes and restored by the
  next request, which then waits about 6 s more; Qwen's sampling
  (temperature 1.0, top_p 0.95, top_k 20) for requests that set none; up to 32
  requests admitted at once; the chat page at `/`; and the Mac kept awake while
  requests run. Each start asks Hugging Face for the model's newest commit, in
  one request of at most 5 s, and follows it. `--revision <commit>` would pin
  it; this setup does not.
- **The key reaches Splash in its environment.** The LaunchAgent runs
  `/bin/sh -c`, which reads the key file into `SPLASH_API_KEY` and `exec`s
  `splash-m1 serve`, so the key is never on a command line or in the plist.
  Splash checks `Authorization: Bearer` or `x-api-key` on every route except
  `/health`, `/ready` and the chat page. `/health` says only
  `{"status":"ok"}`, and `/ready` answers 200 once the model is ready. The chat
  page loads without the key, sends nothing until you enter it, and does not
  keep it *(sourced)*. Splash reads the key once, when it starts.
- **Splash listens only on 127.0.0.1**, its default. `tailscale serve` is the
  only way in, and it adds TLS and limits it to your tailnet.
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
  ([docs/omarchy-desktop.md](docs/omarchy-desktop.md), step 2) work once you are
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

Checks the tailnet (and that Funnel is off), that Splash's LaunchAgent is
loaded in your session and Splash runs as you, not as root, that nothing
listens beyond loopback, the API key with both headers (and wrong, empty and
missing keys), what `/health` reveals, the model ID clients see, and the
hardening. It exits non-zero if anything fails.

---

## 8. Connect your tools

**On each device that will use it:**

1. **Join the tailnet** with the Tailscale login your policy names (step 2).
   Another login, or a device shared in from another tailnet, gets nothing
   until you add it to the policy.
2. **Copy the key**, the one line of `~/.config/llm-server/api-key` on the
   server, through a password manager, or over SSH on the tailnet. Keep it
   where only you can read it, not in shell history or a repository.
3. **Check it:**

   With the key saved, alone, in a file only you can read (here
   `~/.config/llm-server/api-key`), so it reaches curl on stdin rather than its
   command line or your shell history:

   ```sh
   printf 'header = "Authorization: Bearer %s"\n' "$(cat ~/.config/llm-server/api-key)" \
     | curl -sf -K - https://<machine>.<tailnet>.ts.net/v1/models
   ```

   `"id": "mlx-community/Qwen3.8-27B-4bit"` means the tailnet, TLS, the key and
   Splash all work.

Base URL `https://<machine>.<tailnet>.ts.net/v1` (Anthropic clients take it
without `/v1`), model `mlx-community/Qwen3.8-27B-4bit`, API key as above.
Splash applies Qwen's sampling settings when a client sends none, and the
model thinks before answering: allow 16K+ output tokens, or a reply that runs out while thinking
comes back empty. **Tell clients the context window**, 262,144 tokens here, or
less, so they compact before reaching it. `/v1/models` reports it as
`context_length`.

**Which tools work** (Splash 1.3.2-m1.1, Qwen3.8-27B). All four work. What
was checked, on the Mac and from another machine
([findings](docs/findings.md#the-server-splash-for-m1m2-and-qwen38-27b)):

| Client | API it uses | Checked |
|---|---|---|
| Claude Code | Anthropic Messages | Its request shapes: a system message in mid-conversation, and a JSON-schema title request. Claude Code 2.x itself, through `splash-m1 claude` on the Mac and from another machine with the client guide's setup: answered, with tool calls and their results passed correctly |
| Codex | Responses | Its request shapes: `include: ["reasoning.encrypted_content"]` with `store: false`, and a second turn that sends the output back. Codex itself, from another machine: worked over six turns |
| Hermes Agent, OpenCode, and other OpenAI chat-completions clients | `/v1/chat/completions` | The endpoint, in the speed comparison. Hermes and OpenCode from another machine: worked |

Under Claude
Code's large prompt the model can drift from a trivial instruction: on a first
attempt it explored the Mac with tool calls instead of answering, until it was
stopped. Splash's own launchers, `splash-m1 claude`, `codex`, `opencode`,
`hermes` and `pi`, connect only to a server on the same Mac. From another
machine, configure each tool by hand:
[docs/omarchy-client.md](docs/omarchy-client.md) has step-by-step
configurations for all four, with checks.

---

## 9. Running it

| | |
|---|---|
| Restart | `launchctl kickstart -k gui/$(id -u)/com.llmserver.splash` |
| Stop | `launchctl bootout gui/$(id -u)/com.llmserver.splash`; it starts again at your next login, or when you re-run `3-services.sh` |
| Status | `curl -s -o /dev/null -w '%{http_code}\n' 127.0.0.1:8000/ready` prints 200 once the model is ready; `grep -E 'Ready\|Done' ~/Library/Logs/llm-server/splash.log \| tail` shows when it became ready and the last requests |
| Job | `~/Library/LaunchAgents/com.llmserver.splash.plist` (from `config/com.llmserver.splash.plist`; change it by re-running `3-services.sh`) |
| Log | `~/Library/Logs/llm-server/splash.log` (Splash's output; nothing rotates it) |
| API key | `~/.config/llm-server/api-key` |
| Splash | `~/Library/Application Support/Splash-M1/<version>`, with `current` pointing at the newest; the command is `$(brew --prefix)/bin/splash-m1` |
| Splash's data | `~/Library/Application Support/Splash`: `models/` (links into the Hugging Face cache), `runtime/`, and `thinking.key` |
| Models | `~/.cache/huggingface/hub`: the model, 15 GB, and its draft, 3.6 GB |
| Prompt cache | Temporary files in `$TMPDIR`, up to 32 GiB, freed when Splash exits |
| Crash traces | `~/Library/Logs/Splash/crash`, only with `SPLASH_CRASH_TRACE=1` |
| Chat page | `https://<machine>.<tailnet>.ts.net/`, with the key |

**After a restart**, connect with Screen Sharing and log in: the server starts
with your session. The status command above prints 200 when it is ready, a
minute or two later.

**Update Splash.** The release is pinned in `scripts/lib.sh`, so `brew upgrade`
never changes it, and a new release is a change to this repository. Watch [the
port's releases](https://github.com/paperniuk/splash/releases), and read each
one's notes, especially for client support (step 8). To move to one, read its
`install-m1.sh` and take its SHA-256:

```sh
curl -fsSLO https://github.com/paperniuk/splash/releases/download/<version>/install-m1.sh
shasum -a 256 install-m1.sh
```

Set `SPLASH_VERSION` to the release's tag and `SPLASH_INSTALLER_SHA256` to that
SHA-256 in `scripts/lib.sh`, then:

```sh
sh scripts/1-install.sh
sh scripts/3-services.sh
```

`1-install.sh` installs the release beside the old one and points `splash-m1`
at it. The running server keeps the old version until it restarts.
`3-services.sh` restarts it, because the LaunchAgent names the pinned version,
then waits for the model and checks the endpoint. `splash-m1 --version` says
which version is installed. Older versions stay under `~/Library/Application Support/Splash-M1`
until you delete them. Clients need no change.

**Update Tailscale** with Homebrew, `brew upgrade tailscale` or a routine
`brew upgrade`, then restart it: `sudo brew services restart tailscale`.

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

**Change the model.** Set `LLM_MODEL` in `config.env` and re-run
`3-services.sh`. It rewrites the LaunchAgent and restarts the server, which
downloads the new model and its draft at its first start. Clients must ask for
the new model's ID, and check the context window `/v1/models` reports.

**Rotate the key.** Delete `~/.config/llm-server/api-key` and re-run
`3-services.sh`. It makes a new key and restarts the server, because Splash
reads the key only when it starts; the endpoint is down until the model is
back, a minute or two. Then update your clients. If you change the file
instead of deleting it, restart the server yourself (the table above).

**Remove it.** `sudo sh scripts/uninstall.sh` turns off `tailscale serve`,
removes Splash's LaunchAgent, the hardening jobs and the SSH hardening (so SSH
accepts passwords again, the macOS default). It prints what it deliberately
left: models, key, logs, Splash itself, Tailscale, tailnet membership, power
settings. Splash's data folder, `~/Library/Application Support/Splash`, stays
too.

---

## Troubleshooting

| Symptom | Likely cause | Fix |
|---|---|---|
| `401` | Missing or wrong key | Check the header; the key is the line in `~/.config/llm-server/api-key`. Splash reads it only when it starts, so after changing the file, restart the server (step 9) |
| `403` "Host NAME is not allowed; restart the server with --allowed-host NAME" | The request names the server by a name it was not started with: a client uses another name, or the machine's tailnet name changed | Use `https://<machine>.<tailnet>.ts.net` in clients; after a rename, re-run `3-services.sh` |
| `502` from the endpoint | Splash is not running: after a restart, nobody has logged in | Log in over Screen Sharing, then check its status (step 9) |
| `503` `engine_recovering` | Splash's engine failed and is restarting; the message names the failure | Retry. If it fails three times soon after starting, Splash stops restarting it and answers `500` `engine_failed`: restart the server (step 9) and read the log |
| Empty answers | The model spent the reply's output limit thinking | Allow 16K+ output tokens (step 8), and ask for `medium` reasoning effort |
| `3-services.sh`: "something else listens on port 8000" | Another server uses the port | Stop the process the message names, then re-run `3-services.sh` |
| `Bootstrap failed: 5: Input/output error` | A launchd job was restarted too quickly | Re-run the script; it waits and retries |
