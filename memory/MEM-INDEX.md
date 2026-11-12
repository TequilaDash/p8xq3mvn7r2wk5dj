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

## MEM-007 LC_HOME_PATH 语义误传（2026-11-13）

- 现象：全屏启动报 `App bundle not found! Unable to read LCAppInfo.plist`
- 我的错误动作：v0.3.801 把 `LC_HOME_PATH` 设为 `Documents`，注释还写「与上游 LCPath.docPath 对齐」
- 根因：只看了一半——上游 `LCPath.docPath` 确实是 Documents，但 `LC_HOME_PATH` 环境变量语义是 **HOME（容器根）**，LCBootstrap.m:341 自己拼 `<LC_HOME_PATH>/Documents`，:744 是 `setenv("LC_HOME_PATH", getenv("HOME"), 0)`
- 正确做法：`setenv("LC_HOME_PATH", NSHomeDirectory(), 1)`
- 检测方法：`grep -n 'LC_HOME_PATH' vendor/.../LCBootstrap.m` 看上游怎么消费它，而不是假设
- 关联规范：R-009

## MEM-008 合入时误删上游仍存在的 bug 补丁（2026-11-13）

- 现象：多任务启动闪退 `insert nil object`（AppSceneViewController initWithBundleId +1032）
- 我的错误动作：全量合入 9d6ea09b05 时，把 M6（nil 兜底）当作「旧架构补丁」删掉
- 根因：判定「哪些补丁作废」时只看「旧架构 vs 新架构」，没看**上游该崩溃点是否仍在**——上游 :64-69 的字典字面量一字未改
- 正确做法：删除任何补丁前，先在上游原文里 grep 该 bug 点是否还存在；仍在则必须重放
- 检测方法：`grep -n 'hostUrlScheme' vendor/.../AppSceneViewController.m` 确认上游写法
- 关联规范：R-009

## MEM-009 空闭包按钮依赖手势关闭（2026-11-13）

- 现象：错误弹窗右上角「好」点了没反应
- 我的错误动作：照抄上游 `Button("好") {}`（空闭包），以为是上游设计就没管
- 根因：上游依赖 `.sheet` 的下滑手势关闭；本仓 sheet 被更上层 presentation 干扰时手势失效，空闭包就真的什么都不做
- 正确做法：`@Environment(\.dismiss) private var dismiss` + `Button("好") { dismiss() }`
- 检测方法：所有弹窗的关闭按钮必须显式调用 dismiss，grep `Button("好") {}` 应为 0
- 关联规范：R-011

## MEM-010 崩溃无痕：isLiveProcess 分支不写 error 键（2026-11-13）

- 现象：闪退后手动启动不弹报错，且有没有弹窗「毫无规律」
- 我的错误动作：一直以为弹窗逻辑本身有问题，没查上游 exceptionHandler 的分支差异
- 根因：上游 `exceptionHandler` 只在 `!isLiveProcess` 写 `lcUserDefaults["error"]`；`isLiveProcess` 分支只调 `NSExtensionContext cancelRequestWithError`，宿主读不到
- 正确做法：双写——`lcUserDefaults["error"]` + `lcSharedDefaults["lastGuestLaunchError"]`(+uptime)，扩展上下文照旧
- 检测方法：`grep -A12 'static void exceptionHandler' vendor/.../LCBootstrap.m` 必须看到两处写入
- 关联规范：R-018

## MEM-011 cp 目标路径写错，文件落进不该编的 target（2026-11-13）

- 现象：0.3.843 CI 编译失败 `'LiveContainerSwiftUI-Swift.h' file not found (in target 'TDLiveProcess')`
- 我的错误动作：`cp vendor/.../AppSceneViewController.m TDLiveProcess/LC/../` 想放到 LC 目录，`..` 让它落到了 `TDLiveProcess/` 根
- 根因：cp 目标用了相对路径含 `..`，没有验证落地位置
- 正确做法：cp 到确切文件路径（不带 `..`）；cp 后 `ls` 目标目录确认；再用 `git status` 看新增文件是否符合预期
- 检测方法：`git status --porcelain | grep '^??'` 无意外新增；xcodegen 的 target sources 列表不含新文件
- 关联规范：R-009
