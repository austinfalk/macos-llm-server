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

This guide runs Splash on its defaults, apart from the LaunchAgent and the
default reasoning effort (step 5), and defers to the published measurements of
Splash and its M1/M2 port. What was measured on this guide's machine is in
[`docs/findings.md`](docs/findings.md).

---

## Before you start

**Hardware.** A Mac with an M1 or M2 chip. Splash itself runs on M3 and newer
only. [paperniuk/splash](https://github.com/paperniuk/splash) is an unofficial
community port that adds Metal kernels for M1 and M2 GPUs. Its author tested it
on an M1 Max and not on an M2 *(sourced)*. On an M3 or newer, use official
Splash (`brew install incoai/tap/splash`) instead, because `1-install.sh`
refuses any chip but an M1 or M2. Memory decides which models you can run.
Splash sizes its memory and context at startup, and stops if the model does
not fit. The model used here needs at least 36 GB of unified memory, 48 GB
recommended *(sourced)*. This guide has measured only a 64 GB Mac.

**Set expectations.** A local model is private, not fast. On an M1 Max, the
model used here reads a new prompt at about 150-185 tokens a second and writes
at about 23-38, slower as a conversation grows. An agent's first turn takes a
minute or two. Follow-ups start in 1-2 s, because the server caches the
conversation. Hosted models run far faster. Local suits code that cannot leave
the building, batch and overnight jobs, and a private endpoint for your own
scripts ([findings](docs/findings.md#context-is-local-worth-it-sourced)).

**You need** macOS 26.4 or later, an administrator account on the Mac,
[Homebrew](https://brew.sh), a [Tailscale](https://tailscale.com) account,
about an hour, and room for the model download, about 19 GB.

**Get this repository onto the Mac**, anywhere you like. Optionally copy
`config.env.example` to `config.env` and change settings. Every setting has a
working default, and the file explains each one.

---

## 1. Choose a model

Splash serves two model families, Qwen3.8-27B and Qwen3.6-35B-A3B, in several
quantizations: MLX checkpoints of 2 to 8 bits, Unsloth's GGUF variants of 1 to
8 bits, NVFP4, and Prism ML's 2-bit Ternary Bonsai 2 (7.2 GB) *(sourced)*.
Splash pairs each with the DFlash2 draft model trained for its family, which
makes it write faster.

The default here is **Qwen3.8-27B** in MLX 4-bit,
`mlx-community/Qwen3.8-27B-4bit`, the checkpoint the port's release notes name.
It scores 34 on the [Artificial Analysis Intelligence
Index](https://artificialanalysis.ai/) v4.3.2, which changes over time, against
18 for Qwen3.6-35B-A3B *(sourced)*. The 35B-A3B is a mixture of experts with 3B
parameters active per token, so it writes faster, at a large cost in quality
([findings](docs/findings.md#the-server-splash-for-m1m2-and-qwen38-27b)).

To serve another, set `LLM_MODEL` in `config.env` to what Splash's `--model`
takes: an MLX repository, such as `mlx-community/Qwen3.6-35B-A3B-4bit`, or a
GGUF repository and variant, `OWNER/REPO:VARIANT`, such as
`unsloth/Qwen3.8-27B-GGUF:UD-Q4_K_M`. [Splash's model
list](https://github.com/incoai/splash#models) links the variants. Smaller ones
fit Macs with less memory. None was measured here.

---

## 2. Prepare the tailnet

In the [Tailscale admin console](https://login.tailscale.com/admin):

1. **DNS** → turn on **MagicDNS** and **HTTPS Certificates**. The server's TLS
   comes from these. Certificates are public record, so the machine's tailnet
   name appears in Certificate Transparency logs.
2. **Access controls** → edit [`config/tailscale-policy.hujson`](config/tailscale-policy.hujson),
   replacing `YOUR-LOGIN` with your login from the Users page, and paste it in.
   Pasting **replaces** your tailnet's whole policy. The policy lets the machine
   carry the `tag:llm-server` tag, and makes the tailnet **default-deny**, so
   you get in only on the ports the template lists. If other devices on your
   tailnet need to reach each other, add grants for them.
3. **Settings → Device management** → turn on **Device approval**, so a leaked
   auth key is not enough to join.

---

## 3. Install the software

As your normal user:

```sh
sh scripts/1-install.sh
```

The script checks for an M1 or M2 and macOS 26.4 or later, installs
`tailscale` from Homebrew and Splash's M1/M2 port from its release, and keeps
the model cache out of Time Machine. If the Tailscale app is installed, the
script warns you. This setup runs Homebrew's `tailscaled` instead, and running
both has not been tested.

**Which Splash.** `1-install.sh` downloads the port's release installer,
`install-m1.sh`, for the pinned version (`SPLASH_VERSION` in `scripts/lib.sh`),
and runs it only if its SHA-256 is `SPLASH_INSTALLER_SHA256`. The installer
checks the release archive's SHA-256, installs the `splash-m1` command (step 9
lists where things go), and leaves an official `splash` alone. Because of the
pin, `brew upgrade` never changes Splash. A new release is a step you take
(step 9).

**Optional: a Hugging Face token.** Models download from Hugging Face, which
rate-limits anonymous downloads. Create a **read** token (Settings → Access
Tokens), keep it in your password manager, and put it where Hugging Face's
tools look. This command copies it from 1Password without showing it:

```sh
( umask 077; mkdir -p ~/.cache/huggingface && op read "op://Private/<item>/<field>" > ~/.cache/huggingface/token )
```

---

## 4. Join the tailnet

```sh
sudo sh scripts/2-tailscale.sh
```

The script runs Tailscale as a system daemon, so the tailnet is up at boot,
before anyone logs in, and you can reach the login window remotely. The first
time, it prints a login URL. Open it, and approve the machine in the admin
console. The script joins with the `tag:llm-server` tag, and tagged devices
never have their keys expire. It also makes your account Tailscale's operator,
so step 5 needs no sudo, and checks that HTTPS certificates are available.

---

## 5. Start the server

As yourself, not sudo:

```sh
sh scripts/3-services.sh
```

The script generates an API key, installs a LaunchAgent that runs Splash, waits
for the model, and publishes it on your tailnet. Then it **checks the
endpoint**. A request with the key must get 200, and one without must get 401.
The first start downloads the model and its draft, about 19 GB, prepares the
weights, and times this Mac's Neural Engine against its GPU. That can take half
an hour, and the script waits up to an hour. Later starts take a minute or two.
You can re-run the script at any time. It restarts the server only when its
settings change.

Your endpoint is `https://<machine>.<tailnet>.ts.net/v1`, and the model ID
clients use is `mlx-community/Qwen3.8-27B-4bit`. The key is the one line of
`~/.config/llm-server/api-key`.

**How it runs.** Splash ships no service manager, so `3-services.sh` fills in
`config/com.llmserver.splash.plist` and installs it as
`~/Library/LaunchAgents/com.llmserver.splash.plist`. launchd runs Splash in
your login session, where macOS gives it the GPU and the Neural Engine. It
starts Splash at login, stops it at logout, and starts it again if it fails.
Splash's output goes to `~/Library/Logs/llm-server/splash.log`. The LaunchAgent
runs `splash-m1 serve` with three flags
([findings](docs/findings.md#the-server-splash-for-m1m2-and-qwen38-27b) has
the reasons):

- `--model mlx-community/Qwen3.8-27B-4bit` (`LLM_MODEL`) is the model, and the
  ID clients use. Splash adds its draft, `incoai/Qwen3.8-27B-DFlash2`, without
  a flag.
- `--allowed-host <machine>.<tailnet>.ts.net` lets in the requests that
  `tailscale serve` passes on. Splash answers 403 to any other Host name, a
  guard against DNS rebinding. The script reads the name from Tailscale.
- `--default-reasoning-effort medium` sets the effort to `medium`, not the
  template's `xhigh`, for chat completions and Responses requests that name
  none.

Everything else is Splash's default, including its port, 8000, which
`tailscale serve` forwards to. At each start, Splash also follows the model's
newest commit on Hugging Face. This setup does not pin one with `--revision`.

**The key reaches Splash in its environment.** The LaunchAgent runs
`/bin/sh -c`, which reads the key file into `SPLASH_API_KEY` and `exec`s
`splash-m1 serve`, so the key is never on a command line or in the plist.
Splash reads it once, when it starts. It checks `Authorization: Bearer` or
`x-api-key` on every route except `/health`, `/ready` and the chat page.
`/health` says only `{"status":"ok"}`, and `/ready` answers 200 once the model
is ready. The chat page loads without the key, sends nothing until you enter
it, and does not keep it *(sourced)*.

**Splash listens only on 127.0.0.1**, its default. `tailscale serve` is the
only way in, and it adds TLS and limits access to your tailnet.

**The key guards the network, not the machine.** Anything running on the Mac
as you can read the key file.

---

## 6. Harden the machine

```sh
sudo sh scripts/4-harden.sh
```

- **Automatic login.** The script turns it off and removes `/etc/kcpassword`,
  which stores the login password with a published, reversible obfuscation.
  After a restart, you log in yourself, over Screen Sharing (below).
- **SSH.** If Remote Login is on, SSH accepts keys only, and only from the
  tailnet unless you set `LLM_SSH_TAILNET_ONLY=no`. Tailscale's access rules do
  not cover your local network, so without this your SSH password is open to
  anything on the LAN. If your account has no SSH key installed, the script
  stops before it changes SSH, rather than lock you out. Add a key to
  `~/.ssh/authorized_keys` and re-run.
- **Power.** Desktops never sleep, and restart after a power failure where the
  hardware supports it. Laptops never sleep on mains power, and a watchdog
  **shuts down cleanly at 15% battery** instead of dying and losing memory. On
  battery, a laptop still sleeps when idle, and the server with it, unless you
  set `LLM_DISABLE_SLEEP=yes` (below). Apple documents that Apple Silicon
  laptops power back on when mains power returns. This guide has not tested it.
- **AirPlay Receiver.** If it is on, the script warns you, because it listens
  on ports 5000 and 7000 on every network. Unless you use it, turn it off in
  System Settings → General → AirDrop & Handoff.
- **Screen Sharing, tailnet only.** Screen Sharing (port 5900), the Kerberos
  port its sign-in can use (88), and Sunshine listen on every network. The
  script installs pf rules, reloaded at every boot, that drop their ports
  unless the connection comes from the tailnet
  ([findings](docs/findings.md#security)). Screen Sharing is how you log in
  after a restart, so turn it on: System Settings → General → Sharing →
  **Screen Sharing**, **Allow access for: Only these users** (your account),
  and **"VNC viewers may control screen with password"** off, because that
  password is an old 8-character scheme.
  [docs/omarchy-desktop.md](docs/omarchy-desktop.md) covers the clients, and
  Sunshine for smoother video once you are logged in.

**FileVault is your decision.** With it **off**, the Mac reaches the login
window by itself after any restart, and you log in over Screen Sharing, but
anyone holding the machine can read the disk. With it **on**, the disk is
protected, but after an unplanned restart the Mac waits at FileVault's unlock
screen, with no network, until someone types the password at the machine. For
planned restarts, `sudo fdesetup authrestart` unlocks the next boot once. A
desktop in a locked room and a laptop that travels deserve different answers.

**Laptops with the lid shut.** Closing the lid normally sleeps a laptop. To
keep it serving, set `LLM_DISABLE_SLEEP=yes` in `config.env` and re-run
`4-harden.sh`, which then applies `pmset -a disablesleep 1`. That setting is
undocumented and system-wide, battery included. The default, `no`, sets it
back to `0`. On mains power, with the lid shut, this guide's Mac served
requests for hours without sleeping
([findings](docs/findings.md#unattended-operation)). On battery it has not
been tested.

---

## 7. Verify

Logged in on the Mac:

```sh
sudo sh scripts/verify.sh
```

The script checks the tailnet (and that Funnel is off), that Splash's
LaunchAgent is loaded in your session and Splash runs as you, not as root, that
nothing listens beyond loopback, the API key with both headers (and wrong,
empty and missing keys), what `/health` reveals, the model ID clients see, and
the hardening. It exits non-zero if anything fails.

---

## 8. Connect your tools

**On each device that will use it:**

1. **Join the tailnet** with the Tailscale login your policy names (step 2).
   Another login, or a device shared in from another tailnet, gets nothing
   until you add it to the policy.
2. **Copy the key**, the one line of `~/.config/llm-server/api-key` on the
   server, through a password manager, or over SSH on the tailnet. Keep it
   where only you can read it, not in shell history or a repository.
3. **Check it.** With the key saved, alone, in a file only you can read (here
   `~/.config/llm-server/api-key`), this command passes it to curl on stdin,
   not on its command line or in your shell history:

   ```sh
   printf 'header = "Authorization: Bearer %s"\n' "$(cat ~/.config/llm-server/api-key)" \
     | curl -sf -K - https://<machine>.<tailnet>.ts.net/v1/models
   ```

   `"id": "mlx-community/Qwen3.8-27B-4bit"` means the tailnet, TLS, the key and
   Splash all work.

Clients need the base URL `https://<machine>.<tailnet>.ts.net/v1` (Anthropic
clients take it without `/v1`), the model `mlx-community/Qwen3.8-27B-4bit`, and
the key. Splash applies Qwen's sampling settings when a client sends none. The
model thinks before it answers, and the output limit counts the thinking, so a
reply that runs out while thinking comes back empty. The client guide's configs
allow 32,768 output tokens. **Tell clients the context window**, 262,144 tokens
here, or less, so they compact before reaching it. `/v1/models` reports it as
`context_length`.

**Which tools work.** Claude Code (Anthropic Messages), Codex (Responses), and
Hermes Agent and OpenCode (chat completions) all worked from another machine on
2026-10-18, with Splash 1.3.2-m1.1 and an earlier version of the client guide's
settings ([findings](docs/findings.md#the-server-splash-for-m1m2-and-qwen38-27b)).
Under Claude Code's large prompt, the model once explored the Mac with tool
calls instead of following a trivial instruction, until it was stopped.
Splash's own launchers, `splash-m1 claude`, `codex`, `opencode`, `hermes` and
`pi`, connect only to a server on the same Mac. From another machine, configure
each tool by hand. [docs/omarchy-client.md](docs/omarchy-client.md) has
step-by-step configurations for all four, with checks.

---

## 9. Running it

| | |
|---|---|
| Restart | `launchctl kickstart -k gui/$(id -u)/com.llmserver.splash` |
| Stop | `launchctl bootout gui/$(id -u)/com.llmserver.splash`. It starts again at your next login, or when you re-run `3-services.sh` |
| Status | `curl -s -o /dev/null -w '%{http_code}\n' 127.0.0.1:8000/ready` prints 200 once the model is ready. `grep -E 'Ready\|Done' ~/Library/Logs/llm-server/splash.log \| tail` shows when it became ready and the last requests |
| Job | `~/Library/LaunchAgents/com.llmserver.splash.plist`, rendered from `config/com.llmserver.splash.plist`. Change it by re-running `3-services.sh` |
| Log | `~/Library/Logs/llm-server/splash.log`, Splash's output, which nothing rotates |
| API key | `~/.config/llm-server/api-key` |
| Splash | `~/Library/Application Support/Splash-M1/<version>`, with `current` pointing at the newest. The command is `$(brew --prefix)/bin/splash-m1` |
| Splash's data | `~/Library/Application Support/Splash`: `models/` (links into the Hugging Face cache), `runtime/`, and `thinking.key` |
| Models | `~/.cache/huggingface/hub`: the model, 15 GB, and its draft, 3.6 GB |
| Prompt cache | Temporary files in `$TMPDIR`, up to 32 GiB, freed when Splash exits |
| Crash traces | `~/Library/Logs/Splash/crash`, only with `SPLASH_CRASH_TRACE=1` |
| Chat page | `https://<machine>.<tailnet>.ts.net/`, with the key |

**After a restart**, connect with Screen Sharing and log in. The server starts
with your session, and the status command above prints 200 a minute or two
later.

**Update Splash.** A new release is a change to this repository's pin in
`scripts/lib.sh`. Watch [the port's
releases](https://github.com/paperniuk/splash/releases), and read each one's
notes, especially for client support (step 8). To move to one, download its
`install-m1.sh`, read it, and take its SHA-256:

```sh
curl -fsSLO https://github.com/paperniuk/splash/releases/download/<version>/install-m1.sh
shasum -a 256 install-m1.sh
```

Set `SPLASH_VERSION` to the release's tag and `SPLASH_INSTALLER_SHA256` to that
SHA-256 in `scripts/lib.sh`, then run:

```sh
sh scripts/1-install.sh
sh scripts/3-services.sh
```

`1-install.sh` installs the release beside the old one and points `splash-m1`
at it. The running server keeps the old version until it restarts. The
LaunchAgent names the version in a comment, so a new pin changes the file that
`3-services.sh` renders. The script then restarts the server, waits for the
model, and checks the endpoint. `splash-m1 --version` prints the installed
version. Older versions stay under `~/Library/Application Support/Splash-M1`
until you delete them. Clients need no change.

**Update Tailscale** with Homebrew, `brew upgrade tailscale` or a routine
`brew upgrade`, then restart it with `sudo brew services restart tailscale`.
Because `sudo brew services` makes root own the running version's `bin/`, the
cleanup after the upgrade fails with "Could not cleanup old kegs". Once the
restart has moved the service to the new version, give the old one back to
your account and remove it:

```sh
sudo chown -R "$(whoami):admin" "$(brew --cellar tailscale)/OLD_VERSION"
brew cleanup tailscale
```

Leave the running version owned by root, because the daemon runs as root
([findings](docs/findings.md#security)).

**Change the model.** Set `LLM_MODEL` in `config.env` and re-run
`3-services.sh`. It rewrites the LaunchAgent and restarts the server, which
downloads the new model and its draft at its first start. Clients must ask for
the new model's ID, and check the context window `/v1/models` reports.

**Rotate the key.** Delete `~/.config/llm-server/api-key` and re-run
`3-services.sh`. It makes a new key and restarts the server, because Splash
reads the key only when it starts. The endpoint is down until the model is
back, a minute or two. Then update your clients. If you change the file
instead of deleting it, restart the server yourself (the table above).

**Remove it.** `sudo sh scripts/uninstall.sh` turns off `tailscale serve` and
removes Splash's LaunchAgent, the hardening jobs, the pf rules and the SSH
hardening, so SSH accepts passwords again, the macOS default. It prints what it
leaves in place on purpose: the models, the key, the logs, Splash and its data
folder, Tailscale and the tailnet membership, the power settings, and automatic
login, which stays off.

---

## Troubleshooting

| Symptom | Likely cause | Fix |
|---|---|---|
| `401` | Missing or wrong key | Check the header. The key is the line in `~/.config/llm-server/api-key`. Splash reads it only when it starts, so after changing the file, restart the server (step 9) |
| `403` "Host NAME is not allowed; restart the server with --allowed-host NAME" | The request names the server by a name it was not started with. A client uses another name, or the machine's tailnet name changed | Use `https://<machine>.<tailnet>.ts.net` in clients. After a rename, re-run `3-services.sh` |
| `502` from the endpoint | Splash is not running, usually because nobody has logged in since a restart | Log in over Screen Sharing, then check its status (step 9) |
| `503` `engine_recovering` | Splash's engine failed and is restarting. The message names the failure | Retry. If it fails three times soon after starting, Splash stops restarting it and answers `500` `engine_failed`. Restart the server (step 9) and read the log |
| Empty answers | The model spent the client's whole output limit thinking | Raise the client's output limit. The configs in [docs/omarchy-client.md](docs/omarchy-client.md) allow 32,768 tokens |
| `3-services.sh`: "something else listens on port 8000" | Another server uses the port | Stop the process the message names, then re-run `3-services.sh` |
| `Bootstrap failed: 5: Input/output error` | A launchd job was restarted too quickly | Re-run the script. It waits and retries |
