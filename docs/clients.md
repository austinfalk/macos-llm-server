# Connecting a client

How to use the server from another Linux or macOS machine with OpenCode.
Follow the steps in order, running each check before the next. Written for
OpenCode 2.3.2, and not yet followed against mlx-serve.

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
shows, or TLS fails. Replace `ENDPOINT` in the config below. In shell
commands, set it once with `export ENDPOINT=https://...`.

Four facts shape every config:

- **One model ID** for every model setting, helpers and subagents included:
  the `Model` line `3-services.sh` printed. The config below uses the default,
  `Inkling-2-Mini-Uncensored-q4attn`. If the server's differs, replace it everywhere.
  mlx-serve answers a name it does not know with its one model instead of an
  error, so a wrong ID goes unnoticed.
- **No sampling settings.** mlx-serve applies the model's own defaults when a
  request sets none.
- **About 32K output tokens and long timeouts.** The model thinks first, the
  limit counts the thinking, and a reply cut off while thinking comes back
  empty. OpenCode's config sets 32,768.
- **A window of 262,144 tokens.** The server pins it, below the model's own
  1,048,576 tokens, and reports it in `/v1/models` as `context_length`.

Any other client of the OpenAI API (chat completions or Responses) or of
Anthropic's Messages API works with the key, the model ID and the base URL
`ENDPOINT/v1`. Give a Messages client the base URL `ENDPOINT` instead,
because it adds `/v1` itself. mlx-serve also speaks Ollama's API at
`ENDPOINT`.

**Working with it.** The first turn is slow. The M1 Max reads a prompt at
about 420 tokens a second, and an agent's first prompt is 8-20K tokens, so
expect 20-50 s there. Follow-ups start sooner,
because the server caches the conversation so far. A new session, a changed
system prompt or tool set, or an edit to an earlier message makes it read
the prompt again, from the start when the change is more than about 2,000
tokens back ([findings](findings.md#what-mlx-serves-notes-say-about-this-model)).
So keep sessions going and turn off MCP servers a session does not need. Requests share the GPU, so run one agent at a time.

**Reasoning effort.** A request that names no effort thinks at `high`,
Inkling's default ([findings](findings.md#reasoning-effort)), so OpenCode
needs no setting. For a quicker answer on one OpenCode task, press
**Ctrl+T** in the TUI, or run
`opencode run --model tailnet/Inkling-2-Mini-Uncensored-q4attn#medium`.

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
changes, run it again, then `opencode service restart`: OpenCode reads the
file when it loads its config, and its background server keeps the key it
read.

**Check:**

```sh
printf 'header = "Authorization: Bearer %s"\n' "$(cat ~/.config/llm-server/api-key)" \
  | curl -sf -K - "$ENDPOINT/v1/models" | grep -o -E '"(id|context_length)": *("[^"]*"|[0-9]+)' | head -2
curl -s -o /dev/null -w '%{http_code}\n' "$ENDPOINT/v1/models"
```

The first prints `"id":"Inkling-2-Mini-Uncensored-q4attn"` and
`"context_length":262144`, the second `401`.

## 3. OpenCode

Install OpenCode 2 from [its docs](https://opencode.ai/docs).
`~/.config/opencode/opencode.json` (OpenCode reads the key file itself):

```json
{
  "$schema": "https://opencode.ai/config.json",
  "model": "tailnet/Inkling-2-Mini-Uncensored-q4attn",
  "providers": {
    "tailnet": {
      "name": "LLM server",
      "package": "@opencode/ai/providers/openai-compatible",
      "settings": {
        "baseURL": "ENDPOINT/v1",
        "apiKey": "{file:~/.config/llm-server/api-key}",
        "chunkTimeout": 3600000
      },
      "models": {
        "Inkling-2-Mini-Uncensored-q4attn": {
          "name": "Inkling 2 Mini Uncensored",
          "capabilities": {
            "reasoning": {"supported": true, "effort": ["low", "medium", "high"]}
          },
          "limit": {"context": 262144, "input": 229376, "output": 32768}
        }
      }
    }
  },
  "agents": {
    "title": {"model": "tailnet/Inkling-2-Mini-Uncensored-q4attn"},
    "summary": {"model": "tailnet/Inkling-2-Mini-Uncensored-q4attn"},
    "compaction": {"model": "tailnet/Inkling-2-Mini-Uncensored-q4attn"}
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

Keep any other keys already in the file.
`opencode debug config --standalone` shows how OpenCode read it.

If a package manager installed OpenCode (Homebrew, mise), add
`"update": "disable"`, so OpenCode leaves updates to it.

On the server itself, use the provider ID `local` instead of `tailnet`,
everywhere it appears, and set `baseURL` to `http://127.0.0.1:8000/v1`. The
server asks for the key from this Mac too. Keep both `name` values. OpenCode
then shows the model as `Inkling 2 Mini Uncensored` and the provider as `LLM server` on
every machine, including in a remote session on the server. Also add these
`policies`, so that the server's OpenCode offers only this model and never
OpenCode's hosted free models:

```json
"policies": [
  {"action": "provider.use", "resource": "*", "effect": "deny"},
  {"action": "provider.use", "resource": "local", "effect": "allow"}
]
```

Why:

- `limit`: `context` is the server's window, and `input` is that window less
  the output limit. The output limit
  counts thinking, and mlx-serve keeps no room for the answer, so a reply cut
  off while thinking comes back empty (mlx-serve's
  [reasoning notes](https://github.com/ddalcu/mlx-serve/blob/v26.11.4-pre-release.1/docs/reasoning-protocols.md)).
  32,768 leaves room for both.
- `agents`: OpenCode's docs do not say which model the hidden `title`,
  `summary` and `compaction` agents use by default, so each is pinned. Build
  and plan use the top-level `model`, and subagents use their session's model.
- `capabilities.reasoning` gives the low, medium and high variants. With none
  chosen, Inkling's default `high` applies.
- `chunkTimeout`: by default OpenCode gives up on a stream after 15 minutes
  without a chunk. A cold prompt near the limit takes longer than that to
  read: about 20 minutes on the M1 Max. mlx-serve
  sends a keepalive on a silent stream every 5 s, but whether OpenCode counts
  one as a chunk is not checked, so the timeout is 60 minutes.
- `permissions`: by default OpenCode edits files, runs commands, fetches URLs,
  searches the web and reads outside the project without asking. These rules
  ask, except for a few read-only commands. The last matching rule wins, so
  `*` comes first.

**Check:**

```sh
opencode run --standalone "Reply with the single word OK."
opencode run --standalone -c "Now reply with the single word YES."
opencode models --standalone | grep '^tailnet/'    # tailnet/Inkling-2-Mini-Uncensored-q4attn
```

Without `--standalone`, these commands use a background `opencode serve`,
starting one if none is running. A server keeps the config it read when it
started, so after an edit it answers with the old one. `opencode run` exits 0
even after an error, so read its output.

## 4. Check OpenCode

1. Run the check in step 3, and note the time to the first word of a first
   turn and of a follow-up.
2. Ask the user to run this on the server:

   ```sh
   grep 'POST /v1/' ~/Library/Logs/llm-server/mlx-serve.log | tail -20
   ```

   Each OpenCode turn shows a `POST /v1/chat/completions` line. An error after
   one of them is a failure.

**When re-testing for `docs/findings.md`:** also work on a real task in one
OpenCode session until its context passes 64K tokens. Note
anything refused, dropped or resent, and how long turns take to start as it
grows. Report what passed and failed, with the times.
