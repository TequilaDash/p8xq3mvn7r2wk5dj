#!/usr/bin/env python3
"""发版前核对：tag 名 == 产物版本号 == CHANGELOG 顶部 == project.yml.

背景（R-GIT-1，2026-11-11 踩过）：
    v0.3.823 的 release 里 IPA 文件名是 `TequilaDash-0.3.814-xcode-unsigned.ipa`。
    原因：`git revert` 撤了整个 commit，把同 commit 的版本号 bump 一起吃掉了。
    tag 叫 823，产物叫 814，owner 装包后看到的还是旧版本号。

本脚本在**打 tag 之前**把这条链核死：

    project.yml 顶层 MARKETING_VERSION  (8 处必须一致)
    Resources/Info.plist                CFBundleShortVersionString
    CHANGELOG.md                        顶部 `## [x.y.z]`
    git tag                             即将创建的名字

用法:
    python Resources/Scripts/release_check.py v0.3.824
    python Resources/Scripts/release_check.py            # 只核对三处，不核对 tag 名

退出码: 0 = 可以打 tag; 1 = 有问题
"""

import os
import re
import subprocess
import sys

REPO = os.path.dirname(os.path.dirname(os.path.dirname(os.path.abspath(__file__))))


def sh(*args):
    return subprocess.run(args, cwd=REPO, capture_output=True, text=True).stdout


def read(rel):
    p = os.path.join(REPO, rel)
    if not os.path.isfile(p):
        return ""
    with open(p, "r", encoding="utf-8", errors="replace") as fh:
        return fh.read()


def main():
    want_tag = sys.argv[1] if len(sys.argv) > 1 else ""
    problems = []

    # ① project.yml：所有 MARKETING_VERSION 必须同一个值
    proj = read("project.yml")
    versions = re.findall(r'MARKETING_VERSION:\s*"([0-9.]+)"', proj)
    builds = re.findall(r'CURRENT_PROJECT_VERSION:\s*"([0-9]+)"', proj)
    if not versions:
        problems.append("project.yml 找不到 MARKETING_VERSION")
        ver = ""
    else:
        uniq = sorted(set(versions))
        if len(uniq) != 1:
            problems.append("project.yml 里 MARKETING_VERSION 不一致: %s" % uniq)
        ver = uniq[0]
        print("① project.yml  MARKETING_VERSION = %s（%d 处）  build = %s（%d 处）"
              % (ver, len(versions), sorted(set(builds))[0] if builds else "?", len(builds)))

    # ② Info.plist
    plist = read("Resources/Info.plist")
    m = re.search(r"<key>CFBundleShortVersionString</key>\s*<string>([^<]+)</string>", plist)
    plist_ver = m.group(1).strip() if m else ""
    if plist_ver != ver:
        problems.append("Info.plist CFBundleShortVersionString=%s != project.yml %s"
                        % (plist_ver or "(缺)", ver))
    else:
        print("② Info.plist   CFBundleShortVersionString = %s  OK" % plist_ver)

    # ③ CHANGELOG 顶部
    chl = read("CHANGELOG.md")
    cm = re.search(r"^##\s*\[([0-9.]+)\]", chl, re.M)
    chl_ver = cm.group(1) if cm else ""
    if chl_ver != ver:
        problems.append("CHANGELOG 顶部 [%s] != project.yml %s（revert 可能吃掉了 bump）"
                        % (chl_ver or "(无)", ver))
    else:
        print("③ CHANGELOG    [%s]  OK" % chl_ver)

    # ④ tag 名（可选）
    if want_tag:
        tag_ver = want_tag.lstrip("v")
        if tag_ver != ver:
            problems.append("tag 名 %s 的版本 %s != 实际产物版本 %s"
                            % (want_tag, tag_ver, ver))
        else:
            print("④ tag 名       %s  OK" % want_tag)
        if sh("git", "tag", "-l", want_tag).strip():
            problems.append("tag %s 已存在（不要重复打；如需重打先删旧 tag）" % want_tag)

    print("-" * 60)
    if problems:
        for p in problems:
            print("ERROR " + p)
        print("=> 不许打 tag")
        return 1
    print("=> 可以打 tag（产物文件名将是 TequilaDash-%s-xcode-unsigned.ipa）" % ver)
    return 0


if __name__ == "__main__":
    sys.exit(main())
