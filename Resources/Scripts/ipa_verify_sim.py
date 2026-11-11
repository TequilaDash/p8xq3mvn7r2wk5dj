#!/usr/bin/env python3
"""本地模拟 CI 的 IPA 校验步骤 —— 不用等 25 分钟 CI 就知道会不会过.

背景（R-CI-1 的延伸）：
    `.github/workflows/build-xcode.yml` 的 `Verify SAP assets inside IPA` 步骤
    连续 6 轮失败，每轮都要等 ~25 分钟才看到结果。
    本脚本把该步骤的逻辑在本地用 zipfile 复现，拿现成 IPA 一跑就知道。

用法:
    python Resources/Scripts/ipa_verify_sim.py <ipa> [<ipa2> ...]
    python Resources/Scripts/ipa_verify_sim.py --list-plugins <ipa>   # 只看 PlugIns 内容

退出码: 0 = 会通过; 1 = 会失败（打印原因）
"""

import re
import sys
import zipfile

# 与 build-xcode.yml 保持一致
APP_NAME = "TequilaDash.app"
LP_CANDIDATES = ["LiveProcess", "TequilaDashLiveProcess"]
SAP_REQUIRED = ["SAPAssets/CommerceKit", "SAPAssets/CoreFP"]
TUNNEL_APPEX = "TequilaDashTunnel"


def check(ipa):
    """返回 (ok, messages)."""
    msgs = []
    ok = True
    with zipfile.ZipFile(ipa) as z:
        names = z.namelist()
        listing = "\n".join(names)

        # ① SAPAssets（必须）
        for need in SAP_REQUIRED:
            if need not in listing:
                msgs.append("FAIL SAPAssets 缺 %s" % need)
                ok = False
        if ok:
            msgs.append("OK   SAPAssets 齐（CommerceKit + CoreFP）")

        # ② 隧道版 NE entitlements（仅当是 Tunnel 版）
        if "Tunnel" in ipa:
            app_ent = "Payload/%s/%s.entitlements" % (APP_NAME, "TequilaDash")
            ext_ent = "Payload/%s/PlugIns/%s.appex/%s.entitlements" % (APP_NAME, TUNNEL_APPEX, TUNNEL_APPEX)
            for label, path in (("主 App", app_ent), ("扩展", ext_ent)):
                if path not in names:
                    msgs.append("FAIL 隧道版%s entitlements 不存在: %s" % (label, path))
                    ok = False
                    continue
                body = z.read(path).decode("utf-8", "replace")
                if "com.apple.developer.networking.networkextension" not in body:
                    msgs.append("FAIL 隧道版%s entitlements 缺 NE 权限" % label)
                    ok = False
            if ok:
                msgs.append("OK   隧道版 NE entitlements（app + appex）")

        # ③ LiveProcess appex（必须存在 + 名字两种都接受）
        lp_dir = ""
        for cand in LP_CANDIDATES:
            if "PlugIns/%s.appex/Info.plist" % cand in listing:
                lp_dir = cand
                break
        if not lp_dir:
            msgs.append("FAIL 缺 PlugIns/{LiveProcess,TequilaDashLiveProcess}.appex")
            ok = False
        else:
            msgs.append("OK   LiveProcess appex = %s.appex" % lp_dir)
            # ④ entitlements：未签名 IPA 里可有可无（R-CI-6），只报告
            m = re.search(r"PlugIns/%s\.appex/[^/]+\.entitlements" % re.escape(lp_dir), listing)
            if m:
                msgs.append("INFO entitlements present: %s" % m.group(0))
            else:
                msgs.append("INFO entitlements absent（未签名 IPA 正常）")

        # ⑤ CFBundleVersion 一致（需要解析 plist，用 plistlib）
        try:
            import plistlib
            app_info = plistlib.loads(z.read("Payload/%s/Info.plist" % APP_NAME))
            app_cv = app_info.get("CFBundleVersion", "")
            if lp_dir:
                lp_info = plistlib.loads(z.read("Payload/%s/PlugIns/%s.appex/Info.plist" % (APP_NAME, lp_dir)))
                lp_cv = lp_info.get("CFBundleVersion", "")
                if lp_cv != app_cv:
                    msgs.append("FAIL LiveProcess CFBundleVersion=%s != 主 App %s" % (lp_cv, app_cv))
                    ok = False
                else:
                    msgs.append("OK   CFBundleVersion 一致 (%s)" % app_cv)
        except Exception as e:  # noqa: BLE001
            msgs.append("WARN 无法比对 CFBundleVersion: %s" % e)

    return ok, msgs


def list_plugins(ipa):
    with zipfile.ZipFile(ipa) as z:
        for n in sorted(z.namelist()):
            if "PlugIns/" in n:
                print("  ", n)


def main():
    args = [a for a in sys.argv[1:] if not a.startswith("--")]
    if not args:
        print(__doc__)
        return 2
    if "--list-plugins" in sys.argv:
        for ipa in args:
            print("===", ipa)
            list_plugins(ipa)
        return 0

    all_ok = True
    for ipa in args:
        print("===", ipa)
        ok, msgs = check(ipa)
        for m in msgs:
            print("  ", m)
        print("  =>", "PASS" if ok else "FAIL")
        all_ok = all_ok and ok
    return 0 if all_ok else 1


if __name__ == "__main__":
    sys.exit(main())
