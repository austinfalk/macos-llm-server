# Using the server from an Omarchy (Linux) machine

How to connect an [Omarchy](https://omarchy.org) machine to the server and use
it from Claude Code, Codex, Hermes Agent and OpenCode. Written to be followed
step by step, by a person or by a Claude Code session running in a clone of
this repository on the Omarchy machine. Last followed on Omarchy 4.0.5 with
Claude Code 2.1.302, Codex 0.163.0, Hermes Agent 0.21.1 (as
`hermes-desktop 2026.9.7-5` installs it) and OpenCode 2.0.32, with the server
on Splash's M1/M2 port 1.3.2-m1.1 (October 2026). The Mac's desktop and SSH to
the server are in [omarchy-desktop.md](omarchy-desktop.md).

**If you are Claude Code following this:** do one step at a time and run its
check before the next. If a check fails, or a command, flag or config key does
not exist in the installed version, stop and tell the user. Do not work around
it. Before relying on a setting, confirm it in that tool's own docs or `--help`
for the installed version. Never print the key, put it on a command line, or
write it anywhere except the one file in step 2. Hand anything that needs
`sudo` or a GUI to the user. You cannot read the server's log, so where a check
needs it, ask the user.

Throughout, `ENDPOINT` means `https://<machine>.<tailnet>.ts.net`, the server's
address, which `tailscale status` lists once step 1 is done. The server runs
[Splash](https://github.com/incoai/splash), through its M1/M2 port
[paperniuk/splash](https://github.com/paperniuk/splash), with Qwen3.8-27B and
its DFlash2 draft. Every API is under `ENDPOINT/v1`: OpenAI chat completions
and Responses, and Anthropic Messages. Splash's own client launchers
(`splash-m1 claude` and the others) connect only to a server on the same Mac,
so each tool is configured by hand here, with the launchers' settings where
they set one (the port's `install/clients.py`). Four facts shape every config:

- **One model ID.** Every model setting, including background and helper
  models, names `mlx-community/Qwen3.8-27B-4bit`. Splash answers any other
  model name with 404.
- **Sampling is the server's.** Splash applies Qwen's defaults (temperature
  1.0, top_p 0.95, top_k 20) when a request sets none, so these configs set
  none.
- **Reasoning takes output.** The model thinks before it answers, and the
  output limit counts the thinking. A reply cut off while still thinking comes
  back empty, so the configs allow 32,768 output tokens and long timeouts.
- **The window is 262,144 tokens**, the model's native window, which
  `/v1/models` reports as `context_length`. Each client gets the whole window
  and compacts before reaching it. Nothing has been measured end to end past
  about 31K tokens. If a client fails near the limit, lower that client's
  window to 144,384, a window all four have run with, recompute the limits
  derived from it (Codex's 90%, OpenCode's input), and record it in
  [`findings.md`](findings.md).

## Before you start

You need these from the server's owner:

- The server set up and verified (the [README](../README.md), steps 1-7).
- A Tailscale login that the server's tailnet policy names (README, step 2).
- The API key in 1Password, as an *API Credential* item named
  `LLM server API key` in the Private vault, so that its secret reference is
  `op://Private/LLM server API key/credential`. The key is the one line of
  `~/.config/llm-server/api-key` on the server, without its newline. The owner
  creates the item with `op item create` reading it from stdin, so the key
  never reaches a command line.

## What works

| Tool | Use it for | API | Step |
|---|---|---|---|
| Claude Code (`claude-local`) | Coding | Anthropic Messages | 3 |
| Codex (`codex-local`) | Coding | Responses | 4 |
| Hermes Agent (desktop app and `hermes`) | General agent work: research, writing, running commands, long tasks you check on later | chat completions | 5 |
| OpenCode (`opencode`) | Coding in a repository, from the terminal | chat completions | 6 |

All four worked from this machine on 2026-10-18 with these settings, after
working with an earlier version of them
([findings](findings.md#the-server-splash-for-m1m2-and-qwen38-27b)). Any other
tool that speaks OpenAI chat completions should work the same way: base URL `ENDPOINT/v1`, the key from step 2, and the
model ID above.

### Working well with it

- **The first turn is the slow one.** The server reads a new prompt at about
  6 s per thousand tokens, and an agent's first prompt is 8-20K tokens of
  instructions and tool definitions. From this machine, the first turn started
  writing after 56 s in OpenCode (8,528 tokens), 61 s in Hermes (12,177),
  112 s in Claude Code (20,109) and 135 s in Codex (18,600). The server then
  caches the conversation and reads only what is new. A follow-up starts in
  about 2 s, or later when a tool result adds text: about 7,000 new tokens
  took 40-46 s. It writes at 23-38 tokens a second, slower as a conversation
  grows, so hand it tasks you can walk away from.
- **Keep conversations going.** A new session, a changed system prompt or tool
  set, or an edit to an earlier message makes the server read again from the
  first change. Every MCP server and tool adds to every prompt, so turn off
  what a session does not need.
- **One agent at a time.** Requests share the GPU, so two agents slow each
  other down. Background tasks (titles, summaries) count too, so the configs
  below send them to the same model or turn them off.

If the server stops answering, for example with `502` after the Mac restarts,
see the README's [Troubleshooting](../README.md#troubleshooting).

### Reasoning effort

Most of a long turn is the model thinking. Qwen3.8's template knows `low`,
`medium` and `xhigh`, its default. The server gives `medium` to chat
completions and Responses requests that name no effort, because `xhigh` took
about twice as long for a small gain and sometimes came back empty
([findings](findings.md#the-server-splash-for-m1m2-and-qwen38-27b)). So Codex,
Hermes and OpenCode need no effort setting. Claude Code uses the Messages API,
where Splash takes a missing effort as `high`, as Anthropic's API does (the
port's `server/api_shapes.py`), so `claude-local` asks for `medium` itself.
Splash renders `high` as `xhigh` for this template. For `high` on one task:

| Client | How |
|---|---|
| Claude Code | Start it as `CLAUDE_CODE_EFFORT_LEVEL=high claude-local` |
| Codex | Add `-c model_reasoning_effort=high` to `codex-local` |
| Hermes | Start it with a second provider that asks for it (step 5) |
| OpenCode | **Ctrl+T** in the TUI, or `opencode run --model tailnet/mlx-community/Qwen3.8-27B-4bit#high` |

## 1. Tailscale

Omarchy menu → **Install → Service → Tailscale**. It installs the package,
enables `tailscaled`, runs `tailscale up`, and lets your user run `tailscale`
without sudo. Log in with the **same account** as the server, which the
tailnet policy grants. Then approve the new device in the admin console.

**Check:**

```sh
tailscale status                 # the server is listed; note its name
tailscale ping <machine>         # "via <LAN address>" = direct; "via DERP" = relayed
```

## 2. The API key

```sh
mkdir -p ~/.config/llm-server && chmod 700 ~/.config/llm-server
( umask 077; op read --no-newline "op://Private/LLM server API key/credential" > ~/.config/llm-server/api-key.new ) \
  && mv ~/.config/llm-server/api-key.new ~/.config/llm-server/api-key
```

Writing to a new file first keeps the old key in place if `op` fails, for
example when 1Password is locked.

OpenCode reads the file as it is, and would send a trailing newline as part of
the key, hence `--no-newline`. Every tool below reads this one file, so when
the server's key changes, run the command again and nothing else.

**Check.** The key goes to curl on stdin, never on its command line:

```sh
printf 'header = "Authorization: Bearer %s"\n' "$(cat ~/.config/llm-server/api-key)" \
  | curl -sf -K - ENDPOINT/v1/models | grep -o '"id": *"[^"]*"'
```

Expected: `"id": "mlx-community/Qwen3.8-27B-4bit"`. Without the key,
`curl -s -o /dev/null -w '%{http_code}\n' ENDPOINT/v1/models` must print `401`.

## 3. Claude Code, beside your normal login

Omarchy ships `claude` as a launcher that installs on first run. Keep your
normal Anthropic login as plain `claude`, and add `claude-local`, which uses a
**separate config directory** with its own settings, history, CLAUDE.md and
MCP servers, so the two cannot affect each other.

`~/.local/bin/claude-local` (then `chmod 755`):

```sh
#!/bin/sh
# Claude Code against the private server. Plain `claude` is untouched.
export CLAUDE_CONFIG_DIR="$HOME/.claude-local"
export CLAUDE_CODE_EFFORT_LEVEL="${CLAUDE_CODE_EFFORT_LEVEL:-medium}"
ANTHROPIC_AUTH_TOKEN="$(cat "$HOME/.config/llm-server/api-key")" || exit 1
export ANTHROPIC_AUTH_TOKEN
unset ANTHROPIC_API_KEY CLAUDE_CODE_USE_BEDROCK CLAUDE_CODE_USE_VERTEX CLAUDE_CODE_USE_FOUNDRY
exec claude "$@"
```

`~/.claude-local/settings.json` (replace `ENDPOINT`):

```json
{
  "env": {
    "ANTHROPIC_BASE_URL": "ENDPOINT",
    "ANTHROPIC_MODEL": "mlx-community/Qwen3.8-27B-4bit",
    "ANTHROPIC_DEFAULT_FABLE_MODEL": "mlx-community/Qwen3.8-27B-4bit",
    "ANTHROPIC_DEFAULT_OPUS_MODEL": "mlx-community/Qwen3.8-27B-4bit",
    "ANTHROPIC_DEFAULT_SONNET_MODEL": "mlx-community/Qwen3.8-27B-4bit",
    "ANTHROPIC_DEFAULT_HAIKU_MODEL": "mlx-community/Qwen3.8-27B-4bit",
    "CLAUDE_CODE_SUBAGENT_MODEL": "mlx-community/Qwen3.8-27B-4bit",
    "CLAUDE_CODE_MAX_CONTEXT_TOKENS": "262144",
    "CLAUDE_CODE_AUTO_COMPACT_WINDOW": "262144",
    "CLAUDE_CODE_ALWAYS_ENABLE_EFFORT": "1",
    "CLAUDE_CODE_DISABLE_NONESSENTIAL_TRAFFIC": "1",
    "API_TIMEOUT_MS": "1800000",
    "CLAUDE_STREAM_IDLE_TIMEOUT_MS": "1800000"
  },
  "permissions": {"deny": ["WebSearch"]}
}
```

Why each, from Claude Code's [environment variables](https://code.claude.com/docs/en/env-vars)
unless marked:

- Every model alias, and subagents, name the one model.
- The two window variables tell Claude Code the model's real window and make
  it compact within it. They, and the `unset` line, are the port's launcher's.
  Like the launcher, this sets no output limit: Claude Code's default for a
  model ID it does not know is 32,000.
- `CLAUDE_CODE_EFFORT_LEVEL` sets the effort, and
  `CLAUDE_CODE_ALWAYS_ENABLE_EFFORT` sends it to a model ID Claude Code does
  not recognize. The level variable outranks `--effort` and `/effort`, so
  `claude-local` sets it, where one launch can change it.
- The `WebSearch` rule does what the launcher's `--disallowedTools WebSearch`
  does. Claude Code's web search runs on Anthropic's search backend
  ([tools reference](https://code.claude.com/docs/en/tools-reference)), which
  this server does not have.
- `API_TIMEOUT_MS` is a precaution. A streaming request must get its response
  headers within it, 10 minutes by default, and nobody has checked whether
  Splash sends them before it has read the prompt. At 150 tokens a second, a
  cold 90K-token prompt takes 10 minutes to read.
- `CLAUDE_STREAM_IDLE_TIMEOUT_MS` lets a turn think for longer than 10
  minutes. While the model thinks, Splash sends Claude Code only keep-alive
  `ping` events, because Claude Code asks it not to show the thinking.
  Claude Code accepts about five minutes of pings, then waits this long for
  real output, 5 minutes by default, before it cancels the request and sends
  it again ([network configuration](https://code.claude.com/docs/en/network-config#streaming-idle-watchdogs)).
  On 2026-10-18 that cancelled a turn that had thought for 600 s, and the
  resent request had to think again from the start. 30 minutes covers the
  32,000-token output limit at the server's speed.

**Check:**

```sh
claude-local -p "Reply with the single word OK."    # OK, after thinking
claude -p "Reply with the single word OK."          # still your Anthropic account
```

The first reply takes about two minutes. Claude Code first prints
`[claude-code:unrecognized_model]`, because it does not know the model ID.
That is expected. On one attempt on the server the model went off task and
explored the machine with tool calls instead of answering. If that happens,
stop it and run the check again.

## 4. Codex

Run Codex from a trusted directory (a git repository you have opened before),
or its check stops before reaching the server. Codex needs the Responses API,
which the server has. Do not use `codex --oss`, which expects a local Ollama.

Add a custom provider and a profile. Current releases keep a profile in its
own file, `~/.codex/<name>.config.toml`, used with `--profile <name>`. Older
ones used `[profiles.<name>]` tables in `~/.codex/config.toml`. **Check which
the installed version supports** and use that. For the profile `local`, which
`codex-local` uses, that is `~/.codex/local.config.toml`:

```toml
model = "mlx-community/Qwen3.8-27B-4bit"
model_provider = "tailnet"
model_context_window = 262144
model_auto_compact_token_limit = 235929
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

The window, compaction at 90% of it, and `web_search` are the port's
launcher's settings. There is no `model_reasoning_effort`, so the server's
`medium` applies. `stream_idle_timeout_ms` is a precaution: Codex drops a
stream that sends nothing for that long, and nobody has checked whether Splash
sends anything while it reads a long prompt.

**Check:** `codex-local exec "Reply with the single word OK."`, and plain
`codex` still uses your normal account. Codex warns that it has no model
metadata for the model ID and uses fallback metadata. That is expected,
because the profile sets the window and compaction itself.

## 5. Hermes Agent

Install **Hermes Desktop**, which also provides the `hermes` command. It needs
`sudo`, so the user runs `omarchy install ai hermes` (Install → AI → Hermes
Desktop in the menu). `omarchy install hermes cli` installs the same app
without opening it. The app installs Hermes from git under
`~/.hermes/hermes-agent`, pinned to the release the package was built from:
`hermes-desktop 2026.9.7-5` gives Hermes 0.21.1.

**Do not update Hermes**, neither with the app's *Check for updates* nor with
`hermes update`. Let it change only when an Omarchy update brings a newer
`hermes-desktop`. The backend updates without the app, and the mismatch breaks
it: approvals and `clarify` stop reaching the app after 0.21.3 (omarchy
#12760), and on current `main` the launcher crashes before opening a window
(omarchy-pkgs #670).

**Remove borrowed credentials.** On first run Hermes imports what it finds,
such as a Copilot credential from the `gh` CLI's login. `hermes auth list`
should be empty. Remove anything there (`hermes auth remove copilot 1`), or it
is a route off the server.

Hermes runs helper calls in the background: compression, reviews, vision, web
extraction, titles. Left at `auto`, each uses the main provider, and falls
back to other providers only if the server has no working connection.
`~/.hermes/config.yaml`:

```yaml
model:
  provider: tailnet
  default: "mlx-community/Qwen3.8-27B-4bit"
  context_length: 262144
providers:
  tailnet:
    api: "ENDPOINT/v1"
    transport: chat_completions
    context_length: 262144
    key_cmd: cat ~/.config/llm-server/api-key
    request_timeout_seconds: 1800
auxiliary:
  title_generation: {enabled: false}
  compression: {provider: main, model: "mlx-community/Qwen3.8-27B-4bit"}
  vision: {provider: main}
  web_extract: {provider: main}
memory:
  write_approval: true
skills:
  write_approval: true
```

**The output limit.** Run `hermes --version`. The port's launcher says that
Hermes before 2026.9.7 (release 0.21.1) asks for an output limit on every
request, 65,536 if unset, and compacts at 75% of the window less that limit.
Later versions ignore the setting. On 0.21.0 or older, add `max_tokens: 32768`
under `model:`, where the launcher puts it. The launcher's `model:` names the
endpoint itself (`provider: custom`), though, and whether Hermes reads
`model.max_tokens` when `model.provider` names an entry under `providers:` has
not been checked. Confirm it in the source under `~/.hermes/hermes-agent`. If
Hermes reads the limit elsewhere, tell the user.

Why each, checked against the 0.21.1 source:

- `key_cmd` prints the key, so the app, started from the menu with no shell
  environment, reads the same file as everything else. `provider: main` is
  `tailnet`.
- `request_timeout_seconds` sets the request and stream timeouts, for the app
  too. 30 minutes is a precaution, as in the other clients.
- No effort setting. Hermes sends its own `agent.reasoning_effort` only to
  providers it knows (`_supports_reasoning_extra_body()` in
  `agent/reasoning_params.py`), so its requests get the server's `medium`.
  It does merge a provider's `extra_body` into every request
  (`agent/agent_init.py`). For `high`, add a provider `tailnet-high`, a copy
  of `tailnet` with
  `extra_body: {reasoning_effort: high}`, and start Hermes with
  `--provider tailnet-high` (check in `hermes --help` that it takes a name
  from `providers:`).
- Background review, a fork of the agent that every ~10 turns saves memories
  and skills, stays on, and runs on the main provider.
  `auxiliary.background_review.enabled: false` turns it off.
- `write_approval` stages what the agent and its reviews want to save, so a
  local model's wrong guesses do not reach every future prompt. Review them
  with `/memory pending` and `/skills pending`.

**Check:** `hermes -z "Reply with the single word OK."`, then confirm that
every call went to the server:

```sh
sqlite3 ~/.hermes/state.db \
  "SELECT model, billing_base_url, task, api_call_count FROM session_model_usage;"
```

Every row should show `ENDPOINT/v1`. Before its first request, Hermes asks for
Ollama's `POST /api/show`, which Splash answers with 404. Hermes goes on
without it, so that 404 is harmless. Then open Hermes from the app menu and
ask for a harmless command that needs approval: the prompt must appear in the
app.

## 6. OpenCode

`~/.config/opencode/opencode.json` (OpenCode reads the key file itself):

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
        "mlx-community/Qwen3.8-27B-4bit": {
          "name": "Qwen3.8 27B (Splash)",
          "reasoning": true,
          "limit": {"context": 262144, "input": 229376, "output": 32768}
        }
      }
    }
  },
  "model": "tailnet/mlx-community/Qwen3.8-27B-4bit",
  "small_model": "tailnet/mlx-community/Qwen3.8-27B-4bit",
  "agent": {
    "build": {"model": "tailnet/mlx-community/Qwen3.8-27B-4bit"},
    "plan": {"model": "tailnet/mlx-community/Qwen3.8-27B-4bit"},
    "general": {"model": "tailnet/mlx-community/Qwen3.8-27B-4bit"},
    "explore": {"model": "tailnet/mlx-community/Qwen3.8-27B-4bit"},
    "title": {"model": "tailnet/mlx-community/Qwen3.8-27B-4bit"},
    "compaction": {"model": "tailnet/mlx-community/Qwen3.8-27B-4bit"},
    "summary": {"model": "tailnet/mlx-community/Qwen3.8-27B-4bit"}
  },
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

Keep any keys already in the file (Omarchy's has `theme` and `autoupdate`).
If it has an `agent` section, keep each agent's other settings and set its
`model`. Plain
`opencode` then uses the server.

Why each, checked against OpenCode 1.18.34's config schema. OpenCode 2.0.32
reads the same file and converts it, and `opencode debug config` shows the
result:

- The model reference is the provider, a slash, and an ID with a slash of its
  own, the shape the port's launcher writes
  (`splash/mlx-community/Qwen3.8-27B-4bit`). Step 7 confirms it.
- `limit`: the window, 32,768 for output, and the input OpenCode compacts at,
  the window less the output, all as the launcher sets them.
- `agent`: an agent's own `model` outranks the top-level one, so the launcher
  pins each built-in agent to the served model, and so does this config.
  OpenCode 2.0.32 adds a `summary` agent, pinned here too, and makes
  `small_model` the `title` agent's model.
- `reasoning: true` makes OpenCode 1.x build **low / medium / high**
  variants. OpenCode 2.0.32 logs the key as an unsupported legacy setting and
  ignores it, but offers the same three variants. **Ctrl+T** switches between
  them in the TUI. For `opencode run`, add the variant to the model with `#`,
  as in the table under **Reasoning effort**. With no variant chosen,
  OpenCode sends no effort, and the server's `medium` applies.
- `chunkTimeout` is the longest OpenCode waits between pieces of a streamed
  reply. After its default, 5 minutes, it drops the request (in testing, it
  then sent it again). Nobody has checked whether Splash sends anything while
  it reads a prompt, and a cold 31K-token prompt took 208 s to its first token
  ([findings](findings.md#the-server-splash-for-m1m2-and-qwen38-27b)), so 30
  minutes is a precaution.
- `permission`: by default OpenCode runs commands and edits files without
  asking, in testing even in the `plan` agent. These rules ask first, except
  for a few read-only commands. The last matching rule wins, so `*` is first.
  `webfetch` is allowed by default too, so without the rule the model could
  send what it has read to any URL. The `websearch` tool is on only for
  OpenCode's own hosted providers.

**Check:** `opencode run "Reply with the single word OK."`, then
`opencode run -c "Now reply with the single word YES."`. `opencode run` exits
once the reply is in, so a title request still thinking may be dropped, which
is harmless. It exits with 0 even after an error, so read its output.

## 7. Check all four, and report

1. **Each client once.** Run any check in steps 3-6 that has not run yet, and
   note the time to the first word of a first turn and of a follow-up.
2. **The OpenCode model ID.** `opencode models | grep '^tailnet/'` should list
   `tailnet/mlx-community/Qwen3.8-27B-4bit`, and step 6's check should have
   answered. If OpenCode reports the model as unknown, stop and tell the user.
3. **Effort.** Ask the user to run this on the server, or over SSH
   ([omarchy-desktop.md](omarchy-desktop.md), step 3):

   ```sh
   grep Started ~/Library/Logs/llm-server/splash.log | tail -20
   ```

   Each line shows a request's prompt size, its cached part and its effort.
   Claude Code's turns should show `effort medium` (its small side requests
   may have thinking off). Codex's, Hermes's and OpenCode's should show
   `effort absent → medium`, or `effort medium` if the client sent it.
   OpenCode's title requests may show `low`. A `high` or `xhigh` that nobody
   asked for is a failure.
4. **One long session.** In Claude Code or OpenCode, work on a real task in
   this repository in one session until its context passes 64K tokens. Note
   anything refused, dropped or sent again, and how long turns take to start
   as it grows.
5. **Report** to the user, for `docs/findings.md`: what passed and what
   failed, each client's times from item 1, and the long session's. Commit
   changes to this repository only if commit signing works on this machine
   (AGENTS.md). Otherwise leave them for the user.
