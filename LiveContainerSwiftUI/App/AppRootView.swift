//
//  AppRootView.swift
//  LiveContainerSwiftUI
//

import SwiftUI

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

            TDGlobalHomeOverlay(action: home.goHome)
                .zIndex(2)
        }
        .onChange(of: onboarding.isPresented, onboardingChanged)
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
                        action()
                        scheduleDim()
                    }
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
                .ignoresSafeArea()
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
