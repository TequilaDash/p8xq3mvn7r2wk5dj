# 本仓对 LiveContainer 的适配点清单（ADAPTERS）

> 本目录（`vendor/LiveContainer/`）是 **LiveContainer 上游源码的完整镜像**，不是本仓的可编译源码。
> 镜像本身逐文件与上游一致（`README.md` 即上游原文）；本仓的所有适配差异记录在**本文件**。
> 目的：以后同步上游更新时，可以直接把新版 LC 源码覆盖进来，
> `diff -r vendor/LiveContainer <新版>` 就能看清上游改了什么，再逐项对照下面的适配清单。
> 我们不是分叉：交互、弹窗、启动链、数据模型都以 LC 为准，差异只在本仓必需的适配点。

## 镜像来源与版本

| 项 | 值 |
|---|---|
| 本地参照树 | `C:/Users/xcrad/.omp/work/ref/lc_rev`（LC 上游摊平副本） |
| 镜像时间 | 2026-11-09 |
| 文件数 | 318 |
| 校验清单 | `.upstream-manifest.json`（每个文件 SHA256 前 16 位） |
| 上游工程参照 | `LiveContainer.xcodeproj/project.pbxproj`（target / build settings 的权威定义） |

上游目录（保持原名，便于 diff）：

```
LiveContainer/          27 个源文件 — LC 核心启动栈 (LCBootstrap/LCSharedUtils/LCMachOUtils/Tweaks/*)
LiveContainerSwiftUI/   44 个源文件 — SwiftUI 层 (LCTabView/LCAppModel/LCAppInfo/LCSettingsView/AppList/*)
MultitaskSupport/       17 个源文件 — 多任务 / 虚拟窗口 / PiP
TweakLoader/             4 个源文件 — Tweak 注入加载器 (dylib)
LaunchAppExtension/      4 个源文件 — 启动扩展
LiveProcess/             2 个源文件 — 扩展入口
ShareExtension/          9 个源文件 — 分享扩展
SideStoreSupport/       10 个源文件 — SideStore 支持
TestJITLess/             1 个源文件
fishhook/  litehook/  ZSign/  xcconfigs/  Resources/
```

## 本仓与上游的对应关系

| 上游 | 本仓 | 关系 |
|---|---|---|
| `LiveContainer/` | `TequilaDashLiveProcess/LC/` | **已搬 + 适配**（见下） |
| `LiveProcess/` | `TequilaDashLiveProcess/`（main.m / Info.plist / entitlements） | **已搬 + 适配** |
| `fishhook/` | `vendor/fishhook/` | 原样 |
| `litehook/` | `vendor/litehook/` | 原样 |
| `ZSign/` | `ZSign/` | 已搬 + 适配（tequiladash wrapper） |
| `LiveContainerSwiftUI/` | `TequilaDash/Views/` 等 | **用本仓 SwiftUI 重写**（UI 现代化要求），行为/结构对齐 LC |
| `MultitaskSupport/` | 待接入 | 见 `docs/LC_UPSTREAM_SYNC.md` 进度表 |
| `TweakLoader/` | 待接入 | `LCBootstrap.m:611-623` 的 dlopen 钩子已就位，缺 dylib target |
| 其余扩展 | 待评估 | 按需 |

## 已搬部分的本仓适配点（同步上游时必须保留）

这些是本仓相对 LC 上游的**有意差异**，覆盖镜像前先确认：

1. `TequilaDashLiveProcess/LC/LCBootstrap.m`
   - 家目录路径：`LC_HOME_PATH` 直接传 `Documents/SandboxApps` 根，不再拼 `/Documents`（本仓目录模型）。
   - 不写 `LCAppInfo.plist`，直接读访客自己的 `Info.plist`（`:289-291`）。
   - `[LCBootstrap][stepN]` 分步 NSLog（可诊断性改造，崩溃取证用）。
   - `exceptionHandler` / `invokeAppMain` 返回路：把完整错误串写共享 suite 的 `lastGuestLaunchError` + `lastGuestLaunchErrorUptime`（本仓 iOS 26 扩展跨进程需要）。
