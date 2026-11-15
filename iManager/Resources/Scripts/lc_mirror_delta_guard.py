#!/usr/bin/env python3
"""镜像改动守卫: 只允许 MIRROR-DELTAS.md 登记过的文件与上游 manifest 不同.

为什么需要 (owner 2026-11-11):
    「我们是同步上游的，上游一般比较稳定的，我们不要乱改，我们是跟随上游同步源码、
      稳定前提，且不要做太多破坏性变更」
    —— 但有时必须改（如 SearchContext 修搜索栏）。所以需要机器强制:
    每一处镜像改动都必须**显式登记**，未登记就报错。

与 lc_mirror_guard.py 的分工:
    · lc_mirror_guard.py:  镜像 vs manifest，**任何差异都报**（纯净度检查）
    · 本脚本:             镜像 vs manifest，**只允许登记文件差异**（改动管控）

用法:
    python lc_mirror_delta_guard.py [仓库根]
退出码: 0 = 只有登记改动; 1 = 有未登记改动 / 登记文件已与上游一致(应移除登记)
"""

import hashlib
import json
import os
import re
import sys

BASE = os.path.dirname(os.path.dirname(os.path.dirname(os.path.abspath(__file__))))
MIRROR = os.path.join(BASE, "vendor", "LiveContainer")
MANIFEST = os.path.join(MIRROR, ".upstream-manifest.json")
DELTAS = os.path.join(MIRROR, "MIRROR-DELTAS.md")

# 允许存在于镜像目录但不属于上游的文件（与 lc_mirror_guard.py 保持一致）
LOCAL_ONLY = {".upstream-manifest.json", "ADAPTERS.md", "MIRROR-DELTAS.md"}


def sha16(path):
    h = hashlib.sha256()
    with open(path, "rb") as fh:
        for chunk in iter(lambda: fh.read(1 << 20), b""):
            h.update(chunk)
    return h.hexdigest()[:16]


def registered_files():
    """从 MIRROR-DELTAS.md 的表格里抽出所有登记过的镜像相对路径."""
    if not os.path.exists(DELTAS):
        return set()
    with open(DELTAS, "r", encoding="utf-8", errors="replace") as fh:
        text = fh.read()
    # 表格行形如: | M1 | `LiveContainerSwiftUI/Views/...swift` | `:12` ... |
    files = set()
    for line in text.splitlines():
        if not line.startswith("|"):
            continue
        for m in re.finditer(r"`([^`]+\.(?:swift|m|mm|h|c|cpp|hpp))`", line):
            candidate = m.group(1)
            # 跳过「上游行号」列那种 :12 形式与绝对路径
            if candidate.startswith("/") or candidate.startswith(":"):
                continue
            files.add(candidate)
    return files


def main():
    root = sys.argv[1] if len(sys.argv) > 1 else "."
    if not os.path.isdir(MIRROR):
        print("[mirror-delta] 镜像目录不存在: %s" % MIRROR)
        return 2

    with open(MANIFEST, "r", encoding="utf-8") as fh:
        recorded = json.load(fh).get("sha256_prefix", {})

    allowed = registered_files()

    diffs = []
    missing = []
    for rel, expected in recorded.items():
        full = os.path.join(MIRROR, rel)
        if not os.path.exists(full):
            missing.append(rel)
            continue
        if sha16(full) != expected:
            diffs.append(rel)

    problems = 0

    # 1) 有差异但未登记 → 违规
    for rel in sorted(diffs):
        if rel not in allowed:
            print("[mirror-delta] ERROR 未登记的上游改动: %s" % rel)
            print("             请写入 vendor/LiveContainer/MIRROR-DELTAS.md 表格后再提交")
            problems += 1

    # 2) 登记了但实际与上游一致 → 登记过期，应移除
    for rel in sorted(allowed):
        if rel in recorded and rel not in diffs:
            print("[mirror-delta] WARN 登记过期（文件已与上游一致，应移除登记）: %s" % rel)

    # 3) 登记的文件在 manifest 里不存在 → 路径写错
    for rel in sorted(allowed):
        if rel not in recorded:
            print("[mirror-delta] ERROR 登记的路径不在上游清单里: %s" % rel)
            problems += 1

    # 4) 文件缺失
    for rel in sorted(missing):
        print("[mirror-delta] ERROR 镜像缺文件: %s" % rel)
        problems += 1

    print("[mirror-delta] 上游 %d 文件 | 有差异 %d | 已登记 %d | 问题 %d"
          % (len(recorded), len(diffs), len(allowed), problems))
    return 1 if problems else 0


if __name__ == "__main__":
    sys.exit(main())
