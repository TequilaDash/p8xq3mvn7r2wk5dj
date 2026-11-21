//
//  AppRootView.swift
//  LiveContainerSwiftUI
//

import SwiftUI
import CoreFoundation

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

    @AppStorage("TDAssistiveTouchMode", store: LCUtils.appGroupUserDefault)
    private var mode = "default"
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
    @State private var pendingPress: DispatchWorkItem?

    var body: some View {
        Group {
            if mode == "always" {
                GeometryReader { proxy in
                    let margin = HomeDesign.homeButtonSize / 2 + 8
                    let base = CGPoint(x: proxy.size.width - margin,
                                       y: proxy.size.height * 0.62)
                    let center = CGPoint(
                        x: min(max(base.x + offsetX, margin), proxy.size.width - margin),
                        y: min(max(base.y + offsetY, margin), proxy.size.height - margin)
                    )

                    HomeButton {
                        // Wait for a possible second tap: one tap goes home,
                        // a double tap opens the stack and cancels the single.
                        pendingPress?.cancel()
                        let work = DispatchWorkItem {
                            action()
                            scheduleDim()
                        }
                        pendingPress = work
                        DispatchQueue.main.asyncAfter(deadline: .now() + 0.28, execute: work)
                    }
                    .simultaneousGesture(
                        TapGesture(count: 2).onEnded {
                            pendingPress?.cancel()
                            pendingPress = nil
                            if #available(iOS 16.0, *) {
                                MultitaskStackManager.shared.present()
                            }
                        }
                    )
                    .background(TDOverlayHitRegion())
                    .position(center)
                    .opacity(dimmed && dimEnabled ? max(0.15, min(1.0, dimAlpha)) : 1)
                    .simultaneousGesture(
                        DragGesture(minimumDistance: 4)
                            .onChanged { value in
                                if dragBase == nil {
                                    dragBase = CGSize(width: offsetX, height: offsetY)
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
private final class TDHostHomeOverlayController {
    static let shared = TDHostHomeOverlayController()

    private var window: TDHostHomeOverlayWindow?
    private var hosting: UIHostingController<TDGlobalHomeOverlay>?
    private var observer: NSObjectProtocol?

    private init() {
        observer = NotificationCenter.default.addObserver(
            forName: UIScene.didActivateNotification, object: nil, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.attach() }
        }
    }

    func attach() {
        guard let scene = UIApplication.shared.connectedScenes
            .compactMap({ $0 as? UIWindowScene })
            .first(where: { $0.activationState == .foregroundActive }) else { return }
        if let window, window.windowScene === scene, !window.isHidden { return }

        window?.isHidden = true
        let host = UIHostingController(rootView: TDGlobalHomeOverlay(action: {
            // Over a guest, minimizing is what the Home press means; on the
            // host's own screens the observer below closes what is open.
            CFNotificationCenterPostNotification(CFNotificationCenterGetDarwinNotifyCenter(),
                                                 CFNotificationName("com.kdt.livecontainer.minimizeAll" as CFString),
                                                 nil, nil, true)
            NotificationCenter.default.post(name: .lcHostHomePressed, object: nil)
        }))
        host.view.backgroundColor = .clear
        let overlay = TDHostHomeOverlayWindow(windowScene: scene)
        overlay.frame = scene.coordinateSpace.bounds
        overlay.windowLevel = UIWindow.Level.alert + 2
        overlay.backgroundColor = .clear
        overlay.rootViewController = host
        overlay.isHidden = false
        hosting = host
        window = overlay
    }
}
