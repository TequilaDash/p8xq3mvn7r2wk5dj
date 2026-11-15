#!/usr/bin/env python3
"""LC 核心适配副本漂移守卫.

背景（owner 2026-11-11 要求「经常同步上游」）:
    本仓有**两份** LC 源码:
      · `vendor/LiveContainer/`        —— 281 文件，逐字节镜像上游（有 lc_mirror_guard）
      · `<prefix>LiveProcess/LC/`      —— 13 文件，LC 核心的**适配副本**（此前**无任何守卫**）

    适配副本必须与上游不同（getenv NULL 防护 / TD_NET_BLOCK 钩子 / 面包屑日志 /
    头文件直取），但差异必须**登记且可见** —— 否则同步上游时没人知道该重放哪几个文件，
    两份源码会越漂越远。

登记位置: `vendor/LiveContainer/ADAPTERS.md` 的「LC 核心适配副本差异」表。
本脚本比对适配副本与 `vendor/LiveContainer/LiveContainer/`，只允许登记过的文件有差异。

用法:
    python Resources/Scripts/lc_core_drift_guard.py <仓库根>
    python Resources/Scripts/lc_core_drift_guard.py --report   # 只打印差异，不判失败

退出码: 0 = 只有登记差异; 1 = 有未登记差异 / 登记已过期; 2 = 路径问题
"""

import glob
import hashlib
import os
import re
import sys

ROOT = os.path.dirname(os.path.dirname(os.path.dirname(os.path.abspath(__file__))))
UPSTREAM_CORE = os.path.join(ROOT, "vendor", "LiveContainer", "LiveContainer")
ADAPTERS = os.path.join(ROOT, "vendor", "LiveContainer", "ADAPTERS.md")

# 适配副本里**本仓新增**的文件（上游没有），必须登记
# 上游有但适配副本不收的文件（如 Info.plist，由 xcodegen 单独处理）
KNOWN_ONLY_UPSTREAM = {"Info.plist"}


def sha256_prefix(path, n=16):
    h = hashlib.sha256()
    with open(path, "rb") as fh:
        for chunk in iter(lambda: fh.read(1 << 20), b""):
            h.update(chunk)
    return h.hexdigest()[:n]


def walk(base):
    out = {}
    if not os.path.isdir(base):
        return out
    for dirpath, dirnames, filenames in os.walk(base):
        dirnames[:] = [d for d in dirnames if d != ".git"]
        for name in filenames:
            full = os.path.join(dirpath, name)
            rel = os.path.relpath(full, base).replace(os.sep, "/")
            out[rel] = full
    return out


def registered():
    """从 ADAPTERS.md 的「LC 核心适配副本差异」表里抽出登记的文件名."""
    if not os.path.exists(ADAPTERS):
        return set()
    with open(ADAPTERS, "r", encoding="utf-8", errors="replace") as fh:
        text = fh.read()
    # 只取该章节之后的内容，避免把别的表里的路径也算进来
    marker = "LC 核心适配副本差异"
    idx = text.find(marker)
    if idx < 0:
        return set()
    section = text[idx:]
    files = set()
    for line in section.splitlines():
        if line.startswith("## ") and marker not in line:
            break  # 到下一章节就停
        if not line.startswith("|"):
            continue
        for m in re.finditer(r"`([^`]+\.(?:swift|m|mm|h|c|cpp|hpp))`", line):
            c = m.group(1)
            if c.startswith("/") or c.startswith(":"):
                continue
            files.add(c)
    return files


def find_adapted():
    hits = glob.glob(os.path.join(ROOT, "*LiveProcess", "LC"))
    hits = [h for h in hits if os.path.isdir(h)]
    return hits[0] if hits else None


def main():
    report_only = "--report" in sys.argv

    adapted = find_adapted()
    if not adapted:
        print("[core-drift] 找不到 <prefix>LiveProcess/LC")
        return 2
    if not os.path.isdir(UPSTREAM_CORE):
        print("[core-drift] 找不到 %s" % UPSTREAM_CORE)
        return 2

    a = walk(adapted)
    u = walk(UPSTREAM_CORE)
    reg = registered()

    only_a = sorted(set(a) - set(u))
    differ = []
    same = 0
    for rel in sorted(set(a) & set(u)):
        if sha256_prefix(a[rel]) == sha256_prefix(u[rel]):
            same += 1
        else:
            differ.append(rel)

    problems = []
    for rel in differ:
        if rel not in reg:
            problems.append("未登记差异: %s" % rel)
    for rel in only_a:
        if rel not in reg:
            problems.append("未登记的新增文件: %s" % rel)
    # 登记了但实际与上游一致 → 登记过期
    for rel in reg:
        if rel in a and rel in u and rel not in differ:
            problems.append("登记过期（已与上游一致，应移除登记）: %s" % rel)

    print("[core-drift] 适配副本 %d 文件 | 逐字节相同 %d | 有差异 %d | 仅适配副本有 %d"
          % (len(a), same, len(differ), len(only_a)))
    if differ:
        print("            有差异: %s" % ", ".join(differ))
    if only_a:
        print("            新增: %s" % ", ".join(only_a))
    if reg:
        print("            已登记: %s" % ", ".join(sorted(reg)))

    if report_only:
        return 0
    if problems:
        for p in problems:
            print("[core-drift] ERROR " + p)
        print("[core-drift] 请在 vendor/LiveContainer/ADAPTERS.md 的"
              "「LC 核心适配副本差异」表里登记后再提交")
        return 1
    return 0


if __name__ == "__main__":
    sys.exit(main())
