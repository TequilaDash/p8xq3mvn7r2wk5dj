# 镜像内改动清单（MIRROR-DELTAS）

> `vendor/LiveContainer/` 是上游源码镜像，**原则上不改**。
> 本文件列出**所有**改动过镜像的地方，供每次同步上游时逐条核对与重放。
>
> 校验方式：`python Resources/Scripts/lc_mirror_delta_guard.py`
> （对比当前镜像与 `.upstream-manifest.json`，只允许本文件登记的文件有差异）

## 当前改动（M1 系列修复 + M2 新增功能 + M3/M4 上游 bug 修补）

| # | 文件 | 上游行号 | 改动 | 原因 | 引入版本 | 真机验证 |
|---|---|---|---|---|---|---|
| M1 | `LiveContainerSwiftUI/Views/AppList/LCAppListView.swift` | `:12`（`class SearchContext`） | 加 `static let shared` | `@ObservedObject` 的默认值在视图重建时重新求值 → 新 `SearchContext` → `query` 归零 → SwiftUI `.searchable` 重新激活搜索框 | v0.3.809 | ✅ 2026-11-11 owner 实测「修复好了」 |

**M1 / M1b / M1c / M1d 属于同一处修复，必须同时应用。**


**M7 同步上游时**：上游若已给 `lcMainBundle` 做兜底 → 删除本仓改动。

| M5 | `LiveContainerSwiftUI/Views/Settings/LCSettingsView.swift` | `:571-585`（`importCertificate` 失败分支） | 失败弹窗里附带 ZSign 的具体失败原因（`ZSigner.lastZSignLogs`），不再笼统显示「验证证书失败」 | owner 2026-11-11 真机：导入普通证书报「验证证书失败」但不知根因，需要直接看到原因而不是去翻日志 | v0.3.832 | ⏳ 待真机 |

**M5 是诊断增强，不改变导入逻辑。同步上游时：**
- 上游若自己加了失败详情展示 → 删除本仓改动。
- 上游若仍是笼统错误 → 保留。

## 上游 bug 修补（2 处）

| # | 文件 | 上游行号 | 改动 | 原因 | 引入版本 |
|---|---|---|---|---|---|
| M3 | `LiveContainer/LCBootstrap.m` | `:41-45`（`+[NSUserDefaults lcSharedDefaults]`） | `if(!lcUserDefaults)` → `if(!lcSharedDefaults)` | 上游笔误：判的是 `lcUserDefaults`，于是每次调用都重新 `initWithSuiteName:` 建**新** defaults 对象 → 刚写入的证书/开关被下一次读取丢弃。访客路径里 `lcUserDefaults` 恰好在 `:724` 已赋值，所以真实运行时碰巧没暴露；但 `lcSharedDefaults` 早于 `:724` 被调用时（如扩展进程）会返回 nil | v0.3.830 |

**M3 / M4 都是上游自身缺陷，同步上游时应先检查上游是否已修：**
- M3 若上游已改成 `if(!lcSharedDefaults)` → 删除本仓改动。
- M4 若上游已给三处都加了判空 → 删除本仓改动。

## 本仓新增功能（2 处）

| # | 文件 | 改动 | 原因 | 引入版本 | 真机验证 |
|---|---|---|---|---|---|
| M4r | `MultitaskSupport/AppSceneViewController.m` | :86-104（bookmarks 三处 addObject） | `bookmarkDataWithOptions` 返回值判空后再 addObject | 上游 4 处 addObject 只有 containerBookmark 一处判空，另 3 处 nil 即 `insertObject:atIndex:` 崩溃（owner 2026-11-13 五个 .ips 中四个都是它）。合入 9d6ea09b05 时被误删，现已重放 | v0.3.846 | ⏳ 待真机 |
| M17 | `LiveContainer/Tweaks/NSFileManager+GuestHooks.m` | `hook_containerURLForSecurityApplicationGroupIdentifier` 第一个分支 | `lcAppGroupPath` 判空，nil 时不再调 `fileURLWithPath:` | 巢中巢下访客 LCSharedUtils 调用本 hook，而本进程无 app group entitlement → `lcAppGroupPath` nil → `+[NSURL fileURLWithPath:nil]` 抛 NSInvalidArgumentException → SIGABRT（owner 2026-11-13 132227.ips） | v0.3.848 | ⏳ 待真机 |

