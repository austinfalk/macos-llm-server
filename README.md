# macos-llm-server

**A private model server on an Apple Silicon Mac.**

These scripts turn a Mac with 64 GB into a model server that your other
devices reach over [Tailscale](https://tailscale.com), with an API key and
nothing else exposed. It serves Inkling 2 Mini Uncensored on the Mac's GPU
with [mlx-serve](https://github.com/ddalcu/mlx-serve), which speaks the
OpenAI (chat completions, Responses), Anthropic (Messages) and Ollama APIs,
so coding agents and scripts can use it.

```
  laptop, phone, CI ──Tailscale──▶ tailscale serve :443 ──▶ mlx-serve 127.0.0.1:8000
                                   TLS, tailnet only        API key, model on the GPU
```

When you finish:

- mlx-serve runs in your login session as a LaunchAgent and restarts if it
  fails.
- The endpoint is reachable only from your tailnet, and only with the key.
  mlx-serve listens on loopback only, and Screen Sharing and SSH refuse the
  local network.
- The disk is encrypted with FileVault. After `sudo fdesetup authrestart` you
  log in over Screen Sharing on the tailnet, and the server starts. After a
  crash or power cut, someone types the password at the Mac.
- `sudo sh scripts/verify.sh` checks all of it.

## Requirements

| | |
|---|---|
| Mac | Apple Silicon with 64 GB, macOS 26.2 or later, an administrator account |
| Software | [Homebrew](https://brew.sh) in `/opt/homebrew`, Xcode 26.2 or later with its Metal toolchain, and a [Tailscale](https://tailscale.com) account |
| Disk | About 43 GB: 20 GB for the release, 17.5 GB for the converted model, 1 GB for the draft model, 4 GB for the build. Once converted, the release can be deleted, at the cost of downloading it again when an mlx-serve update reconverts |
| Time | About 10 minutes to build, plus the 20 GB download |

**What runs.** Three pinned parts, each chosen by measurement on an M1 Max
([findings](docs/findings.md)):

- **mlx-serve** at upstream's tag **26.11.4-pre-release.1**, built from source
  the way upstream builds its releases, with two patches.
  [`patches/inkling2-m1.patch`](patches/inkling2-m1.patch), from
  [namp/mlx-serve-inkling2-m1](https://github.com/namp/mlx-serve-inkling2-m1),
  adds FP16, fused 4-bit-KV attention and drafting for M1 and M2 GPUs, and
  fixes where streamed reasoning goes. The repo carries it as a diff against
  upstream, so it can be dropped once upstream ships the same.
  [`patches/inkling2-m1-speed.patch`](patches/inkling2-m1-speed.patch), this
  repo's own, goes on top: it hands each draft round to the GPU while the rest
  of it is built, and lets a span copied from the prompt verify 16 rows at any
  context, which needed a fix to the fused attention past 8 rows.
- **The model:** [OpenUncensored's Inkling 2 Mini
  Uncensored](https://huggingface.co/OpenUncensored/Inkling-2-Mini-Uncensored),
  Thinking Machines' Inkling 2 Mini with refusals ablated: a looped mixture of
  experts with 26.4B parameters, 3.4B of them active per token, reading text
  and images. It is pinned by revision and checksum.
- **The draft model:** Inco's [DFlash 2 drafter for Inkling 2
  Mini](https://huggingface.co/incoai/Inkling-2-Mini-DFlash2), 1 GB, pinned the
  same way. It proposes the tokens the model checks several at a time, which
  keeps the output exact.
- **The pack:** upstream's converter turns the release into an MLX pack,
  keeping the experts' released bytes and quantizing attention to 4 bits and
  the embedding and head to 6. It scores 0.019 KL divergence against the
  release and 94% top-1 agreement.

**Expect it to be private, not fast.** On the M1 Max it reads a new prompt at
about 420 tokens a second up to 10K tokens, 380 at 30K, 275 at 129K and 200 at 242K,
and writes 57 tokens a second, 46 at 36K tokens deep and 40 at 71K. An
agent's first turn takes 20-50 s, and follow-ups start in under a second,
because mlx-serve caches the conversation, two long ones at once. An M2
takes the same patched paths, and an M3 or later upstream's own; neither is
measured here.
Local suits code that must not leave the machine, batch and overnight work,
and a private endpoint for your scripts.

## Setup

Run every command from the repository's folder on the Mac. Each script checks
its own result and stops with the fix if something is wrong. Each one is safe
to run again.

**If you are an agent:** run steps 1, 3 and 5 yourself. Hand steps 2, 4, 6 and
7 to the user, with each command and what it should print: they need the
Tailscale admin console, a browser login, System Settings or sudo. Step 3
builds for 10 minutes and downloads 20 GB, so run it in the background. If it
is interrupted, run it again: it picks up where it stopped.

### 1. Get the repository

`git clone` it anywhere and `cd` into it. To change a setting, copy
`config.env.example` to `config.env` and edit it. Every setting is explained
there and has a working default.

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

Install Xcode from the App Store if it is missing, open it once, then fetch
its Metal toolchain, which building MLX needs:

```sh
xcodebuild -downloadComponent MetalToolchain
```

Optional: a Hugging Face **read** token in `~/.cache/huggingface/token` lifts
the rate limit on anonymous downloads. Paste it after this command, then press
Ctrl-D:

```sh
( umask 077; mkdir -p ~/.cache/huggingface && cat > ~/.cache/huggingface/token )
```

Then:

```sh
sh scripts/1-install.sh
```

As your normal user, not sudo. It:

1. checks the chip, memory, macOS and Xcode;
2. installs `tailscale`, `cmake`, `webp` and `python@3.12` from Homebrew;
3. builds mlx-serve: it fetches the pinned tag and checks its commit, stages
   Zig after checking its checksum, runs upstream's MLX and libllama scripts
   and checks the library they stage, applies the patch, builds, and lays the
   result out in `~/.mlx-serve/builds/<build>` as upstream's release does;
4. downloads the model's files at the pinned revision into
   `~/.mlx-serve/models/OpenUncensored/Inkling-2-Mini-Uncensored`, eight
   ranges at a time, and checks each one's checksum;
5. converts it with upstream's converter, in a Python environment whose
   packages are pinned by hash, into
   `~/.mlx-serve/models/local/Inkling-2-Mini-Uncensored-q4attn`.

It keeps `~/.mlx-serve` out of Time Machine. If the Tailscale app is
installed, the script warns you. This setup runs Homebrew's `tailscaled`
instead, so quit and remove the app.

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
replaces it and the tailnet drops while it restarts. The script finishes even
if an SSH session drops with it.

### 5. Start the server

```sh
sh scripts/3-services.sh
```

As yourself, not sudo. It generates the API key, installs the generation
defaults and the LaunchAgent, waits for the model to load, publishes it with
`tailscale serve`, and checks that a request with the key gets 200 and one
without gets 401.

It prints what clients need:

- Endpoint: `https://<machine>.<tailnet>.ts.net/v1`, with `:PORT` after the
  name if you set `LLM_HTTPS_PORT`
- Model: `Inkling-2-Mini-Uncensored-q4attn`
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
mlx-serve build, that mlx-serve runs as you and not root, the generation
defaults, that mlx-serve listens on loopback only, the key (right, wrong,
empty, missing, both headers), what `/health` reveals, the model ID, that a
two-turn question gets the right answer, FileVault, pf and SSH. It exits
non-zero on any failure.

### 8. Connect clients

Follow [`docs/clients.md`](docs/clients.md) on each client device. Steps 1-2
join the tailnet and copy the key, step 3 configures OpenCode, and step 4
checks it. The guide also says what any other OpenAI or Anthropic client
needs.

## Running it

| | |
|---|---|
| Status | `curl -s -o /dev/null -w '%{http_code}\n' 127.0.0.1:8000/health` prints 200 when the model is ready, 503 while it loads |
| Restart | `launchctl kickstart -k gui/$(id -u)/com.llmserver.mlx-serve` |
| Stop | `launchctl bootout gui/$(id -u)/com.llmserver.mlx-serve`. It starts again at your next login or `3-services.sh` |
| Log | `~/Library/Logs/llm-server/mlx-serve.log`. Nothing rotates it |
| LaunchAgent | `~/Library/LaunchAgents/com.llmserver.mlx-serve.plist`, from `config/com.llmserver.mlx-serve.plist`. Change it by re-running `3-services.sh` |
| API key | `~/.config/llm-server/api-key` |
| mlx-serve | `~/.mlx-serve/builds/<build>`, one folder per tag and patch, beside the source in `~/.mlx-serve/builds/src`, the converter's Python in `~/.mlx-serve/builds/venv`, and `build.log` |
| Model | `~/.mlx-serve/models/local/Inkling-2-Mini-Uncensored-q4attn`, converted from `~/.mlx-serve/models/OpenUncensored/Inkling-2-Mini-Uncensored` |
| Console | The endpoint without `/v1`, such as `https://<machine>.<tailnet>.ts.net/`. It asks for the key |

**After a restart**, log in over Screen Sharing. The server starts with your
session and answers once the model has loaded, in about 4 s. For a planned
restart, use `sudo fdesetup authrestart`, which unlocks FileVault once, so the
Mac reaches the login window with the tailnet up. After a crash or power cut,
FileVault waits for the password at the Mac itself.

### Update mlx-serve

Read the [release notes](https://github.com/ddalcu/mlx-serve/releases) first,
especially anything about Inkling, M1 and M2, or the flags the LaunchAgent
passes. Then:

1. In `scripts/pins.sh`, set `MLX_SERVE_TAG` to the new tag and
   `MLX_SERVE_COMMIT` to the commit it points to
   (`git ls-remote https://github.com/ddalcu/mlx-serve.git refs/tags/<tag>`).
   If upstream's `fetch-zig.sh` or `fetch-llama.sh` changed version, set
   `ZIG_VERSION` and `ZIG_SHA256` from
   [ziglang.org](https://ziglang.org/download/), and expect
   `1-install.sh` to stop at the new libllama's checksum: check the release
   it came from, then set `LLAMA_DYLIB_SHA256` to the checksum it prints.
2. Run `sh scripts/check-patch.sh`. If a patch no longer applies, rebase
   it on the new tag, namp's first. Drop each part upstream now ships: compare upstream's
   M1 decode and follow-up numbers with the patched build's, and if
   upstream matches, delete the patch.
3. Run `sh scripts/1-install.sh`, which builds beside the running version,
   then `sh scripts/3-services.sh`, which restarts the server onto it, and
   `sudo sh scripts/verify.sh`.
4. Measure it as `docs/findings.md` describes, and record the result there.

To go back, put the previous values in `scripts/pins.sh` and run
`1-install.sh` and `3-services.sh` again. The old build's folder is still in
`~/.mlx-serve/builds`, so nothing is rebuilt.

### Other changes

- **Tailscale:** `brew upgrade tailscale`, then `sudo sh scripts/2-tailscale.sh`,
  which copies the new daemon into place. The tailnet drops while it restarts.
- **HTTPS port:** set `LLM_HTTPS_PORT` (such as `8443`) and re-run
  `3-services.sh`. It moves the endpoint off the old port. Client URLs then
  carry the port.
- **Rotate the key:** delete `~/.config/llm-server/api-key`, re-run
  `3-services.sh`, then update clients. mlx-serve reads the key only at start.
- **Remove it:** `sudo sh scripts/uninstall.sh` removes the LaunchAgent,
  `tailscale serve`, the hardening jobs, pf rules and SSH settings. It lists
  what it leaves on purpose: models, builds, settings, key, logs, Homebrew
  packages, Tailscale, power settings and FileVault.

## How it works

The command-line build of mlx-serve ships no service manager, so
`3-services.sh` renders
[`config/com.llmserver.mlx-serve.plist`](config/com.llmserver.mlx-serve.plist)
into `~/Library/LaunchAgents`. launchd runs mlx-serve in your login session,
where macOS gives it the GPU. The LaunchAgent passes these flags and leaves
everything else at mlx-serve's defaults
([findings](docs/findings.md#settings)):

- `--model ~/.mlx-serve/models/local/Inkling-2-Mini-Uncensored-q4attn`.
  mlx-serve names the model after the folder.
- `--host 127.0.0.1`, because mlx-serve listens on every interface by default.
  `tailscale serve` is the only way in.
- `--port 8000`, where `tailscale serve` sends requests.
- `--api-key-env MLX_SERVE_API_KEY`. The LaunchAgent's shell reads the key
  file into that variable and then starts mlx-serve, so the key is never on a
  command line or in the plist. The shell refuses to start mlx-serve with an
  empty key, which would leave it open.
- `--api-key-strict`. By default mlx-serve lets requests from loopback in
  without the key, and `tailscale serve` connects from loopback, so without
  this flag the whole tailnet would get in without the key.
- `--ctx-size 262144`, a fixed window, so clients can configure it.
- `--prefix-cache-mem 24GB`, so long conversations stay cached.
- `--prefill-chunk 4096`, which reads as fast as larger chunks and keeps
  follow-ups at 242K tokens cached.
- `--kv-quant 4`, which makes decode faster from 8K tokens up, by 22% at
  129K.
- `--log-file off`. launchd writes mlx-serve's output to the log already.

It also sets two MLX variables, `MLX_MAX_MB_PER_BUFFER=1000000` and
`MLX_MAX_OPS_PER_BUFFER=100`. MLX's defaults close a GPU command buffer after
every expert projection, and the GPU waits between buffers; larger buffers
make decode about 13% faster ([findings](docs/findings.md#command-buffers)).

A request that names no reasoning effort thinks at `high`, the default
Thinking Machines ship in Inkling's chat template. Clients such as OpenCode
name none. A request that names an effort keeps it
([findings](docs/findings.md#reasoning-effort)).

mlx-serve checks the key, as `Authorization: Bearer` or `x-api-key`, on every
route except `/health` (which says only `{"status":"ok"}`) and CORS preflight.
Its console at `/` shows a login page until you enter the key. mlx-serve does
not check the Host header, so a web page that points its name at 127.0.0.1
can reach it from a browser on this Mac. Such a page still needs the key. The
key protects the network side: anything running on the Mac as you can read
it.

## Troubleshooting

| Symptom | Cause | Fix |
|---|---|---|
| `401` | Missing or wrong key | Use the line in `~/.config/llm-server/api-key`. After changing the file, restart the server |
| `502` | mlx-serve is not running, usually because nobody logged in since a restart | Log in over Screen Sharing, then check the status |
| `503` `loading` | The model is still loading | Wait, then retry |
| `/health` answers `503` `gpu context lost` | The GPU failed under mlx-serve | Restart the server and read the log |
| Empty answers | The model used the client's whole output limit thinking | Raise the client's output limit to 32,768 |
| `1-install.sh` stops at "no Metal compiler" | Xcode or its Metal toolchain is missing | Install Xcode, open it once, run `xcodebuild -downloadComponent MetalToolchain` |
| `1-install.sh` stops at a checksum | A download differs from its pin | Run it again. If it stops again, upstream changed the file: read why before you change the pin |
| "something else listens on port 8000" | Another server has the port | Stop the process the message names, then re-run `3-services.sh` |
| `Bootstrap failed: 5: Input/output error` | A launchd job restarted too quickly | Re-run the script, which waits and retries |
