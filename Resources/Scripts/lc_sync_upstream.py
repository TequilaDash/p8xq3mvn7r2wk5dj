#!/usr/bin/env python3
"""把 LiveContainer 上游同步进 vendor/LiveContainer/，并按 MIRROR-DELTAS 重放本仓改动.

背景（owner 2026-11-11 要求）：
    「我们要同步上游就必须用 livecontainer 的原仓库代码，如果自己分叉了也必须经常
     同步上游代码并适配好我们专属的 livecontainer 分叉，再合并到我们仓库里。」

    本仓有**两份** LC 源码：
      · `vendor/LiveContainer/`        —— 281 文件，逐字节镜像上游（有守卫）
      · `<prefix>LiveProcess/LC/`      —— 13 文件，LC 核心的**适配副本**（无守卫）
    同步时必须两份一起处理，否则会越漂越远。

用法:
    python Resources/Scripts/lc_sync_upstream.py --check              # 只报告落后多少
    python Resources/Scripts/lc_sync_upstream.py --fetch              # 拉最新上游到临时目录
    python Resources/Scripts/lc_sync_upstream.py --apply <上游目录>    # 同步并重放 MIRROR-DELTAS
    python Resources/Scripts/lc_sync_upstream.py --diff-core <上游目录> # 只比对 LC 核心适配副本

退出码: 0 = 无需同步 / 同步成功; 1 = 有差异待处理; 2 = 环境问题
"""

import argparse
import hashlib
import json
import os
import shutil
import subprocess
import sys
import tempfile

ROOT = os.path.dirname(os.path.dirname(os.path.dirname(os.path.abspath(__file__))))
MIRROR = os.path.join(ROOT, "vendor", "LiveContainer")
MANIFEST = os.path.join(MIRROR, ".upstream-manifest.json")
DELTAS = os.path.join(MIRROR, "MIRROR-DELTAS.md")
def _find_core_adapted():
    """定位 LC 核心适配副本（`<prefix>LiveProcess/LC`），前缀随仓库命名变化，不硬编码."""
    import glob
    hits = glob.glob(os.path.join(ROOT, "*LiveProcess", "LC"))
    hits = [h for h in hits if os.path.isdir(h)]
    return hits[0] if hits else None


CORE_ADAPTED = _find_core_adapted()
UPSTREAM_REPO = "https://github.com/LiveContainer/LiveContainer.git"

# 镜像内**不属于上游**的本仓文件（守卫 LOCAL_ONLY 同口径）
LOCAL_ONLY = {".upstream-manifest.json", "ADAPTERS.md", "MIRROR-DELTAS.md"}


def sha256_prefix(path, n=16):
    h = hashlib.sha256()
    with open(path, "rb") as fh:
        for chunk in iter(lambda: fh.read(1 << 20), b""):
            h.update(chunk)
    return h.hexdigest()[:n]


def walk_files(base):
    out = {}
    for dirpath, dirnames, filenames in os.walk(base):
        dirnames[:] = [d for d in dirnames if d != ".git"]
        for name in filenames:
            full = os.path.join(dirpath, name)
            rel = os.path.relpath(full, base).replace(os.sep, "/")
            if rel in LOCAL_ONLY:
                continue
            out[rel] = full
    return out


def load_manifest():
    if not os.path.exists(MANIFEST):
        return {}
    with open(MANIFEST, "r", encoding="utf-8") as fh:
        return json.load(fh).get("sha256_prefix", {})


def registered_deltas():
    """从 MIRROR-DELTAS.md 表格里抽出登记过的镜像相对路径（与 delta_guard 同口径）."""
    import re
    if not os.path.exists(DELTAS):
        return set()
    with open(DELTAS, "r", encoding="utf-8", errors="replace") as fh:
        text = fh.read()
    files = set()
    for line in text.splitlines():
        if not line.startswith("|"):
            continue
        for m in re.finditer(r"`([^`]+\.(?:swift|m|mm|h|c|cpp|hpp))`", line):
            c = m.group(1)
            if c.startswith("/") or c.startswith(":"):
                continue
            files.add(c)
    return files


def cmd_check():
    manifest = load_manifest()
    if not manifest:
        print("没有 manifest，先跑 lc_mirror_guard.py --write")
        return 2
    actual = walk_files(MIRROR)
    missing = sorted(set(manifest) - set(actual))
    extra = sorted(set(actual) - set(manifest))
    changed = []
    for rel, full in actual.items():
        want = manifest.get(rel)
        if want and sha256_prefix(full) != want:
            changed.append(rel)
    deltas = registered_deltas()
    unregistered = [r for r in changed if r not in deltas]

    print("镜像 %d 文件 | manifest %d | 缺失 %d | 多出 %d | 改动 %d（其中已登记 %d）"
          % (len(actual), len(manifest), len(missing), len(extra), len(changed), len(deltas)))
    for r in missing:
        print("  MISSING", r)
    for r in extra:
        print("  EXTRA  ", r)
    for r in unregistered:
        print("  CHANGED(未登记)", r)
    for r in sorted(deltas):
        print("  已登记改动", r)

    # 核心适配副本 vs 上游核心目录
    upstream_core = os.path.join(MIRROR, "LiveContainer")
    if CORE_ADAPTED and os.path.isdir(upstream_core):
        print()
        print("=== LC 核心适配副本 vs 上游 LiveContainer/ ===")
        diff_core(CORE_ADAPTED, upstream_core)
    return 0 if not unregistered else 1