| M16 | `LiveContainer/Tweaks/NSFileManager+GuestHooks.m` | 全局 IMP 变量 + `NSFMGuestHooksInit` + `hook_createDirectoryAtPath` 体内 | ①hook 内直接调用 init 时保存的真实 IMP，而非 `[self hook_...]`；②iOS 26+ 不装该 swizzle | 巢中巢：访客自身若为另一个 LiveContainer，会二次交换同一 selector，两套 category 同名方法互当「原实现」→ 无限递归（.ips depth=10678，递归帧 imageIndex 全是访客 LiveContainerShared，本仓仅 1 帧）。持真实 IMP 使链条必然终止；iOS 26+ Swift 桥另有单 hook 自递归风险 | v0.3.846 | ⏳ 待真机 |
| M13 | `LiveContainer/LCBootstrap.m` | `exceptionHandler`（:740-760） | 崩溃时**双写** error 到 lcUserDefaults + lcSharedDefaults（lastGuestLaunchError/Uptime），扩展上下文照旧 | 上游只在 `!isLiveProcess` 时写 error 键；`isLiveProcess` 分支交给 NSExtensionContext，宿主读不到 → owner 实测「闪退后下次启动不弹报错，且有无弹窗毫无规律」 | v0.3.843 | ⏳ 待真机 |
| M6r | `MultitaskSupport/AppSceneViewController.m` | :64-83 userInfo 字典 | hostUrlScheme/_bundleId/_dataUUID 全部 nil 兜底 | 上游原文 `@{@"hostUrlScheme": lcAppUrlScheme, ...}` 任一 nil 即 insert-nil 崩溃；宿主 TDHostBoot 不经过 LiveContainerMain 时 lcAppUrlScheme=nil（owner 2026-11-12 .ips 实证，多任务闪退） | v0.3.843 | ⏳ 待真机 |
| M7 | `LiveContainer/LCSharedUtils.m` | `launchToGuestAppWithClassicMode` 内 | `lcMainBundle` 为 nil 时兜底 `NSBundle.mainBundle`（宿主进程 TDHostBoot 不经过 LiveContainerMain） | v0.3.833 | ✅ 已重放至 9d6ea09b05 合入版 |
| C7 | `LiveContainer/Tweaks/Tweaks.h` | 末尾加 NetBlock 两函数声明 | 联网禁用钩子声明（NetworkBlock.m 的接口） | ✅ 已重放 |
| M9 | `LiveContainerSwiftUI/Utilities/LCUtilsExtensions.swift` | `signTweaks` 内 | 移除 checkCodeSignature 预校验（iOS 19+ mmap 未签名 dylib → SIGKILL CODESIGNING），直接全量重签 | v0.3.835 | ✅ 已重放至 9d6ea09b05 合入版 |
| M5 | `LiveContainerSwiftUI/Views/Settings/LCSettingsView.swift` | `importCertificate` 失败分支 | 弹窗附带 ZSigner.lastZSignLogs 具体原因 | v0.3.832 | ✅ 已重放 |
| M2 | `LiveContainerSwiftUI/Views/AppList/AppSettings/LCAppSettingsView.swift` | netBlockEnabled + Section | 联网禁用开关（LC 无此功能），写 TDNetBlock-<relativeBundlePath> | v0.3.825 | ✅ 已重放 |
| M1 | `LiveContainerSwiftUI/Views/AppList/LCAppListView.swift` | SearchContext.shared + 清空 guard | 搜索栏 X 取消重激活（宿主 SwiftUI 会重建视图） | v0.3.816 | ✅ 已重放 |
| M2 | `LiveContainerSwiftUI/Views/AppList/AppSettings/LCAppSettingsView.swift` | ① `@State netBlockEnabled`（:40-42）② `init` 里读 TDNetBlock-&lt;relativeBundlePath&gt;（:50-55）③ 锁定/隐藏节之后加「禁止联网」Section + `onChange` 写回（:249-264） | **LC 上游没有此功能**。owner 2026-11-08 需求：按 App 禁用联网。链路：UI 写 `UserDefaults["TDNetBlock-<selected>"]` → HostGuestEntry.m:43-46 读并 `setenv("TD_NET_BLOCK","1")` → 访客进程 LCBootstrap.m:550 调 `NetBlockGuestHooksInit()`、`:617-623` 调 `NetBlockApplyAfterGuestLoad()` → NetworkBlock.m 拦 BSD `connect`（EPERM） | v0.3.825 | ⏳ 待真机 |

