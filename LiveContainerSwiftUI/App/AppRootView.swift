//
//  AppRootView.swift
//  LiveContainerSwiftUI
//

import SwiftUI
import CoreFoundation
import Combine

/// The main window's root: the Home Screen, with onboarding over it while it
/// shows. Onboarding sits in the same view tree rather than being presented,
/// so the questions and errors installs raise from the Home Screen still show
/// over it. When onboarding finishes it fades away while the Home Screen
/// fades in and its icons settle from a little closer, as after unlocking.
struct AppRootView: View {
    @Environment(OnboardingModel.self) private var onboarding
    @Environment(HomeScreenModel.self) private var home
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @EnvironmentObject private var sceneDelegate: SceneDelegate

    var body: some View {
        ZStack {
            HomeScreenView()
                .scaleEffect(onboarding.isPresented && !reduceMotion ? OnboardingDesign.homeArrivalScale : 1)
                .opacity(onboarding.isPresented ? 0 : 1)
                // Hidden under onboarding for touches and VoiceOver alike.
                .allowsHitTesting(!onboarding.isPresented)
                .accessibilityHidden(onboarding.isPresented)

            if onboarding.isPresented {
                OnboardingView(startsAtConnect: onboarding.startsAtConnect)
                    .transition(.opacity)
                    .zIndex(1)
            }

        }
        .onChange(of: onboarding.isPresented, onboardingChanged)
        .onAppear { TDHostHomeOverlayController.shared.attach() }
        .onReceive(NotificationCenter.default.publisher(for: .lcHostHomePressed)) { _ in
            if #available(iOS 16.0, *) {
                MultitaskStackManager.shared.dismiss()
                MultitaskDockManager.shared.minimizeAllWindows()
            }
            home.goHome()
        }
        .onReceive(NotificationCenter.default.publisher(for: .lcCloseHostScreens)) { _ in
            home.showHomeScreen()
        }
        .onReceive(NotificationCenter.default.publisher(for: .lcStackShowAppSettings)) { note in
            guard let uuid = note.userInfo?["uuid"] as? String,
                  let app = home.apps.values.first(where: {
                      ($0.appInfo.dataUUID as String?) == uuid
                  }) else { return }
            home.showSettings(for: app)
        }
        .onReceive(NotificationCenter.default.publisher(for: .lcStackSplitApp)) { note in
            guard let uuid = note.userInfo?["uuid"] as? String,
                  let app = home.apps.values.first(where: {
                      ($0.appInfo.dataUUID as String?) == uuid
                  }) else { return }
            home.showHomeScreen()
            if home.canOpenInSplitScreen(app) {
                home.openInSplitScreen(app)
            }
        }
        // Where the Home button goes, on the Home Screen and every screen
        // over it: beside an iPad's Home button, as the iPad is turned.
        .environment(\.homeButtonEdge, HomeButtonEdge(sceneDelegate.interfaceOrientation))
        .appIconAppearance()
        // Zeus's pink, for switches too, as Zeus tints its own, in place of
        // iOS's green.
        .tint(AppAccent.color)
    }

    /// Closes what's open over the Home Screen, like Settings, when
    /// onboarding opens from it, since onboarding shows under presented
    /// screens.
    private func onboardingChanged() {
        if onboarding.isPresented {
            home.showHomeScreen()
        }
    }
}

/// The experimental “always show” Home button on zContainer's own screen.
/// Guest apps get the UIKit overlay from TweakLoader; this is the host half,
/// so the setting also holds on the Home Screen and Settings.
private struct TDGlobalHomeOverlay: View {
    let action: () -> Void

    // Refreshed by the controller on local and cross-process setting changes.
    let mode: String
    @AppStorage("TDAssistiveTouchIdleDim", store: LCUtils.appGroupUserDefault)
    private var dimEnabled = true
    @AppStorage("TDAssistiveTouchIdleAlpha", store: LCUtils.appGroupUserDefault)
    private var dimAlpha = 0.4
    @AppStorage("TDDesktopHomeOffsetX", store: LCUtils.appGroupUserDefault)
    private var offsetX = 0.0
    @AppStorage("TDDesktopHomeOffsetY", store: LCUtils.appGroupUserDefault)
    private var offsetY = 0.0

    @State private var dimmed = false
    @State private var dimGeneration = 0
    @State private var dragBase: CGSize?

