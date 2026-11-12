# RULES.md — TD 宿主项目规范（条件 → 动作 → 验证）

> 每条规范三段式：条件（何时触发）→ 动作（做什么，带命令）→ 验证（如何证明已执行）。
> 禁止「要仔细/要认真」类无法检验的表述。违反记录见 memory/ 对应 MEM 编号。

## R-007 禁止未验证的状态断言
- 条件：输出「已同步/已对齐/完全一致/最新版/100% 一致」等状态词之前
- 动作：跑 `diff -rq <上游> vendor/LiveContainer > /tmp/d.txt 2>&1; wc -l < /tmp/d.txt`，并在同一段回复里贴出行数；行数 >0 时必须列出 `grep "Only in\|differ" /tmp/d.txt` 的完整清单；同时用 API `commits?per_page=30` 逐条列出上游 message 证明无遗漏
- 验证：该命令与输出出现在回复里；`lc_sync_upstream.py --check` 输出「有差异 N」与登记数相等
- 违反记录：MEM-001

## R-008 修复连续 3 轮无效必须停下查根基
- 条件：同一症状连续 3 个版本（tag）修复后 owner 报告仍失败
- 动作：停止打补丁；下载上游 main.zip 全量 diff vendor/；列出「上游有而我们没有」的文件与函数清单；确认当前架构与上游架构是否一致（而非参数/数值差异）
- 验证：修复方案必须先引用上游对应代码行号，再给出本仓改动
- 违反记录：MEM-001（M6/M8/M10/M11/M12 六轮无效）

## R-009 合入上游后必须全量重放登记补丁并过三守卫
- 条件：对 vendor/ 做任何「覆盖/合入」操作之后
- 动作：①按 MIRROR-DELTAS 表逐条重放；②manifest 重建（lc_sync_upstream --check 或手动 sha256）；③三守卫全绿：`lc_mirror_guard.py`、`lc_mirror_delta_guard.py`、`lc_core_drift_guard.py`；④`swift_precommit_check.py` rc=0
- 验证：四条命令输出贴在回复里；cp 覆盖过的文件逐个 grep 本仓补丁标记（如 NetBlock、TD_NET_BLOCK、v0.3.8xx）确认未丢失
- 违反记录：v0.3.840 编译失败（C7 声明被 cp 覆盖丢失）

## R-010 移植副本文档里的路径不得含反引号文件名（防 guard 误判）
- 条件：在 ADAPTERS.md / 登记表里写「补丁已落 vendor」类说明时
- 动作：说明文字里不给文件名加反引号（drift guard 用反引号内路径提取登记项，补丁落 vendor 后副本==vendor 会被误判「登记过期」）
- 验证：`lc_core_drift_guard.py` 输出无「登记过期」
- 违反记录：2026-11-12 C1/C4 行误判

## R-011 每版发布前必须自查「是否引入新交互问题」
- 条件：修改任何 UIWindow/view 层级/hitTest/事件分发相关代码之后
- 动作：在 commit message 里明确列出「可能影响的交互面」清单（主界面点击、弹窗、多任务、dock），并在给 owner 的验证清单里让 owner 先验证这些面没有被破坏
- 验证：CHANGELOG 有「交互面影响」小节
- 违反记录：M12 独立 window 全屏挡触摸（v0.3.838）

## R-012 仓库改名后的连锁检查
- 条件：执行 PATCH /repositories/{id} 改名之后
- 动作：①SAP 缓存 key 版本号 +1；②DerivedData 缓存 key 版本号 +1（CMakeCache 记旧绝对路径）；③用 API clone_url 重设 git remote；④curl 确认 name 非残缺（Windows 无 /dev/urandom，随机名用 python 生成并验证长度）
- 验证：下一次 CI 的 SAP step 无 "CMakeCache.txt directory is different" 错误
- 违反记录：2026-11-12 连续两次 SAP 构建失败

## R-013 ObjC 入口翻译单元用 @interface 前置声明
- 条件：在 main 入口 .m（HostGuestEntry.m）里需要调用 LC 类方法时
- 动作：写 `@interface ClassName : NSObject` + 方法声明，不 import LC 头文件（会拉进 extern 变量链导致顺序脆弱）
- 验证：CI 编译无 "use of undeclared identifier"
- 违反记录：v0.3.840 编译失败（LCSharedUtils 未声明）
