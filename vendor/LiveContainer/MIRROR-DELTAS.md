# 镜像内改动清单（MIRROR-DELTAS）

> `vendor/LiveContainer/` 是上游源码镜像，**原则上不改**。
> 本文件列出**所有**改动过镜像的地方，供每次同步上游时逐条核对与重放。
>
> 校验方式：`python Resources/Scripts/lc_mirror_delta_guard.py`
> （对比当前镜像与 `.upstream-manifest.json`，只允许本文件登记的文件有差异）

## 当前改动（1 处）

| # | 文件 | 上游行号 | 改动 | 原因 | 引入版本 | 真机验证 |
|---|---|---|---|---|---|---|
| M1 | `LiveContainerSwiftUI/Views/AppList/LCAppListView.swift` | `:12`（`class SearchContext`） | 加 `static let shared` | `@ObservedObject` 的默认值在视图重建时重新求值 → 新 `SearchContext` → `query` 归零 → SwiftUI `.searchable` 重新激活搜索框 | v0.3.809 | ✅ 2026-11-11 owner 实测「修复好了」 |
| M1b | 同上 | `:86`（`LCAppListView.searchContext`） | `= SearchContext()` → `= .shared` | 同上 | v0.3.809 | ✅ 同上 |
| M1c | `LiveContainerSwiftUI/Views/LCAltStoreSourcesView.swift` | `:487` | `= SearchContext()` → `= .shared` | 同上 | v0.3.809 | ✅ 同上 |

**三行改动属于同一处修复（M1），必须同时应用，否则共享实例不生效。**

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
