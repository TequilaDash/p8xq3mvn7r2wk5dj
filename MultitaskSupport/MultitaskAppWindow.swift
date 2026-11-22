//
//  MultitaskAppWindow.swift
//  LiveContainer
//
//  Created by s s on 2025/5/17.
//
import SwiftUI

@available(iOS 16.1, *)
struct MultitaskAppInfo {
    var displayName: String
    var dataUUID: String
    var bundleId: String
    // new for every launch, so a window that goes away late changes only its own entry, never the one a newer launch of the same container made
    let launchID = UUID()
    // the window's session once iOS disconnected it; iOS can bring a disconnected window back, so the entry stays until that session is gone
    var disconnectedSessionID: String? = nil
    fileprivate var pidCallback: ((NSNumber, Error?) -> Void)?

    init(displayName: String, dataUUID: String, bundleId: String, pidCallback: ((NSNumber, Error?) -> Void)?) {
        self.displayName = displayName
        self.dataUUID = dataUUID
        self.bundleId = bundleId
        self.pidCallback = pidCallback
    }
}

@available(iOS 16.1, *)
@objc class MultitaskWindowManager: NSObject {
    @Environment(\.openWindow) static var openWindow
    static var appDict: [String: MultitaskAppInfo] = [:]
    
    @objc class func openAppWindow(displayName: String, dataUUID: String, bundleId: String, pidCallback: ((NSNumber, Error?) -> Void)?) {
        guard appDict[dataUUID] == nil else {
            pidCallback?(0, NSError(domain: "LCMultitaskLaunch", code:4, userInfo: [NSLocalizedDescriptionKey: "该容器已有原生窗口，未重复启动"]))
            return
        }
        let info = MultitaskAppInfo(displayName: displayName, dataUUID: dataUUID, bundleId: bundleId, pidCallback: pidCallback)
        appDict[dataUUID] = info
        // A restart gets a new SwiftUI scene value, so openWindow cannot
        // reconnect the old, already-terminated controller for this container.
        openWindow(id: "appView", value: info.launchID.uuidString)
    }
    
    @objc class func openExistingAppWindow(dataUUID: String) -> Bool {
        guard let info = appDict[dataUUID] else { return false }
        // the window was closed, so the app launches again the full way: signing, JIT and the launch date
        if let sessionID = info.disconnectedSessionID,
           !UIApplication.shared.openSessions.contains(where: { $0.persistentIdentifier == sessionID }) {
            removeAppInfo(info)
            return false
        }
        openWindow(id: "appView", value: info.launchID.uuidString)
        return true
    }

    // records the session of a disconnected window on the entry of that window's launch only
    class func recordDisconnectedSession(_ sessionID: String, for info: MultitaskAppInfo) {
        guard appDict[info.dataUUID]?.launchID == info.launchID else { return }
        appDict[info.dataUUID]?.disconnectedSessionID = sessionID
        if appDict[info.dataUUID]?.pidCallback != nil {
            completeLaunch(for: info, pid: 0, error: NSError(domain: "LCMultitaskLaunch", code:5, userInfo: [NSLocalizedDescriptionKey: "多任务窗口在启动完成前已断开"]))
        }
    }

    // removes the entry of a closing window's launch only, so a newer launch of the same container keeps its own
    class func removeAppInfo(_ info: MultitaskAppInfo) {
        guard appDict[info.dataUUID]?.launchID == info.launchID else { return }
        let callback = appDict[info.dataUUID]?.pidCallback
        appDict[info.dataUUID] = nil
        if let callback {
            callback(0, NSError(domain: "LCMultitaskLaunch", code:6, userInfo: [NSLocalizedDescriptionKey: "多任务窗口在启动完成前已关闭"]))
        }
    }

    /// A late result from an old window must never consume a newer launch's
    /// continuation (or attach JIT to a different guest's PID).
    class func completeLaunch(for info: MultitaskAppInfo, pid: NSNumber, error: Error?) {
        guard appDict[info.dataUUID]?.launchID == info.launchID else { return }
        let callback = appDict[info.dataUUID]?.pidCallback
        appDict[info.dataUUID]?.pidCallback = nil
        callback?(pid, error)
    }
}

