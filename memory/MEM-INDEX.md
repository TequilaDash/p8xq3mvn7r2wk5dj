# memory/ 错误记录索引

每条含 6 字段：现象 / 我的错误动作 / 根因（方法层） / 正确做法 / 检测方法 / 关联规范。

## MEM-001 假验证导致 6 轮无效补丁（2026-11-12）

- 现象：owner 报多任务白屏/窗口消失/模块注入无效，连续 6 版修复（M6/M8/M10/M11/M12/M12b）全部无效；owner 指出上游 commit 9d6ea09b05 的特性我们没有
- 我的错误动作：多轮宣称「镜像与上游 main 100% 一致」「已用最新 nightly 9d6ea09b05」；owner 质问时反驳「上游无新 commit」
- 根因：验证方法错误——diff -rq 输出被管道吞掉后未核对退出码与行数，空输出被当「一致」；从未逐条读上游 commits API 的 message；把「同步」理解为 mtime 快照对比
- 正确做法：宣称一致前跑 `diff -rq > 文件 + wc -l + grep Only in` 三件套；`curl commits?per_page=30` 逐条读 message；连续 3 轮修复无效立即停下全量 diff 上游
- 检测方法：`lc_sync_upstream.py --check`；diff 输出落盘后 wc
- 关联规范：R-007、R-008

## MEM-002 C7 声明被合入覆盖（2026-11-12）

- 现象：v0.3.840 CI 编译失败，LCBootstrap.m:597/667 "call to undeclared function NetBlockGuestHooksInit/NetBlockApplyAfterGuestLoad"
- 我的错误动作：合入上游时 `cp` 上游 Tweaks.h 覆盖 vendor，丢掉了本仓 C7 的 NetBlock 声明，未做合入后补丁完整性检查
- 根因：没有「合入后逐个 grep 本仓补丁标记」的步骤（R-009 缺失时的直接后果）
- 正确做法：合入后按 R-009 四步走：重放→manifest→三守卫→precommit；cp 过的文件 grep 补丁标记
- 检测方法：`grep -c NetBlock vendor/LiveContainer/LiveContainer/Tweaks/Tweaks.h` ≥2
- 关联规范：R-009

## MEM-003 M12 独立 window 全屏挡触摸（2026-11-12）

- 现象：owner 实测「多任务窗口打开后除多任务外任意界面都点不了」
- 我的错误动作：为解决「窗口消失」引入 windowLevel .alert+100 的全屏独立 UIWindow
- 根因：把「UIWindow 加 hitTest 穿透」当成安全操作，未认识独立 window 在 UIKit+SwiftUI presentation 混合下的事件分发不可从代码推理；未按 R-011 先自查交互面
- 正确做法：M12b——挂 keyWindow + UIWindow.didBecomeKeyNotification 重挂 + showDock 查 view.window != nil；独立 window 方案永久禁用
- 检测方法：R-011 的交互面清单必须在 CHANGELOG 与验证清单中出现
- 关联规范：R-011

## MEM-004 仓库改名连锁 CI 失败（2026-11-12）

- 现象：改名后连续两次 SAP 构建失败（CMakeCache.txt directory is different）
- 我的错误动作：只改了 SAP 缓存 key，漏了 DerivedData 缓存（build/Build/Intermediates.noindex 含 SAP 的 CMakeCache 旧绝对路径）；第一次随机名只生成出 "k" 一个字符
- 根因：没有盘点「哪些缓存含绝对路径」；Windows 无 /dev/urandom 导致 shell 命令链带着失败结果继续执行
- 正确做法：R-012 四步；随机名用 python 生成并先验证长度再调 API
- 检测方法：CI SAP step 无 CMakeCache 错误；curl 确认 name 完整
- 关联规范：R-012

## MEM-005 v0.3.840 编译失败 LCSharedUtils 未声明（2026-11-12）

- 现象：HostGuestEntry.m "use of undeclared identifier 'LCSharedUtils'"
- 我的错误动作：入口翻译单元直接调 LCSharedUtils.appGroupID 未声明
- 根因：不确定 import 头的副作用链（会拉进 extern 变量），选择了裸调用
- 正确做法：R-013 的 @interface 前置声明
- 检测方法：CI 无 undeclared identifier
- 关联规范：R-013
