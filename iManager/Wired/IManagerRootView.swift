import SwiftUI

struct IManagerRootView: View {
    @AppStorage("TDGlobalSpoof") private var globalHide = false

    var body: some View {
        List {
            Section {
                Toggle("全局隐藏模式", isOn: $globalHide)
            }
            Section {
                NavigationLink {
                    TDHideStatusView()
                } label: {
                    Label("隐藏状态", systemImage: "eye.slash")
                }
                NavigationLink {
                    ExploitLogView()
                } label: {
                    Label("exploit 日志", systemImage: "doc.text.magnifyingglass")
                }
            } header: {
                Text("诊断")
            }
        }
        .navigationTitle("iManager")
        .navigationBarTitleDisplayMode(.inline)
    }
}
