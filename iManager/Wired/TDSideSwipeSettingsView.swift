import SwiftUI

struct TDSideSwipeSettingsView: View {
    private static var defaults: UserDefaults? {
        UserDefaults(suiteName: LCSharedUtils.appGroupID())
    }

    @State private var mode: String = {
        (Self.defaults?.string(forKey: "TDSideSwipeMode")) ?? "default"
    }()

    var body: some View {
        List {
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
