"""Merge AtomicChat's uncensoring adapter into an Inkling 2 Mini MLX pack: W' = (I - r r^T) W at the 49 sites it names
(each layer's attention output, each layer's 128 routed expert down projections, the token embedding).

The adapter is a rank-1 LoRA in GGUF whose lora_b at each site is a unit direction r (lora_a = -W^T r, alpha 1), so the
merge reads only the directions and applies the projection to the weights themselves:
- attention output and embedding: the release's BF16 weight, projected in f32, quantized once at the pack's bits for
  that module (affine, group 64, scales in the pack's dtype);
- expert down projections: the pack's own NVFP4 (one global scale an expert) or MXFP8 bank decoded, projected in f32
  and encoded again in the same format. Re-encoding an unedited bank this way returns the release's bytes exactly.
Every other tensor keeps its bytes. Needs only mlx (the converter's environment).
   python -I merge-uncensoring.py PACK DST RELEASE ADAPTER.gguf"""
import json
import shutil
import struct
import sys
from pathlib import Path

import mlx.core as mx

UNIT = 6.0 * 448.0  # an NVFP4 bank's decoded values times global_scale / UNIT are the weights


def gguf_f32(path):
    """The F32 tensors of a GGUF file, by name, each flattened in its file order."""
    b = Path(path).read_bytes()
    assert b[:4] == b"GGUF" and struct.unpack_from("<I", b, 4)[0] == 3, "not a GGUF v3 file"
    n_tensors, n_kv = struct.unpack_from("<QQ", b, 8)
    pos = 24
    scalar = {0: "B", 1: "b", 2: "H", 3: "h", 4: "I", 5: "i", 6: "f", 7: "?", 10: "Q", 11: "q", 12: "d"}

    def string():
        nonlocal pos
        (n,) = struct.unpack_from("<Q", b, pos)
        pos += 8 + n
        return b[pos - n:pos].decode()

    def value(t):
        nonlocal pos
        if t == 8:
            return string()
        if t == 9:
            et, n = struct.unpack_from("<IQ", b, pos)
            pos += 12
            return [value(et) for _ in range(n)]
        (v,) = struct.unpack_from("<" + scalar[t], b, pos)
        pos += struct.calcsize(scalar[t])
        return v

    meta = {}
    for _ in range(n_kv):
        k = string()
        (t,) = struct.unpack_from("<I", b, pos)
        pos += 4
        meta[k] = value(t)
    info = []
    for _ in range(n_tensors):
        name = string()
        (nd,) = struct.unpack_from("<I", b, pos)
        dims = struct.unpack_from(f"<{nd}Q", b, pos + 4)
        dtype, off = struct.unpack_from("<IQ", b, pos + 4 + 8 * nd)
        pos += 4 + 8 * nd + 12
        assert dtype == 0, (name, "not F32")
        info.append((name, dims, off))
    align = meta.get("general.alignment", 32)
    base = (pos + align - 1) // align * align
    out = {}
    for name, dims, off in info:
        n = 1
        for d in dims:
            n *= d
        out[name] = mx.array(memoryview(b)[base + off:base + off + 4 * n].cast("f"))
    return meta, out


def directions(path):
    meta, t = gguf_f32(path)
    assert meta.get("adapter.lora_alpha") == 1.0 and str(meta.get("atomic.abliterate.rank")) == "1", "not a rank-1 ablation"
    out = {"embed": t["token_embd.weight.lora_b"]}
    for L in range(24):
        out[f"o{L}"] = t[f"blk.{L}.attn_output.weight.lora_b"]
        out[f"d{L}"] = t[f"blk.{L}.ffn_down_exps.weight.lora_b"].reshape(128, -1)  # one direction an expert
    for k, r in out.items():
        n = mx.linalg.norm(r, axis=-1)
        assert mx.all(mx.abs(n - 1) < 1e-3).item(), (k, "not a unit direction")
    return out


