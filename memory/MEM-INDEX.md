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

## MEM-012 合入上游后 i18n 键只更新了 vendor 侧（2026-11-13）

- 现象：设置页显示原始变量名 `lc.appSettings.helperProcessesSupport` / `.fixBackgroundTaskIdentifiers`
- 我的错误动作：合入时只把 vendor 的 Localizable.xcstrings 覆盖进来，没同步宿主实际打包的 `Resources/Localizable.xcstrings`
- 根因：资源有两份（vendor 的 + 宿主打包用的），我一直只同步前者；且没有「代码引用键 vs 打包资源」的校验
- 正确做法：合入后把新键从 vendor xcstrings 合并进宿主 xcstrings（en+zh-Hans+zh-Hant）；用 lc_i18n_guard.py 校验
- 检测方法：`python Resources/Scripts/lc_i18n_guard.py .` 输出「缺失 0」
- 关联规范：R-020

## MEM-013 i18n needs_review 状态导致翻译不生效（2026-11-13）

- 现象：键明明有中文值，App 里仍显示英文（看起来「有翻译却没生效」）
- 我的错误动作：只检查「本地化是否存在」，没检查 `stringUnit.state`
- 根因：String Catalog 的 `needs_review` / `new` 状态在构建时**不会被采用**，回退源语言；上游把新增键的中文标了 `needs_review`，直接复制过来等于没翻译
- 正确做法：zh-Hans/zh-Hant 的 `stringUnit.state` 一律置 `translated`；plural 变体要逐 case 检查
- 检测方法：`lc_i18n_guard.py`（已加 `_is_translated()`，把非 translated 视为「缺本地化」）输出「缺本地化 0」
- 关联规范：R-020

## MEM-014 删补丁只看「架构新旧」，不看上游该 bug 是否还在（2026-11-13，二次犯）

- 现象：0.3.845 全模式启动闪退，5 个 .ips 里 4 个是 `insertObject:atIndex: object cannot be nil`
- 我的错误动作：合入 9d6ea09b05 时把 M4（bookmarks addObject 判空）归为「旧架构补丁」删除，只保留了 M6r 的字典判空
- 根因：判断「补丁是否作废」时只看架构描述，没有逐处核对上游该 bug 的具体代码是否仍存在（上游 4 处 addObject 只判空 1 处，另 3 处原封不动）
- 正确做法：删除任何补丁前，`grep` 上游该 bug 的全部出现点（不是抽一处），每个出现点都要判断；M4 有 4 处，我只看了 1 处
- 检测方法：`grep -c 'bookmarks addObject' 上游文件` = 4，其中带 `if (` 保护的必须 = 4
- 关联规范：R-015

## MEM-015 iOS 26+ Foundation Swift 桥导致 swizzle 无限递归（2026-11-13）

- 现象：SIGSEGV at stack guard，`recursionInfoArray depth 10678`，栈全是 `hook_createDirectoryAtPath + 92`
- 我的错误动作：把崩溃当成普通 nil/布局问题查，没读 `recursionInfoArray`
- 根因：iOS 26+ Foundation 的 `-createDirectoryAtPath:...` 真实实现是 Swift 桥 `_NSFileManagerBridge.createDirectory(at:)`，桥又回调 ObjC selector → hook → 原实现 → 桥 → 无限递归
- 正确做法：iOS 26+ 跳过该 swizzle（该 hook 只为修老 WebKit cookie 问题）
- 检测方法：`.ips` 里出现 `recursionInfoArray` 且 depth > 1000 即判「无限递归」，直接看栈里被重复的 symbol
- 关联规范：R-022

## MEM-016 宿主进程没有 uncaught exception handler（2026-11-13）

