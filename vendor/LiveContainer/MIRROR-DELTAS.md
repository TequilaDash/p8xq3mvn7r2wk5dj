# 镜像内改动清单（MIRROR-DELTAS）

> `vendor/LiveContainer/` 是上游源码镜像，**原则上不改**。
> 本文件列出**所有**改动过镜像的地方，供每次同步上游时逐条核对与重放。
>
> 校验方式：`python Resources/Scripts/lc_mirror_delta_guard.py`
> （对比当前镜像与 `.upstream-manifest.json`，只允许本文件登记的文件有差异）

## 当前改动（M1 系列 1 处修复 + M2 1 处新增功能）

| # | 文件 | 上游行号 | 改动 | 原因 | 引入版本 | 真机验证 |
|---|---|---|---|---|---|---|
| M1 | `LiveContainerSwiftUI/Views/AppList/LCAppListView.swift` | `:12`（`class SearchContext`） | 加 `static let shared` | `@ObservedObject` 的默认值在视图重建时重新求值 → 新 `SearchContext` → `query` 归零 → SwiftUI `.searchable` 重新激活搜索框 | v0.3.809 | ✅ 2026-11-11 owner 实测「修复好了」 |
| M1b | 同上 | `:86`（`LCAppListView.searchContext`） | `= SearchContext()` → `= .shared` | 同上 | v0.3.809 | ✅ 同上 |
| M1c | `LiveContainerSwiftUI/Views/LCAltStoreSourcesView.swift` | `:487` | `= SearchContext()` → `= .shared` | 同上 | v0.3.809 | ✅ 同上 |
| M1d | `LiveContainerSwiftUI/Views/AppList/LCAppListView.swift` | `:31-48`（`SearchContext.init` 的 debounce sink） | `value.isEmpty` 时提前 `return`，不置 `isTyping = true` | 点搜索栏 X 取消后，sink 仍置 `isTyping` → 视图重算 → `.searchable` 重新激活搜索框（真机实测：先点键盘「完成」再点 X 不会复现） | v0.3.816 | ⏳ 待真机 |

**M1 / M1b / M1c / M1d 属于同一处修复，必须同时应用。**

## 本仓新增功能（2 处）

| # | 文件 | 改动 | 原因 | 引入版本 | 真机验证 |
|---|---|---|---|---|---|
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
