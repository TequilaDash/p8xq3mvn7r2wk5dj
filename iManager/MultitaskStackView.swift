//
//  MultitaskStackView.swift
//  LiveContainer
//
//  图五: 原生 springboard 风格的**堆叠后台界面**.
//  双击辅助触控进入 -> 看到所有在跑的多任务窗口(卡片堆叠, 后一个压前一个),
//  点卡片进入该 app 的多任务窗口, 卡片上滑删除该窗口(结束访客进程).
//  设计:
//   · 实际窗口按 MRU 排序；Dock 只供元数据，未打开的 app 不进入后台
//   · 卡片左右滑动切换, 当前卡片置顶, 相邻卡片始终露出可点击的部分
//   · 点卡片恢复对应窗口; 原生 iPad 窗口激活自己的 scene
//   · 上滑走真实 closeWindow/terminate 路径, 不用删列表冒充关闭
//

import Foundation
import SwiftUI
import UIKit
import Combine

@available(iOS 16.0, *)
/// deck 自己的窗口。SwiftUI 里某个点若返回 nil，窗口默认会让触摸落到下一层
/// 窗口（访客/主屏）——表现就是"点空闲处完全没反应"。这里保证窗口内任何点
/// 都属于 deck 自己。
private final class StackDeckWindow: UIWindow {
    /// deck 自己的内容视图（viewport）。系统对某点返回 nil 或只返回托管根视图时，
    /// 把该点交给它，好让 viewport 自己的轻点/拖动识别器参与。
    weak var deckView: UIView?
    /// 这个点是否属于"不该返回"的区域（卡片、dock）。由 viewport 提供。
    var shouldIgnoreTap: ((CGPoint) -> Bool)?
    /// 窗口级轻点回调：在 sendEvent 里判定，任何手势链都截不走。
    var onWindowTap: (() -> Void)?
    private var tapBegan: (time: TimeInterval, point: CGPoint)?

    override func hitTest(_ point: CGPoint, with event: UIEvent?) -> UIView? {
        let hit = super.hitTest(point, with: event)
        let bare = hit == nil || hit === rootViewController?.view
        if bare, let deckView, deckView.window === self, bounds.contains(point) {
            let local = deckView.convert(point, from: self)
            if deckView.point(inside: local, with: event) { return deckView }
        }
        if let hit { return hit }
        return bounds.contains(point) ? rootViewController?.view : nil
    }

