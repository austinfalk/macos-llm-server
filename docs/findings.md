# Findings

The reasons behind each choice in the [guide](../README.md), and the
measurements behind them. The server is a MacBook Pro 16" (M1 Max, 32-core
GPU, 64 GB) on macOS 27.x. Items marked *(sourced)* come from the linked
references and were not reproduced here. Items marked *(source)* were read
from mlx-serve's code at the pinned tag, not measured. Everything else was
measured from 2026-11-23 to 2026-11-27 with the Mac to itself: no other model
server, no download or build running, on AC power.

The goal is Inkling 2 Mini, in MLX weights, decoding at the limit this Mac's
memory bandwidth and KV cache set, with speculative decoding on
([How close to the limit](#how-close-to-the-limit)). The setup has three
parts, each chosen by measurement and replaceable by a faster one:

| Part | Choice | Against |
|---|---|---|
| Engine | Upstream mlx-serve 26.11.4-pre-release.1, built from source, with namp's M1/M2 patch and this repo's speed patch | The same build without each patch, and Splash 1.7.3-m1 for M1/M2 |
| Model | Thinking Machines' release, converted 8-bit by upstream's converter with the experts as released, and AtomicChat's uncensoring merged in | OpenUncensored's uncensored release at 4- and 8-bit attention, the stock release at 4, 5, 6 and 8 bits |
| Flags | A 262,144-token window, a 16 GB prefix cache, 4,096-token prefill chunks, 8-bit KV cache, larger MLX command buffers | mlx-serve's defaults, and 4-bit or full KV |

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

### DFlash 2, namp's update of 2026-11-25

namp's `c352f28..ab16dcb3` adds a drafter in Metal for Inco's DFlash 2 model
([incoai/Inkling-2-Mini-DFlash2](https://huggingface.co/incoai/Inkling-2-Mini-DFlash2),
1 GB in BF16, quantized to 8 bits at load). It replaces the pack's own draft
head, and copied spans still come first; acceptance stays exact. The
LaunchAgent names its folder in `INKLING_DFLASH2_DIR`, and `1-install.sh`
downloads it, pinned by revision and checksum. The same commit adds a tool
that grafts Lucebox's "Fast" fine-tune into every layer's attention output
projection: a different model, on the tensors that hold the uncensoring's
ablation, so it was not tried.

Against the build before it, in the order before, DFlash 2, before,
DFlash 2, with this repo's patch on both:

| Workload | Before | DFlash 2 |
|---|---|---|
| Decode, greedy, short | 55.0-55.8 tok/s | 56.8-57.7 tok/s |
| Decode, sampled as OpenCode asks | 55.1-55.6 tok/s | 56.2-56.9 tok/s |
| Thinking at `medium` | 57.6-58.3 tok/s | 59.5-60.0 tok/s |
| Tokens accepted in a 7-row round | 4.09 | 4.56-4.70 |
| The drafter's time a round | 6.7 ms | 7.4 ms |

Edits, two and four requests at once, and prompt reading did not move.
**Kept.**

### This repo's patch

`patches/inkling2-m1-speed.patch` changes 24 lines of namp's code, in three
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

**More threadgroups for the cached-KV read.** One row's read of the cache
split its keys 256 at a time into at most 16 parts: 128 threadgroups at 4K
keys and up, 4 to a core. 128 keys a part and at most 64 parts:

| Decode after a prompt of | 256 keys, 16 parts | 128 keys, 64 parts |
|---|---|---|
| 18K tokens | 50.3-50.4 tok/s | 51.1 tok/s |
| 36K tokens | 45.7-45.8 tok/s | 46.9 tok/s |
| 71K tokens | 39.2-39.7 tok/s | 41.7 tok/s |

32 or 64 parts at 256 keys came between the two. A trace at 36K shows the
read is limited by arithmetic, not bandwidth (read bandwidth falls, the ALU
limiter rises), so more parts help only a little.

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

The pack is the one closest to Thinking Machines' release that this Mac runs
at speed, with refusals removed. Each candidate was scored against the
release itself (`thinkingmachines/Inkling-2-Mini` at `c9d02830`), served by
plain upstream mlx-serve at the pinned tag with full KV, using upstream's
`tests/inkling2_kld.py` over its 8 files: 14,724 positions at 6,000
characters a file, and 58,998 positions over 100,000 characters each of two
of them. The long pass is the one below; the short pass ranks every pack the
same way. Speed is decode on this setup, greedy, short prompts and at 71K
tokens:

| Pack | KV | Mean KLD | Top-1 | Perplexity | Decode | At 71K |
|---|---|---|---|---|---|---|
| The release, mlx-serve with both patches | full | 0.0041 | 96.9% | 7.26 | 18 tok/s | 8 |
| Stock 8-bit (upstream's converter, `--bits 8`) | 8-bit | 0.0052 | 96.5% | | 54.1 | 36.1 |
| Stock, attention 6-bit, k and v 8-bit | 8-bit | 0.0070 | 96.0% | | 54.9 | 36.7 |
| Stock, attention 6-bit | 8-bit | 0.0077 | 95.7% | | 55.0 | 35.8 |
| **Stock 8-bit with AtomicChat's uncensoring** | **8-bit** | **0.0110** | **94.7%** | **7.26** | **52.7** | **34.9** |
| Stock, attention 5-bit | 8-bit | 0.0127 | 94.6% | | 51.3 | 36.1 |
| Stock, attention 4-bit | 8-bit | 0.0275 | 91.7% | | 57.6 | 39.0 |
| OpenUncensored, attention 4-bit (the previous pack) | 8-bit | 0.0418 | 90.1% | | 56.6 | 36.5 |
| OpenUncensored, attention 4-bit (the previous pack) | 4-bit | 0.0548 | 88.5% | | 58.7 | 40.0 |

- **The floor is about 0.004.** Two exact computations of the release differ
  by that much: this repo's build against plain upstream 0.0041, and mlx-lm's
  draft support for Inkling 2 (PR #2086 at `e2b5bbd3`) against plain upstream
  0.0043.
- **The costs add up.** 4-bit KV costs about 0.02 KLD, OpenUncensored's
  ablation about 0.02, 4-bit attention 0.015 to 0.022. 8-bit KV costs about
  0.001. 6-bit attention closes 88% of the gap from 4-bit to 8-bit but decodes
  only 2% faster than 8-bit; 5-bit is slower than 6-bit and less exact.
- **AtomicChat's uncensoring costs 0.006**, against OpenUncensored's 0.02,
  and leaves perplexity at 7.263 against the release's 7.261. Its adapter
  ([`AtomicChat/Inkling-2-Mini-Uncensored-GGUF`](https://huggingface.co/AtomicChat/Inkling-2-Mini-Uncensored-GGUF),
  `Inkling-2-Mini-Uncensored-LoRA.gguf`) is rank 1 at 49 sites: each layer's
  attention output, its 128 expert down projections and the embedding. At
  each, lora_b is a unit direction r and lora_a is exactly -W^T r (correlation
  1.0000 against the release), so it is the projection W' = (I - r r^T) W.
  `scripts/merge-uncensoring.py` applies that to the weights: the attention
  output and embedding from the release's BF16, quantized 8-bit once, and the
  expert banks decoded, projected and encoded again in their own NVFP4 or
  MXFP8. Encoding an unedited bank that way returns the release's bytes
  exactly, so the merge changes nothing else. GGUF is only read for the
  directions; the server reads MLX weights.
- **It removes refusals.** Of 12 borderline asks (a roast, lock picking, a
  phishing sample, hotwiring in a story, tracking a teen's phone and the
  like), the stock 8-bit pack declined 9; the merged pack and the previous
  pack declined none.
- **The install builds it exactly.** Upstream's converter at `--bits 8`
  reproduces `ddalcu/Inkling-2-Mini-MLX-8bit` byte for byte, and the merge
  gives the same bytes on every run and on the converter's pinned mlx 0.32.4,
  so `config/model-pack.sha256` pins the result.

**Kept:** the stock 8-bit pack with AtomicChat's uncensoring and 8-bit KV,
5 times closer to the release than the previous pack, for 8% of decode at
short prompts and 14% at 71K ([Measurements](#measurements)). The release
itself decodes at 18 tok/s here: its BF16 attention has no fast M1 path.

## Settings

Everything is mlx-serve's default except the LaunchAgent, ten flags, two MLX
variables ([Command buffers](#command-buffers)) and one generation rule
(README, "How it works").

- `--model ~/.mlx-serve/models/local/Inkling-2-Mini-Uncensored-8bit`, the
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
- `--prefix-cache-mem 16GB`. The default left 0 to 2.3 GB, too little for one
  long conversation. 16 GB keeps two long conversations (129K and 111K) and a
  242K one cached in 8-bit KV. At 24 GB mlx-serve granted 18.5-20 GB, and a
  cold 242K prompt behind two cached long ones ran out of GPU memory in
  prefill: its admission check saw 11.2 GB free for a 10.6 GB need.
- `--prefill-chunk 4096`. Without it, mlx-serve shrinks the chunk to pay for a
  larger cache, down to 512 tokens. 4,096 reads as fast as 8,192, and keeps a
  242K follow-up cached where 8,192 missed: with 8,192, the conversation's
  last cache point fell behind the sliding window.
- `--kv-quant 8`. The KV cache in 8 bits, read by the patch's fused attention
  ([Context depth](#context-depth)).
- `--log-file off`. launchd already writes mlx-serve's output to
  `~/Library/Logs/llm-server/mlx-serve.log`.
- No generation rules: a request that names no effort thinks at the
  template's `high` ([Reasoning effort](#reasoning-effort)).

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
and 22% at 129K. Prompt reading is unchanged, and peak wired memory falls by
11.6 GB (39.6 to 28.0). That run, before the patch's later kernels, put 8-bit
KV slower than 4-bit everywhere: 44.6 tok/s short, 24.4 at 129K.

Scored against the release, though, 4-bit KV is the largest single cost: 0.02
KLD, where 8-bit costs 0.001 ([The pack](#the-pack)). On the final engine,
the previous pack with 8-bit KV against 4-bit decoded 4% slower short and
7-9% slower at 36K and 71K. **Kept: 8-bit**, for the pack closest to the
release.

### Tried and rejected

| Change | Result |
|---|---|
| `--kv-quant 4` | 4% faster short and 9% at 71K, but 0.02 KLD from the release where 8-bit costs 0.001 (above) |
| Prefill chunk 8192 against 4096 | Equal reading speed; a 242K follow-up missed the cache |
| Prefill chunk 2048 | 8-10% slower reading at 3K and 12K, and a 38K follow-up missed |
| Prefix cache 8 GB, 4-bit KV | A 242K conversation did not fit, so its follow-up read cold for 20 min |
| Prefix cache 24 GB, 8-bit KV | A cold 242K prompt behind two cached long conversations ran out of GPU memory |
| `--ssm-checkpoint-max 0` | No change |
| `--max-concurrent 2` | Inside the controls |
| `--prefix-cache-disk 40GB` | Follow-ups of two long conversations both read cold, where the RAM cache alone serves one |
| `INKLING_NO_DRAFT=1`, the update's drafting off | 4% faster on short sampled prompts, half the speed on whole-file edits (above); with the final command buffers 2% faster on short prompts and a third slower on edits |
| `MLX_MAX_OPS_PER_BUFFER` 25 or 1,000 | 25 slower than the default; 1,000 slowed prompt reading by 8% |
| `prep` reading the joined projections in place at 2+ rows, without MLX's copies | Inside the controls |
| The router's top 8 picked inside the expert kernel, one launch fewer a visit | Same output, 4-10% slower: every threadgroup ranks before it reads |
| A one-row cached-KV read without 8x8 matrix tiles | About 100 us a launch against 18-58: 20-25% slower decode |
| The drafter at 4 bits, or at most 4 or 5 drafts | Inside the controls |
| No draft the round after one that chose none | Inside the controls; it seldom took effect |
| megakernel-zoo's Inkling 2 Mini engine for the M5 Max | Does not start on an M1: kernels of 576 threads a group, where the M1 allows 448 |

The chunk, cache, checkpoint, concurrency and disk rows ran earlier the same
day on the stock release with the 8-bit pack and full KV. What decided them,
the cache's size against a conversation's and the sliding window against the
chunk, does not depend on the engine or the pack.

## Reasoning effort

Inkling's chat template maps an effort word to a level, `none` 0.0,
`minimal` 0.1, `low` 0.2, `medium` 0.7, `high` 0.9, and `xhigh` and `max`
0.99, and uses 0.9 when a request names none *(sourced: the pack's
`chat_template.jinja`)*. mlx-serve passes each word through *(source:
`src/host/chat/effort.zig`)*, and OpenCode sends its variant's word
unchanged *(measured: OpenCode 2.4.1, all seven)*. At `none` the model still
reasons briefly: 204 characters on a one-line puzzle, against 271 at `high`
*(measured)*. OpenCode names no effort unless you pick a variant, so every
turn would think at `high`.

`~/.mlx-serve/generation-settings.json` holds rules for request fields. A
rule fills a field the request leaves out; `"ignore_client": true` would make
it replace the request's value. mlx-serve reads the file again when it
changes *(sourced: `docs/reference.md`, "Generation defaults")*. It refuses
the whole file over one bad field or value *(source:
`src/host/api/generation_settings.zig`)*.

This repo sets no such rule, so a request that names no effort thinks at
`high`, the default Thinking Machines ship. An earlier version installed
`{"reasoning_effort": {"value": "medium"}}` to save time: on five prompts, a
full answer took 68 s at `medium` and 106 s at `high`, on the stock release
before tuning. It was dropped to keep the model as its authors run it.
Reasoning longer is also more accurate here: the `verify.sh` edit below came
back exact 18 of 20 times at `medium` against 22 of 32 at `none`.
`3-services.sh` removes the old rule.

## Measurements

The final setup (both patches, the merged 8-bit pack, 8-bit KV, the DFlash 2
drafter, the flags and MLX variables above, a panel between two of the
previous setup and the gates on 2026-11-27), against the stock release that
started 2026-11-23, mlx-serve 26.11.4-pre-release.1 with the 8-bit stock pack
and the same window, cache and chunk. The previous setup (OpenUncensored,
4-bit attention, 4-bit KV) is in the last column, from the same window:

| Metric | Stock release | Final | Previous |
|---|---|---|---|
| Decode, greedy, short prompts | 43.8 tok/s | 52.7 tok/s | 56.5-58.2 |
| Decode, sampled as OpenCode asks, short prompts | not measured | 51.1 tok/s | 57.1-58.4 |
| Whole-file edits, greedy, 1-4K | not measured | 286 chars/s | 292-294 |
| Thinking at `medium`, sampled | not measured | 55.2 tok/s | 60.5-62.2 |
| Decode at 36K / 71K tokens | not measured | 40.5 / 34.9 tok/s | 45.6-47.1 / 40.6-41.2 |
| Two / four requests at once, together | 42.7 tok/s / not measured | 45.4 / 62.8 tok/s | 48.0-48.2 / 68.1-68.3 |
| Prompt reading at 10K / 30K tokens | not measured / 362-371 tok/s | 419 / 379 tok/s | 420-421 / 380 |
| Cold read, 128.7K / 241.7K tokens | 8.0 / 20.1 min | 8.2 / 20.6 min | 7.7 / 19.4 |
| First token of a follow-up at 2.9K / 10K / 30K | 0.81 / 0.87 / 1.07 s | 0.47 / 0.52 / 0.63 s | 0.45-0.46 / 0.49-0.50 / 0.62 |
| OpenCode-shaped follow-ups at 3K / 12K / 39K | 0.6 / 0.7 / 1.0-1.6 s | 0.49 / 0.54 / 0.67 s | 0.48 / 0.53 / 0.65 |
| Reasoning split from the answer when streaming without tools | no (#1292) | yes | yes |
| Two long conversations (129K, 111K), follow-up on each | the first cached, the second read cold | both cached, first token in 1.1-1.5 s | both cached |
| Follow-up at 242K tokens | cached, first token 3.3 s | cached, full answer in 30 s | cached, 7.8-22.8 s |
| Graded follow-ups | 16 of 16 | 16 of 16 | 16 of 16 |
| Three codes in a 129K / 242K-token prompt | 3 of 3 / 3 of 3 | 3 of 3 / 3 of 3 | 3 of 3 / 3 of 3 |
| Refusals, 12 borderline asks | 9 (stock 8-bit pack) | 0 | 0 |
| Mean KLD from the release, top-1 | 0.0052, 96.5% (with 8-bit KV) | 0.0110, 94.7% | 0.0548, 88.5% |
| Start to ready, pack in the page cache | 2-4 s | 4.3 s | 4.3 s |
| Peak wired memory, panel | 37-39 GB | 37.6 GB | 30.1-30.6 GB |

The first token of a short prompt varied from 295 to 500 ms between runs of
the same setup, so it is not compared. A follow-up's full answer at 242K takes as long as its reasoning runs, at
about 20 tokens a second. Decode at 129K and 242K was not measured on the
final setup.

One edit, a rename in `verify.sh`, sometimes comes back wrong. The model
writes the whole file but puts a backslash before each double quote of an awk
program inside `$(...)`, so awk cannot parse the line. The other two edits
always came back exact. The model makes this mistake on every pack and build
tried, 16 tries each, sampled at effort `none`:

| Setup | Exact |
|---|---|
| This setup, two runs | 9 and 13 of 16 |
| This setup, drafting off | 12 of 16 |
| Uncensored, 8-bit | 9 of 16 |
| Stock, 8-bit, the pack mlx-serve publishes | 11 of 16 |

Every miss was the same backslash, and the spread between setups is within
that between two runs of this one. Neither the drafter, the 4-bit attention
nor the uncensored weights cause it. It comes with shorter reasoning: tries
that reasoned past 3,000 characters were exact 11 of 13 times, shorter ones
43 of 67. At effort `medium` this setup was exact 18 of 20 times. Greedy runs split the same way,
because the GPU's sums are not bit-identical from run to run and the first
few tokens of reasoning decide which way it goes.

### How close to the limit

A plain decode step of the final pack reads about 4.0 GB: 1.84 GB of the 8
routed experts in each of 48 layer visits, 1.69 GB of 8-bit attention and
gates over the same visits, and the 0.50 GB 8-bit head *(counted from the
pack's tensors)*. The GPU reads 342 GB/s here, so one token a step cannot
beat 85 tok/s; the final setup decodes 52.7, 62% of that, with drafting. The
previous pack, with 4-bit attention and a 6-bit head, read 3.26 GB a step,
a 105 tok/s ceiling; with drafting off its step took 17.2 ms, 58 tok/s. The
analysis below was measured on that pack.

- **The experts** run near 280 GB/s, 82% of the limit. A Metal System Trace
  with GPU counters shows read bandwidth at its peak during them and a mean of
  48% over the step.
- **The small kernels** between them cost about 3 us each to launch, measured
  in a chain of 1,600: about 1-2 ms of a step. Removing two of them a visit
  gained nothing (Tried and rejected).
- **The rest** is medium projections that read below bandwidth: a 2,048-row
  4-bit projection reads at 137 GB/s, the 6,552-row joined one at 246.
- **Drafting** pays less here than on a dense model. Each row a verify adds
  costs 6.5-8 ms, about what the experts it brings take to read at the expert
  kernels' speed: rows route to different experts.
- **Deep in a conversation** the one-row cache read is limited by arithmetic,
  not bandwidth: at 36K tokens a step takes 4 ms more than the 1 ms its KV
  bytes need.

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

## References

- mlx-serve: https://github.com/ddalcu/mlx-serve, 26.11.4-pre-release.1:
  https://github.com/ddalcu/mlx-serve/releases/tag/v26.11.4-pre-release.1,
  its docs and code at the tag: https://github.com/ddalcu/mlx-serve/tree/v26.11.4-pre-release.1
- The patch's source: https://github.com/namp/mlx-serve-inkling2-m1
- The model: https://huggingface.co/thinkingmachines/Inkling-2-Mini
- The uncensoring adapter: https://huggingface.co/AtomicChat/Inkling-2-Mini-Uncensored-GGUF
- The previous pack's source: https://huggingface.co/OpenUncensored/Inkling-2-Mini-Uncensored
- mlx-lm's draft support for Inkling 2: https://github.com/ml-explore/mlx-lm/pull/2086
- Upstream issue #1292 (reasoning in `content` when streaming without tools)
  and #1308 (decode collapse on long generations on an M1 Max):
  https://github.com/ddalcu/mlx-serve/issues
