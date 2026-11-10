import UIKit

/// 宿主的 AppDelegate 桥：**完全复用上游 `AppDelegate`**（不重写任何逻辑），
/// 只为满足两件事:
///   1. 宿主不能直接引用 framework 里的 internal `AppDelegate`（Swift 访问控制），
///      所以这里做一个 public 薄壳，宿主用 `@UIApplicationDelegateAdaptor` 挂它.
///   2. 上游 `AppDelegate.application(_:configurationForConnecting:)` 会给每个 scene
///      设 `configuration.delegateClass = SceneDelegate.self`（App/AppDelegate.swift:36-40）——
///      `LCTabView` 的 `@EnvironmentObject var sceneDelegate: SceneDelegate` 正是靠这条
///      系统注入才拿到值。宿主必须走同一条路，否则 LC 原生 UI 首帧就崩.
///
/// 这里**不添加任何上游没有的行为**：didFinishLaunching 与 scene 配置全部继承上游实现.
public final class LCUIAppDelegate: AppDelegate {}
