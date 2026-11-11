#!/usr/bin/env python3
"""LiveContainer 镜像完整性守卫.

校验 vendor/LiveContainer/ 是否仍是上游源码的**完整镜像**:
  1. 镜像内每个文件都与 .upstream-manifest.json 记录的 SHA256 前缀一致
     (manifest 之外只允许 ADAPTERS.md 与 manifest 自身).
  2. manifest 声明的上游文件一个不缺.
  3. 可选: 给了 --ref <上游目录> 就逐文件比对真实上游, 报 missing/extra/diff.

用法:
    python Resources/Scripts/lc_mirror_guard.py
    python Resources/Scripts/lc_mirror_guard.py --ref C:/path/to/LiveContainer-main
    python Resources/Scripts/lc_mirror_guard.py --write   # 重新生成 manifest

为什么需要: 镜像一旦被本仓改动(而不是改适配副本), 上游同步就会静默丢改动或冲突.
CI 的 guard job 会跑本脚本 (无 --ref), 保证镜像不被误改.
"""

import argparse
import hashlib
import json
import os
import sys

ROOT = os.path.dirname(os.path.dirname(os.path.dirname(os.path.abspath(__file__))))
MIRROR = os.path.join(ROOT, "vendor", "LiveContainer")
MANIFEST = os.path.join(MIRROR, ".upstream-manifest.json")

# 允许存在于镜像目录但不属于上游的东西.
LOCAL_ONLY = {".upstream-manifest.json", "ADAPTERS.md", "MIRROR-DELTAS.md"}

# 上游 submodule: 参照树里可能为空, 比对时跳过其内部文件.
SUBMODULE_DIRS = {"fishhook", "litehook", "OpenSSL"}


def sha16(path):
    h = hashlib.sha256()
    with open(path, "rb") as fh:
        for chunk in iter(lambda: fh.read(1 << 20), b""):
            h.update(chunk)
    return h.hexdigest()[:16]


def walk(base, skip_submodule_git=True):
    out = {}
    for dirpath, dirnames, filenames in os.walk(base):
        if skip_submodule_git:
            dirnames[:] = [d for d in dirnames if d != ".git"]
        for name in filenames:
            full = os.path.join(dirpath, name)
            rel = os.path.relpath(full, base).replace(os.sep, "/")
            out[rel] = full
    return out


def _registered_delta_files():
    """从 MIRROR-DELTAS.md 抽出登记过的镜像相对路径（与 delta 守卫同口径）."""
    deltas = os.path.join(MIRROR, "MIRROR-DELTAS.md")
    if not os.path.exists(deltas):
        return set()
    import re as _re
    out = set()
    with open(deltas, "r", encoding="utf-8", errors="replace") as fh:
        for line in fh:
            if not line.startswith("|"):
                continue
            for m in _re.finditer(r"`([^`]+\.(?:swift|m|mm|h|c|cpp|hpp))`", line):
                v = m.group(1)
                if v.startswith("/") or v.startswith(":"):
                    continue
                out.add(v)
    return out


def load_manifest():
    with open(MANIFEST, "r", encoding="utf-8") as fh:
        return json.load(fh)


def write_manifest(ref_dir=None):
    """重生成 manifest.

    ref_dir 给了就从**上游参照树**取哈希（记录上游原始值，镜像改动不会污染基线）；
    否则按镜像当前内容算（仅在上游尚未镜像时使用）。
    """
    if ref_dir:
        entries = {}
        for rel, full in walk(ref_dir).items():
            if rel.split("/")[0] in SUBMODULE_DIRS and "/" not in rel:
                continue
            entries[rel] = sha16(full)
        data = {
            "source": "LiveContainer upstream (ref: %s)" % ref_dir.replace("\\", "/"),
            "captured": "2026-11-09",
            "files": len(entries),
            "sha256_prefix": dict(sorted(entries.items())),
        }
        with open(MANIFEST, "w", encoding="utf-8", newline="\n") as fh:
            json.dump(data, fh, ensure_ascii=False, indent=2)
            fh.write("\n")
        print("[lc-mirror] wrote manifest from REF: %d files" % len(entries))
        return 0

    files = walk(MIRROR)
    entries = {}
    for rel, full in files.items():
        if rel in LOCAL_ONLY:
            continue
        entries[rel] = sha16(full)
    data = {
        "source": "LiveContainer upstream (local mirror: C:/Users/xcrad/.omp/work/ref/lc_rev)",
        "captured": "2026-11-09",
        "files": len(entries),
        "sha256_prefix": dict(sorted(entries.items())),
    }
    with open(MANIFEST, "w", encoding="utf-8", newline="\n") as fh:
        json.dump(data, fh, ensure_ascii=False, indent=2)
        fh.write("\n")
    print("[lc-mirror] wrote manifest: %d files" % len(entries))
    return 0