def ablate(w, r):
    """(I - r r^T) W for W [out, in] (r [out]) or a bank [E, out, in] (r [E, out]), in f32."""
    if w.ndim == 2:
        return w - r[:, None] * (r[None, :] @ w)
    return w - r[:, :, None] * (r[:, None, :] @ w)


def bank(t, r):
    """A down-projection bank, decoded, projected and encoded again in its own format, 16 experts at a time."""
    w, s, g = t["weight"], t["scales"], t.get("global_scale")
    mode, bits, gs = {2: ("nvfp4", 4, 16), 8: ("mxfp8", 8, 32)}[w.shape[-1] // s.shape[-1]]
    ws, ss, gl = [], [], []
    for e in range(0, w.shape[0], 16):
        x = mx.dequantize(w[e:e + 16], s[e:e + 16], group_size=gs, bits=bits, mode=mode).astype(mx.float32)
        ge = None if g is None else g[e:e + 16].astype(mx.float32)
        if ge is not None:
            x = x * (ge / UNIT)[:, None, None]
        x = ablate(x, r[e:e + 16])
        if ge is not None:
            ge = mx.maximum(ge, mx.max(mx.abs(x), axis=(1, 2)))  # an expert holds values up to its global scale
            x = x / (ge / UNIT)[:, None, None]
            gl.append(ge)
        qw, qs = mx.quantize(x.astype(mx.bfloat16), group_size=gs, bits=bits, mode=mode)
        mx.eval(qw, qs, *gl[-1:])
        ws.append(qw); ss.append(qs)
    out = {"weight": mx.concatenate(ws), "scales": mx.concatenate(ss)}
    if g is not None:
        out["global_scale"] = mx.concatenate(gl).astype(g.dtype)
    return out


def main():
    src, dst, rel, ad = (Path(a).expanduser() for a in sys.argv[1:5])
    q = json.loads((src / "config.json").read_text())["quantization"]
    index = json.loads((src / "model.safetensors.index.json").read_text())["weight_map"]
    R = directions(ad)
    relw = mx.load(str(rel / "model-00001-of-00001.safetensors"))
    sites = {"model.language_model.embed_tokens": ("model.llm.embed.weight", R["embed"])}
    for L in range(24):
        sites[f"model.language_model.layers.{L}.self_attn.o_proj"] = (f"model.llm.layers.{L}.attn.wo_ud.weight", R[f"o{L}"])
        sites[f"model.language_model.layers.{L}.mlp.experts.down_proj"] = (None, R[f"d{L}"])

    def tensors(p):
        return {k[len(p) + 1:]: mx.load(str(src / index[k]))[k] for k in index if k.startswith(p + ".")}

    edited = {}  # a module's tensors can span shards: edit it once and write each piece to its own shard

    def edit(p):
        if p not in edited:
            rk, r = sites[p]
            t = tensors(p)
            if rk is None:
                edited[p] = bank(t, r)
            else:
                w = relw[rk].astype(mx.float32)
                w = w - (w @ r)[:, None] * r[None, :] if p.endswith("embed_tokens") else ablate(w, r)
                qq, sdt = q.get(p, q), t["scales"].dtype
                qw, qs, qb = mx.quantize(w.astype(mx.bfloat16), group_size=qq["group_size"], bits=qq["bits"])
                edited[p] = {"weight": qw, "scales": qs.astype(sdt), "biases": qb.astype(sdt)}
        return edited[p]

    dst.mkdir(parents=True, exist_ok=False)
    done = set()
    for shard in sorted(set(index.values())):
        t = mx.load(str(src / shard))
        for p in sites:
            for k in [k for k in t if k.startswith(p + ".")]:
                t[k] = edit(p)[k[len(p) + 1:]]
                done.add(p)
        mx.save_safetensors(str(dst / shard), t, metadata={"format": "mlx"})
        print(shard, flush=True)
    assert len(done) == len(sites) == 49, len(done)
    for f in src.iterdir():
        if f.is_file() and not f.name.startswith("model-"):
            shutil.copy2(f, dst / f.name)
    print("49 sites merged")


if __name__ == "__main__":
    main()