    var body: some View {
        Group {
            if mode == "always" {
                GeometryReader { proxy in
                    let margin = HomeDesign.homeButtonSize / 2 + 8
                    let base = CGPoint(x: proxy.size.width - margin,
                                       y: proxy.size.height * 0.62)
                    // Keep the old right-origin offset protocol for saved drags.
                    // Only an unset placement defaults to the left, away from chevrons.
                    let hasSavedPlacement = LCUtils.appGroupUserDefault.object(forKey: "TDDesktopHomeOffsetX") != nil
                        || LCUtils.appGroupUserDefault.object(forKey: "TDDesktopHomeOffsetY") != nil
                    let effectiveOffset = hasSavedPlacement
                        ? CGSize(width: offsetX, height: offsetY)
                        : CGSize(width: margin - base.x, height: 0)
                    let center = CGPoint(
                        x: min(max(base.x + effectiveOffset.width, margin), proxy.size.width - margin),
                        y: min(max(base.y + effectiveOffset.height, margin), proxy.size.height - margin)
                    )

                    HomeButton(action: {}, showsGlass: true)
                        .highPriorityGesture(
                            TapGesture(count: 2)
                                .exclusively(before: TapGesture(count: 1))
                                .onEnded { tap in
                                    switch tap {
                                    case .first(_):
                                        if #available(iOS 16.0, *) {
                                            MultitaskStackManager.shared.present()
                                        }
                                    case .second(_):
                                        action()
                                        scheduleDim()
                                    }
                                }
                        )
                        .accessibilityAction {
                            action()
                            scheduleDim()
                        }
                        .background(TDOverlayHitRegion())
                        .position(center)
                    .opacity(dimmed && dimEnabled ? max(0.15, min(1.0, dimAlpha)) : 1)
                    .simultaneousGesture(
                        DragGesture(minimumDistance: 4)
                            .onChanged { value in
                                if dragBase == nil {
                                    dragBase = effectiveOffset
                                    dimmed = false
                                }
                                offsetX = (dragBase?.width ?? 0) + value.translation.width
                                offsetY = (dragBase?.height ?? 0) + value.translation.height
                            }
                            .onEnded { _ in
                                dragBase = nil
                                scheduleDim()
                            }
                    )
                }
                // Keep the button inside the scene's safe area. It cannot cover
                // the status bar, home indicator, or bottom controls while dragged.
                .onAppear(perform: scheduleDim)
                .onChange(of: mode) { _, _ in scheduleDim() }
                .onChange(of: dimEnabled) { _, _ in scheduleDim() }
                .onChange(of: dimAlpha) { _, _ in scheduleDim() }
            }
        }
    }

    private func scheduleDim() {
        dimGeneration += 1
        let generation = dimGeneration
        dimmed = false
        guard dimEnabled else { return }
        DispatchQueue.main.asyncAfter(deadline: .now() + 3) {
            guard generation == dimGeneration else { return }
            dimmed = true
        }
    }
}

extension Notification.Name {
    /// The host Home button's single tap, handled by AppRootView.
    static let lcHostHomePressed = Notification.Name("LCHostHomePressed")
}

/// A window that lets touches through except on the Home button itself, so it
/// can sit above alerts ("App 已终止") without blocking them.
private final class TDHostHomeOverlayWindow: UIWindow {
    weak var buttonRegion: UIView?

    override var canBecomeKey: Bool { false }

    // Match the UIKit guest overlay: this transparent window must not become
    // the source of the application's status-bar geometry or style.
    @objc(_canAffectStatusBarAppearance)
    func td_canAffectStatusBarAppearance() -> Bool { false }

    override func hitTest(_ point: CGPoint, with event: UIEvent?) -> UIView? {
        // Convert at hit-test time: dragging can move SwiftUI ancestors without
        // laying out the marker itself. A cached rectangle would stay behind.
        guard let region = buttonRegion, region.window === self,
              region.bounds.contains(region.convert(point, from: self)) else { return nil }
        return super.hitTest(point, with: event)
    }
}


private struct TDOverlayHitRegion: UIViewRepresentable {
    func makeUIView(context: Context) -> UIView {
        let view = RegionView()
        view.isUserInteractionEnabled = false
        view.backgroundColor = .clear
        return view
    }

    func updateUIView(_ view: UIView, context: Context) {}

    static func dismantleUIView(_ view: UIView, coordinator: ()) {
        (view as? RegionView)?.clearInteractiveRegion()
    }

    private final class RegionView: UIView {
        weak var overlayWindow: TDHostHomeOverlayWindow?

        override func didMoveToWindow() {
            super.didMoveToWindow()
            clearInteractiveRegion()
            overlayWindow = window as? TDHostHomeOverlayWindow
            overlayWindow?.buttonRegion = self
        }

        func clearInteractiveRegion() {
            if overlayWindow?.buttonRegion === self {
                overlayWindow?.buttonRegion = nil
            }
            overlayWindow = nil
        }
    }
}

