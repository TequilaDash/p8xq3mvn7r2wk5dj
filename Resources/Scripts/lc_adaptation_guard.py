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


def check_product_name_references(root):
    """R-CI-2: 产物名与 CI/脚本里的硬编码引用必须一致（或显式兼容两种）."""
    problems = []
    yml = read(os.path.join(root, "project.yml"))

    # 收集各 app-extension target 的 PRODUCT_NAME
    product_names = {}
    for m in re.finditer(
            r"^  ([A-Za-z][\w-]*):\n(.*?)(?=^  [A-Za-z][\w-]*:\n|\Z)", yml, re.S | re.M):
        target, block = m.group(1), m.group(2)
        if "type: app-extension" not in block and "type: extensionkit-extension" not in block:
            continue
        pm = re.search(r"PRODUCT_NAME:\s*([\w.-]+)", block)
        if pm:
            product_names[target] = pm.group(1)

    # 检查 CI workflow 里对 appex 路径的硬编码
    wf = read(os.path.join(root, ".github", "workflows", "build-xcode.yml"))
    if not wf:
        return problems

    # 反向检查：workflow 里硬编码的每个 `<X>.appex` 字面量，
    # 必须能在某个 target 的 PRODUCT_NAME 里找到，或属于本仓显式兼容的历史名。
    known = set(product_names.values())
    # 本仓主 App 的两个扩展：LiveProcess 在 v0.3.818 改成上游名，旧名保留兼容；
    # Tunnel 是隧道扩展，不参与本轮命名对齐。两者都算合法引用。
    legacy_ok = {"LiveProcess", "TequilaDashLiveProcess", "TequilaDashTunnel",
                 "ShareExtension", "LaunchAppExtension"}

    # ① 字面量 `<X>.appex`
    refs = set(re.findall(r"(?<![$\w{])([A-Za-z][\w]*)\.appex", wf))
    # ② `for CAND in A B; do` 这种「候选名单」——本仓实际写法，
    #    名字不带 .appex，最容易漏检（v0.3.816 的 bug 就藏在这里）。
    for m in re.finditer(r"for\s+\w+\s+in\s+([^;\n]+);", wf):
        for tok in m.group(1).split():
            tok = tok.strip('"\'')
            if re.fullmatch(r"[A-Za-z][\w]*", tok):
                refs.add(tok)

    for ref in sorted(refs):
        if ref in known or ref in legacy_ok:
            continue
        problems.append(
            "R-CI-2 build-xcode.yml 引用了 `%s`（.appex 字面量或候选名单成员），"
            "但没有任何 target 的 PRODUCT_NAME 是它（过期引用，校验步会找不到产物）" % ref)
    return problems


def check_pipefail_grep_q(root):
    """R-CI-5: `set -o pipefail` 的 step 里禁止 `cmd | grep -q`（SIGPIPE 静默失败）."""
    problems = []
    wf_path = os.path.join(root, ".github", "workflows", "build-xcode.yml")
    wf = read(wf_path)
    if not wf:
        return problems

    lines = wf.splitlines()
    in_pipefail = False
    for no, line in enumerate(lines, 1):
        if "pipefail" in line:
            in_pipefail = True
        # step 边界（`- name:` 或 `run: |`）重置判断
        if line.strip().startswith("- name:"):
            in_pipefail = "pipefail" in line
        if not in_pipefail:
            continue
        stripped = line.strip()
        # 只报**真正危险**的形态：`| grep -q` 直接作为 `if`/`while` 的条件。
        # 不报：
        #   · `find ... | head -n1`  —— head 正常读完即退出，不产生 SIGPIPE 误判
        #   · `... | grep -q X || { echo ...; exit 1; }` —— 有 || 兜底，失败会走兜底
        #   · 注释行
        if stripped.startswith("#"):
            continue
        if not re.search(r"\|\s*grep\s+-[a-zA-Z]*q", stripped):
            continue
        # 危险：出现在 if / while 条件里（没有 || 兜底）
        is_condition = bool(re.match(r"^(if|while|elif)\b", stripped))
        has_fallback = "||" in stripped
        if is_condition and not has_fallback:
            problems.append(
                "R-CI-5 build-xcode.yml:%d 在 pipefail 下把 `| grep -q` 用作 if 条件"
                "（SIGPIPE 会让条件误判 false，且无 ::error:: 输出）: %s" % (no, stripped[:70]))
    return problems


