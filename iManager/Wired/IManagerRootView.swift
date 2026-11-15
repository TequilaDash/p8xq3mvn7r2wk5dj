import SwiftUI

struct IManagerRootView: View {
    // Captured at first access of this SwiftUI type: if any guest has run,
    // HOME is polluted; but this static is initialized lazily on first UI use,
    // which is BEFORE the user can launch a guest (settings are only reachable
    // from the host UI). Acceptable.
    static var hostDocumentsDir: String = {
        let h = getenv("HOME")
        let home = (h != nil) ? String(cString: h!) : NSHomeDirectory()
        return (home as NSString).appendingPathComponent("Documents")
    }()

    @State private var globalHide: Bool = {
        let p = Self.hostDocumentsDir() + "/TDGlobalHide"
        return (try? String(contentsOfFile: p, encoding: .utf8)) == "1"
    }()
    private var flagPath: String { Self.hostDocumentsDir() + "/TDGlobalHide" }
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