/// The host half of the always-on Home button. It lives in its own window above
/// alerts, which a view inside the root hierarchy cannot cover, and it starts
/// without loading TweakLoader or global user tweaks.
@MainActor
final class TDHostHomeOverlayController {
    static let shared = TDHostHomeOverlayController()

    // 全局只有一个按钮：单窗口，随前台场景移动，不在每个 scene 各建一个。
    private var window: TDHostHomeOverlayWindow?
    private var hosting: UIHostingController<TDGlobalHomeOverlay>?
    private var observers: [NSObjectProtocol] = []

    private init() {
        let center = NotificationCenter.default
        for name in [UIScene.didActivateNotification, UIScene.didDisconnectNotification,
                     UIScene.didEnterBackgroundNotification,
                     UIWindow.didBecomeVisibleNotification, UserDefaults.didChangeNotification] {
            observers.append(center.addObserver(forName: name, object: nil, queue: .main) { [weak self] note in
                // Showing our window emits the same notification. Do not recurse.
                if note.object is TDHostHomeOverlayWindow { return }
                MainActor.assumeIsolated { self?.attach() }
            })
        }
        CFNotificationCenterAddObserver(
            CFNotificationCenterGetDarwinNotifyCenter(), nil,
            { _, _, _, _, _ in
                Task { @MainActor in
                    LCUtils.appGroupUserDefault.synchronize()
                    TDHostHomeOverlayController.shared.attach()
                }
            },
            "com.kdt.livecontainer.assistiveTouchSettingsChanged" as CFString,
            nil, .deliverImmediately
        )
    }

    private func rootView(mode: String) -> TDGlobalHomeOverlay {
        TDGlobalHomeOverlay(action: {
            CFNotificationCenterPostNotification(CFNotificationCenterGetDarwinNotifyCenter(),
                                                 CFNotificationName("com.kdt.livecontainer.minimizeAll" as CFString),
                                                 nil, nil, true)
            NotificationCenter.default.post(name: .lcHostHomePressed, object: nil)
            // A native app window has its own scene; bring the accepted Home
            // scene forward as well, rather than only changing a hidden model.
            if let scene = MainWindow.scene {
                UIApplication.shared.requestSceneSessionActivation(scene.session, userActivity: nil, options: nil) { error in
                    NSLog("[TDHome] Home scene activation failed: %@", error.localizedDescription)
                }
            }
        }, mode: mode)
    }

    private func overlayLevel(in scene: UIWindowScene) -> UIWindow.Level {
        let highest = scene.windows.filter {
            !($0 is TDHostHomeOverlayWindow) && !$0.isHidden && $0.alpha > 0 && $0.rootViewController != nil
        }.map { $0.windowLevel.rawValue }.max() ?? UIWindow.Level.normal.rawValue
        return UIWindow.Level(rawValue: max(UIWindow.Level.alert.rawValue + 2, highest + 1))
    }

    func attach() {
        let mode = LCUtils.appGroupUserDefault.string(forKey: "TDAssistiveTouchMode") ?? "default"
        let scenes = UIApplication.shared.connectedScenes
            .compactMap { $0 as? UIWindowScene }
            .filter { $0.session.role == .windowApplication }
        // 只跟一个前台场景走；找不到就藏，绝不为了多场景再开一个窗。
        guard mode == "always",
              let scene = scenes.first(where: { $0.activationState == .foregroundActive })
                        ?? scenes.first(where: { $0.activationState == .foregroundInactive }),
              !scene.coordinateSpace.bounds.isEmpty,
              scene.windows.contains(where: {
                  !($0 is TDHostHomeOverlayWindow) && !$0.isHidden &&
                  $0.windowLevel == .normal && $0.rootViewController != nil
              }) else {
            window?.isHidden = true
            return
        }

        if let overlay = window {
            if overlay.windowScene !== scene { overlay.windowScene = scene }
            if let host = overlay.rootViewController as? UIHostingController<TDGlobalHomeOverlay>,
               host.rootView.mode != mode {
                host.rootView = rootView(mode: mode)
            }
            overlay.frame = scene.coordinateSpace.bounds
            overlay.windowLevel = overlayLevel(in: scene)
            overlay.isHidden = false
            return
        }

        let host = UIHostingController(rootView: rootView(mode: mode))
        host.view.backgroundColor = .clear
        let overlay = TDHostHomeOverlayWindow(windowScene: scene)
        overlay.frame = scene.coordinateSpace.bounds
        overlay.windowLevel = overlayLevel(in: scene)
        overlay.backgroundColor = .clear
        overlay.rootViewController = host
        // Retain before showing: window-visible callbacks can be synchronous.
        window = overlay
        hosting = host
        overlay.isHidden = false
    }
}
