# Using the server from an Omarchy (Linux) machine

How to connect an [Omarchy](https://omarchy.org) machine to the server, and
how to get the most out of it: the tailnet, the key, Hermes Agent and OpenCode
(which work today), Claude Code and Codex (ready for when TensorFold supports
them), the Mac's desktop, and SSH. Written to be followed step by step, by a
person or by a Claude Code session running in a clone of this repo on the
Omarchy machine. Researched against Omarchy 4.0.4, Claude Code's current docs,
Codex rust-v0.157.1, Hermes Agent 0.21.0 (as `hermes-desktop 2026.8.31-3`
installs it) and OpenCode 1.18.34, with the server on TensorFold's Python line,
0.6.5 and 0.6.6 (October 2026).

**If you are Claude Code following this:** do one step at a time and run its
check before the next. If a check fails, or a command, flag or config key does
not exist in the installed version, stop and tell the user: do not work around
it. Tools change fast: before relying on a setting, confirm it in that tool's
own docs or `--help` for the installed version. Never print the key, put it
on a command line, or write it anywhere except the one file in step 2. Anything
needing `sudo` or a GUI, hand to the user.

Throughout, `ENDPOINT` means `https://<machine>.<tailnet>.ts.net` — the server's
address, which `tailscale status` lists once step 1 is done. The server runs
[TensorFold](https://github.com/ashhart/TensorFold) with Qwen3.8-27B and its
DFlash2 drafter, which clients know as **`local-model`**, with a
**144,384-token context**: what the server reports at startup, the most one
request can use in its memory budget while keeping the prompt cached for the
next turn. Every API is under `ENDPOINT/v1`: OpenAI chat
completions and Responses, and Anthropic Messages. Three facts shape every
config below:

- **One model.** Every model setting, including background and helper models,
  names `local-model`. The server answers any model name with the one it runs,
  but naming it keeps each tool's records honest.
- **Sampling is the server's.** TensorFold applies the model's own defaults
  (temperature 1.0, top_k 20, top_p 0.95, as it reports at startup) to every
  API when a request leaves them out, so these configs set none.
- **Reasoning takes output.** The model thinks before answering, and the reply
  limit counts the thinking; allow 16K+ output tokens, and long timeouts. A
  reply cut off while still thinking comes back empty.

## How to use this server

### What works today

TensorFold 0.6 with Qwen3.8-27B, tested from this machine on 2026-10-03:

| Tool | Use it for | API | Status |
|---|---|---|---|
| **Hermes Agent** (desktop app and `hermes`) | General agent work: research, writing, running commands, long tasks you check on later | chat completions | **Works** (step 5) |
| **OpenCode** (`opencode`) | Coding in a repository, from the terminal | chat completions | **Works** (step 6) |
| Claude Code (`claude-local`) | Coding | Anthropic Messages | Refused by TensorFold with this model (step 3) |
| Codex (`codex-local`) | Coding | Responses | Refused by TensorFold with any model (step 4) |

Any other tool that speaks OpenAI chat completions should work the same way:
base URL `ENDPOINT/v1`, API key from step 2, model `local-model`.

Why the two refusals, in short (details in `docs/findings.md`, "The
server"):

- **Claude Code** sends system messages in the middle of a conversation.
  TensorFold's Anthropic endpoint keeps them where they are, which needs a
  model whose chat template accepts them, and Qwen3.8's does not ("System
  message must be at the beginning"). Its chat-completions endpoint turns them
  into user messages instead, so Hermes and OpenCode never hit this.
- **Codex** asks for encrypted reasoning on every request, which TensorFold
  refuses ("include is not supported"). Codex has no setting to stop asking.

Neither is a configuration mistake, and neither has a fix on this side short
of hacking the requests, which this setup does not do.

### Working well with it

- **The first turn is the slow one.** The server reads a cold prompt at about
  100 tokens a second — roughly 10 s per thousand tokens — and an agent's
  first prompt is 10-15K tokens of instructions and tool definitions: expect
  1½-2½ minutes before the first word. After that the server keeps the
  conversation cached and reads only what is new: a follow-up took 5.7 s end
  to end.
- **So keep conversations going.** One long session is much faster than many
  short ones. A new session, a changed system prompt, a different set of tools
  or skills, or editing an earlier message all make the server read from the
  first change onward.
- **Fewer tools, faster starts.** Every MCP server and tool adds its
  definition to every prompt. Turn off what a session does not need.
- **Writing runs at 15-20 tokens a second**, faster on code, where the draft
  model guesses well. A long answer with long thinking takes minutes. Hand it
  tasks you can walk away from rather than ones you watch line by line.
- **Choose how hard it thinks.** Most of a long turn is the model thinking
  (one step today thought for 11,777 tokens, 26 minutes). Qwen3.8's template
  knows three reasoning efforts: `low` ("keep your thinking brief"),
  `medium`, and `xhigh`, its default, which tells it to "think carefully ...
  validate key assumptions, consider plausible alternatives". The configs
  below ask for **`medium`** instead; in OpenCode, Ctrl+T switches per job
  (`opencode run --variant low|medium|high`), and TensorFold hears `high` as
  `xhigh`. Others' tests *(sourced, not run here)*: on agentic questions about
  a codebase, `medium` scored 8.18 against `xhigh`'s 8.61 in about half the
  time (76 s against 143 s median), and `low` was both worse and slower, its
  shorter thinking costing extra agent rounds (Kodesage, 45 questions, one
  run each). On four single-turn coding tasks `xhigh` took 2 h 36 min against
  `medium`'s 22 min, with no clear quality winner (Jose Romero). And at
  `xhigh` about 19% of calls came back empty after thinking, none at `medium`
  or `low` (QwenLM/Qwen3.8 #216, on vLLM and llama.cpp). The server itself
  stays at the template's default: TensorFold's `--reasoning-effort` flag
  would set one for every client, but this setup keeps the server stock. To
  see what a request got, each line of the server's log carries `effort=`
  (`None` means the template's `xhigh`).
- **One agent at a time.** The server can run up to 8 requests together, but
  they share the GPU: two agents slow each other down, and a long prompt from
  one slows the other's reply while it is read. Background tasks (titles,
  summaries) count too. The configs
  below send helper tasks to the same model or turn them off.
- **The window is 144,384 tokens.** Each tool is told so below and compacts
  (summarises older turns) before reaching it.
- **After the Mac restarts, the server is down until you log in.** Requests get
  `502`. Connect with Remmina (step 7) and log in at the login window; the
  model server starts with your session and takes a few minutes to load. Over
  SSH, `tensorfold service status local-model` says when it is up.
- **Watching it work.** On the server,
  `tail -f ~/Library/Logs/TensorFold/local-model/server.log` shows each request
  as it finishes: prompt size, how much came from the cache, time to the first
  token, and speed. It never logs prompt text.

### When TensorFold updates

TensorFold releases often; each release's notes are in its
[changelog](https://github.com/ashhart/TensorFold/blob/main/CHANGELOG.md). On
the server: `brew upgrade tensorfold@0.6 && tensorfold service restart local-model`.
Then look for:

- **For Claude Code:** the Anthropic Messages endpoint accepting
  mid-conversation system messages for models whose templates cannot keep them
  (for example, rendering them as user messages, as its chat endpoint does).
- **For Codex:** the Responses endpoint accepting or ignoring
  `include: ["reasoning.encrypted_content"]`.

Claude Code may need one more thing: its title requests use TensorFold's
`[grammar]` extra (xgrammar), which the Homebrew formula does not install
(`docs/findings.md`). If its check fails once system messages are accepted,
look there next.

Either change makes that tool work with no change here: its setup (steps 3 and 4)
is in place. Test with the step's check, and if it passes, record it in
`docs/findings.md` and remove the step's "not working" note.

## 0. On the server's side, once (the user)

1. **Put the API key in 1Password** as an *API Credential* item, `LLM server
   API key`, in the Private vault — so its secret reference is
   `op://Private/LLM server API key/credential`. The key is the `clients:` line of
   `~/.config/tensorfold/api-keys` on the server, without the label. Create it
   with `op item create` reading the item from stdin, so the key never reaches
   a command line.
2. **Tailnet policy.** Paste the current `config/tailscale-policy.hujson` (with
   your login filled in) into the admin console. It includes `tcp:5900` for
   step 7 and Sunshine's ports for 7b.
3. **Screen Sharing firewall.** On the server, `sudo sh scripts/4-harden.sh`,
   then `sudo sh scripts/verify.sh`: it should report "firewall loaded:
   Screen Sharing (5900), Kerberos (88) and Sunshine from the tailnet only".

## 1. Tailscale

Omarchy menu → **Install → Service → Tailscale**. It installs the package,
enables `tailscaled`, runs `tailscale up` (log in with the **same account** as
the server — the tailnet policy grants that login, and nothing else), and lets
your user run `tailscale` without sudo. Then approve the new device in the admin
console (Device approval is on).

**Check:**

```sh
tailscale status                 # the server is listed; note its name
tailscale ping <machine>         # "via <LAN address>" = direct; "via DERP" = relayed
```

## 2. The API key

```sh
mkdir -p ~/.config/llm-server && chmod 700 ~/.config/llm-server
( umask 077; op read --no-newline "op://Private/LLM server API key/credential" > ~/.config/llm-server/api-key )
```

`--no-newline` matters: OpenCode reads the file as-is, and a trailing newline
would be sent as part of the key. Every tool below reads this one file,
so rotating the key means replacing this file and nothing else. When the
server's key changes, run the line again.

**Check** — the key goes to curl on stdin, never on its command line:

```sh
printf 'header = "Authorization: Bearer %s"\n' "$(cat ~/.config/llm-server/api-key)" \
  | curl -sf -K - ENDPOINT/v1/models | grep -o '"id": *"[^"]*"'
```

Expected: `"id": "local-model"`. Without the key,
`curl -s -o /dev/null -w '%{http_code}\n' ENDPOINT/v1/models` must print `401`.

## 3. Claude Code, beside your normal login

**Not working with this server's model yet** (2026-10-03, Claude Code 2.1.288,
TensorFold 0.6.5): every request fails at once with HTTP 400, `the model's chat
template does not support mid-conversation system messages`. Qwen3.8's template
accepts a system message only at the start; see "How to use this server" and
"When TensorFold updates" above. Set it up anyway if you like — it is ready for
that update — but use Hermes or OpenCode for now.

Omarchy ships `claude` as a launcher that installs on first run. Keep your
normal Anthropic login as plain `claude`, and add `claude-local`, which uses a
**separate config directory** — its own settings, history, CLAUDE.md and MCP
servers — so nothing here can leak into, or be overridden by, the normal one.

`~/.local/bin/claude-local` (then `chmod 755`):

```sh
#!/bin/sh
# Claude Code against the private server. Plain `claude` is untouched.
export CLAUDE_CONFIG_DIR="$HOME/.claude-local"
ANTHROPIC_AUTH_TOKEN="$(cat "$HOME/.config/llm-server/api-key")" || exit 1
export ANTHROPIC_AUTH_TOKEN
unset ANTHROPIC_API_KEY
exec claude "$@"
```

`~/.claude-local/settings.json` (replace `ENDPOINT`):

```json
{
  "env": {
    "ANTHROPIC_BASE_URL": "ENDPOINT",
    "ANTHROPIC_MODEL": "local-model",
    "ANTHROPIC_DEFAULT_FABLE_MODEL": "local-model",
    "ANTHROPIC_DEFAULT_OPUS_MODEL": "local-model",
    "ANTHROPIC_DEFAULT_SONNET_MODEL": "local-model",
    "ANTHROPIC_DEFAULT_HAIKU_MODEL": "local-model",
    "CLAUDE_CODE_SUBAGENT_MODEL": "local-model",
    "CLAUDE_CODE_MAX_CONTEXT_TOKENS": "144384",
    "CLAUDE_CODE_MAX_OUTPUT_TOKENS": "16384",
    "CLAUDE_CODE_DISABLE_NONESSENTIAL_TRAFFIC": "1",
    "API_TIMEOUT_MS": "1800000"
  }
}
```

Why each: every model alias and subagents point at the one model.
`CLAUDE_CODE_MAX_CONTEXT_TOKENS` is Claude Code's documented way to tell it a
custom model's real window, so it compacts before the server's 144,384 tokens
rather than failing past it
([docs](https://code.claude.com/docs/en/model-config)). Timeouts are long because
reading a large prompt takes minutes.

**Check:**

```sh
claude-local -p "Reply with the single word OK."    # OK, after thinking
claude -p "Reply with the single word OK."          # still your Anthropic account
```

On the server, `tail ~/Library/Logs/TensorFold/local-model/server.log` shows
each request's path and the key's label (`key=clients`), never prompt text. Then
use it interactively on a real
task and watch the first turn: Claude Code's opening prompt is large, so the
first reply takes a minute or more; later turns should be much faster (the
server caches the prompt).

## 4. Codex

**Not working with TensorFold yet** (2026-10-03, TensorFold 0.6.5): every
request fails at once with HTTP 400, `include is not supported
(reasoning.encrypted_content)`. Codex sends that on every Responses request,
with no setting to stop it, so this holds for any model; see "When TensorFold
updates" above. When testing, run Codex from a trusted directory (a git repo
you have opened before) or its check stops before reaching the server.

Omarchy ships `codex` as a launcher too. Codex needs the Responses API
(`wire_api = "chat"` was removed), which the server has. It has no setting for
temperature, which is fine: the server applies the model's defaults. Do not use
`codex --oss`: it expects a local Ollama.

Add a custom provider and a profile. The research found profiles as separate
files (`~/.codex/<name>.config.toml`, used with `--profile <name>`) in current
releases; older ones used `[profiles.<name>]` tables in `~/.codex/config.toml`.
**Check which the installed version supports** (`codex --help`, its config
docs) and use that. With the profile named `local`, as `codex-local` below
expects, that is `~/.codex/local.config.toml`.

```toml
model = "local-model"
model_provider = "tailnet"
model_context_window = 144384
model_auto_compact_token_limit = 128000
model_reasoning_effort = "medium"
web_search = "disabled"

[model_providers.tailnet]
name = "LLM server"
base_url = "ENDPOINT/v1"
env_key = "LLM_SERVER_API_KEY"
wire_api = "responses"
stream_idle_timeout_ms = 900000
```

`~/.local/bin/codex-local` (then `chmod 755`):

```sh
#!/bin/sh
LLM_SERVER_API_KEY="$(cat "$HOME/.config/llm-server/api-key")" || exit 1
export LLM_SERVER_API_KEY
exec codex --profile local "$@"
```

**Check:** `codex-local exec "Reply with the single word OK."`, and plain
`codex` still uses your normal account.

## 5. Hermes Agent

Install **Hermes Desktop** (the user: it needs `sudo`), which also provides the
`hermes` command:

```sh
omarchy install ai hermes
```

Not `omarchy install hermes cli`: that installs from PyPI, which Hermes stopped
publishing to after 0.19.0 (hermes-agent PR #68217), and Omarchy's `main`
has already retired it in favour of the app (omarchy PR #12844). The app
installs Hermes from git under `~/.hermes/hermes-agent`, pinned to the release
the package was built from — `hermes-desktop 2026.8.31-3` gives Hermes 0.21.0.

**Do not update Hermes** — neither the app's *Check for updates* nor
`hermes update` — until Omarchy ships a newer `hermes-desktop`. The backend
updates without the app, and the mismatch breaks it: approvals and `clarify`
stop reaching the app after 0.21.3 (omarchy #12760), and on current `main`
the launcher crashes before opening a window (omarchy-pkgs #670). Nothing
updates automatically.

**Remove borrowed credentials.** On first run Hermes imports what it finds —
in testing, a Copilot credential from the `gh` CLI's login. `hermes auth list`
should be empty; remove anything there (`hermes auth remove copilot 1`), which
also stops it being imported again. Otherwise it is a route off the server.

Hermes runs helper calls in the background — context compression, reviews,
vision, web extraction, titles. Unset (`auto`), each uses the main provider,
falling back to OpenRouter, Nous Portal and other providers only if the server
has no working connection. `~/.hermes/config.yaml`:

```yaml
model:
  provider: tailnet
  default: "local-model"
  context_length: 144384
providers:
  tailnet:
    api: "ENDPOINT/v1"
    transport: chat_completions
    context_length: 144384
    key_cmd: cat ~/.config/llm-server/api-key
    request_timeout_seconds: 1800
    extra_body: {reasoning_effort: medium}
auxiliary:
  title_generation: {enabled: false}
  compression: {provider: main, model: "local-model", extra_body: {reasoning_effort: medium}}
  vision: {provider: main, extra_body: {reasoning_effort: medium}}
  web_extract: {provider: main, extra_body: {reasoning_effort: medium}}
memory:
  write_approval: true
skills:
  write_approval: true
```

Why each, checked against the 0.21.0 source:

- `key_cmd` runs a command that prints the key, so the app, started from the
  menu with no shell environment, reads the same one file as everything else.
  (`key_env` would need the key in the environment or a second copy in
  `~/.hermes/.env`.) No launcher script is needed.
- `request_timeout_seconds` on the provider sets both the request and stream
  timeouts, for the app too; the `HERMES_API_TIMEOUT` and
  `HERMES_STREAM_READ_TIMEOUT` variables would only reach a terminal.
- `provider: main` resolves to the main provider, `tailnet`.
- `extra_body: {reasoning_effort: medium}` asks for `medium` effort ("How to
  use this server"). Not Hermes's own setting: 0.21.0 reads
  `agent.reasoning_effort` (and `/reasoning`, `--reasoning`) but sends it only
  to providers it knows (Nous Portal, OpenRouter, GitHub Models, LM Studio,
  Ollama Cloud, Vercel); for any other endpoint
  `_supports_reasoning_extra_body()` in `run_agent.py` returns false, and the
  server logged `effort=None`. A custom provider's `extra_body` is merged into
  every request (`agent/agent_init.py`), background reviews included; each
  helper task takes its own. So Hermes cannot switch effort per job: for
  `xhigh`, add a second provider for the same server with
  `extra_body: {reasoning_effort: xhigh}` and switch to it.
- Background review — a fork of the agent that, every ~10 turns, looks back
  over the conversation and saves memories and skills — is left on. With no
  `provider`/`model` of its own it runs on the main runtime, inheriting the
  provider's timeout. It does not hold up your next turn: a new turn cancels a
  review in progress. `auxiliary.background_review.enabled: false` turns it
  off; `/refine` still runs one by hand.
- `write_approval` stages what reviews (and the agent) want to save instead
  of writing it: a local model's wrong guesses would otherwise go into every
  future prompt. Review them with `/memory pending` and `/skills pending`.
- The skills curator (weekly) only archives unused skills; it makes no model
  calls unless `curator.consolidate` is turned on.

**Check:** `hermes -z "Reply with the single word OK."`, then confirm every
call went to the server — Hermes records each in its state database:

```sh
sqlite3 ~/.hermes/state.db \
  "SELECT model, billing_base_url, task, api_call_count FROM session_model_usage;"
```

Every row should show `ENDPOINT/v1`, and on the server
`grep 'done req' ~/Library/Logs/TensorFold/local-model/server.log | tail -1`
(over SSH, step 8) should show `effort=medium`. Measured on the Omarchy
machine (2026-10-03): 2 min 11 s for the check, a 13,532-token prompt read
from cold.
Then open Hermes from the app menu, send a message, and ask for a harmless
command that needs approval: the approval prompt must appear in the app.

## 6. OpenCode

`~/.config/opencode/opencode.json` — it reads the key file itself:

```json
{
  "$schema": "https://opencode.ai/config.json",
  "provider": {
    "tailnet": {
      "npm": "@ai-sdk/openai-compatible",
      "name": "LLM server",
      "options": {
        "baseURL": "ENDPOINT/v1",
        "apiKey": "{file:~/.config/llm-server/api-key}",
        "chunkTimeout": 1800000
      },
      "models": {
        "local-model": {
          "name": "Qwen3.8 27B (TensorFold)",
          "limit": {"context": 144384, "output": 16384},
          "reasoning": true,
          "options": {"reasoningEffort": "medium"}
        }
      }
    }
  },
  "model": "tailnet/local-model",
  "small_model": "tailnet/local-model",
  "permission": {
    "edit": "ask",
    "webfetch": "ask",
    "bash": {
      "*": "ask",
      "git status": "allow", "git status *": "allow",
      "git diff": "allow", "git diff *": "allow",
      "ls": "allow", "ls *": "allow"
    }
  }
}
```

Keep any keys already in the file (Omarchy's has `autoupdate`; OpenCode
1.18.34 moved its `theme` to `tui.json` on its own). With `model` set, plain
`opencode` uses the server.

Why each, checked against OpenCode 1.18.34's config schema:

- `chunkTimeout` is the longest OpenCode waits between pieces of a streamed
  reply, 5 minutes by default, after which it drops the request (in testing,
  it then sent the request again). TensorFold sends nothing while it reads a
  prompt, so any step with more than 5 minutes of new text to read is dropped,
  and the retry starts over. In a long session that happened three times in
  one answer (`docs/findings.md`). 30 minutes matches the other tools'
  timeouts. `headerTimeout` does not matter here (TensorFold answers at once),
  and `timeout`, on the whole request, has no default in the schema (a
  26-minute request was not cut off).
- `permission`: OpenCode allows most tools by default, so the model runs
  commands and edits files without asking; in testing it ran commands in the
  `plan` agent too. These rules ask first, except for a few read-only
  commands. The last matching rule wins (OpenCode's docs), so `*` goes first;
  in testing, OpenCode's log showed each command of a chained line checked on
  its own.
- `reasoning: true` and `options.reasoningEffort`: OpenCode builds **low /
  medium / high** variants for a reasoning model on an OpenAI-compatible
  provider, and **Ctrl+T** (`variant_cycle`) switches between them
  (`--variant` for `opencode run`); TensorFold hears `high` as `xhigh`. With
  no variant chosen the model's `options` apply: `medium` ("How to use this
  server"); without them OpenCode sends no effort and the template's `xhigh`
  applies. (1.18.34's source: `provider/transform.ts`,
  `session/llm/request.ts`.) Tested 2026-10-03: the default gave
  `effort=medium`, `--variant low` gave `effort=low` for the reply and the
  session title alike, and with no `options`, `effort=None`.
- `webfetch: ask`: OpenCode's fetch tool is always available and allowed by
  default (every agent starts from `"*": "allow"` in 1.18.34's source), so the
  model could request any URL — and put what it has read into the request —
  without asking. Asking keeps that in your hands. Its `websearch` tool needs
  no rule: OpenCode enables it only for its own hosted providers, or with Exa
  or Parallel turned on.

**Check:** `opencode run "Reply with the single word OK."`, then
`opencode run -c "Now reply with the single word YES."`. On the server,
`grep 'done req' ~/Library/Logs/TensorFold/local-model/server.log | tail -3`
should show `effort=medium`, and after `opencode run --variant low ...`,
`effort=low`. `opencode run` exits once the reply is in, so a title request
still thinking may be dropped (it happened at `xhigh`; harmless).
Measured on the Omarchy machine (2026-10-03): 1 min 48 s for the first (a
10,758-token prompt, read from cold) and 5.7 s end to end for the follow-up,
whose prompt the server read almost entirely from its cache (1.5 s).

## 7. The Mac's desktop

On the Mac (the user, in the GUI): System Settings → General → Sharing →
**Screen Sharing** on; **Allow access for: Only these users** → your account;
**"VNC viewers may control screen with password" off**. The server's firewall
(step 0) already limits it to the tailnet.

On Omarchy: `sudo pacman -S remmina libvncserver` (Remmina's VNC plugin needs
`libvncserver`; TigerVNC cannot sign in to a Mac). With "VNC viewers may
control screen with password" off, the Mac offers only Apple's sign-in methods
(security types 30, 33, 35, 36); Remmina's VNC plugin speaks type 30.

The connection, as a file — `~/.local/share/remmina/<machine>-mac.remmina`
(`chmod 600`; the folder `700`):

```ini
[remmina]
name=<machine> (Mac Screen Sharing)
protocol=VNC
server=<machine>:5900
username=<your Mac username>
password=
colordepth=16
quality=1
disablepasswordstoring=1
scale=1
```

Remmina asks for the Mac password on each connection and does not store it.
16-bit colour and "Medium" quality cut the data a lot; text stays readable.

- **Lag.** Remmina cannot use the video encoding Apple's own client gets, so it
  sends compressed pixels, and a Retina screen is a lot of them: macOS draws
  each point as 2×2 pixels, and Screen Sharing sends the pixels. On the Mac,
  System Settings → Displays:
  - **Larger Text** (the end of the scale) is the easy step. On a 16" MacBook
    Pro it looks like 1168×755 and sends 2336×1510 — 3.5 million pixels
    instead of 7.7 million at the default. Noticeably faster in use.
  - **A non-Retina mode** cuts that by four again: Advanced → **Show
    resolutions as list** → **Show all resolutions**, then pick one without
    "(HiDPI)". Text in Remmina gets softer, since it stretches the smaller
    image to the window.

  To see what the Mac is sending, over SSH (step 8):
  `system_profiler -json SPDisplaysDataType | grep -E '_spdisplays_(pixels|resolution)'`
  — `pixels` is what Remmina receives. Wired Ethernet helps too. For smooth
  video, see 7b.
- **Super key.** Turn on Remmina's **Grab all keyboard events** (toolbar), or
  Hyprland keeps Super shortcuts for itself.
- **No audio.** Normal: VNC carries none, and the Mac sends sound only to
  Apple's own client.
- The first connection to a Mac with no display attached can time out while it
  starts a virtual screen; connect again.

**Check:** you see the Mac's screen (the login window, if nobody is logged in).
On the server, `verify.sh` shows Screen Sharing dropped from the local network
and allowed from the tailnet.

## 7b. Sunshine and Moonlight (optional)

Smooth video and sound instead of Screen Sharing: **Sunshine** on the Mac
encodes the screen as H.264/HEVC video with the Mac's hardware encoder;
**Moonlight** on Omarchy plays it. Set up and verified on 2026-10-03 with
Sunshine v2026.914.233613 and moonlight-qt from `extra`: HEVC with hardware
decoding at both ends, over a direct tailnet connection, and much smoother than
Remmina.

**Decide first.** This adds a third-party service to a server otherwise kept to
built-in components, and it needs Screen Recording and Accessibility — full
view and control of the Mac. Sunshine's macOS support is marked experimental in
its stable docs, and has open bugs that matter here:

- H.264 on macOS halves the frame rate in current releases (LizardByte/Sunshine
  #5697): use **HEVC**.
- When the display sleeps, Sunshine has nothing to capture and Moonlight
  cannot connect (#5509); step 5 below keeps the display awake on the charger.
- It needs a logged-in GUI session. With FileVault on, nothing streams after a
  restart until someone logs in (Screen Sharing works at the login window).
- With no monitor attached it needs a display to capture: an HDMI dummy plug
  or a BetterDisplay virtual screen (community reports; not in Sunshine's docs).

For admin work, step 7 is enough. **Keep step 7 set up either way**: it is the
way back in when Sunshine cannot help — see "When Sunshine fails" below.

### On the Mac (the user)

1. **Install** the signed `Sunshine-macOS-arm64.dmg` from
   [LizardByte/Sunshine releases](https://github.com/LizardByte/Sunshine/releases)
   (stable, not a pre-release), into /Applications. Prefer it to LizardByte's
   Homebrew tap, which has only a command-line formula with an ad-hoc
   signature: macOS ties Screen Recording and Accessibility for such a binary
   to that exact build, so they would likely need granting again after every
   `brew upgrade`. The app is signed with LizardByte's Developer ID and
   notarized, and keeps them.
2. **Permissions**, when asked on first launch: Screen Recording, Accessibility
   (keyboard and mouse), and Microphone / System Audio Recording for sound.
   Leave `audio_sink` empty: on macOS 14+ Sunshine captures system audio itself
   (PR #4209); the docs' advice to install BlackHole is out of date.
   After Screen Recording, macOS offers **Quit & Reopen**. On the first run
   Sunshine hung there instead: still running, its web UI not answering. If
   so, quit it and open it again (`pkill -x Sunshine; open -a Sunshine`); its
   log, `~/.config/sunshine/sunshine.log`, should then list
   `Found HEVC encoder: hevc_videotoolbox`.
3. **Settings**, in `~/.config/sunshine/sunshine.conf`:

   ```ini
   origin_web_ui_allowed = pc
   upnp = disabled
   ```

   `pc` means the web UI answers only on the Mac itself: https://localhost:47990
   in Safari on the Mac (through Remmina, or in person; the certificate is
   self-signed, so accept the warning), or from Omarchy through SSH (step 8):
   `ssh -L 47990:127.0.0.1:47990 <machine>`, then https://localhost:47990. Leave `bind_address` empty — binding to the tailnet
   address would also move the web UI off localhost and lock you out of it.
   Sunshine treats tailnet addresses as LAN, so the stream is not encrypted by
   Sunshine; it is inside WireGuard.
4. **First run:** in the web UI, create the Sunshine username and password
   (store them in 1Password), and start Sunshine at login (a login item: it
   must run in your GUI session, not as a daemon).
5. **Keep the display awake on the charger:** `sudo pmset -c displaysleep 0`
   (undo: `sudo pmset -c displaysleep <minutes>`). Without it, with the lid
   shut, the display goes off the moment a Remmina session ends (Screen Sharing
   holds it on only while connected), and otherwise after a few idle minutes;
   Sunshine then logs "No display devices are active", so Moonlight cannot
   connect. With it, Moonlight shows the **lock screen** and you can type your
   password there. On battery the display still sleeps. With the lid shut the
   panel stays dark anyway; with it open, the screen stays on.
   (Amphetamine, or `caffeinate -d`, does the same while it runs.)

   **The Mac no longer locks when the display would have slept**, so let the
   screen saver lock it: System Settings → Lock Screen → **Start Screen Saver
   when inactive** (10 minutes here; the default is 20) with **Require password
   after screen saver begins or display is turned off** at **Immediately**.
   Input through Moonlight counts as activity. Amphetamine holds off the
   screen saver too, so the Mac does not lock while it runs (presumably
   `caffeinate -d` as well; not checked).
   Checked 2026-10-03: at 1 minute it locked, and Moonlight showed the lock
   screen and took the password.
6. **Firewall.** Sunshine listens on every network, like Screen Sharing. The
   server's pf anchor (`config/pf-screensharing.conf`) already drops its
   default ports — TCP 47984, 47989, 47990, 48010 and UDP 47998-48000 — unless
   the connection comes from the tailnet. With Sunshine running,
   `sudo sh scripts/verify.sh` reports the web UI allowed from the Mac itself,
   and Sunshine dropped from the local network and allowed from the tailnet. Keep Sunshine's base `port`
   at its default, 47989, or the rules miss it.
7. **Tailnet policy:** `config/tailscale-policy.hujson` has the ports in the
   grant's `ip` list:

   ```
   "tcp:47984", "tcp:47989", "tcp:48010", "udp:47998-48000",
   ```

   Check them with the admin console's policy tests. 47990 (the web UI)
   stays out: it is reached through SSH.

### On Omarchy

1. `sudo pacman -S moonlight-qt` (in `extra`). Intel graphics decode HEVC in
   hardware through VAAPI (`intel-media-driver`).
2. **Add the host** with **+** (top right): `<machine>` (MagicDNS) or its
   100.x address. Moonlight's own search will not find it: that uses mDNS,
   which stays on the local network, where Sunshine is firewalled. Moonlight
   shows a PIN; enter it in Sunshine's web UI → PIN. If adding times out,
   check the tailnet policy (7b, "On the Mac", item 7): `nc -z -w 3 <machine> 47989`.
3. **Settings** (the gear in the main window; there is no settings screen
   during a stream, so end it with Ctrl+Alt+Shift+Q, change them, and start
   again): video codec **HEVC**, or **Automatic** as long as the statistics
   still show HEVC; **Capture system keyboard shortcuts**: in fullscreen (so
   Super goes to the Mac).
4. **Keys:** Ctrl+Alt+Shift+Q ends the stream, +Z releases the keyboard and
   mouse, +X toggles fullscreen, +S shows statistics. Moonlight does not send
   the Command key: **Right Option** is Command on the Mac.

No MTU change is needed: Moonlight caps packets for addresses like the
tailnet's at a size that fits Tailscale's.

**If the mouse lags**, the statistics (Ctrl+Alt+Shift+S) say where. High or
jumpy network latency: Wi-Fi — a cable on the Mac, or on both, helps most.
High rendering time or frame queue delay: turn off **V-Sync** and **Frame
pacing** in Moonlight's settings, which add a frame or more each. A 120 FPS
stream, if the Omarchy screen can show it, also moves the cursor twice as
often as 60. `tailscale status` on either machine should say `direct`, not
`relay`.

**Check:** the stream shows the Mac's screen with sound, Ctrl+Alt+Shift+S
reports HEVC with hardware decoding, and from another machine on the local
network (not the tailnet) the ports stay closed:
`nc -z -w 3 <Mac's LAN address> 47989` must fail.

### When Sunshine fails: back to Remmina

Screen Sharing (step 7) is built into macOS and shares nothing with Sunshine —
not its app, its ports or its permissions — so the Remmina connection keeps
working whatever happens to Sunshine. Use it when:

- **The Mac has restarted.** Sunshine runs only in a logged-in session; Screen
  Sharing works at the login window. Log in through Remmina, and Sunshine
  and the model server start with your session. Once logged in, a locked
  screen is no reason to switch back: with the display awake (7b, item 5),
  Moonlight shows it and takes your password.
- **The stream is black or frozen**, or Moonlight cannot connect (the display
  slept, #5509): check 7b, item 5, connect with Remmina, or restart Sunshine over
  SSH (step 8):
  `pkill -x Sunshine; sleep 2; open -a Sunshine` (it runs in the menu bar, with
  no Dock icon).
- **Moonlight cannot find or pair with the host**: Sunshine's web UI is still
  reachable through the SSH tunnel above.

Connect with one or the other, not both at once (untested together).

## 8. SSH to the server (optional)

Nothing above needs a shell on the server — the key comes from 1Password —
but SSH is the way to administer it from here (logs, `tensorfold service`,
`verify.sh`)
without the desktop. The server accepts SSH keys only, and only from the
tailnet; the key is the one in its `~/.ssh/authorized_keys`, kept in
1Password and served by 1Password's SSH agent, so its private half never
leaves 1Password.

1. **1Password's SSH agent on:** 1Password → Settings → Developer → *Use the
   SSH agent*. It offers keys from the Personal/Private vault by default; for a
   key in another vault, add the vault to `~/.config/1Password/ssh/agent.toml`.
2. **`ssh` uses it, and only this key.** `SSH_AUTH_SOCK=~/.1password/agent.sock
   ssh-add -l` should list the key. With several keys in the agent it offers
   them in turn, and the server can give up ("Too many authentication
   failures") before reaching the right one, so name it. Save its public half
   straight from the agent — no export from 1Password needed:

   ```sh
   SSH_AUTH_SOCK=~/.1password/agent.sock ssh-add -L | grep ' <key title>$' > ~/.ssh/<machine>.pub
   ```

   and add to `~/.ssh/config`, above any `Host *` block (with your Mac
   username):

   ```
   Host <machine>
       HostName <machine>
       User <you>
       IdentityFile ~/.ssh/<machine>.pub
       IdentitiesOnly yes
       IdentityAgent ~/.1password/agent.sock
   ```
3. **Check the host key before trusting it.** From Omarchy, without
   connecting: `ssh-keyscan -t ed25519 <machine> | ssh-keygen -lf -`. On the
   Mac (over Screen Sharing, step 7):
   `ssh-keyscan -t ed25519 localhost | ssh-keygen -lf -`, which avoids typing
   the host key's path. The `SHA256:` fingerprints must match in full; if not,
   stop.
4. **Connect:** `ssh <machine>` (MagicDNS; else the full
   `<machine>.<tailnet>.ts.net`), accept the fingerprint you just checked, and
   approve the key in 1Password.

**Check:** `ssh <machine> 'sw_vers -productVersion; /opt/homebrew/opt/tensorfold@0.6/bin/tensorfold service status local-model'`
prints the macOS version and the model service's state. A command run this way
gets no login shell, so Homebrew's tools are not on its `PATH`: interactively
(`ssh <machine>`) `tensorfold` works; in a one-off command, use its full path.
The service lives in your GUI login, so it runs only while you are logged in on
the Mac; after a restart, log in through Remmina (step 7) first.

## 9. Report

Tell the user what passed, what failed, and the first-turn and later-turn times
from steps 5 and 6. Commit changes to this repo only if commit signing works on this
machine (CLAUDE.md); otherwise leave them for the user.

## Later

- **iPhone and iPad:** the Tailscale app with the same login; any chat app
  that takes a custom OpenAI-compatible base URL and API key (not yet chosen
  or tested here); **Screens** for the Mac's desktop, signing in with the Mac
  account.
  Avoid Chatbox on iOS: its key authentication to custom endpoints fails there
  (chatboxai/chatbox #3516).
- **blip** ([nixfred/blip](https://github.com/nixfred/blip)) — iMessage on
  Omarchy. It has no AI features; it needs a Mac signed in to your Apple ID,
  logged in and awake, as its gateway. If that is the server, it needs Full
  Disk Access for macOS's SSH helper (`sshd-keygen-wrapper`), which its own
  README warns applies to **every** SSH key on the account, not just blip's.
  Decide that trade-off before installing it.
