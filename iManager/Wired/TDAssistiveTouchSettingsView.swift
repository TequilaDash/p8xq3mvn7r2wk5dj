import SwiftUI

struct TDAssistiveTouchSettingsView: View {
    private static var defaults: UserDefaults? {
        UserDefaults(suiteName: LCSharedUtils.appGroupID())
    }

    @State private var mode: String = {
        (Self.defaults?.string(forKey: "TDAssistiveTouchMode")) ?? "default"
    }()
    @State private var idleDim: Bool = {
        (Self.defaults?.object(forKey: "TDAssistiveTouchIdleDim") as? Bool) ?? true
    }()
    @State private var idleAlpha: Double = {
        (Self.defaults?.object(forKey: "TDAssistiveTouchIdleAlpha") as? Double) ?? 0.4
    }()
    @State private var animate = false

    var body: some View {
        List {
            Section {
                demoCard
                    .listRowInsets(EdgeInsets())
                    .listRowBackground(Color.clear)
            }

            Section {
                row("保持现状", value: "default")
                row("始终显示", value: "always")
            } footer: {
                Text("保持现状：沿用“外观 → 应用内显示主屏按键”和每个 App 自己的开关，行为与加入实验开关前一致。始终显示：任何界面、包括桌面都显示同一个可拖动的辅助触控按钮，单击返回 zContainer 主界面。")
                    .font(.footnote)
            }

            Section {
                Toggle("空闲时淡化", isOn: $idleDim)
                    .onChange(of: idleDim) { _, value in
                        Self.defaults?.set(value, forKey: "TDAssistiveTouchIdleDim")
                        Self.defaults?.synchronize()
                    }
                if idleDim {
                    VStack(alignment: .leading, spacing: 6) {
                        HStack {
                            Text("淡化程度")
                            Spacer()
                            Text("\(Int((idleAlpha * 100).rounded()))%")
                                .foregroundStyle(.secondary)
                                .monospacedDigit()
                        }
                        Slider(value: $idleAlpha, in: 0.15...1.0, step: 0.05)
                            .onChange(of: idleAlpha) { _, value in
                                Self.defaults?.set(value, forKey: "TDAssistiveTouchIdleAlpha")
                                Self.defaults?.synchronize()
                            }
                    }
                }
            } footer: {
                Text("空闲 3 秒后按钮会变淡；这里的百分比是变淡后的不透明度。关闭后按钮始终保持全不透明。")
                    .font(.footnote)
            }
        }
        .navigationTitle("辅助触控")
        .navigationBarTitleDisplayMode(.inline)
        .onAppear { animate = true }
    }

    private var demoCard: some View {
        ZStack(alignment: .topLeading) {
            RoundedRectangle(cornerRadius: 20, style: .continuous)
                .fill(
                    LinearGradient(colors: [Color(red: 0.21, green: 0.28, blue: 0.62),
                                            Color(red: 0.48, green: 0.32, blue: 0.72)],
                                   startPoint: .topLeading,
                                   endPoint: .bottomTrailing)
                )

            VStack(alignment: .leading, spacing: 8) {
                Text("辅助触控")
                    .font(.headline)
                    .foregroundStyle(.white)
                Text("拖动按钮到任意位置\n空闲时按设置变淡")
                    .font(.subheadline)
                    .foregroundStyle(.white.opacity(0.85))
            }
            .padding(20)

            GeometryReader { geo in
                ZStack {
                    ForEach([48.0, 38.0, 28.0], id: \.self) { size in
                        Circle()
                            .fill(Color.white.opacity(size > 40 ? 0.12 : (size > 30 ? 0.22 : 0.92)))
                            .frame(width: size, height: size)
                    }
                    Circle()
                        .fill(Color.black.opacity(0.32))
                        .frame(width: 52, height: 52)
                    Circle()
                        .strokeBorder(Color.white.opacity(0.22), lineWidth: 1)
                        .frame(width: 52, height: 52)
                }
                .frame(width: 52, height: 52)
                .opacity(animate ? 0.4 : 1.0)
                .position(
                    x: animate ? geo.size.width - 46 : geo.size.width * 0.56,
                    y: geo.size.height * 0.58
                )
                .animation(
                    .easeInOut(duration: 1.6).repeatForever(autoreverses: true),
                    value: animate
                )
            }
        }
        .frame(height: 170)
        .clipShape(RoundedRectangle(cornerRadius: 20, style: .continuous))
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
    }

    private func row(_ title: String, value: String) -> some View {
        HStack {
            Text(title)
            Spacer()
            if mode == value {
                Image(systemName: "checkmark")
                    .foregroundStyle(Color.accentColor)
            }
        }
        .contentShape(Rectangle())
        .onTapGesture {
            mode = value
            Self.defaults?.set(value, forKey: "TDAssistiveTouchMode")
            Self.defaults?.synchronize()
        }
    }
}
