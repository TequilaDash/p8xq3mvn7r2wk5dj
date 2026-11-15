//
//  TDLCWindow.swift
//  TequilaDashLCUIAdapters
//
//  本仓适配 (M44, 2026-11-15 重写): 沙盒容器改为 **宿主主窗口根控制器替换**,
//  与上游 LiveContainer "单窗口承载 dock + hosted scene" 完全同构, 而不是
//  新开一个 full-screen 顶层窗口 —— 0.3.888 实测三个回归都源于后者:
//    ① 其它界面无法触摸 (顶层窗口截获全部触摸);
//    ② 多任务被强制全屏 (Decorated frame=bounds + LC 独占窗口);
//    ③ 手势/界面不显示 (窗口层级把宿主 SwiftUI 盖在下面).
//  根因回顾: 上游 dock + hosted scene 全部住在 LC 自己的 **主窗口** 里,
//  我们是把内容拆进 SwiftUI fullScreenCover / 独立 UIWindow 再搬家,
//  才一路引入层级断言和白屏. 本版彻底回到上游结构:
//    - show(): 记录宿主当前 rootVC, 换成 TDLCUIHost.makeTabViewController().
//    - hide(): 还原宿主 rootVC.
//    - DecoratedAppSceneViewController 的 rootVC = 该主窗口 rootVC (无父级,
//      与 dock windowHostingView 的 superview 一致).
//

import UIKit

@objc(TDLCWindowController)
public final class TDLCWindowController: NSObject {
    @objc public static let shared = TDLCWindowController()

    private var savedHostRoot: UIViewController?
    private var guestContainer: UIViewController?
    private var observer: NSObjectProtocol?

    private var hostWindow: UIWindow? {
        for scene in UIApplication.shared.connectedScenes {
            guard let ws = scene as? UIWindowScene else { continue }
            if let w = ws.windows.first(where: { $0.isKeyWindow }) { return w }
        }
        return nil
    }

    @objc public var hostViewController: UIViewController? {
        return hostWindow?.rootViewController
    }

    @objc public func show() {
        guard let w = hostWindow else { return }
        if savedHostRoot == nil {
            savedHostRoot = w.rootViewController
        }
        let root = TDLCUIHost.makeTabViewController()
        ensureObserverInstalled()
        w.rootViewController = root
        w.makeKeyAndVisible()
        NotificationCenter.default.post(name: Notification.Name("TDShowSandboxOverlay"), object: nil)
    }

    @objc public func hide() {
        guard let w = hostWindow, let saved = savedHostRoot else { return }
        w.rootViewController = saved
        savedHostRoot = nil
        w.makeKeyAndVisible()
        guestContainer = nil
        NotificationCenter.default.post(name: Notification.Name("TDHideSandboxOverlay"), object: nil)
    }

    @objc public var isVisible: Bool {
        return savedHostRoot != nil
    }

    /// show + 返回主窗口 root VC (DecoratedAppSceneViewController 的 rootVC).
    /// 该 VC 无父级 (窗口 root), 且 dock 的 windowHostingView 已挪进其 view,
    /// 使 UIKit 层级检查 superview 链与 rootVC 一致 (M44b 同类修复).
    @objc public func showAndGetHost() -> UIViewController? {
        show()
        guard let root = hostViewController else { return nil }
        let dockHost = MultitaskDockManager.shared.windowHostingView
        if dockHost.superview !== root.view {
            dockHost.frame = root.view.bounds
            dockHost.autoresizingMask = [.flexibleWidth, .flexibleHeight]
            root.view.addSubview(dockHost)
            NSLog("[TD-Multitask] dock windowHostingView re-homed into host root VC (main window)")
        }
        return root
    }

    @objc public func ensureObserverInstalled() {
        guard observer == nil else { return }
        observer = NotificationCenter.default.addObserver(
            forName: Notification.Name("TDCloseSandboxContainer"), object: nil, queue: .main
        ) { [weak self] _ in
            self?.hide()
        }
    }
}
