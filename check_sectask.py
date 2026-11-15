#!/usr/bin/env python3
# 审计 v2 §四第二批第二刀 + 第三刀设计草稿的自检脚本（本地静态验证，不依赖 macOS 工具链）
# 检查对象: TDVRootConfig.h/.m + TDVRootShim.m 的 SecTask/csops 扩表增量
import re, sys

FAIL = []
def check(cond, msg):
    print(("PASS  " if cond else "FAIL  ") + msg)
    if not cond:
        FAIL.append(msg)

H = "TequilaDashLCUIAdapters/VRoot/TDVRootConfig.h"
M = "TequilaDashLCUIAdapters/VRoot/TDVRootConfig.m"
S = "TequilaDashLCUIAdapters/VRoot/TDVRootShim.m"

h = open(H, encoding="utf-8").read()
m = open(M, encoding="utf-8").read()
s = open(S, encoding="utf-8").read()

# --- 1. 头文件声明齐全 ---
check("TDVSecTaskSpoofEnabled" in h and "TDVSecTaskHideEntitlement" in h,
      "TDVRootConfig.h 声明 SecTask 两个导出")
check("TDVCsopsSpoofEnabled" in h and "TDVCsopsSpoofLookup" in h,
      "TDVRootConfig.h 声明 csops 两个导出")

# --- 2. Config.m 实现: 门控 env + 逻辑 ---
check('getenv("TD_SECTASK_SPOOF")' in m, "SecTask 门控 env TD_SECTASK_SPOOF 存在")
check('getenv("TD_CSOPS_SPOOF")' in m, "csops 门控 env TD_CSOPS_SPOOF 存在")
# SecTask: 隐藏键表 + 前缀通配
check("kTDVSecTaskHideExact" in m and "kTDVSecTaskHidePrefixes" in m,
      "SecTask 隐藏表: 精确表 + 前缀表两段")
# 语义: 拦截面 = Copy (Create 透传); 返回 NULL 前清 *error (调用方可能解引用 CFErrorRef)
check(re.search(r"tdv_sectask_copy_impl[\s\S]*?if \(error\) \*error = NULL;", s) is not None,
      "shim Copy 拦截返回 NULL 时清 *error")
# create 不注册 interpose (设计决定: 拦截面只在 Copy, 减少表面积)
check("TDV_INTERPOSE(tdv_sectask_create_impl" not in s,
      "shim Create 未注册 interpose (纯透传语义)")
# csops: 拦 CS_OPS_STATUS(0) 的字面量 + 注释标注
check("ops == 0 /*CS_OPS_STATUS*/" in s, "csops 只拦 CS_OPS_STATUS(0) 且注释标注")
# debug 位清除常量
check("0x10000000u" in m, "CS_DEBUGGED 位 0x10000000 显式常量")
# get-task-allow (0x2000) 伪清除必须可配
check("TD_CSOPS_KEEP_DEBUGGED" in m, "CS_DEBUGGED 保留开关存在 (调试器场景)")
# init 锁内同步读 env
check(re.search(r"tdv_init_locked[\s\S]*?gTDVSecTaskSpoof\s*=\s*getenv", m) is not None,
      "SecTask 门控在 tdv_init_locked 内求值")
check(re.search(r"tdv_init_locked[\s\S]*?gTDVCsopsSpoof\s*=\s*getenv", m) is not None,
      "csops 门控在 tdv_init_locked 内求值")

# --- 3. Shim interpose: 签名正确 + 表注册 ---
check("__asm(\"_SecTaskCopyValueForEntitlement\")" in s, "shim SecTaskCopyValueForEntitlement 裸符号绑定")
check("__asm(\"_csops\")" in s, "shim csops 裸符号绑定")
check("TDV_INTERPOSE(tdv_sectask_copy" in s, "interpose 表注册 SecTaskCopyValueForEntitlement")
check("TDV_INTERPOSE(tdv_csops" in s, "interpose 表注册 csops")
# csops_audittoken 也拦 (audit token 通道同一个 flags 查询)
check("__asm(\"_csops_audittoken\")" in s and "TDV_INTERPOSE(tdv_csops_audittoken" in s,
      "csops_audittoken 一并拦截")
# create 的 extern 声明现在无消费者 —— 不应存在 (编译器会警告未使用)
check("tdv_real_sectask_create" not in s,
      "SecTaskCreate 裸符号声明已随 impl 删除 (无死代码)")

# --- 4. 括号/圆括号平衡 ---
for name, text in (("Config.h", h), ("Config.m", m), ("Shim.m", s)):
    check(text.count("{") == text.count("}"), f"{name} 大括号平衡")

# --- 5. 本镜像自调用豁免说明: SecTaskCreateFromSelf 的 shim 实现内部调原实现 ---
check(re.search(r"tdv_sectask_copy_impl[\s\S]*?return tdv_real_sectask_copy\(task, entitlement, error\);", s) is not None,
      "shim Copy 未命中键时透传原实现 (自镜像豁免语义)")

print()
if FAIL:
    print(f"{len(FAIL)} 项未过")
    sys.exit(1)
print("全部通过")
