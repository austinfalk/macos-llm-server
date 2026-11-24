# Findings

The reasons behind each choice in the [guide](../README.md), and the
measurements behind them. The server is a MacBook Pro 16" (M1 Max, 32-core
GPU, 64 GB) on macOS 27.x. Items marked *(sourced)* come from the linked
references and were not reproduced here. Items marked *(source)* were read
from mlx-serve's code at the pinned tag, not measured. Everything else was
measured on 2026-11-23 with the Mac to itself: no other model server, no
download or build running, on AC power.

The setup has three parts, each chosen by measurement:

| Part | Choice | Against |
|---|---|---|
| Engine | Upstream mlx-serve 26.11.4-pre-release.1, built from source, with namp's M1/M2 patch | The same build without the patch |
| Model | OpenUncensored's Inkling 2 Mini Uncensored, converted by upstream's converter: attention 4-bit, embedding and head 6-bit, experts as released | The 8-bit pack of the stock model, and namp's 4-bit requant |
| Flags | A 262,144-token window, a 24 GB prefix cache, 4,096-token prefill chunks, 4-bit KV cache | mlx-serve's defaults, and 8-bit or full KV |

## How it was measured

- **The panel.** Six greedy decode prompts with thinking off (median of
  six), three sampled prompts at the server's default effort, two requests
  at once, prompt reading at 0.8K, 2.9K, 10K and 30K tokens, the first token
  of a short prompt and of follow-ups at 2.9K, 10K and 30K tokens, and peak
  wired memory. Times are the client's: decode is tokens after the first over
  the time after it.
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
fork changes 17 files under `src/` and nothing in the build. This repo carries
that change as `patches/inkling2-m1.patch` (namp's `83865a4..e18e2ed`, `src/`
only) and applies it to upstream's source, so the fork can be dropped once
upstream ships the same, and nothing else of the fork is needed. What the
patch does *(sourced: namp's README)*:

- FP16 instead of bf16 on M1 and M2, which have no bf16 arithmetic.
- Attention fused with a 4- or 8-bit KV cache, read in one kernel.
- Barrier-free expert down and up projections, and FP16 gates.
- Inkling's reasoning sent as `reasoning_content` in a streamed reply without
  tools. Upstream sends it in `content` (upstream issue #1292), so a client
  that sends the answer back sends the reasoning too, and misses the cache.
- An opt-in draft for M1 and M2 (`INKLING_FORCE_DRAFT=1`), off by default.

Both builds were made the same way, by upstream's release recipe at the tag:
Zig 0.17.0, MLX and mlx-c from the tag's submodules, libllama b12110, `zig
build -Doptimize=ReleaseFast -Dstrip`, laid out and signed ad hoc as the
release workflow does. A clean build took 8 minutes, the patched rebuild 3.

On the stock 8-bit pack, two runs of each, alternating:

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

## The pack

OpenUncensored's
[Inkling-2-Mini-Uncensored](https://huggingface.co/OpenUncensored/Inkling-2-Mini-Uncensored)
is the release with refusals ablated. It ships in the release's own format,
and only its 20 attention output projections differ from the release; the
draft head is byte-identical to the stock pack's. mlx-serve reads MLX packs,
so `1-install.sh` converts it with upstream's own
`tests/convert_inkling2.py`, which keeps the routed experts' bytes (NVFP4 and
MXFP8) and quantizes the rest.

Five packs, each scored against its own release, all on the patched engine
with the base flags:

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
  agreement. Prompt reading and follow-ups are unchanged. It also frees 1.5
  GB, which mlx-serve gives to the prefix cache.
- **Upstream's converter matches namp's requant.** Converted from the release
  in one step, it scores the same as namp's two steps (release to 8-bit to
  4-bit) and decodes as fast, so the install needs nothing of namp's but the
  engine patch. Its pack is 17.5 GB, and converting it took 7 s.

**Kept:** the last row. The four lossy packs differ from their release by
about the same amount, so the choice is speed and the uncensored model.

## Settings

Everything is mlx-serve's default except the LaunchAgent, ten flags and one
generation rule (README, "How it works").

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

### Context depth

The KV cache grows with the conversation, and decode reads all of it for every
token, so decode slows as a conversation gets longer. In 4 bits it reads a
quarter of the bytes, through the patch's fused kernel. Decode of the final
pack, KV in full against 4 bits, with full KV run before and after:

| Prompt | Full KV | 4-bit KV |
|---|---|---|
| 2K tokens (the panel) | 48.0 tok/s | 45.0 tok/s |
| 8K | 45.6 | 45.9 |
| 36K | 37.2 | 41.1 |
| 71K | 30.6 | 36.0 |
| 129K (the 8-bit pack) | 22.8 | 27.9 |

4-bit KV loses 6% on short prompts and wins from 8K tokens up, by 18% at 71K
and 22% at 129K. An agent's first prompt is already 8-20K tokens. Prompt
reading is unchanged, peak wired memory falls by 11.6 GB, and mlx-serve's
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
| The patch's M1 draft, `INKLING_FORCE_DRAFT=1` | Decode 50.5 against 51.3-51.6 tok/s, and 1 GB more memory: verifying drafted rows costs more than it saves on an M1, as namp found too |

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

The final setup (patched engine, the converted uncensored pack, the flags
above), against the stock release that started the day, mlx-serve
26.11.4-pre-release.1 with the 8-bit stock pack and the same window, cache
and chunk:

| Metric | Stock release | Final |
|---|---|---|
| Decode, greedy, short prompts | 43.8 tok/s | 47.9 tok/s |
| Decode at 36K / 71K tokens | not measured | 41.1 / 36.0 tok/s |
| Decode at 129K / 242K tokens | 22.1 / 16 tok/s | 27.9 (8-bit pack) / 21.7 tok/s |
| Two requests at once, together | 42.7 tok/s | 45.2 tok/s |
| Prompt reading at 10K / 30K tokens | not measured / 362-371 tok/s | 427 / 383 tok/s |
| Cold read, 128.7K / 241.7K tokens | 8.0 / 20.1 min | 7.8 / 20.4 min |
| First token of a follow-up at 2.9K / 10K / 30K | 0.81 / 0.87 / 1.07 s | 0.49 / 0.53 / 0.64 s |
| OpenCode-shaped follow-ups at 3K / 12K / 39K | 0.6 / 0.7 / 1.0-1.6 s | 0.55 / 0.6 / 0.72-1.52 s |
| Reasoning split from the answer when streaming without tools | no (#1292) | yes |
| Two long conversations (129K, 111K), follow-up on each | the first cached, the second read cold | both cached, first token in 1.1 s |
| Follow-up at 242K tokens | cached, first token 3.3 s | cached, full 205-token answer in 11.9 s |
| Graded follow-ups | 16 of 16 | 16 of 16 |
| Three codes in a 129K / 242K-token prompt | 3 of 3 / 3 of 3 | 3 of 3 (8-bit pack) / 3 of 3 |
| Start to ready, pack in the page cache | 2-4 s | 3.8 s |
| Peak wired memory, panel | 37-39 GB | 28 GB |

The first token of a short prompt varied from 295 to 500 ms between runs of
the same setup, so it is not compared.

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
