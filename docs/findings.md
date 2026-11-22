# Findings

Measurements of the server behind the [guide](../README.md), when they ran,
and what they changed. Everything ran on a MacBook Pro 16" (M1 Max, 32-core GPU,
64 GB) on macOS 27.x. Items marked *(sourced)* come from the linked references
and were not reproduced here.

The Mac runs [paperniuk/splash](https://github.com/paperniuk/splash)
1.6.1-m1.1, an unofficial port of [Splash](https://github.com/incoai/splash) to
M1 and M2, because Splash refuses GPUs older than the M3's. Each port release
is the Splash release of the same number plus Metal kernels for the M1 and M2
GPUs, prefill commands short enough that macOS does not abort long prompts,
and prefill on the Neural Engine too. Its author tests on an M1 Max, and a
contributor on an M2 Max *(sourced)*.

## Settings

Everything is Splash's default except the LaunchAgent and three flags, plus
two on some M1 and M2 chips (README, "How it works"):

- `--model mlx-community/Qwen3.8-27B-4bit`, the MLX checkpoint Splash's README
  lists. Splash pairs it with `incoai/Qwen3.8-27B-DFlash2` by itself. The
  repository ID is the model ID clients use, because some clients reject a
  reply whose `model` differs from what they asked for *(sourced: Splash's
  `docs/server.md`, "API model aliases")*.
- `--allowed-host <machine>.<tailnet>.ts.net`. Without it, Splash answers 403
  to what `tailscale serve` passes on. The check ignores the port. With the
  flag, a Host with no port, `:443` or `:8443` got 200, and another name got
  403 (1.6.1-m1.1, 2026-11-21). So `LLM_HTTPS_PORT` needs no change to the flag.
- `--default-reasoning-effort medium` ([Reasoning effort](#reasoning-effort)).
- On 1.6.1-m1.1, `--ane-ffn-share 0.68 --ane-ffn-minimum-rows 512` on an M1
  Max ([Prefill as a pair of chunks](#prefill-as-a-pair-of-chunks)).

By default Splash listens on 127.0.0.1:8000, frees the weights after 10 idle
minutes, admits 32 requests at once, running or waiting, and keeps the Mac
awake while requests run *(sourced: `server/serve_options.py`)*.

## Reasoning effort

Qwen3.8's template knows `low`, `medium` and `xhigh`, its default. The server
defaults to `medium` because of these measurements *(sourced)*:

- Kodesage, 45 agentic questions about a codebase: substance 7.79 at `low`,
  8.18 at `medium`, 8.61 at `xhigh`, with median times of 95, 76 and 143 s.
- Jose Romero, four coding tasks: 22 min at `medium` against 2 h 36 min at
  `xhigh`. Each effort won one task.
- QwenLM/Qwen3.8 #216: 18 of 93 `xhigh` calls returned an empty answer, none
  of 95 at `low` or `medium`.

On 2026-11-21, with OpenCode 2.3.2 on 1.6.1-m1.1, Splash's log showed
`effort absent → medium` for OpenCode's turns, `low` for its titles, and
`high` for a turn sent with `#high`.

**The default does not reach Messages requests.** A Messages request that
asks for thinking and names no `output_config.effort` gets `high`, as
Anthropic's API does (`field_value(output_config, "effort", "high")` in
`server/dialects/anthropic.py`, 1.6.1-m1.1 and 1.7.0-m1). The request then
carries an effort, so `--default-reasoning-effort` does not apply, and Qwen's
template renders `high` as `xhigh` (`REASONING_EFFORT_ALIASES` in
`server/chat_templates.py`). This is read from the source and from Splash's
`docs/api.md` and `docs/server.md`, not measured. A Messages client has to ask
for `medium` itself.

Splash 1.7 adds `--reasoning-effort`, which forces one effort on every
request, and refuses it together with `--default-reasoning-effort`
*(sourced)*. Not adopted, because clients that ask for `high` on purpose would
lose it.

## Prefill as a pair of chunks

The port runs part of each prefill layer's FFN on the Neural Engine, at a
share it calibrates on a build's first start, 0.47 here. 1.6.1-m1.1 adds an
opt-in mode. Given a share by hand, it reads each prefill command of 256 rows
or more as two chunks, with the Neural Engine on one chunk's FFN while the GPU
runs the other's attention. Its notes run it with `--ane-ffn-minimum-rows 512`,
say the mode pays off only at about 0.2 above the calibrated share, and give
0.735 for an M1 Max, 0.88 for an M1 Pro and 0.53 for an M2 Max. They report
+18-19% cold prefill on the 27B at 2.1K to 16.7K tokens and -5% at 560, with
logits as close to the GPU alone as the calibrated split (KL 0.00057 against
0.00050) *(sourced)*.

**Against the calibrated split** (2026-11-21). The calibrated split alone,
with no pair, read cold prompts of this repository's files at 190 tok/s at 820
tokens, 194 at 2.9K and 187 at 10K (medians of 4 runs, TTFT from Splash's
log). The pair at 0.68 reads them at 179, 236 and 239 (table below): 6% slower
at 820 tokens and 28% faster at 10K. Prompts under about 700 tokens take
about 5 s either way, and cached follow-ups read only what is new. Decode is
untouched, because the pair applies to prefill only.

**The M1 Max's share** (2026-11-21). Each run restarted Splash with the
LaunchAgent's flags and one change, warmed each prompt size once, then read
two or three cold prompts of each size, prefill time from Splash's log. Every
candidate ran between two runs of 0.735, the port's value, and counts only
where it beat both. Cold prefill, tok/s:

| Share | 820 tokens | 2.9K | 11K | 34K | 128K |
|---|---|---|---|---|---|
| 0.735 (8 runs) | 163 | 217 | 222-228 | 200-202 | 124 |
| 0.60 | 203 | 231 | 225 | | |
| 0.65 | 186 | 236 | 234 | | |
| **0.68** (4 runs) | **179** | **236** | **239** | **206-208** | **122** |
| 0.72 | | 227 | 234.5 | 203-205 | |
| 0.80 | 153 | 202 | 215 | | |

Splash rounds the share it is given (0.60 to 0.59, 0.64 to 0.65, 0.735 to
0.74). 0.68 is the fastest share from 2.9K to 34K tokens. Over 0.735, it is
+9% at 2.9K, +5% at 11K, +3% at 34K, and +10% at 820. At 128K it was 2%
slower, one run each, so the best share rises again for the longest prompts.
Run to run, prefill varied under 1%. Decode, short-prompt TTFT (0.27 s) and
cached follow-ups (1.0 s) did not change, and greedy answers to six short
prompts were identical. On an 11K-token prompt the greedy answer differed from
0.735's after 147 characters, where the control's own cached rerun also
differed. That is a near-tie, and any change to the split can change its
outcome. At 0.68, three codes hidden at 10%, 50% and 90% of a 127.6K-token and
a 238.8K-token prompt came back exactly. Those prompts read at 122 and 80
tok/s, in 17 and 50 minutes.

`--ane-ffn-minimum-rows` stays at 512. At 1024, with a share of 0.735,
commands under 1,024 rows ran at the given share without the pair, 150 tok/s
at 820 tokens and 200 at 2.9K, slower than both controls. At 256, with 0.68,
prompts from 256 tokens pair, and 400-token prompts read at 120 tok/s against
147 at 512.

**Changed:** `scripts/variant.sh` passes 0.68 on an M1 Max, and the notes'
shares on an M1 Pro and an M2 Max, with 1.6.1-m1.1. Other chips get none,
because the notes name none for them. 1.7.0-m1 times the pair on its first
start (0.74 on an M1 Max for the 27B, from 769 rows, in its notes
*(sourced)*, and 0.68 from 769 rows when it ran here), so the next port bump
drops the flags.

## Other settings tried

Measured the same way on 2026-11-21, each between two control runs. None was
adopted.

- `--kv-format bf16`: decode, prefill and TTFT inside the controls. It doubles
  the KV read per token, and that read is large only at long context.
- `--prefill-mode full`: 11K-token prefill at 207 tok/s against 206-217, and
  it drops the bound that keeps macOS from aborting long prefills.
- `--prefill-bound-ms 4000`: 217 against 206 and 222, inside the controls.
- `--persistent-cache`: no change while serving. After a restart, the
  follow-up of an 11K-token conversation started in 1.2 s instead of 46.7 s.
  Splash took back 3 GB of cached state in 5 s and started as fast as without
  it. It keeps up to 32 GiB in `~/Library/Caches/Splash`. Left off, because
  restarts here are rare, only for upgrades and reboots.

**Where decode stands.** The GPU copies memory at 371 GB/s and multiplies
fp16 at 7.9 TFLOPS (Metal, measured here). Each decode cycle reads the
target's weights (about 15.4 GB), the draft's (3.85 GB) and the recurrent
state, about 19.5 GB in all, so a cycle cannot take less than 53 ms. Splash's
log puts its cycles at 87 ms ("Decode step costs"), about 60% of the speed
that floor allows. None of Splash's settings reaches the kernels that make up
the gap. Prefill at 11K tokens keeps the GPU at about 80% of its multiply
rate, with the Neural Engine doing most of the FFN.

## Upgrades

Each upgrade ran `1-install.sh` and `3-services.sh` and kept the checkpoint,
the draft and every flag. Down is the time from Splash stopping to "Ready".
Each new build calibrates the Neural Engine once, and later starts reuse it.
Every installer's SHA-256 matched its release notes.

| Date | Version | Down | Neural Engine share | Result |
|---|---|---|---|---|
| 2026-11-21 | 1.6.1-m1 to 1.7.0-m1 | 287 s | 0.50, in 127.5 s, plus 114.5 s timing the chunk pair | **Rolled back.** Follow-ups wrote nonsense |
| 2026-11-21 | 1.7.0-m1 to 1.6.1-m1.1 | 70 s | 0.47, in 42.7 s | Passed. 16 of 16 graded follow-ups |

**1.7.0-m1 wrote nonsense in short conversations.** It is Splash 1.7.0 with
the port's kernels, and its notes promise 6% faster decode and 14% faster
cold prefill at 16.7K tokens for this checkpoint on an M1 Max *(sourced)*. It
passed `3-services.sh` (200 with the key, 401 without). Single requests, a
7K-token cold prompt, its cached follow-up, Messages and two-turn Responses
all answered correctly. But any short conversation with an earlier assistant
turn went wrong. The graded set has four such chats: 3+3 after 2+2, Italy's
capital after France's, a code follow-up, and recalling two earlier answers.
Each ran with thinking off and at `medium`, with and without a 2K-token system
prompt, and 2 of the 16 passed. Replies repeated one token to the output
limit, came back empty, or ignored the conversation. Once, with the shared
system prompt, the Italy question answered "6", the answer to another
conversation. `--verify-rows all` and a fresh start did not help. In the same
window 1.6.1-m1 answered all of these. No issue upstream or in the port
matched on 2026-11-21, and none was filed. **Changed:** the port is pinned at
1.6.1-m1.1, and `verify.sh` asks the 3+3 follow-up and fails unless it answers
6, because the status checks passed on the broken build.

The port's open issue #63, decode slowing after about a day of uptime with
"growth paused" in the log, is not fixed in 1.6.1-m1.1 or 1.7.0-m1
*(sourced)*. It was reported with a MoE model, not this checkpoint.

**Splash 1.7.0 is pinned for M3 and later**, as released. It has not run
here, and whether the 1.7.0-m1 failure comes from Splash's code or the port's
is not known. On a first M3 setup, `verify.sh`'s follow-up check is the test.

## Startup

With the model already downloaded, the weights load in about 6.5 s, and Splash
reports "Ready · context 256K" (262,144 tokens) about 28 s after it starts. A new build's first start
adds the Neural Engine calibration, 42.7 s for 1.6.1-m1.1
([Upgrades](#upgrades)). Idle,
wired memory was about 33 GiB.

## Speed

1.6.1-m1.1 with the pair at 0.68, on 2026-11-21, in the runs that chose the
share ([Prefill as a pair of chunks](#prefill-as-a-pair-of-chunks)). Eight
runs, each after a restart, on mains power, with thermals settled. Times and
rates come from Splash's log.

| Measure | Result |
|---|---|
| Decode, six code prompts, thinking off, 384 tokens, greedy | median 37.3-37.6 tok/s per run; 28.5-61.4 by prompt, at 2.6-5.5 tokens per draft cycle |
| Decode, three prompts thinking at `medium` | median 40.9-49.0 tok/s per run |
| Decode after a 127.6K and a 238.8K-token prompt | 36 and 25 tok/s |
| Cold prefill | 179 tok/s at 820 tokens, 236 at 2.9K, 239 at 11K, 206 at 34K, 122 at 128K, 80 at 239K |
| First token of a short prompt | 0.27 s |
| Cached follow-up of a 10K-token conversation | 1.0 s |
| Start to "Ready" with a calibrated build | 28 s |

Decode depends on the prompt because each draft cycle costs the same and
accepts a different number of tokens.

OpenCode's first turns on 2026-11-21, 8.7K and 9.6K tokens, got their first
token in 42 and 50 s (209 and 193 tok/s), below the table's rate for two
reasons. The first was the first request after a restart, and the first
requests after a start read slower (21.4 s against 13.5 s for 2.9K tokens).
The second waited 6.5 s for the weights after an idle release, and shared the
GPU with OpenCode's title request.

The port's README for 1.6.1-m1.1 puts this checkpoint on an M1 Max at about
61 tok/s on a code prompt and 46-60 across code and prose prompts. The port's
1.5.0-m1 notes, the last to time Qwen3.6-35B-A3B, put it at 143.5 tok/s
against 55.8 for this checkpoint *(sourced)*. Writing is slower here because
these prompts draft worse: 2.6-5.5 tokens per draft cycle, median 3.35, against
6-7 on the port's code prompts *(sourced: port issue #11)*.

**Splash sends no tokens while it reads a prompt** (2026-11-21, 1.6.1-m1.1). A
streamed chat completion with an uncached prompt got its headers and an empty
first chunk in 0.06 s, then nothing until Splash had read the prompt: 17
minutes for 127.6K tokens and 50 for 238.8K. Splash sends progress chunks
during the read only to a streamed request that sets `"return_progress": true`
*(sourced: Splash's `docs/api.md`, "Output limits and streaming")*. Without
it, a client's timeout between chunks has to cover the whole read, so the
client guide raises OpenCode's `chunkTimeout` from 15 to 60 minutes.

**Idle release.** After 10 idle minutes Splash frees the weights, and the next
request waits for them ("Weights restored in 6.47 s" in Splash's log on
2026-11-21). `--idle-release off` is the option if those seconds matter
*(sourced: incoai/splash #292)*.

**Other hardware.** Hosted providers serve this model at hundreds of tokens a
second, and Apple quotes an M5 Max at 6.7 times an M1 Max on prompt
processing *(sourced)*.

## Heat

In the runs above, on mains power with the lid open, macOS reported thermal
state `fair` within minutes of the first request. Decode on the first three
control runs fell from 36.1 to 33.5 to 31.4 tok/s as the Mac warmed, then
held at 37.3-37.8 for the rest of the day, so only runs next to each other
are compared. What happens under longer sustained load is not measured.

## Not measured

- Any Mac other than this one: an M2, an M3 or later, or less than 64 GB.
- Heat under hours of continuous load. The runs in [Heat](#heat) restarted
  Splash about every 6 minutes.
- Coding quality. The guide defers to published results.
- How much time `medium` saves on a real session.

## References

- Splash: https://github.com/incoai/splash, and 1.7.0's notes:
  https://github.com/incoai/splash/releases/tag/1.7.0
- The M1/M2 port: https://github.com/paperniuk/splash, and the notes for
  1.5.0-m1, 1.6.1-m1.1 and 1.7.0-m1:
  https://github.com/paperniuk/splash/releases/tag/1.5.0-m1,
  https://github.com/paperniuk/splash/releases/tag/1.6.1-m1.1,
  https://github.com/paperniuk/splash/releases/tag/1.7.0-m1
- The port's README for 1.6.1-m1.1: https://github.com/paperniuk/splash/blob/1.6.1-m1.1/README.md
- Port issue #11, decode cycles on M1 Max: https://github.com/paperniuk/splash/issues/11
- Port issue #63, decode slowing after a day: https://github.com/paperniuk/splash/issues/63
- incoai/splash #292, `--idle-release off`: https://github.com/incoai/splash/issues/292
- Splash on 24 GB Macs: https://github.com/incoai/splash/blob/1.7.0/docs/performance.md#smaller-ggufs-on-24-gb-macs
- The port's models by Mac memory: https://github.com/paperniuk/splash#which-model-for-your-mac
- Artificial Analysis Intelligence Index: https://artificialanalysis.ai/
- Hosted providers: https://openrouter.ai/qwen/qwen3.8-27b
- Apple M5 Max: https://www.apple.com/newsroom/2026/08/apple-introduces-new-mac-studio-with-m5-max-and-m5-ultra/
- Kodesage, Qwen3.8 27B efforts: https://kodesage.ai/blog/qwen-3-8-27b-llm-model-review
- Jose Romero, every reasoning level: https://hijoseromero.com/letters/qwen-thinking-levels
- QwenLM/Qwen3.8 #216, empty answers at xhigh: https://github.com/QwenLM/Qwen3.8/issues/216