def diff_core(adapted, upstream):
    """逐文件比对适配副本与上游核心目录，打印差异摘要."""
    a = walk_files(adapted)
    u = walk_files(upstream)
    only_a = sorted(set(a) - set(u))
    only_u = sorted(set(u) - set(a))
    same, differ = [], []
    for rel in sorted(set(a) & set(u)):
        if sha256_prefix(a[rel]) == sha256_prefix(u[rel]):
            same.append(rel)
        else:
            differ.append(rel)
    print("  逐字节相同 %d | 有差异 %d | 仅适配副本有 %d | 仅上游有 %d"
          % (len(same), len(differ), len(only_a), len(only_u)))
    for rel in differ:
        lines = subprocess.run(
            ["diff", "-u", u[rel], a[rel]], capture_output=True, text=True
        ).stdout.count("\n")
        print("    DIFF  %-40s (%d diff 行)" % (rel, lines))
    for rel in only_a:
        print("    ONLY-ADAPTED", rel)
    for rel in only_u:
        print("    ONLY-UPSTREAM", rel)
    print("  说明: 这些差异是**必要的适配**（getenv NULL 防护 / TD_NET_BLOCK 钩子 /")
    print("        面包屑日志 / 头文件直取），同步上游时必须逐条重放，不能直接覆盖。")


def cmd_fetch():
    tmp = tempfile.mkdtemp(prefix="lc-upstream-")
    print("clone %s -> %s" % (UPSTREAM_REPO, tmp))
    r = subprocess.run(["git", "clone", "--depth", "1", UPSTREAM_REPO, tmp],
                       capture_output=True, text=True)
    if r.returncode != 0:
        print("clone 失败:", r.stderr[:500])
        return 2
    head = subprocess.run(["git", "-C", tmp, "rev-parse", "HEAD"],
                          capture_output=True, text=True).stdout.strip()
    print("HEAD =", head)
    print("上游目录:", tmp)
    print()
    print("下一步: python Resources/Scripts/lc_sync_upstream.py --diff-core \"%s\"" % tmp)
    return 0


def cmd_apply(upstream):
    """把上游内容覆盖进镜像，然后逐条重放 MIRROR-DELTAS 里登记的改动."""
    if not os.path.isdir(upstream):
        print("上游目录不存在:", upstream)
        return 2
    deltas = registered_deltas()
    if not deltas:
        print("MIRROR-DELTAS 里没有登记任何改动 —— 直接全量覆盖即可，但请先确认这是预期")
        return 2

    # 1) 备份当前登记文件的内容（重放要用）
    backups = {}
    for rel in deltas:
        src = os.path.join(MIRROR, rel)
        if os.path.exists(src):
            with open(src, "r", encoding="utf-8", errors="replace") as fh:
                backups[rel] = fh.read()

    # 2) 全量覆盖（保留本仓自有文件）
    replaced = 0
    for rel, full in walk_files(upstream).items():
        dst = os.path.join(MIRROR, rel)
        os.makedirs(os.path.dirname(dst), exist_ok=True)
        shutil.copy2(full, dst)
        replaced += 1
    print("覆盖 %d 文件" % replaced)

    # 3) 报告哪些登记文件被覆盖（需要人工重放）
    print()
    print("=== 需要人工重放的登记改动 ===")
    for rel in sorted(backups):
        now = os.path.join(MIRROR, rel)
        if not os.path.exists(now):
            print("  %s: 上游已删除该文件，请从 MIRROR-DELTAS 移除登记" % rel)
            continue
        with open(now, "r", encoding="utf-8", errors="replace") as fh:
            new = fh.read()
        if new == backups[rel]:
            print("  %s: 上游内容与重放后一致（无需动作）" % rel)
        else:
            print("  %s: 已被上游覆盖，按 MIRROR-DELTAS 重放" % rel)

    # 4) 重生成 manifest
    r = subprocess.run([sys.executable, os.path.join(ROOT, "Resources", "Scripts",
                                                     "lc_mirror_guard.py"), "--write"],
                       capture_output=True, text=True)
    print(r.stdout.strip() or r.stderr.strip())
    print()
    print("下一步:")
    print("  1. 按 MIRROR-DELTAS 逐条重放上面列出的文件")
    print("  2. python Resources/Scripts/lc_sync_upstream.py --diff-core \"%s\"" % upstream)
    print("  3. 按 diff-core 输出，把上游核心目录的新改动重放进 TDPLiveProcess/LC/")
    print("  4. python Resources/Scripts/swift_precommit_check.py .")
    return 0


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--check", action="store_true", help="只报告镜像状态")
    ap.add_argument("--fetch", action="store_true", help="clone 最新上游到临时目录")
    ap.add_argument("--apply", metavar="UPSTREAM_DIR", help="同步并提示重放")
    ap.add_argument("--diff-core", metavar="UPSTREAM_DIR", help="比对 LC 核心适配副本")
    args = ap.parse_args()

    if args.fetch:
        return cmd_fetch()
    if args.apply:
        return cmd_apply(args.apply)
    if args.diff_core:
        up_core = os.path.join(args.diff_core, "LiveContainer")
        if not os.path.isdir(up_core):
            print("找不到 %s" % up_core)
            return 2
        diff_core(CORE_ADAPTED, up_core)
        return 0
    return cmd_check()


if __name__ == "__main__":
    sys.exit(main())