@available(iOS 16.1, *)
struct AppSceneViewSwiftUI: UIViewControllerRepresentable {
    @Binding var show: Bool
    @Binding var didRequestManualClose: Bool
    let bundleId: String
    let dataUUID: String
    let initSize: CGSize
    let onAppInitialize: (Int32, Error?) -> Void
    
    class Coordinator: NSObject, AppSceneViewControllerDelegate {
        let onExit: (Bool) -> Void
        let onAppInitialize: (Int32, Error?) -> Void
        init(onAppInitialize: @escaping (Int32, Error?) -> Void, onExit: @escaping (Bool) -> Void) {
            self.onAppInitialize = onAppInitialize
            self.onExit = onExit
        }
        
        func appSceneVCAppDidExit(_ vc: AppSceneViewController!) {
            onExit(vc?.isUserTerminating ?? false)
        }
        
        /// One line per activation in the exportable log, so fullscreen and
        /// multitask geometry can be compared instead of inferred.
        /// Same resolution order as TDConsoleLog: the env override, then the
        /// guest's Documents. A missing app group must not silently disable
        /// diagnostics: a sideloaded group can be unavailable while the app
        /// still runs.
        private static func consoleLogDirectory() -> URL? {
            var paths: [String] = []
            if let override = ProcessInfo.processInfo.environment["TD_CONSOLE_LOG_DIR"], override.hasPrefix("/") {
                paths.append(override)
            }
            if let home = ProcessInfo.processInfo.environment["LC_HOME_PATH"], home.hasPrefix("/") {
                paths.append(home + "/Documents/ConsoleLog")
            }
            if let group = LCSharedUtils.appGroupID(),
               let container = FileManager.default.containerURL(forSecurityApplicationGroupIdentifier: group) {
                paths.append(container.appendingPathComponent("LiveContainer/ConsoleLog").path)
            }
            for path in paths {
                let url = URL(fileURLWithPath: path, isDirectory: true)
                if (try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)) != nil {
                    return url
                }
            }
            return nil
        }

        private static func appendGeometryLine(_ line: String) {
            guard let dir = consoleLogDirectory() else { return }
            let path = dir.appendingPathComponent("geometry-\(getpid()).log")
            if let handle = try? FileHandle(forWritingTo: path) {
                handle.seekToEndOfFile()
                handle.write(line.data(using: String.Encoding.utf8) ?? Data())
                try? handle.close()
            } else {
                try? line.write(to: path, atomically: true, encoding: .utf8)
            }
        }

        private static func logGeometry(vc: AppSceneViewController, window: UIWindow?) {
            appendGeometryLine("[geometry] mode=native-host pid=\(getpid()) view=\(vc.view.bounds) window=\(window?.bounds.debugDescription ?? "(none)") safe=\(String(describing: window?.safeAreaInsets)) scene=\(String(describing: window?.windowScene?.interfaceOrientation.rawValue))\n")
            logBottomOverlays(window: window)
        }

        /// Everything that is drawn over the bottom edge of a screen, so the
        /// small block that covers the content can be named from the log
        /// instead of guessed at: the class, its frame in the window that owns
        /// it, and whether it is visible. The guest's resize grabber and the
        /// split divider are subviews of the guest window; the floating Home
        /// button is a window of its own.
        private static func logBottomOverlays(window: UIWindow?) {
            let band: CGFloat = 140
            var lines: [String] = []
            func describe(_ view: UIView, in container: UIView, depth: Int) {
                let frame = view.convert(view.bounds, to: container)
                if frame.maxY >= container.bounds.maxY - band {
                    lines.append("\(String(repeating: "  ", count: depth))\(type(of: view)) frame=\(NSStringFromCGRect(frame)) alpha=\(view.alpha) hidden=\(view.isHidden)")
                }
                for sub in view.subviews {
                    describe(sub, in: container, depth: depth + 1)
                }
            }
            func scan(_ candidate: UIWindow?) {
                guard let candidate else { return }
                for sub in candidate.subviews {
                    describe(sub, in: candidate, depth: 0)
                }
            }
            scan(window)
            for scene in UIApplication.shared.connectedScenes {
                guard let windowScene = scene as? UIWindowScene else { continue }
                for hostWindow in windowScene.windows {
                    scan(hostWindow)
                }
            }
            guard !lines.isEmpty else { return }
            let text = "[bottom-overlays] pid=\(getpid())\n" + lines.joined(separator: "\n") + "\n"
            appendGeometryLine(text)
            NSLog("%@", text)
        }

