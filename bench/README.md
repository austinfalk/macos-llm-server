# Measuring a change

The harness behind every number in `docs/findings.md`. It measures a
candidate the way `AGENTS.md` ("Measuring") asks: production stopped, one GPU
job at a time, the candidate between two runs of the current setup, scored
against Thinking Machines' release, and passed through the gates before it
ships.

## What to watch

Check these by hand now and then. Compare each with its pin in
`scripts/pins.sh`, and send anything new down the path at the end of this
file:

| Source | Pinned as | What would be a candidate |
|---|---|---|
| [thinkingmachines/Inkling-2-Mini](https://huggingface.co/thinkingmachines/Inkling-2-Mini) | `LLM_SOURCE_REVISION` | A new revision: weights, template or config |
| [ddalcu/mlx-serve releases](https://github.com/ddalcu/mlx-serve/releases) | `MLX_SERVE_TAG` | A release: follow "Update mlx-serve" in the README, and drop each part of the patches it now ships |
| [namp/mlx-serve-inkling2-m1](https://github.com/namp/mlx-serve-inkling2-m1) | `patches/inkling2-m1.patch` | New M1/M2 kernel work |
| [incoai/Inkling-2-Mini-DFlash2](https://huggingface.co/incoai/Inkling-2-Mini-DFlash2), and Inco's other drafters | `LLM_DRAFT_REVISION` | A better draft model |
| [AtomicChat/Inkling-2-Mini-Uncensored-GGUF](https://huggingface.co/AtomicChat/Inkling-2-Mini-Uncensored-GGUF) | `LLM_ADAPTER_REVISION` | A new `Inkling-2-Mini-Uncensored-LoRA.gguf`. A commit that touches only the README is not one |
| [paperniuk/splash](https://github.com/paperniuk/splash), [incoai/splash](https://github.com/incoai/splash) | none | A release worth benchmarking against mlx-serve: another engine |

Thinking Machines ships no MLX pack of its own. Any MLX pack of Inkling 2
Mini is a conversion of the release, so build it here from the release and
compare.

Each source's latest revision, to compare with the pins:

```sh
. scripts/pins.sh
for r in thinkingmachines/Inkling-2-Mini incoai/Inkling-2-Mini-DFlash2 AtomicChat/Inkling-2-Mini-Uncensored-GGUF; do
	curl -s "https://huggingface.co/api/models/$r" | jq -r '"\(.id) \(.sha) \(.lastModified)"'
done
gh release list -R ddalcu/mlx-serve -L 3
gh api repos/namp/mlx-serve-inkling2-m1/commits --jq '.[:3][] | "\(.sha[:8]) \(.commit.committer.date) \(.commit.message | split("\n")[0])"'
for r in paperniuk/splash incoai/splash; do gh release list -R "$r" -L 2; done
```

For AtomicChat, a new commit counts only if the LoRA file's checksum
changed: compare `config/adapter-source.sha256` with the `lfs.oid` that
`https://huggingface.co/api/models/AtomicChat/Inkling-2-Mini-Uncensored-GGUF/tree/main`
lists for the file.

## Starting a session

A short prompt is enough, because the rules live in the repo:

> Read AGENTS.md, NEXT.md and bench/README.md. Check each source in "What
> to watch" against its pin, and test what is new, along with any
> improvement of our own you can find toward the goal, down "The path a
> candidate takes". Start from docs/findings.md: "How close to the limit"
> gives the ceiling and where the time goes, and "Tried and rejected" lists
> what not to repeat without a new reason. Open a PR for anything that
> passes.

An improvement of our own is a flag (a config's `set`), a pack (a new
`model`), or a code change: a diff against the patched tree, built with
`sh bench/build.sh NAME change.diff`, then a config with that `bin`. A
change that ships goes into `patches/inkling2-m1-speed.patch`.

## Once per machine

```sh
python3 bench/corpus.py
"$(brew --prefix python@3.12)/bin/python3.12" -m venv ~/.mlx-serve/builds/venv-mlxlm
~/.mlx-serve/builds/venv-mlxlm/bin/pip install -r bench/requirements-mlxlm.txt
```

- `corpus.py` rebuilds the frozen texts in `bench/out/corpus/` from pinned
  git revisions: this repo's own files at one commit for the prompts, and
  upstream mlx-serve's files for the accuracy score. The same texts give the
  same token positions, so numbers stay comparable from one run to the next.
- The mlx-lm environment runs the release in its own NVFP4/MXFP8 weights
  for the reference logprobs, and gives the harness Inkling's tokenizer.

Then, in a window (below), run `kldref` once: the release's logprobs over
the corpus, about 10 minutes. Every pack is scored against them.

## A config

A file in `bench/configs/` names only what a candidate changes from
production. The harness reads the installed LaunchAgent for the rest, so
`configs/control.json` (`{}`) is the current setup:

```json
{"set": {"--kv-quant": "4"}}
```

| Key | Meaning |
|---|---|
| `bin` | another mlx-serve binary, for a patch or release built beside the live one |
| `model` | another pack |
| `set` | flags to add or replace, `{"--flag": "value"}` |
| `drop` | flags to remove |
| `env` | environment variables to add |
| `workloads` | a subset of the speed workloads, by default all of them |

The candidate runs on `127.0.0.1:8001` with production's key. Paths may
start with `~`.

## A window

`window.sh` stops production, runs each step, and starts production again,
even when a step fails. Detached, it survives the terminal closing:

```sh
sh bench/window.sh --detach kv4 configs/control.json configs/kv4.json configs/control.json
tail -f bench/out/logs/window-kv4.log
```

Each step is a config, for a speed run, or one of:

| Step | What it measures | Time |
|---|---|---|
| `CONFIG` | Decode (greedy and sampled, thinking off), whole-file edits, thinking, 2 and 4 at once, prefill at 3K/10K/30K, follow-ups, decode behind 32K and 64K. One line in `out/ledger.jsonl`; `python3 bench/bench.py show` lists them | ~15 min |
| `kld:CONFIG` | KLD and top-1 agreement against the release, short and long passes, with upstream's `tests/inkling2_kld.py` unmodified | ~15 min |
| `gates:CONFIG` | The 16 graded follow-ups, the OpenCode-shaped follow-ups, two long cached sessions, and the needles at 129K and 242K with their follow-ups | ~60 min |
| `longgates:CONFIG` | Only the long sessions and the needles | ~50 min |
| `refuse:CONFIG` | How many of 12 borderline requests the pack declines | ~5 min |
| `kldref` | The release's reference logprobs | ~10 min |

A run refuses to start on battery, and flags itself when a video encoder or
Time Machine was busy, since both skew every number. If a window dies with
production stopped, `sh scripts/3-services.sh` starts it again.

## The path a candidate takes

Stop at the first step it fails:

1. Build or convert it beside the live setup, pinned: a new binary with
   `bench/build.sh` (a new mlx-serve release: "Update mlx-serve" in the
   README), a new pack under `~/.mlx-serve/models/local/`. No build or
   download while a window runs.
2. A new pack: `kld:` first. Keep it only if it is as close to the release
   as the live pack (KLD 0.011 long, top-1 94.7%), or the speed it buys is
   worth the difference.
3. Speed: control, candidate, control, in one window. Keep it only if it
   beats both controls on its metric and loses nothing elsewhere by more
   than about 3%.
4. `gates:` on the candidate, and `refuse:` for a new pack.
5. Record the numbers in `docs/findings.md`, change the pin or flag, and open
   a PR. After the merge, `1-install.sh`, `3-services.sh`, then
   `sudo sh scripts/verify.sh`.

Results, logs and the corpus stay in `bench/out/`, which git ignores.
