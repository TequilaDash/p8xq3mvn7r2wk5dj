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

@objc public final class TDLCWindowController: NSObject {
    @objc public static let shared = TDLCWindowController()

    private var window: UIWindow?
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

    /// show + 返回窗口 root VC（供 LCUtils 的 DecoratedAppSceneViewController 当 rootVC）.
    @objc public func showAndGetHost() -> UIViewController? {
        show()
        return hostViewController
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