def check_entitlements_not_hardcoded(root):
    """R-CI-3: CI 里校验 .entitlements 存在时，不得锁死具体文件名.

    踩过 3 轮（run 42966013181 / 42970095124 / 42967765114）：
    entitlements 的名字由**源文件名**决定，也可能被签名工具改名；
    锁死 `$LP_DIR.entitlements` 或任何具体名都会失败。
    """
    problems = []
    wf = read(os.path.join(root, ".github", "workflows", "build-xcode.yml"))
    if not wf:
        return problems
    for no, line in enumerate(wf.splitlines(), 1):
        st = line.strip()
        if st.startswith("#") or "grep" not in st:
            continue
        # 命中：grep ... "PlugIns/$X.appex/<具体名>.entitlements"
        if re.search(r"PlugIns/\$?\w*\.appex/\$?\w+\.entitlements", st):
            # 允许通配写法 [^/]+\.entitlements
            if "[^/]+" in st:
                continue
            problems.append(
                "R-CI-3 build-xcode.yml:%d 把 entitlements 文件名写死（%s）"
                "—— 名字随源文件/签名工具变，应改用通配 `[^/]+` + .entitlements"
                % (no, st[:70]))
    return problems


def check_unsigned_entitlements_not_fatal(root):
    """R-CI-6: 未签名轨道（CODE_SIGNING_ALLOWED=NO）不得把 entitlements 缺失当错误."""
    problems = []
    wf = read(os.path.join(root, ".github", "workflows", "build-xcode.yml"))
    if not wf:
        return problems

    unsigned = "CODE_SIGNING_ALLOWED=NO" in wf or "CODE_SIGNING_ALLOWED: NO" in wf
    if not unsigned:
        return problems

    # 例外：隧道版（Tunnel.appex）的 entitlements 由源目录当资源拷进包，实测确实存在
    # （run 42973296579 日志 "tunnel entitlements OK"），故它的 NE 校验保留为致命错误。
    # 只针对 LiveProcess —— 它的 entitlements 未随包携带（同一 run 实测）。
    for no, line in enumerate(wf.splitlines(), 1):
        st = line.strip()
        if st.startswith("#"):
            continue
        if "entitlements" not in st or "exit 1" not in st:
            continue
        if "Tunnel" in st or "隧道版" in st:
            continue  # 白名单：隧道版 entitlements 确实随包携带
        problems.append(
            "R-CI-6 build-xcode.yml:%d 在未签名轨道里把 entitlements 缺失当致命错误"
            "（CODE_SIGN_ENTITLEMENTS 只在签名时写进产物，侧载工具会自己施加）: %s"
            % (no, st[:70]))
    return problems



def check_extensionkit_lands_in_plugins(root):
    """R-LC-14: extensionkit-extension 必须由 postBuild 挪进 PlugIns/.

    侧载工具（SideStore/isideload）只扫描 PlugIns/ 里的扩展并级联改写 bundle id。
    xcodegen 会把 extensionkit-extension 放 Extensions/，那里它看不见 →
    扩展 id 保持编译期值，主 App 被改成 <id>.<TEAMID> → 前缀不匹配 → 安装被拒
    （IXErrorDomain Code=8，owner 2026-11-11 实测）。
    """
    problems = []
    proj = read(os.path.join(root, "project.yml"))
    if not proj:
        return problems

    has_extkit = "type: extensionkit-extension" in proj
    if not has_extkit:
        return problems

    # 必须有把 Extensions/ 挪到 PlugIns/ 的 postBuild
    moved = ("Extensions" in proj and "PlugIns" in proj
             and ("Relocate extensionkit appex" in proj or "mv \"${appex}\"" in proj))
    if not moved:
        problems.append(
            "R-LC-14 用了 extensionkit-extension 但没有 postBuild 把 Extensions/*.appex "
            "挪到 PlugIns/ —— 侧载工具看不见，安装会报 "
            "IXErrorDomain Code=8 'does not match required prefix'")
    return problems


