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
    /// The app whose settings sheet is open over the stack.
    @Published var settingsTarget: StackSettingsTarget?

    // A window retains its root controller, and the manager owns both until
    // dismissal. Retaining only host.view does not retain a hosting controller.
    private var hostingController: UIHostingController<AnyView>?
    private var hostingWindow: UIWindow?
    private weak var previousKeyWindow: UIWindow?
    private var pendingPresentation = false
    private var selectedUUID: String?
    private var closingControllers: [String: ObjectIdentifier] = [:]
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
        var seen = Set<String>()
        func visit(_ controller: UIViewController) {
            if let app = controller as? AppSceneViewController,
               let uuid = app.dataUUID, !uuid.isEmpty, seen.insert(uuid).inserted {
                result.append(app)
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

    private func refreshApps() {
        let controllers = appControllers()
        let byUUID = Dictionary(uniqueKeysWithValues: controllers.compactMap { controller -> (String, AppSceneViewController)? in
            guard let uuid = controller.dataUUID else { return nil }
            return (uuid, controller)
        })
        closingControllers = closingControllers.filter { uuid, identifier in
            byUUID[uuid].map { ObjectIdentifier($0) == identifier } ?? false
        }
        // Take the preview from the live window, never from a hidden/minimized
        // one: a hidden view snapshots empty and would show a black card.
        var freshPreviews: [String: UIView] = [:]
        for controller in controllers {
            guard let uuid = controller.dataUUID else { continue }
            let decorated = decoratedController(for: controller)
            let source = decorated?.viewIfLoaded ?? controller.viewIfLoaded
            if let source, !source.isHidden, source.alpha > 0,
               source.window != nil, !source.bounds.isEmpty,
               let snapshot = source.snapshotView(afterScreenUpdates: false) {
                freshPreviews[uuid] = snapshot
            } else if let snapshot = decorated?.stackPreview {
                freshPreviews[uuid] = snapshot
            }
        }
        let dockApps = MultitaskDockManager.shared.apps
        for app in dockApps where freshPreviews[app.appUUID] == nil {
            if let decorated = app.view?._viewDelegate() as? DecoratedAppSceneViewController,
               let snapshot = decorated.stackPreview {
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
            if let existing = dockByUUID[uuid], existing.view != nil { return existing }
            guard let controller else { return dockByUUID[uuid] }
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
            DataManager.shared.model.showHomeScreen()
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

    /// The Home Screen's model for the app in a stack card, when the app is
    /// still installed.
    private func appModel(for uuid: String) -> LCAppModel? {
        DataManager.shared.model.apps.values.first { app in
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
            guard let app = self.appModel(for: uuid) else {
                self.message = "找不到该应用的信息"
                return
            }
            self.settingsTarget = StackSettingsTarget(id: uuid, app: app)
        }
    }

    @objc public func openInSplitScreen(uuid: String) {
        DispatchQueue.main.async {
            guard let app = self.appModel(for: uuid) else {
                self.message = "找不到该应用的信息"
                return
            }
            guard DataManager.shared.model.canOpenInSplitScreen(app) else {
                self.message = "该应用不能分屏运行"
                return
            }
            DataManager.shared.model.showHomeScreen()
            self.dismiss()
            DataManager.shared.model.openInSplitScreen(app)
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
}

/// The app whose settings sheet is open over the stack.
@available(iOS 16.0, *)
struct StackSettingsTarget: Identifiable {
    let id: String
    let app: LCAppModel
}


@available(iOS 16.0, *)
struct MultitaskStackView: View {
    @EnvironmentObject var manager: MultitaskStackManager
    @State private var dragOffset: CGSize = .zero
    @State private var dragAxis: Axis?
    @State private var draggedUUID: String?

    var body: some View {
        ZStack {
            Rectangle()
                .fill(.ultraThinMaterial)
                .overlay(Color.black.opacity(0.35))
                .ignoresSafeArea()
                .onTapGesture { manager.dismiss() }
            VStack(spacing: 14) {
                HStack {
                    Text("多任务后台").font(.title2.bold())
                    Spacer()
                    Button { manager.dismiss() } label: { Image(systemName: "xmark.circle.fill").font(.title2) }
                        .accessibilityLabel("关闭后台视图")
                }
                .padding(.horizontal, 24)
                if manager.apps.isEmpty {
                    Spacer()
                    Image(systemName: "rectangle.stack").font(.system(size: 46, weight: .light))
                    Text("没有正在运行的多任务窗口").font(.callout)
                    Spacer()
                } else {
                    GeometryReader { geometry in deck(in: geometry.size) }
                    HStack(spacing: 28) {
                        Button { moveSelection(by: -1) } label: { Image(systemName: "chevron.left") }
                            .disabled(manager.selectedIndex == 0)
                            .accessibilityLabel("上一个窗口")
                        Text("\(manager.selectedIndex + 1) / \(manager.apps.count)").monospacedDigit()
                        Button { moveSelection(by: 1) } label: { Image(systemName: "chevron.right") }
                            .disabled(manager.selectedIndex >= manager.apps.count - 1)
                            .accessibilityLabel("下一个窗口")
                    }
                    Text("左右滑动切换 · 点按打开 · 长按更多 · 上滑关闭")
                        .font(.footnote)
                        .foregroundStyle(.white.opacity(0.7))
                    Button {
                        manager.closeAll()
                    } label: {
                        Label("全部清除", systemImage: "trash")
                            .font(.subheadline.weight(.semibold))
                            .padding(.horizontal, 22)
                            .padding(.vertical, 11)
                            .background(.ultraThinMaterial, in: Capsule())
                            .overlay(Capsule().stroke(.white.opacity(0.2), lineWidth: 1))
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel("关闭全部多任务窗口")
                }
                if let message = manager.message { Text(message).font(.footnote).accessibilityAddTraits(.updatesFrequently) }
            }
            .foregroundStyle(.white)
            .padding(.vertical, 24)
        }
        .sheet(item: $manager.settingsTarget) { target in
            HomeAppSettingsScreen(app: target.app)
        }
    }

    private func moveSelection(by distance: Int) {
        withAnimation(.spring(response: 0.35, dampingFraction: 0.85)) {
            manager.focus(index: manager.selectedIndex + distance)
        }
    }

    private func deck(in size: CGSize) -> some View {
        // The card follows the phone's aspect, so a full-screen guest picture
        // fills it without black bars above and below.
        let screen = UIScreen.main.bounds
        let phoneRatio = screen.height / max(screen.width, 1)
        let width = min(420, size.width * 0.72)
        let height = min(size.height * 0.84, width * phoneRatio)
        let stride = max(1, width * 0.48)
        let horizontal = dragAxis == .horizontal ? dragOffset.width : 0
        return ZStack {
            ForEach(Array(manager.apps.enumerated()), id: \.element.appUUID) { index, app in
                let distance = CGFloat(index - manager.selectedIndex)
                let depth = min(4, abs(distance))
                let vertical = app.appUUID == draggedUUID && dragAxis == .vertical ? min(0, dragOffset.height) : 0
                AppStackCard(app: app, size: CGSize(width: width, height: height),
                             preview: manager.previewSnapshot(for: app.appUUID),
                             onSelect: { manager.selectApp(uuid: app.appUUID) },
                             onClose: { manager.closeApp(uuid: app.appUUID) },
                             onAppInfo: { manager.showAppInfo(uuid: app.appUUID) },
                             onSplit: { manager.openInSplitScreen(uuid: app.appUUID) },
                             onPictureInPicture: { manager.togglePictureInPicture(uuid: app.appUUID) })
                    .scaleEffect(1 - depth * 0.055)
                    .offset(x: distance * stride + horizontal, y: depth * 14 + vertical)
                    .zIndex(Double(manager.apps.count) - Double(abs(distance)))
                    .accessibilityHidden(index != manager.selectedIndex)
            }
        }
        .frame(width: size.width, height: size.height)
        .contentShape(Rectangle())
        .clipped()
        .gesture(DragGesture(minimumDistance: 12)
            .onChanged { value in
                if dragAxis == nil {
                    dragAxis = abs(value.translation.width) > abs(value.translation.height) ? .horizontal : .vertical
                    draggedUUID = manager.apps.indices.contains(manager.selectedIndex) ? manager.apps[manager.selectedIndex].appUUID : nil
                }
                dragOffset = value.translation
            }
            .onEnded { value in
                withAnimation(.spring(response: 0.35, dampingFraction: 0.85)) {
                    if dragAxis == .horizontal, let uuid = draggedUUID,
                       let index = manager.apps.firstIndex(where: { $0.appUUID == uuid }) {
                        let travel = value.translation.width
                        if abs(travel) > 40 || abs(value.predictedEndTranslation.width) > stride * 0.5 {
                            manager.focus(index: index + (travel < 0 ? 1 : -1))
                        }
                    } else if dragAxis == .vertical,
                              value.translation.height < -100 || (value.translation.height < -30 && value.predictedEndTranslation.height < -180),
                              let uuid = draggedUUID {
                        manager.closeApp(uuid: uuid)
                    }
                    dragOffset = .zero
                    dragAxis = nil
                    draggedUUID = nil
                }
            })
        .animation(.spring(response: 0.35, dampingFraction: 0.85), value: manager.apps.map(\.appUUID))
        .accessibilityAdjustableAction { direction in
            switch direction {
            case .increment: moveSelection(by: 1)
            case .decrement: moveSelection(by: -1)
            @unknown default: break
            }
        }
    }
}

@available(iOS 16.0, *)
struct AppStackCard: View {
    let app: DockAppModel
    let size: CGSize
    let preview: UIView?
    var onSelect: () -> Void
    var onClose: () -> Void
    var onAppInfo: () -> Void
    var onSplit: () -> Void
    var onPictureInPicture: () -> Void
    @State private var icon: UIImage?

    var body: some View {
        ZStack(alignment: .topLeading) {
            if let preview {
                ScaledSnapshotView(snapshot: preview)
                    .clipShape(RoundedRectangle(cornerRadius: 26, style: .continuous))
            } else {
                RoundedRectangle(cornerRadius: 26, style: .continuous)
                    .fill(Color(white: 0.14))
                Text(app.appName).font(.title3.weight(.semibold))
                    .multilineTextAlignment(.center).lineLimit(2)
                    .padding(24)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
            HStack(spacing: 10) {
                Group {
                    if let icon {
                        Image(uiImage: icon).resizable().scaledToFit()
                    } else {
                        Image(systemName: "app.fill").resizable().scaledToFit()
                            .foregroundStyle(.white.opacity(0.65))
                    }
                }
                .frame(width: 40, height: 40)
                .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
                Text(app.appName).font(.headline).lineLimit(1)
                    .padding(.horizontal, 10).padding(.vertical, 6)
                    .background(.black.opacity(0.55), in: Capsule())
            }
            .padding(18)
        }
        .frame(width: size.width, height: size.height)
        .background(RoundedRectangle(cornerRadius: 26, style: .continuous).fill(Color(white: 0.14)))
        .overlay(RoundedRectangle(cornerRadius: 26, style: .continuous).stroke(.white.opacity(0.25), lineWidth: 1))
        .contentShape(RoundedRectangle(cornerRadius: 26, style: .continuous))
        .onTapGesture(perform: onSelect)
        .contextMenu {
            Button(action: onAppInfo) {
                Label("应用信息", systemImage: "info.circle")
            }
            Button(action: onSplit) {
                Label("分屏", systemImage: "rectangle.split.1x2")
            }
            Button(action: onPictureInPicture) {
                Label("画中画模式", systemImage: "pip")
            }
            Divider()
            Button(role: .destructive, action: onClose) {
                Label("清除", systemImage: "xmark")
            }
        }
        .overlay(alignment: .topTrailing) {
            Button(action: onClose) { Image(systemName: "xmark.circle.fill").font(.title2).padding(16) }
                .accessibilityLabel("关闭 \(app.appName)")
        }
        .shadow(color: .black.opacity(0.4), radius: 12, y: 6)
        .accessibilityAction(named: Text("打开窗口"), onSelect)
        .accessibilityAction(named: Text("关闭窗口"), onClose)
        .onAppear(perform: loadIcon)
    }

    private func loadIcon() {
        // Shared SwiftUI models are main-thread state; only image decoding is
        // moved off the main queue.
        let info = app.appInfo ?? AppInfoProvider.shared.findAppInfo(appName: app.appName, dataUUID: app.appUUID)
        DispatchQueue.global(qos: .userInitiated).async {
            let image = info?.iconIsDarkIcon(false)
            DispatchQueue.main.async { icon = image }
        }
    }
}

/// Puts the guest window's snapshot in a card at its aspect ratio, scaled to
/// fit the card. The snapshot is a picture only; touches go to the card.
@available(iOS 16.0, *)
private struct ScaledSnapshotView: UIViewRepresentable {
    let snapshot: UIView

    func makeUIView(context: Context) -> SnapshotContainer {
        SnapshotContainer(snapshot: snapshot)
    }

    func updateUIView(_ container: SnapshotContainer, context: Context) {
        container.updateSnapshot(snapshot)
    }

    final class SnapshotContainer: UIView {
        private var snapshot: UIView

        init(snapshot: UIView) {
            self.snapshot = snapshot
            super.init(frame: .zero)
            backgroundColor = .black
            clipsToBounds = true
            isUserInteractionEnabled = false
            addSubview(snapshot)
        }

        func updateSnapshot(_ snapshot: UIView) {
            if self.snapshot !== snapshot {
                self.snapshot.removeFromSuperview()
                self.snapshot = snapshot
                addSubview(snapshot)
            }
            setNeedsLayout()
        }

        @available(*, unavailable)
        required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

        override func layoutSubviews() {
            super.layoutSubviews()
            let source = snapshot.bounds.size == .zero ? snapshot.frame.size : snapshot.bounds.size
            guard bounds.width > 0, bounds.height > 0, source.width > 0, source.height > 0 else { return }
            snapshot.transform = .identity
            snapshot.bounds = CGRect(origin: .zero, size: source)
            // Aspect fill: the phone picture covers the card, so no black
            // letterbox shows above and below the guest screenshot.
            let scale = max(bounds.width / source.width, bounds.height / source.height)
            snapshot.transform = CGAffineTransform(scaleX: scale, y: scale)
            snapshot.center = CGPoint(x: bounds.midX, y: bounds.midY)
        }
    }
}
