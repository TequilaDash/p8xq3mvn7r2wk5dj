import UIKit
import SwiftUI
import Intents

/// 宿主的 AppDelegate —— **逐行照抄上游 `AppDelegate`**（App/AppDelegate.swift:6-46），
/// 唯一差异是加上 `public` 让宿主能挂 `@UIApplicationDelegateAdaptor`.
///
/// 为什么必须复制而不能继承: 上游 `AppDelegate` 声明为 `@objc class`（internal），
/// Swift 不允许 `public` 类继承 `internal` 类（CI 报 "class cannot be declared public
/// because its superclass is internal"）。改镜像加 `public` 会破坏镜像原样，
/// 所以在这里复制；上游同步时比对下面 6 项即可（每项都标了上游行号）。
///
/// 上游做的 6 件事（App/AppDelegate.swift）:
///   1. `application.shortcutItems = nil`                              (:7)
///   2. 移除 `LCNeedToAcquireJIT` 键                                   (:8)
///   3. `willTerminate` 时若 JIT 弹窗中且未设 LCKeepSelectedWhenQuit,
///      清 `selected`/`selectedContainer`                              (:10-16)
///   4. method_exchangeImplementations 交换 requestSceneSessionActivation
///      → 让新 scene 以全屏弹出                                        (:19-22)
///   5. iOS 升级后清 symbolOffsetCache                                 (:25-33)
///   6. `configurationForConnecting` 设 delegateClass = SceneDelegate.self
///      ← LCTabView 的 @EnvironmentObject sceneDelegate 靠这条系统注入   (:36-40)
///   7. `handlerFor intent` 返回 ViewAppIntentHandler（App Intents）    (:42-46)
public final class LCUIAppDelegate: UIResponder, UIApplicationDelegate {

    public func application(_ application: UIApplication,
                            didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]? = nil) -> Bool {
        application.shortcutItems = nil
        UserDefaults.standard.removeObject(forKey: "LCNeedToAcquireJIT")

        NotificationCenter.default.addObserver(forName: UIApplication.willTerminateNotification, object: nil, queue: .main) { _ in
            if DataManager.shared.model.isJITModalOpen && !UserDefaults.standard.bool(forKey: "LCKeepSelectedWhenQuit") {
                UserDefaults.standard.removeObject(forKey: "selected")
                UserDefaults.standard.removeObject(forKey: "selectedContainer")
            }
        }

        // 让新 scene 以全屏窗口弹出（上游同款 method swizzle）.
        method_exchangeImplementations(
            class_getInstanceMethod(UIApplication.self, #selector(UIApplication.requestSceneSessionActivation(_:userActivity:options:errorHandler:)))!,
            class_getInstanceMethod(UIApplication.self, #selector(UIApplication.hook_requestSceneSessionActivation(_:userActivity:options:errorHandler:)))!
        )

        // iOS 升级后符号偏移缓存失效，清掉.
        if let lastIOSBuildVersion = LCUtils.appGroupUserDefault.string(forKey: "LCLastIOSBuildVersion"),
           let currentVersion = UIDevice.current.buildVersion,
           lastIOSBuildVersion == currentVersion {
            // 同一系统版本，缓存仍有效.
        } else {
            LCUtils.appGroupUserDefault.removeObject(forKey: "symbolOffsetCache")
            LCUtils.appGroupUserDefault.setValue(UIDevice.current.buildVersion, forKey: "LCLastIOSBuildVersion")
        }

        return true
    }

    /// **关键**: 给每个 scene 配 SceneDelegate —— 上游 :36-40 同款.
    public func application(_ application: UIApplication,
                            configurationForConnecting connectingSceneSession: UISceneSession,
                            options: UIScene.ConnectionOptions) -> UISceneConfiguration {
        let configuration = UISceneConfiguration(name: nil, sessionRole: connectingSceneSession.role)
        configuration.delegateClass = SceneDelegate.self
        return configuration
    }

    public func application(_ application: UIApplication, handlerFor intent: INIntent) -> Any? {
        switch intent {
        case is ViewAppIntent: return ViewAppIntentHandler()
        default: return nil
        }
    }
}