- 现象：崩溃后再次进入 App，**一个报错弹窗都不弹**
- 我的错误动作：以为 M13 双写已覆盖所有崩溃；实际 M13 只在 guest 的 exceptionHandler 生效
- 根因：上游 `NSSetUncaughtExceptionHandler` 装在 `LiveContainerMain`；宿主走 `TDHostBoot` 从不经过它 → 宿主进程崩溃不写任何 error 键
- 正确做法：`TDInitLCGlobals()` 里也装宿主自己的 handler（写 standard + app group 双份 + uptime）
- 检测方法：`grep -c TDUncaughtExceptionHandler 宿主入口文件` ≥ 2；多任务崩溃后重启 App 必见弹窗
- 关联规范：R-018

## MEM-017 巢中巢：访客自身是另一个 LiveContainer（2026-11-13）

- 现象：`hook_createDirectoryAtPath` 无限递归 depth 10678，SIGSEGV at stack guard
- 我的错误动作：先判成「iOS 26 Swift 桥单 hook 自递归」，只加 @available 跳过
- 根因：读 .ips 的 `imageIndex` 才知道递归帧全在访客自带的 `LiveContainerShared.framework`（`app.reiko.zcontainer.app`），本仓仅 1 帧 → 两套 LC 同进程，各 swizzle 一次同一 selector，两套 category 同名方法互当「原实现」→ 成环
- 原版为何不炸：SideStore 安装时 `if(!isSideStore)` 整块跳过 `NSFMGuestHooksInit`，本仓非 SideStore 必装
- 正确做法：init 时捕获真实 IMP，hook 内直接调 IMP（不用 `[self hook_...]`）；iOS 26+ 另加不装该 swizzle
- 检测方法：`.ips` 递归帧逐个查 `imageIndex` 对应 `usedImages[i].path`，看是不是访客 bundle
- 关联规范：R-024

## MEM-018 多任务「只有 UI」= SwiftUI 场景被 exclude（2026-11-13）

- 现象：多任务模式只有 dock，访客窗口不出现，界面白屏
- 我的错误动作：先怀疑 guest 进程没起来 / 扩展配置错误，去查 LiveProcess
- 根因：原生窗口模式靠 `WindowGroup(id:"appView")`（`LiveContainerSwiftUIApp.swift:112`），而本仓 framework target **exclude** 了该文件 → `openWindow(id:)` 无场景可用
- 正确做法：强制虚拟窗口路径（`DecoratedAppSceneViewController`），并显式记录忽略 `LCMultitaskMode`
- 检测方法：`python -c` 读 project.yml 的 `LiveContainerSwiftUI.sources[0].excludes`，确认是否含 `App/LiveContainerSwiftUIApp.swift`
- 关联规范：R-026

## MEM-019 LC 会销毁宿主场景（2026-11-13）

- 现象：从多任务返回后再次进入沙盒容器，整个界面消失
- 根因：我们给 `SceneDelegate.window` 挂了真实 windowScene；LC 的 `closeDuplicatedWindow()`（LCTabView:149）与 `requestSceneDestruction()`（MultitaskAppWindow:226）会拿该 scene 的 session 调 `requestSceneSessionDestruction` → 销毁的是宿主自己的场景
- 正确做法：转发窗口不给 windowScene（session 恒 nil），两处销毁变 no-op；dock/访客窗口走 `connectedScenes.first` 不受影响
- 关联规范：R-027

## MEM-020 全仓改名必须词边界 + 保护标准库调用（2026-11-13）

- 现象：把旧工程名全局替换成本仓名称后，`re.<旧名>(...)` 被改成 `re.<新名>(...)`，多个守卫脚本 `AttributeError: module 're' has no attribute ...`；vendor 镜像也被改到，触发 LC 镜像守卫
- 根因：直接字符串替换，没有区分「标识符内部子串 / Python 标准库调用 / 只读镜像」
- 正确做法：`(?<![A-Za-z0-9_])OLD(?![A-Za-z0-9_])` 词边界；显式跳过 `re.OLD(`；os.walk 路径前缀要归一化（`./vendor` vs `.\\vendor`），vendor 一律 `git checkout --`
- 验证：`swift_precommit_check.py` 全绿（含 LC 镜像/漂移守卫）

