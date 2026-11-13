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
- 验证：四条命令输出贴在回复里；cp 覆盖过的文件逐个 grep 本仓补丁标记（如 NetBlock、TD_NET_BLOCK、v0.3.8xx）确认未丢失；**Swift 补丁必须验证「声明存在 + 括号结构正确」**——grep 到补丁文本不等于编译通过，Section 级补丁必须确认插入点在正确的作用域（曾把 Section 插进 footer 内部导致 type-check 超时）
- 违反记录：v0.3.840 编译失败（C7 声明被 cp 覆盖丢失）；v0.3.841 编译失败（M2 State 漏插 + Section 插进 footer）

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

## R-014 环境变量的「语义」必须从上游消费点反推，不得从变量名/相似概念推断
- 条件：设置任何传给上游代码的环境变量（LC_HOME_PATH / HOME / TMPDIR 等）
- 动作：先 `grep -n '<VAR>' 上游源码`，读每一处消费点的拼接逻辑；若上游自己也 setenv 该变量，以那次赋值为准
- 验证：在回复里贴出上游消费点行号 + 拼出的完整路径示例（如 `<HOME>/Documents/Applications/x.app` 存在）
- 违反记录：MEM-007（LC_HOME_PATH 误传 Documents，全屏启动 App bundle not found）

## R-015 删除补丁前必须确认上游该 bug 点是否仍存在
- 条件：合入上游后清理「作废补丁」时
- 动作：对每个待删补丁，在上游原文 grep 该 bug 的特征代码（如 `hostUrlScheme` 字典字面量）；仍在则保留并重放，只在**上游已重写该段**时才删
- 验证：待删补丁清单里每条都附「上游 grep 结果」；`grep -c 'insert nil\|hostUrlScheme' 上游文件` 的输出贴在回复里
- 违反记录：MEM-008（误删 M6 nil 兜底 → 多任务闪退）

## R-016 弹窗关闭按钮必须显式 dismiss
- 条件：写任何 `Button("好"/"确定"/"关闭")` 或 sheet/alert 的确认按钮
- 动作：用 `@Environment(\.dismiss)` 或绑定 isPresented 置 false；禁止空闭包 `{}`
- 验证：`grep -rn 'Button("好") {}'` 全仓应为 0
- 违反记录：MEM-009（照抄上游空闭包，本仓层叠下失效）

## R-017 「对齐上游」必须同时对齐**启动时序与环境变量语义**，不只文件内容
- 条件：每次全量合入上游 / 移植新入口之后
- 动作：逐项核对 `LC_HOME_PATH` / `HOME` / `TMPDIR` / `CFFIXED_USER_HOME` 的赋值点，读上游**消费点**（grep 后看拼接），不要凭名字推断；并核对 `LiveContainerMain` 里那段全局初始化，独立宿主必须在 `TDInitLCGlobals()` 里复刻
- 验证：回复里贴出上游消费点行号 + 本仓拼出的完整路径示例（如 `<HOME>/Documents/Applications/x.app` 在真机上存在）
- 违反记录：MEM-007（LC_HOME_PATH 误传 Documents → 全屏启动 App bundle not found）

## R-018 崩溃路径必须有可观测留痕
- 条件：写/改任何异常处理、扩展失败回调、进程退出路径
- 动作：所有失败分支都必须写一个宿主可读的持久标记（`lcUserDefaults["error"]` + `lcSharedDefaults["lastGuestLaunchError"]` + uptime），不得只走 NSExtensionContext / exit
- 验证：`grep -A12 'static void exceptionHandler' 上游文件` 确认双写；真机崩溃后重启 App 必须看到弹窗
- 违反记录：MEM-010（isLiveProcess 分支不写 error → 弹窗时有时无）

## R-019 cp/写入文件必须用无 `..` 的确切路径，并验证落地
- 条件：合入/重放补丁时复制任何文件
- 动作：目标路径写完整（`<repo>/TDLiveProcess/LC/xxx.m`），不用 `../`；复制后立即 `ls` 目标目录 + `git status --porcelain` 检查新增项
- 验证：新增文件清单与预期一一对应；CI 编译无「file not found in target X」类错误
- 违反记录：MEM-011

## R-020 资源有两份，合入上游必须同步「打包用的那一份」
- 条件：合入上游 Resources/ 下任何资源（Localizable.xcstrings / LCAssets.bundle / lproj 等）
- 动作：①覆盖 vendor 侧；②把差异合并进宿主打包路径（`Resources/Localizable.xcstrings`、`Resources/LCAssets.bundle`）；③跑 `lc_i18n_guard.py .` 与 `bash Resources/Scripts/` 相关校验
- 验证：lc_i18n_guard 输出「缺失 0 | 无 en 0」；真机上设置页不出现任何 `lc.` 开头的键名
- 违反记录：MEM-012

## R-021 i18n 校验必须包含 state 字段
- 条件：合并/新增任何 Localizable 条目
- 动作：`stringUnit.state` 必须是 `translated`（plural 变体逐 case 检查）；`needs_review`/`new` 等同未翻译
- 验证：`python Resources/Scripts/lc_i18n_guard.py .` 输出「缺本地化 0」
- 违反记录：MEM-013

