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

    // 两个进程共用的设置: app group defaults.
    private static var sharedDefaults: UserDefaults? {
        UserDefaults(suiteName: LCSharedUtils.appGroupID())
    }

    @State private var envSpoof: Bool = {
        (Self.sharedDefaults?.object(forKey: "TDEnvSpoof") as? Bool) ?? true
    }()

    @State private var crashSignals: Bool = {
        (Self.sharedDefaults?.object(forKey: "TDConsoleSignals") as? Bool) ?? false
    }()

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
                    Label("ConsoleLog", systemImage: "exclamationmark.triangle")
                }
            } header: {
                Text("诊断")
            }
            Section {
                Toggle("环境伪值", isOn: $envSpoof)
                Toggle("崩溃信号采集", isOn: $crashSignals)
            } header: {
                Text("实验性")
            } footer: {
                Text("环境伪值关闭后所有访客都不再做 sysctl/SecTask/csops/proc 伪值；崩溃信号采集会安装信号处理器以记录回溯，部分检测器会因此多报一项。")
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
        .onChange(of: envSpoof) { nv in
            Self.sharedDefaults?.set(nv, forKey: "TDEnvSpoof")
        }
        .onChange(of: crashSignals) { nv in
            Self.sharedDefaults?.set(nv, forKey: "TDConsoleSignals")
        }
        .navigationTitle("iManager")
        .navigationBarTitleDisplayMode(.inline)
    }
}
