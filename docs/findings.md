# Findings

The reasons behind each choice in the [guide](../README.md), and the
measurements behind them. The server is a MacBook Pro 16" (M1 Max, 32-core
GPU, 64 GB) on macOS 27.x. Items marked *(sourced)* come from the linked
references and were not reproduced here. Items marked *(source)* were read
from mlx-serve's code at the pinned tag, not measured. Everything else was
measured on 2026-11-23, 2026-11-24 and 2026-11-25 with the Mac to itself: no other model
server, no download or build running, on AC power.

The setup has three parts, each chosen by measurement:

| Part | Choice | Against |
|---|---|---|
| Engine | Upstream mlx-serve 26.11.4-pre-release.1, built from source, with namp's M1/M2 patch and this repo's speed patch | The same build without each patch, and Splash 1.7.3-m1 for M1/M2 |
| Model | OpenUncensored's Inkling 2 Mini Uncensored, converted by upstream's converter: attention 4-bit, embedding and head 6-bit, experts as released | The 8-bit pack of the stock model, and namp's 4-bit requant |
| Flags | A 262,144-token window, a 24 GB prefix cache, 4,096-token prefill chunks, 4-bit KV cache, larger MLX command buffers | mlx-serve's defaults, and 8-bit or full KV |

## How it was measured

- **The panel.** Six greedy decode prompts with thinking off (median of
  six), three sampled prompts at the server's default effort, two requests
  at once, prompt reading at 0.8K, 2.9K, 10K and 30K tokens, the first token
  of a short prompt and of follow-ups at 2.9K, 10K and 30K tokens, and peak
  wired memory. Times are the client's: decode is tokens after the first over
  the time after it.
- **Sampled workloads.** OpenCode sends no temperature, so its requests run
  at the pack's default: temperature 1.0, top-p 1.0, top-k 0. Six short
  prompts at that default; three whole-file edits, each renaming one function
  in a 2K- to 9K-character script of this repo and returning the file, diffed
  against the expected file; and three coding asks at `medium`. mlx-serve's
  completion-token count for the same text varies by up to 2x between runs
  and builds, so edits are compared in characters per second.
- **Tokens, from 2026-11-25.** Each reply is counted again with the model's
  own tokenizer, reasoning included, because mlx-serve's completion-token count
  varies. Whole-file edits are greedy in A/B runs, since sampled replies differ
  in length from run to run; the gates still sample.
- **Controls.** Each candidate ran between two runs of the current best, and
  was kept only if it beat both on its metric and lost nothing else by more
  than about 3%. Run-to-run noise on decode was under 1%.
- **Depth.** Decode of 300 greedy tokens after a cold prompt of 8K, 36K and
  71K tokens, and after a needle prompt of 129K.
- **Quality.** Upstream's `tests/inkling2_kld.py`: the top logprobs of
  14,613 positions over 8 files of mlx-serve's own source and docs, served by
  each pack, compared with the release's. Mean KL divergence, top-1
  agreement and perplexity.
- **Gates**, run on the final setup before it shipped:
  - three random codes at 10%, 50% and 90% depth of a 129K- and a 242K-token
    prompt, all three answered, then a cached follow-up;
  - 16 graded follow-ups: four short chats whose last turn depends on an
    earlier answer, at thinking off and `medium`, with and without a 2K-token
    system prompt;
  - OpenCode-shaped follow-ups: streamed, one tool declared, only the answer
    sent back, at 3K, 11K and 38K tokens;
  - two long conversations, 129K and 111K tokens, then a follow-up on each,
    to see whether the cache keeps both.

## The engine

