import SwiftUI

struct IManagerRootView: View {
    @State private var globalHide: Bool = {
        let p = NSHomeDirectory() + "/Documents/TDGlobalHide"
        return (try? String(contentsOfFile: p, encoding: .utf8)) == "1"
    }()
    private var flagPath: String { NSHomeDirectory() + "/Documents/TDGlobalHide" }
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
        .onChange(of: globalHide) { nv in
            if nv {
                try? "1".write(to: URL(fileURLWithPath: flagPath), atomically: true, encoding: .utf8)
            } else {
                try? FileManager.default.removeItem(atPath: flagPath)
            }
        }
        .navigationTitle("iManager")
        .navigationBarTitleDisplayMode(.inline)
    }
}
