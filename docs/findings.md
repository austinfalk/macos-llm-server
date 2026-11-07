# Findings

The measurements behind the recommendations in the [guide](../README.md). Each
section says what was measured, when, and what it changed. All of it ran on a
MacBook Pro 16" (M1 Max, 10-core CPU, 32-core GPU, 64 GB).

The findings come in two parts:

1. Part 1, [the server](#the-server-splash-for-m1m2-and-qwen38-27b), is the
   server as it runs now, Splash's M1/M2 port 1.5.0-m1 on its defaults, on
   macOS 27.0.1. It covers the settings, startup, speed, idle release, clients,
   known gaps and what is not measured.
2. Part 2, [the Mac](#the-mac), covers heat, unattended operation, security,
   and whether local is worth it.

Items marked *(sourced)* come from the linked references and were not
reproduced here. Everything else was.

---

## The server: Splash for M1/M2 and Qwen3.8-27B

Since 2026-10-18 the server runs
[paperniuk/splash](https://github.com/paperniuk/splash), since 2026-11-07
release 1.5.0-m1 (2026-11-01), an unofficial port of [Splash](https://github.com/incoai/splash)
for M1 and M2. Splash, by Inco, needs an M3 or newer and refuses older GPUs.
The port adds Metal kernels for Apple7 and Apple8 GPUs (M1, M2), bounded
prefill commands so that macOS does not abort long prompts
(`ImpactingInteractivity`), and Neural Engine prefill on M1 and M2
*(sourced)*. Its author tested it on an M1 Max, not on an M2 *(sourced)*.
1.5.0-m1 is Splash 1.5.0 with the port's kernels on top *(sourced)*.
[Upgrade to 1.5.0-m1](#upgrade-to-150-m1) has what the upgrade changed here,
and why the server skipped 1.6.0-m1.

### Settings

Everything is stock except the service. Splash comes from the port's release
installer, pinned by version and SHA-256. The model is the MLX 4-bit
checkpoint the port's release notes name, `mlx-community/Qwen3.8-27B-4bit`,
and Splash pairs it with its DFlash2 draft, `incoai/Qwen3.8-27B-DFlash2`,
without a flag. Splash ships no service manager, so the repository's own
LaunchAgent runs it (README, step 5) with three flags:

- `--model` chooses the model. Its repository ID is the model ID clients use.
- `--allowed-host`, with the machine's tailnet name, lets requests through
  `tailscale serve` in. Splash answers 403 to a Host name it does not know
  ("Host example.com is not allowed; restart the server with --allowed-host
  example.com"), a guard against DNS rebinding, and `tailscale serve` passes
  the tailnet name on. With the flag the endpoint answered 200. The server was
  not run without it.
- `--default-reasoning-effort medium` gives `medium` to chat completions and
  Responses requests that name no effort, instead of the template's `xhigh`.
  [Reasoning effort](#reasoning-effort) has the evidence, and why Messages
  requests do not get it.

Everything else is Splash's default. Splash listens on 127.0.0.1, port 8000.
It frees the weights after 10 idle minutes ([Idle release](#idle-release)). It
admits up to 32 requests at once, running or waiting, and answers 503 to more
(`--queue-size`). It keeps the Mac awake while requests run, though the display
may still sleep (`--allow-idle-sleep` turns that off). The port's
`server/serve_options.py` gives the last two *(sourced)*.
`sudo sh scripts/verify.sh` passed with 0 failures on these settings
(2026-10-18).

**The checkpoint.** Inco's earlier `incoai/Qwen3.8-27B-Splash` packages no
longer load since Splash 1.3.1, which stops and names the MLX model instead
("the MLX 4-bit models hold the same weights") *(sourced)*. The port measured
this checkpoint on an M1 Max at 61.5 tok/s on a code prompt at temperature 0,
and 51.5 over six mixed prompts. It measured Qwen3.6-35B-A3B at 127 tok/s.
Prose is slower than code, because the draft guesses fewer of its tokens
*(sourced)*.

**Changed** (2026-10-18): the server uses Splash's defaults where it can. The
LaunchAgent had passed five flags, and three of them kept the port and model
ID that clients already used. `--port 8080` kept the port, and
`--served-model-name local-model` with `--announce-served-name` kept the model
ID. Splash now listens on its default port, 8000. The model ID is the
repository ID, `mlx-community/Qwen3.8-27B-4bit`. Clients that ask for
`local-model` must ask for the repository ID instead. The alias is not needed
for clients that check the name. Splash's DEVELOPMENT.md ("API model aliases")
says some clients reject a response whose `model` differs from the name they
asked for, and a client that asks for the repository ID gets it back
*(sourced)*. And the LaunchAgent passes `--default-reasoning-effort medium`, on
the evidence in [Reasoning effort](#reasoning-effort).

### Reasoning effort

Qwen3.8's template knows `low`, `medium` and `xhigh`, its default. The
server's default is `medium` because of these measurements by others
*(sourced)*:

- Kodesage asked agentic questions about a codebase (45, one run per effort,
  judged by Claude Opus 4.6 against reference answers). Substance was 7.79 at
  `low`, 8.18 at `medium` and 8.61 at `xhigh`, with medians of 95, 76 and
  143 s. `low` was slower than `medium` because it took more agent rounds.
- Jose Romero ran four single-turn coding tasks on a Ryzen AI Max+ 395. They
  took 22 min at `medium` against 2 h 36 min at `xhigh` (160,571 output
  tokens), and each effort won one task.
- In QwenLM/Qwen3.8 #216, about 19% of `xhigh` calls (18 of 93) returned an
  empty answer after thinking, and none of 95 at `low` or `medium`.

**A Messages request with no effort runs at `xhigh`.** When a Messages
request asks for thinking and names no `output_config.effort`, Splash gives it
`high` (`server/api_shapes.py:686` in the port,
`effort = _field(output_config, "effort", "high")`). The request then carries
an effort, and `--default-reasoning-effort` applies only to a request without
one (`server/frontend.py:860`). If Qwen3.8's template raises an error on
`high`, Splash renders the alias `xhigh` instead (`render_chat_template` and
`REASONING_EFFORT_ALIASES = {"high": "xhigh", ...}` in
`server/chat_templates.py:99`); whether it does was not checked. This is read from the
installed port, 1.3.2-m1.1 and again 1.4.0-m1, and was not measured. `claude-local` asks for
`medium` itself with `CLAUDE_CODE_EFFORT_LEVEL`, and the client guide's step 7
logged `effort medium` for it ([Clients](#clients)).

### Startup

This is the first start, on 2026-10-18, with the files already downloaded.
Splash began loading at 17:13:19 and a second later logged "Chat template ·
patched to render later system messages in place (the original template rejects
them)". It loaded the weights in 7.5 s, chose its "Kernel policy for GPU family
7 with 32 cores", and calibrated the Neural Engine's share of the prefill FFN
in 72.6 s, at 0.47 ("79.3 ms per 2048-row FFN layer against 142.3 on the GPU
alone"). It sized the SSD cache at 32 GiB, and at 17:14:56 logged "Ready ·
context 256K", which is 262,144 tokens, the model's native window. With the
server idle, wired memory was about 33 GiB, and the engine's resident size
7.4 GB. Later starts reuse the calibration. A restart was ready 22 s after
loading began.

### Upgrade to 1.5.0-m1

On 2026-11-07 the server moved from 1.4.0-m1 to 1.5.0-m1 with
`1-install.sh` and `3-services.sh`. The port's notes measure the 27B MLX
4-bit on an M1 Max at the same speed as 1.4.0-m1 *(sourced)*. The release's
changes are for other checkpoints, local model folders (`--model-dir`), and a
256-row floor for a prefill that runs beside a decode, which can pause a
decoding client for about 3 s instead of about 1 s *(sourced)*. The
checkpoint, its draft and every setting stayed the same. The installer's
SHA-256 matches the release notes, and it differs from 1.4.0-m1's only in its
version.

The endpoint was down for 68 s, from Splash stopping to "Ready". The build
calibrated the Neural Engine again, in 41.4 s, and kept share 0.47. Weights
loaded in 6.3 s. `3-services.sh` passed its checks (200 with the key, 401
without). Two single-turn chats and a three-turn chat that reused its cached
prefix answered correctly, with no effort given, at `medium`.

**1.6.0-m1 was tried first and rolled back.** It is the newest release
(2026-11-06). The same `3-services.sh` checks passed, and then every chat
but one failed. Splash logged "Engine failed
· native loop did not answer status within 30 s", answered 503
`runtime_unavailable`, and restarted the engine, which took about 40 s each
time. Prompts of 17 and 25 tokens failed. An 11-token prompt passed. This is the port's issue #51: on M1 and M2 a
request hangs when its last prefill chunk is 17 to 32 rows, and draft PR #52
has a one-line fix *(sourced)*. The reporters there found 1.5.0-m1 unaffected
*(sourced)*, and the same 17- and 25-token prompts passed on it here. The
server stays on 1.5.0-m1 until a release includes the fix.

### Upgrade to 1.4.0-m1

On 2026-10-31 the server moved from 1.3.2-m1.1 to 1.4.0-m1 with
`1-install.sh` and `3-services.sh`. The port's notes promise faster prompt
appends, 1.14-1.31 times faster long-context attention, and 1-3% faster
decode for the 27B MLX 4-bit on an M1 Max *(sourced)*. The checkpoint, its
draft and every setting stayed the same.

The endpoint was down for 89 s, from the restart in `3-services.sh` to its
checks passing. The new build calibrated the Neural Engine again, as its
notes said it would. It took 54.9 s and kept share 0.47 ("79.0 ms per
2048-row FFN layer against 142.0 on the GPU alone"). Weights loaded in 7.5 s
and Splash was ready 85 s after loading began. `/v1/models` still reports
`context_length` 262,144. A short chat with no effort ran at `medium`, as
before, and wrote 61.1 tok/s at 5.8 tokens a cycle. `sudo sh scripts/verify.sh`
passed with 0 failures and 0 warnings. [Speed](#speed) compares it with
1.3.2-m1.1.

### Speed

Measured on 2026-10-18, on 1.3.2-m1.1. Each case was a streamed chat completion, timed on the
client. First token is the time to the first token. Read is the prompt tokens
over that time. Write is the completion tokens less one over the time from the
first token to the last. Requests asked for `reasoning_effort: medium`, as the
clients do, with the server's default sampling and 512 output tokens (1,024
for the short code request). Each case ran three times, and each run's prompts
started with a fresh nonce so that cold cases stayed cold. The prompts are
this repository's files from `main`. Medians, with the range in parentheses,
and read and write in tok/s:

| Case | Prompt tokens | First token | Read | Write |
|---|---|---|---|---|
| A question about `verify.sh`, cold | 2,615 | 14.1 s | 185 | 38.0 (33.1-44.5) |
| Its follow-up, cached | 2,640-2,870 | 2.1 s | | 33.9 (26.1-34.6) |
| README and three scripts, cold | 12,107 | 67.9 s | 178 | 26.0 (25.4-32.1) |
| A short code request | 63-67 | 1.0 s | | 33.1 (28.7-35.3) |
| README, findings, client guide and four scripts, cold | 31,349 | 208.2 s | 151 | 25.1 (22.3-28.0) |
| Its follow-up, cached | 31,370 | 1.1 s | | 22.8 (20.2-22.9) |

**On 1.4.0-m1.** On 2026-10-31 the same script ran the first four cases
again, three runs each, after a warm-up request. Its prompts came from the
commit `main` was at on 2026-10-18, and their token counts match the table.
The 31K cases were left out to keep the run under 10 minutes.

| Case | First token | Read | Write |
|---|---|---|---|
| A question about `verify.sh`, cold | 12.9 s | 203 | 44.0 (42.2-46.1) |
| Its follow-up, cached | 1.5 s | | 34.4 (33.7-35.6) |
| README and three scripts, cold | 60.4 s | 201 | 32.7 (29.0-35.5) |
| A short code request | 0.9 s | | 41.3 (40.2-45.2) |

Cold prompts read 10-13% faster, and every case wrote faster, by 2-26%.
How much of that is the new build is not known. Splash's log puts the decode
cycle at 94-101 ms, against about 109 ms on 1.3.2-m1.1 (below). That is
8-14% faster, more than the 1-3% the port's notes claim for this checkpoint
*(sourced)*, and those notes claim no change in cold prefill. The 2026-10-18
run came straight after another benchmark, so the Mac may not have been in the
same state; that was not checked. Long-context attention,
the release's largest change, was not measured.

Reading and writing both slow as the conversation grows. Cached follow-ups
start in 1-2 s. The replies were coherent (spot-checked). At `medium`, 512
tokens is mostly thinking.

**Why the short code request writes slower than the port's 61.5 tok/s.**
Splash's log reports how many tokens each draft cycle yields. This text gave
3.0-4.6 a cycle, mostly thinking prose. The port's code prompts give 6-7 (its
issue #11) *(sourced)*. Greedy, with thinking off, the code request wrote
38 tok/s at 4.2 tokens a cycle. That is a decode cycle of about 109 ms here,
against the port's 97 ms on an M1 Max with macOS 26.7.1 *(sourced)*. So the
kernels run within about 12% of the port's, and the difference is how much of
the draft this text accepts. In the port's issue #11, an M1 Max on macOS
27.0.1 also measured cycles about 20% slower than the port's machine, with the
GPU at full clock *(sourced)*.

### Idle release

Measured on 2026-10-18. Splash frees the weights after 10 idle minutes
(`--idle-release 10m`) and restores them for the next request.
`POST /v1/memory/release` does the same at once. After it, three short
requests ran. The log said "Weights restored in 5.98 s", the first request's
time to first token was 6.3 s (0.3 s for the next two), and it wrote at
31.1 tok/s (27.5-28.3 for the next two). So a request after 10 idle minutes
waits about 6 s more, and nothing else was slower. The setting stays at its
default. `--idle-release off`, which upstream added for dedicated servers
(incoai/splash #292) *(sourced)*, is the candidate if those 6 s matter.

### Clients

Each client ran twice from a Linux client machine on 2026-10-18. The first run
was before the change to Splash's defaults, with port 8080, the `local-model`
ID and an earlier version of the client guide. The second followed the client
guide's step 7 with the current settings.

**The API shapes** (2026-10-18, on the Mac):

- Keys. Without one, `/v1/models` and `/metrics` answer 401. `x-api-key`
  works, and `/health` is `{"status":"ok"}`. `/v1/models` listed the served
  ID, at the time `local-model`, with `context_length` 262,144.
- Claude Code's shapes. A mid-conversation system message after an assistant
  turn got 200, because Splash patches the template to render it in place
  ([Startup](#startup)). A JSON-schema `output_config`, as in Claude Code's
  title requests, got 200 with valid JSON.
- Codex's shape. `/v1/responses` with
  `include: ["reasoning.encrypted_content"]` and `store: false` got 200, with
  `encrypted_content` in its reasoning item, and so did a second turn that sent
  the output items back.

**Claude Code itself** (2.x, on the Mac). `splash-m1 claude -p "Reply with the
single word OK."` answered "OK" in one turn. The launcher points
`ANTHROPIC_BASE_URL` at the server, passes the key as the auth token, names the
served ID for every model, and sets `CLAUDE_CODE_MAX_CONTEXT_TOKENS` and
`CLAUDE_CODE_AUTO_COMPACT_WINDOW` to the server's context. Claude Code's first
request is about 21,200 tokens, its system prompt and 22 tools, read cold in
114.5 s. Follow-ups were cached. Claude Code asks for effort `high`. A first
attempt went off task. Instead of answering, the model explored the
environment with tool calls for about 14 turns before it was stopped, and
Claude Code's permission prompts refused all but `whoami`, `pwd` and `ls`. The
tool calls and their results passed correctly. So under Claude Code's prompt
this model can ignore a trivial instruction.

**OpenCode from the client machine** (1.18.34, its existing config unchanged,
2026-10-18). "summarize the readme" worked, with a complete answer. The first
request after 13 idle minutes restored the weights in 5.8 s. The title request
(569 tokens, effort `low`) ran alongside the first turn (8,528 tokens cold,
effort `medium`), which started writing after 56.0 s and made a tool call at
55.3 tok/s. The second turn read the README, 15,810 tokens with 8,512 cached.
Its first token came after 40.6 s, then 512 tokens at 30.9 tok/s. From the
question to the last token took 1 min 48 s.

**Claude Code from the client machine** (`claude-local`, the client guide's
setup, 2026-10-18). It worked on the first try. A small request (739 tokens,
thinking off) took 4.9 s. The first turn, 20,109 tokens cold at effort `high`
(Claude Code's own choice) with 23 tools, started writing after 111.9 s and
made a tool call. The second turn, 27,249 tokens with 20,096 cached, started
after 45.9 s and wrote 872 tokens at 26.6 tok/s. It took 3 min 15 s in all,
with nothing refused.

**Hermes Agent from the client machine** (0.21.0, its existing config
unchanged, 2026-10-18). It worked, in five requests over 3 min 43 s, with
effort `medium` arriving through `extra_body` and 20 tools. The first turn,
12,177 tokens cold, started writing after 61.4 s. Most follow-ups started in
about 2 s. One turn found only 8,192 of its 13,742 tokens cached although the
turn before had 12,352. Hermes's prompt probably changed before that point
(not confirmed), and that turn waited 30.2 s. Before its first request Hermes
asked for Ollama's `POST /api/show`, which Splash answers 404. Hermes went on
without it.

**Codex from the client machine** (`codex-local`, the client guide's setup,
2026-10-18). It worked, in six requests over 3 min 44 s, at effort `medium`
with 44 tools. A side request of 4,647 tokens ran alongside the first turn,
18,600 tokens cold, which started writing after 134.8 s (about 138 tok/s,
below the usual 180, probably for sharing the engine with the side request).
Codex sends its encrypted reasoning back each turn, and turns 2-5 went
through with their prompts cached, starting after 2-19 s.

So all four clients work against Splash from the client machine. Hermes and
OpenCode use chat completions, the endpoint measured above. Splash's own
launchers (`splash-m1 claude|codex|opencode|hermes|pi`) connect to a server on
the same Mac only, so another machine configures each client by hand, as the
client guide does. The launchers' settings are in the port's
`install/clients.py`. OpenCode, Pi and Hermes get a 32K output limit, and
OpenCode and Hermes a quarter of the context when it is under 128K
*(sourced)*.

**Step 7 of the client guide** (2026-10-18, with the current settings). The
client machine followed the guide with Claude Code 2.1.302, Codex 0.163.0,
Hermes 0.21.1 and OpenCode 2.0.32. All four passed. The times are wall times for each whole command, from one run
each, not the time to the first token:

| Client | First turn | Follow-up |
|---|---|---|
| `claude-local -p` | 97 s (16,165-token prompt) | not run |
| `codex-local exec` | 99 s (18,170) | not run |
| `hermes -z` | 71 s (12,728) | not run |
| `opencode run` | 54 s (9,655) | 2 s (9,696, of which 9,632 cached) |

The weights had been released after 10 idle minutes, so `claude-local`'s turn
includes the 5.82 s Splash took to restore them. Splash logged `effort medium`
for `claude-local`, `effort absent → medium` for Codex, Hermes and OpenCode,
and `low` for OpenCode's title requests. OpenCode's `#high`, `#low` and
`#medium` model variants arrived as `high`, `low` and `medium`.

**The long session** (2026-10-18, step 7.4). One `claude-local -p --continue`
session in this repository ran a read-only documentation audit with Read, Grep
and Glob. Context sizes are from the session transcript:

| Prompt | Time | Requests | Output tokens | Context at its last request |
|---|---|---|---|---|
| 1 | 116 s | 3 | 1,618 | 25,164 |
| 2 | 850 s | 9 | 15,435 | 41,185 |
| 3 | 753 s | 3 | 11,262 | 67,132 |
| 4 | 370 s | 10 | 6,677 | 74,875 |
| 5 | cancelled and sent again, then stopped | | | 94,953 (from the Splash log) |

- Nothing was refused or dropped before prompt 5. The cache kept up. A
  request at 70,916 tokens read only 196 of them new.
- The time went to thinking, not reading (inferred from the timings). Each
  prompt's time follows its output tokens. Prompt 2's longest request had
  6,881 new tokens to read and reached its first token in 60.4 s, then wrote
  14,296 tokens at 21.2 tok/s.
- A first attempt was stopped during prompt 1 and started again, because it
  overlapped a Hermes desktop test and the two slowed each other down.

**Claude Code cancels a turn that thinks for 10 minutes.** In prompt 5, Splash
logged the first token at 163.1 s, then 12,139 tokens at 20.2 tok/s, all of it
thinking that Claude Code did not show. At 763 s it logged `Cancelled`,
599.9 s after the first token. Claude Code then sent the identical request
again (the same `requestDigest`), which would have had to think again from the
start. While the model thinks, Splash sends Claude Code only a `ping` event
every 2 s. That holds for thinking with `display: omitted`, which Claude Code
asks for in `-p` sessions, and with `display: updates`, which it asks for in
interactive ones. Claude Code accepts about five minutes of pings, then waits
300 s more for an event it parses, and then cancels the request and sends it
again *(sourced)*. The port's Claude Code launcher does not set this timeout.
With `CLAUDE_STREAM_IDLE_TIMEOUT_MS=1800000`, two turns of the resumed
session, at 95K tokens of context, thought for 794 s and 843 s after their
first tokens. Both finished with `Done` at the 32,000-token output limit.
An earlier check without the long context was inconclusive, because each
request reached the output limit in about 9 minutes, before the old cutoff.

**Changed:** the client guide sets `CLAUDE_STREAM_IDLE_TIMEOUT_MS` to
1800000, 30 minutes, in `claude-local`'s settings, and follows OpenCode 2.x
and Hermes 0.21.1 (PR #8).

### Known gaps

The port lists these *(sourced)*:

- No fast attention kernel for `--kv-format bf16`, which runs 1.7-1.9 times
  slower, so the INT8 default stays.
- MLX checkpoints were untested end to end on M1 before 1.3.2-m1.x.
- Nothing below 64 GB has been measured.

### Not measured

- Lid-closed operation on battery. It was verified on mains only, in
  [Unattended operation](#unattended-operation).
- Recovery from a power cut, and the battery watchdog firing.
- Heat under Splash, and heat beyond 10 minutes of sustained load, once
  thermal pressure is Heavy. [Heat](#heat) was measured before Splash.
- Coding quality on this server. The guide defers to the published results of
  Splash, its M1/M2 port and Artificial Analysis rather than running
  benchmarks.
- How much time `medium` reasoning effort saves on a real session.
- A long interactive `claude-local` turn with `CLAUDE_STREAM_IDLE_TIMEOUT_MS`
  set. The check above ran `claude-local -p`.
- Where OpenCode 2.x sends a `summary` request, whose agent the client guide
  pins to the server.
- `uninstall.sh` against Splash. It is destructive by design.
- Any Mac other than this one: an M2, an M3 or later, or anything with less
  than 64 GB. The port's author has not tested an M2 either *(sourced)*.

---

## The Mac

These findings are about the Mac rather than the engine.

### Heat

Measured on 2026-09-24, before the server ran Splash, on macOS 27.0. Ten
minutes of continuous decoding, requests back to back, plugged in, lid open:

| | first 6 min | last 4 min |
|---|---|---|
| GPU clock | 1,289-1,291 MHz | 1,289-1,291 MHz |
| GPU power | ~33 W | ~34 W |
| macOS thermal pressure | Nominal | Nominal, then **Heavy** from 8.7 min |

**No throttling.** The GPU stayed at its maximum clock for all 120 samples,
including the 70 seconds under Heavy pressure, and the decode rate did not
fall. Not settled: what happens if Heavy pressure lasts; it appeared only at
the end.

### Unattended operation

Measured on 2026-09-27.

**It keeps serving with the lid shut, on mains power.** With `pmset -a
disablesleep 1` (`SleepDisabled 1`), the lid closed (`AppleClamshellState =
Yes` in `ioreg`) and AC attached, the Mac answered requests from a Linux
client from 13:35 to past 15:00 on 2026-09-27, and SSH and Screen Sharing
worked throughout. `pmset -g log` has 920 entries that day and no `Sleep`,
`Wake` or `DarkWake` event on it or the day before; uptime was 19 h. The first
hour of requests came before any Screen Sharing session, so `screensharingd`'s
sleep assertion was not what kept it awake.

`launchctl bootout` returns before the job is gone; an immediate `bootstrap`
of the same label fails with `5: Input/output error`. Hence `stop_job` and
`start_job` in `scripts/lib.sh`.

### Security

Found by 2026-10-03, except where an item says otherwise.

- **Tailscale ACLs do not cover the local network** *(sourced)*. With the macOS
  firewall off, anything listening on all interfaces is on the LAN; before
  hardening, SSH offered password authentication to it.
- **macOS sshd ignores `ListenAddress`**: launchd owns the socket. Source
  restrictions have to be per-connection (`Match Address`).
- **A `Match Address` list of only negations matches nothing.**
  `Match Address !100.64.0.0/10,!127.0.0.1` looks like "everything except
  these" and silently applies to no connection at all; it needs a positive
  pattern first: `Match Address *,!100.64.0.0/10,...`. Caught by
  `verify.sh`, which asks `sshd -T -C` what it would apply to a LAN address
  rather than trusting the file.
- **OpenSSH 10.5 prints `sshd -T` keywords in mixed case**
  (`PasswordAuthentication no`, not `passwordauthentication no`), as on this
  Mac with macOS 27.2. `verify.sh` and `4-harden.sh` matched the lowercase
  names, so on 2026-11-07 `verify.sh` failed both password checks with an
  empty value while sshd still refused passwords. Both scripts now compare
  the keyword in any case.
- **`fdesetup enable` can print no recovery key** (2026-11-07, macOS 27.2).
  On APFS it keeps a personal recovery key from an earlier enablement and
  creates none (`man fdesetup`). The key System Settings showed, its copy in
  Passwords, did not pass `fdesetup validaterecovery`. After
  `fdesetup changerecovery -personal`, the new key passed, and Settings still
  showed the old one. The man page allows one personal recovery key at a time,
  so the copy in Passwords was stale, not a second key.
  [Six Colors](https://sixcolors.com/post/2026/05/filevault-keys-cant-be-escrowed-in-iCloud-anymore/)
  reports Settings and Passwords out of step with the Mac's key before, fixed
  by turning FileVault off and on in Settings *(sourced)*.
- **pf filters loopback.** Rules that pass only tailnet sources also drop
  connections from 127.0.0.1, so Screen Sharing's port never answers on the
  Mac itself. A connection to the machine's own LAN address comes from that
  address, so `verify.sh`'s local-network test still sees it dropped.
- **Root and Homebrew.** Homebrew's prefix belongs to the user, so a job root
  runs from it lets anything running as that user become root at its next
  start. The model server is a LaunchAgent in the user's session and runs as
  that user. Until 2026-11-07, `tailscaled` ran as root from Homebrew, as its
  formula says (`sudo brew services`), from
  `/opt/homebrew/opt/tailscale/bin/tailscaled`. The binary was root's, but
  `opt/` and the version's folder were the user's, so the user could repoint
  it, and root wrote its log into the user's `var/log/`. `2-tailscale.sh` now
  copies it to `/usr/local/bin/tailscaled` and runs it from a
  `com.tailscale.tailscaled` job with no log paths. Tailscale's own
  `tailscaled install-system-daemon` does nearly the same, but its job does
  not restart tailscaled if it exits, and it always restarts the daemon
  (`cmd/tailscaled/install_darwin.go`) *(sourced)*, so the script does not use
  it. The state file stays `/Library/Tailscale/tailscaled.state` for both
  (`paths/paths_unix.go`), so the machine keeps its identity across the switch
  *(sourced)*. Root still copies the binary from Homebrew's prefix when the
  script runs, the same trust as running the scripts from a checkout the user
  owns.

### Context: is local worth it *(sourced)*

This Mac's speeds here are Splash's from 2026-10-18 ([Speed](#speed)).

The same model is hosted by many providers at around $0.10 / $1.80 per million
input / output tokens, at hundreds of tokens per second. On this M1 Max, with
Splash, it reads a new prompt at 150-185 tokens a second and writes 23-38, less
as a conversation grows, so an agent's first turn takes a minute or two. Newer
chips are much faster at reading prompts: Apple quotes 6.7x for M5 Max over M1
Max on prompt processing.

Local makes sense for code that cannot leave the machine, batch and overnight
work, a private endpoint for your own scripts, and learning. It does not compete
with hosted models on speed.

## References

- Splash: https://github.com/incoai/splash
- Splash's M1/M2 port: https://github.com/paperniuk/splash
- The port's issue #11, decode cycles on M1 Max: https://github.com/paperniuk/splash/issues/11
- incoai/splash #292, `--idle-release off`: https://github.com/incoai/splash/issues/292
- Claude Code, streaming idle watchdogs: https://code.claude.com/docs/en/network-config#streaming-idle-watchdogs
- Artificial Analysis Intelligence Index: https://artificialanalysis.ai/
- Apple, automatic login for administrators: https://support.apple.com/guide/mac-help/mchlp1158/mac
- Apple Silicon laptops powering on with power: https://support.apple.com/en-us/120622
- Tailscale, ACLs and the local network: https://tailscale.com/docs/features/access-control/acls
- Tailscale grants syntax: https://tailscale.com/docs/reference/syntax/grants
- Hosted pricing: https://openrouter.ai/qwen/qwen3.8-27b
- Apple M5 Max: https://www.apple.com/newsroom/2026/08/apple-introduces-new-mac-studio-with-m5-max-and-m5-ultra/
- Kodesage, Qwen3.8 27B review (efforts): https://kodesage.ai/blog/qwen-3-8-27b-llm-model-review
- Jose Romero, every reasoning level: https://hijoseromero.com/letters/qwen-thinking-levels
- QwenLM/Qwen3.8 #216, empty answers at xhigh: https://github.com/QwenLM/Qwen3.8/issues/216
