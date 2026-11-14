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
        // M44d (owner 真机: 手势没了 + 白屏 + 卡死): **预热顺序是根因**.
        // 上游 MultitaskDockManager.init() 第一行就
        //   `keyWindow!.rootViewController!.view.subviews.first!.addSubview(windowHostingView)`
        // —— 强解包链 + "挂到 keyWindow root 的第一个子视图"。若在我们窗口
        // makeKeyAndVisible **之后**才首次触碰 .shared，keyWindow=LC 窗口,
        // rootVC=Tab VC → dock 挂进 SwiftUI 内部视图 (层级错乱=手势死/白屏),
        // subviews.first 结构不符时直接崩溃/卡死。
        // 修法: 在创建 LC 窗口**之前**预热 dock (此时 keyWindow 仍是宿主主窗口,
        // dock 挂到宿主 rootVC.view 上 = 正常层级), 之后 ensureWindow + re-home
        // 把 windowHostingView 搬进 LC 窗口的 guestContainer (同窗口迁移,
        // presenter 链不断)。
        _ = MultitaskDockManager.shared   // 预热: dock 挂到宿主 keyWindow
        show()
        guard let window, let rootVC = window.rootViewController else { return nil }
        if guestContainer == nil {
            let c = UIViewController()
            c.view.backgroundColor = .clear
            guestContainer = c
        }
        // M44c: 容器 view 挂在 rootVC.view 下 (非 window 直挂 —— 游离于 VC 链
        // 之外与 overlay 时代 presenter 断链同构), zPosition 盖过 Tab 内容.
        if guestContainer?.view.superview !== rootVC.view {
            guestContainer?.view.removeFromSuperview()
            guestContainer?.view.frame = rootVC.view.bounds
            guestContainer?.view.autoresizingMask = [.flexibleWidth, .flexibleHeight]
            rootVC.view.addSubview(guestContainer!.view)
            guestContainer?.view.layer.zPosition = 9999
            NSLog("[TD-Multitask] guestContainer re-homed into window.rootVC.view (M44c)")
        }
        guestContainer?.view.frame = rootVC.view.bounds
        // M44b: dock 的 windowHostingView 必须与 DecoratedAppSceneViewController
        // 的 rootVC 同链 —— 从宿主 keyWindow (预热挂点) 搬进 guestContainer.view
        // (同窗口迁移, presenter 链不断).
        let dockHost = MultitaskDockManager.shared.windowHostingView
        if dockHost.superview !== guestContainer?.view {
            dockHost.frame = guestContainer?.view.bounds ?? rootVC.view.bounds
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
