import Foundation
import UIKit

/// 多任务 public 门面 (LC 同款「虚拟窗口」路径).
///
/// 为什么需要这一层: framework 内 `MultitaskWindowManager` / `DataManager` / `SharedModel`
/// 都是 internal (vendor/LiveContainer/MultitaskSupport/MultitaskAppWindow.swift:23,
/// Utilities/Shared.swift:55,109), 宿主 App 只能调 public 符号. 本文件编进 framework,
/// 与 vendor 镜像隔离 —— 上游更新不动这里.
///
/// 为什么走 DecoratedAppSceneViewController 而不是 MultitaskWindowManager.openAppWindow:
/// 后者用 SwiftUI `@Environment(\.openWindow)` (MultitaskAppWindow.swift:24,31), 要求宿主 App
/// 的 Scene 里声明 `WindowGroup(id: "appView", for: String.self)` 并开启
/// UIApplicationSupportsMultipleScenes; 本仓 App scene 没有该 group, 也不改它.
/// LC 自己的默认模式 (LCMultitaskMode != 1) 正是这条手工建窗路径 (LCUtils.m:84-89), 行为一致.
@available(iOS 16.0, *)
public enum LCMultitaskLauncher {

    /// 在宿主窗口上叠加一个访客虚拟窗口. 返回 false = 找不到宿主 rootVC 或控制器初始化失败.
    @discardableResult
    public static func openVirtualWindow(displayName: String,
                                         bundleId: String,
                                         dataUUID: String) -> Bool {
        guard let hostRoot = keyRootViewController() else {
            NSLog("[LCMultitaskLauncher] no host rootViewController, abort")
            return false
        }
        // ObjC 的 initWindowName:... 在 Swift 侧导入为可失败 init?, 必须 guard let
        // (CI run 42653277259 实测: optional 未解包直接报错).
        guard let controller = DecoratedAppSceneViewController(windowName: displayName,
                                                               bundleId: bundleId,
                                                               dataUUID: dataUUID,
                                                               rootVC: hostRoot) else {
            NSLog("[LCMultitaskLauncher] DecoratedAppSceneViewController init returned nil")
            return false
        }
        controller.view.autoresizingMask = [.flexibleTopMargin, .flexibleLeftMargin,
                                            .flexibleRightMargin, .flexibleBottomMargin]
        controller.view.center = hostRoot.view.center
        return true
    }

    /// 取当前 key window 的 rootViewController (无 key window 时退到窗口列表首项).
    private static func keyRootViewController() -> UIViewController? {
        let scenes = UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }
        for scene in scenes {
            if let keyRoot = scene.windows.first(where: { $0.isKeyWindow })?.rootViewController {
                return keyRoot
            }
            if let root = scene.windows.first?.rootViewController {
                return root
            }
        }
        return nil
    }
}