2. `TequilaDashLiveProcess/main.m` — 扩展入口类名改 `TequilaDashLiveProcessHandler`。
3. `TequilaDash/HostGuestEntry.m` — 双模入口（本仓特有，LC 用 `-e _LiveContainerMain`）。
4. `ZSign/tequiladash_wrapper.mm` — 本仓签名器桥接（LC 无此文件）。
5. `TequilaDashLCUIAdapters/Utilities/LCUtils.m` — **编译用适配副本**，替代镜像里的
   `LiveContainerSwiftUI/Utilities/LCUtils.m`（该镜像文件在 framework target 的 sources 里被
   `excludes` 排除）。三处差异：
   - `#import <IOKit/IOKitLib.h>` 与 `isTXMScriptRequired` 的 IOKit 调用用
     `#if TARGET_OS_MACCATALYST || TARGET_OS_OSX` 包住（上游链接 MacOSX SDK 的
     IOKit.framework，本仓只编 iOS，iOS SDK 无公开 IOKit 头）。
   - 三个 `../../` 相对 include 改裸名（`LCSharedUtils.h` /
     `DecoratedAppSceneViewController.h` / `zsigner.h`），由 `HEADER_SEARCH_PATHS` 解析。
   同步上游 LCUtils.m 时把这三处差异重新应用到适配副本。
6. `project.yml` 的 `LiveContainerSwiftUI` framework target：模块名必须为
   `LiveContainerSwiftUI`（3 个多任务 ObjC 文件 import 生成的 `LiveContainerSwiftUI-Swift.h`），
   `SWIFT_VERSION: "5.0"`（上游 pbxproj:1197/1240 原值），排除上游 `@main` 入口
   `App/LiveContainerSwiftUIApp.swift`（宿主入口是 `HostGuestEntry.m → TDHostBoot()`）。
   LC 核心 `.m` 不编进 framework（主 App 已编适配副本），用 `-Wl,-undefined,dynamic_lookup`
   运行时解析，避免同进程两份 ObjC 类。
7. `TequilaDashLiveProcess/LC/LCBootstrap.m` **启动闪退加固四处**（对上游同名文件的有意加固）：
   - `docPath`：`getenv("LC_HOME_PATH")` 为 NULL 时回落 `HOME`，两者皆空则返回错误串
     （原写法 `[NSString stringWithUTF8String:NULL]` 是 UB）。
   - `newHomePath` 为空时不 `setenv`（`setenv(name, NULL, 1)` 是 UB）。
   - `lcAppUrlScheme` 改用 `firstObject` 链取（原 `[0]` 在 `CFBundleURLTypes` 为空时越界崩溃）。
   - `LC_HOME_PATH` 的 `setenv` 前判 `getenv("HOME")` 非空。
   另补 `Localization.h/.m`（上游有、原适配副本缺失，`AppSceneViewController.m` 依赖 `NSString.loc`）。
8. `TequilaDashLiveProcess/main.m` **键映射加固**：`setObject:` 逐项判空（
   `setObject:nil` 抛 `NSInvalidArgumentException`，是启动闪退真因之一），
   并同时接受 LC 原键名 `hostUrlScheme` / `selected` / `selectedContainer`
   （LC 的 MultitaskSupport 只发这三个）。
9. `TequilaDashLCUIAdapters/MultitaskBridge.h/.m` — 多任务入口
   `int TDMultitaskOpenVirtualWindow(displayName, bundleId, dataUUID)`（编进 framework）。
   走 LC 默认的 `DecoratedAppSceneViewController` 手工建窗路径（不依赖 SwiftUI
   `openWindow` 与 `WindowGroup(id:"appView")`）。宿主侧用 `@_silgen_name` 声明调用。
   **不要**在主 App 里 `import LiveContainerSwiftUI`：会把 framework 的 ObjC 头拉进同一
   翻译单元，与既有桥接头重复定义枚举（`LCUtils.h` 的 `Unknown` / `LCAppInfo.h` 的
   `Disabled`，CI run 42657238035 实测）。
10. `project.yml` 主 target 资源：`vendor/LiveContainer/Resources/en.lproj`（folder reference）。
    上游 `Shared.swift:162-166` 的 `String.enBundle` 用 `Bundle(path: path!)` 强解包
    `en.lproj`，缺它则首个未命中本地化键直接崩。
11. `TequilaDashLCUIAdapters/Utilities/LCUtils.m` 的 `liveProcessBundleIdentifier`：
    上游硬编码 `LiveProcess.appex`，本仓产物名是 `TequilaDashLiveProcess.appex`；
    适配为「上游名 → 扫 PlugIns 里 bundleId 以 `.liveprocess` 结尾的 appex → 上游 LC1 猜测链」。
