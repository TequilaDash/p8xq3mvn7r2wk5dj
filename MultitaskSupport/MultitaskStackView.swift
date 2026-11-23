//
//  MultitaskStackView.swift
//  LiveContainer
//
//  图五: 原生 springboard 风格的**堆叠后台界面**.
//  双击辅助触控进入 -> 看到所有在跑的多任务窗口(卡片堆叠, 后一个压前一个),
//  点卡片进入该 app 的多任务窗口, 卡片上滑删除该窗口(结束访客进程).
//  设计:
//   · 优先复用 Dock 的顺序, 同时收集实际窗口, 关闭 Dock 也不会漏掉后台
//   · 卡片左右滑动切换, 当前卡片置顶, 相邻卡片始终露出可点击的部分
//   · 点卡片恢复对应窗口; 原生 iPad 窗口激活自己的 scene
//   · 上滑走真实 closeWindow/terminate 路径, 不用删列表冒充关闭
//

import Foundation
import SwiftUI
import UIKit
import Combine

@available(iOS 16.0, *)
@objcMembers
public class MultitaskStackManager: NSObject, ObservableObject {
    @Published public private(set) var isVisible = false
    @Published public var selectedIndex = 0
    @Published private(set) var apps: [DockAppModel] = []
    @Published private(set) var message: String?

    // A window retains its root controller, and the manager owns both until
    // dismissal. Retaining only host.view does not retain a hosting controller.
    private var hostingController: UIHostingController<AnyView>?
    private var hostingWindow: UIWindow?
    private weak var previousKeyWindow: UIWindow?
    private var pendingPresentation = false
    private var selectedUUID: String?
    private var closingControllers: [String: ObjectIdentifier] = [:]
    // These survive removal of a card. A menu action is bound to the launch
    // it displayed, never merely to a container a newer guest might reuse.
    private var displayedControllers: [String: AppSceneViewController] = [:]
    private var restartingControllers: [String: ObjectIdentifier] = [:]
    private var dockSubscription: AnyCancellable?
    // Static pictures taken while the guest windows are still on screen. The
    // cards show what each app actually looks like, shrunk, instead of an icon.
    private var previews: [String: UIView] = [:]
    private static let requestKey = "LCPendingAppStackRequest"
    static let enabledKey = "TDAppStackEnabled"

    /// The stack is a real feature with a real switch; both the button and the
    /// settings page read the same app-group key.
    static var isEnabled: Bool {
        guard let defaults = UserDefaults.lcShared() else { return true }
        guard defaults.object(forKey: enabledKey) != nil else { return true }
        return defaults.bool(forKey: enabledKey)
    }

    public static let shared = MultitaskStackManager()