        func appSceneVC(_ vc: AppSceneViewController!, didInitializeWithError error: (any Error)!) {
            onAppInitialize(vc.pid, error)
            // Keep the error in SwiftUI state before leaving the embedded scene.
            if error != nil {
                NSLog("[LC][Multitask] app init failed: %@", error.localizedDescription)
                DispatchQueue.main.async {
                    self.onExit(vc?.isUserTerminating ?? false)
                }
            }
        }
        
        func appSceneVCWillActivateScene(_ vc: AppSceneViewController!) {
            let window = vc.view.window
            (window?.windowScene?.statusBarManager as? LCStatusBarManager)?.nativeWindowViewController = vc
            Self.logGeometry(vc: vc, window: window)
            vc.updateSettings { settings in
                guard let settings else { return }
                settings.deviceOrientation = UIDevice.current.orientation
                // Use the same scene orientation as the later resize path.
                if let orientation = window?.windowScene?.interfaceOrientation, orientation != .unknown {
                    settings.setInterfaceOrientation(orientation)
                }
                let size = vc.view.bounds.size
                let frame = settings.interfaceOrientation().isLandscape
                    ? CGRect(x: 0, y: 0, width: size.height, height: size.width)
                    : CGRect(origin: .zero, size: size)
                settings.setFrame(frame)
            }
            // fix live resize
            vc.contentView.autoresizingMask = [.flexibleWidth, .flexibleHeight]
        }
        
        func appSceneVC(_ vc: AppSceneViewController!, didUpdateFrom settings: UIMutableApplicationSceneSettings!, transitionContext context: Any!, lifecycleActionType actionType: UInt32) {
            settings.interruptionPolicy = 0
            // This path forwards the host's lifecycle transition, but not its
            // whole-window geometry: the embedded viewport can be smaller.
            guard let window = vc.view.window, !vc.view.bounds.isEmpty else { return }
            if let orientation = window.windowScene?.interfaceOrientation, orientation != .unknown {
                settings.setInterfaceOrientation(orientation)
            }
            let scale = vc.scaleRatio
            let size = CGSize(width: vc.view.bounds.width / scale, height: vc.view.bounds.height / scale)
            let frame = settings.interfaceOrientation().isLandscape
                ? CGRect(x: 0, y: 0, width: size.height, height: size.width)
                : CGRect(origin: .zero, size: size)
            settings.setFrame(frame)
            let insets = LCGuestSceneSafeAreaInsets(vc.view, vc.view, vc.additionalSafeAreaInsets)
            LCApplyGuestSceneSafeAreaInsets(settings, UIEdgeInsets(top: insets.top / scale, left: insets.left / scale,
                                                                 bottom: insets.bottom / scale, right: insets.right / scale))
            LCApplyGuestSceneStatusBarFrame(settings, vc.view, scale)
            vc.presenter.scene.updateSettings(settings, withTransitionContext: context, completion: nil)
            // Not sure what actionType 2 is, but it's only set when this scene enters foreground, so we can pass URL scheme here
            if actionType == 2, let launchUrl = UserDefaults.standard.string(forKey: "launchAppUrlScheme") {
                UserDefaults.standard.removeObject(forKey: "launchAppUrlScheme")
                vc.openURLScheme(launchUrl)
            }
        }
    }
    
    func makeCoordinator() -> Coordinator {
        Coordinator(onAppInitialize: onAppInitialize, onExit: { isManual in
            if isManual { didRequestManualClose = true }
            show = false
        })
    }
    
    func makeUIViewController(context: Context) -> UIViewController {
        return AppSceneViewController(bundleId: bundleId, dataUUID: dataUUID, delegate: context.coordinator)
    }
    
    func updateUIViewController(_ vc: UIViewController, context _: Context) {
        if let vc = vc as? AppSceneViewController {
            if !show {
                vc.terminate()
            }
        }
    }
}

