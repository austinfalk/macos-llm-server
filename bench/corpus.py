#!/usr/bin/env python3
"""Rebuild the frozen texts the harness reads, byte for byte, from pinned git revisions, into bench/out/corpus/.

- gate.txt: this repo's own files at GATE_COMMIT, joined, repeated to 1.5 MB. The prompts for prefill, follow-ups,
  depth and the needles are cut from it.
- kld/: the eight files upstream's tests/inkling2_kld.py reads, from mlx-serve at UPSTREAM_COMMIT with this repo's
  two patches as of PATCH_COMMIT applied. inkling2_kld.py refuses a corpus that changed between two runs, so the
  texts stay pinned while the repo moves on.
   python3 bench/corpus.py
"""
import shutil
import subprocess
import tempfile
from pathlib import Path

HERE = Path(__file__).resolve().parent
REPO = HERE.parent
SRC = Path("~/.mlx-serve/builds/src").expanduser()  # MLX_SERVE_SRC in scripts/lib.sh
OUT = HERE / "out" / "corpus"

GATE_COMMIT = "754d87d"
GATE_FILES = ["README.md", "docs/findings.md", "docs/clients.md", "scripts/1-install.sh", "scripts/2-tailscale.sh",
              "scripts/3-services.sh", "scripts/4-harden.sh", "scripts/check-public.sh", "scripts/lib.sh",
              "scripts/test-variant.sh", "scripts/uninstall.sh", "scripts/variant.sh", "scripts/verify.sh"]
UPSTREAM_COMMIT = "2fe9be8"
PATCH_COMMIT = "7f56c5d"
KLD_FILES = ["docs/reference.md", "src/plugins/inkling2/kernels.zig", "CHANGELOG.md", "tests/convert_inkling2.py",
             "app/CLAUDE.md", "README.md", "src/host/chat/AGENTS.md", "docs/recipes/add-a-model.md"]


def git(repo, *args, **kw):
    return subprocess.run(["git", "-C", str(repo), *args], check=True, capture_output=True, **kw).stdout


def main():
    OUT.mkdir(parents=True, exist_ok=True)
    block = "\n\n".join(f"=== {f} ===\n" + git(REPO, "show", f"{GATE_COMMIT}:{f}", text=True) for f in GATE_FILES)
    (OUT / "gate.txt").write_text("\n\n".join([block] * 16))

    with tempfile.TemporaryDirectory() as tmp:
        t = Path(tmp)
        tar = git(SRC, "archive", UPSTREAM_COMMIT)
        subprocess.run(["tar", "-x", "-C", tmp], input=tar, check=True)
        for p in ("inkling2-m1.patch", "inkling2-m1-speed.patch"):
            diff = git(REPO, "show", f"{PATCH_COMMIT}:patches/{p}")
            subprocess.run(["patch", "-s", "-p1", "-d", tmp], input=diff, check=True, stdout=subprocess.DEVNULL)
        kld = OUT / "kld"
        shutil.rmtree(kld, ignore_errors=True)
        for f in KLD_FILES:
            (kld / f).parent.mkdir(parents=True, exist_ok=True)
            shutil.copyfile(t / f, kld / f)
    print(f"corpus in {OUT.relative_to(REPO)}")


if __name__ == "__main__":
    main()
