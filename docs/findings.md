# Findings

The measurements behind the recommendations in the [guide](../README.md). Each
section says what was measured and what it changed.

**Measured on:** MacBook Pro 16" (M1 Max, 10-core CPU, 32-core GPU, 64 GB).
The first section measured the server as it runs now, Splash's M1/M2 port
1.3.2-m1.1, on macOS 27.0.1. The sections marked as history, and "Memory under
TensorFold", measured the server before it: TensorFold's Python line, 0.6.5
and then 0.6.6 (whose changes are CUDA-only), on macOS 27.0, and its native
1.0.12 engine on macOS 27.0.1. They stay true for what they measured. Each
section gives its dates.

Items marked *(sourced)* come from the linked references and were not
reproduced here. Everything else was.

---

## The server: Splash for M1/M2 and Qwen3.8-27B

**Why Splash, and these settings** (2026-10-18). TensorFold's Python line is
frozen at 0.6.6, which refuses Claude Code's and Codex's requests, and its
native engine read the 27B's prompts here at about 40% of 0.6.6's speed (the
history sections below). The server now runs
[paperniuk/splash](https://github.com/paperniuk/splash) 1.3.2-m1.1
(2026-10-16), an unofficial port of [Splash](https://github.com/incoai/splash)
for M1 and M2. Splash, by Inco, needs an M3 or newer and refuses older GPUs.
The port adds Metal kernels for Apple7 and Apple8 GPUs (M1, M2), bounded
prefill commands so that macOS does not abort long prompts
(`ImpactingInteractivity`), and Neural Engine prefill on M1 and M2
*(sourced)*. Its author tested it on an M1 Max, not on an M2 *(sourced)*.

Everything is stock but the service: the port's release installer, pinned by
version and SHA-256; the MLX 4-bit checkpoint its release notes name; the
DFlash2 draft Splash pairs with it, `incoai/Qwen3.8-27B-DFlash2`; and Splash's
defaults, with five flags. `--model` and `--port 8080` choose the model and the
port. `--served-model-name local-model` and `--announce-served-name` keep the
model ID clients use. `--allowed-host`, with the machine's tailnet name, lets
requests through `tailscale serve` in: Splash answers 403 to a Host name it
does not know ("Host example.com is not allowed; restart the server with
--allowed-host example.com"), a guard against DNS rebinding, and
`tailscale serve` passes the tailnet name on. With the flag the endpoint
answered 200; the server was not run without it. Splash ships no service manager, so the repository's own
LaunchAgent runs it (README, step 5).

**Same weights.** `mlx-community/Qwen3.8-27B-4bit`'s three weight shards have
the same sizes and SHA-256 as those of `TensorFold/Qwen3.8-27B-MLX-4bit`, which
the server ran before. The drafts differ: TensorFold used
`z-lab/Qwen3.8-27B-DFlash2`. Inco's earlier `incoai/Qwen3.8-27B-Splash`
packages no longer load since Splash 1.3.1, which stops and names the MLX model
instead ("the MLX 4-bit models hold the same weights") *(sourced)*. The port
measured this checkpoint on an M1 Max at 61.5 tok/s on a code prompt at
temperature 0, and 51.5 over six mixed prompts. It measured Qwen3.6-35B-A3B at
127 tok/s. Prose is slower than code, because the draft guesses fewer of its
tokens *(sourced)*.

**Startup** (the first start, with the files already downloaded). Splash began
loading at 17:13:19 and a second later logged "Chat template · patched to
render later system messages in place (the original template rejects them)".
It loaded the weights in 7.5 s, chose its "Kernel policy for GPU family 7 with
32 cores", and calibrated the Neural Engine's share of the prefill FFN in
72.6 s, at 0.47 ("79.3 ms per 2048-row FFN layer against 142.3 on the GPU
alone"). It sized the SSD cache at 32 GiB, and at 17:14:56 logged "Ready ·
context 256K": 262,144 tokens, the model's native window (0.6.6 gave 144,384).
The endpoint was down 2 min 51 s in all: TensorFold stopped at 17:12:05, memory
settled for 60 s, and Splash was ready at 17:14:56. With the server idle, wired
memory was about 33 GiB, and the engine's resident size 7.4 GB. Later starts
reuse the calibration: a restart was ready 22 s after loading began.

**Speed against TensorFold 0.6.6** (2026-10-18). Same Mac, same weights, same
day, one server at a time: 0.6.6 was stopped, and memory steady for 60 s,
before Splash started. Each case was a streamed chat completion, timed on the
client: the time to the first token; read, the prompt tokens over that time;
and write, the completion tokens less one over the time from the first token
to the last. Requests asked for `reasoning_effort: medium`, as the clients do,
with the server's default sampling and 512 output tokens (1,024 for the short
code request). Each case ran three times, and each run's prompts started with
a fresh nonce so that cold cases stayed cold. The prompts are this
repository's files from `main`. Medians, with the range in brackets; read and
write in tok/s:

| Case | Prompt tokens | First token, 0.6.6 | First token, Splash | Read, 0.6.6 | Read, Splash | Write, 0.6.6 | Write, Splash |
|---|---|---|---|---|---|---|---|
| A question about `verify.sh`, cold | 2,615 | 23.6 s | 14.1 s | 111 | 185 | 29.0 (27.9-31.7) | 38.0 (33.1-44.5) |
| Its follow-up, cached | 2,640-2,870 | 1.0 s | 2.1 s | | | 26.0 (24.4-28.1) | 33.9 (26.1-34.6) |
| README and three scripts, cold | 12,107 | 111.0 s | 67.9 s | 109 | 178 | 22.9 (22.0-24.4) | 26.0 (25.4-32.1) |
| A short code request | 63-67 | 0.9 s | 1.0 s | | | 34.1 (31.3-35.1) | 33.1 (28.7-35.3) |
| README, findings, client guide and four scripts, cold | 31,349 | 308.3 s | 208.2 s | 102 | 151 | 16.1 (15.1-16.6) | 25.1 (22.3-28.0) |
| Its follow-up, cached | 31,370 | 0.8 s | 1.1 s | | | 14.0 (13.9-14.2) | 22.8 (20.2-22.9) |

Splash reads cold prompts 1.5-1.7 times as fast. It writes about as fast on a
short prompt, and up to 1.6 times as fast as the conversation grows, where
0.6.6 slowed most. Cached follow-ups start in 1-2 s on both, Splash's a little
later. The replies were coherent on both (spot-checked); at `medium`, 512
tokens is mostly thinking on both. The native-engine section below took its
figures from each server's own log, so they do not compare with these.

**Why the short code request is level, and slower than the port's 61.5
tok/s.** Splash's log reports how many tokens each draft cycle yields. This
text gave 3.0-4.6 a cycle, mostly thinking prose; the port's code prompts give
6-7 (its issue #11) *(sourced)*. Greedy, with thinking off, the code request
wrote 38 tok/s at 4.2 tokens a cycle: a decode cycle of about 109 ms here,
against the port's 97 ms on an M1 Max with macOS 26.7.1 *(sourced)*. So the
kernels run within about 12% of the port's, and the difference is how much of
the draft this text accepts. In the port's issue #11, an M1 Max on macOS
27.0.1 also measured cycles about 20% slower than the port's machine, with the
GPU at full clock *(sourced)*.

**Idle release** (2026-10-18). Splash frees the weights after 10 idle minutes
(`--idle-release 10m`) and restores them for the next request;
`POST /v1/memory/release` does the same at once. After it, three short
requests: the log said "Weights restored in 5.98 s", the first request's time
to first token was 6.3 s (0.3 s for the next two), and it wrote at 31.1 tok/s
(27.5-28.3 for the next two). So a request after 10 idle minutes waits about
6 s more, and nothing else was slower. The setting stays at its default.
`--idle-release off`, which upstream added for dedicated servers
(incoai/splash #292) *(sourced)*, is the candidate if those 6 s matter.

**Clients: the API shapes** (2026-10-18, on the Mac):

- Keys: 401 without one on `/v1/models` and `/metrics`; `x-api-key` works;
  `/health` is `{"status":"ok"}`. `/v1/models` lists `local-model` with
  `context_length` 262,144.
- Claude Code's shapes: a mid-conversation system message after an assistant
  turn got 200 (0.6.6 refused it: Qwen's template), and a JSON-schema
  `output_config`, as in Claude Code's title requests, got 200 with valid JSON
  (0.6.6 needed an extra it did not ship).
- Codex's shape: `/v1/responses` with
  `include: ["reasoning.encrypted_content"]` and `store: false` got 200, with
  `encrypted_content` in its reasoning item, and so did a second turn that sent
  the output items back (0.6.6 refused `include`).

**Claude Code itself** (2.x, on the Mac): `splash-m1 claude -p "Reply with the
single word OK."` answered "OK" in one turn. The launcher points
`ANTHROPIC_BASE_URL` at the server, passes the key as the auth token, names the
served ID for every model, and sets `CLAUDE_CODE_MAX_CONTEXT_TOKENS` and
`CLAUDE_CODE_AUTO_COMPACT_WINDOW` to the server's context. Claude Code's first
request is about 21,200 tokens, its system prompt and 22 tools, read cold in
114.5 s; follow-ups were cached. Claude Code asks for effort `high`. A first attempt
went off task: instead of answering, the model explored the environment with
tool calls for about 14 turns before it was stopped, and Claude Code's
permission prompts refused all but `whoami`, `pwd` and `ls`. The tool calls and
their results passed correctly. So under Claude Code's prompt this model can
ignore a trivial instruction.

**OpenCode from the client machine** (1.18.34, its existing config
unchanged, 2026-10-18): "summarize the readme" worked, with a complete answer.
The first request after 13 idle minutes restored the weights in 5.8 s. The
title request (569 tokens, effort `low`) ran alongside the first turn (8,528
tokens cold, effort `medium`), which started writing after 56.0 s and made a
tool call at 55.3 tok/s. The second turn read the README: 15,810 tokens, 8,512
cached, first token after 40.6 s, then 512 tokens at 30.9 tok/s. From the
question to the last token took 1 min 48 s.

**Claude Code from the client machine** (`claude-local`, the client guide's
setup, 2026-10-18): it worked on the first try. A small request (739 tokens,
thinking off) took 4.9 s. The first turn, 20,109 tokens cold at effort `high`
(Claude Code's own choice) with 23 tools, started writing after 111.9 s and
made a tool call. The second turn, 27,249 tokens with 20,096 cached, started
after 45.9 s and wrote 872 tokens at 26.6 tok/s. It took 3 min 15 s in all,
with nothing refused.

**Hermes Agent from the client machine** (0.21.0, its existing config
unchanged, 2026-10-18): it worked, in five requests over 3 min 43 s, with
effort `medium` arriving through `extra_body` and 20 tools. The first turn,
12,177 tokens cold, started writing after 61.4 s (0.6.6: 125.8 s for 13,532).
Most follow-ups started in about 2 s. One turn found only 8,192 of its 13,742
tokens cached although the turn before had 12,352: Hermes's prompt probably
changed before that point (not confirmed), and that turn waited 30.2 s. Before
its first request Hermes asked for Ollama's `POST /api/show`, which Splash
answers 404; Hermes went on without it.

**Not run yet:** Codex against Splash. Hermes and OpenCode use chat completions, the endpoint
measured above. Splash's own launchers
(`splash-m1 claude|codex|opencode|hermes|pi`) connect to a server on the same
Mac only, so another machine configures each client by hand, as the client
guide does. The launchers' settings are in the port's `install/clients.py`:
OpenCode, Pi and Hermes get a 32K output limit, and OpenCode and Hermes a
quarter of the context when it is under 128K *(sourced)*. Also not run yet:
`sudo sh scripts/verify.sh`, whose Splash checks changed with the move, and
`uninstall.sh`, which is destructive by design.

**Known gaps the port lists** *(sourced)*: no fast attention kernel for
`--kv-format bf16`, which runs 1.7-1.9 times slower, so the INT8 default
stays; MLX checkpoints were untested end to end on M1 before 1.3.2-m1.x; and
nothing below 64 GB has been measured.

**Changed:** the server runs Splash's M1/M2 port 1.3.2-m1.1 with
`mlx-community/Qwen3.8-27B-4bit`, in the repository's own LaunchAgent, instead
of TensorFold 0.6.6's service. The key is a bare key in
`~/.config/llm-server/api-key`; this Mac's TensorFold key was copied into it,
so clients did not change. Clients may use 262,144 tokens of context, and
their configs still say 144,384, which works. The client guide no longer marks
Claude Code and Codex as refused.

## History: TensorFold 0.6 and Qwen3.8-27B

The server ran this until 2026-10-18, when Splash replaced it (above).

**Why TensorFold, and these settings.** The server ran
[TensorFold](https://github.com/ashhart/TensorFold) 0.6.5, and later 0.6.6, and
followed its documented defaults rather than tuning its own. Everything was
stock: the Homebrew tap, the recipe's checkpoint and drafter, `tensorfold
service` with an API key file, and no serve flags beyond name and port. The one
deviation from `service install`'s defaults was `--python` through Homebrew's
`opt` link: the
default records the versioned Cellar path, which `brew upgrade` deletes.

**Why Qwen3.8-27B.** Of TensorFold's eight recipes, five fit 64 GB (Flash Next
needs about 75.6 GiB resident; GLM-5.3-Flash and DeepSeek-V4-Flash are written
for 256 GB). Artificial Analysis Intelligence Index v4.3.2 *(sourced)*:

| Recipe | Index | Fits 64 GB | Claude Code (template check below) |
|---|---|---|---|
| GLM-5.3-Flash | 42 | no | accepted |
| Qwen3.8 Flash Next | 40 | no | refused |
| **Qwen3.8-27B** | **34** | yes | refused |
| DeepSeek-V4-Flash | 34 | no | accepted |
| Ternary Bonsai 2 27B | not rated; Prism claims 98.2% of the 27B | yes | refused |
| Qwen3.6-35B-A3B | 18 | yes | refused |
| Gemma 4 26B-A4B | 17 (estimated) | yes | accepted |
| Nemotron 3.5 Lightning | 13 | yes | accepted |

The 27B is the strongest model this Mac can run under TensorFold; Bonsai is a
compressed copy of it, which M1-M4 widen back to 4-bit to run. The 35B-A3B is
the faster option — on this Mac its one-token step measured 14.5 ms against the
27B's 64 ms — but it scores about half as high.

**What TensorFold reports at startup** (2026-10-03): a 144,384-token context
window, "the most one request can use in the 44.8 GiB memory budget and still
keep its prompt for the next turn" (the model's own window is 262,144; the
recipe's 64 GB M5 Pro figure is 140,288); DFlash2 drafting on; 16.3 GiB of
weights; up to 8 requests sharing a round; and this Mac's kernel timings: one
token 64 ms, an 8-row verify window 103 ms. The M1 has no tensor units, so
TensorFold runs its row decoder here.

**Speed, measured** from the server's own log:

| Request | Prompt | Read | Writing |
|---|---|---|---|
| A question about `verify.sh`, from the Mac | 3,741 tokens, cold | 37.7 s (99 tok/s) | 17 tok/s, prose |
| Hermes Agent's first turn, from Omarchy | 13,532, cold | 125.8 s (108 tok/s) | 17.5 tok/s |
| OpenCode's first turn, from Omarchy | 10,758, cold | 98.6 s (109 tok/s) | 14.8 tok/s |
| OpenCode's follow-up | 10,809, 10,740 cached | 1.5 s | 19.4 tok/s |

So a cold prompt costs about 9-10 s per thousand tokens, and a follow-up in the
same conversation reads only what is new. Hermes's first turn took 2 min 11 s
and OpenCode's 1 min 48 s end to end.

**A real session** (OpenCode 1.18.34 from Omarchy, `plan` agent, 2026-10-03):
a question about this repo, then a follow-up in the same session.

| | Requests | Context at the end | Read | Written | Time |
|---|---|---|---|---|---|
| Question | 7, plus a title | 58,389 | 58,455 new tokens in 638 s (92 tok/s) | 4,005 tokens, 11.0 tok/s overall | 16 min 51 s |
| Follow-up | 3 that finished, 3 dropped | 73,116 | 39,516 new tokens in 533 s (74 tok/s) | 13,940 tokens, 8-9 tok/s | 51 min 10 s |

- **Both speeds fall as the conversation grows.** Writing went from 21 tok/s at
  12K tokens to 9.6 at 58K and 8.2 at 73K; reading from about 107 to 68 tok/s.
  The question's final answer, 2,830 tokens, took 5 minutes; one step of the
  follow-up thought for 11,777 tokens (72% of the 16,384 output limit) and took
  26 minutes.
- **Tool results are most of the reading.** Each file or command output the
  agent reads is new text: one step added 19,330 tokens (207 s).
- **OpenCode dropped three requests after exactly 5 minutes** with nothing
  received (TensorFold's `client_disconnections_total` counted 3) and sent each
  again: its `chunkTimeout` default, while TensorFold was still reading the
  prompt. 15 of the follow-up's 51 minutes went to dropped attempts. After the
  first drop the retry found only 41,625 of 61,234 tokens cached (12 cache
  evictions by then) and read for 4 minutes. Why the two later attempts did not
  start within 5 minutes, when the one that finally did read its 8,098 new
  tokens in 119 s, is not known: the log does not say whether the server went
  on with an abandoned request.
- **OpenCode ran shell commands without asking** (`shellcheck`), which is its
  default.

**Changed:** the client guide's OpenCode config sets `chunkTimeout` to 30
minutes and asks before edits and most commands.

**Reasoning effort** (2026-10-03). Qwen3.8's template defaults to `xhigh`;
TensorFold reads a request's `reasoning_effort` and logs it as `effort=`.
OpenCode 1.18.34 with `reasoning: true` sends its model `options`' effort by
default (`reasoningEffort: medium` gave `effort=medium`; without it,
`effort=None`) and the chosen variant otherwise (`--variant low` gave
`effort=low`, title included). Hermes 0.21.0 never sends its own
`agent.reasoning_effort` to a custom endpoint (`effort=None`;
`_supports_reasoning_extra_body()` is false for unknown providers), but the
provider's `extra_body: {reasoning_effort: medium}` arrived as
`effort=medium`. One "Reply with OK" each: `xhigh` 23 and 32 tokens, `medium`
780, `low` 25 — too few to say what an effort saves here.

Others have measured it *(sourced)*. Kodesage, agentic questions about a
codebase (45, one run per effort, judged by Claude Opus 4.6 against reference
answers): substance 7.79 / 8.18 / 8.61 for low / medium / xhigh, median
95 / 76 / 143 s; `low` was slower than `medium` because it took more agent
rounds. Jose Romero, four single-turn coding tasks on a Ryzen AI Max+ 395:
22 min at `medium` against 2 h 36 min at `xhigh` (160,571 output tokens), each
effort winning one task. QwenLM/Qwen3.8 #216: about 19% of `xhigh` calls (18
of 93) returned an empty answer after thinking, none of 95 at `low`/`medium`.

**Changed:** the client guide asks for `medium` from OpenCode (Ctrl+T to
switch) and Hermes (`extra_body`). The server stays at the template's `xhigh`
rather than use TensorFold's `--reasoning-effort`.

**Clients, from the Omarchy machine** (each sent "Reply with the single word
OK." with the configs in `docs/omarchy-client.md`):

| Client | API | Result |
|---|---|---|
| Hermes Agent 0.21.0 | chat completions | works |
| OpenCode 1.18.34 | chat completions | works |
| Claude Code 2.1.288 | Anthropic Messages | HTTP 400 at once |
| Codex | Responses | HTTP 400 at once |

Both refusals are TensorFold behaving as documented (its API reference and its
error messages), not a configuration fault:

- **Claude Code** sends mid-conversation system messages. TensorFold's Messages
  endpoint keeps them "in place with its system role; the model's chat template
  must support later system messages", and refuses the request when it does
  not. At startup it probes the template; its own probe, run on each recipe's
  template, gives the column above (for GLM-5.3 and DeepSeek-V4 through
  TensorFold's own prompt builders, which replace the checkpoint's template).
  Qwen3.8's and Qwen3.6's templates raise "System message must be at the
  beginning." Its chat-completions endpoint, by contrast, renders such a
  message as a user message, which is why Hermes and OpenCode are unaffected.
- **Codex** puts `include: ["reasoning.encrypted_content"]` on every Responses
  request (`codex-rs/core/src/client.rs`, unconditionally, with `store: false`),
  and TensorFold's Responses endpoint refuses any `include` (its API reference);
  its error says "reasoning comes as text in its reasoning item, and nothing is
  encrypted". No Codex setting
  removes it, so Codex does not work with TensorFold 0.6.5 and any model.
- Claude Code's title requests also need TensorFold's `[grammar]` extra
  (xgrammar), which the Homebrew formula does not install. Not reached yet.

**Changed:** the client guide uses Hermes and OpenCode, keeps the Claude Code
and Codex setups ready for a TensorFold release that accepts their requests,
and says what to look for in its changelog.

## History: TensorFold's native engine (1.0.12) on this Mac

TensorFold's Python line is frozen at 0.6.6; client fixes now land only in its
native 1.x engine. On 2026-10-17 the native 1.0.12 binary (the release archive,
the same bytes as the tap's `tensorfold` formula) served the same Qwen3.8-27B
checkpoint and DFlash2 drafter, with its stock settings (`--drafter`, `--name`,
`--api-key-file`; context left at its 32,768 default). The 27B is qualified on
M5 Max and M3 Ultra only, not on an M1.

It loaded in 59 s (19.4 GiB wired, 8 streams of 32,768 tokens). The same three
example requests went to each server from the Mac, at `reasoning_effort:
medium` and 512 reply tokens, with each server's own timings:

| Request | 0.6.6 read | 1.0.12 read | 0.6.6 writing | 1.0.12 writing |
|---|---|---|---|---|
| A question about `verify.sh`, 2,580 tokens cold | 29.5 s (87 tok/s) | 37.3 s (69 tok/s) | 30.6 tok/s | 21.9 tok/s |
| Its follow-up, 2,560-2,575 cached | 2.4 s | 1.4 s | 28.0 tok/s | 16.9 tok/s |
| README and three scripts, 12,072 tokens cold | 110.9 s (109 tok/s) | 283.6 s (43 tok/s) | 22.9 tok/s | 9.5 tok/s |

So on an M1 Max the native 27B reads long prompts at about 40% of 0.6.6's
speed and writes at about half, as TensorFold's README warns ("prompt
processing trails mlx_lm for now"). Short API checks on the same server:

- Keys: 401 without one on `/v1/models` and `/metrics`; `X-Api-Key` works;
  `/health` is `{"status": "ok"}`. `/v1/models` lists the efforts xhigh,
  medium, low and none.
- Codex's shape works: `/v1/responses` with `include:
  ["reasoning.encrypted_content"]` and `store: false`, and a second turn that
  sends the first turn's output items back, both 200.
- Messages accepts a mid-conversation system message after a user turn (the
  Qwen template refused it on 0.6.6), and refuses one after an assistant turn
  ("must follow a user turn"). A JSON-schema `output_config`, as in Claude
  Code's title requests, gets 400: structured output is Nemotron and
  Qwen3.5-2B only. Claude Code itself was not run.

**Started again after the memory settled** (same day; 0.6.6 stopped, then
wired memory steady for 60 s and no swap; the engine's saved startup timings
moved aside so it timed itself again): the same three requests gave the same
tokens and the same timings to 0.1 s. The first run was not a memory or
startup artifact. At `--context 144384`, the size the clients are configured
for, the server fits 3 streams and leaves **no prompt cache** ("prompt cache:
0.0 GiB"), so the follow-up re-read its whole conversation: 37.9 s to its first
token instead of 1.4 s.

**Nemotron 3.5 Lightning on 1.0.12** (same day, revision `d9d758fb`, stock
flags: 262,144-token context, 16 GiB prompt cache, loaded in 33 s). It is
fast here: the same example requests read at 532 and 551 tok/s (the 27B on
0.6.6: 87 and 109) and wrote at 30-44 tok/s, a follow-up started in 0.19 s,
and Claude Code's title request (JSON schema) worked. But its longer replies
can collapse into one repeated string, 后汉书, until the output cap:

| Request (no tools, a 36-token prompt) | Result |
|---|---|
| ~600 words of prose, greedy, thinking off | coherent, 759 tokens; drafts 382/561 |
| The same with `"draft": false` | the same tokens (same `sha`) |
| A tool call to a short path, greedy | correct |
| The same prose, thinking on, server's default sampling (temperature 1.0, top_p 0.95) | reasoning sound for ~2,300 characters, then 后汉书 repeated |
| The same, thinking on, greedy | coherent to the 600-token cap |

The same collapse came greedy, thinking off, in a tool call whose path was a
long scratch directory, and in a real Claude Code tool call (twice, to the
16,384-token cap). Low draft acceptance marks it in the log (10 of 587, 24 of
18,428). Not found in TensorFold's issues. On M1 Max, macOS 27.0.1 (26A434).

**Changed:** nothing; the server stays on 0.6.6. Try the native 27B again when
a release reports faster 27B prompts on M1-M4; Nemotron when the collapse is
fixed.

## Remote desktop: Sunshine needs the display awake

Tested 2026-10-03 from the Omarchy machine (Sunshine 2026.914.233613,
Moonlight, lid shut, on mains). The display went off the moment a Remmina
session ended, with no idle wait: Screen Sharing holds the display on only while
connected, and with the lid shut nothing else did (the likely reason; not
checked separately). Otherwise it slept after 5 idle minutes, and the screen
locked when it did. With the display asleep, Sunshine logged "No
display devices are active at the moment! Cannot probe the encoders" and
Moonlight could not connect. With the display kept awake (Amphetamine at
first), Moonlight connected to the **locked** Mac, showed the lock screen and
took the password: Sunshine captures and types into it. Screen Sharing (Remmina)
works either way, and is still the only way in at the login window after a
restart, where Sunshine is not yet running.

With the display kept awake the Mac no longer locks on display sleep, which on
the charger had always come first (after 5 minutes, before the screen saver's
default 20). The screen saver takes that over: started after 10 idle minutes,
with the password required immediately. Checked the same day at a 1-minute
setting: it locked, and Moonlight showed the lock screen and took the password.
Amphetamine holds off the screen saver as well, so the Mac does not lock while
it runs; presumably `caffeinate -d` too, which holds the same display-sleep
assertion (not checked).

**Changed:** `pmset -c displaysleep 0` (the charger only), and the screen saver
set to 10 minutes with the password required immediately. Recorded in the
client guide's Sunshine steps.

## Memory under TensorFold

TensorFold gives its process 70% of RAM by default — 44.8 GiB here — and its
startup line says how far `TENSORFOLD_MEMORY_LIMIT_GB` can raise that: 51.8
GiB on this Mac, the GPU's `recommendedMaxWorkingSetSize` (81% of RAM). Do not
raise `iogpu.wired_limit_mb` to make a model fit: Apple documents the
working-set size as a hint and never mentions that sysctl, and nothing here
needed it.

## Heat

Ten minutes of continuous decoding, requests back to back, plugged in, lid
open (2026-09-24):

| | first 6 min | last 4 min |
|---|---|---|
| GPU clock | 1,289–1,291 MHz | 1,289–1,291 MHz |
| GPU power | ~33 W | ~34 W |
| macOS thermal pressure | Nominal | Nominal, then **Heavy** from 8.7 min |

**No throttling.** The GPU stayed at its maximum clock for all 120 samples,
including the 70 seconds under Heavy pressure, and the decode rate did not
fall. Not settled: what happens if Heavy pressure lasts; it appeared only at
the end.

## Unattended operation

**It keeps serving with the lid shut, on mains power.** With `pmset -a
disablesleep 1` (`SleepDisabled 1`), the lid closed (`AppleClamshellState =
Yes` in `ioreg`) and AC attached, the Mac answered requests from the Omarchy
client from 13:35 to past 15:00 on 2026-09-27, and SSH and Screen Sharing
worked throughout. `pmset -g log` has 920 entries that day and no `Sleep`,
`Wake` or `DarkWake` event on it or the day before; uptime was 19 h. The first
hour of requests came before any Screen Sharing session, so `screensharingd`'s
sleep assertion was not what kept it awake.

`launchctl bootout` returns before the job is gone; an immediate `bootstrap`
of the same label fails with `5: Input/output error`. Hence `stop_job` and
`start_job` in `scripts/lib.sh`.

## Security

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
- **`/etc/kcpassword`** holds the auto-login password, obfuscated with a
  published key.
- **pf filters loopback.** Rules that pass only tailnet sources also drop
  connections from 127.0.0.1: Screen Sharing's port never answers on the Mac
  itself, and Sunshine's web UI, which answers only there, did not load until
  loopback was let through to its port alone (2026-10-03). A connection to the
  machine's own LAN address comes from that address, so `verify.sh`'s
  local-network test still sees it dropped.
- **Root and Homebrew.** Homebrew's prefix belongs to the user, so a job root
  runs from it lets anything running as that user become root at its next
  start. The model server is a LaunchAgent in the user's session and runs as
  that user (TensorFold's service refused root); the
  one root service from Homebrew is `tailscaled`, as its formula says to run it
  (`sudo brew services`). That leaves its running version owned by root, which
  is why `brew upgrade tailscale` cannot clean up the old one (README, step 9).

## Context: is local worth it *(sourced)*

The same model is hosted by many providers at around $0.10 / $1.80 per million
input / output tokens, at hundreds of tokens per second. On this M1 Max, with
Splash, it reads a new prompt at 150-185 tokens a second and writes 23-38, less
as a conversation grows, so an agent's first turn takes a minute or two (with
TensorFold it read about 100 and wrote 15-20). Newer chips are much faster at
reading prompts: Apple quotes 6.7x for M5 Max over M1 Max on prompt processing.

Local makes sense for code that cannot leave the machine, batch and overnight
work, a private endpoint for your own scripts, and learning. It does not compete
with hosted models on speed.

## Not measured

- Lid-closed operation on battery (verified on mains only; see
  [Unattended operation](#unattended-operation)).
- Recovery from a power cut, and the battery watchdog firing.
- Heat beyond 10 minutes of sustained load, once thermal pressure is Heavy.
- Coding quality on this server: the guide defers to the published results of
  Splash, its M1/M2 port and Artificial Analysis rather than running
  benchmarks.
- How much time `medium` reasoning effort saves on a real session.
- Any client against Splash from another machine (see
  [the server](#the-server-splash-for-m1m2-and-qwen38-27b), "Not run yet").
- Any Mac other than this one: no M2, and nothing under 64 GB. The port's
  author has not tested an M2 either *(sourced)*.

## References

- Splash: https://github.com/incoai/splash
- Splash's M1/M2 port: https://github.com/paperniuk/splash
- The port's issue #11, decode cycles on M1 Max: https://github.com/paperniuk/splash/issues/11
- incoai/splash #292, `--idle-release off`: https://github.com/incoai/splash/issues/292
- TensorFold: https://github.com/ashhart/TensorFold
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
