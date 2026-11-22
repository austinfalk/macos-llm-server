# macos-llm-server

**A private model server on an Apple Silicon Mac.**

These scripts turn a Mac with an M1 or later into a model server that your
other devices reach over [Tailscale](https://tailscale.com), with an API key
and nothing else exposed. The model runs on the Mac's GPU and Neural Engine
with [Splash](https://github.com/incoai/splash), which serves OpenAI
(chat completions, Responses) and Anthropic (Messages) APIs, so coding agents
and scripts can use it.

```
  laptop, phone, CI ──Tailscale──▶ tailscale serve :443 ──▶ Splash 127.0.0.1:8000
                                   TLS, tailnet only        API key, model on the GPU
```

When you finish:

- Splash runs in your login session as a LaunchAgent and restarts if it fails.
- The endpoint is reachable only from your tailnet, and only with the key.
  Splash listens on loopback only, and Screen Sharing and SSH refuse the local
  network.
- The disk is encrypted with FileVault. After `sudo fdesetup authrestart` you
  log in over Screen Sharing on the tailnet, and the server starts. After a
  crash or power cut, someone types the password at the Mac.
- `sudo sh scripts/verify.sh` checks all of it.

## Requirements

| | |
|---|---|
| Mac | Apple Silicon, macOS 26.4 or later, an administrator account |
| Memory | 48 GB or more for the default model. With less, pick a smaller one before step 5 ([Models](#models)) |
| Disk | About 25 GB for the model and its draft, plus Splash's SSD cache, which it sizes itself up to 32 GiB |
| Software | [Homebrew](https://brew.sh) in `/opt/homebrew`, its default on Apple Silicon, and a [Tailscale](https://tailscale.com) account |
| Time | About an hour, most of it the first download |

The scripts pick the Splash build for the chip:

| Chip | Build | Installed from |
|---|---|---|
| M3 or later | [Splash](https://github.com/incoai/splash), by Inco | Homebrew formula `incoai/tap/splash`, command `splash` |
| M1 or M2 | [paperniuk/splash](https://github.com/paperniuk/splash), an unofficial community port, because Splash refuses GPUs older than the M3's | The port's release installer, command `splash-m1` |

Each build is pinned by version and checksum in `scripts/variant.sh`, so
`brew upgrade` never moves it. Pinned now: Splash **1.7.0** and the port
**1.6.1-m1.1**. The port's 1.7.0-m1 was tried and rolled back because it wrote
nonsense in short conversations ([findings](docs/findings.md#upgrades)).
Everything measured here ran on an M1 Max with 64 GB. The M3-and-later path
follows Splash's own instructions but has not run on such a Mac here yet.

**Expect it to be private, not fast.** On the M1 Max the default model reads a
new prompt at about 160-235 tokens a second and writes 23-44, slower as a
conversation grows. An agent's first turn takes one to two minutes, and
follow-ups start in a second or two, because Splash caches the conversation.
Base M1 and M2 chips have fewer GPU cores and will be slower (not measured).
Newer chips read prompts much faster. Local suits code that must not leave the
machine, batch and overnight work, and a private endpoint for your scripts.

## Setup

Run every command from the repository's folder on the Mac. Each script checks
its own result and stops with the fix if something is wrong. Each one is safe
to run again.

**If you are an agent:** run steps 1, 3 and 5 yourself. Hand steps 2, 4, 6 and
7 to the user, with each command and what it should print: they need the
Tailscale admin console, a browser login, System Settings or sudo. Step 5 can
run for an hour on the first start, so run it in the background and follow
`~/Library/Logs/llm-server/splash.log`. If it is interrupted, run it again: it
waits for the server already starting.

### 1. Get the repository

`git clone` it anywhere and `cd` into it. To change a setting, copy
`config.env.example` to `config.env` and edit it. Every setting is explained
there. **On a Mac with less than 48 GB, do this now and set `LLM_MODEL` from
[Models](#models)**: the default model does not fit, and step 5 downloads
whatever `LLM_MODEL` names. Every other setting has a working default.

### 2. Prepare the tailnet

In the [Tailscale admin console](https://login.tailscale.com/admin):

1. **DNS**: turn on **MagicDNS** and **HTTPS Certificates**. Certificates are
   public, so the machine's tailnet name appears in Certificate Transparency
   logs.
2. **Access controls**: if the tailnet has no policy of its own yet, paste in
   [`config/tailscale-policy.hujson`](config/tailscale-policy.hujson), which
   **replaces** the whole policy. If it has rules you need, add only that
   file's grant to them. The grant lets each member's devices reach that
   member's other devices, the server included, and nothing else. To run the
   server as a tagged device instead, follow the comment at the end of the
   file and set `LLM_TAG`.
3. **Settings → Device management**: turn on **Device approval**.

### 3. Install

```sh
sh scripts/1-install.sh
```

As your normal user, not sudo. It checks the chip and macOS, installs
`tailscale` from Homebrew and the pinned Splash build, and keeps the model cache
out of Time Machine. It refuses a Splash whose version or checksum differs
from the pins. On an M3 or later, Homebrew's tap offers only the newest
Splash, so once Splash releases past the pin the script stops and says so.
Then follow [Update Splash](#update-splash) to pin the new release, or wait for
this repository to pin it.

If the Tailscale app is installed, the script warns you. This setup runs
Homebrew's `tailscaled` instead, so quit and remove the app.

Optional: a Hugging Face **read** token in `~/.cache/huggingface/token` lifts
the rate limit on anonymous downloads. Paste it after this command, then press
Ctrl-D:

```sh
( umask 077; mkdir -p ~/.cache/huggingface && cat > ~/.cache/huggingface/token )
```

### 4. Join the tailnet

```sh
sudo sh scripts/2-tailscale.sh
```

It copies `tailscaled` to `/usr/local/bin`, where only root can change it, and
runs it as a system daemon, so the tailnet is up at boot before anyone logs
in. The first time, it prints a login URL. Open it, log in, then approve the
machine on the admin console's **Machines** page. On the same page,
**disable key expiry** for it, or the endpoint drops off the tailnet when the
key expires. The script warns until you have. It also makes your account
Tailscale's operator, so the next step needs no sudo.

If the Mac ran Homebrew's `sudo brew services` tailscaled before, the script
replaces it and the tailnet drops for a few seconds. The script finishes even
if an SSH session drops with it.

### 5. Start the server

```sh
sh scripts/3-services.sh
```

As yourself, not sudo. It generates the API key, installs the LaunchAgent,
waits for the model, publishes it with `tailscale serve`, and checks that a
request with the key gets 200 and one without gets 401. The first start
downloads the model and its draft, about 19 GB, and times the Neural Engine
against the GPU. That can take half an hour, and the script waits up to an
hour. Later starts take a minute or two.

It prints what clients need:

- Endpoint: `https://<machine>.<tailnet>.ts.net/v1`, with `:PORT` after the
  name if you set `LLM_HTTPS_PORT`
- Model: `LLM_MODEL`, `mlx-community/Qwen3.8-27B-4bit` by default
- Key: the one line of `~/.config/llm-server/api-key`

Save the key in your password manager now, so client devices can copy it
without showing it ([client guide](docs/clients.md), step 2). To copy it over
SSH instead, turn on Remote Login (System Settings → General → Sharing) and
add your client's public key to `~/.ssh/authorized_keys` before step 6.

### 6. Harden

Turn on FileVault if it is off:

```sh
sudo fdesetup enable
```

Keep the recovery key it prints in your password manager. If it prints none,
the Mac kept an older key you may not have. Make a new one and check your copy:

```sh
sudo fdesetup changerecovery -personal
sudo fdesetup validaterecovery     # asks for the key, prints true
```

Turn on Screen Sharing, which is how you log in after a restart: System
Settings → General → Sharing → **Screen Sharing**, allow only your account,
and turn off **VNC viewers may control screen with password**. Turn off any
sharing service you do not use, and AirPlay Receiver (General → AirDrop &
Handoff). If you are connected over Screen Sharing from the local network,
reconnect over `<machine>.<tailnet>.ts.net` first: the pf rules drop
local-network Screen Sharing as soon as they load. Then:

```sh
sudo sh scripts/4-harden.sh
```

It limits Screen Sharing (5900) and Kerberos (88) to the tailnet with pf rules
that load at boot, makes SSH accept keys only and only from the tailnet (it
stops first if your account has no SSH key, so you are not locked out), and
keeps the Mac from sleeping on mains power. It warns if FileVault is off.

**Laptops.** Closing the lid sleeps the Mac, and a sleeping Mac stops serving.
To keep serving with the lid shut, set `LLM_DISABLE_SLEEP=yes` in `config.env`
and re-run `4-harden.sh`. It applies `pmset -a disablesleep 1`, which is
system-wide and includes battery, so it also installs a watchdog that shuts
the Mac down cleanly at 15% battery (`LLM_BATTERY_SHUTDOWN_PCT`). This was
tested on mains power only.

### 7. Verify

```sh
sudo sh scripts/verify.sh
```

Run it while logged in on the Mac, because the server runs in your login
session. It checks the tailnet (and that Funnel is off), the LaunchAgent, the
pinned Splash version, that Splash runs as you and not root, that Splash's
port listens on loopback only, the key (right, wrong, empty, missing,
both headers), what `/health` reveals, the model ID, that a two-turn question
gets the right answer, FileVault, pf and SSH. It exits non-zero on any
failure.

### 8. Connect clients

Follow [`docs/clients.md`](docs/clients.md) on each client device. Steps 1-2
join the tailnet and copy the key, step 3 configures OpenCode, and step 4
checks it. The guide also says what any other OpenAI or Anthropic client
needs. Splash's own launchers (`splash claude` and the others) reach only a
server on the same Mac.

## Models

Splash serves a few model families, Qwen3.8-27B and Qwen3.6-35B-A3B among
them, as MLX checkpoints and Unsloth GGUFs, and pairs each with its DFlash2
draft by itself ([Splash's model list](https://github.com/incoai/splash#models)).
Set `LLM_MODEL` in `config.env` to what `--model` takes.

| Mac memory | Model | Notes |
|---|---|---|
| 48 GB or more | `mlx-community/Qwen3.8-27B-4bit` (default) | Scores 34 on the Artificial Analysis Intelligence Index v4.3.2. Run here on 64 GB |
| 48 GB or more, for speed | `mlx-community/Qwen3.6-35B-A3B-4bit` | 3B parameters active per token, so the port writes about twice as fast, but it scores 18 *(sourced)* |
| 36-47 GB | The default may fit | Splash's README gave 36 GB as the 4-bit models' minimum and 48 GB as recommended, up to 1.4.0 *(sourced)*. Not run here |
| 24-32 GB | `unsloth/Qwen3.6-35B-A3B-GGUF:UD-Q2_K_XL` | Splash measured it on a 24 GB Mac with the full 256K context *(sourced)*. The port has not published a 24 GB measurement. Not run here |
| Under 24 GB | None | Not covered by Splash or this guide |

Splash sizes memory and context at start and stops with a message if the
model does not fit. A 27B GGUF small enough for 24 GB gets about 53K tokens of
context there, too little for coding agents *(sourced)*. The model is also the
model ID every client sends, so changing it means changing every client.

## Running it

| | |
|---|---|
| Status | `curl -s -o /dev/null -w '%{http_code}\n' 127.0.0.1:8000/ready` prints 200 when the model is ready |
| Restart | `launchctl kickstart -k gui/$(id -u)/com.llmserver.splash` |
| Stop | `launchctl bootout gui/$(id -u)/com.llmserver.splash`. It starts again at your next login or `3-services.sh` |
| Log | `~/Library/Logs/llm-server/splash.log`. Nothing rotates it |
| LaunchAgent | `~/Library/LaunchAgents/com.llmserver.splash.plist`, from `config/com.llmserver.splash.plist`. Change it by re-running `3-services.sh` |
| API key | `~/.config/llm-server/api-key` |
| Splash | M3+: `$(brew --prefix)/opt/splash`. M1/M2: `~/Library/Application Support/Splash-M1/<version>`, with `current` linking the version installed last |
| Splash's data | `~/Library/Application Support/Splash` |
| Models | `~/.cache/huggingface/hub` |
| Chat page | The endpoint without `/v1`, such as `https://<machine>.<tailnet>.ts.net/`. It asks for the key |

**After a restart**, log in over Screen Sharing. The server starts with your
session and is ready a minute or two later. For a planned restart, use
`sudo fdesetup authrestart`, which unlocks FileVault once, so the Mac reaches
the login window with the tailnet up. After a crash or power cut, FileVault
waits for the password at the Mac itself.

### Update Splash

Read the release notes first, especially anything about clients or flags the
LaunchAgent passes. Then change the build's block in `scripts/variant.sh`.

**M3 or later**, from [Splash's releases](https://github.com/incoai/splash/releases):

```sh
curl -fsSL https://github.com/incoai/splash/releases/download/<version>/SHA256SUMS
```

Set `SPLASH_VERSION` to the tag, `SPLASH_ARCHIVE_SHA256` to the checksum on
the `splash-<version>-arm64-macos26.tar.gz` line, and `SPLASH_BOTTLE_SHA256` to
the one on the `.bottle.tar.gz` line. With several bottles, list each checksum,
space-separated, in the order `brew info --json=v2 incoai/tap/splash` lists
them.
Then:

```sh
brew update && brew unpin splash
sh scripts/1-install.sh       # refuses unless the formula matches, then pins again
sh scripts/3-services.sh
```

If `1-install.sh` refuses, the tap has not caught up. Run `brew pin splash`
and try again later.

**M1 or M2**, from [the port's releases](https://github.com/paperniuk/splash/releases):

```sh
cd "$(mktemp -d)" && curl -fsSLO https://github.com/paperniuk/splash/releases/download/<version>/install-m1.sh
shasum -a 256 install-m1.sh   # must match the release notes. Read the script
```

Set `SPLASH_VERSION` to the tag and `SPLASH_INSTALLER_SHA256` to that
checksum. Then, back in the repository:

```sh
sh scripts/1-install.sh       # installs beside the old version
sh scripts/3-services.sh
```

Old versions stay in `~/Library/Application Support/Splash-M1` until you
delete them.

On either build, `3-services.sh` sees the new version in the LaunchAgent,
restarts the server onto it, waits for the model and checks the endpoint. A
new release recalibrates once, so the endpoint is down a few minutes.
Clients need no change.

Then run `sudo sh scripts/verify.sh`. Besides the status codes, it asks a
two-turn question and fails unless the answer is right. The status codes alone
passed on 1.7.0-m1, which wrote nonsense. If it fails on an M1 or M2, put the previous
values back in `scripts/variant.sh` and run the two scripts again: the old
version is still installed. On an M3 or later the tap offers only its newest
formula, so there is no scripted way back. Stop the server and wait for a
fixed release. Record the result in `docs/findings.md`.

### Other changes

- **Tailscale:** `brew upgrade tailscale`, then `sudo sh scripts/2-tailscale.sh`,
  which copies the new daemon into place. The tailnet drops for a few seconds.
- **Model:** set `LLM_MODEL` in `config.env`, re-run `3-services.sh`, and give
  clients the new model ID and context window.
- **HTTPS port:** set `LLM_HTTPS_PORT` (such as `8443`) and re-run
  `3-services.sh`. It moves the endpoint off the old port. Client URLs then
  carry the port.
- **Rotate the key:** delete `~/.config/llm-server/api-key`, re-run
  `3-services.sh`, then update clients. Splash reads the key only at start.
- **Remove it:** `sudo sh scripts/uninstall.sh` removes the LaunchAgent,
  `tailscale serve`, the hardening jobs, pf rules and SSH settings. It lists
  what it leaves on purpose: models, key, logs, Splash, Tailscale, power
  settings and FileVault.

## How it works

Splash ships no service manager, so `3-services.sh` renders
[`config/com.llmserver.splash.plist`](config/com.llmserver.splash.plist) into
`~/Library/LaunchAgents`. launchd runs Splash in your login session, where
macOS gives it the GPU and the Neural Engine. The LaunchAgent runs
`splash serve` (or `splash-m1 serve`) with three flags, two more on some M1
and M2 chips, and leaves everything
else at Splash's defaults:

- `--model mlx-community/Qwen3.8-27B-4bit`: the model, and the ID clients use.
  Splash adds its draft, `incoai/Qwen3.8-27B-DFlash2`, by itself.
- `--allowed-host <machine>.<tailnet>.ts.net`: Splash answers 403 to unknown
  Host names, a guard against DNS rebinding, so it must know the name
  `tailscale serve` passes on. The script reads it from Tailscale.
- `--default-reasoning-effort medium`: chat completions and Responses requests
  that name no effort get `medium` instead of the template's `xhigh`, which
  took far longer for a small gain and sometimes answered empty
  ([findings](docs/findings.md#reasoning-effort)).
- `--ane-ffn-share 0.68 --ane-ffn-minimum-rows 512`, on an M1 Max with the
  port's 1.6.1-m1.1 (0.88 on an M1 Pro, 0.53 on an M2 Max, none on other
  chips): prompts of 512 tokens or more read as a pair of chunks, the Neural
  Engine on one while the GPU works on the other, about a quarter faster on
  10K-token prompts and a little slower under 1K. The M1 Pro and M2 Max
  values are the port's; the M1 Max's was measured here, a little below the
  port's 0.735 ([findings](docs/findings.md#prefill-as-a-pair-of-chunks)).
  From 1.7.0-m1 the port times the pair itself, so the next bump drops them.

Splash listens on 127.0.0.1:8000, its default, so `tailscale serve` is the only
way in. The LaunchAgent's shell reads the key file into `SPLASH_API_KEY` and
then starts Splash, so the key is never on a command line or in the plist.
Splash checks `Authorization: Bearer` or `x-api-key` on every route except
`/health` (which says only `{"status":"ok"}`), `/ready` and the chat page,
which sends nothing until you enter the key. The key protects the network
side: anything running on the Mac as you can read it.

## Troubleshooting

| Symptom | Cause | Fix |
|---|---|---|
| `401` | Missing or wrong key | Use the line in `~/.config/llm-server/api-key`. After changing the file, restart the server |
| `403` "Host NAME is not allowed" | The client uses another name, or the machine was renamed | Use `https://<machine>.<tailnet>.ts.net`. After a rename, re-run `3-services.sh` |
| `502` | Splash is not running, usually because nobody logged in since a restart | Log in over Screen Sharing, then check the status |
| `503` `engine_recovering` | The engine failed and is restarting | Retry. After repeated failures Splash answers `500` `engine_failed`: restart the server and read the log |
| Empty answers | The model used the client's whole output limit thinking | Raise the client's output limit to 32,768 |
| "something else listens on port 8000" | Another server has the port | Stop the process the message names, then re-run `3-services.sh` |
| `Bootstrap failed: 5: Input/output error` | A launchd job restarted too quickly | Re-run the script, which waits and retries |
