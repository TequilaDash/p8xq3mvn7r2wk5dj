#!/usr/bin/env python3
"""i18n 守卫：代码里引用的 `.loc` 键必须在宿主 Localizable.xcstrings 里存在。

背景（owner 2026-11-13 真机反馈）：
    合入上游 9d6ea09b05 后，App 设置页出现**原始变量名**
    `lc.appSettings.helperProcessesSupport` / `lc.appSettings.fixBackgroundTaskIdentifiers`
    —— 因为这两条新键只在上游 `vendor/LiveContainer/Resources/Localizable.xcstrings` 里，
    宿主实际打包的 `Resources/Localizable.xcstrings` 还是旧的。

规则：
    · 代码（vendor/ + 适配层）里所有 `"lc.xxx"` / `"TDxxx"` 字面量 → 视为 UI 键
    · 每个键必须在 `Resources/Localizable.xcstrings` 里出现
    · 每条键至少要有 `en` 本地化（否则英文环境也显示键名）

用法：
    python Resources/Scripts/lc_i18n_guard.py <仓库根>
    python Resources/Scripts/lc_i18n_guard.py . --list   # 只列缺的，不判失败

退出码：0 = 全齐；1 = 有缺失
"""

import io
import json
import os
import re
import sys

SCAN_DIRS = (
    "vendor/LiveContainer",
    "TDLCUIAdapters",
    "TDLiveProcess/LC",
    "TD",
)
KEY_RE = re.compile(r'"((?:lc|TD|td)\.[A-Za-z0-9_.]+)"')


def collect_code_keys(root):
    keys = {}
    for base in SCAN_DIRS:
        d = os.path.join(root, base)
        if not os.path.isdir(d):
            continue
        for dp, dn, fn in os.walk(d):
            dn[:] = [x for x in dn if x not in (".git", "build")]
            for n in fn:
                if not n.endswith((".swift", ".m", ".h", ".mm")):
                    continue
                p = os.path.join(dp, n)
                try:
                    s = io.open(p, encoding="utf-8", errors="replace").read()
                except OSError:
                    continue
                for k in KEY_RE.findall(s):
                    keys.setdefault(k, os.path.relpath(p, root).replace(os.sep, "/"))
    return keys



def _is_translated(unit):
    """单条本地化是否可直接用于构建：state == translated（含 plural 变体逐项检查）。"""
    su = unit.get("stringUnit")
    if su:
        return su.get("state") == "translated" and bool(su.get("value"))
    variations = unit.get("variations") or {}
    for kind in variations.values():
        for case in kind.values():
            inner = case.get("stringUnit") or {}
            if inner.get("state") != "translated" or not inner.get("value"):
                return False
    return bool(variations)

def main():
    root = sys.argv[1] if len(sys.argv) > 1 and not sys.argv[1].startswith("-") else "."
    list_only = "--list" in sys.argv

    cat = os.path.join(root, "Resources", "Localizable.xcstrings")
    if not os.path.isfile(cat):
        print("[i18n] 找不到 %s" % cat)
        return 2
    strings = json.load(open(cat, encoding="utf-8")).get("strings", {})
    code_keys = collect_code_keys(root)

    # 宿主只打包 en / zh-Hans / zh-Hant 三种本地化（其余语种在构建时被剥离），
    # 所以这三者缺任一 → 该语言用户看到英文甚至原始键名，都算缺陷。
    REQUIRED = ("en", "zh-Hans", "zh-Hant")
    missing = []
    no_loc = []
    for k, src in sorted(code_keys.items()):
        if k not in strings:
            missing.append((k, src))
            continue
        locs = (strings[k].get("localizations") or {})
        absent = []
        for lg in REQUIRED:
            if lg not in locs:
                absent.append(lg)
                continue
            # `needs_review` / `new` 状态在构建时**不会被采用**（回退源语言），
            # 等于没翻译。变体（plural）要逐个检查内部 stringUnit。
            if not _is_translated(locs[lg]):
                absent.append(lg + "(未确认)")
        if absent:
            no_loc.append((k, src, ",".join(absent)))

    print("[i18n] 代码引用键 %d | xcstrings 键 %d | 缺失 %d | 缺本地化 %d"
          % (len(code_keys), len(strings), len(missing), len(no_loc)))
    for k, src in missing:
        print("  MISSING %s   (引用于 %s)" % (k, src))
    for k, src, absent in no_loc:
        print("  NO-LOC  %s   (缺 %s, 引用于 %s)" % (k, absent, src))

    if list_only:
        return 0
    if missing or no_loc:
        print("[i18n] 请把上游 Localizable.xcstrings 里对应键合并进 Resources/Localizable.xcstrings")
        return 1
    return 0


if __name__ == "__main__":
    sys.exit(main())