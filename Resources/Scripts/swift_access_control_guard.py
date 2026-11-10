#!/usr/bin/env python3
"""访问控制守卫: 禁止 `public` 类继承 `internal` 类.

为什么需要 (v0.3.801 真实 CI 失败):
    `TequilaDashLCUIAdapters/LCUIAppDelegate.swift` 曾写
        public final class LCUIAppDelegate: AppDelegate
    而同文件注释里已经写明「AppDelegate 是 internal（宿主不可见）」——
    两句话互相矛盾, Swift 编译器直接报
        "class cannot be declared public because its superclass is internal"
    CI run 42761745800 第一次跑就打出来了.

    根因不是编译器, 是**写代码时没把已读到的事实当约束**: 注释里承认了 internal,
    下一行照样写 public 继承. 本守卫把这条约束变成机器检查, 不靠人记.

检查规则:
  1. 收集本仓所有 Swift 文件里的类声明 `class|struct|enum|actor NAME: Super`
     - 记录每个名字的访问级别 (public/open/internal/private/fileprivate)
  2. 若某个 public/open 类型的父类/父协议里, 有本仓内部声明为 internal 及以下的名字
     → ERROR (Swift 不允许 public 类型暴露 internal 类型)

用法:
    python swift_access_control_guard.py [仓库根, 默认 .]
退出码: 0 = 通过; 1 = 发现违规; 2 = 参数错误
"""

import os
import re
import sys

# 类声明: 可选修饰符 + class/struct/enum/actor + 名字 + 可选继承列表
DECL_RE = re.compile(
    r"^\s*(?P<mods>(?:(?:public|open|internal|private|fileprivate|final|@\w+)\s+)*)"
    r"(?:class|struct|enum|actor)\s+(?P<name>\w+)"
    r"(?:\s*:\s*(?P<bases>[^{]+?))?\s*\{.*$"
)

ACCESS_ORDER = {"private": 0, "fileprivate": 1, "internal": 2, "public": 3, "open": 4}


def declared_access(mods: str) -> str:
    """从修饰符串取访问级别; 默认 internal."""
    found = None
    for word in mods.split():
        if word in ACCESS_ORDER:
            found = word
    return found or "internal"


def scan(root: str):
    """返回 {类型名: (文件, 行号, 访问级别)} 与声明列表."""
    decls = {}
    for dirpath, dirnames, filenames in os.walk(root):
        dirnames[:] = [d for d in dirnames if d not in {".git", "build", "DerivedData"}]
        for name in filenames:
            if not name.endswith(".swift"):
                continue
            path = os.path.join(dirpath, name)
            # 镜像目录只读参照, 不参与本仓规则
            rel = os.path.relpath(path, root).replace(os.sep, "/")
            if rel.startswith("vendor/"):
                continue
            try:
                with open(path, "r", encoding="utf-8", errors="replace") as fh:
                    lines = fh.readlines()
            except OSError:
                continue
            for no, line in enumerate(lines, 1):
                m = DECL_RE.match(line)
                if not m:
                    continue
                decls[m.group("name")] = (rel, no, declared_access(m.group("mods")),
                                          (m.group("bases") or "").strip())
    return decls


def main():
    root = sys.argv[1] if len(sys.argv) > 1 else "."
    if not os.path.isdir(root):
        print("仓库根不存在: %s" % root)
        return 2

    decls = scan(root)
    problems = []

    for name, (rel, no, access, bases) in sorted(decls.items()):
        if access not in ("public", "open"):
            continue
        if not bases:
            continue
        # 只看类继承（结构体/枚举的冒号后是协议, 规则不同, 但 public 暴露 internal 协议同样违规）
        for base in re.split(r"[,\s]+", bases):
            base = base.strip()
            if not base or base.startswith("("):
                continue
            base = re.sub(r"<.*>$", "", base)
            if base not in decls:
                continue
            base_rel, base_no, base_access, _ = decls[base]
            if ACCESS_ORDER[base_access] < ACCESS_ORDER["public"]:
                problems.append(
                    "%s:%d  %s 是 %s, 却继承/遵循了 %s 的 %s (%s:%d)"
                    % (rel, no, name, access, base_access, base, base_rel, base_no)
                )

    for p in problems:
        print("[access-control] ERROR %s" % p)
    print("[access-control] 扫描类型 %d 个, 违规 %d 个" % (len(decls), len(problems)))
    return 1 if problems else 0


if __name__ == "__main__":
    sys.exit(main())