def check_unsigned_entitlements_no_appidentifierprefix(root):
    """R-LC-15: 未签名 IPA 的 entitlements 不得用 $(AppIdentifierPrefix).

    实测侧载工具会展开 $(DEVELOPMENT_TEAM) 但不展开 $(AppIdentifierPrefix)，
    产物留字面量 → LCJITLessDiagnoseView 比对 keychain-access-groups 必失败
    → 免 JIT 前置检查过不去（owner 2026-11-11 真机截图）。
    """
    problems = []
    for rel in ("TD.entitlements",):
        pass
    import glob
    for path in glob.glob(os.path.join(root, "*.entitlements")):
        if "Tunnel" in os.path.basename(path):
            continue
        text = read(path)
        if not text:
            continue
        # 跳过 XML 注释：注释里提到这个变量是为了说明「为什么不能用」
        import re as _re
        body = _re.sub(r"<!--.*?-->", "", text, flags=_re.S)
        if "$(AppIdentifierPrefix)" in body:
            n = body.count("$(AppIdentifierPrefix)")
            problems.append(
                "R-LC-15 %s 用了 %d 处 $(AppIdentifierPrefix)；未签名 IPA 里侧载工具"
                "不会展开它 → 免 JIT 的 keychain-access-groups 判定恒失败。"
                "改用 $(DEVELOPMENT_TEAM)." % (os.path.basename(path), n))
    return problems


def check_extension_bundle_id_follows_host(root):
    """R-LC-14b: 扩展 bundle ID 必须从主 App ID 派生（<host>.<扩展名>）。

    SideStore 安装时把主 App 改成 <id>.<TEAMID>，扩展若写死独立 ID，
    iOS 报 'does not match required prefix ... for parent'。
    """
    problems = []
    proj = read(os.path.join(root, "project.yml"))
    if not proj:
        return problems
    import re
    # 找所有 target 级 PRODUCT_BUNDLE_IDENTIFIER 字面量（非 $(...) 开头）
    for m in re.finditer(r'^\s+PRODUCT_BUNDLE_IDENTIFIER:\s*"?([^"\n]+)"?\s*$', proj, re.M):
        val = m.group(1).strip()
        if val.startswith("$(") or val.startswith("${"):
            continue
        # 顶层 TD_HOST_BUNDLE_ID / PRODUCT_BUNDLE_IDENTIFIER 那两行是主 App 的，允许
        line_no = proj[:m.start()].count("\n") + 1
        if line_no <= 50:
            continue
        problems.append(
            "R-LC-14b project.yml:%d 扩展 bundle ID 写死 '%s'；"
            "应写成 $(TD_HOST_BUNDLE_ID).<扩展名>，否则 SideStore 改名后前缀不匹配"
            % (line_no, val))
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
        ("R-CI-2 产物名与 CI 硬编码一致", check_product_name_references),
        ("R-CI-5 pipefail 下禁止 grep -q", check_pipefail_grep_q),
        ("R-CI-3 entitlements 文件名不得写死", check_entitlements_not_hardcoded),
        ("R-CI-6 未签名轨道不得校验 entitlements", check_unsigned_entitlements_not_fatal),
        ("R-LC-14 extensionkit 必须落 PlugIns", check_extensionkit_lands_in_plugins),
        ("R-LC-14b 扩展 bundle ID 必须派生自主 App", check_extension_bundle_id_follows_host),
        ("R-LC-15 entitlements 禁用 AppIdentifierPrefix", check_unsigned_entitlements_no_appidentifierprefix),
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
