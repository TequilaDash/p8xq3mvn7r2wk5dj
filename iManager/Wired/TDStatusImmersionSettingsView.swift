//
//  TDStatusImmersionSettingsView.swift
//  iManager
//

import SwiftUI

/// iManager > 实验性 > 状态栏沉浸.
///
/// The Home Screen hides the status bar while immersive content fills the
/// top of the screen, the way the iOS Home Screen does in an app that
/// requests it. The toggle is stored in the app group, so the whole app —
/// the Home Screen, guest windows, and multitask windows — reads it.
struct TDStatusImmersionSettingsView: View {
    /// Whether the Home Screen's status bar immersive mode is on.
    @AppStorage("LCStatusBarImmersion", store: LCUtils.appGroupUserDefault)
    private var immersion = false

    /// Whether the card example shows the animated demo instead of a static
    /// preview. It plays once each time the page opens.
    @State private var demoPlaying = false

    var body: some View {
        List {
            Section {
                Toggle("主屏幕隐藏状态栏", isOn: $immersion)
            } footer: {
                Text("仅作用于主屏幕。访客应用和多任务窗口保持各自的状态栏。")
            }

            Section {
                ImmersionDemoCard(playing: demoPlaying)
            } header: {
                Text("示例")
            } footer: {
                Text("状态栏按该功能使用的卡片动画滑出。")
            }
        }
        .navigationTitle("状态栏沉浸")
        .navigationBarTitleDisplayMode(.inline)
        .onAppear { demoPlaying = true }
        .onDisappear { demoPlaying = false }
    }
}

/// The animated example: a wallpaper-like card whose status bar slides away
/// and back, showing what the toggle does to the Home Screen.
private struct ImmersionDemoCard: View {
    /// Whether the demo is running.
    let playing: Bool

    @State private var hidden = false

    var body: some View {
        VStack(spacing: 0) {
            // A fake status bar, drawn over the card the way the system
            // draws the real one over the wallpaper.
            ZStack {
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .fill(Color.blue.gradient.opacity(0.85))
                    .aspectRatio(16 / 9, contentMode: .fit)
                VStack {
                    HStack {
                        Text("9:41")
                            .font(.system(size: 14, weight: .semibold, design: .rounded))
                            .foregroundStyle(.white)
                        Spacer()
                        Image(systemName: "wifi")
                        Image(systemName: "battery.75percent")
                    }
                    .font(.system(size: 13))
                    .foregroundStyle(.white)
                    .padding(.horizontal, 18)
                    .padding(.top, 8)
                    .opacity(hidden ? 0 : 1)
                    .frame(maxHeight: .infinity, alignment: .top)
                }
            }
            .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
            .frame(maxWidth: 320)
            .animation(.spring(response: 0.55, dampingFraction: 0.8), value: hidden)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 12)
        .onChange(of: playing) { _, isPlaying in
            guard isPlaying else { return }
            // Play once: hide, pause to let the animation finish, restore.
            hidden = true
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.4) { hidden = false }
        }
    }
}