## R-022 看到 recursionInfoArray 即判无限递归，先看被重复的 symbol
- 条件：.ips 出现 `recursionInfoArray` 或 `SIGSEGV` at stack guard
- 动作：读 `recursionInfoArray[0].depth` 与 `keyFrame.symbol`；若 depth > 1000，判定为无限递归，不要去查 nil/布局
- 验证：修复后该 .ips 不再出现，或 depth 归零
- 违反记录：MEM-015

## R-023 iOS 26+ 禁止 swizzle Foundation 的 Swift 桥方法
- 条件：要对 Foundation 类（NSFileManager/NSURLSession 等）做 `method_exchangeImplementations`
- 动作：先用 `if (@available(iOS 26.0, *))` 跳过，或在 hook 内做 thread-local 重入保护；已知 Swift 桥会回调 ObjC selector 造成互相递归的 selector 清单要记录在 MIRROR-DELTAS
- 验证：真机上该功能不崩；`.ips` 无 recursionInfoArray
- 违反记录：MEM-015

## R-024 判断崩溃归属必须逐帧查 imageIndex → usedImages[i].path
- 条件：分析 .ips 的 threads[].frames
- 动作：对关键帧取 `imageIndex`，映射到 `usedImages[imageIndex].path`，区分「本仓二进制 / 访客 bundle / 系统库」；只看 symbol 名会误判归属
- 验证：结论里每个关键帧都标注了所属 image 路径
- 违反记录：MEM-017

## R-025 swizzle 后不得用 `[self hook_xxx]` 作为「原实现」
- 条件：写/移植 method swizzling hook
- 动作：init 时用 `method_getImplementation` 保存真实 IMP，hook 内用函数指针调用；`[self hook_...]` 依赖交换链，第三方再交换一次即成环
- 验证：同进程存在第二份同类 hook 时仍不递归（.ips 无 recursionInfoArray）
- 违反记录：MEM-017

## R-026 移植上游 App 到 framework 时必须核对「被 exclude 的 App 入口文件里定义了什么」
- 条件：把 SwiftUI App 迁到独立宿主，framework target exclude 其 `*App.swift`
- 动作：逐项检查被排除文件中的 `WindowGroup(id:)` / `Scene` / `@main` 侧定义；凡被其他代码 `openWindow(id:)` 引用而本仓未声明者，必须改用自宿主可达路径并打日志
- 验证：多任务/多窗口类功能能真正出现内容，不只剩外壳 UI
- 违反记录：MEM-018

## R-027 不要把宿主真实 UIWindowScene 交给第三方代码
- 条件：给第三方 `SceneDelegate.window` 一类对象提供窗口
- 动作：提供**无 windowScene** 的离屏转发窗口；否则第三方 `requestSceneSessionDestruction(session)` 会销毁宿主场景
- 验证：反复进出相关页面，宿主场景 session 不被销毁（界面不消失）
- 违反记录：MEM-019

## R-028 批量改名三条硬约束
- 条件：对仓库做任何批量重命名
- 动作：①词边界正则，不碰标识符内部子串 ②白名单排除语言标准库调用（如 `re.X(`）③只读镜像（vendor）与生成目录（target/scratch）不参与，误改后 `git checkout --` 还原
- 验证：precommit 全绿；`git status` 中无 vendor/生成目录改动
- 违反记录：MEM-020

## R-029 系统修掉一个原语后，先找同能力的替代实现再断言「功能坏了」
- 条件：某个免越狱原语在特定 iOS 版本失效
- 动作：确认失效码（bad_query: -4）；找社区替代实现（worse_query），按其返回码语义（-1/-2/-4/-5/-6）逐条映射到代码注释与日志；同时提供老用户一次性迁移把新玩法加入默认集合
- 验证：真机上该原语返回 >=0 句柄；失败时日志能直接读出错误码
- 违反记录：MEM-021

## R-030 初始化期持久化必须显式写盘
- 条件：在 `init` 中给带 didSet 的 `@Published` / 存储属性赋值，且该值需要落盘
- 动作：在 init 内直接调用 `UserDefaults.set`（或等价持久化），不要指望属性观察器
- 验证：连续冷启动两次，状态仍在
- 违反记录：MEM-022

## R-031 第三方控制器只挂在自己的容器或独立窗口上
- 条件：把第三方 UIViewController 用 `addChildViewController` 挂到宿主
- 动作：不要挂 SwiftUI 的 `PresentationHostingController`/系统的私有容器；自建普通容器 VC（必要时独立覆盖窗口，并实现 hitTest 穿透）
- 验证：多任务/浮窗能出现画面且不触发 UIKit 层级断言
- 违反记录：MEM-023

## R-032 网络拦截必须覆盖 connectx
- 条件：实现/修改网络禁用类 hook
- 动作：至少覆盖 connect、connectx、sendto、sendmsg、getaddrinfo；安装与首次拦截都要打日志；状态读取以「访客自己的配置文件」为准
- 验证：Console 出现 `[NetBlock] hooks 已安装` 与 `[NetBlock] 已拦截 <syscall>`；目标 App 无法解析/外发
- 违反记录：MEM-024