namp's [mlx-serve-inkling2-m1](https://github.com/namp/mlx-serve-inkling2-m1)
is a fork of upstream at the commit the pinned tag points to: its `src/` tree
at the base commit is upstream's at 26.11.4-pre-release.1, file for file. The
fork changes 29 files under `src/` and nothing in the build. This repo carries
that change as `patches/inkling2-m1.patch` (namp's `83865a4..c352f28`, `src/`
only) and applies it to upstream's source, so the fork can be dropped once
upstream ships the same, and nothing else of the fork is needed. What the
patch does *(sourced: namp's README)*:

- FP16 instead of bf16 on M1 and M2, which have no bf16 arithmetic.
- Attention fused with a 4- or 8-bit KV cache, read in one kernel.
- Barrier-free expert down and up projections, and FP16 gates.
- Inkling's reasoning sent as `reasoning_content` in a streamed reply without
  tools. Upstream sends it in `content` (upstream issue #1292), so a client
  that sends the answer back sends the reasoning too, and misses the cache.
- Expert projections read at 16 and 8 lanes a group, and, when drafted rows
  are verified, one read of an expert's weights for up to four rows that
  picked it.
- Drafting on by default on M1 and M2: the pack's draft head, plus spans
  copied from the prompt. At a sampled temperature with top-p 1 and top-k 0,
  the draft and the model share one random draw per position, which keeps
  the output distribution exact and accepts more drafted tokens.
  `INKLING_NO_DRAFT=1` turns drafting off.

Both builds were made the same way, by upstream's release recipe at the tag:
Zig 0.17.0, MLX and mlx-c from the tag's submodules, libllama b12110, `zig
build -Doptimize=ReleaseFast -Dstrip`, laid out and signed ad hoc as the
release workflow does. A clean build took 8 minutes, the patched rebuild 3.

The patch's first version (namp's `e18e2ed`), on the stock 8-bit pack, two
runs of each, alternating:

| Metric | Stock | Patched |
|---|---|---|
| Decode, greedy | 43.8-43.9 tok/s | 47.7-48.1 tok/s |
| Two requests at once, together | 40.7-42.7 tok/s | 44.6-47.8 tok/s |
| First token of a follow-up at 2.9K / 10K / 30K | 0.81 / 0.87 / 1.07 s | 0.48 / 0.53 / 0.64 s |
| Prompt reading at 30K | 362-371 tok/s | 382-384 tok/s |
| Decode deep in a 129K-token prompt | 22.1 tok/s | 22.8 tok/s |
| Mean KLD against the stock build, same pack | | 0.0035, top-1 97.4%, perplexity 5.173 to 5.175 |

The patched build is 9% faster at decode and 40% faster to a follow-up's
first token, and its output matches the stock build's to within 0.0035 KLD,
less than the pack choices below move it. **Kept.**

### namp's update of 2026-11-24

namp's `e18e2ed..c352f28` added the expert dedup, the narrower kernels and
default drafting above. On the uncensored pack with the final flags, in the
order before, update, update with drafting off, before, update:

| Workload | Before | Update | Update, drafting off |
|---|---|---|---|
| Short prompts, greedy | 48.0-48.8 tok/s | 49.3 tok/s | 50.6 tok/s |
| Short prompts, sampled | 47.9-48.2 tok/s | 47.7-48.0 tok/s | 50.0 tok/s |
| Whole-file edits, sampled | 93-103 chars/s | 178-186 chars/s | 97 chars/s |
| Coding asks at `medium`, sampled | 47.4-47.5 tok/s | 50.6-53.1 tok/s | 49.3 tok/s |
| Edits exact, sampled | 15 of 19 | 12 of 19 | 7 of 9 |
| Decode after 8K / 36K / 71K-token prompts, greedy | 46.2-46.6 / 41.3 / 36.3 tok/s | 45.7-48.0 / 41.3-41.6 / 35.6 tok/s | |
| Mean KLD against the build before | | 0.0000, top-1 100% | |

Sampling at the pack's default costs the build before nothing on short
prompts, so greedy numbers hold for OpenCode. The update nearly doubles
whole-file edits, the work an agent does most, because spans copied from the
prompt are almost always accepted: 2,980 of 3,129 in one run. Every edit that
missed, on either build, escaped the quotes inside a `$(...)` by hand; the
gap in exact edits is inside what 19 runs can tell apart. Greedy edits were
exact on every build. Drafting off is 4% faster on short sampled prompts and
loses the edit gain. The update passed every gate. **Kept**, with drafting on.

### This repo's patch

`patches/inkling2-m1-speed.patch` changes 16 lines of namp's code, in two
parts. Measured on the uncensored 4-bit pack with the final flags and command
buffers, each part between two runs of the build before it.

**Draft rounds handed to the GPU as they are built.** A draft round waits
for its picks, so the GPU sat idle while the CPU built the whole verify
graph. The patch sets the round's `pipeline_every` to 4 layer visits, the
cadence mlx-serve already uses for its other verifiers. 2 and 8 measured the
same. A verify round's time, by rows:

| Rows | Before | After |
|---|---|---|
| 1 | 22.5 ms | 19.5 ms |
| 4 | 47.0 ms | 43.8 ms |
| 7 drafted | 67.3-68.4 ms | 63.3 ms |
| 7 copied from the prompt | 73.3-74.8 ms | 65.3 ms |
| 16 copied | 120-121 ms | 108 ms |

Whole-file edits went from 199-203 to 237 chars/s, thinking at `medium`
from 55.5-56.4 to 58.7 tok/s, short decode by 2-3%. Outputs are the same
computation, handed over sooner.

**Spans copied from the prompt verify 16 rows at any context.** namp's
drafter proposes up to 15 copied tokens only while the context is 2,048
tokens or less, and 6 past it, because its fused 4-bit-KV verify read took 8
rows; a wider verify dequantized the whole window at every visit. An agent's
context is 10K to 40K tokens, so its edits got 6. Letting the fused read take
16 rows first broke every edit: the kernel attended only the first 8 of the
rows it verifies. The patch loops that part of `qkv_ink2_verify.metal` over
tiles of 8, which leaves 8 rows or fewer unchanged, and lifts the context
limit:

| Edits | Before | After |
|---|---|---|
| 1-4K tokens of context | 231-239 chars/s | 274 chars/s |
| Behind a cached 31K-token context | 196 chars/s | 220 chars/s |
| A 16-row copy round at 31K | not used | 163 ms, 14.7 tokens accepted |

Every edit came back exact. Short decode and thinking did not move. Without
the kernel fix, 16 rows at 31K took 200 ms and lost to 7.

### Splash 1.7.3-m1

paperniuk's Splash port for M1 and M2 serves Inkling 2 Mini from 1.7.3-m1,
with Inco's DFlash2 draft model. It serves the same converted pack, once its
`config.json` names `text_config.model_type` (`inkling2_loop_text`), which
upstream's converter leaves out. Splash between two runs of the final setup,
the same day:

| Workload | Final setup | Splash 1.7.3-m1 |
|---|---|---|
| Decode, greedy / sampled as OpenCode asks, short | 55.8-56.2 / 55.8-56.0 tok/s | 45.0 / 41.7 |
| Thinking at `medium` | 57.0-59.1 tok/s | 51.8 |
| Whole-file edits, greedy, 1-4K of context | 275-277 chars/s | 308 |
| Two / four requests at once, together | 48.1-48.2 / 68.2-68.3 tok/s | 64.3 / 84.1 |
| Prompt reading at 3K / 10K / 30K | 425-427 / 421 / 380 tok/s | 547 / 516 / 412 |
| First token of a follow-up at 3K / 10K / 30K | 0.45-0.46 / 0.50 / 0.61 s | 0.18 / 0.18 / 0.19 |
| Decode after a 36K / 71K-token prompt | 45.8-46.0 / 39.3-39.4 tok/s | 43.1 / 30.2 |

Splash's draft runs 55-60 tok/s on code and 37-45 on prose. A one-row verify
step costs it 38 ms, and 62 ms at 8 rows, against 19.5 and 63 ms here.
mlx-serve is kept for one request at a time, which is most of an agent's
turn: decode is 20-34% faster and 30% faster deep in a conversation. Splash
reads prompts faster and answers follow-ups sooner.

## The pack

OpenUncensored's
[Inkling-2-Mini-Uncensored](https://huggingface.co/OpenUncensored/Inkling-2-Mini-Uncensored)
is the release with refusals ablated. It ships in the release's own format,
and only its 20 attention output projections differ from the release; the
draft head is byte-identical to the stock pack's. mlx-serve reads MLX packs,
so `1-install.sh` converts it with upstream's own
`tests/convert_inkling2.py`, which keeps the routed experts' bytes (NVFP4 and
MXFP8) and quantizes the rest.

Five packs, decode on the patched engine with the base flags. The uncensored
packs are scored against the uncensored release; the stock 4-bit pack against
the stock 8-bit pack, since the stock release was not downloaded here (the
8-bit pack's card puts it at 0.0040 from its release *(sourced)*):

| Pack | Built by | Decode | Mean KLD | Top-1 | Perplexity |
|---|---|---|---|---|---|
| Stock, 8-bit (`ddalcu/Inkling-2-Mini-MLX-8bit`) | upstream's converter, `--bits 8` | 47.9-48.0 tok/s | reference | | 5.173 |
| Stock, 4-bit attention | namp's requant of the 8-bit pack | 50.9 tok/s | 0.0185 | 94.0% | 5.244 |
| Uncensored, 8-bit | upstream's converter, `--bits 8` | 47.9 tok/s | 0.0042 | 97.1% | 5.217 |
| Uncensored, 4-bit attention | namp's requant of the 8-bit pack | 51.5-51.6 tok/s | 0.0188 | 94.0% | 5.262 |
| **Uncensored, 4-bit attention** | **upstream's converter, `--bits 4 --embed-bits 6 --head-bits 6`** | **51.7 tok/s** | **0.0189** | **94.0%** | **5.276** |

- **Uncensored costs no speed.** Its 8-bit pack decodes as fast as the stock
  one, and reads prompts as fast. Against the stock pack, its output differs
  by 0.0177 KLD, about what 4-bit attention costs.
- **4-bit attention is 7.5% faster at decode**, at 0.019 KLD and 94% top-1
  agreement. Prompt reading and follow-ups are unchanged, and the pack is
  17.5 GB against the 8-bit pack's 18.7.
- **Upstream's converter matches namp's requant.** Converted from the release
  in one step, it scores the same as namp's two steps (release to 8-bit to
  4-bit) and decodes as fast, so the install needs nothing of namp's but the
  engine patch. Its pack is 17.5 GB, and converting it took 7 s.

**Kept:** the last row. The four lossy packs differ from their release by
about the same amount, so the choice is speed and the uncensored model.

## Settings

Everything is mlx-serve's default except the LaunchAgent, ten flags, two MLX
variables ([Command buffers](#command-buffers)) and one generation rule
(README, "How it works").

- `--model ~/.mlx-serve/models/local/Inkling-2-Mini-Uncensored-q4attn`, the
  converted pack. mlx-serve reads `--model` as a path and names the model
  after the folder's last part *(source: `src/main.zig`)*. It serves a request
  naming an unknown model with its one model instead of answering 404
  *(source: `src/host/http/router.zig`)*.
- `--host 127.0.0.1`. By default mlx-serve listens on 0.0.0.0, every
  interface *(sourced: `docs/cli.md`)*.
- `--port 8000`, the target of `tailscale serve`. The default is 11234.
- `--api-key-env MLX_SERVE_API_KEY`. mlx-serve reads the key from the
  variable instead of its command line, which any account can read with `ps`.
  An empty or missing variable leaves the server open, so the LaunchAgent's
  shell refuses to start it without a key *(source: `src/main.zig`)*.
- `--api-key-strict`. Without it, mlx-serve asks no key of a client on
  loopback *(source: `apiKeyGateApplies` in `src/host/http/auth.zig`)*, and
  `tailscale serve` connects from 127.0.0.1, so every request from the tailnet
  would get in without the key. `verify.sh` checks the 401 over the tailnet.
- `--ctx-size 262144`. Left to itself, mlx-serve sizes the window from the
  memory free at each start, 130K to 500K tokens here, and a window that moves
  breaks a client's configured limit. The model takes 1,048,576, but reading
  262,144 cold already takes about 20 minutes on this Mac.
- `--prefix-cache-mem 24GB`. mlx-serve grants less than it is asked, after the
  weights, the window's KV and the prefill's reserve: about 23 GB with this pack
  and 4-bit KV. The default left 0 to 2.3 GB, too little for one long
  conversation.
- `--prefill-chunk 4096`. Without it, mlx-serve shrinks the chunk to pay for a
  larger cache, down to 512 tokens. 4,096 reads as fast as 8,192, and keeps a
  242K follow-up cached where 8,192 missed: with 8,192, the conversation's
  last cache point fell behind the sliding window.
- `--kv-quant 4`. The KV cache in 4 bits, read by the patch's fused attention
  ([Context depth](#context-depth)).
- `--log-file off`. launchd already writes mlx-serve's output to
  `~/Library/Logs/llm-server/mlx-serve.log`.
- `~/.mlx-serve/generation-settings.json` holds
  `{"reasoning_effort": {"value": "medium"}}`
  ([Reasoning effort](#reasoning-effort)).

By default mlx-serve keeps the model loaded however long it idles, keeps
shared prefixes in a RAM cache and writes none to disk, queues requests and
decodes those that arrive together in one batch, and stops a request after
300 s without a new token *(sourced: `docs/cli.md`)*. mlx-serve has no list of
allowed Host names, so a web page that points its name at 127.0.0.1 can reach
it from a browser on this Mac, but `--api-key-strict` makes it present the key
too.

### Command buffers

MLX starts a new Metal command buffer once the current one references more
than 50 MB of buffers or holds 50 operations: the defaults for an M1 Max
*(source: `mlx/backend/metal/device.cpp`)*. Every expert projection reads a
573 MB bank, so a decode step closed about two buffers a layer visit, 107 a
token, and the GPU idled about 32 us between them: 16% of the step, in a
Metal System Trace. The LaunchAgent sets `MLX_MAX_MB_PER_BUFFER=1000000` and
`MLX_MAX_OPS_PER_BUFFER=100`:

| Workload | Defaults | 1,000,000 MB | And 100 ops |
|---|---|---|---|
| Decode, greedy, short | 48.7-49.0 tok/s | 52.0-54.0 | 55.1-55.3 |
| Decode, sampled as OpenCode asks | 47.8-48.4 | 51.6-53.9 | 54.2-55.3 |
| Thinking at `medium` | 50.0-51.2 | 53.6-55.8 | 55.4-57.3 |
| Four requests at once, together | 64.4-64.7 | 65.9-66.0 | 68.3-68.7 |

Prompt reading and follow-ups did not change. 25 ops was slower than 50, and
1,000 slowed prompt reading by 8%.

### Context depth

The KV cache grows with the conversation, and decode reads all of it for every
token, so decode slows as a conversation gets longer. In 4 bits it reads a
quarter of the bytes, through the patch's fused kernel. Decode of the
uncensored 4-bit pack, KV in full against 4 bits, with full KV run before and
after. The deep rows used namp's requant, which decodes as fast as the final
pack, and the 129K row the stock 8-bit pack:

| Prompt | Full KV | 4-bit KV |
|---|---|---|
| Short (the panel) | 51.3-51.6 tok/s | 47.9 tok/s |
| 8K | 45.6 | 45.9 |
| 36K | 37.2 | 41.1 |
| 71K | 30.6 | 36.0 |
| 129K | 22.8 | 27.9 |

4-bit KV loses 7% on short prompts and wins from 8K tokens up, by 18% at 71K
and 22% at 129K. An agent's first prompt is already 8-20K tokens. Prompt
reading is unchanged, peak wired memory falls by 11.6 GB (39.6 to 28.0), and mlx-serve's
cache grant grows from 17.2 to about 23 GB. The 129K needle passed 3 of 3. 8-bit
KV was slower than 4-bit everywhere: 44.6 tok/s short, 24.4 at 129K.
**Kept: 4-bit.**

### Tried and rejected

| Change | Result |
|---|---|
| `--kv-quant 8` | Slower than 4-bit at every depth (above) |
| Prefill chunk 8192 against 4096 | Equal reading speed; a 242K follow-up missed the cache |
| Prefill chunk 2048 | 8-10% slower reading at 3K and 12K, and a 38K follow-up missed |
| Prefix cache 8 GB | A 242K conversation did not fit, so its follow-up read cold for 20 min |
| `--ssm-checkpoint-max 0` | No change |
| `--max-concurrent 2` | Inside the controls |
| `--prefix-cache-disk 40GB` | Follow-ups of two long conversations both read cold, where the RAM cache alone serves one |
| `INKLING_NO_DRAFT=1`, the update's drafting off | 4% faster on short sampled prompts, half the speed on whole-file edits (above); with the final command buffers 2% faster on short prompts and a third slower on edits |
| `MLX_MAX_OPS_PER_BUFFER` 25 or 1,000 | 25 slower than the default; 1,000 slowed prompt reading by 8% |
| `prep` reading the joined projections in place at 2+ rows, without MLX's copies | Inside the controls |

The chunk, cache, checkpoint, concurrency and disk rows ran earlier the same
day on the stock release with the 8-bit pack and full KV. What decided them,
the cache's size against a conversation's and the sliding window against the
chunk, does not depend on the engine or the pack.

## Reasoning effort

Inkling's chat template maps an effort word to a level, `low` 0.2, `medium`
0.7, `high` 0.9 and `xhigh` 0.99, and uses 0.9 when a request names none
*(sourced: the pack's `chat_template.jinja`)*. OpenCode names none unless
you pick a variant, so every turn would think at `high`.

`~/.mlx-serve/generation-settings.json` holds rules for request fields. A
rule fills a field the request leaves out; `"ignore_client": true` would make
it replace the request's value. mlx-serve reads the file again when it
changes *(sourced: `docs/reference.md`, "Generation defaults")*. It refuses
the whole file over one bad field or value *(source:
`src/host/api/generation_settings.zig`)*.

`3-services.sh` installs `{"reasoning_effort": {"value": "medium"}}`, without
`ignore_client`, so a client that asks for `high` still gets it. On five
prompts, a full answer took 68 s at `medium` and 106 s at `high`, on the stock
release before tuning.

## Measurements

The final setup (both patches, the converted uncensored pack, the flags and
MLX variables above, built clean by `1-install.sh`, two panels and the gates on
2026-11-25), against the stock release that started 2026-11-23, mlx-serve
26.11.4-pre-release.1 with the 8-bit stock pack and the same window, cache
and chunk:

| Metric | Stock release | Final |
|---|---|---|
| Decode, greedy, short prompts | 43.8 tok/s | 55.8-56.2 tok/s |
| Decode, sampled as OpenCode asks, short prompts | not measured | 55.7-56.0 tok/s |
| Whole-file edits, greedy, 1-4K / behind 31K of context | not measured | 275-283 / 220 chars/s, all exact |
| Thinking at `medium`, sampled | not measured | 57.0-59.1 tok/s |
| Decode at 36K / 71K tokens | not measured | 45.8-46.0 / 39.3-39.4 tok/s |
| Decode at 129K / 242K tokens | 22.1 / 16 tok/s | 27.9 (8-bit pack) / 21.7 tok/s, before namp's update; not measured since |
| Two / four requests at once, together | 42.7 tok/s / not measured | 48.1-48.5 / 68.2-68.7 tok/s |
| Prompt reading at 10K / 30K tokens | not measured / 362-371 tok/s | 421 / 380 tok/s |
| Cold read, 128.7K / 241.7K tokens | 8.0 / 20.1 min | 7.8 / 19.6 min |
| First token of a follow-up at 2.9K / 10K / 30K | 0.81 / 0.87 / 1.07 s | 0.45-0.46 / 0.50 / 0.61 s |
| OpenCode-shaped follow-ups at 3K / 12K / 39K | 0.6 / 0.7 / 1.0-1.6 s | 0.48-0.49 / 0.53 / 0.65-1.43 s |
| Reasoning split from the answer when streaming without tools | no (#1292) | yes |
| Two long conversations (129K, 111K), follow-up on each | the first cached, the second read cold | both cached, first token in 1.0-1.2 s |
| Follow-up at 242K tokens | cached, first token 3.3 s | cached, full answer in 7.8 s |
| Graded follow-ups | 16 of 16 | 16 of 16 |
| Three codes in a 129K / 242K-token prompt | 3 of 3 / 3 of 3 | 3 of 3 / 3 of 3 |
| Start to ready, pack in the page cache | 2-4 s | 3.2 s |
| Peak wired memory, panel | 37-39 GB | 29 GB |

The first token of a short prompt varied from 295 to 500 ms between runs of
the same setup, so it is not compared. The second 39K OpenCode-shaped
follow-up took 1.43 s because it read 245 new tokens, the earlier answer
being longer.

### How close to the limit

A plain decode step reads 3.26 GB: 1.84 GB of the 8 routed experts in each of
48 layer visits, 1.04 GB of attention and gates over the same visits, and the
0.38 GB head. The GPU reads 342 GB/s here, so one token a step cannot beat
105 tok/s. Short decode runs at 56, 53% of that, up from 46% at the start of
2026-11-25. A Metal System Trace with GPU counters puts the read bandwidth at
peak during the expert kernels and at a mean of 48% over the step. Read from
the code, a step is about 760 stages in a row, most of them small, at roughly
10 us each. Fewer, fused stages are the next gain. A verify round has more to
gain than a plain step: each added row costs 6.5-8 ms, where its new experts
are at most about 1.6 GB, 5 ms.

## What mlx-serve's notes say about this model

From the notes of the plugin that serves Inkling 2,
`src/plugins/inkling2/AGENTS.md` at the pinned tag *(source)*:

- A sliding-window layer keeps the window plus 2,048 rows. A prefix-cache
  match more than 2,048 tokens behind the end of a cached conversation misses,
  so an edit that far back reads the prompt again from the start.
- A follow-up stores a new cache entry beside the one it extends, and the
  cache evicts the oldest entry first.
- On M1 and M2, two of its kernels compile for 384 to 576 threads a group,
  where an M3 or later runs 768. mlx logs this at every start; no output here
  was wrong.

## Not measured

- Any Mac other than this one: an M2, an M3 or later, or less than 64 GB.
  The patch's M1/M2 paths apply to M1 and M2 only; on M3 and later upstream's
  own paths run, and mlx-serve loads the pack's draft head by itself.
- Coding quality, and what the ablation changes beyond refusals. The guide
  defers to published results.
- How much time `medium` saves over `high` on a real session.

## References

- mlx-serve: https://github.com/ddalcu/mlx-serve, 26.11.4-pre-release.1:
  https://github.com/ddalcu/mlx-serve/releases/tag/v26.11.4-pre-release.1,
  its docs and code at the tag: https://github.com/ddalcu/mlx-serve/tree/v26.11.4-pre-release.1
- The patch's source: https://github.com/namp/mlx-serve-inkling2-m1
- The model: https://huggingface.co/OpenUncensored/Inkling-2-Mini-Uncensored
- The base model: https://huggingface.co/thinkingmachines/Inkling-2-Mini
- Upstream issue #1292 (reasoning in `content` when streaming without tools)
  and #1308 (decode collapse on long generations on an M1 Max):
  https://github.com/ddalcu/mlx-serve/issues