    private override init() {
        super.init()
        let center = NotificationCenter.default
        center.addObserver(self, selector: #selector(sceneDidActivate(_:)), name: UIScene.didActivateNotification, object: nil)
        center.addObserver(self, selector: #selector(sceneWillDeactivate(_:)), name: UIScene.willDeactivateNotification, object: nil)
        center.addObserver(self, selector: #selector(sceneDidDisconnect(_:)), name: UIScene.didDisconnectNotification, object: nil)
        center.addObserver(self, selector: #selector(applicationDidActivate), name: UIApplication.didBecomeActiveNotification, object: nil)
        center.addObserver(self, selector: #selector(windowsDidChange(_:)), name: UIWindow.didBecomeVisibleNotification, object: nil)
        center.addObserver(self, selector: #selector(windowsDidChange(_:)), name: NSNotification.Name("LCMultitaskWindowsChanged"), object: nil)
        dockSubscription = MultitaskDockManager.shared.$apps
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in
                guard let self, self.isVisible || self.pendingPresentation else { return }
                self.refreshApps()
            }
        readStoredRequest()
        presentIfPossible()
    }

    /// Repeated delivery is idempotent. A background host keeps the request
    /// pending until it has an active scene and an actual content window.
    @objc public func present() {
        DispatchQueue.main.async {
            guard Self.isEnabled else { return }
            self.readStoredRequest()
            self.pendingPresentation = true
            self.message = nil
            self.presentIfPossible()
        }
    }

    @objc public func dismiss() {
        DispatchQueue.main.async {
            self.pendingPresentation = false
            self.clearStoredRequest()
            self.detachWindow()
        }
    }

    private func readStoredRequest() {
        guard let defaults = UserDefaults.lcShared() else { return }
        guard let request = defaults.dictionary(forKey: Self.requestKey) else { return }
        guard let timestamp = request["timestamp"] as? TimeInterval,
              let identifier = request["identifier"] as? String, !identifier.isEmpty else {
            clearStoredRequest()
            return
        }
        let age = Date().timeIntervalSince1970 - timestamp
        guard age >= -5, age < 30 else {
            clearStoredRequest()
            return
        }
        pendingPresentation = true
    }

    private func clearStoredRequest() {
        guard let defaults = UserDefaults.lcShared() else { return }
        guard defaults.object(forKey: Self.requestKey) != nil else { return }
        defaults.removeObject(forKey: Self.requestKey)
        defaults.synchronize()
    }

    private func presentIfPossible() {
        guard pendingPresentation else { return }
        if let window = hostingWindow, !window.isHidden,
           window.windowScene?.activationState == .foregroundActive,
           hostingController?.viewIfLoaded?.window === window {
            refreshApps()
            pendingPresentation = false
            clearStoredRequest()
            return
        }
        let windows = UIApplication.shared.connectedScenes
            .compactMap { $0 as? UIWindowScene }
            .filter { $0.activationState == .foregroundActive && $0.session.role == .windowApplication }
            .flatMap(\.windows)
            .filter { $0 !== hostingWindow && !$0.isHidden && $0.alpha > 0 && $0.rootViewController != nil && $0.windowLevel == .normal && !$0.bounds.isEmpty }
        guard let target = windows.first(where: \.isKeyWindow) ?? windows.first,
              let scene = target.windowScene else { return }

        detachWindow()
        refreshApps()
        focus(index: max(0, apps.count - 1))
        let host = UIHostingController(rootView: AnyView(MultitaskStackView().environmentObject(self)))
        host.view.backgroundColor = .clear
        let window = UIWindow(windowScene: scene)
        window.frame = target.frame
        window.backgroundColor = .clear
        window.windowLevel = UIWindow.Level(rawValue: UIWindow.Level.alert.rawValue + 1)
        window.rootViewController = host
        previousKeyWindow = scene.windows.first(where: \.isKeyWindow) ?? target
        hostingController = host
        hostingWindow = window
        window.makeKeyAndVisible()
        guard !window.isHidden, host.view.window === window,
              scene.activationState == .foregroundActive else {
            detachWindow()
            return
        }
        isVisible = true
        pendingPresentation = false
        clearStoredRequest()
        NSLog("[TDHome] app stack attached: scene=%@ cards=%ld", scene.session.persistentIdentifier, apps.count)
    }

    private func detachWindow() {
        let previous = previousKeyWindow
        hostingWindow?.isHidden = true
        hostingWindow?.rootViewController = nil
        hostingWindow?.windowScene = nil
        hostingController = nil
        hostingWindow = nil
        previousKeyWindow = nil
        isVisible = false
        apps.removeAll()
        previews.removeAll()
        displayedControllers.removeAll()
        focus(index: 0)
        if let previous, !previous.isHidden, previous.windowScene?.activationState == .foregroundActive {
            previous.makeKey()
        }
    }

    @objc private func applicationDidActivate() {
        readStoredRequest()
        presentIfPossible()
    }

    @objc private func sceneDidActivate(_ notification: Notification) {
        applicationDidActivate()
    }

    @objc private func sceneWillDeactivate(_ notification: Notification) {
        guard let scene = notification.object as? UIWindowScene, hostingWindow?.windowScene === scene else { return }
        pendingPresentation = isVisible || pendingPresentation
        detachWindow()
    }

    @objc private func sceneDidDisconnect(_ notification: Notification) {
        sceneWillDeactivate(notification)
        presentIfPossible()
    }

    @objc private func windowsDidChange(_ notification: Notification) {
        // makeKeyAndVisible posts synchronously while presentation is mounting.
        if let window = notification.object as? UIWindow, window === hostingWindow { return }
        if isVisible { refreshApps() }
        presentIfPossible()
    }

    // Dock registration is disabled with the Dock setting. Traverse the real
    // controller hierarchy as well, including native scenes and minimized views.
    private func appControllers() -> [AppSceneViewController] {
        var result: [AppSceneViewController] = []
        var indices: [String: Int] = [:]
        func visit(_ controller: UIViewController) {
            if let app = controller as? AppSceneViewController,
               let uuid = app.dataUUID, !uuid.isEmpty {
                if let index = indices[uuid] {
                    let old = result[index]
                    if (closingControllers[uuid] == ObjectIdentifier(old) && closingControllers[uuid] != ObjectIdentifier(app)) || (old.isTerminated && !app.isTerminated) {
                        result[index] = app
                    }
                } else {
                    indices[uuid] = result.count
                    result.append(app)
                }
            }
            for child in controller.children { visit(child) }
            if let presented = controller.presentedViewController { visit(presented) }
        }
        for scene in UIApplication.shared.connectedScenes.compactMap({ $0 as? UIWindowScene }) {
            for window in scene.windows where window !== hostingWindow {
                if let root = window.rootViewController { visit(root) }
            }
        }
        for app in MultitaskDockManager.shared.apps {
            if let decorated = app.view?._viewDelegate() as? DecoratedAppSceneViewController {
                visit(decorated)
            }
        }
        return result
    }

    private func decoratedController(for controller: AppSceneViewController) -> DecoratedAppSceneViewController? {
        var parent = controller.parent
        while let current = parent {
            if let decorated = current as? DecoratedAppSceneViewController { return decorated }
            parent = current.parent
        }
        return nil
    }

    private func currentAppUUID() -> String? {
        // iOS 的后台里当前 app 一定在最右边; 靠 key window 找出正在显示的那个访客窗口.
        let keyWindow = UIApplication.shared.connectedScenes
            .compactMap { $0 as? UIWindowScene }
            .filter { $0.activationState == .foregroundActive }
            .flatMap(\.windows)
            .first(where: { $0.isKeyWindow && $0 !== hostingWindow })
        guard let keyWindow else { return nil }
        for controller in appControllers() {
            if let view = controller.viewIfLoaded, view.window === keyWindow { return controller.dataUUID }
            if let decorated = decoratedController(for: controller)?.viewIfLoaded, decorated.window === keyWindow {
                return controller.dataUUID
            }
        }
        return nil
    }

    private func refreshApps() {
        let controllers = appControllers()
        let byUUID = Dictionary(uniqueKeysWithValues: controllers.compactMap { controller -> (String, AppSceneViewController)? in
            guard let uuid = controller.dataUUID else { return nil }
            return (uuid, controller)
        })
        displayedControllers = byUUID
        closingControllers = closingControllers.filter { uuid, identifier in
            byUUID[uuid].map { ObjectIdentifier($0) == identifier } ?? false
        }
        // Take the preview from the live window, never from a hidden/minimized
        // one: a hidden view snapshots empty and would show a black card.
        var freshPreviews: [String: UIView] = [:]
        for controller in controllers {
            guard let uuid = controller.dataUUID else { continue }
            let decorated = decoratedController(for: controller)
            let source = controller.viewIfLoaded
            let wrapperVisible = (decorated?.viewIfLoaded).map { !$0.isHidden && $0.alpha > 0 } ?? true
            if let source, wrapperVisible, !source.isHidden, source.alpha > 0,
               source.window != nil, !source.bounds.isEmpty,
               let snapshot = source.snapshotView(afterScreenUpdates: false) {
                freshPreviews[uuid] = snapshot
            } else if let snapshot = decorated?.stackContentPreview {
                freshPreviews[uuid] = snapshot
            }
        }
        let dockApps = MultitaskDockManager.shared.apps
        for app in dockApps where freshPreviews[app.appUUID] == nil {
            if let decorated = app.view?._viewDelegate() as? DecoratedAppSceneViewController,
               let snapshot = decorated.stackContentPreview {
                freshPreviews[app.appUUID] = snapshot
            }
        }
        previews = freshPreviews
        var seen = Set<String>()
        let order = (dockApps.map(\.appUUID) + controllers.compactMap(\.dataUUID))
            .filter { seen.insert($0).inserted }
        var dockByUUID: [String: DockAppModel] = [:]
        for app in dockApps where dockByUUID[app.appUUID] == nil {
            dockByUUID[app.appUUID] = app
        }
        apps = order.compactMap { uuid in
            let controller = byUUID[uuid]
            if let controller, closingControllers[uuid] == ObjectIdentifier(controller) { return nil }
            if let existing = dockByUUID[uuid], existing.view != nil {
                if let controller {
                    if existing.view === decoratedController(for: controller)?.viewIfLoaded { return existing }
                } else {
                    return existing
                }
            }
            guard let controller else { return dockByUUID[uuid] }
            let existing = dockByUUID[uuid]
            let info = existing?.appInfo ?? AppInfoProvider.shared.findAppInfo(appName: existing?.appName ?? controller.bundleId ?? "", dataUUID: uuid)
            let name = existing?.appName ?? info?.displayName() ?? controller.bundleId ?? uuid
            let view: UIView? = decoratedController(for: controller)?.view ?? controller.viewIfLoaded
            return DockAppModel(appName: name, appUUID: uuid, appInfo: info, view: view)
        }
        focus(index: selectedUUID.flatMap { uuid in apps.firstIndex(where: { $0.appUUID == uuid }) } ?? selectedIndex)
        // 当前 app 排到最右边: iOS 的后台就是这个顺序, 打开后台默认聚焦它而不是最右那张.
        if let current = currentAppUUID(),
           let currentIndex = apps.firstIndex(where: { $0.appUUID == current }),
           currentIndex != apps.count - 1 {
            let card = apps.remove(at: currentIndex)
            apps.append(card)
            focus(index: apps.count - 1)
        }
    }

    func previewSnapshot(for uuid: String) -> UIView? {
        previews[uuid]
    }

    func focus(index: Int) {
        selectedIndex = min(max(0, index), max(0, apps.count - 1))
        selectedUUID = apps.indices.contains(selectedIndex) ? apps[selectedIndex].appUUID : nil
    }

    @objc public func selectApp(uuid: String) {
        DispatchQueue.main.async {
            // Settings and other host screens sit above guest windows; close
            // them first so tapping a card really reveals its window.
            NotificationCenter.default.post(name: .lcCloseHostScreens, object: nil)
            let controllers = self.appControllers()
            guard let controller = controllers.first(where: { $0.dataUUID == uuid }),
                  self.closingControllers[uuid] != ObjectIdentifier(controller) else {
                self.message = "窗口已经关闭"
                self.refreshApps()
                return
            }
            if let target = self.decoratedController(for: controller) {
                guard let view = target.viewIfLoaded, let container = view.superview else {
                    self.message = "窗口暂时无法恢复"
                    return
                }
                if target.isStashed { target.unstash(animated: false) }
                for other in controllers {
                    if let decorated = self.decoratedController(for: other), decorated !== target { decorated.minimizeWindow() }
                }
                if !MultitaskDockManager.shared.bringMultitaskViewToFront(uuid: uuid) {
                    if let pip = PiPManager.shared, pip.isPiP(withDecoratedVC: target) { pip.stopPiP() }
                    target.restoreFromDock()
                    container.bringSubviewToFront(view)
                    target.revealWindowControls()
                }
                self.dismiss()
            } else if let scene = controller.viewIfLoaded?.window?.windowScene {
                UIApplication.shared.requestSceneSessionActivation(scene.session, userActivity: nil, options: nil) { error in
                    NSLog("[TDHome] app stack activation failed: %@", error.localizedDescription)
                    self.present()
                }
                self.dismiss()
            } else {
                self.message = "窗口暂时无法恢复"
            }
        }
    }

    @objc public func closeApp(uuid: String) {
        DispatchQueue.main.async {
            guard self.restartingControllers[uuid] == nil else {
                self.message = "该应用正在重新启动，请稍候"
                return
            }
            guard let controller = self.appControllers().first(where: { $0.dataUUID == uuid }) else {
                self.message = "窗口已经关闭"
                self.refreshApps()
                return
            }
            let identifier = ObjectIdentifier(controller)
            guard self.closingControllers[uuid] != identifier else { return }
            self.closingControllers[uuid] = identifier
            if let decorated = self.decoratedController(for: controller) {
                decorated.closeWindow()
            } else {
                controller.terminate()
                if let scene = controller.viewIfLoaded?.window?.windowScene {
                    UIApplication.shared.requestSceneSessionDestruction(scene.session, options: nil) { error in
                        NSLog("[TDHome] app stack close scene failed: %@", error.localizedDescription)
                        DispatchQueue.main.async {
                            guard self.closingControllers[uuid] == identifier else { return }
                            self.closingControllers.removeValue(forKey: uuid)
                            self.message = "窗口关闭失败：\(error.localizedDescription)"
                            self.refreshApps()
                        }
                    }
                }
            }
            // Only a real close above removes a card; Dock cleanup remains the
            // controller's responsibility when the guest actually exits.
            self.refreshApps()
        }
    }

    func restartTarget(for uuid: String) -> AppSceneViewController? {
        displayedControllers[uuid]
    }

    private func restartModel(bundleId: String, uuid: String) -> LCAppModel? {
        func matches(_ app: LCAppModel) -> Bool {
            app.appInfo.relativeBundlePath == bundleId && app.uiContainers.contains { $0.folderName == uuid }
        }
        let model = DataManager.shared.model
        return model.apps.first(where: matches) ?? model.hiddenApps.first(where: matches)
    }

    private func showRestartMessage(_ text: String) {
        message = text
        // Keep async failures visible even if the user dismissed the stack
        // while waiting for process exit, signing or JIT.
        pendingPresentation = true
        presentIfPossible()
    }

    private func restartFailed(uuid: String, identifier: ObjectIdentifier, detail: String) {
        guard restartingControllers[uuid] == identifier else { return }
        restartingControllers.removeValue(forKey: uuid)
        if closingControllers[uuid] == identifier { closingControllers.removeValue(forKey: uuid) }
        showRestartMessage("重新启动失败：\(detail)")
    }

    func restartApp(uuid: String, controller expectedController: AppSceneViewController?) {
        DispatchQueue.main.async {
            guard self.restartingControllers[uuid] == nil else {
                self.showRestartMessage("该应用正在重新启动，请勿重复操作")
                return
            }
            guard let expectedController,
                  let controller = self.appControllers().first(where: { $0.dataUUID == uuid }),
                  controller === expectedController,
                  self.closingControllers[uuid] != ObjectIdentifier(controller),
                  !controller.isUserTerminating || controller.isTerminated else {
                self.showRestartMessage("窗口已经关闭或已更改，请重新选择要启动的应用")
                return
            }
            guard let bundleId = controller.bundleId, !bundleId.isEmpty, controller.pid > 0,
                  let app = self.restartModel(bundleId: bundleId, uuid: uuid) else {
                self.showRestartMessage("找不到原来的应用或容器，未重新启动")
                return
            }
            guard !app.isAppRunning, app.appInfo.defaultClassicMode == 0 else {
                self.showRestartMessage("应用正在启动或已改为非多任务模式，请稍后重试")
                return
            }
            let mode: MultitaskMode = controller.isNativeWindow ? .nativeWindow : .virtualWindow
            let decorated = self.decoratedController(for: controller)
            let oldScene = mode == .nativeWindow ? controller.viewIfLoaded?.window?.windowScene : nil
            var removeNativeEntry: (() -> Bool)?
            if mode == .nativeWindow {
                guard #available(iOS 16.1, *), oldScene != nil,
                      let info = MultitaskWindowManager.appDict[uuid], info.bundleId == bundleId else {
                    self.showRestartMessage("原生窗口已经关闭，无法确认要重新启动的窗口")
                    return
                }
                removeNativeEntry = {
                    guard MultitaskWindowManager.appDict[uuid]?.launchID == info.launchID else { return false }
                    MultitaskWindowManager.removeAppInfo(info)
                    return true
                }
            } else if decorated == nil {
                self.showRestartMessage("找不到该应用的多任务窗口，未重新启动")
                return
            }
            // Snapshot identity before closeWindow can release its wrapper.
            let identifier = ObjectIdentifier(controller)
            let oldPID = controller.pid
            self.restartingControllers[uuid] = identifier
            self.closingControllers[uuid] = identifier
            self.message = "正在重新启动 \(app.appInfo.displayName() ?? bundleId)…"
            if let pip = PiPManager.shared, pip.isPiP(withVC: controller) { pip.stopPiP() }
            decorated?.closeWindow()
            controller.terminate { error in
                guard self.restartingControllers[uuid] == identifier else { return }
                if let error {
                    self.restartFailed(uuid: uuid, identifier: identifier, detail: error.localizedDescription)
                    return
                }
                guard !self.appControllers().contains(where: { $0.dataUUID == uuid && $0 !== controller }) else {
                    self.restartFailed(uuid: uuid, identifier: identifier, detail: "该容器已经出现新的窗口，未重复启动")
                    return
                }
                if let removeNativeEntry, !removeNativeEntry() {
                    self.restartFailed(uuid: uuid, identifier: identifier, detail: "原生窗口的启动记录已更改，未重复启动")
                    return
                }
                MultitaskDockManager.shared.removeRunningApp(uuid)
                Task { @MainActor in
                    // The native successor uses a new launchID scene value,
                    // so destroying the old session late cannot close it.
                    defer {
                        if let oldScene {
                            UIApplication.shared.requestSceneSessionDestruction(oldScene.session, options: nil) { error in
                                DispatchQueue.main.async {
                                    self.showRestartMessage("原窗口关闭失败：\(error.localizedDescription)")
                                }
                            }
                        }
                    }
                    do {
                        guard self.restartModel(bundleId: bundleId, uuid: uuid) === app else {
                            throw "应用或容器已被移除，未重新启动"
                        }
                        try await app.runApp(multitask: true, containerFolderName: uuid, bundleIdOverride: bundleId, multitaskWindowMode: mode)
                        guard let replacement = self.appControllers().first(where: { $0.dataUUID == uuid }),
                              replacement !== controller, replacement.bundleId == bundleId,
                              replacement.isNativeWindow == (mode == .nativeWindow),
                              replacement.pid > 0, !replacement.isTerminated else {
                            throw "应用未能建立新的多任务窗口"
                        }
                        self.restartingControllers.removeValue(forKey: uuid)
                        if self.closingControllers[uuid] == identifier { self.closingControllers.removeValue(forKey: uuid) }
                        self.message = nil
                        self.pendingPresentation = false
                        self.clearStoredRequest()
                        NotificationCenter.default.post(name: .lcCloseHostScreens, object: nil)
                        self.detachWindow()
                        // Bring only the replacement forward; selectApp's
                        // minimize-other-windows policy is not a restart.
                        if let window = self.decoratedController(for: replacement),
                           let view = window.viewIfLoaded, let container = view.superview {
                            if view.isHidden { window.restoreFromDock() }
                            container.bringSubviewToFront(view)
                            window.revealWindowControls()
                        } else if let scene = replacement.viewIfLoaded?.window?.windowScene {
                            UIApplication.shared.requestSceneSessionActivation(scene.session, userActivity: nil, options: nil) { error in
                                DispatchQueue.main.async {
                                    self.showRestartMessage("应用已重新启动，但窗口打开失败：\(error.localizedDescription)")
                                }
                            }
                        } else {
                            self.showRestartMessage("应用已重新启动，但暂时没有可显示的窗口")
                        }
                        NSLog("[LC][Multitask] restarted bundle=%@ container=%@ oldPID=%d newPID=%d mode=%ld", bundleId, uuid, oldPID, replacement.pid, mode.rawValue)
                    } catch {
                        self.restartFailed(uuid: uuid, identifier: identifier, detail: error.localizedDescription)
                    }
                }
            }
            self.refreshApps()
        }
    }

    /// The Home Screen's model for the app in a stack card, when the app is
    /// still installed.
    private func appModel(for uuid: String) -> LCAppModel? {
        DataManager.shared.model.apps.first { app in
            (app.appInfo.dataUUID as String?) == uuid
        }
    }

    /// Closes every running window; each card leaves only after its guest ends.
    @objc public func closeAll() {
        for uuid in apps.map(\.appUUID) {
            closeApp(uuid: uuid)
        }
    }

    @objc public func showAppInfo(uuid: String) {
        DispatchQueue.main.async {
            guard self.appModel(for: uuid) != nil else {
                self.message = "找不到该应用的信息"
                return
            }
            self.dismiss()
            NotificationCenter.default.post(name: .lcStackShowAppSettings, object: nil, userInfo: ["uuid": uuid])
        }
    }

    @objc public func openInSplitScreen(uuid: String) {
        DispatchQueue.main.async {
            guard self.appModel(for: uuid) != nil else {
                self.message = "找不到该应用的信息"
                return
            }
            self.dismiss()
            NotificationCenter.default.post(name: .lcStackSplitApp, object: nil, userInfo: ["uuid": uuid])
        }
    }

    @objc public func togglePictureInPicture(uuid: String) {
        DispatchQueue.main.async {
            guard let controller = self.appControllers().first(where: { $0.dataUUID == uuid }) else {
                self.message = "窗口已经关闭"
                self.refreshApps()
                return
            }
            guard let pip = PiPManager.shared else {
                self.message = "系统不支持画中画"
                return
            }
            if pip.isPiP(withVC: controller) {
                pip.stopPiP()
            } else {
                pip.startPiP(withVC: controller)
            }
            self.dismiss()
        }
    }

    /// One-shot orientation override: the guest applies it once and deletes
    /// the key, so this never changes the app's permanent rotation lock.
    @objc public func rotateApp(uuid: String, direction: Int) {
        DispatchQueue.main.async {
            guard let controller = self.appControllers().first(where: { $0.dataUUID == uuid }) else {
                self.message = "窗口已经关闭"
                self.refreshApps()
                return
            }
            // 宿主这一侧必须自己把场景方向改掉: 访客进程里的 mask hook 只决定
            // "允许哪些方向", 嵌入的场景还得被告知按新方向重排, 否则画面上什么
            // 都不会转（这正是之前点了没反应的原因）。
            let orientation: UIInterfaceOrientation
            switch direction {
            case 1: orientation = .landscapeRight
            case 3: orientation = .portraitUpsideDown
            case 2: orientation = .portrait
            default: orientation = .unknown
            }
            controller.orientationOverride = orientation
            controller.updateFrame(settingsBlock: nil)
            // The guest checks the request's uuid against NSUserDefaults.lcGuestAppId,
            // which is the BUNDLE ID (LCBootstrap). The stack card's uuid is the
            // data-UUID, so writing it here made every request be ignored.
            let guestId = self.appModel(for: uuid)?.appInfo.bundleIdentifier() ?? uuid
            // The guest reads the request from the shared app group defaults
            // (NSUserDefaults.lcSharedDefaults), so write it to that same suite.
            let defaults = LCUtils.appGroupUserDefault
            defaults.set(["uuid": guestId, "dir": direction], forKey: "LCPendingOrientationOverride")
            defaults.synchronize()
            CFNotificationCenterPostNotification(CFNotificationCenterGetDarwinNotifyCenter(),
                                                 CFNotificationName("com.kdt.livecontainer.applyOrientation" as CFString),
                                                 nil, nil, true)
            self.dismiss()
        }
    }
}

extension Notification.Name {
    /// Posted when the stack opens a window, so the Home Screen closes its own
    /// sheet before the guest comes forward.
    static let lcCloseHostScreens = Notification.Name("LCCloseHostScreens")
    /// Posted with `userInfo["uuid"]` when the stack asks for an app's split.
    static let lcStackSplitApp = Notification.Name("LCStackSplitApp")
    /// Posted with `userInfo["uuid"]` to open an app's settings on the host,
    /// where the SwiftUI environment objects exist.
    static let lcStackShowAppSettings = Notification.Name("LCStackShowAppSettings")
}


@available(iOS 16.0, *)
struct MultitaskStackView: View {
    @EnvironmentObject var manager: MultitaskStackManager
    @ObservedObject private var dockManager = MultitaskDockManager.shared
    @AppStorage("TDAppStackClearAllEnabled", store: LCUtils.appGroupUserDefault)
    private var showClearAll = true
    // 背景来源：wallpaper = 跟随壁纸（iOS 后台那样），app = 跟随当前应用
    @AppStorage("TDAppStackBackground", store: LCUtils.appGroupUserDefault)
    private var backgroundSource = "app"
    @AppStorage("TDAppStackBlur", store: LCUtils.appGroupUserDefault)
    private var backgroundBlur = 12.0
    @State private var wallpaperImage: UIImage?
    @State private var backdropVisible = false

    var body: some View {
        ZStack {
            backgroundLayer.opacity(backdropVisible ? 1 : 0)
            StackDeckRepresentable(manager: manager, dockApps: dockManager.apps,
                                   showClearAll: showClearAll) { visible, duration in
                withAnimation(.easeOut(duration: duration)) { backdropVisible = visible }
            }
        }
        .ignoresSafeArea()
        .task {
            guard wallpaperImage == nil else { return }
            let isPad = UIDevice.current.userInterfaceIdiom == .pad
            wallpaperImage = WallpaperFile.load() ?? WallpaperFile.loadDefault(isPad: isPad)
        }
    }

    // 背景：跟随壁纸（模糊后铺满）或跟随应用（毛玻璃压暗），点击空白回前台。
    @ViewBuilder
    private var backgroundLayer: some View {
        if backgroundSource == "wallpaper", let wallpaperImage {
            Image(uiImage: wallpaperImage)
                .resizable()
                .scaledToFill()
                .blur(radius: backgroundBlur)
                .overlay(Color.black.opacity(0.18))
                .ignoresSafeArea()
        } else {
            Rectangle()
                .fill(.ultraThinMaterial)
                .overlay(Color.black.opacity(0.12 + backgroundBlur / 60))
                .ignoresSafeArea()
        }
    }

}

// MARK: - Reference deck (LCOrbitTaskSwitcher.m, actual bundled line numbers)
// All native types stay in this file, so the existing Xcode target needs no new
// file membership. Snapshots remain inert; no guest view is moved or resized.
@available(iOS 16.0, *)
private struct StackDeckRepresentable: UIViewRepresentable {
    let manager: MultitaskStackManager
    let dockApps: [DockAppModel]
    let showClearAll: Bool
    let backdrop: (Bool, TimeInterval) -> Void

    func makeUIView(context: Context) -> StackDeckViewport { StackDeckViewport() }
    func updateUIView(_ view: StackDeckViewport, context: Context) {
        view.configure(manager: manager, dockApps: dockApps, showClearAll: showClearAll, backdrop: backdrop)
    }
    static func dismantleUIView(_ view: StackDeckViewport, coordinator: ()) { view.invalidate() }
}

// Pure geometry/threshold functions are also exercised by checks/deck_math_tests.swift.
private enum StackDeckMath {
    static func layout(width: CGFloat, height: CGFloat, safeTop: CGFloat, safeBottom: CGFloat,
                       hasDock: Bool, count: Int, source: CGSize) -> (width: CGFloat, height: CGFloat, centerX: CGFloat, centerY: CGFloat, stride: CGFloat, cardBottom: CGFloat) {
        let dockTop = max(safeTop + 12, height - safeBottom - 64 - 4)
        let cardBottom = hasDock ? dockTop - 28 : height - safeBottom - 16
        let availableHeight = max(35, cardBottom - safeTop)
        let previewHeight = max(1, min(height * 0.70, availableHeight - 60))
        let maxCardWidth = max(1, width > height ? previewHeight * 0.78 : width * 0.72)
        let validSource = source.width.isFinite && source.height.isFinite && source.width > 0 && source.height > 0
        let aspect = validSource ? source.width / source.height : maxCardWidth / previewHeight
        let w = min(maxCardWidth, previewHeight * aspect), h = min(previewHeight, maxCardWidth / aspect)
        let cy = min(safeTop + availableHeight * 0.52, cardBottom - 1.018 * (17 + h * 0.5))
        return (w, h, width / 2 + (count > 1 ? maxCardWidth * 0.125 : 0), cy, maxCardWidth * 0.77, cardBottom)
    }
    static func pose(distance: CGFloat, stride: CGFloat) -> (scale: CGFloat, shift: CGFloat) {
        let pageX = distance * stride
        let deckX = distance < 0 ? pageX / (1 - 2.25 * distance) : pageX
        return (1 + 0.018 * max(-3, min(1, distance)), deckX - pageX)
    }
    static func targetPage(current: CGFloat, velocity: CGFloat, start: CGFloat, count: Int) -> CGFloat {
        guard count > 0, current.isFinite, velocity.isFinite, start.isFinite else { return 0 }
        var page = current.rounded()
        if abs(velocity) > 0.25 {
            let directional = velocity > 0 ? floor(current + 0.05) + 1 : ceil(current - 0.05) - 1
            page = min(max(directional, min(page, start - 1)), max(page, start + 1))
        }
        return min(max(0, page), CGFloat(count - 1))
    }
    static func shouldClose(translation: CGPoint, velocityY: CGFloat, startOffset: CGFloat, height: CGFloat) -> Bool {
        let projected = translation.y + startOffset + 0.12 * max(-2200, min(1400, velocityY))
        return translation.y < -8 && abs(translation.y) > abs(translation.x) * 1.12 && projected < -height * 0.23
    }
}

@available(iOS 16.0, *)
private final class StackDeckCard: UIView, UIContextMenuInteractionDelegate {
    let uuid: String
    let launch: AppSceneViewController?
    weak var owner: StackDeckViewport?
    let preview = UIView()
    let icon = UIImageView()
    let centerIcon = UIImageView()
    let name = UILabel()
    var snapshot: UIView?
    var sourceSize = CGSize.zero
    var resting = CGAffineTransform.identity
    var index = 0
    var bundleID = ""
    var expandedFrame: CGRect?
    var sourceVisible = false
    var isPiP = false

    init(app: DockAppModel, launch: AppSceneViewController?, owner: StackDeckViewport) {
        uuid = app.appUUID
        self.launch = launch
        self.owner = owner
        super.init(frame: .zero)
        accessibilityIdentifier = "stack.card.\(uuid)"
        isAccessibilityElement = true
        accessibilityTraits = .button
        icon.contentMode = .scaleAspectFit
        icon.layer.cornerRadius = 6
        icon.clipsToBounds = true
        icon.tintColor = .white
        name.font = .systemFont(ofSize: 14, weight: .semibold)
        name.textColor = .white
        name.lineBreakMode = .byTruncatingTail
        preview.layer.cornerRadius = 28
        preview.layer.cornerCurve = .continuous
        preview.clipsToBounds = true
        preview.isUserInteractionEnabled = false
        centerIcon.contentMode = .scaleAspectFit
        centerIcon.layer.cornerCurve = .continuous
        centerIcon.clipsToBounds = true
        centerIcon.tintColor = .white
        addSubview(preview)
        addSubview(icon)
        addSubview(name)
        preview.addSubview(centerIcon)
        // Shadow belongs to the preview, never to a transparent whole-card outline (:403-406).
        layer.shadowColor = UIColor.black.cgColor
        layer.shadowOpacity = 0.30
        layer.shadowRadius = 16
        layer.shadowOffset = CGSize(width: 0, height: 8)
        let pan = UIPanGestureRecognizer(target: owner, action: #selector(StackDeckViewport.cardPanned(_:)))
        pan.delegate = owner
        let tap = UITapGestureRecognizer(target: owner, action: #selector(StackDeckViewport.cardTapped(_:)))
        addGestureRecognizer(pan)
        addGestureRecognizer(tap)
        tap.require(toFail: pan)
        owner.pages.panGestureRecognizer.require(toFail: pan)
        addInteraction(UIContextMenuInteraction(delegate: self))
        accessibilityCustomActions = [
            UIAccessibilityCustomAction(name: "关闭窗口", target: self, selector: #selector(closeAccessible)),
            UIAccessibilityCustomAction(name: "重新启动", target: self, selector: #selector(restartAccessible))
        ]
        update(app: app, snapshot: nil)
    }
    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    func update(app: DockAppModel, snapshot: UIView?) {
        if icon.image == nil || name.text != app.appName {
            let info = app.appInfo ?? AppInfoProvider.shared.findAppInfo(appName: app.appName, dataUUID: uuid)
            icon.image = info?.iconIsDarkIcon(false) ?? UIImage(systemName: "app.fill")
        }
        name.text = app.appName
        accessibilityLabel = app.appName
        bundleID = app.appInfo?.bundleIdentifier() ?? ""
        isPiP = launch.map { PiPManager.shared?.isPiP(withVC: $0) == true } ?? false
        centerIcon.image = isPiP ? UIImage(systemName: "pip.fill") : icon.image
        let snapshot = isPiP ? nil : snapshot
        if self.snapshot !== snapshot {
            self.snapshot?.removeFromSuperview()
            self.snapshot = snapshot
            if let snapshot {
                snapshot.isUserInteractionEnabled = false
                preview.insertSubview(snapshot, belowSubview: centerIcon)
            }
        }
        // Never derive preview aspect from the decorated window (:562-564).
        sourceSize = snapshot?.bounds.size ?? launch?.viewIfLoaded?.bounds.size ?? .zero
        updateExpandedFrame()
        centerIcon.isHidden = snapshot != nil
        preview.backgroundColor = snapshot == nil ? UIColor(white: 0.16, alpha: 1) : .black
        preview.layer.borderWidth = snapshot == nil ? 0.5 : 0
        preview.layer.borderColor = UIColor.white.withAlphaComponent(0.20).cgColor
        accessibilityHint = isPiP ? "此 App 的画面保留在画中画中" : (snapshot == nil ? "静态图标预览，轻点切换到此 App" : "轻点打开，上滑关闭，长按更多操作")
        setNeedsLayout()
    }
    func updateExpandedFrame() {
        expandedFrame = nil; sourceVisible = false
        guard let source = launch?.viewIfLoaded, let scene = owner?.window?.windowScene,
              source.window?.windowScene === scene else { return }
        expandedFrame = source.convert(source.bounds, to: owner)
        sourceVisible = true
        var ancestor: UIView? = source
        while let view = ancestor {
            if view.isHidden || view.alpha <= 0 { sourceVisible = false; break }
            ancestor = view.superview
        }
    }
    override func layoutSubviews() {
        super.layoutSubviews()
        preview.frame = CGRect(x: 0, y: 34, width: bounds.width, height: max(1, bounds.height - 34))
        if let snapshot, sourceSize.width > 0, sourceSize.height > 0 {
            snapshot.transform = .identity
            snapshot.bounds = CGRect(origin: .zero, size: sourceSize)
            snapshot.transform = CGAffineTransform(scaleX: preview.bounds.width / sourceSize.width,
                                                 y: preview.bounds.height / sourceSize.height)
            snapshot.center = CGPoint(x: preview.bounds.midX, y: preview.bounds.midY)
        }
        let side: CGFloat = isPiP ? 54 : min(94, max(44, min(preview.bounds.width, preview.bounds.height) * 0.30))
        centerIcon.frame = CGRect(x: (preview.bounds.width - side) / 2, y: (preview.bounds.height - side) / 2, width: side, height: side)
        centerIcon.layer.cornerRadius = side * 0.225
        layer.shadowPath = UIBezierPath(roundedRect: preview.frame, cornerRadius: 28).cgPath
    }
    override func accessibilityActivate() -> Bool { owner?.activate(self); return true }
    @objc private func closeAccessible() -> Bool { owner?.close(self, velocity: 0); return true }
    @objc private func restartAccessible() -> Bool { perform { $0.restartApp(uuid: self.uuid, controller: self.launch) }; return true }
    private func perform(_ action: (MultitaskStackManager) -> Void) {
        guard let owner, owner.isCurrent(self), let manager = owner.manager else { return }
        action(manager)
    }
    func contextMenuInteraction(_ interaction: UIContextMenuInteraction, configurationForMenuAtLocation location: CGPoint) -> UIContextMenuConfiguration? {
        guard owner?.isCurrent(self) == true else { return nil }
        return UIContextMenuConfiguration(identifier: nil, previewProvider: nil) { [weak self] _ in
            guard let self else { return nil }
            func item(_ title: String, _ symbol: String, _ action: @escaping (MultitaskStackManager) -> Void) -> UIAction {
                UIAction(title: title, image: UIImage(systemName: symbol)) { [weak self] _ in self?.perform(action) }
            }
            let rotate = UIMenu(title: "旋转方向", image: UIImage(systemName: "rotate.left"), children: [
                item("默认", "arrow.uturn.backward.circle") { $0.rotateApp(uuid: self.uuid, direction: 0) },
                item("横屏", "arrow.left.and.right") { $0.rotateApp(uuid: self.uuid, direction: 1) },
                item("竖屏", "arrow.up.and.down") { $0.rotateApp(uuid: self.uuid, direction: 2) },
                item("反转", "arrow.2.squarepath") { $0.rotateApp(uuid: self.uuid, direction: 3) }
            ])
            let close = UIAction(title: "清除", image: UIImage(systemName: "xmark"), attributes: .destructive) { [weak self] _ in
                guard let self else { return }; self.owner?.close(self, velocity: 0)
            }
            return UIMenu(title: self.bundleID, children: [
                item("应用信息", "info.circle") { $0.showAppInfo(uuid: self.uuid) },
                item("分屏", "rectangle.split.1x2") { $0.openInSplitScreen(uuid: self.uuid) }, rotate,
                item("画中画模式", "pip") { $0.togglePictureInPicture(uuid: self.uuid) },
                item("重新启动", "arrow.clockwise") { $0.restartApp(uuid: self.uuid, controller: self.launch) }, close
            ])
        }
    }
}

@available(iOS 16.0, *)
private final class StackDeckViewport: UIView, UIScrollViewDelegate, UIGestureRecognizerDelegate {
    weak var manager: MultitaskStackManager?
    let pages = UIScrollView()
    private let dock = UIVisualEffectView(effect: UIBlurEffect(style: .systemThinMaterialDark))
    private let dockScroll = UIScrollView()
    private let clearButton = UIButton(type: .system)
    private let emptyLabel = UILabel()
    private let messageLabel = UILabel()
    private var cards: [StackDeckCard] = []
    private var dockIDs: [String] = []
    private var dockButtons: [UIButton] = []
    private var stride: CGFloat = 1
    private var selected = 0
    private var dragStartPage: CGFloat = 0
    private var scrolling = false
    private var layingOut = false
    private var transitioning = false
    private var invalidated = false
    private var hasEntered = false
    private var showClearAll = false
    private var lastBounds = CGRect.null
    private var lastSafe = UIEdgeInsets.zero
    private var entrance: UIViewPropertyAnimator?
    private var transition: UIViewPropertyAnimator?
    private var rebound: UIViewPropertyAnimator?
    private weak var draggingCard: StackDeckCard?
    private weak var reboundingCard: StackDeckCard?
    private var dragStartOffset: CGFloat = 0
    private var focusGeneration = 0
    private var backdrop: ((Bool, TimeInterval) -> Void)?
    private let dockIconSize: CGFloat = 48 // reference default :1213, clamp :1254

    override init(frame: CGRect) {
        super.init(frame: frame)
        accessibilityViewIsModal = true
        pages.delegate = self
        pages.clipsToBounds = true
        pages.showsHorizontalScrollIndicator = false
        pages.decelerationRate = .fast
        pages.isDirectionalLockEnabled = true
        pages.bounces = false
        pages.contentInsetAdjustmentBehavior = .never
        addSubview(pages)
        dock.layer.cornerRadius = 19
        dock.layer.cornerCurve = .continuous
        dock.clipsToBounds = true
        dock.layer.borderWidth = 0.5
        dock.layer.borderColor = UIColor.white.withAlphaComponent(0.16).cgColor
        addSubview(dock)
        dockScroll.showsHorizontalScrollIndicator = false
        dockScroll.alwaysBounceHorizontal = true
        dockScroll.isDirectionalLockEnabled = true
        dockScroll.contentInsetAdjustmentBehavior = .never
        // Artwork and glass are siblings, not inside effect.contentView (:373-379).
        addSubview(dockScroll)
        clearButton.setImage(UIImage(systemName: "trash"), for: .normal)
        clearButton.tintColor = .white
        clearButton.backgroundColor = UIColor.white.withAlphaComponent(0.18)
        clearButton.layer.cornerRadius = 22
        clearButton.accessibilityLabel = "全部清除"
        clearButton.addTarget(self, action: #selector(clearAll), for: .touchUpInside)
        dockScroll.addSubview(clearButton)
        emptyLabel.text = "没有正在运行的 App"
        emptyLabel.textAlignment = .center
        emptyLabel.font = .systemFont(ofSize: 15, weight: .medium)
        emptyLabel.textColor = UIColor.white.withAlphaComponent(0.82)
        emptyLabel.isUserInteractionEnabled = false
        addSubview(emptyLabel)
        messageLabel.font = .systemFont(ofSize: 13, weight: .medium)
        messageLabel.textColor = .white
        messageLabel.textAlignment = .center
        messageLabel.numberOfLines = 2
        messageLabel.isUserInteractionEnabled = false
        messageLabel.backgroundColor = UIColor.black.withAlphaComponent(0.65)
        messageLabel.layer.cornerRadius = 10
        messageLabel.clipsToBounds = true
        addSubview(messageLabel)
        dockScroll.layer.cornerRadius = 19
        dockScroll.layer.cornerCurve = .continuous
        let tap = UITapGestureRecognizer(target: self, action: #selector(backgroundTapped))
        tap.delegate = self
        addGestureRecognizer(tap)
    }
    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    func configure(manager: MultitaskStackManager, dockApps: [DockAppModel], showClearAll: Bool,
                   backdrop: @escaping (Bool, TimeInterval) -> Void) {
        guard !invalidated else { return }
        self.manager = manager
        self.backdrop = backdrop
        messageLabel.text = manager.message
        messageLabel.isHidden = manager.message == nil
        if self.showClearAll != showClearAll { lastBounds = .null }
        self.showClearAll = showClearAll
        var seen = Set<String>()
        let apps = manager.apps.filter { seen.insert($0.appUUID).inserted }
        let old = cards
        let changed = old.map(\.uuid) != apps.map(\.appUUID) || apps.contains { app in
            old.first(where: { $0.uuid == app.appUUID })?.launch !== manager.restartTarget(for: app.appUUID)
        }
        let wasEntered = hasEntered
        let oldFrames = Dictionary(uniqueKeysWithValues: old.map { ($0.uuid, $0.preview.convert($0.preview.bounds, to: self)) })
        if changed {
            focusGeneration += 1
            finishEntrance(); stopRebound(); draggingCard = nil; scrolling = false
            pages.setContentOffset(pages.contentOffset, animated: false)
            if transitioning {
                transition?.stopAnimation(true); transition = nil
                transitioning = false; pages.isScrollEnabled = true; isUserInteractionEnabled = true
                DispatchQueue.main.async { [weak self] in self?.backdrop?(true, 0.15) }
            }
            pages.alpha = 1; emptyLabel.alpha = 1
        }
        cards = apps.enumerated().map { index, app in
            let launch = manager.restartTarget(for: app.appUUID)
            let card = old.first { $0.uuid == app.appUUID && $0.launch === launch } ?? StackDeckCard(app: app, launch: launch, owner: self)
            if card.superview == nil { pages.addSubview(card) }
            pages.bringSubviewToFront(card)
            card.index = index
            let previousSize = card.sourceSize
            card.update(app: app, snapshot: manager.previewSnapshot(for: app.appUUID))
            if previousSize != card.sourceSize { lastBounds = .null }
            if changed { card.preview.layer.cornerRadius = 28 }
            return card
        }
        for card in old where !cards.contains(where: { $0 === card }) { card.removeFromSuperview() }
        var dockSeen = Set<String>()
        let dockApps = dockApps.filter { dockSeen.insert($0.appUUID).inserted }
        if dockIDs != dockApps.map(\.appUUID) {
            dockButtons.forEach { $0.removeFromSuperview() }
            dockIDs = dockApps.map(\.appUUID)
            dockButtons = dockApps.map { app in
                let button = UIButton(type: .custom)
                let image = UIImageView(image: app.appInfo?.iconIsDarkIcon(false) ?? UIImage(systemName: "app.fill"))
                image.contentMode = .scaleAspectFit
                image.tintColor = .white
                image.layer.cornerRadius = dockIconSize * 0.225
                image.clipsToBounds = true
                image.frame = CGRect(x: 0, y: 0, width: dockIconSize, height: dockIconSize)
                image.isUserInteractionEnabled = false
                button.addSubview(image)
                button.accessibilityLabel = app.appName
                let uuid = app.appUUID
                button.addAction(UIAction { [weak self] _ in self?.activate(uuid: uuid) }, for: .touchUpInside)
                dockScroll.addSubview(button)
                return button
            }
            lastBounds = .null
        }
        let desired = min(max(0, manager.selectedIndex), max(0, cards.count - 1))
        emptyLabel.isHidden = !cards.isEmpty
        clearButton.isHidden = !showClearAll || cards.isEmpty
        let hideDock = dockApps.isEmpty && clearButton.isHidden
        if dock.isHidden != hideDock { lastBounds = .null }
        dock.isHidden = hideDock
        dockScroll.isHidden = hideDock
        if changed {
            selected = desired
            lastBounds = .null
            setNeedsLayout()
            layoutIfNeeded()
            if wasEntered && !transitioning && !UIAccessibility.isReduceMotionEnabled {
                for card in cards {
                    if let frame = oldFrames[card.uuid] { align(card, to: frame) }
                }
                animateEntrance(duration: 0.28, damping: 0.88)
            }
        } else if !scrolling && draggingCard == nil && selected != desired && !transitioning {
            selected = desired
            let animated = !UIAccessibility.isReduceMotionEnabled
            scrolling = animated
            pages.setContentOffset(CGPoint(x: CGFloat(selected) * stride, y: 0), animated: animated)
        }
        setNeedsLayout()
    }

    override func didMoveToWindow() {
        super.didMoveToWindow()
        if window != nil { lastBounds = .null; setNeedsLayout() }
    }
    override func safeAreaInsetsDidChange() { super.safeAreaInsetsDidChange(); setNeedsLayout() }
    override func layoutSubviews() {
        super.layoutSubviews()
        guard !invalidated, !transitioning, draggingCard == nil, !scrolling,
              !pages.isDragging, !pages.isDecelerating, bounds.width > 0, bounds.height > 0 else { return }
        guard lastBounds != bounds || lastSafe != safeAreaInsets else { return }
        finishEntrance(); stopRebound()
        layingOut = true
        defer { layingOut = false }
        lastBounds = bounds; lastSafe = safeAreaInsets
        let width = bounds.width, height = bounds.height, safe = safeAreaInsets
        messageLabel.frame = CGRect(x: safe.left + 16, y: safe.top + 4,
                                    width: max(1, width - safe.left - safe.right - 32), height: 44)
        // Reference :523-545. One scene-local coordinate system; no UIScreen.main.
        let dockHeight = max(54, ceil(dockIconSize) + 16)
        let dockTop = max(safe.top + 12, height - safe.bottom - dockHeight - 4)
        var x: CGFloat = 14
        for button in dockButtons {
            button.frame = CGRect(x: x, y: 8, width: max(44, dockIconSize), height: dockHeight - 16)
            button.subviews.first?.center = CGPoint(x: button.bounds.midX, y: button.bounds.midY)
            x += max(44, dockIconSize) + 10
        }
        // Host-only control is a trailing Dock item, preserving cardBottom and
        // every app's reference x/8pt inset. It scrolls rather than covering cards.
        if !clearButton.isHidden {
            clearButton.frame = CGRect(x: x + 2, y: 10, width: 44, height: 44)
            x += max(44, dockIconSize) + 10
        }
        let dockWidth = max(1, min(width - safe.left - safe.right - 28, x + 4))
        dock.bounds = CGRect(x: 0, y: 0, width: dockWidth, height: dockHeight)
        dock.center = CGPoint(x: width / 2, y: dockTop + dockHeight / 2)
        let oldDockOffset = dockScroll.contentOffset.x
        dockScroll.bounds = dock.bounds
        dockScroll.center = dock.center
        dockScroll.contentSize = CGSize(width: x + 4, height: dockHeight)
        dockScroll.contentOffset = CGPoint(x: min(max(0, oldDockOffset), max(0, x + 4 - dockWidth)), y: 0)
        let cardBottom = dock.isHidden ? height - safe.bottom - 16 : dockTop - 28
        let availableHeight = max(35, cardBottom - safe.top)
        emptyLabel.frame = CGRect(x: 0, y: safe.top, width: width, height: availableHeight)
        stride = StackDeckMath.layout(width: width, height: height, safeTop: safe.top, safeBottom: safe.bottom,
                                      hasDock: !dock.isHidden, count: cards.count, source: .zero).stride
        pages.frame = bounds
        pages.contentSize = CGSize(width: width + stride * CGFloat(max(0, cards.count - 1)), height: height)
        for card in cards {
            let geometry = StackDeckMath.layout(width: width, height: height, safeTop: safe.top, safeBottom: safe.bottom,
                                                hasDock: !dock.isHidden, count: cards.count, source: card.sourceSize)
            card.transform = .identity
            card.bounds = CGRect(x: 0, y: 0, width: geometry.width, height: geometry.height + 34)
            card.center = CGPoint(x: geometry.centerX + CGFloat(card.index) * stride, y: geometry.centerY)
            card.updateExpandedFrame()
            card.setNeedsLayout(); card.layoutIfNeeded()
        }
        pages.contentOffset = CGPoint(x: CGFloat(selected) * stride, y: 0)
        updateDeck()
        if !hasEntered && window != nil {
            hasEntered = true
            DispatchQueue.main.async { [weak self] in self?.beginEntrance() }
        }
    }

    private func updateDeck() {
        guard !transitioning, stride > 0 else { return }
        let page = pages.contentOffset.x / stride
        // Reference :654-669. Index order, not distance-to-selection order.
        for card in cards {
            let pose = StackDeckMath.pose(distance: CGFloat(card.index) - page, stride: stride)
            card.resting = CGAffineTransform(a: pose.scale, b: 0, c: 0, d: pose.scale, tx: pose.shift, ty: 0)
            if card !== draggingCard && card !== reboundingCard { card.transform = card.resting }
            card.layer.zPosition = CGFloat(2 + card.index)
            card.alpha = 1
        }
        // Reference :671-684. Titles use only the exposed interval.
        let leftEdge = pages.contentOffset.x, rightEdge = leftEdge + pages.bounds.width
        for card in cards {
            let left = max(leftEdge + 12, card.frame.minX)
            var right = min(rightEdge - 12, card.frame.maxX)
            if card.index + 1 < cards.count { right = min(right, cards[card.index + 1].frame.minX - 5) }
            let iconX = card.convert(CGPoint(x: left, y: 0), from: pages).x
            card.icon.alpha = max(0, min(1, (right - left - 16) / 9))
            card.icon.frame = CGRect(x: iconX, y: 0, width: 25, height: 25)
            let titleWidth = max(0, (right - left) / card.transform.a - 33)
            card.name.frame = CGRect(x: iconX + 33, y: 1, width: titleWidth, height: 24)
            card.name.alpha = max(0, min(1, (titleWidth - 48) / 20)) * card.icon.alpha
            card.accessibilityElementsHidden = card.frame.maxX < leftEdge || card.frame.minX > rightEdge
        }
    }
    private func publishFocus() {
        guard cards.indices.contains(selected) else { return }
        focusGeneration += 1
        let generation = focusGeneration, uuid = cards[selected].uuid
        DispatchQueue.main.async { [weak self] in
            guard let self, !self.invalidated, generation == self.focusGeneration,
                  let manager = self.manager,
                  let index = manager.apps.firstIndex(where: { $0.appUUID == uuid }) else { return }
            if manager.selectedIndex != index { manager.focus(index: index) }
        }
    }
    func scrollViewDidScroll(_ scrollView: UIScrollView) {
        guard scrollView === pages, !layingOut, !transitioning else { return }
        if !cards.isEmpty {
            let next = min(cards.count - 1, max(0, Int((pages.contentOffset.x / stride).rounded())))
            if selected != next { selected = next; publishFocus() }
        }
        UIView.performWithoutAnimation { updateDeck() }
    }
    func scrollViewWillBeginDragging(_ scrollView: UIScrollView) {
        guard scrollView === pages else { return }
        finishEntrance(); stopRebound()
        dragStartPage = (pages.contentOffset.x / max(1, stride)).rounded()
        scrolling = true
    }
    func scrollViewWillEndDragging(_ scrollView: UIScrollView, withVelocity velocity: CGPoint, targetContentOffset: UnsafeMutablePointer<CGPoint>) {
        guard scrollView === pages, !cards.isEmpty else { return }
        let current = pages.contentOffset.x / stride
        let page = StackDeckMath.targetPage(current: current, velocity: velocity.x, start: scrolling ? dragStartPage : current.rounded(), count: cards.count)
        targetContentOffset.pointee = CGPoint(x: page * stride, y: 0)
    }
    func scrollViewDidEndDragging(_ scrollView: UIScrollView, willDecelerate decelerate: Bool) {
        guard scrollView === pages, !decelerate else { return }
        let target = CGFloat(selected) * stride
        if abs(pages.contentOffset.x - target) >= 0.5 {
            let animated = !UIAccessibility.isReduceMotionEnabled
            pages.setContentOffset(CGPoint(x: target, y: 0), animated: animated)
            if animated { return }
        }
        finishScrolling()
    }
    func scrollViewDidEndDecelerating(_ scrollView: UIScrollView) { if scrollView === pages { finishScrolling() } }
    func scrollViewDidEndScrollingAnimation(_ scrollView: UIScrollView) { if scrollView === pages { finishScrolling() } }
    private func finishScrolling() { scrolling = false; setNeedsLayout() }
    func gestureRecognizerShouldBegin(_ gestureRecognizer: UIGestureRecognizer) -> Bool {
        guard !transitioning, !invalidated else { return false }
        if let pan = gestureRecognizer as? UIPanGestureRecognizer {
            let v = pan.velocity(in: self)
            return abs(v.y) > abs(v.x) * 1.2
        }
        return true
    }
    func gestureRecognizer(_ gestureRecognizer: UIGestureRecognizer, shouldReceive touch: UITouch) -> Bool {
        if gestureRecognizer.view === self {
            if touch.view?.isDescendant(of: dockScroll) == true || touch.view?.isDescendant(of: clearButton) == true { return false }
            if cards.contains(where: { touch.view?.isDescendant(of: $0) == true }) { return false }
        }
        return true
    }
    @objc func cardTapped(_ tap: UITapGestureRecognizer) { if let card = tap.view as? StackDeckCard { activate(card) } }
    @objc private func backgroundTapped() { dismissDeck() }
    @objc private func clearAll() { manager?.closeAll() }
    func isCurrent(_ card: StackDeckCard) -> Bool {
        guard !invalidated, !transitioning, cards.contains(where: { $0 === card }), let manager,
              manager.apps.contains(where: { $0.appUUID == card.uuid }) else { return false }
        return manager.restartTarget(for: card.uuid) === card.launch
    }
    @objc func cardPanned(_ pan: UIPanGestureRecognizer) {
        guard let card = pan.view as? StackDeckCard, !transitioning, !invalidated else { return }
        let translation = pan.translation(in: self), velocity = pan.velocity(in: self)
        if pan.state == .began {
            finishEntrance()
            let visible = reboundingCard === card ? card.layer.presentation()?.affineTransform().ty : nil
            dragStartOffset = visible.map { $0 - card.resting.ty } ?? 0
            stopRebound(); draggingCard = card
        }
        guard draggingCard === card else { return }
        if pan.state == .began || pan.state == .changed || pan.state == .ended {
            var y = translation.y + dragStartOffset
            if y > 0 { y = 0.25 * y / (1 + y / max(1, card.preview.bounds.height)) }
            var transform = card.resting; transform.ty += y; card.transform = transform
        }
        guard pan.state == .ended || pan.state == .cancelled || pan.state == .failed else { return }
        draggingCard = nil
        if pan.state == .ended && StackDeckMath.shouldClose(translation: translation, velocityY: velocity.y, startOffset: dragStartOffset, height: card.preview.bounds.height) {
            close(card, velocity: velocity.y); return
        }
        let offset = card.transform.ty - card.resting.ty
        if UIAccessibility.isReduceMotionEnabled || abs(offset) < 0.5 { card.transform = card.resting; updateDeck(); return }
        let v = pan.state == .ended ? max(-4, min(4, velocity.y / -offset)) : 0
        let animator = UIViewPropertyAnimator(duration: 0.32, timingParameters: UISpringTimingParameters(dampingRatio: 0.84, initialVelocity: CGVector(dx: 0, dy: v)))
        rebound = animator; reboundingCard = card
        animator.addAnimations { card.transform = card.resting }
        animator.addCompletion { [weak self] _ in self?.rebound = nil; self?.reboundingCard = nil; self?.updateDeck(); self?.setNeedsLayout() }
        animator.startAnimation()
    }
    private func stopRebound() {
        rebound?.stopAnimation(true); rebound = nil
        reboundingCard?.transform = reboundingCard?.resting ?? .identity
        reboundingCard = nil
    }
    private func finishEntrance() {
        if let entrance, entrance.state == .active { entrance.stopAnimation(false); entrance.finishAnimation(at: .end) }
        entrance = nil
        cards.forEach { $0.layer.removeAnimation(forKey: "stack.stagger.in") }
        dockButtons.forEach { $0.layer.removeAnimation(forKey: "stack.stagger.in") }
    }
    private func align(_ card: StackDeckCard, to frame: CGRect) {
        guard card.preview.bounds.width > 0, card.preview.bounds.height > 0 else { return }
        let target = pages.convert(frame, from: self)
        let sx = target.width / card.preview.bounds.width, sy = target.height / card.preview.bounds.height
        card.transform = CGAffineTransform(a: sx, b: 0, c: 0, d: sy, tx: target.midX - card.center.x,
                                           ty: target.midY - card.center.y - sy * (card.preview.frame.midY - card.bounds.midY))
    }
    private func beginEntrance() {
        guard !invalidated, !transitioning else { return }
        finishEntrance()
        cards.forEach { $0.updateExpandedFrame() }
        let duration: TimeInterval = UIAccessibility.isReduceMotionEnabled ? 0 : 0.38
        backdrop?(true, duration)
        if let card = cards.first(where: { $0.index == selected }), let frame = card.expandedFrame,
           card.sourceVisible {
            for other in cards { other.alpha = other === card ? 1 : 0 }
            align(card, to: frame)
        } else {
            for card in cards { card.alpha = 0; card.transform = card.resting.scaledBy(x: 0.91, y: 0.91); card.transform.ty += 32 }
        }
        dock.transform = CGAffineTransform(translationX: 0, y: 32)
        dockScroll.transform = dock.transform
        dock.alpha = 0; dockScroll.alpha = 0; clearButton.alpha = 0
        animateEntrance(duration: duration, damping: 0.91)
        if !UIAccessibility.isReduceMotionEnabled {
            var step = 0
            for card in cards where abs(card.index - selected) <= 1 {
                fadeIn(card.layer, delay: 0.045 * Double(step)); step += 1
            }
            for (index, button) in dockButtons.enumerated() where button.frame.intersects(dockScroll.bounds) {
                fadeIn(button.layer, delay: 0.03 * Double(index))
            }
        }
    }
    private func fadeIn(_ layer: CALayer, delay: TimeInterval) {
        let fade = CABasicAnimation(keyPath: "opacity")
        fade.fromValue = 0; fade.toValue = 1; fade.duration = 0.26
        fade.timingFunction = CAMediaTimingFunction(name: .easeOut)
        fade.beginTime = layer.convertTime(CACurrentMediaTime(), from: nil) + delay
        fade.fillMode = .backwards
        layer.add(fade, forKey: "stack.stagger.in")
    }
    private func animateEntrance(duration: TimeInterval, damping: CGFloat) {
        let animations = { [weak self] in
            guard let self else { return }
            self.updateDeck(); self.dock.transform = .identity; self.dockScroll.transform = .identity
            self.dock.alpha = 1; self.dockScroll.alpha = 1; self.clearButton.alpha = 1
        }
        if UIAccessibility.isReduceMotionEnabled || duration == 0 { animations(); return }
        let animator = UIViewPropertyAnimator(duration: duration, dampingRatio: damping, animations: animations)
        entrance = animator
        animator.addCompletion { [weak self] _ in self?.entrance = nil }
        animator.startAnimation()
    }
    private func runTransition(duration: TimeInterval, damping: CGFloat, velocity: CGFloat = 0,
                               animations: @escaping () -> Void, completion: @escaping () -> Void) {
        finishEntrance(); stopRebound()
        transitioning = true; pages.isScrollEnabled = false; isUserInteractionEnabled = false
        let done = { [weak self] in
            guard let self, !self.invalidated else { return }
            self.transitioning = false; self.pages.isScrollEnabled = true; self.isUserInteractionEnabled = true
            completion()
        }
        if UIAccessibility.isReduceMotionEnabled { animations(); done(); return }
        let animator = UIViewPropertyAnimator(duration: duration, timingParameters: UISpringTimingParameters(dampingRatio: damping, initialVelocity: CGVector(dx: 0, dy: velocity)))
        transition = animator; animator.addAnimations(animations)
        animator.addCompletion { [weak self] position in
            self?.transition = nil
            if position == .end { done() }
        }
        animator.startAnimation()
    }
    func close(_ card: StackDeckCard, velocity: CGFloat) {
        guard isCurrent(card) else { return }
        finishEntrance(); stopRebound()
        let frame = card.preview.convert(card.preview.bounds, to: self)
        let travel = max(30, frame.maxY + 60)
        runTransition(duration: 0.30, damping: 1, velocity: max(0, min(5, -velocity / travel)), animations: {
            var t = card.transform; t.ty -= travel; card.transform = t; card.alpha = 0
        }) { [weak self, weak card] in
            guard let self, let card, self.isCurrent(card) else { return }
            self.manager?.closeApp(uuid: card.uuid)
            // Real manager confirmation owns removal. Recover if close is refused.
            DispatchQueue.main.async { [weak self] in self?.updateDeck(); self?.setNeedsLayout() }
        }
    }
    func activate(uuid: String) {
        if let card = cards.first(where: { $0.uuid == uuid }) { activate(card) }
        else { manager?.selectApp(uuid: uuid) }
    }
    func activate(_ card: StackDeckCard) {
        guard isCurrent(card) else { return }
        finishEntrance(); stopRebound()
        card.updateExpandedFrame()
        backdrop?(false, 0.34)
        runTransition(duration: 0.34, damping: 0.92, animations: { [weak self] in
            guard let self else { return }
            self.hideDock()
            for other in self.cards { other.icon.alpha = 0; other.name.alpha = 0; if other !== card { other.alpha = 0 } }
            self.align(card, to: card.expandedFrame ?? self.bounds)
            card.preview.layer.cornerRadius = 0
        }) { [weak self, weak card] in
            guard let self, let card, self.isCurrent(card) else { return }
            self.manager?.selectApp(uuid: card.uuid)
            DispatchQueue.main.async { [weak self] in
                guard let self, self.manager?.isVisible == true else { return }
                DispatchQueue.main.async { [weak self] in
                    guard let self, self.manager?.isVisible == true else { return }
                    card.preview.layer.cornerRadius = 28; self.updateDeck(); self.backdrop?(true, 0.15)
                    self.dock.alpha = 1; self.dockScroll.alpha = 1; self.clearButton.alpha = 1
                    self.dock.transform = .identity; self.dockScroll.transform = .identity
                    self.emptyLabel.alpha = 1
                }
            }
        }
    }
    private func hideDock() {
        dock.transform = CGAffineTransform(translationX: 0, y: 32); dockScroll.transform = dock.transform
        dock.alpha = 0; dockScroll.alpha = 0; clearButton.alpha = 0; emptyLabel.alpha = 0
    }
    private func dismissDeck() {
        guard !transitioning else { return }
        backdrop?(false, 0.28)
        runTransition(duration: 0.28, damping: 1, animations: { [weak self] in
            guard let self else { return }
            self.hideDock(); self.pages.alpha = 0
            for card in self.cards { card.transform = card.resting.scaledBy(x: 0.86, y: 0.86); card.transform.ty += 46 }
        }) { [weak self] in self?.manager?.dismiss() }
        // Host policy is intentionally preserved: dismiss to previous window,
        // unlike reference :1274-1279, which explicitly invokes showHome.
    }
    override func accessibilityPerformEscape() -> Bool { dismissDeck(); return true }
    func invalidate() {
        invalidated = true; focusGeneration += 1
        entrance?.stopAnimation(true); transition?.stopAnimation(true); rebound?.stopAnimation(true)
        entrance = nil; transition = nil; rebound = nil
        pages.delegate = nil
        cards.forEach { $0.owner = nil; $0.removeFromSuperview() }
        cards.removeAll(); manager = nil; backdrop = nil
    }
}