12. **启动崩溃检测（本仓特有，上游无）** —— 无 app group 时 `LCSharedUtils.appGroupID`
    返回 `"Unknown"`，扩展容器与宿主不共享 suite，`lastGuestLaunchError` 跨进程读不到。
    替代链路（三处，缺一不可）：
    - `TequilaDash/Engine/LaunchGuest.m`：`TDLaunchGuestRestart(NSString *pendingMarkerPath)`
      在重启前落 `<可用容器>/.td_guest_launch_pending` 并把绝对路径记进标准 defaults
      的 `TDGuestLaunchMarker`。
    - `TequilaDashLiveProcess/LC/LCBootstrap.m`：`invokeAppMain` 里紧挨 `// Go!`
      （沙盒接管 + dyld 注入 + bundle 装载 + 入口点解析全部通过之后）删该文件。
    - `TequilaDash/Views/GuestLaunchError.swift`：宿主启动时若文件仍在 = 上次崩在
      启动阶段，生成中文诊断串交给 `GuestLaunchErrorSheet`。
13. `project.yml` 的 `TestJITLess` target（`library.dynamic`，源 `vendor/LiveContainer/TestJITLess`
    原样，`EXECUTABLE_PREFIX: ""` 让产物叫 `TestJITLess.dylib`）+ 主 App embed。
    消费方是上游 `LiveContainerSwiftUI/Utilities/LCUtils.m:265-266`：按
    `<主Bundle>/Frameworks/TestJITLess.dylib` 拷进临时目录再做注入试验，不嵌入则该诊断路径静默失效。
    与 `TweakLoader` 的区别：TweakLoader 是访客进程内的 tweak 装载器（LCBootstrap dlopen），
    TestJITLess 只是 JIT-less 能力探针（constructor 置 `LC_JITLESS_TEST_LOADED`）。

14. **JIT-less 诊断入口桥（本仓特有，上游无）** —— 上游 `LCJITLessDiagnoseView` 只在
    `LCSettingsView` 里可达，本仓宿主不渲染上游设置页。桥接三件套：
    - `TequilaDashLCUIAdapters/JITLessDiagnoseBridge.swift`（编进 framework）：
      `@objc class TDJITLessDiagnoseHost.makeViewController()`，包 `LCJITLessDiagnoseView()`
      并注入 `DataManager.shared.model`（缺它 `@EnvironmentObject` 首帧崩）。
    - `TequilaDash/Views/JITLessDiagnoseView.swift`（宿主）：`NSClassFromString` 反射拿
      UIViewController，反射不到显示 `ContentUnavailableView`，不留假入口。
    - `TequilaDash/Views/MoreView.swift`：「元数据与诊断」组新增「JIT-less 诊断」行。
    另注意：新 dylib target 必须整段覆盖顶层 `OTHER_LDFLAGS`（含主 App 专用的
    `$(DERIVED_FILE_DIR)/SAP/lib/libunicorn.a`），否则继承后链接期找不到文件
    （CI run 42663291263 实测，对齐 Tunnel 的覆盖写法）。

## 同步上游的标准流程

```bash
# 1. 覆盖镜像（保持上游目录名）
robocopy <新版LC> vendor/LiveContainer /MIR /XD .git screenshots
# 2. 看上游改了什么
git diff -- vendor/LiveContainer
# 3. 更新 .upstream-manifest.json
python Resources/Scripts/lc_mirror_guard.py --write   # 重新生成 .upstream-manifest.json
# 4. 对照上面的「适配点」逐项检查 TequilaDashLiveProcess/LC/ 是否需要同步
# 5. 跑守卫 + dispatch CI 拿真实类型检查
```

## 为什么镜像放在 `vendor/` 而不参与编译

- xcodegen `project.yml` 的 `sources:` 是**显式 path 列表**，`vendor/LiveContainer` 不在其中，不会被编译。
- 仓库守卫（`swift_ui_copy_guard.py` / `sf_symbol_guard.py` 等）只扫 `TequilaDash/`，镜像在 `vendor/` 下不触发。
- 这样镜像可以 100% 保持上游原样（含上游自己的中文句号/配色/符号），不会被本仓硬规则误伤。

