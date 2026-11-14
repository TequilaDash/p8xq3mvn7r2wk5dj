//
//  TDLCWindow.swift
//  TequilaDashLCUIAdapters
//
//  本仓适配 (M44, 2026-11-14): 沙盒容器改用 **LC 独占原生窗口** 承载,
//  与上游 LiveContainer "单窗口承载 dock + hosted scene" 完全同构.
//  旧方案 (SwiftUI fullScreenCover + TDGuestOverlay 覆盖窗口 + windowHostingView
//  反复搬家) 会把 _UISceneHostingView 从创建它的窗口里拆走 —— hosted scene 的
//  presenter 链被断, scene 只剩白屏 (owner 长期白屏根因).
//  本窗口就是 keyWindow: dock 的 windowHostingView 自然落在本窗口 rootVC.view
//  里, 不需要任何搬家; 多任务访客 scene 与上游完全同一条渲染链.
//

import UIKit

@objc(TDLCWindowController)
public final class TDLCWindowController: NSObject {
    @objc public static let shared = TDLCWindowController()

    private var window: UIWindow?
    private var guestContainer: UIViewController?
    private var observer: NSObjectProtocol?

    @objc public var hostViewController: UIViewController? {
        return window?.rootViewController
    }

    @objc public func show() {
        ensureWindow()
        guard let window else { return }
        window.isHidden = false
        window.makeKeyAndVisible()
        NotificationCenter.default.post(name: Notification.Name("TDShowSandboxOverlay"), object: nil)
    }

    /// show + 返回**无父级的访客容器 VC**（供 DecoratedAppSceneViewController 的
    /// `[rootVC addChildViewController:self]` 用 —— 0.3.884 .ips 150942 实证：
    /// 直接传 window.rootViewController 会因 "already has a parent" 层级断言闪退）.
    @objc public func showAndGetHost() -> UIViewController? {
        show()
        guard let window else { return nil }
        if guestContainer == nil {
            let c = UIViewController()
            c.view.backgroundColor = .clear
            c.view.frame = window.bounds
            c.view.autoresizingMask = [.flexibleWidth, .flexibleHeight]
            window.addSubview(c.view)
            guestContainer = c
        }
        guestContainer?.view.frame = window.bounds
        // M44b (0.3.886 .ips 162906 实证): DecoratedAppSceneViewController 先
        // `[windowHostingView addSubview:self.view]` 再 `[rootVC addChildViewController:self]`。
        // UIKit 层级检查要求 self.view.superview 的 VC 链 == rootVC；dock 的
        // windowHostingView 原先挂在 SwiftUI 子 hosting VC 下，与传入的容器 VC 不一致
        // → "should have parent ... but requested parent is ..." 断言（仍然闪退）。
        // 修法: 先把 dock 的 windowHostingView 挪进**同一个 LC 窗口内**的 guestContainer.view，
        // 链一致；仍是同窗口（非同窗口搬家才不会断 scene presenter）。
        let dockHost = MultitaskDockManager.shared.windowHostingView
        if dockHost.superview !== guestContainer?.view {
            dockHost.frame = guestContainer?.view.bounds ?? window.bounds
            dockHost.autoresizingMask = [.flexibleWidth, .flexibleHeight]
            guestContainer?.view.addSubview(dockHost)
            NSLog("[TD-Multitask] dock windowHostingView re-homed into LC guestContainer (same window)")
        }
        return guestContainer
    }

    @objc public func hide() {
        guard let window, !window.isHidden else { return }
        window.isHidden = true
        NotificationCenter.default.post(name: Notification.Name("TDHideSandboxOverlay"), object: nil)
    }

    @objc public var isVisible: Bool {
        return !(window?.isHidden ?? true)
    }

    private func ensureWindow() {
        if window != nil { return }
        // 审计 §4.1: scene 选择优先级 keyWindow 所在 scene > foregroundActive > 任意;
        // 后台拉起时两个宽松条件都可能选中非当前 scene (窗口挂错空间 = 前台白屏).
        let keyScene = UIApplication.shared.connectedScenes
            .compactMap { $0 as? UIWindowScene }
            .first { $0.windows.contains(where: { $0.isKeyWindow }) }
        let scene = keyScene
            ?? (UIApplication.shared.connectedScenes.first(where: { $0.activationState == .foregroundActive }) as? UIWindowScene)
            ?? (UIApplication.shared.connectedScenes.first(where: { $0 is UIWindowScene }) as? UIWindowScene)
        guard let scene else { return }
        let w = UIWindow(windowScene: scene)
        w.frame = scene.coordinateSpace.bounds
        w.windowLevel = .normal + 50
        w.backgroundColor = .systemGroupedBackground
        w.rootViewController = TDLCUIHost.makeTabViewController()
        window = w
        observer = NotificationCenter.default.addObserver(
            forName: Notification.Name("TDCloseSandboxContainer"), object: nil, queue: .main
        ) { [weak self] _ in
            self?.hide()
        }
    }
}