**M2 的键必须与 `HostGuestEntry.m:43-45` 完全一致**：那边先拼 TDNetBlock-&lt;selected&gt;，再用 TDLastGuestBundleId 覆盖——而 TDLastGuestBundleId 全仓无人写入，故实际生效的永远是 TDNetBlock-&lt;selected&gt;，其中 `selected` 由 LCAppModel.swift:324-329 写成 `appInfo.relativeBundlePath`。

## 上游同步时怎么处理（M2）

1. 上游若自己加了「联网禁用」→ **删除本仓 M2**，用上游版本，并从本表移除。
2. 上游若仍未加 → 按上表三处重放（`LCAppSettingsView` 的行号会变，按 `lc.appSettings.lockApp` 这个 Toggle 定位插入点）。
3. 重放后跑 `lc_mirror_guard.py --write` + `lc_mirror_delta_guard.py` 确认只剩 M1*/M2。

## 上游同步时怎么处理

1. 上游若已修 `SearchContext`（比如自己加了 `shared` 或改用 `@StateObject`）→ **删除本仓改动**，用上游版本，并从本表移除 M1。
2. 上游若仍未修 → 重新应用这 3 行（文件路径/行号可能变，按 `class SearchContext` 与 `searchContext: SearchContext =` 定位）。
3. 应用后跑 `lc_mirror_guard.py --write` 重生成 manifest，再跑 `lc_mirror_delta_guard.py` 确认只剩 M1。

## 已回退的改动（历史，勿重犯）

| 文件 | 曾改什么 | 为什么回退 |
|---|---|---|
| `LiveContainerSwiftUI/Views/AppList/LCAppListView.swift`（安装后清理 Inbox IPA 的 catch 块） | 把 `errorInfo = ...; errorShow = true` 改成 `print` | owner 2026-11-11 明确要求「同步上游、稳定优先，不要做破坏性变更」。该报错在 v0.3.814 修好列表问题后不再触发 |

## 不在本清单的改动（在适配层，不碰镜像）

以下都在 `TequilaDashLCUIAdapters/`、`TequilaDashLiveProcess/LC/`、`project.yml`，
**不属于镜像改动**，详见 `ADAPTERS.md` 第 1-19 条。

## 逐文件差异登记（机器可读，`lc_mirror_delta_guard.py` 按此核对）

> 只登记与上游 `9d6ea09b05` 存在字节差异的文件；**路径必须与 manifest 中的相对路径完全一致**。
> 合并上游后若某行变成 WARN「登记过期」，说明该差异已消失，应删除该行。

