# LiveContainer 上游源码镜像（权威副本）

> 本目录是 **LiveContainer 上游源码的完整镜像**，不是本仓的可编译源码。
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
9. `TequilaDashLCUIAdapters/MultitaskFacade.swift` — 多任务 public 门面
   `LCMultitaskLauncher.openVirtualWindow(displayName:bundleId:dataUUID:)`。
   framework 内 `MultitaskWindowManager`/`DataManager`/`SharedModel` 均 internal，
   宿主调不到；门面走 LC 默认的 `DecoratedAppSceneViewController` 手工建窗路径
   （不依赖 SwiftUI `openWindow` 与 `WindowGroup(id:"appView")`）。
10. `project.yml` 主 target 资源：`vendor/LiveContainer/Resources/en.lproj`（folder reference）。
    上游 `Shared.swift:162-166` 的 `String.enBundle` 用 `Bundle(path: path!)` 强解包
    `en.lproj`，缺它则首个未命中本地化键直接崩。
11. `TequilaDashLCUIAdapters/Utilities/LCUtils.m` 的 `liveProcessBundleIdentifier`：
    上游硬编码 `LiveProcess.appex`，本仓产物名是 `TequilaDashLiveProcess.appex`；
    适配为「上游名 → 扫 PlugIns 里 bundleId 以 `.liveprocess` 结尾的 appex → 上游 LC1 猜测链」。

## 同步上游的标准流程

```bash
# 1. 覆盖镜像（保持上游目录名）
robocopy <新版LC> vendor/LiveContainer /MIR /XD .git screenshots
# 2. 看上游改了什么
git diff -- vendor/LiveContainer
# 3. 更新 .upstream-manifest.json
python Resources/Scripts/lc_upstream_manifest.py
# 4. 对照上面的「适配点」逐项检查 TequilaDashLiveProcess/LC/ 是否需要同步
# 5. 跑守卫 + dispatch CI 拿真实类型检查
```

## 为什么镜像放在 `vendor/` 而不参与编译

- xcodegen `project.yml` 的 `sources:` 是**显式 path 列表**，`vendor/LiveContainer` 不在其中，不会被编译。
- 仓库守卫（`swift_ui_copy_guard.py` / `sf_symbol_guard.py` 等）只扫 `TequilaDash/`，镜像在 `vendor/` 下不触发。
- 这样镜像可以 100% 保持上游原样（含上游自己的中文句号/配色/符号），不会被本仓硬规则误伤。
