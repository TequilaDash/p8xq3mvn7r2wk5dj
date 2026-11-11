#!/usr/bin/env python3
"""LC 移植适配规则守卫: 把「已犯过的错」变成机器检查.

对应 E:/DSH/tequiladash/00_交接包_2026-11-08/04_规则与雷区.md 的 R-LC-1..R-LC-8.
每条规则一个检查函数, 违反即 ERROR.

已实现的可机器检查项:
  R-LC-2  镜像改动必须登记在 MIRROR-DELTAS.md      （另由 lc_mirror_delta_guard.py 管）
  R-LC-3  两个扩展的 sources 必须包含 LCSharedUtils.m
  R-LC-4  LC 源码里的 `@ObservedObject var x = X()` 必须用 .shared
  R-LC-6  改 suite 后必须成对: 宿主写 LCCertificate* 时必须同时有 group suite 写入
  R-LC-7  主 target 不得直接打包 vendor 下的 .xcassets（必须用物理副本 .bundle）
  R-LC-8  容器根三处必须一致（LCPath.docPath / SandboxContainerStore.root / LCPathBridge）

R-LC-1/5/9/10 是语义规则（产物名、searchable 副作用、验签限制、TweakLoader 位置），
不适合机器检查，靠 code review + 本文档。

用法: python lc_adaptation_guard.py [仓库根]
"""

import os
import re
import sys

BASE = os.path.dirname(os.path.dirname(os.path.dirname(os.path.abspath(__file__))))


def read(path):
    try:
        with open(path, "r", encoding="utf-8", errors="replace") as fh:
            return fh.read()
    except OSError:
        return ""


def check_extension_has_lc_core(root):
    """R-LC-3: 两个扩展必须自带 LCSharedUtils.m（独立进程没有主 App 的类）."""
    problems = []
    yml = read(os.path.join(root, "project.yml"))
    for target in ("ShareExtension", "LaunchAppExtension"):
        m = re.search(
            r"^  %s:\n(.*?)(?=^  [A-Za-z][A-Za-z0-9_-]*:\n|\Z)" % re.escape(target),
            yml, re.S | re.M)
        if not m:
            problems.append("R-LC-3 project.yml 里找不到 target %s" % target)
            continue
        block = m.group(1)
        if "LCSharedUtils.m" not in block:
            problems.append(
                "R-LC-3 %s 的 sources 缺 LCSharedUtils.m（独立进程需要自带 LC 核心）" % target)
        if "LCSharedGlobalsShim.m" not in block:
            problems.append(
                "R-LC-3 %s 的 sources 缺 LCSharedGlobalsShim.m（全局符号桩）" % target)
    return problems


def check_observed_object_defaults(root):
    """R-LC-4: LC 源码里 `@ObservedObject var x: X = X()` 必须改成 `.shared`."""
    problems = []
    vendor = os.path.join(root, "vendor", "LiveContainer")
    for dirpath, dirnames, filenames in os.walk(vendor):
        dirnames[:] = [d for d in dirnames if d != ".git"]
        for name in filenames:
            if not name.endswith(".swift"):
                continue
            path = os.path.join(dirpath, name)
            rel = os.path.relpath(path, root).replace(os.sep, "/")
            for no, line in enumerate(read(path).splitlines(), 1):
                if "@ObservedObject" not in line or "=" not in line:
                    continue
                # 形如: @ObservedObject var searchContext: SearchContext = SearchContext()
                if re.search(r"=\s*[A-Z]\w*\(\)\s*$", line.strip()):
                    problems.append(
                        "R-LC-4 %s:%d 用 `= X()` 初始化 @ObservedObject"
                        "（视图重建会重新求值，应改 `.shared`）" % (rel, no))
    return problems


def check_certificate_suite_pairing(root):
    """R-LC-6: 宿主写 LCCertificate* 时必须同时写 group suite."""
    problems = []
    path = os.path.join(root, "TequilaDash", "Views", "CertificateView.swift")
    src = read(path)
    if not src:
        return problems
    if "LCCertificatePassword" in src and "LCSharedDefaultsBridge" not in src:
        problems.append(
            "R-LC-6 CertificateView 写 LCCertificate* 但没有用 LCSharedDefaultsBridge"
            "（LC 读 group suite，只写 standard 会读不到）")
    return problems


def check_xcassets_from_vendor(root):
    """R-LC-7: 主 target 不得直接打包 vendor 下的 .xcassets."""
    problems = []
    yml = read(os.path.join(root, "project.yml"))
    for line in yml.splitlines():
        s = line.strip()
        if not s.startswith("- path:") and not s.startswith("path:"):
            continue
        if "vendor/" in s and ".xcassets" in s:
            problems.append(
                "R-LC-7 project.yml 直接打包了 vendor 的 .xcassets: %s"
                "（xcodegen 会编进 Assets.car 覆盖主 App 图标，应物理复制成 .bundle）" % s)
    return problems


def check_container_root_consistency(root):
    """R-LC-8: 容器根三处必须一致（都指向 Documents/）."""
    problems = []
    store = read(os.path.join(root, "TequilaDash", "Engine", "SandboxContainerStore.swift"))
    bridge = read(os.path.join(root, "TequilaDashLCUIAdapters", "LCPathBridge.swift"))

    if store:
        m = re.search(r"static var root: URL \{\s*(.*?)\n    \}", store, re.S)
        if m and "SandboxApps" in m.group(1):
            problems.append("R-LC-8 SandboxContainerStore.root 仍拼了 SandboxApps")
    if bridge:
        m = re.search(r"static var hostContainerRoot: URL \{\s*(.*?)\n    \}", bridge, re.S)
        if m and "SandboxApps" in m.group(1):
            problems.append(
                "R-LC-8 LCPathBridge.hostContainerRoot 仍拼了 SandboxApps"
                "（与 LCPath.docPath / SandboxContainerStore.root 不一致）")
    return problems


def main():
    root = sys.argv[1] if len(sys.argv) > 1 else "."
    if not os.path.isdir(os.path.join(root, "vendor", "LiveContainer")):
        print("[lc-adapt] 不是本仓根目录: %s" % root)
        return 2

    checks = [
        ("R-LC-3 扩展自带 LC 核心", check_extension_has_lc_core),
        ("R-LC-4 @ObservedObject 默认值", check_observed_object_defaults),
        ("R-LC-6 证书 suite 成对", check_certificate_suite_pairing),
        ("R-LC-7 xcassets 不得直打包 vendor", check_xcassets_from_vendor),
        ("R-LC-8 容器根一致性", check_container_root_consistency),
    ]

    total = 0
    for label, fn in checks:
        for p in fn(root):
            print("[lc-adapt] ERROR %s" % p)
            total += 1

    print("[lc-adapt] 检查 %d 条规则, 问题 %d 个" % (len(checks), total))
    return 1 if total else 0


if __name__ == "__main__":
    sys.exit(main())