15. **dylib target 三件套（v0.3.799 真机崩溃教训）**：xcodegen 的 `target:` 依赖默认
    `link:true`，会把 `library.dynamic` 写进主二进制的 LOAD_DYLIB（`@rpath/...`），
    同时产物落在 `.app/` 根而非 `Frameworks/` —— 两个条件叠加 = dyld 启动即 abort。
    上游不链接这两个 dylib（纯 dlopen），所以必须 `link:false` + postBuild 挪位。
    另：启动前全量重签是本仓历史实现，上游有 `checkCodeSignature` 跳过判断
    （LCAppInfo.m:369-380），v0.3.799 起对齐。

16. **`SearchContext` 改共享实例（v0.3.809，镜像内改动）**
    `LiveContainerSwiftUI/Views/AppList/LCAppListView.swift:12` 加 `static let shared`，
    并把 `:86`（LCAppListView）与 `LCAltStoreSourcesView.swift:487` 的
    `@ObservedObject var searchContext = SearchContext()` 改成 `= .shared`。
    原因：`@ObservedObject` 的默认值在视图重建时重新求值 → 新 `SearchContext` →
    `query` 回到 ""，SwiftUI `.searchable` 观察到变化会重新激活搜索框，
    表现为「取消搜索后键盘又自动进入搜索态」。上游作为 App 根不重建所以没暴露，
    本仓经 `UIHostingController` + `TabView` 承载会重建。

17. **两个扩展自带 LC 核心（独立进程隔离）**
    `ShareExtension` 与 `LaunchAppExtension` 是独立进程，主 App 里静态编入的 `LCSharedUtils`
    不在那个进程。上游靠 `LiveContainerShared.framework`（真 dylib，两进程各自加载）解决；
    本仓在 `project.yml` 的扩展 sources 里补 `TequilaDashLiveProcess/LC/LCSharedUtils.m` +
    `Localization.m`，并新增 `TequilaDashLCUIAdapters/Extensions/LCSharedGlobalsShim.m`
    提供 `LCSharedUtils.m` 需要的 4 个全局（`lcUserDefaults`/`lcSharedDefaults`/`lcAppUrlScheme`/
    `lcMainBundle`）+ `NSUserDefaults` category。
    **不整个编 `LCBootstrap.m`**（947 行，含 `LiveContainerMain`/`appMain` 主 App 专用符号）。
    `ShareExtension/main.m` 已自带 `lcMainBundle`，故桩用 `TD_EXT_HAS_LC_MAIN_BUNDLE` 宏跳过。

18. **扩展的 Info.plist 必须 `GENERATE_INFOPLIST_FILE: YES`**
    上游 pbxproj（`17CAE623/624`）用 `GENERATE_INFOPLIST_FILE: YES` + `INFOPLIST_FILE` 合并，
    Xcode 补 `CFBundlePackageType` 等必需键。只给 `INFOPLIST_FILE` 时 AppIntents 编译期解析失败
    （`Unable to parse Info.plist` → `AppIntentsSSUTraining` 非零退出）。

19. **app group 值用 SideStore/AltStore 的固定 group**
    照抄上游 `xcconfigs/Global.xcconfig:14-15`：
    `group.com.SideStore.SideStore` + `group.com.rileytestut.AltStore`
    （Release 时 `DEVELOPMENT_TEAM_SUFFIX` 为空）。侧载工具会注入这两个 group；
    自签/免费账号没有 → 删掉这两项即可（主 App 其余功能不受影响）。

## LC 核心适配副本差异（2026-11-12 全量合入上游 9d6ea09b05 后）

适配副本 `<prefix>LiveProcess/LC/`（29 文件）：逐字节相同 26、有差异 2、本仓新增 1。

| # | 文件 | 差异 | 原因 | 同步上游时 |
|---|---|---|---|---|
| C1 | （联网禁用补丁落在 vendor 的 Bootstrap，见 MIRROR-DELTAS） | 适配副本与上游一致 | 联网禁用 | vendor 侧维护 |
| C2 | `LCMachOUtils.m` | ①头文件直取 LCMachOUtils.h/litehook.h ②验签失败诊断日志 | 搬运集不含 LCUtils.h；诊断定位签名问题 | ①保留 ②上游若加诊断则删 |
| C3 | `Tweaks/NetworkBlock.m` | 本仓新增文件 | 联网禁用实现 | 保留 |

（旧 C1 面包屑/getenv 防护/writeLCAppInfoIfNeeded、C3-C7 头文件路径差异已被上游
9d6ea09b05 重构吸收或不再需要，全部移除。Tweaks 其余文件与上游逐字节一致。）

