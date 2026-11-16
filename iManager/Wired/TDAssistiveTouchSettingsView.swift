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
            Section {
                Picker("显示方式", selection: $mode) {
                    Text("保持现状").tag("default")
                    Text("始终显示").tag("always")
                }
                .pickerStyle(.inline)
            } footer: {
                Text("保持现状：沿用应用设置里的主屏按键开关，行为与之前完全一致。始终显示：任何应用界面都显示同一个主屏按键，只有单击回到主界面这一个功能。")
            }
        }
        .navigationTitle("辅助触控")
        .navigationBarTitleDisplayMode(.inline)
        .onChange(of: mode) { nv in
            Self.defaults?.set(nv, forKey: "TDAssistiveTouchMode")
        }
    }
}
