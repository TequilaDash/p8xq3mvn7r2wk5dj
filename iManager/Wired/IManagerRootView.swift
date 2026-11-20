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
                NavigationLink {
                    TDAssistiveTouchSettingsView()
                } label: {
                    Label("辅助触控", systemImage: "circle.grid.cross")
                }
                NavigationLink {
                    TDSideSwipeSettingsView()
                } label: {
                    Label("侧边下滑", systemImage: "hand.draw")
                }
                NavigationLink {
                    TDAudioInputSettingsView()
                } label: {
                    Label("修复音频输入", systemImage: "mic.badge.plus")
                }
            } header: {
                Text("实验性")
            } footer: {
        Text("环境伪值关闭后所有访客都不再做 sysctl/SecTask/csops/proc 伪值；崩溃信号采集开启后记录信号回溯；辅助触控与侧边下滑分别控制主屏按键和返回手势。")
            }
        }
        .onChange(of: globalHide) { nv in
            // app group 是宿主与 LiveProcess 扩展**都能**读到的地方. Documents
            // 标志文件只有宿主进程能读到 (扩展进程的 HOME 是扩展沙盒), 多任务
            // 访客因此永远读到"未开启全局隐藏" —— 用户实测"开了和不开一样".
            Self.sharedDefaults?.set(nv, forKey: "TDGlobalHide")
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
        .onChange(of: crashSignals) { nv in
            Self.sharedDefaults?.set(nv, forKey: "TDConsoleSignals")
        }
        .onAppear {
            // TDAudioBridgeHost removed in 1.1.55: the guest (LiveProcess
            // extension) now authorizes its own audio session directly
            // (has a foreground scene in multitask windows). Host replay
            // only interrupted other apps' playback.
        }
        .navigationTitle("iManager")
        .navigationBarTitleDisplayMode(.inline)
    }
}