@available(iOS 16.1, *)
struct MultitaskAppWindow: View {
    @State var show = true
    @State var pid = 0
    @State var appInfo: MultitaskAppInfo? = nil
    @State var errorMessage: String? = nil
    @State private var hasScheduledAutoClose = false
    @State private var didRequestManualClose = false
    @EnvironmentObject var sceneDelegate: SceneDelegate
    @Environment(\.openWindow) var openWindow
    @AppStorage("LCMultitaskMode", store: LCUtils.appGroupUserDefault) var multitaskMode: MultitaskMode = .virtualWindow
    @AppStorage("LCSkipTerminatedScreen", store: LCUtils.appGroupUserDefault) var skipTerminatedScreen = false
    let pub = NotificationCenter.default.publisher(for: UIScene.didDisconnectNotification)
    init(id: String) {
        guard let launchID = UUID(uuidString: id),
              var appInfo = MultitaskWindowManager.appDict.values.first(where: { $0.launchID == launchID }) else {
            return
        }
        // Only the launch registry owns the callback; State copies keep the
        // identity but must not retain a consumed continuation.
        appInfo.pidCallback = nil
        _appInfo = State(initialValue: appInfo)
    }
    
    var body: some View {
        let isVirtualWindowMode = multitaskMode == .virtualWindow
        Group {
            if show, let appInfo {
                GeometryReader { geometry in
                    AppSceneViewSwiftUI(show: $show, didRequestManualClose: $didRequestManualClose, bundleId: appInfo.bundleId, dataUUID: appInfo.dataUUID, initSize: geometry.size,
                                        onAppInitialize: { pid, error in
                        DispatchQueue.main.async {
                            guard MultitaskWindowManager.appDict[appInfo.dataUUID]?.launchID == appInfo.launchID else { return }
                            if error == nil {
                                self.pid = Int(pid)
                            } else {
                                self.errorMessage = error?.localizedDescription
                            }
                            MultitaskWindowManager.completeLaunch(for: appInfo, pid: NSNumber(value: pid), error: error)
                        }
                    })
                    .background(.black)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                }
                .ignoresSafeArea(.all, edges: .all)
                .navigationTitle(Text("\(appInfo.displayName) - \(String(pid))"))
                
            } else if skipTerminatedScreen && errorMessage == nil && isVirtualWindowMode, appInfo != nil {
                Color.clear
                    .ignoresSafeArea(.all, edges: .all)
                    .onAppear {
                        guard !didRequestManualClose else { return }
                        if let appInfo {
                            MultitaskRelaunchManager.scheduleRelaunchIfNeeded(bundleId: appInfo.bundleId, dataUUID: appInfo.dataUUID, isManualTermination: false)
                        }
                        if !hasScheduledAutoClose {
                            hasScheduledAutoClose = true
                            DispatchQueue.main.async {
                                requestSceneDestruction(isManual: false)
                            }
                        }
                    }
            } else {
                VStack {
                    Text("lc.multitaskAppWindow.appTerminated".loc)
                        .font(.largeTitle)
                    if let errorMessage {
                        Text(errorMessage)
                            .font(.system(.body, design: .monospaced))
                        Button("lc.common.copy".loc) {
                            UIPasteboard.general.string = errorMessage
                            requestSceneDestruction(isManual: true)
                        }
                        .buttonStyle(.bordered)
                    }
                    Button("lc.common.close".loc) {
                        requestSceneDestruction(isManual: true)
                    }
                    .buttonStyle(.bordered)
                }.onAppear {
                    // appInfo == nil indicates this is the first scene opened in this launch. We don't want this so we open lc's main scene and close this view
                    // however lc's main view may already be starting in another scene so we wait a bit before opening the main view
                    // also we have to keep the view open for a little bit otherwise lc will be killed by iOS
                    if appInfo == nil {
                        if DataManager.shared.model.mainWindowOpened {
                            requestSceneDestruction()
                        } else {
                            DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) {
                                if !DataManager.shared.model.mainWindowOpened {
                                    openWindow(id: "Main")
                                }
                                DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) {
                                    requestSceneDestruction()
                                }
                            }
                        }
                    }
                }
            }
        }
        .onReceive(pub) { out in
            if let scene1 = sceneDelegate.window?.windowScene, let scene2 = out.object as? UIWindowScene, scene1 == scene2 {
                // recorded on every screen, so a later launch knows this window is gone once its session is
                if let appInfo {
                    MultitaskWindowManager.recordDisconnectedSession(scene2.session.persistentIdentifier, for: appInfo)
                }
                show = false
            }
        }
    }
    
    private func requestSceneDestruction(isManual: Bool = false) {
        if isManual {
            didRequestManualClose = true
        }
        guard let session = sceneDelegate.window?.windowScene?.session else { return }
        // this window is going away, so the next launch takes the full way
        if let appInfo { MultitaskWindowManager.removeAppInfo(appInfo) }
        UIApplication.shared.requestSceneSessionDestruction(session, options: nil) { error in
            print(error)
        }
    }
}

