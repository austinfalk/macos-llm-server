"""Upstream tests/inkling2_kld.py `collect`, run in-process by mlx-lm (ml-explore/mlx-lm#2086) instead of over HTTP: the same corpus,
cut the same way, and the same JSON (token strings, top-K {token: logprob}, the text token's logprob).
Run by `bench.py kldref`:
   ~/.mlx-serve/builds/venv-mlxlm/bin/python -I bench/mlxlm_collect.py MODEL_DIR OUT [--chars N] [files...]"""
import argparse, json, sys
from pathlib import Path
import mlx.core as mx
from mlx_lm import load

CORPUS = ["docs/reference.md", "src/plugins/inkling2/kernels.zig", "CHANGELOG.md", "tests/convert_inkling2.py",
          "app/CLAUDE.md", "README.md", "src/host/chat/AGENTS.md", "docs/recipes/add-a-model.md"]
ap = argparse.ArgumentParser()
ap.add_argument("model"); ap.add_argument("out")
ap.add_argument("--root", default=str(Path(__file__).resolve().parent / "out" / "corpus" / "kld"))
ap.add_argument("--chars", type=int, default=6000); ap.add_argument("--top", type=int, default=20)
ap.add_argument("--chunk", type=int, default=1024)
ap.add_argument("files", nargs="*")
a = ap.parse_args()
model, tok = load(a.model)
docs = []
for name in a.files or CORPUS:
    text = (Path(a.root) / name).read_text(encoding="utf-8", errors="replace")[: a.chars]
    ids = tok.encode(text, add_special_tokens=False)
    cache = model.make_cache()
    tops, lps = [{}], [None]
    for lo in range(0, len(ids), a.chunk):
        x = mx.array(ids[lo: lo + a.chunk])[None]
        lg = model(x, cache=cache)[0].astype(mx.float32)
        lp = lg - mx.logsumexp(lg, axis=-1, keepdims=True)
        idx = mx.argpartition(-lp, a.top - 1, axis=-1)[:, : a.top]
        val = mx.take_along_axis(lp, idx, axis=-1)
        nxt = mx.array(ids[lo + 1: lo + 1 + x.shape[1]])
        own = mx.take_along_axis(lp[: nxt.shape[0]], nxt[:, None], axis=-1)[:, 0]
        mx.eval(idx, val, own)
        for r, (ii, vv) in enumerate(zip(idx.tolist(), val.tolist())):
            if lo + r + 1 < len(ids):
                tops.append({tok.decode([i]): v for i, v in zip(ii, vv)})
        lps += own.tolist()
    toks = [tok.decode([i]) for i in ids]
    docs.append({"file": name, "tokens": toks, "top": tops[: len(ids)], "logprob": lps[: len(ids)]})
    print(f"{name}: {len(ids)} positions", flush=True)
Path(a.out).write_text(json.dumps({"top": a.top, "docs": docs}))
