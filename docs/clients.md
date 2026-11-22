# Connecting a client

How to use the server from another Linux or macOS machine with Claude Code,
Codex, Hermes Agent or OpenCode. Follow the steps in order, running each check
before the next. Last followed on a Linux client on 2026-10-18 with Claude
Code 2.1.302, Codex 0.163.0, Hermes Agent 0.21.1 and OpenCode 2.0.32
([findings](findings.md#clients)). OpenCode's step was last checked with
OpenCode 2.3.2 on the server on 2026-11-21.

**If you are an agent following this:** do one step at a time and run its
check. If a check fails, or a command, flag or config key does not exist in
the installed version, stop and tell the user rather than work around it.
Confirm settings in the tool's own docs or `--help` for its installed version.
Never print the key, put it on a command line, or write it anywhere but the
file in step 2. Hand anything that needs `sudo`, a GUI or the server's log to
the user.

## What you need

- The server set up and verified ([README](../README.md), steps 1-7).
- A Tailscale login the tailnet policy grants: by default, the same one as
  the server.
- A way to read the key on the server, `~/.config/llm-server/api-key`: a
  password manager's CLI, or SSH over the tailnet.

Below, `ENDPOINT` is the `Endpoint` line `3-services.sh` printed on the
server, without the trailing `/v1`: `https://<machine>.<tailnet>.ts.net`, or
`https://<machine>.<tailnet>.ts.net:8443` when the server sets
`LLM_HTTPS_PORT`. Use the full name, not the short one `tailscale status`
shows, or TLS and Splash's host check fail. Replace `ENDPOINT` in every config
below. In shell commands, set it once with `export ENDPOINT=https://...`.

Four facts shape every config:

- **One model ID** for every model setting, helpers and subagents included:
  the `Model` line `3-services.sh` printed. The configs below use the default,
  `mlx-community/Qwen3.8-27B-4bit`. If the server's differs, replace it
  everywhere. Splash answers any other name with 404.
- **No sampling settings.** Splash applies Qwen's defaults when a request sets
  none.
- **About 32K output tokens and long timeouts.** The model thinks first, the
  limit counts the thinking, and a reply cut off while thinking comes back
  empty. OpenCode's config sets 32,768, Claude Code's default is 32,000, and
  Codex and Hermes 0.21.1 send no limit.
- **The window `/v1/models` reports as `context_length`**, 262,144 tokens for
  the default model. If the server's differs, use its value and recompute the
  limits derived from it (Codex's 90%, OpenCode's input). Sessions have
  reached 95K. If a client fails near the limit, lower its window to 144,384,
  the largest all four clients have run with, and record it in
  [findings](findings.md).

| Tool | API | Step |
|---|---|---|
| Claude Code (`claude-local`) | Anthropic Messages | 3 |
| Codex (`codex-local`) | Responses | 4 |
| Hermes Agent (`hermes` and the desktop app) | chat completions | 5 |
| OpenCode (`opencode`) | chat completions | 6 |

Any other OpenAI-compatible tool works with base URL `ENDPOINT/v1`, the key
and the model ID.

**Working with it.** The first turn is slow. On the M1 Max the server reads a
new prompt at about 6 s per thousand tokens, and an agent's first prompt is 8-20K tokens, so
expect one to two minutes. Follow-ups start in about 2 s because the server
caches the conversation, longer when a tool result adds a lot of text. A new
session, a changed system prompt or tool set, or an edit to an earlier message
makes it read again from that point, so keep sessions going and turn off MCP
servers a session does not need. Requests share the GPU, so run one agent at a
time.

**Reasoning effort.** The server gives `medium` to chat completions and
Responses requests that name none, so Codex, Hermes and OpenCode need no
setting. Messages requests with no effort get `high`, so `claude-local` asks
for `medium` itself. For `high` on one task:

| Client | How |
|---|---|
| Claude Code | `CLAUDE_CODE_EFFORT_LEVEL=high claude-local` |
| Codex | `codex-local -c model_reasoning_effort=high` |
| Hermes | The `tailnet-high` provider (step 5) |
| OpenCode | **Ctrl+T** in the TUI, or `opencode run --model tailnet/mlx-community/Qwen3.8-27B-4bit#high` |

## 1. Tailscale

Install Tailscale from [its download page](https://tailscale.com/download),
log in with the account the policy grants, and approve the device in the admin
console.

**Check:**

```sh
tailscale status            # lists the server
tailscale ping <machine>    # "via <address>" is direct, "via DERP" relayed
```

## 2. The key

Every client reads the key from `~/.config/llm-server/api-key`, holding the
key alone with **no trailing newline** (OpenCode would send it). Write it from
a command, so the key never reaches a command line or shell history:

```sh
mkdir -p ~/.config/llm-server && chmod 700 ~/.config/llm-server
```

From 1Password, if you saved the key there (README, step 5), with your own
vault, item and field names:

```sh
( umask 077; op read --no-newline "op://<vault>/<item>/<field>" > ~/.config/llm-server/api-key.new ) \
  && mv ~/.config/llm-server/api-key.new ~/.config/llm-server/api-key
```

Or over SSH from the server, which needs Remote Login and your key on it
(README, step 5):

```sh
( umask 077; ssh <machine> 'tr -d "\n" < ~/.config/llm-server/api-key' > ~/.config/llm-server/api-key.new ) \
  && mv ~/.config/llm-server/api-key.new ~/.config/llm-server/api-key
```

The `.new` file keeps the old key if the command fails. When the server's key
changes, run it again and nothing else.

**Check:**

```sh
printf 'header = "Authorization: Bearer %s"\n' "$(cat ~/.config/llm-server/api-key)" \
  | curl -sf -K - "$ENDPOINT/v1/models" | grep -o '"id": *"[^"]*"'
curl -s -o /dev/null -w '%{http_code}\n' "$ENDPOINT/v1/models"
```

The first prints `"id": "mlx-community/Qwen3.8-27B-4bit"`, the second `401`.

## 3. Claude Code

Install Claude Code from [its setup page](https://code.claude.com/docs/en/setup).
Plain `claude` keeps your Anthropic login. `claude-local` uses a separate
config directory, with its own settings, history and MCP servers.

Write this to `~/.local/bin/claude-local`, or another directory on your
`PATH`, and run `chmod 755` on it:

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

`~/.claude-local/settings.json`, with `ENDPOINT` replaced:

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

Why, from Claude Code's [environment variables](https://code.claude.com/docs/en/env-vars):

- The base URL has no `/v1`: Anthropic clients add it.
- Every model alias and subagents name the one model.
- The two window variables and the `unset` line are what the port's
  `splash-m1 claude` launcher sets. No output limit is set, so Claude Code uses
  its default for an unknown model, 32,000.
- `CLAUDE_CODE_ALWAYS_ENABLE_EFFORT` sends the effort to a model ID Claude Code
  does not know. The effort variable outranks `--effort` and `/effort`.
- `WebSearch` needs Anthropic's search backend, which this server lacks.
- `CLAUDE_STREAM_IDLE_TIMEOUT_MS` lets a turn think for over 10 minutes.
  Without it, Claude Code cancels and resends a turn that thinks that long
  ([findings](findings.md#clients)). `API_TIMEOUT_MS` is a precaution for cold
  prompts that take over 10 minutes to read.

**Check:**

```sh
claude-local -p "Reply with the single word OK."   # OK, after a minute or two
claude -p "Reply with the single word OK."         # still your Anthropic account
```

Claude Code prints `[claude-code:unrecognized_model]` first, which is
expected. If the model goes off task and explores the machine with tool calls
instead of answering, stop it and run the check again.

## 4. Codex

Install Codex from [its README](https://github.com/openai/codex). Run it from
a directory it trusts (a git repository you have opened before), or its check
stops before reaching the server. Do not use `codex --oss`, which expects
Ollama.

Codex 0.163.0, the version tested, reads a profile from
`~/.codex/<name>.config.toml`, used with `--profile <name>`. Older versions
read `[profiles.<name>]` tables in `~/.codex/config.toml` instead. For the
profile `local`, `~/.codex/local.config.toml`:

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

Write this to `~/.local/bin/codex-local` and run `chmod 755` on it:

```sh
#!/bin/sh
LLM_SERVER_API_KEY="$(cat "$HOME/.config/llm-server/api-key")" || exit 1
export LLM_SERVER_API_KEY
exec codex --profile local "$@"
```

The window, compaction at 90% of it, and `web_search` match the port's
launcher. No `model_reasoning_effort`, so the server's `medium` applies. The
15-minute `stream_idle_timeout_ms` is a precaution: Codex drops a stream that
sends nothing that long, and its slowest first turn here started after 135 s.

**Check:** `codex-local exec "Reply with the single word OK."`. A warning
about missing model metadata is expected. Plain `codex` still uses your
account.

## 5. Hermes Agent

Install Hermes Agent from [its README](https://github.com/NousResearch/hermes-agent).
The desktop app is optional.

**Remove borrowed credentials first.** On first run Hermes imports what it
finds, such as a Copilot login from `gh`. `hermes auth list` must be empty:
remove anything there (`hermes auth remove copilot 1`). The app's model picker
may still show other providers as signed in, but in 0.21.1 none gets a
request unless you pick it.

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

Why, checked against the 0.21.1 source:

- `key_cmd` lets the app, started without a shell environment, read the same
  file. `provider: main` means `tailnet`, so helper calls stay on the server.
- `write_approval` stages memories and skills for review (`/memory pending`,
  `/skills pending`), so a wrong guess does not reach every future prompt.
- No effort setting: Hermes sends its own only to providers it knows. For
  `high`, add a provider `tailnet-high`, a copy of `tailnet` with
  `extra_body: {reasoning_effort: high}`, and start
  `hermes --provider tailnet-high --model mlx-community/Qwen3.8-27B-4bit`
  (terminal only; the app does not list it).
- **On Hermes 0.21.0 or older** (`hermes --version`), Hermes asks for 65,536
  output tokens unless told otherwise. Add `max_tokens: 32768` under `model:`.
  Upgrading is simpler.

**Check:** `hermes -z "Reply with the single word OK."`, then confirm every
call went to the server:

```sh
sqlite3 ~/.hermes/state.db \
  "SELECT model, billing_base_url, task, api_call_count FROM session_model_usage;"
```

Every row shows `ENDPOINT/v1`. A 404 for `POST /api/show` before the first
request is Hermes probing for Ollama, and harmless. In the app, ask for a
command that needs approval: the prompt must appear.

## 6. OpenCode

Install OpenCode 2 from [its docs](https://opencode.ai/docs).
`~/.config/opencode/opencode.json` (OpenCode reads the key file itself):

```json
{
  "$schema": "https://opencode.ai/config.json",
  "model": "tailnet/mlx-community/Qwen3.8-27B-4bit",
  "providers": {
    "tailnet": {
      "name": "LLM server",
      "package": "@opencode/ai/providers/openai-compatible",
      "settings": {
        "baseURL": "ENDPOINT/v1",
        "apiKey": "{file:~/.config/llm-server/api-key}",
        "chunkTimeout": 1800000
      },
      "models": {
        "mlx-community/Qwen3.8-27B-4bit": {
          "name": "Qwen3.8 27B",
          "capabilities": {
            "reasoning": {"supported": true, "effort": ["low", "medium", "high"]}
          },
          "limit": {"context": 262144, "input": 229376, "output": 32768}
        }
      }
    }
  },
  "agents": {
    "title": {"model": "tailnet/mlx-community/Qwen3.8-27B-4bit"},
    "summary": {"model": "tailnet/mlx-community/Qwen3.8-27B-4bit"},
    "compaction": {"model": "tailnet/mlx-community/Qwen3.8-27B-4bit"}
  },
  "permissions": [
    {"action": "edit", "resource": "*", "effect": "ask"},
    {"action": "webfetch", "resource": "*", "effect": "ask"},
    {"action": "websearch", "resource": "*", "effect": "ask"},
    {"action": "external_directory", "resource": "*", "effect": "ask"},
    {"action": "shell", "resource": "*", "effect": "ask"},
    {"action": "shell", "resource": "git status", "effect": "allow"},
    {"action": "shell", "resource": "git status *", "effect": "allow"},
    {"action": "shell", "resource": "git diff", "effect": "allow"},
    {"action": "shell", "resource": "git diff *", "effect": "allow"},
    {"action": "shell", "resource": "ls", "effect": "allow"},
    {"action": "shell", "resource": "ls *", "effect": "allow"}
  ]
}
```

Keep any other keys already in the file. If it has OpenCode 1 keys
(`provider`, `agent`, `permission` or `small_model`), move what you keep into
`providers`, `agents` and `permissions` as the
[migration guide](https://opencode.ai/docs/migrate-v1) describes, and delete
the old keys. `opencode debug config` shows how OpenCode read the file.

On the server itself, use the provider ID `local` instead of `tailnet`,
everywhere it appears, and set `baseURL` to `http://127.0.0.1:8000/v1`. Keep
both `name` values. OpenCode then shows the model as `Qwen3.8 27B` and the
provider as `LLM server` on every machine, including in a remote session on
the server. Also add these `policies`, so that the server's OpenCode offers
only this model and never OpenCode's hosted free models:

```json
"policies": [
  {"action": "provider.use", "resource": "*", "effect": "deny"},
  {"action": "provider.use", "resource": "local", "effect": "allow"}
]
```

Why:

- `limit` matches the port's launcher.
- `agents`: OpenCode's docs do not say which model the hidden `title`,
  `summary` and `compaction` agents use by default, so each is pinned. Build
  and plan use the top-level `model`, and subagents use their session's model.
- `capabilities.reasoning` gives the low, medium and high variants. With none
  chosen, the server's `medium` applies.
- `chunkTimeout`: Splash sends headers at once and its first token when it has
  read the prompt, about 6 s per thousand tokens. OpenCode's default of 15
  minutes between chunks would drop a cold prompt longer than about 150K
  tokens.
- `permissions`: by default OpenCode edits files, runs commands, fetches URLs,
  searches the web and reads outside the project without asking. These rules
  ask, except for a few read-only commands. The last matching rule wins, so
  `*` comes first.

**Check:**

```sh
opencode run "Reply with the single word OK."
opencode run -c "Now reply with the single word YES."
opencode models | grep '^tailnet/'    # tailnet/mlx-community/Qwen3.8-27B-4bit
```

`opencode run` exits 0 even after an error, so read its output.

## 7. Check the clients you set up

1. Run the check of each client you set up, and note the time to the first
   word of a first turn and of a follow-up.
2. Ask the user to run this on the server:

   ```sh
   grep Started ~/Library/Logs/llm-server/splash.log | tail -20
   ```

   Claude Code's turns show `effort medium`. Codex's, Hermes's and OpenCode's
   show `effort absent → medium` (or `medium`), and OpenCode's titles may show
   `low`. A `high` or `xhigh` nobody asked for is a failure.

**When re-testing for `docs/findings.md`:** also work on a real task in one
Claude Code or OpenCode session until its context passes 64K tokens. Note
anything refused, dropped or resent, and how long turns take to start as it
grows. Report what passed and failed, with the times.