@objcMembers
class MultitaskRelaunchManager: NSObject {
    private static var pendingKeys: Set<String> = []
    private static let pendingLock = NSLock()
    
    static func scheduleRelaunchIfNeeded(bundleId: String, dataUUID: String, isManualTermination: Bool) {
        let defaults = LCUtils.appGroupUserDefault
        let multitaskMode = MultitaskMode(rawValue: defaults.integer(forKey: "LCMultitaskMode")) ?? .virtualWindow
        guard defaults.bool(forKey: "LCSkipTerminatedScreen"),
              defaults.bool(forKey: "LCRestartTerminatedApp"),
              multitaskMode == .virtualWindow,
              !isManualTermination else { return }
        
        let key = "\(bundleId)#\(dataUUID)"
        guard markPendingIfNeeded(key: key) else { return }
        
        Task {
            defer { clearPending(key: key) }
            try? await Task.sleep(nanoseconds: 500_000_000)
            await relaunchApp(bundleId: bundleId, dataUUID: dataUUID)
        }
    }
    
    private static func markPendingIfNeeded(key: String) -> Bool {
        pendingLock.lock()
        defer { pendingLock.unlock() }
        if pendingKeys.contains(key) {
            return false
        }
        pendingKeys.insert(key)
        return true
    }
    
    private static func clearPending(key: String) {
        pendingLock.lock()
        pendingKeys.remove(key)
        pendingLock.unlock()
    }
    
    private static func relaunchApp(bundleId: String, dataUUID: String) async {
        guard let appModel = await MainActor.run(body: { lookupAppModel(bundleId: bundleId) }),
              appModel.appInfo.lastLaunched.distance(to: .now) > 2
        else {
            return
        }
        
        do {
            try await appModel.runApp(multitask: true, containerFolderName: dataUUID)
        } catch {
            print("Failed to restart \(bundleId): \(error)")
        }
    }
    
    @MainActor private static func lookupAppModel(bundleId: String) -> LCAppModel? {
        let sharedModel = DataManager.shared.model
        if let app = sharedModel.apps.first(where: { $0.appInfo.relativeBundlePath == bundleId }) {
            return app
        }
        return sharedModel.hiddenApps.first(where: { $0.appInfo.relativeBundlePath == bundleId })
    }
}
