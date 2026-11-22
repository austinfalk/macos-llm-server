# Connecting a client

How to use the server from another Linux or macOS machine with OpenCode.
Follow the steps in order, running each check before the next. Last followed
on a Linux client on 2026-10-18 with OpenCode 2.0.32
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
shows, or TLS and Splash's host check fail. Replace `ENDPOINT` in the config
below. In shell commands, set it once with `export ENDPOINT=https://...`.

Four facts shape every config:

- **One model ID** for every model setting, helpers and subagents included:
  the `Model` line `3-services.sh` printed. The config below uses the default,
  `mlx-community/Qwen3.8-27B-4bit`. If the server's differs, replace it
  everywhere. Splash answers any other name with 404.
- **No sampling settings.** Splash applies Qwen's defaults when a request sets
  none.
- **About 32K output tokens and long timeouts.** The model thinks first, the
  limit counts the thinking, and a reply cut off while thinking comes back
  empty. OpenCode's config sets 32,768.
- **The window `/v1/models` reports as `context_length`**, 262,144 tokens for
  the default model. If the server's differs, use its value and recompute the
  limit derived from it, OpenCode's `input`. Sessions have reached 95K. If a
  client fails near the limit, lower its window to 144,384, which OpenCode has
  run with, and record it in [findings](findings.md).

Any other client of the OpenAI API (chat completions or Responses) or of
Anthropic's Messages API works with the key, the model ID and the base URL
`ENDPOINT/v1`. Give a Messages client the base URL `ENDPOINT` instead,
because it adds `/v1` itself.

**Working with it.** The first turn is slow. On the M1 Max the server reads a
new prompt at about 6 s per thousand tokens, and an agent's first prompt is 8-20K tokens, so
expect one to two minutes. Follow-ups start in about 2 s because the server
caches the conversation, longer when a tool result adds a lot of text. A new
session, a changed system prompt or tool set, or an edit to an earlier message
makes it read again from that point, so keep sessions going and turn off MCP
servers a session does not need. Requests share the GPU, so run one agent at a
time.

**Reasoning effort.** The server gives `medium` to chat completions and
Responses requests that name none, so OpenCode needs no setting. Messages
requests with no effort get `high`, which Qwen's template renders as `xhigh`
([findings](findings.md#reasoning-effort)). Set `medium` in a Messages
client. For `high` on one OpenCode task, press **Ctrl+T** in the TUI, or run
`opencode run --model tailnet/mlx-community/Qwen3.8-27B-4bit#high`.

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

## 3. OpenCode

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

## 4. Check OpenCode

1. Run the check in step 3, and note the time to the first word of a first
   turn and of a follow-up.
2. Ask the user to run this on the server:

   ```sh
   grep Started ~/Library/Logs/llm-server/splash.log | tail -20
   ```

   OpenCode's turns show `effort absent → medium` (or `medium`), and its
   titles may show `low`. A `high` or `xhigh` nobody asked for is a failure.

**When re-testing for `docs/findings.md`:** also work on a real task in one
OpenCode session until its context passes 64K tokens. Note
anything refused, dropped or resent, and how long turns take to start as it
grows. Report what passed and failed, with the times.
