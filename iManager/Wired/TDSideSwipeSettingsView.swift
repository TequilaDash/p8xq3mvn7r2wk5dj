import SwiftUI

struct TDSideSwipeSettingsView: View {
    private static var defaults: UserDefaults? {
        UserDefaults(suiteName: LCSharedUtils.appGroupID())
    }

    @State private var mode: String = {
        (Self.defaults?.string(forKey: "TDSideSwipeMode")) ?? "default"
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
                row("全局应用", value: "always")
            } footer: {
                Text("全局应用后，在任意访客应用界面从屏幕左右边缘向下滑动，可使用与主屏按键相同的返回动作。")
                    .font(.footnote)
            }
        }
        .navigationTitle("侧边下滑")
        .navigationBarTitleDisplayMode(.inline)
    }

    private var demoCard: some View {
        ZStack(alignment: .topLeading) {
            RoundedRectangle(cornerRadius: 20, style: .continuous)
                .fill(
                    LinearGradient(colors: [Color(red: 0.36, green: 0.42, blue: 0.95),
                                            Color(red: 0.62, green: 0.35, blue: 0.92)],
                                   startPoint: .topLeading, endPoint: .bottomTrailing)
                )
            VStack(alignment: .leading, spacing: 8) {
                Text("侧边下滑")
                    .font(.headline)
                    .foregroundStyle(.white)
                Text("从屏幕边缘向下拖动\n回到 zContainer 主界面")
                    .font(.subheadline)
                    .foregroundStyle(.white.opacity(0.85))
            }
            .padding(20)

            GeometryReader { geo in
                Capsule()
                    .fill(Color.white.opacity(0.35))
                    .frame(width: 4)
                    .padding(.vertical, 26)
                    .offset(x: geo.size.width - 26)
                Image(systemName: "hand.point.down.fill")
                    .font(.system(size: 30, weight: .semibold))
                    .foregroundStyle(.white)
                    .shadow(color: .black.opacity(0.25), radius: 4, y: 2)
                    .offset(x: geo.size.width - 40,
                            y: animate ? geo.size.height - 80 : 24)
                    .opacity(animate ? 1 : 0.2)
                    .animation(.easeInOut(duration: 1.5).repeatForever(autoreverses: false),
                               value: animate)
            }
        }
        .frame(height: 170)
        .clipShape(RoundedRectangle(cornerRadius: 20, style: .continuous))
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
        .onAppear { animate = true }
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
            Self.defaults?.set(value, forKey: "TDSideSwipeMode")
        }
    }
}
