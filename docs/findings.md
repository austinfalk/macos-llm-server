# Findings

What was measured behind the [guide](../README.md), when, and what it changed.
Everything ran on a MacBook Pro 16" (M1 Max, 32-core GPU, 64 GB) on macOS
27.x. Items marked *(sourced)* come from the linked references and were not
reproduced here.

## The server

The Mac runs [paperniuk/splash](https://github.com/paperniuk/splash)
1.6.1-m1.1, an unofficial port of [Splash](https://github.com/incoai/splash) to
M1 and M2. Splash itself refuses GPUs older than the M3's. The port adds Metal
kernels for the M1 and M2 GPUs, keeps prefill commands short enough that macOS
does not abort long prompts, and runs prefill on the M1 and M2 Neural Engine
too. Each
port release is the Splash release of the same number with these changes on
top. Its author tests on an M1 Max, and a contributor on an M2 Max
*(sourced)*.

### Settings

Everything is Splash's default except the LaunchAgent and three flags, plus
two on some M1 and M2 chips (README, "How it works"):

- `--model mlx-community/Qwen3.8-27B-4bit`, the MLX checkpoint Splash's README
  lists. Splash pairs it with `incoai/Qwen3.8-27B-DFlash2` by itself. The
  repository ID is the model ID clients use, because some clients reject a
  reply whose `model` differs from what they asked for *(sourced: Splash's
  DEVELOPMENT.md, "API model aliases")*.
- `--allowed-host <machine>.<tailnet>.ts.net`. Without it Splash answers 403
  ("Host NAME is not allowed; restart the server with --allowed-host NAME") to
  what `tailscale serve` passes on. The check ignores the port: with the flag,
  requests whose Host carried no port, `:443` or `:8443` all got 200, and
  another name got 403 (1.5.0-m1 and 1.6.1-m1). So `LLM_HTTPS_PORT` needs no
  change to the flag.
- `--default-reasoning-effort medium` ([Reasoning effort](#reasoning-effort)).
- On 1.6.1-m1.1, `--ane-ffn-share 0.68 --ane-ffn-minimum-rows 512` on an M1
  Max ([Prefill as a pair of chunks](#prefill-as-a-pair-of-chunks)).

Defaults worth knowing: Splash listens on 127.0.0.1:8000, frees the weights
after 10 idle minutes, admits 32 requests at once, running or waiting, and
keeps the Mac awake while requests run *(sourced: `server/serve_options.py`)*.

**Changed** (2026-10-18): the LaunchAgent dropped `--port 8080` and the
`local-model` alias. Splash now uses its default port, 8000, behind
`tailscale serve`, and clients use the repository ID.

**Speed by checkpoint.** The port measured this checkpoint on an M1 Max at
61.5 tok/s on a code prompt and 51.5 over six mixed prompts, and
Qwen3.6-35B-A3B at 127 tok/s *(sourced)*.

### Reasoning effort

Qwen3.8's template knows `low`, `medium` and `xhigh`, its default. The server
defaults to `medium` because of others' measurements *(sourced)*:

- Kodesage, 45 agentic questions about a codebase: substance 7.79 at `low`,
  8.18 at `medium`, 8.61 at `xhigh`, with median times of 95, 76 and 143 s.
- Jose Romero, four coding tasks: 22 min at `medium` against 2 h 36 min at
  `xhigh`. Each effort won one task.
- QwenLM/Qwen3.8 #216: 18 of 93 `xhigh` calls returned an empty answer, none
  of 95 at `low` or `medium`.

**The default does not reach Messages requests.** A Messages request that
asks for thinking and names no `output_config.effort` gets `high`, as
Anthropic's API does (`field_value(output_config, "effort", "high")`, in
`server/dialects/anthropic.py` in 1.6.1-m1.1 and 1.7.0-m1). The request then carries an
effort, so `--default-reasoning-effort` does not apply, and Qwen's template
renders `high` as `xhigh` (`REASONING_EFFORT_ALIASES` in
`server/chat_templates.py`). Read from the source, not measured. So a
Messages client has to ask for `medium` itself. The guide's `claude-local`
did, and the server log showed `effort medium` for it.

Splash 1.7 adds `--reasoning-effort`, which forces one effort on every
request, and refuses it together with `--default-reasoning-effort`
*(sourced)*. Not adopted: clients that ask for `high` on purpose would lose it.

### Prefill as a pair of chunks

The port runs each prefill layer's FFN partly on the Neural Engine, at a
share it calibrates on the first start of a build: 0.47 here. 1.6.1-m1.1 adds
an opt-in mode: given a share by hand, it reads each prefill command of 512
rows or more as two chunks, the Neural Engine on one chunk's FFN while the GPU
runs the other's attention. Its notes say it pays only about 0.2 above the
calibrated share, give 0.735 on an M1 Max, 0.88 on an M1 Pro and 0.53 on an
M2 Max, and measured +18-19% cold prefill on the 27B at 2.1K to 16.7K tokens,
-5% at 560, with logits as close to the GPU alone as the calibrated split
(KL 0.00057 against 0.00050) *(sourced)*.

Measured here on 2026-11-21: cold prompts of this repository's files with a
fresh nonce, one output token, TTFT from Splash's log, the pair, then the
calibrated split, then the pair again, a restart between each. Medians, tok/s:

| Prompt | Pair (3 runs) | Calibrated (4 runs) | Pair again (4 runs) | Change |
|---|---|---|---|---|
| 820 tokens | 164 | 190 | 164 | -14% |
| 2.9K | 213 | 194 | 212 | +10% |
| 9.8-10K | 234 | 187 | 233 | +25% |

A 10K-token prompt now starts in 43 s instead of 53. Prompts under about 700
tokens are slower, but they take seconds either way, and cached follow-ups
read only what is new. Decode is untouched: the pair applies to prefill only.
**Changed:** `scripts/variant.sh` passes a share for M1 Max, M1 Pro and M2
Max with 1.6.1-m1.1, and none on other chips, which the notes do not name.
1.7.0-m1 times the pair on the first start (0.74 on an M1 Max for the 27B,
from 769 rows, in its notes *(sourced)*; 0.68 from 769 rows when it ran here),
so the next port bump drops the flags.

**The M1 Max's share, measured** (2026-11-21). Each run restarted Splash with
the LaunchAgent's flags and one change, warmed each prompt size once, then
read cold prompts of this repository's files with a fresh nonce, two or three
of each size, prefill time from Splash's log. Every candidate ran between two
runs of 0.735, the port's value, and counts only where it beat both. Cold
prefill, tok/s:

| Share | 820 tokens | 2.9K | 11K | 34K | 128K |
|---|---|---|---|---|---|
| 0.735 (8 runs) | 163 | 217 | 222-228 | 200-202 | 124 |
| 0.60 | 203 | 231 | 225 | | |
| 0.65 | 186 | 236 | 234 | | |
| **0.68** (4 runs) | **179** | **236** | **239** | **206-208** | **122** |
| 0.72 | | 227 | 234.5 | 203-205 | |
| 0.80 | 153 | 202 | 215 | | |

Splash rounds the share it is given (0.60 to 0.59, 0.64 to 0.65, 0.735 to
0.74). 0.68 is fastest from 2.9K to 34K tokens: +9% at 2.9K, +5% at 11K, +3%
at 34K over 0.735, and +10% at 820. At 128K it was 2% slower, one run each,
so the best share rises again for the longest prompts. Run to run, prefill
varied under 1%. Decode, short-prompt TTFT (0.27 s) and cached follow-ups
(1.0 s) did not change, and greedy answers to six short prompts were
identical. On an 11K-token prompt the greedy answer differed from 0.735's
after 147 characters, where the control's own cached rerun also differed: a
near-tie, as any change to the split can turn. At 0.68, three codes hidden at
10%, 50% and 90% of a 127.6K-token and a 238.8K-token prompt came back exactly;
those prompts read at 122 and 80 tok/s, 17 and 50 minutes. **Changed:**
`scripts/variant.sh` passes 0.68 on an M1 Max.

`--ane-ffn-minimum-rows 1024` at 0.735 ran prefill commands under 1,024 rows
at the given share without the pair: 150 at 820 tokens and 200 at 2.9K,
slower than both controls.
`--ane-ffn-minimum-rows 256` at 0.68 pairs prompts from 256 tokens: 400-token
prompts read at 120 tok/s against 147 with 512, so 512 stays.

### Other settings tried

Measured the same way on 2026-11-21, each between two control runs, none
adopted:

- `--kv-format bf16`: decode, prefill and TTFT inside the controls. It doubles
  the KV read per token, which only costs more at long context.
- `--prefill-mode full`: 11K-token prefill 207 tok/s against 206-217, and it
  drops the bound that keeps macOS from aborting long prefills.
- `--prefill-bound-ms 4000`: 217 against 206 and 222, inside the controls.
- `--persistent-cache`: no change while serving. After a restart, the
  follow-up of an 11K-token conversation started in 1.2 s instead of 46.7 s:
  Splash took back 3 GB of cached state in 5 s and started as fast as
  without it. It keeps up to 32 GiB in `~/Library/Caches/Splash`. Left
  at the default for now; restarts here are rare, upgrades and reboots.

**Where decode stands.** The GPU copies memory at 371 GB/s and multiplies
fp16 at 7.9 TFLOPS (Metal, measured here). Each decode cycle reads the
target's weights (about 15.4 GB), the draft's (3.85 GB) and the recurrent
state, about 19.5 GB, so it cannot take less than 53 ms. Splash measures its
cycles at 87 ms (its log, "Decode step costs"), about 60% of that floor.
None of Splash's settings reaches the kernels that make up the gap. Prefill
at 11K tokens keeps the GPU at about 80% of its multiply rate, with the
Neural Engine doing most of the FFN.

### Upgrades

Each upgrade ran `1-install.sh` and `3-services.sh` and kept the checkpoint,
the draft and every flag. Downtime runs from Splash stopping to "Ready". Each
new build recalibrates the Neural Engine once, and later starts reuse it.
Every installer's SHA-256 matched its release notes.

| Date | Version | Down | Neural Engine share | Result |
|---|---|---|---|---|
| 2026-10-31 | 1.3.2-m1.1 → 1.4.0-m1 | 89 s | 0.47, in 54.9 s | Passed. Faster on every speed case ([Speed](#speed)) |
| 2026-11-07 | 1.4.0-m1 → 1.5.0-m1 | 68 s | 0.47, in 41.4 s | Passed |
| 2026-11-07 | 1.5.0-m1 → 1.6.0-m1 | | | **Rolled back.** Requests hung (below) |
| 2026-11-14 | 1.5.0-m1 → 1.6.1-m1 | 104 s | 0.47, in 74.3 s | Passed. The hang is gone |
| 2026-11-21 | 1.6.1-m1 → 1.7.0-m1 | 287 s | 0.50, in 127.5 s, plus 114.5 s for its new chunk-pair timing | **Rolled back.** Follow-ups wrote nonsense (below) |
| 2026-11-21 | 1.7.0-m1 → 1.6.1-m1.1 | 70 s | 0.47, in 42.7 s | Passed. 16 of 16 graded follow-ups |

**1.6.0-m1 hung on M1.** Every chat but one failed with "Engine failed ·
native loop did not answer status within 30 s" and 503, and the engine took
about 40 s to restart each time. Prompts of 17 and 25 tokens failed and an
11-token one passed. This was the port's issue #51: the first compile of a
fused decode kernel took minutes on M1 and M2 and outran the 30 s watchdog
*(sourced)*. 1.6.1-m1 compiles only the kernels a model uses, and Splash 1.6.1
compiles every prefill shape in a warm-up before "Ready" *(sourced)*. On
1.6.1-m1, 38 fresh chats covering every prompt length that had hung, and a
three-turn cached chat, all answered.

**1.7.0-m1 wrote nonsense in short conversations.** It is Splash 1.7.0 with
the port's kernels, and its notes promise 6% faster decode and 14% faster
cold prefill at 16.7K tokens for this checkpoint on an M1 Max *(sourced)*. The
upgrade passed `3-services.sh` (200 with the key, 401 without), and single
requests, a 7K-token cold prompt, its cached follow-up, Messages and two-turn
Responses all answered correctly. But any short conversation with an earlier
assistant turn went wrong. A graded set of four such chats (3+3 after 2+2,
Italy's capital after France's, a code follow-up, recalling two earlier
answers), each with thinking off and at `medium`, with and without a 2K-token
system prompt, passed 2 of 16. Replies repeated one token to the output
limit, came back empty, or ignored the conversation. Once, with the shared
system prompt, the Italy question answered "6", the answer to another
conversation. `--verify-rows all` and a fresh start did not help. In the same
window 1.6.1-m1 answered all of these, and 1.6.1-m1.1 later passed 16 of 16.
No issue upstream or in the port matched on 2026-11-21. Not reported (the
maintainer's choice). **Changed:** the port is pinned at 1.6.1-m1.1, and
`verify.sh` now asks one of these follow-ups and fails unless it answers 6,
because the status checks passed on the broken build.

**1.6.1-m1.1** is 1.6.1-m1 with a fix for MoE models whose experts stream from
disk, and an opt-in prefill mode (`--ane-ffn-share`), not used here. Decode
and prefill for this checkpoint are unchanged from 1.6.1-m1 *(sourced)*. The
port's open issue #63, decode slowing after about a day of uptime, applies to
every version *(sourced)*.

**Splash 1.7.0 is pinned for M3 and later**, as released. It verifies draft
trees and prompt-lookup candidates in one pass, stores cached states in INT8,
and starts persistent caches from 1.6 cold once *(sourced)*. It has not run
on hardware here, and whether the 1.7.0-m1 failure comes from Splash's code
or the port's is not known. On a first M3 setup, `verify.sh`'s follow-up check
is the test.

### Startup

From the log of a start with the model already downloaded: weights load in
about 7 s, Splash patches the chat template to render later system messages
in place, picks the kernel policy for GPU family 7, sizes an SSD cache of up
to 32 GiB in `$TMPDIR`, and reports "Ready · context 256K" (262,144 tokens).
The first start of a new build adds the Neural Engine calibration, 1-3 min.
Idle, wired memory was about 33 GiB.

### Speed

Streamed chat completions at effort `medium`, timed on the client, three runs
each, medians. Read is prompt tokens over the time to the first token. Write
is completion tokens over the time after it. The prompts are this repository's
files, each with a fresh nonce so cold cases stay cold.

| Case | Prompt tokens | 1.3.2-m1.1 first token | 1.4.0-m1 first token | 1.4.0-m1 read | 1.4.0-m1 write |
|---|---|---|---|---|---|
| A question about `verify.sh`, cold | 2,615 | 14.1 s | 12.9 s | 203 | 44.0 |
| Its follow-up, cached | 2,640-2,870 | 2.1 s | 1.5 s | | 34.4 |
| README and three scripts, cold | 12,107 | 67.9 s | 60.4 s | 201 | 32.7 |
| A short code request | 63-67 | 1.0 s | 0.9 s | | 41.3 |
| Docs and four scripts, cold | 31,349 | 208.2 s | not run | | |

On 1.3.2-m1.1 the 31K case read at 151 tok/s and wrote 25.1, and its cached
follow-up started in 1.1 s. Reading and writing both slow as the conversation grows, and cached
follow-ups start in 1-2 s. Thinking prose drafts worse than code: these
prompts gave 3-4.6 tokens per draft cycle against 6-7 on the port's code prompts
*(sourced: port issue #11)*, which is why it writes below the port's 61 tok/s.

**Idle release.** After 10 idle minutes Splash frees the weights. The next
request waited 6 s more while they were restored ("Weights restored in
5.98 s"), and nothing else was slower. `--idle-release off` is the option if
those 6 s matter *(sourced: incoai/splash #292)*.

### Clients

All four clients worked from a Linux machine on the tailnet on 2026-10-18
(1.3.2-m1.1), following [the client guide](clients.md): Claude Code 2.1.302,
Codex 0.163.0, Hermes Agent 0.21.1 and OpenCode 2.0.32. Wall time of one
command each:

| Client | API | First turn | Prompt | Follow-up |
|---|---|---|---|---|
| `claude-local -p` | Messages | 97 s | 16,165 tokens | |
| `codex-local exec` | Responses | 99 s | 18,170 | |
| `hermes -z` | chat completions | 71 s | 12,728 | |
| `opencode run` | chat completions | 54 s | 9,655 | 2 s, 9,632 cached |

The log showed `effort medium` for `claude-local`, `effort absent → medium`
for the others, and `low` for OpenCode's titles. The API shapes these clients
need all answered 200: a mid-conversation system message, a JSON-schema
`output_config` (Claude Code's titles), and Responses with
`include: ["reasoning.encrypted_content"]` and `store: false` over two turns
(Codex). On 1.6.1-m1.1 and 1.7.0-m1 the reasoning item comes back as a visible
`summary` with `encrypted_content` null, and the second turn, which sends it
back, still answers. Hermes first asks for Ollama's `POST /api/show`, gets 404, and goes on.

**OpenCode 2.3.2 on the server, 2026-11-21 (1.6.1-m1.1).** The guide's
config moved to OpenCode 2's keys (`providers`, `agents`, `permissions`,
`capabilities.reasoning`). OpenCode 2 still reads the OpenCode 1 keys and
ignores a model's `reasoning: true` (its migration guide). With the new
config, `opencode run` and a follow-up answered. The log showed `low` for
the title, `effort absent → medium` for the first turn, and `high` for a
follow-up sent with `#high`. A streamed chat completion with an uncached
6K-token prompt got its headers and an empty first chunk in 0.06 s, then
nothing for the 49 s Splash took to read the prompt. So OpenCode's
`chunkTimeout`, 15 minutes by default, is the limit that applies, and the
config raises it to 30 minutes.

**Claude Code cancels a turn that thinks for 10 minutes.** While the model
thinks, Splash sends Claude Code only `ping` events. Claude Code accepts about
five minutes of them, waits `CLAUDE_STREAM_IDLE_TIMEOUT_MS` (5 min by default)
for real output, then cancels and resends the request *(sourced)*, which
starts the thinking again. That cancelled a turn at 600 s. With the timeout at
30 minutes, two turns at 95K tokens of context thought for 794 and 843 s and
finished. **Changed:** the client guide set it while it covered Claude Code.

**A long session.** One `claude-local -p --continue` documentation audit ran
five prompts, growing to 74,875 tokens of context with nothing refused or
dropped. The time went to thinking, not reading: a request at 70,916 tokens
read only 196 new ones. One request wrote 14,296 tokens at 21.2 tok/s.

**Under Claude Code's large prompt the model can drift.** Asked to reply "OK",
it once explored the machine with tool calls for 14 turns until it was
stopped.

### Not measured

- Any Mac other than this one: an M2, an M3 or later, or less than 64 GB.
- Lid-closed operation on battery, recovery from a power cut, and the battery
  watchdog firing.
- Heat under Splash ([Heat](#heat) is from before it).
- Coding quality. The guide defers to published results.
- How much time `medium` saves on a real session.
- `uninstall.sh` on a working server, because it takes the server down.

## The Mac

### Heat

2026-09-24, before Splash: ten minutes of continuous decoding, plugged in,
lid open. The GPU stayed at its full 1,290 MHz and about 34 W for all 120
samples, and decode did not slow, although macOS reported thermal pressure
Heavy from 8.7 minutes. What happens if Heavy lasts is unknown.

### Unattended operation

2026-09-27: with `pmset -a disablesleep 1`, the lid closed and mains power,
the Mac answered requests for over 90 minutes, with SSH and Screen Sharing
working throughout. `pmset -g log` showed no sleep or wake events that day.

### Security

- **Tailscale's access rules do not cover the local network** *(sourced)*.
  Anything listening on all interfaces is on the LAN. Before hardening, SSH
  offered password login to it.
- **macOS sshd ignores `ListenAddress`**, because launchd owns its socket, so
  the tailnet-only rule is a `Match Address` block.
- **A `Match Address` list of only negations matches nothing.** It needs a
  positive pattern first: `Match Address *,!100.64.0.0/10,...`. `verify.sh`
  asks `sshd -T -C` what applies to a LAN address instead of reading the file.
- **OpenSSH 10.5 prints `sshd -T` keywords in mixed case**
  (`PasswordAuthentication no`). The scripts compare keywords in any case.
- **`fdesetup enable` can print no recovery key.** On APFS it keeps one from
  an earlier enablement (`man fdesetup`). The copy System Settings showed, in
  Passwords, failed `fdesetup validaterecovery`. After
  `fdesetup changerecovery -personal` the new key passed, and Settings still
  showed the old one. [Six
  Colors](https://sixcolors.com/post/2026/05/filevault-keys-cant-be-escrowed-in-iCloud-anymore/)
  reports the same mismatch *(sourced)*.
- **`autogroup:self` leaves out tagged devices.** With only that grant, a
  client's packet filter did not list the server while it was tagged, and did
  once it joined untagged. So the policy grants by ownership, and
  `2-tailscale.sh` refuses a tagged machine when `LLM_TAG` is empty.
- **pf filters loopback.** Tailnet-only rules also drop connections from
  127.0.0.1, so Screen Sharing never answers on the Mac itself.
- **Nothing root runs lives in Homebrew's prefix**, which the user owns. Until
  2026-11-07 `tailscaled` ran as root from it (`sudo brew services`), so
  anything running as the user could swap it. `2-tailscale.sh` copies it to
  `/usr/local/bin` and runs it from `com.tailscale.tailscaled`. Tailscale's own
  `install-system-daemon` does not restart tailscaled if it exits
  (`cmd/tailscaled/install_darwin.go`) *(sourced)*, so the script writes its
  own job. Both keep `/Library/Tailscale/tailscaled.state`, so the machine
  keeps its identity.
- **`launchctl bootout` returns before the job is gone**, and an immediate
  `bootstrap` fails with `5: Input/output error`. Hence `stop_job` and
  `start_job` in `scripts/lib.sh`.

### Is local worth it

Hosted providers serve the same model at about $0.10 / $1.80 per million
input / output tokens and hundreds of tokens a second *(sourced)*. This M1 Max reads 160-235
and writes 23-44. Apple quotes an M5 Max at 6.7 times an M1 Max on prompt
processing *(sourced)*. Local is for privacy, batch work and a private endpoint, not
speed.

## References

- Splash: https://github.com/incoai/splash, and 1.7.0's notes:
  https://github.com/incoai/splash/releases/tag/1.7.0
- The M1/M2 port: https://github.com/paperniuk/splash, and the notes for
  1.6.1-m1.1 and 1.7.0-m1:
  https://github.com/paperniuk/splash/releases/tag/1.6.1-m1.1,
  https://github.com/paperniuk/splash/releases/tag/1.7.0-m1
- Port issue #11, decode cycles on M1 Max: https://github.com/paperniuk/splash/issues/11
- Port issue #51, the 1.6.0-m1 hang: https://github.com/paperniuk/splash/issues/51
- incoai/splash #292, `--idle-release off`: https://github.com/incoai/splash/issues/292
- Splash on 24 GB Macs: https://github.com/incoai/splash/blob/1.7.0/docs/performance.md#smaller-ggufs-on-24-gb-macs
- Claude Code, streaming idle watchdogs: https://code.claude.com/docs/en/network-config#streaming-idle-watchdogs
- Artificial Analysis Intelligence Index: https://artificialanalysis.ai/
- Tailscale, ACLs and the local network: https://tailscale.com/docs/features/access-control/acls
- Hosted pricing: https://openrouter.ai/qwen/qwen3.8-27b
- Apple M5 Max: https://www.apple.com/newsroom/2026/08/apple-introduces-new-mac-studio-with-m5-max-and-m5-ultra/
- Kodesage, Qwen3.8 27B efforts: https://kodesage.ai/blog/qwen-3-8-27b-llm-model-review
- Jose Romero, every reasoning level: https://hijoseromero.com/letters/qwen-thinking-levels
- QwenLM/Qwen3.8 #216, empty answers at xhigh: https://github.com/QwenLM/Qwen3.8/issues/216