def check_against_manifest():
    data = load_manifest()
    recorded = data.get("sha256_prefix", {})
    problems = 0

    on_disk = walk(MIRROR)
    for rel in sorted(set(on_disk) - set(recorded) - LOCAL_ONLY):
        print("[lc-mirror] EXTRA (not in manifest): %s" % rel)
        problems += 1
    for rel in sorted(set(recorded) - set(on_disk)):
        print("[lc-mirror] MISSING: %s" % rel)
        problems += 1
    # MIRROR-DELTAS.md 登记过的改动由 lc_mirror_delta_guard.py 专项管控,
    # 这里不重复报错（否则两个守卫互相打架: 本脚本要求「零差异」,
    # 而 delta 守卫要求「只允许登记文件有差异」）.
    allowed = _registered_delta_files()
    for rel, expected in sorted(recorded.items()):
        full = on_disk.get(rel)
        if not full:
            continue
        actual = sha16(full)
        if actual != expected:
            if rel in allowed:
                continue
            print("[lc-mirror] MODIFIED: %s (manifest %s, disk %s)" % (rel, expected, actual))
            problems += 1

    print("[lc-mirror] manifest=%d on_disk=%d problems=%d"
          % (len(recorded), len(on_disk), problems))
    return problems


def check_against_ref(ref_dir):
    upstream = walk(ref_dir)
    upstream = {k: v for k, v in upstream.items()
                if k.split("/")[0] not in SUBMODULE_DIRS or "/" in k}
    # 上游 submodule 空目录: 参照树里若有同名文件仍应比对; 只有整目录缺失才跳过.
    for sub in SUBMODULE_DIRS:
        if not os.path.isdir(os.path.join(ref_dir, sub)):
            upstream = {k: v for k, v in upstream.items() if not k.startswith(sub + "/")}

    mirror = walk(MIRROR)
    mirror = {k: v for k, v in mirror.items() if k not in LOCAL_ONLY}

    problems = 0
    for rel in sorted(set(upstream) - set(mirror)):
        print("[lc-mirror] upstream-only: %s" % rel)
        problems += 1
    for rel in sorted(set(mirror) - set(upstream)):
        print("[lc-mirror] mirror-only: %s" % rel)
        problems += 1
    for rel in sorted(set(upstream) & set(mirror)):
        if sha16(upstream[rel]) != sha16(mirror[rel]):
            print("[lc-mirror] differs: %s" % rel)
            problems += 1

    print("[lc-mirror] ref=%d mirror=%d problems=%d"
          % (len(upstream), len(mirror), problems))
    return problems


def main():
    ap = argparse.ArgumentParser()
    # 位置参数 = 仓库根, 由 swift_precommit_check.py 统一传入; 本脚本按自身路径定位镜像,
    # 所以接受但忽略它 (与其它守卫的调用约定保持一致).
    ap.add_argument("root", nargs="?", default=".", help="仓库根 (忽略, 仅为统一调用约定)")
    ap.add_argument("--ref", help="上游参照目录; 给了就逐文件比对")
    ap.add_argument("--write", action="store_true", help="重新生成 manifest")
    args = ap.parse_args()
    if not os.path.isdir(MIRROR):
        print("[lc-mirror] mirror directory not found: %s" % MIRROR)
        return 1

    if args.write:
        return write_manifest(args.ref)

    problems = check_against_manifest()
    if args.ref:
        if not os.path.isdir(args.ref):
            print("[lc-mirror] ref directory not found: %s" % args.ref)
            return 1
        problems += check_against_ref(args.ref)

    if problems:
        print("[lc-mirror] FAIL: %d problem(s). 镜像必须与上游一致; 本仓改动请落到适配副本." % problems)
        return 1
    print("[lc-mirror] OK")
    return 0


if __name__ == "__main__":
    sys.exit(main())