## MEM-021 bad_query 在 iOS 27.0b4 失效 → 用 worse_query（2026-11-13）

- 现象：iOS 27.0 beta 4 起 bad_query 对任意容器返回 -4（kernelRejected），列目录/取扩展全废
- 替代原语：worse_query（App Group 的 Library/Caches 换 symlink → containermanagerd 按 class 7 / part 3 签发 token → 本进程 consume）
- 落地：`Engine/worse_query.{h,m}` + `Exploits/WorseQueryExploit.swift`，登记进 `ExploitRegistry`，默认启用，老用户一次性迁移
- 关键约束：必须有已签名 `group.*`（否则 -1）；**只在宿主进程有效**，访客进程里 LC 的 app group hook 会改写路径 → -5/-6
- 关联规范：R-029

## MEM-022 @Published 在 init 里赋值不触发 didSet → 迁移只活在内存（2026-11-13）

- 现象：老用户升级后 worse_query 当次可见，重启 App 又回到旧集合
- 根因：`ExploitSettings.init` 里 `self.enabled = set` 不触发 didSet，UserDefaults 从未写入；迁移标记却写了 → 下次启动"已迁移"且集合仍旧
- 正确做法：init 内所有需要持久化的状态显式 `UserDefaults.set`，不要依赖 didSet
- 验证：安装后重启两次，macOS 上读 container 里的 plist 确认 `ExploitSettings.enabled.rawValues` 含新值
- 关联规范：R-030

## MEM-023 访客浮窗不能挂 SwiftUI 的 PresentationHostingController（2026-11-13）

- 现象：多任务启动 SIGABRT，四个 .ips 都在 `DecoratedAppSceneViewController initWindowName:` 的
  `[rootVC addChildViewController:self]`
- 根因：上一版把 `fullScreenCover` 的 `PresentationHostingController` 当 rootVC，
  UIKit 层级检查直接抛「child view controller ... should have parent ... but requested parent is ...」
- 正确做法：自建**覆盖窗口**（普通容器 VC + windowLevel 高一层 + hitTest 只拦截访客区域），
  并把 LC dock 的 `windowHostingView`（真正承载访客画面的视图）挪进该窗口
- 检测方法：Console 出现 `[TD-Multitask] 覆盖窗口挂载`
- 关联规范：R-031

## MEM-024 「禁止联网没用」两类真因（2026-11-13）

- 现象：开关打开后 App 仍能联网；且界面上有两套开关
- 真因1：旧开关写 `TDNetBlock-<relativeBundlePath>`、新开关存 LCAppInfo `TDNetBlock`，两套口径并存；且 HostGuestEntry 只读 standardUserDefaults，绕过 LCAppModel 的入口读不到
- 真因2：只 hook `connect`；Network.framework / nw_connection 走 **connectx**，这类 App 形同未拦
- 正确做法：只保留一套 UI；HostGuestEntry 直接读访客 `LCAppInfo.plist` 的 TDNetBlock；hook 覆盖 connect/sendto/sendmsg/getaddrinfo/**connectx**，并打印一次安装/拦截日志
- 已知边界：WebKit 网络进程（com.apple.WebKit.Networking）是系统进程，guest 内 hook 管不到
- 关联规范：R-032

## MEM-025 LC 设置页接宿主能力用「宿主提供控制器 + 反射」（2026-11-13）

- 需求：沙盒容器（LC 原生 SwiftUI，在框架 target）里加「日志」入口，面板要能读主 App 的 LoginLogger、启停 SSH
- 约束：框架不能 import 主 App 类型
- 做法：主 App 提供 `@objc(TDLogPanelHost).makeViewController()`；框架侧 `NSClassFromString` + `perform` 取 VC，用 UIViewControllerRepresentable 放进 sheet
- 坑：面板跑在独立 UIHostingController 里，`@Environment(\.dismiss)` 拿不到外层 SwiftUI sheet → 关闭按钮改发 `NotificationCenter` 通知，由 sheet 容器 `dismiss()`
