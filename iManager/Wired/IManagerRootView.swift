import SwiftUI

struct IManagerRootView: View {
    private static var hostDocumentsDir: String? {
        guard let path = TDHostHomeDocumentsPath(), path[0] != 0 else { return nil }
        return String(cString: path)
    }

    @State private var globalHide: Bool = {
        guard let documents = Self.hostDocumentsDir else { return false }
        let path = documents + "/TDGlobalHide"
        return (try? String(contentsOfFile: path, encoding: .utf8)) == "1"
    }()

    private var flagPath: String? {
        Self.hostDocumentsDir.map { $0 + "/TDGlobalHide" }
    }

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
                NavigationLink {
                    IManagerConsoleLogView()
                } label: {
                    Label("崩溃日志", systemImage: "exclamationmark.triangle")
                }
            } header: {
                Text("诊断")
            }
        }
        .onChange(of: globalHide) { nv in
            guard let flagPath else {
                NSLog("[TDGlobalHide] cannot resolve host Documents path")
                return
            }
            do {
                if nv {
                    try "1".write(to: URL(fileURLWithPath: flagPath), atomically: true, encoding: .utf8)
                } else {
                    try FileManager.default.removeItem(atPath: flagPath)
                }
                NSLog("[TDGlobalHide] write=%d path=%@", nv, flagPath)
            } catch {
                NSLog("[TDGlobalHide] write=%d path=%@ error=%@", nv, flagPath, error.localizedDescription)
            }
        }
        .navigationTitle("iManager")
        .navigationBarTitleDisplayMode(.inline)
    }
}
