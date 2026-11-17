import SwiftUI

struct TDAssistiveTouchSettingsView: View {
    private static var defaults: UserDefaults? {
        UserDefaults(suiteName: LCSharedUtils.appGroupID())
    }

    @State private var mode: String = {
        (Self.defaults?.string(forKey: "TDAssistiveTouchMode")) ?? "default"
    }()

    var body: some View {
        List {
            row("保持现状", value: "default")
            row("始终显示", value: "always")
        }
        .navigationTitle("辅助触控")
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
            Self.defaults?.set(value, forKey: "TDAssistiveTouchMode")
            Self.defaults?.synchronize()
        }
    }
}