| # | 文件 | 差异编号 | 说明 | 引入版本 |
|---|---|---|---|---|
| 1 | `LiveContainer/LCBootstrap.m` | M13 + M18 + M22 + M26 | 崩溃双写 error；巢中巢兼容（UI 已移除）；`TDNetBlock` 传参；**动态**检测访客是否引用 `TweakLoader.dylibC` 才建别名 | v0.3.860 |
| 2 | `LiveContainer/LCSharedUtils.m` | M7 | `lcMainBundle` nil 兜底 | v0.3.833 |
| 2b | `LiveContainer/LCMachOUtils.m` | M27 | `insertDylibCommand` 补字符串 NUL 终止（否则注入路径读进旧数据，出现 `TweakLoader.dylibC`） | v0.3.859 |
| 2c | `LiveContainer/LCMachOUtils.h` | M26 | 声明 `LCMachOReferencesString`（只读扫描访客 load command） | v0.3.860 |
| 3b | `LiveContainer/Tweaks/Dyld.m` | M33 | `hideLiveContainer` 诊断日志（hide 标志/路径/被改写的镜像） | v0.3.870 |
| 3 | `LiveContainer/Tweaks/NSFileManager+GuestHooks.m` | M16 + M17 | ①保存真实 IMP 防两套 hook 成环 ②iOS 26+ 不装 createDirectory swizzle ③`lcAppGroupPath` 判空 | v0.3.848 |
| 4 | `LiveContainer/Tweaks/Tweaks.h` | C7 | `NetBlockGuestHooksInit` 声明（宿主联网拦截，上游无） | v0.3.840 |
| 3a | `LiveContainer/utils.h` | M42 | `swizzle`/`swizzleClassMethod` 幂等化（按 class+sel 去重，只交换一次；嵌套反复 swizzle 在 iOS 26 段错误，0.3.881 .ips 实证） | v0.3.882 |
| 5 | `LiveContainerSwiftUI/Models/LCAppInfo.h` | M18 + M22 + M36 + M38 + M39 | `nestedLCCompat` / `netBlock` / `vrootMode` / `isolateTmpDir` / `cowSnapshot` 属性 | v0.3.880 |
| 6 | `LiveContainerSwiftUI/Models/LCAppInfo.m` | M18 + M22 + M36 + M38 + M39 | `nestedLCCompat`(LCNestedLCCompat) / `netBlock`(TDNetBlock) / `vrootMode`(TDVRoot: off|path|full) / `isolateTmpDir`(TDIsolateTMPDIR) / `cowSnapshot`(TDCoWSnapshot) | v0.3.880 |
| 7 | `LiveContainerSwiftUI/Models/LCAppModel.swift` | M18 + M22 + M36 + M38 + M39 | `uiNestedLCCompat`/`uiNetBlock`/`uiVRootMode`/`uiIsolateTmpDir`/`uiCoWSnapshot`；runApp 写 `TDGuestNetBlock` | v0.3.880 |
| 8 | `LiveContainerSwiftUI/Utilities/LCUtilsExtensions.swift` | M9 | `signTweaks` 移除签名预校验 | v0.3.835 |
| 8b | `LiveContainerSwiftUI/Views/AppList/LCAppListView.swift` | M30 | 左上角返回按钮（仅 `TDHostedSandbox` 时显示，通知宿主关闭沙盒容器） | v0.3.862 |
| 8c | `LiveContainerSwiftUI/Views/AppList/LCAppBanner/LCAppBannerViewController.swift` | M35 | 打开 App 设置时显式注入 `SharedModel`/`LCAppSortManager`（Menu 内容闭包丢失 EnvironmentObject 导致 SIGTRAP `EnvironmentObject.error()`） | v0.3.875 |
| 9 | `LiveContainerSwiftUI/Views/AppList/AppSettings/LCAppSettingsView.swift` | M18 + M22 + M36 + M38 + M39 | 「实验性」段：巢中巢兼容 + 禁止联网 + vroot 三态 + TMPDIR 隔离 + APFS 快照 | v0.3.880 |
| 12 | `LiveContainerSwiftUI/Views/Settings/LCSettingsView.swift` | M5 + M25 + M32 | 证书失败详情；沙盒容器专属「日志」二级页（`Documents/sandbox.log`）与「实验性功能」二级页（呈现方式切换） | v0.3.866 |
| 13 | `MultitaskSupport/AppSceneViewController.m` | M4r + M6r + M22 + M31 | bookmarks 判空 + userInfo 兜底 + 传 `tdNetBlock` + 多任务诊断日志（扩展 uuid/pid、hostingVC、scene） | v0.3.865 |

### 本仓新增文件（上游无，不算差异）
- `LiveContainer/Tweaks/NSExtension+GuestHooks.m`
- `TweakLoader/BackgroundTasks.m`