    override func sendEvent(_ event: UIEvent) {
        if event.type == .touches, let touch = event.allTouches?.first {
            switch touch.phase {
            case .began:
                tapBegan = (CACurrentMediaTime(), touch.location(in: self))
            case .ended:
                if let began = tapBegan {
                    let end = touch.location(in: self)
                    let moved = hypot(end.x - began.point.x, end.y - began.point.y)
                    let quick = CACurrentMediaTime() - began.time < 0.7
                    if moved < 10, quick, shouldIgnoreTap?(end) != true {
                        onWindowTap?()
                    }
                }
                tapBegan = nil
            case .cancelled:
                tapBegan = nil
            default:
                break
            }
        }
        super.sendEvent(event)
    }
}

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
    /// 实际在屏的 deck 窗口。hostingWindow 有可能在某种路径上被提前清空，
    /// 这里留一个独立引用，保证"关闭"一定能把窗口从屏幕上撤掉。
    private static weak var liveDeckWindow: UIWindow?
    // Hide the actual hosting windows, not merely UIKit hit testing: remote
    // scene event-deferring regions can otherwise remain eligible for input.
    private var suppressedWindows: [(window: UIWindow, hidden: Bool, interactive: Bool)] = []
    private var changingSuppressedWindows = false
    private weak var previousKeyWindow: UIWindow?
    private var pendingPresentation = false
    private var selectingTargetWindow = false
    private var selectedUUID: String?
    private var pendingFocusUUID: String?
    private var lastRequestIdentifier: String?
    private var closingControllers: [String: ObjectIdentifier] = [:]
    // These survive removal of a card. A menu action is bound to the launch
    // it displayed, never merely to a container a newer guest might reuse.
    private var displayedControllers: [String: AppSceneViewController] = [:]
    private var restartingControllers: [String: ObjectIdentifier] = [:]
    private var dockSubscription: AnyCancellable?
    // Static pictures taken while the guest windows are still on screen. The
    // cards show what each app actually looks like, shrunk, instead of an icon.
    private var previews: [String: UIView] = [:]
    // Session-local recent tasks outlive process/controller removal. These
    // records retain inert pictures and metadata, never a guest/controller.
    private struct RecentTask {
        let controllerID: ObjectIdentifier
        let bundleID: String
        let mode: MultitaskMode
        let model: DockAppModel
        var preview: UIView?
    }
    private var recentTasks: [String: RecentTask] = [:]
    private var launchingRecent = Set<String>()

    @objc(rememberController:)
    public func rememberController(_ controller: AppSceneViewController) {
        precondition(Thread.isMainThread)
        guard let uuid = controller.dataUUID, !uuid.isEmpty,
              let bundleID = controller.bundleId, !bundleID.isEmpty,
              controller.pid > 0 else { return }
        let identity = ObjectIdentifier(controller)
        guard !controller.isUserTerminating, closingControllers[uuid] != identity else { return }
        let previous = recentTasks[uuid]
        // A delayed exit of an older process must not replace the successor.
        if controller.isTerminated, let previous, previous.controllerID != identity { return }
        let info = AppInfoProvider.shared.findAppInfo(appName: bundleID, dataUUID: uuid)
        let decorated = decoratedController(for: controller)
        var picture = previous?.controllerID == identity ? previous?.preview : nil
        if let snapshot = decorated?.stackContentPreview {
            picture = snapshot
        } else if !controller.isTerminated, let source = controller.viewIfLoaded,
                  source.window != nil, source.window?.isHidden == false, !source.bounds.isEmpty, !source.isHidden,
                  decorated?.viewIfLoaded?.isHidden != true {
            source.layoutIfNeeded()
            picture = source.snapshotView(afterScreenUpdates: false) ?? picture
        }
        recentTasks[uuid] = RecentTask(controllerID: identity, bundleID: bundleID,
                                      mode: controller.isNativeWindow ? .nativeWindow : .virtualWindow,
                                      model: DockAppModel(appName: info?.displayName() ?? bundleID,
                                                          appUUID: uuid, appInfo: info, view: nil),
                                      preview: picture)
    }

    @objc(forgetController:)
    public func forgetController(_ controller: AppSceneViewController) {
        precondition(Thread.isMainThread)
        guard let uuid = controller.dataUUID,
              recentTasks[uuid]?.controllerID == ObjectIdentifier(controller) else { return }
        recentTasks.removeValue(forKey: uuid)
    }

    private func launchRecentTask(uuid: String) {
        guard !launchingRecent.contains(uuid), let recent = recentTasks[uuid],
              let app = restartModel(bundleId: recent.bundleID, uuid: uuid) else {
            message = "找不到最近任务的应用或容器，未启动"
            return
        }
        guard !app.isAppRunning else { message = "应用正在启动，请稍候"; return }
        // A retained native scene may still own an exited process record. Do
        // not create a second native entry or remove a live successor.
        if #available(iOS 16.1, *), recent.mode == .nativeWindow,
           let oldInfo = MultitaskWindowManager.appDict[uuid] {
            guard let old = appControllers().first(where: { $0.dataUUID == uuid && $0.isTerminated }),
                  ObjectIdentifier(old) == recent.controllerID else {
                message = "原生窗口记录尚未释放，未重复启动"
                return
            }
            MultitaskWindowManager.removeAppInfo(oldInfo)
        }
        launchingRecent.insert(uuid)
        Task { @MainActor [self] in
            defer { self.launchingRecent.remove(uuid) }
            do {
                try await app.runApp(multitask: true, containerFolderName: uuid,
                                     bundleIdOverride: recent.bundleID, multitaskWindowMode: recent.mode)
                guard let replacement = self.appControllers().first(where: { $0.dataUUID == uuid && !$0.isTerminated }) else {
                    throw "应用未建立新的多任务窗口"
                }
                self.rememberController(replacement)
                MultitaskManager.recordUse(container: uuid)
                self.selectApp(uuid: uuid)
            } catch {
                self.showRestartMessage("最近任务启动失败：\(error.localizedDescription)")
            }
        }
    }
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
        center.addObserver(self, selector: #selector(recencyDidChange(_:)), name: MultitaskManager.recencyChanged, object: nil)
        dockSubscription = MultitaskDockManager.shared.$apps
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in
                guard let self, !self.changingSuppressedWindows,
                      self.isVisible || self.pendingPresentation else { return }
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
            if !self.isVisible, self.pendingFocusUUID == nil, let uuid = self.currentAppUUID() {
                MultitaskManager.recordUse(container: uuid)
                self.pendingFocusUUID = uuid
            }
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

    /// 辅助触控单击回主屏：deck 是独立的 alert+1 窗口，不拆掉它会一直盖着主屏。
    func dismissDeckForHome() {
        guard Thread.isMainThread else { return }
        pendingPresentation = false
        clearStoredRequest()
        restoreSuppressedWindows()
        detachWindow(restoreKey: false)
    }

    /// 关闭最近任务并回到"上一级"：上一层可能是某个 App，不一定是主屏。
    /// 回主屏是辅助触控按钮的职责，不该由"点空白"顺手做掉。
    func dismissDeckRestoringPrevious() {
        precondition(Thread.isMainThread)
        pendingPresentation = false
        clearStoredRequest()
        detachWindow(restoreKey: true)
    }

    func dismissToHome() {
        precondition(Thread.isMainThread)
        restoreSuppressedWindows()
        MultitaskDockManager.shared.minimizeAllWindows()
        NotificationCenter.default.post(name: .lcCloseHostScreens, object: nil)
        if let home = MainWindow.window {
            previousKeyWindow = home
            if let scene = home.windowScene, scene.activationState != .foregroundActive {
                UIApplication.shared.requestSceneSessionActivation(scene.session, userActivity: nil, options: nil) { error in
                    NSLog("[TDHome] return Home scene failed: %@", error.localizedDescription)
                }
            }
        }
        pendingPresentation = false
        clearStoredRequest()
        detachWindow(restoreKey: true)
    }

    // Target activation owns focus. Never queue dismiss(), which restores the
    // old Home key window one run-loop turn after the guest is already shown.
    private func finishAppSelection() {
        pendingPresentation = false
        clearStoredRequest()
        detachWindow(restoreKey: false)
        selectingTargetWindow = false
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
        if identifier != lastRequestIdentifier {
            lastRequestIdentifier = identifier
            if let uuid = request["container"] as? String, !uuid.isEmpty,
               appControllers().contains(where: { $0.dataUUID == uuid && !$0.isTerminated }) {
                // The guest supplies its container before opening the host;
                // shared host UIWindow identity cannot identify a virtual app.
                MultitaskManager.recordUse(container: uuid)
                pendingFocusUUID = uuid
            }
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
        guard !changingSuppressedWindows, pendingPresentation else { return }
        if let window = hostingWindow, !window.isHidden,
           window.windowScene?.activationState == .foregroundActive,
           hostingController?.viewIfLoaded?.window === window {
            refreshApps()
            focusPendingApp()
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
        focusPendingApp()
        let host = UIHostingController(rootView: AnyView(MultitaskStackView().environmentObject(self)))
        host.view.backgroundColor = .clear
        host.view.isOpaque = false
        let window = StackDeckWindow(windowScene: scene)
        // 1.1.113: 全屏盖住。此前 frame=target.frame（上一个前台访客窗口的区域），
        // deck 覆盖不到的屏幕空白处触摸会直接落到底下的访客窗口——用户实测
        // “从堆叠后台空闲处点击能操作多任务 app 界面”。窗口盖满屏后，viewport
        // 的 hitTest 对空白返回 self 消费，卡片/dock 之外的任何触摸都不再漏。
        window.frame = scene.coordinateSpace.bounds
        window.backgroundColor = .clear
        window.windowLevel = UIWindow.Level(rawValue: UIWindow.Level.alert.rawValue + 1)
        window.rootViewController = host
        previousKeyWindow = scene.windows.first(where: \.isKeyWindow) ?? target
        hostingController = host
        hostingWindow = window
        Self.liveDeckWindow = window
        window.makeKeyAndVisible()
        // Capture pictures before hiding. A hidden hosting window removes its
        // remote surfaces from the input/display tree as well as UIKit hits.
        // Do not hide AssistiveTouch/alerts, and never move a guest to a new scene.
        suppressUnderlyingWindows()
        window.makeKey() // hiding the former key must not leave focus elsewhere
        guard window.isKeyWindow, !window.isHidden, host.view.window === window,
              scene.activationState == .foregroundActive else {
            detachWindow()
            return
        }
        isVisible = true
        pendingPresentation = false
        clearStoredRequest()
        NSLog("[TDHome] app stack attached: scene=%@ cards=%ld", scene.session.persistentIdentifier, apps.count)
    }

    private func suppressUnderlyingWindows() {
        guard !changingSuppressedWindows, let deck = hostingWindow else { return }
        changingSuppressedWindows = true
        defer { changingSuppressedWindows = false }
        let windows = UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.flatMap(\.windows)
        // 访客窗口不一定是 .normal：TweakLoader 会把窗口抬到 1000 或
        // lastObject+1，那些窗口比 deck 的 alert+1 还高，只过滤 .normal
        // 等于放它们继续收触摸——这就是"空白处点击仍然透传"的真正原因。
        // 除了 deck 自己和辅助触控，其余全部隐藏，detach 时按原值恢复。
        // deck 在 alert+1(2001)；访客窗口是 1000 或 lastObject+1，都在它下面；
        // 辅助触控在 alert+2(2002) 之上。按层级区分即可，不用去问控制器。
        for window in windows where window !== deck && !window.isHidden
            && window.windowLevel < deck.windowLevel {
            if !suppressedWindows.contains(where: { $0.window === window }) {
                suppressedWindows.append((window, window.isHidden, window.isUserInteractionEnabled))
            }
            window.isUserInteractionEnabled = false
            window.isHidden = true
        }
    }

    private func restoreSuppressedWindows() {
        let wasChanging = changingSuppressedWindows
        changingSuppressedWindows = true
        defer { changingSuppressedWindows = wasChanging }
        let saved = suppressedWindows
        suppressedWindows.removeAll()
        for state in saved {
            state.window.isUserInteractionEnabled = state.interactive
            state.window.isHidden = state.hidden
        }
    }

    private func detachWindow(restoreKey: Bool = true) {
        let wasChanging = changingSuppressedWindows
        changingSuppressedWindows = true
        defer { changingSuppressedWindows = wasChanging }
        restoreSuppressedWindows()
        let previous = previousKeyWindow
        hostingWindow?.isHidden = true
        Self.liveDeckWindow?.isHidden = true
        Self.liveDeckWindow = nil
        hostingWindow?.rootViewController = nil
        hostingWindow?.windowScene = nil
        hostingController = nil
        hostingWindow = nil
        isVisible = false
        apps.removeAll()
        previews.removeAll()
        displayedControllers.removeAll()
        focus(index: 0)
        if restoreKey {
            // 回到"上一级"：优先恢复 deck 出现之前的那个 key window。
            // 之前 fallback 只认 windowLevel == .normal，而访客窗口是 1000
            // （TweakLoader 设的），永远匹配不到 → 退化成主屏，
            // 用户看到的就是"从应用里退出再回主屏"。这里放宽到任意可见窗口。
            func visible(_ win: UIWindow) -> Bool {
                !win.isHidden && win.alpha > 0 && win.windowScene?.activationState == .foregroundActive
            }
            // 拆成独立语句：写成一条 ?? 链会让类型检查超时（CI 实测）。
            var restoreTarget: UIWindow? = nil
            if let prev = previous, visible(prev) { restoreTarget = prev }
            if restoreTarget == nil {
                restoreTarget = previous?.windowScene?.windows.first { visible($0) && $0.rootViewController != nil }
            }
            if restoreTarget == nil {
                let scenes = UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }
                for scene in scenes where scene.activationState == .foregroundActive {
                    if let found = scene.windows.first(where: { visible($0) && $0.rootViewController != nil }) {
                        restoreTarget = found
                        break
                    }
                }
            }
            restoreTarget?.makeKey()
        }
        previousKeyWindow = nil
    }

    @objc private func applicationDidActivate() {
        guard !changingSuppressedWindows else { return }
        readStoredRequest()
        presentIfPossible()
    }

    @objc private func sceneDidActivate(_ notification: Notification) {
        if let scene = notification.object as? UIWindowScene, !isVisible {
            let native = appControllers().first { $0.isNativeWindow && $0.viewIfLoaded?.window?.windowScene === scene }
            if let uuid = native?.dataUUID { MultitaskManager.recordUse(container: uuid) }
        }
        applicationDidActivate()
    }

    @objc private func recencyDidChange(_ notification: Notification) {
        if isVisible && !changingSuppressedWindows { refreshApps() }
    }

    private func focusPendingApp() {
        let uuid = pendingFocusUUID
        pendingFocusUUID = nil
        focus(index: uuid.flatMap { id in apps.firstIndex { $0.appUUID == id } } ?? 0)
    }

    @objc private func sceneWillDeactivate(_ notification: Notification) {
        guard !changingSuppressedWindows,
              let scene = notification.object as? UIWindowScene, hostingWindow?.windowScene === scene else { return }
        if selectingTargetWindow {
            pendingPresentation = false
            detachWindow(restoreKey: false)
            return
        }
        pendingPresentation = isVisible || pendingPresentation
        detachWindow()
    }

    @objc private func sceneDidDisconnect(_ notification: Notification) {
        sceneWillDeactivate(notification)
        presentIfPossible()
    }

    @objc private func windowsDidChange(_ notification: Notification) {
        // makeKeyAndVisible posts synchronously while presentation is mounting.
        if changingSuppressedWindows { return }
        if let window = notification.object as? UIWindow, window === hostingWindow { return }
        if isVisible {
            refreshApps() // capture a newly visible guest before suppressing it
            suppressUnderlyingWindows()
            hostingWindow?.makeKey()
        }
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
        // A host window can contain several guests. Resolve virtual z-order
        // first; a shared keyWindow alone cannot identify the current app.
        let keyWindow = UIApplication.shared.connectedScenes
            .compactMap { $0 as? UIWindowScene }
            .filter { $0.activationState == .foregroundActive }
            .flatMap(\.windows)
            .first(where: { $0.isKeyWindow && $0 !== hostingWindow })
        guard let keyWindow else { return nil }
        if let native = appControllers().first(where: {
            $0.isNativeWindow && !$0.isTerminated && $0.viewIfLoaded?.window === keyWindow
        }) { return native.dataUUID }
        let host = MultitaskDockManager.shared.windowHostingView
        if host.window != nil, host.window === keyWindow, !host.isHidden, host.alpha > 0 {
            for view in host.subviews.reversed() where !view.isHidden && view.alpha > 0 {
                if let decorated = view._viewDelegate() as? DecoratedAppSceneViewController,
                   !decorated.isStashed, !decorated.appSceneVC.isTerminated {
                    return decorated.appSceneVC.dataUUID
                }
            }
        }
        // Hidden virtual siblings share that window too. Do not select one
        // just because its controller still belongs to the key host window.
        return nil
    }

    private func refreshApps() {
        // A retained termination card is still a recent task, not evidence of
        // resident memory. Preserve its restart target and last-use order.
        let controllers = appControllers().filter { $0.pid > 0 }
        // Independent keys avoid read-modify-write races with other guests.
        let defaults = LCUtils.appGroupUserDefault
        let now = Date().timeIntervalSince1970
        for controller in controllers where !controller.isTerminated && !controller.isUserTerminating {
            defaults.set(["bundleId": controller.bundleId ?? "", "ts": now],
                         forKey: "TDLiveGuestPid.\(controller.pid)")
        }
        defaults.synchronize()
        let byUUID = Dictionary(uniqueKeysWithValues: controllers.compactMap { controller -> (String, AppSceneViewController)? in
            guard let uuid = controller.dataUUID else { return nil }
            return (uuid, controller)
        })
        let previousControllers = displayedControllers
        for controller in controllers {
            if controller.isUserTerminating, let uuid = controller.dataUUID,
               recentTasks[uuid]?.controllerID == ObjectIdentifier(controller) {
                recentTasks.removeValue(forKey: uuid)
            } else {
                rememberController(controller)
            }
        }
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
            if controller.isTerminated {
                freshPreviews[uuid] = decorated?.stackContentPreview
                continue
            }
            let source = controller.viewIfLoaded
            let wrapperVisible = (decorated?.viewIfLoaded).map { !$0.isHidden && $0.alpha > 0 } ?? true
            if let source, wrapperVisible, !source.isHidden, source.alpha > 0,
               source.window != nil, source.window?.isHidden == false, !source.bounds.isEmpty,
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
        // A transient nil snapshot must not replace the last real picture.
        // Never carry a previous process's picture into a same-UUID relaunch.
        for (uuid, controller) in byUUID where freshPreviews[uuid] == nil {
            if previousControllers[uuid] === controller, let previous = previews[uuid] {
                freshPreviews[uuid] = previous
            }
        }
        for (uuid, recent) in recentTasks where freshPreviews[uuid] == nil {
            freshPreviews[uuid] = recent.preview
        }
        previews = freshPreviews
        // A recent record requires a real launch, never an installed-app list.
        // Process exit does not erase history. Explicit close does.
        let order = MultitaskManager.recentOrder(candidates: controllers.compactMap(\.dataUUID) + recentTasks.keys.sorted())
        var dockByUUID: [String: DockAppModel] = [:]
        for app in dockApps where dockByUUID[app.appUUID] == nil {
            dockByUUID[app.appUUID] = app
        }
        apps = order.compactMap { uuid in
            let controller = byUUID[uuid]
            if let controller, closingControllers[uuid] == ObjectIdentifier(controller) || controller.isUserTerminating { return nil }
            if let existing = dockByUUID[uuid], let controller,
               existing.view != nil, existing.view === decoratedController(for: controller)?.viewIfLoaded {
                return existing
            }
            guard let controller else { return recentTasks[uuid]?.model }
            let existing = dockByUUID[uuid]
            let info = existing?.appInfo ?? AppInfoProvider.shared.findAppInfo(appName: existing?.appName ?? controller.bundleId ?? "", dataUUID: uuid)
            let name = existing?.appName ?? info?.displayName() ?? controller.bundleId ?? uuid
            let view: UIView? = decoratedController(for: controller)?.view ?? controller.viewIfLoaded
            return DockAppModel(appName: name, appUUID: uuid, appInfo: info, view: view)
        }
        focus(index: selectedUUID.flatMap { uuid in apps.firstIndex(where: { $0.appUUID == uuid }) } ?? selectedIndex)
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
            guard let controller = controllers.first(where: { $0.dataUUID == uuid }) else {
                self.launchRecentTask(uuid: uuid)
                return
            }
            if controller.isTerminated {
                self.restartApp(uuid: uuid, controller: controller)
                return
            }
            guard self.closingControllers[uuid] != ObjectIdentifier(controller) else { return }
            if let target = self.decoratedController(for: controller) {
                guard let view = target.viewIfLoaded, let container = view.superview else {
                    self.message = "窗口暂时无法恢复"
                    return
                }
                // 先摆内容，最后才恢复可见：反过来会在恢复那一帧露出旧帧，
                // 用户实测"进入那一瞬间只占上半屏"。
                if target.isStashed { target.unstash(animated: false) }
                // 访客窗口可能是窗口化状态（isMaximized == false），恢复可见那一帧
                // 就会露出"居中小卡 + 上下黑边"（用户截图 IMG_0666）。
                // 在恢复可见之前就把它铺满，那一帧直接是全屏。
                // 有挂起的分屏请求时，后面 bringMultitaskViewToFront 里的
                // claimPhoneSplitRequestForWindow 会把窗口重新塞回一格，把这里
                // 刚做的全屏覆盖掉。deck 选卡要的是整屏，先清掉挂起请求。
                LCWindowSnapManager.shared.cancelPhoneSplitRequest()
                // 不能只看 isMaximized：iPhone 上它默认就是 YES，而窗口可能正处在
                // 手机分屏的一格里。方法自身幂等，已全屏且未吸附时立即返回。
                target.maximizeWindowWithoutAnimation()
                for other in controllers {
                    if let decorated = self.decoratedController(for: other), decorated !== target { decorated.minimizeWindow() }
                }
                // 访客的真实画面由 scene 异步设值决定尺寸：decorated 视图已经是
                // 全屏，但 surface 还停在窗口化大小。等它跟上再露出、再收回 deck
                // 窗口，否则那一帧就是"居中小卡+上下黑边"（IMG_0666）。
                target.reveal(whenSurfaceFillsWindow: { [weak self, weak target, weak view, weak container] in
                    guard let self, let target, let view, let container else { return }
                    if !MultitaskDockManager.shared.bringMultitaskViewToFront(uuid: uuid, fromDeck: true) {
                        if let pip = PiPManager.shared, pip.isPiP(withDecoratedVC: target) { pip.stopPiP() }
                        // The deck snapshot already performed the entrance. Reveal
                        // the real surface in its final pose, without a second fly-in.
                        MultitaskDockManager.shared.revealForDeckSelection(target)
                        container.bringSubviewToFront(view)
                        target.revealWindowControls()
                    }
                    self.restoreSuppressedWindows()
                    MultitaskManager.recordUse(container: uuid)
                    self.finishAppSelection()
                    view.window?.makeKey()
                })
            } else if let targetWindow = controller.viewIfLoaded?.window,
                      let scene = targetWindow.windowScene {
                self.selectingTargetWindow = true
                self.restoreSuppressedWindows()
                UIApplication.shared.requestSceneSessionActivation(scene.session, userActivity: nil, options: nil) { error in
                    NSLog("[TDHome] app stack activation failed: %@", error.localizedDescription)
                    self.present()
                }
                // Native app window, not the saved Home window, owns focus.
                MultitaskManager.recordUse(container: uuid)
                self.finishAppSelection()
                targetWindow.makeKey()
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
            guard !self.launchingRecent.contains(uuid) else { return }
            guard let controller = self.appControllers().first(where: { $0.dataUUID == uuid }) else {
                self.recentTasks.removeValue(forKey: uuid)
                self.refreshApps()
                return
            }
            let identifier = ObjectIdentifier(controller)
            guard self.closingControllers[uuid] != identifier else { return }
            self.closingControllers[uuid] = identifier
            self.recentTasks.removeValue(forKey: uuid)
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
                        // Keep the deck covering Home until the replacement
                        // has been revealed and owns focus.
                        // Bring only the replacement forward; selectApp's
                        // minimize-other-windows policy is not a restart.
                        if let window = self.decoratedController(for: replacement),
                           let view = window.viewIfLoaded, let container = view.superview {
                            MultitaskDockManager.shared.revealForDeckSelection(window)
                            container.bringSubviewToFront(view)
                            window.revealWindowControls()
                            self.finishAppSelection()
                            view.window?.makeKey()
                        } else if let targetWindow = replacement.viewIfLoaded?.window,
                                  let scene = targetWindow.windowScene {
                            self.selectingTargetWindow = true
                            self.restoreSuppressedWindows()
                            UIApplication.shared.requestSceneSessionActivation(scene.session, userActivity: nil, options: nil) { error in
                                DispatchQueue.main.async {
                                    self.showRestartMessage("应用已重新启动，但窗口打开失败：\(error.localizedDescription)")
                                }
                            }
                            self.finishAppSelection()
                            targetWindow.makeKey()
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
        GeometryReader { geometry in
            // A scaledToFill wallpaper may have a wider ideal size than the
            // screen. It must never participate in the deck's layout proposal.
            Color.clear
                .frame(width: geometry.size.width, height: geometry.size.height)
                .overlay {
                    backgroundLayer
                        .frame(width: geometry.size.width, height: geometry.size.height)
                        .clipped()
                        .opacity(backdropVisible ? 1 : 0)
                        .allowsHitTesting(false)
                }
                .overlay {
                    StackDeckRepresentable(manager: manager, dockApps: dockManager.apps,
                                           showClearAll: showClearAll) { visible, duration in
                        withAnimation(.easeOut(duration: duration)) { backdropVisible = visible }
                    }
                    .frame(width: geometry.size.width, height: geometry.size.height)
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

    func makeUIView(context: Context) -> StackDeckViewport { StackDeckViewport(frame: .zero) }
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
    /// 模糊预览：盖在快照之上、图标之下。只在对应 App 的开关打开时显示。
    let blurView = UIVisualEffectView(effect: UIBlurEffect(style: .regular))
    let icon = UIImageView()
    private let protectionMark = UIImageView()
    private var appIcon: UIImage?
    let centerIcon = UIImageView()
    let unavailableLabel = UILabel()
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
        // One exact circular shape for rendering, hit testing and menu lift.
        // Do not approximate a continuous corner with a circular hit region.
        preview.layer.cornerCurve = .circular
        preview.clipsToBounds = true
        preview.isUserInteractionEnabled = false
        centerIcon.contentMode = .scaleAspectFit
        centerIcon.layer.cornerCurve = .continuous
        centerIcon.clipsToBounds = true
        centerIcon.tintColor = .white
        addSubview(preview)
        blurView.isUserInteractionEnabled = false
        blurView.isHidden = true
        preview.addSubview(blurView)
        protectionMark.contentMode = .scaleAspectFit
        protectionMark.tintColor = UIColor(white: 0.88, alpha: 1)
        protectionMark.clipsToBounds = true
        protectionMark.isUserInteractionEnabled = false
        protectionMark.isHidden = true
        preview.addSubview(protectionMark)
        addSubview(icon)
        addSubview(name)
        preview.addSubview(centerIcon)
        unavailableLabel.text = "画面快照暂不可用"
        unavailableLabel.font = .systemFont(ofSize: 13)
        unavailableLabel.textColor = .secondaryLabel
        unavailableLabel.textAlignment = .center
        unavailableLabel.numberOfLines = 2
        preview.addSubview(unavailableLabel)
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
            appIcon = info?.iconIsDarkIcon(false)
            icon.image = appIcon ?? UIImage(systemName: "app.fill")
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
                preview.insertSubview(snapshot, at: 0)
            }
        }
        // Never derive preview aspect from the decorated window (:562-564).
        sourceSize = snapshot?.bounds.size ?? launch?.viewIfLoaded?.bounds.size ?? .zero
        updateExpandedFrame()
        // PiP keeps its explicit existing placeholder; never pretend an app
        // icon is the last screen when a normal task snapshot was unavailable.
        centerIcon.isHidden = !isPiP
        unavailableLabel.isHidden = snapshot != nil || isPiP
        // 模糊预览：只模糊画面内容，图标与名称保持清晰（参考系统多任务）。
        let blurMap = (LCUtils.appGroupUserDefault.dictionary(forKey: "iManagerRecentTasksBlurPerApp") as? [String: Bool]) ?? [:]
        let protected = (blurMap[uuid] ?? false) && snapshot != nil
        blurView.isHidden = !protected
        protectionMark.isHidden = !protected
        protectionMark.image = protected ? (appIcon ?? Self.protectionFallback) : nil
        preview.backgroundColor = snapshot == nil ? UIColor(white: 0.16, alpha: 1) : .black
        preview.layer.borderWidth = snapshot == nil ? 0.5 : 0
        preview.layer.borderColor = UIColor.white.withAlphaComponent(0.20).cgColor
        accessibilityHint = isPiP ? "此 App 的画面保留在画中画中" : (snapshot == nil ? "画面快照暂不可用，轻点切换到此 App" : "轻点打开，上滑关闭，长按更多操作")
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
            // 等比缩放（aspect fit）：分别缩放会把画面纵向压扁，
            // 这就是"纵向排布还是有挤压感"的来源。
            let scale = min(preview.bounds.width / sourceSize.width,
                            preview.bounds.height / sourceSize.height)
            snapshot.transform = CGAffineTransform(scaleX: scale, y: scale)
            snapshot.center = CGPoint(x: preview.bounds.midX, y: preview.bounds.midY)
        }
        blurView.frame = preview.bounds
        // Bottom to top: snapshot -> blur -> clear protection mark -> PiP
        // centerIcon -> unavailableLabel. Header icon/name are outside preview.
        preview.bringSubviewToFront(blurView)
        preview.bringSubviewToFront(protectionMark)
        preview.bringSubviewToFront(centerIcon)
        let markSide = min(64, min(preview.bounds.width, preview.bounds.height) * 0.22)
        protectionMark.bounds = CGRect(x: 0, y: 0, width: markSide, height: markSide)
        protectionMark.center = CGPoint(x: preview.bounds.midX, y: preview.bounds.height * 0.54)
        protectionMark.layer.cornerRadius = appIcon == nil ? 0 : markSide * 0.225
        preview.bringSubviewToFront(unavailableLabel)
        let side: CGFloat = isPiP ? 54 : min(94, max(44, min(preview.bounds.width, preview.bounds.height) * 0.30))
        centerIcon.frame = CGRect(x: (preview.bounds.width - side) / 2, y: (preview.bounds.height - side) / 2, width: side, height: side)
        centerIcon.layer.cornerRadius = side * 0.225
        unavailableLabel.frame = preview.bounds.insetBy(dx: 12, dy: 12)
        layer.shadowPath = UIBezierPath(roundedRect: preview.frame, cornerRadius: 28).cgPath
    }
    // Reference fallback: split hexagon, a narrow seam and a four-point star.
    private static let protectionFallback: UIImage = {
        UIGraphicsImageRenderer(size: CGSize(width: 64, height: 64)).image { _ in
            UIColor(white: 0.88, alpha: 1).setFill()
            for mirrored in [false, true] {
                let points: [CGPoint] = [(0.46, 0.04), (0.10, 0.25), (0.10, 0.75),
                                        (0.46, 0.96), (0.46, 0.62), (0.33, 0.50),
                                        (0.46, 0.38)].map { x, y in
                    CGPoint(x: CGFloat(mirrored ? 1 - x : x) * 64, y: CGFloat(y) * 64)
                }
                let half = UIBezierPath()
                half.move(to: points[0])
                for point in points.dropFirst() { half.addLine(to: point) }
                half.close(); half.fill()
            }
            let star = UIBezierPath()
            star.move(to: CGPoint(x: 32, y: 27))
            star.addLine(to: CGPoint(x: 34, y: 30))
            star.addLine(to: CGPoint(x: 37, y: 32))
            star.addLine(to: CGPoint(x: 34, y: 34))
            star.addLine(to: CGPoint(x: 32, y: 37))
            star.addLine(to: CGPoint(x: 30, y: 34))
            star.addLine(to: CGPoint(x: 27, y: 32))
            star.addLine(to: CGPoint(x: 30, y: 30))
            star.close(); star.fill()
        }
    }()

    static func previewPath(bounds: CGRect, radius: CGFloat) -> UIBezierPath {
        UIBezierPath(roundedRect: bounds, cornerRadius: min(max(0, radius), min(bounds.width, bounds.height) / 2))
    }

    private func menuPreview() -> UITargetedPreview? {
        guard owner?.isCurrent(self) == true, preview.window != nil, !preview.bounds.isEmpty else { return nil }
        let parameters = UIPreviewParameters()
        parameters.backgroundColor = .clear
        parameters.visiblePath = Self.previewPath(bounds: preview.bounds, radius: preview.layer.cornerRadius)
        return UITargetedPreview(view: preview, parameters: parameters)
    }

    func contextMenuInteraction(_ interaction: UIContextMenuInteraction,
                                previewForHighlightingMenuWithConfiguration configuration: UIContextMenuConfiguration) -> UITargetedPreview? {
        menuPreview()
    }
    func contextMenuInteraction(_ interaction: UIContextMenuInteraction,
                                previewForDismissingMenuWithConfiguration configuration: UIContextMenuConfiguration) -> UITargetedPreview? {
        menuPreview()
    }

    override func accessibilityActivate() -> Bool { owner?.activate(self); return true }
    @objc private func closeAccessible() -> Bool { owner?.close(self, velocity: 0); return true }
    @objc private func restartAccessible() -> Bool { perform { $0.restartApp(uuid: self.uuid, controller: self.launch) }; return true }
    private func perform(_ action: (MultitaskStackManager) -> Void) {
        guard let owner, owner.isCurrent(self), let manager = owner.manager else { return }
        action(manager)
    }
    func contextMenuInteraction(_ interaction: UIContextMenuInteraction, configurationForMenuAtLocation location: CGPoint) -> UIContextMenuConfiguration? {
        guard let owner, owner.isCurrent(self), owner.prepareContextMenu(for: self) else { return nil }
        // previewProvider returns a UIViewController, NOT UITargetedPreview.
        // Explicit highlight/dismiss previews above lift only this card surface.
        return UIContextMenuConfiguration(identifier: nil, previewProvider: nil) { [weak self] _ in
            guard let self, self.owner?.isCurrent(self) == true else { return nil }
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
    /// Dock 栏样式：clear = 透明玻璃，frosted = 磨砂（默认）。键 TDAppStackDockStyle。
    private func applyDockStyle() {
        let style = LCUtils.appGroupUserDefault.string(forKey: "TDAppStackDockStyle") ?? "frosted"
        if style == "clear" {
            if #available(iOS 26.0, *), SharedModel.isLiquidGlassEnabled {
                // Liquid Glass：系统玻璃材质，随背景折射，比纯透明更贴近系统。
                dock.effect = UIGlassEffect(style: .clear)
                dock.contentView.backgroundColor = .clear
            } else {
                // 老系统退化：去掉模糊，只留极淡的底，能看见背后内容。
                dock.effect = nil
                dock.contentView.backgroundColor = UIColor.white.withAlphaComponent(0.06)
            }
        } else {
            dock.effect = UIBlurEffect(style: .systemThinMaterialDark)
            dock.contentView.backgroundColor = .clear
        }
    }

    /// 内存胶囊：同样适配 Liquid Glass，并支持透明度（键 iManagerMemoryCapsuleOpacity）。
    private func applyMemoryCapsuleStyle() {
        if #available(iOS 26.0, *), SharedModel.isLiquidGlassEnabled {
            memoryCapsule.effect = UIGlassEffect(style: .clear)
        } else {
            memoryCapsule.effect = UIBlurEffect(style: .systemUltraThinMaterial)
        }
        let stored = LCUtils.appGroupUserDefault.object(forKey: "iManagerMemoryCapsuleOpacity") as? Double
        memoryCapsule.alpha = CGFloat(min(max(stored ?? 0.85, 0.2), 1.0))
    }
    private let dockScroll = UIScrollView()
    private let clearButton = UIButton(type: .system)
    private let emptyLabel = UILabel()
    private let messageLabel = UILabel()
    private var cards: [StackDeckCard] = []
    private let blankPan = UIPanGestureRecognizer()
    /// 空白处按下时的位置：用于 touchesEnded 兜底判定"这是一次轻点"。
    /// 挂在 deck 窗口根视图（祖先层）上的返回手势：它能看到本窗口内所有触摸，
    /// 不受 hitTest 把空白交给谁、也不受子层手势链截断的影响。
    private weak var windowTap: UITapGestureRecognizer?
    private var blankTouchStart: CGPoint?
    private var lastBlankDismiss: TimeInterval = 0
    private var blankStartX: CGFloat = 0
    private var blankStartY: CGFloat = 0
    private let memoryCapsule = UIVisualEffectView(effect: UIBlurEffect(style: .systemUltraThinMaterial))
    private let memoryLabel = UILabel()
    private var memoryTimer: Timer?
    private var memoryReadPending = false
    private var memoryPID: Int32?
    private var memoryControllerID: ObjectIdentifier?
    private var memoryBytes: UInt64?
    private let memoryQueue = DispatchQueue(label: "com.zcontainer.deck.memory", qos: .utility)
    private var dockIDs: [String] = []
    private var dockButtons: [UIButton] = []
    private var stride: CGFloat = 1
    private var selected = 0
    private var dragStartPage: CGFloat = 0
    /// 纵向排布卡片拖动的方向：0 未定、1 横滑清除、2 竖滑滚动。
    private var columnDragAxis = 0
    private var scrolling = false
    private var layingOut = false
    private var transitioning = false
    /// 一旦开始关闭，就不再允许布局/入场/重绘把 deck 重新显示出来。
    private var dismissing = false
    private var invalidated = false
    private var hasEntered = false
    private var showClearAll = false
    private var lastBounds = CGRect.null
    private var lastSafe = UIEdgeInsets.zero
    private var appliedColumnLayout: Bool?
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
        pages.bounces = true
        pages.alwaysBounceHorizontal = true
        pages.contentInsetAdjustmentBehavior = .never
        addSubview(pages)
        dock.layer.cornerRadius = 19
        dock.layer.cornerCurve = .continuous
        dock.clipsToBounds = true
        dock.layer.borderWidth = 0.5
        dock.layer.borderColor = UIColor.white.withAlphaComponent(0.16).cgColor
        applyDockStyle()
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
        // 空白处的轻点与拖动挂在 viewport 自己身上：只有 hitTest 把触摸交给
        // 哪个视图，那个视图上的手势才参与。把空白单独交给一个垫底视图，
        // 会让网格区的拖动/卡片手势整体失效（卡片滑不掉、上下翻不动）。
        let tap = UITapGestureRecognizer(target: self, action: #selector(backgroundTapped))
        tap.delegate = self
        addGestureRecognizer(tap)
        blankPan.addTarget(self, action: #selector(blankPanned(_:)))
        blankPan.delegate = self
        addGestureRecognizer(blankPan)
        memoryCapsule.isUserInteractionEnabled = false
        memoryCapsule.clipsToBounds = true
        memoryCapsule.layer.cornerRadius = 16
        memoryCapsule.isHidden = true
        memoryLabel.font = .monospacedDigitSystemFont(ofSize: 12, weight: .semibold)
        memoryLabel.textColor = .label
        memoryLabel.textAlignment = .center
        memoryLabel.adjustsFontSizeToFitWidth = true
        memoryLabel.minimumScaleFactor = 0.8
        memoryLabel.isUserInteractionEnabled = false
        memoryCapsule.contentView.addSubview(memoryLabel)
        addSubview(memoryCapsule) // above pages; contextMenu is a system overlay
    }
    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    override func hitTest(_ point: CGPoint, with event: UIEvent?) -> UIView? {
        guard !isHidden, alpha >= 0.01, isUserInteractionEnabled, self.point(inside: point, with: event) else { return nil }
        if transitioning || invalidated { return self }
        if !dockScroll.isHidden, dockScroll.alpha >= 0.01 {
            let local = dockScroll.convert(point, from: self)
            if dockScroll.point(inside: local, with: event) {
                return dockScroll.hitTest(local, with: event) ?? self
            }
        }
        // No super.hitTest fallback: that would re-admit transparent card frames.
        // 空白必须由本视图自己接收。交给 pages（UIScrollView）会让它吞掉轻点，
        // 表现为"空白点不动、只有摸着卡片才划得动"（test34 实测）。
        // 纵向排布的滚动由 blankPan 直接驱动 pages.contentOffset，不靠 UIScrollView。
        if let card = frontmostPreviewCard(at: point) { return card }
        return self
    }

    private func frontmostPreviewCard(at point: CGPoint) -> StackDeckCard? {
        guard !pages.isHidden, pages.alpha >= 0.01, pages.frame.contains(point) else { return nil }
        var winner: StackDeckCard?
        var bestZ = -CGFloat.greatestFiniteMagnitude
        for card in cards where !card.isHidden && card.isUserInteractionEnabled
            && !card.preview.isHidden && card.alpha >= 0.01 {
            // 用 UIView 自己的坐标换算：它会把 card 的 transform 一并算进去，
            // 比手写 CALayer 换算可靠。之前的 presentation-layer 版本一旦算错，
            // 空白点会被判成"点在卡片上"，空白处就完全没有反应。
            let local = card.preview.convert(point, from: self)
            // 两套独立空间都同意才算命中：卡片在 pages 坐标里的 frame，
            // 与 preview 自己的局部坐标。任何一边说不算，就按空白处理，
            // 避免"空白点被算成点了卡片而毫无反应"。
            let inPages = pages.convert(point, from: self)
            guard card.frame.contains(inPages), card.preview.bounds.contains(local) else { continue }
            let z = card.layer.zPosition
            if winner == nil || z > bestZ { winner = card; bestZ = z }
        }
        return winner
    }

    func prepareContextMenu(for card: StackDeckCard) -> Bool {
        guard isCurrent(card), draggingCard == nil, !pages.isDragging,
              let manager, let logical = manager.apps.firstIndex(where: { $0.appUUID == card.uuid }) else { return false }
        finishEntrance(); stopRebound()
        focusGeneration += 1 // discard a queued focus publication for another card
        layingOut = true
        pages.setContentOffset(pages.contentOffset, animated: false)
        scrolling = false
        selected = card.index
        if !isColumnLayout {
            pages.setContentOffset(CGPoint(x: CGFloat(selected) * stride, y: 0), animated: false)
        }
        layingOut = false
        updateDeck()
        manager.focus(index: logical) // focus only; does NOT record MRU or launch
        updateMemoryTarget()
        return isCurrent(card)
    }

    @objc private func blankPanned(_ pan: UIPanGestureRecognizer) {
        guard !transitioning, !invalidated else { return }
        if isColumnLayout {
            let limit = max(0, pages.contentSize.height - pages.bounds.height)
            switch pan.state {
            case .began:
                finishEntrance(); stopRebound()
                pages.setContentOffset(pages.contentOffset, animated: false)
                blankStartY = pages.contentOffset.y
                scrolling = true
            case .changed:
                let y = min(max(0, blankStartY - pan.translation(in: self).y), limit)
                pages.setContentOffset(CGPoint(x: 0, y: y), animated: false)
            case .ended, .cancelled, .failed:
                pages.setContentOffset(CGPoint(x: 0, y: min(max(0, pages.contentOffset.y), limit)), animated: false)
                finishScrolling()
            default: break
            }
            return
        }
        switch pan.state {
        case .began:
            finishEntrance(); stopRebound()
            pages.setContentOffset(pages.contentOffset, animated: false)
            blankStartX = pages.contentOffset.x
            dragStartPage = (blankStartX / max(1, stride)).rounded()
            scrolling = true
        case .changed:
            // 允许越界拖出 overscroll（原生后台卡效果），松手由 targetPage 归位回弹。
            let x = blankStartX - pan.translation(in: self).x
            pages.setContentOffset(CGPoint(x: x, y: 0), animated: false)
        case .ended, .cancelled, .failed:
            let velocity = pan.state == .ended ? -pan.velocity(in: self).x / max(1, pages.bounds.width) : 0
            let page = StackDeckMath.targetPage(current: pages.contentOffset.x / max(1, stride), velocity: velocity,
                                                start: dragStartPage, count: cards.count)
            let animated = !UIAccessibility.isReduceMotionEnabled
            pages.setContentOffset(CGPoint(x: page * stride, y: 0), animated: animated)
            if !animated || abs(pages.contentOffset.x - page * stride) < 0.5 { finishScrolling() }
        default: break
        }
    }

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
        // Logical MRU index 0 maps to the last visual slot. This preserves
        // LCOrbit :654-668 (negative compression, increasing z), not its FIFO.
        let apps = Array(manager.apps.filter { seen.insert($0.appUUID).inserted }.reversed())
        let old = cards
        let modeChanged = appliedColumnLayout != nil && appliedColumnLayout != isColumnLayout
        let changed = modeChanged || old.map(\.uuid) != apps.map(\.appUUID) || apps.contains { app in
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
                transitioning = false; pages.isScrollEnabled = !isColumnLayout; isUserInteractionEnabled = true
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
        let desired = cards.isEmpty ? 0 : cards.count - 1 - min(max(0, manager.selectedIndex), cards.count - 1)
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
            if wasEntered && !modeChanged && !transitioning && !UIAccessibility.isReduceMotionEnabled {
                for card in cards {
                    if let frame = oldFrames[card.uuid] { align(card, to: frame) }
                }
                animateEntrance(duration: 0.28, damping: 0.88)
            }
        } else if !scrolling && draggingCard == nil && selected != desired && !transitioning {
            selected = desired
            if !isColumnLayout {
                let animated = !UIAccessibility.isReduceMotionEnabled
                scrolling = animated
                pages.setContentOffset(CGPoint(x: CGFloat(selected) * stride, y: 0), animated: animated)
            }
            updateDeck()
        }
        updateMemoryTarget()
        setNeedsLayout()
    }

    /// 返回手势挂在 deck 窗口根视图（祖先层）上：本窗口内所有触摸它都看得到，
    /// 不受 hitTest 把空白交给谁、也不受子层手势链截断的影响。只在卡片与 dock
    /// 之外的区域接管。窗口变更时先摘旧的再挂新的。
    private func installWindowTap() {
        if let tap = windowTap { tap.view?.removeGestureRecognizer(tap) }
        windowTap = nil
        // 窗口级 sendEvent 判定：不经过任何手势识别器，子层吞不掉。
        // 每次都要重新绑定：窗口若被复用，旧闭包指向已失效的 viewport，
        // shouldIgnoreTap 会恒为 true，兜底就永远不触发。
        if let deckWindow = window as? StackDeckWindow {
            deckWindow.deckView = self
            deckWindow.shouldIgnoreTap = { [weak self] point in
                guard let self, !self.invalidated else { return true }
                let local = self.convert(point, from: self.window)
                if self.frontmostPreviewCard(at: local) != nil { return true }
                if !self.dockScroll.isHidden,
                   self.dockScroll.point(inside: self.dockScroll.convert(local, from: self), with: nil) {
                    return true
                }
                return false
            }
            deckWindow.onWindowTap = { [weak self] in self?.backgroundTapped() }
        }
        // 挂在窗口本身上：它是本窗口所有视图的祖先，窗口内任何触摸它都能看到，
        // 不依赖 hitTest 把空白交给谁，也不会被任何子层手势链抢先。
        guard let host = window, !invalidated else { return }
        let tap = UITapGestureRecognizer(target: self, action: #selector(backgroundTapped))
        tap.delegate = self
        tap.cancelsTouchesInView = false
        host.addGestureRecognizer(tap)
        windowTap = tap
    }

    override func didMoveToWindow() {
        super.didMoveToWindow()
        installWindowTap()
        if window != nil, !invalidated {
            lastBounds = .null; setNeedsLayout()
            if memoryTimer == nil {
                let timer = Timer(timeInterval: 2.5, repeats: true) { [weak self] _ in self?.refreshMemory() }
                timer.tolerance = 0.25
                RunLoop.main.add(timer, forMode: .common)
                memoryTimer = timer
            }
            updateMemoryTarget()
            refreshMemory()
        } else {
            memoryTimer?.invalidate(); memoryTimer = nil
            memoryCapsule.isHidden = true
        }
    }

    private func selectedMemoryController() -> AppSceneViewController? {
        guard cards.indices.contains(selected), let controller = cards[selected].launch,
              !controller.isTerminated, !controller.isUserTerminating, controller.pid > 0,
              manager?.restartTarget(for: cards[selected].uuid) === controller else { return nil }
        return controller
    }

    private func updateMemoryTarget() {
        let controller = selectedMemoryController()
        let pid = controller?.pid
        let identity = controller.map { ObjectIdentifier($0) }
        if memoryPID != pid || memoryControllerID != identity {
            memoryPID = pid
            memoryControllerID = identity
            memoryBytes = nil
        }
        renderMemory()
    }

    private func renderMemory() {
        // 透明度/玻璃材质每次渲染都重读，设置改完立刻生效。
        applyMemoryCapsuleStyle()
        let unit = LCUtils.appGroupUserDefault.string(forKey: "TDMemoryUnit") == "GB" ? "GB" : "MB"
        // 「显示内存信息」开关：键 TDAppStackShowMemory，未写入时缺省开。
        let showsMemory = LCUtils.appGroupUserDefault.object(forKey: "TDAppStackShowMemory") as? Bool ?? true
        if showsMemory, memoryPID != nil, let bytes = memoryBytes, bytes > 0 {
            memoryLabel.text = TDMemoryManagerView.fmt(bytes, unit: unit)
            memoryCapsule.isHidden = false
            memoryCapsule.accessibilityLabel = "选中访客内存 " + (memoryLabel.text ?? "")
        } else {
            memoryLabel.text = nil
            memoryCapsule.isHidden = true
        }
        layoutHeader()
    }

    private func refreshMemory() {
        guard !invalidated, window != nil else { return }
        updateMemoryTarget()
        guard !memoryReadPending, let controller = selectedMemoryController() else { return }
        let pid = controller.pid
        let identity = ObjectIdentifier(controller)
        memoryReadPending = true
        // One libproc sample at a time off the main queue; only UInt64? comes
        // back to UIKit, with launch identity checked before displaying it.
        memoryQueue.async { [weak self] in
            // The controller already owns the PID; a missing preferences entry
            // must not suppress a readable memory measurement.
            let bytes = TDMemoryManagerView.footprint(pid: pid)
            DispatchQueue.main.async { [weak self] in
                guard let self else { return }
                self.memoryReadPending = false
                guard !self.invalidated, self.window != nil,
                      let current = self.selectedMemoryController(), current.pid == pid,
                      ObjectIdentifier(current) == identity else { return }
                self.memoryBytes = bytes
                self.renderMemory()
            }
        }
    }

    private func layoutHeader() {
        applyMemoryCapsuleStyle()
        let safe = safeAreaInsets
        let available = max(0, bounds.width - safe.left - safe.right - 32)
        // 32pt high; 12pt horizontal inset, 16pt right safe-area margin.
        let natural = ceil(memoryLabel.intrinsicContentSize.width) + 24
        let width = min(max(76, natural), min(160, available * 0.42))
        memoryCapsule.frame = CGRect(x: bounds.maxX - safe.right - 16 - width,
                                     y: safe.top + 10, width: width, height: 32)
        memoryLabel.frame = memoryCapsule.bounds.insetBy(dx: 12, dy: 7)
        let reserve = memoryCapsule.isHidden ? 0 : width + 12
        let messageWidth = available - reserve
        if !memoryCapsule.isHidden && messageWidth < 120 {
            // Narrow split/native viewport: message goes below, never overlays.
            messageLabel.frame = CGRect(x: safe.left + 16, y: safe.top + 54, width: max(1, available), height: 44)
        } else {
            messageLabel.frame = CGRect(x: safe.left + 16, y: safe.top + 4, width: max(1, messageWidth), height: 44)
        }
    }

    override func safeAreaInsetsDidChange() { super.safeAreaInsetsDidChange(); setNeedsLayout() }
    override func layoutSubviews() {
        super.layoutSubviews()
        // 窗口/根控制器可能晚于 didMoveToWindow 就绪，这里补挂一次。
        if windowTap == nil { installWindowTap() }
        guard !dismissing else { return }
        layoutHeader()
        guard !invalidated, !transitioning, draggingCard == nil, !scrolling,
              !pages.isDragging, !pages.isDecelerating, bounds.width > 0, bounds.height > 0 else { return }
        guard lastBounds != bounds || lastSafe != safeAreaInsets || appliedColumnLayout != isColumnLayout else { return }
        finishEntrance(); stopRebound()
        layingOut = true
        defer { layingOut = false }
        let oldColumnY = appliedColumnLayout == true ? pages.contentOffset.y : 0
        appliedColumnLayout = isColumnLayout
        lastBounds = bounds; lastSafe = safeAreaInsets
        let width = bounds.width, height = bounds.height, safe = safeAreaInsets
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
        if isColumnLayout {
            // Card height includes its 34pt title; pages clips above the Dock.
            let side: CGFloat = 14
            let gap: CGFloat = 12
            // Reserve the header band so the memory capsule cannot cover titles.
            let gridTop = safe.top + 54
            let gridHeight = max(1, cardBottom - gridTop)
            let cardWidth = max(1, (width - side * 2 - gap) / 2)
            // 1.9 ≈ 手机屏幕高宽比（390:844）。用 1.45 会把卡片压扁，
            // 看起来就是"纵向排布被压缩"。
            // 卡片高度按访客真实画面比例算，取不到才退回 1.9。
            let aspect = cards.first.map { card -> CGFloat in
                let size = card.sourceSize
                guard size.width > 1, size.height > 1 else { return 1.9 }
                return size.height / size.width
            } ?? 1.9
            let previewHeight = max(1, min(cardWidth * min(max(aspect, 1.4), 2.3), gridHeight - 34))
            let cardHeight = previewHeight + 34
            let rowPitch = cardHeight + gap
            let rows = (cards.count + 1) / 2
            let usedHeight = CGFloat(rows) * cardHeight + CGFloat(max(0, rows - 1)) * gap
            stride = width
            // 纵向排布下由 blankPan 直接改 contentOffset，关掉 UIScrollView 自己的
            // 手势，否则它会延迟/吞掉空白处的触摸，点击就再也到不了 backgroundTapped。
            pages.isScrollEnabled = false
            pages.alwaysBounceHorizontal = false
            pages.alwaysBounceVertical = false
            pages.frame = CGRect(x: 0, y: gridTop, width: width, height: gridHeight)
            pages.contentSize = CGSize(width: width, height: max(gridHeight, usedHeight + 12))
            for card in cards {
                let column = card.index % 2
                let row = card.index / 2
                card.transform = .identity
                card.bounds = CGRect(x: 0, y: 0, width: cardWidth, height: cardHeight)
                card.center = CGPoint(
                    x: side + cardWidth / 2 + CGFloat(column) * (cardWidth + gap),
                    y: CGFloat(row) * rowPitch + cardHeight / 2
                )
                card.updateExpandedFrame()
                card.setNeedsLayout(); card.layoutIfNeeded()
            }
            pages.contentOffset = CGPoint(x: 0, y: min(max(0, oldColumnY), max(0, pages.contentSize.height - gridHeight)))
        } else {
            pages.isScrollEnabled = true
            pages.alwaysBounceHorizontal = true
            pages.alwaysBounceVertical = false
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
        }
        updateDeck()
        if !hasEntered && window != nil {
            hasEntered = true
            DispatchQueue.main.async { [weak self] in self?.beginEntrance() }
        }
    }

    /// 「纵向排布」：两列网格，卡片不再左右滑动。设置键 iManagerRecentTasksLayout。
    private var isColumnLayout: Bool {
        (LCUtils.appGroupUserDefault.string(forKey: "iManagerRecentTasksLayout") ?? "stack") == "column"
    }

    private func updateDeck() {
        guard !dismissing else { return }
        if isColumnLayout {
            // 网格模式不做形变，卡片按行排好即可。
            for card in cards {
                if card !== draggingCard && card !== reboundingCard { card.transform = .identity }
                card.resting = .identity
                card.layer.zPosition = CGFloat(2 + card.index)
                card.alpha = 1
                card.icon.frame = CGRect(x: 0, y: 0, width: 25, height: 25)
                card.name.frame = CGRect(x: 33, y: 1, width: max(0, card.bounds.width - 33), height: 24)
                card.icon.alpha = 1
                card.name.alpha = 1
                card.accessibilityElementsHidden = !card.frame.intersects(pages.bounds)
            }
            return
        }
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
            if isColumnLayout {
                // 纵向排布没有横向分页：选中"当前视口内最靠上的那张卡"。
                // 之前这里被整段跳过，selected 恒为 0，若第 0 张卡没有
                // launch controller，内存胶囊就永远不显示。
                let top = pages.contentOffset.y
                var best = 0
                var bestDistance = CGFloat.greatestFiniteMagnitude
                for card in cards {
                    let distance = abs(card.frame.minY - top)
                    if distance < bestDistance { bestDistance = distance; best = card.index }
                }
                if selected != best { selected = best; publishFocus(); updateMemoryTarget() }
            } else {
                let next = min(cards.count - 1, max(0, Int((pages.contentOffset.x / stride).rounded())))
                if selected != next { selected = next; publishFocus(); updateMemoryTarget() }
            }
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
        guard scrollView === pages, !cards.isEmpty, !isColumnLayout else { return }
        let current = pages.contentOffset.x / stride
        let page = StackDeckMath.targetPage(current: current, velocity: velocity.x, start: scrolling ? dragStartPage : current.rounded(), count: cards.count)
        targetContentOffset.pointee = CGPoint(x: page * stride, y: 0)
    }
    func scrollViewDidEndDragging(_ scrollView: UIScrollView, willDecelerate decelerate: Bool) {
        guard scrollView === pages, !decelerate else { return }
        if isColumnLayout { finishScrolling(); return }
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
    private func finishScrolling() {
        scrolling = false
        // 停止滚动后重新定位选中卡片并重绘胶囊：只靠 selected 变化会漏掉
        // "滚动停下来但选中索引没变"的情况，胶囊就停在不显示状态。
        updateMemoryTarget()
        renderMemory()
        setNeedsLayout()
    }
    // UIView 自带 gestureRecognizerShouldBegin:, 子类实现必须标 override（CI 类型检查抓出）。
    override func gestureRecognizerShouldBegin(_ gestureRecognizer: UIGestureRecognizer) -> Bool {
        guard !invalidated else { return false }
        if let pan = gestureRecognizer as? UIPanGestureRecognizer {
            guard !transitioning else { return false }
            let v = pan.velocity(in: self)
            if pan === blankPan {
                // 轻点也会产生极小的速度；不设门槛时 pan 抢在 tap 之前开始，
                // tap.require(toFail: blankPan) 于是永远失败——表现就是
                // "空白处点了没反应、回不到上一级"。
                // 用"是否已经真的移动"判断，而不是速度阈值：轻点也会产生
                // 几十点/秒的速度，阈值法必然误判（点空白没反应就是这么来的）。
                // 手指没移动时 pan 不开始，tap 才能正常触发。
                let moved = pan.translation(in: self)
                let distance = max(abs(moved.x), abs(moved.y))
                let speed = max(abs(v.x), abs(v.y))
                guard distance > 8 || speed > 300 else { return false }
                return isColumnLayout ? abs(v.y) > abs(v.x) * 1.2 : abs(v.x) > abs(v.y) * 1.2
            }
            // 纵向排布：横滑清除、竖滑滚动网格，都由 cardPanned 按实际位移
            // 分流。这里预判方向会把竖滑判 false，而空白手势又不接收落在
            // 卡片上的触摸，竖滑就无主（"无法滑动浏览"就是这么来的）。
            if isColumnLayout { return true }
            return abs(v.y) > abs(v.x) * 1.2
        }
        // 轻点（空白返回）是这里唯一入口：transitioning 一旦卡住，tap 永远
        // 进不来 dismissDeck，空白点从此失效。复位后放行。
        if transitioning {
            transition?.stopAnimation(true); transition = nil
            transitioning = false
            pages.isScrollEnabled = !isColumnLayout
        }
        return true
    }
    func gestureRecognizer(_ gestureRecognizer: UIGestureRecognizer, shouldReceive touch: UITouch) -> Bool {
        // 祖先层返回手势：只排除卡片与 dock，其余位置（含所有空格）都接管。
        if gestureRecognizer === windowTap {
            guard let hit = touch.view else { return false }
            if hit === dockScroll || hit.isDescendant(of: dockScroll) { return false }
            if cards.contains(where: { hit === $0 || hit.isDescendant(of: $0) }) { return false }
            return true
        }
        // 空白拖动只认落在 viewport 本身的触摸。
        if gestureRecognizer === blankPan { return touch.view === self }
        // 背景轻点与卡片手势共用本 delegate：只有挂在 viewport 自己身上的
        // 识别器需要排除卡片/dock；卡片自己的识别器必须放行，否则卡片既
        // 滑不掉也点不开。
        if gestureRecognizer.view === self {
            // pages 本身就是卡片容器：落在它身上（而不是某张卡或 dock）的触摸
            // 属于空白，必须放行给背景轻点。
            if touch.view === self || touch.view === pages { return true }
            if touch.view?.isDescendant(of: dockScroll) == true { return false }
            if cards.contains(where: { touch.view === $0 || touch.view?.isDescendant(of: $0) == true }) { return false }
        }
        return true
    }
    @objc func cardTapped(_ tap: UITapGestureRecognizer) {
        guard let card = tap.view as? StackDeckCard else { return }
        if isCurrent(card) { activate(card); return }
        // 命中的卡片不是当前这张时，什么都不做会让"点空白回上一级"失效，
        // 这里按空白处理。
        dismissDeck()
    }
    @objc private func backgroundTapped() { dismissDeck() }
    override func touchesBegan(_ touches: Set<UITouch>, with event: UIEvent?) {
        super.touchesBegan(touches, with: event)
        blankTouchStart = touches.first.flatMap { $0.view === self ? $0.location(in: self) : nil }
    }
    override func touchesEnded(_ touches: Set<UITouch>, with event: UIEvent?) {
        super.touchesEnded(touches, with: event)
        defer { blankTouchStart = nil }
        guard let start = blankTouchStart, let touch = touches.first, touch.view === self else { return }
        let end = touch.location(in: self)
        // 位移超过 10pt 视为拖动（滚动），不当作轻点。
        guard hypot(end.x - start.x, end.y - start.y) < 10 else { return }
        dismissDeck()
    }
    override func touchesCancelled(_ touches: Set<UITouch>, with event: UIEvent?) {
        super.touchesCancelled(touches, with: event)
        blankTouchStart = nil
    }
    @objc private func clearAll() { manager?.closeAll() }
    func isCurrent(_ card: StackDeckCard) -> Bool {
        guard !invalidated, !transitioning, cards.contains(where: { $0 === card }), let manager,
              manager.apps.contains(where: { $0.appUUID == card.uuid }) else { return false }
        return manager.restartTarget(for: card.uuid) === card.launch
    }
    @objc func cardPanned(_ pan: UIPanGestureRecognizer) {
        guard let card = pan.view as? StackDeckCard, !transitioning, !invalidated else { return }
        let translation = pan.translation(in: self), velocity = pan.velocity(in: self)
        // 纵向排布里，卡片上的竖滑交给网格滚动（网格本身可上下翻），
        // 左右滑才是"清除这个多任务后台"，与堆叠排布的上滑关闭区分开。
        if isColumnLayout {
            // 一个手势两种用途：竖滑滚网格（卡片不动），横滑清除这个后台。
            // 方向只在真的动起来之后才定，避免轻点被判成拖动。
            switch pan.state {
            case .began:
                finishEntrance(); stopRebound()
                dragStartOffset = pages.contentOffset.y
                columnDragAxis = 0
            case .changed:
                if columnDragAxis == 0 {
                    let settled = max(abs(translation.x), abs(translation.y)) > 8
                    if settled {
                        columnDragAxis = abs(translation.y) > abs(translation.x) ? 2 : 1
                        if columnDragAxis == 1 { draggingCard = card } else { scrolling = true }
                    }
                }
                if draggingCard === card {
                    var t = card.resting
                    t.tx += translation.x
                    card.transform = t
                } else if columnDragAxis == 2 {
                    let limit = max(0, pages.contentSize.height - pages.bounds.height)
                    pages.contentOffset = CGPoint(x: 0, y: min(max(0, dragStartOffset - translation.y), limit))
                }
            default:
                let wasCard = draggingCard === card
                draggingCard = nil
                let horizontal = abs(translation.x) > 60 && abs(translation.x) > abs(translation.y) * 1.2
                if pan.state == .ended && wasCard && horizontal {
                    closeHorizontally(card, direction: translation.x < 0 ? -1 : 1, velocity: velocity.x)
                } else {
                    if wasCard {
                        UIView.animate(withDuration: 0.24, delay: 0, usingSpringWithDamping: 0.86,
                                       initialSpringVelocity: 0, options: [.allowUserInteraction]) {
                            card.transform = card.resting
                        }
                    }
                    finishScrolling()
                }
                columnDragAxis = 0
            }
            return
        }
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
        guard !invalidated, !transitioning, !dismissing else { return }
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
        // Keep the full-screen viewport interactive as an input shield; its
        // hitTest consumes transition touches instead of exposing live guests.
        transitioning = true; pages.isScrollEnabled = false; isUserInteractionEnabled = true
        let done = { [weak self] in
            // 状态复位只在有效时做，但 completion 必须无条件执行：视图一旦在
            // 转场中被卸载，隐藏窗口那一步会被静默丢弃，结果就是"点了返回，
            // deck 原样留在屏幕上"（dock 与内存胶囊都还在）。
            if let self, !self.invalidated {
                self.transitioning = false
                self.pages.isScrollEnabled = !self.isColumnLayout
                self.isUserInteractionEnabled = true
            }
            completion()
        }
        if UIAccessibility.isReduceMotionEnabled { animations(); done(); return }
        let animator = UIViewPropertyAnimator(duration: duration, timingParameters: UISpringTimingParameters(dampingRatio: damping, initialVelocity: CGVector(dx: 0, dy: velocity)))
        transition = animator; animator.addAnimations(animations)
        animator.addCompletion { [weak self] position in
            self?.transition = nil
            // 动画被中途打断（position != .end）时同样必须复位：否则
            // transitioning 永久为 true，hitTest 会吞掉所有空白点击，
            // 表现为"有卡片时空白怎么点都没反应、无卡片时反而正常"。
            done()
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
    /// 纵向排布的横滑关闭：卡片沿横向飞出，不做上滑位移。
    private func closeHorizontally(_ card: StackDeckCard, direction: CGFloat, velocity: CGFloat) {
        guard isCurrent(card) else { return }
        finishEntrance(); stopRebound()
        let travel = bounds.width + 80
        runTransition(duration: 0.30, damping: 1, velocity: max(0, min(5, abs(velocity) / travel)), animations: {
            var t = card.resting
            t.tx += direction * travel
            card.transform = t
            card.alpha = 0
        }) { [weak self, weak card] in
            guard let self, let card, self.isCurrent(card) else { return }
            self.manager?.closeApp(uuid: card.uuid)
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
            // 回前台一律全屏：用 expandedFrame（访客当前窗口矩形）会让卡片
            // 先飞进一个窗口化小矩形再跳到全屏，就是"进入瞬间居中小卡+黑边"。
            self.align(card, to: self.bounds)
            card.preview.layer.cornerRadius = 0
        }) { [weak self, weak card] in
            guard let self, let card, self.isCurrent(card) else { return }
            self.manager?.selectApp(uuid: card.uuid)
            // 这里只有在"选卡没成功"时才需要把 deck 还原。成功路径下 manager
            // 正在等访客画面就绪、isVisible 仍为 true，若在这里 updateDeck()，
            // 刚铺满的卡片会被按网格姿态重算——那就是进入瞬间的"居中小卡"。
            DispatchQueue.main.async { [weak self] in
                guard let self, self.manager?.isVisible == true else { return }
                guard self.manager?.message != nil else { return } // 成功路径不还原
                card.preview.layer.cornerRadius = 28; self.updateDeck(); self.backdrop?(true, 0.15)
                self.dock.alpha = 1; self.dockScroll.alpha = 1; self.clearButton.alpha = 1
                self.dock.transform = .identity; self.dockScroll.transform = .identity
                self.emptyLabel.alpha = 1
            }
        }
    }
    private func hideDock() {
        dock.transform = CGAffineTransform(translationX: 0, y: 32); dockScroll.transform = dock.transform
        dock.alpha = 0; dockScroll.alpha = 0; clearButton.alpha = 0; emptyLabel.alpha = 0
    }
    private func dismissDeck() {
        // tap 手势、touchesEnded 兜底与窗口级判定可能同时命中，只执行一次。
        let now = CACurrentMediaTime()
        guard now - lastBlankDismiss > 0.45 else { return }
        lastBlankDismiss = now
        // 关闭期间禁止布局/入场/updateDeck 把内容重新显示：
        // 卡片尺寸变化会触发 lastBounds = .null → 整屏重排 + beginEntrance，
        // 表现就是"点了返回，deck 又原地复活"。
        dismissing = true
        // 不再因 transitioning 直接放弃：卡住的标志位会让"点空白返回"彻底失效。
        if transitioning { finishEntrance(); stopRebound(); transitioning = false }
        // 转场期间视图可能被卸载（manager 被清空），先把要调用的对象抓住。
        let manager = self.manager
        backdrop?(false, 0.28)
        runTransition(duration: 0.28, damping: 1, animations: { [weak self] in
            guard let self else { return }
            self.hideDock(); self.pages.alpha = 0
            for card in self.cards { card.transform = card.resting.scaledBy(x: 0.86, y: 0.86); card.transform.ty += 46 }
        }) { [weak self] in
            if let manager {
                manager.dismissDeckRestoringPrevious()
            } else {
                // manager 已失效（视图被卸载等）：至少把窗口从屏幕上撤掉，
                // 否则用户点完返回，deck 会一直留在最上层。
                self?.window?.isHidden = true
            }
        }
        // Blank/escape means Home, unlike selecting a card, which must never
        // restore the old Home key window after revealing the target.
    }
    override func accessibilityPerformEscape() -> Bool { dismissDeck(); return true }
    func invalidate() {
        invalidated = true; dismissing = true; focusGeneration += 1
        memoryTimer?.invalidate(); memoryTimer = nil
        memoryBytes = nil; memoryPID = nil; memoryControllerID = nil; memoryCapsule.isHidden = true
        entrance?.stopAnimation(true); transition?.stopAnimation(true); rebound?.stopAnimation(true)
        entrance = nil; transition = nil; rebound = nil
        pages.delegate = nil
        cards.forEach { $0.owner = nil; $0.removeFromSuperview() }
        cards.removeAll(); manager = nil; backdrop = nil
    }
}
