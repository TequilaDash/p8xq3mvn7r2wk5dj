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
                    Label("音频会话诊断", systemImage: "waveform")
                }
                NavigationLink {
                    TDAppStackSettingsView()
                } label: {
                    Label("堆叠后台", systemImage: "rectangle.stack")
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

/// Second level of the experimental settings: the stack background, its real
/// switch, and an animation of what the cards look like. The switch writes the
/// same app-group key the stack manager and both Home buttons read.
struct TDAppStackSettingsView: View {
    @AppStorage("TDAppStackEnabled", store: LCUtils.appGroupUserDefault)
    private var enabled = true

    var body: some View {
        List {
            Section {
                Toggle("启用堆叠后台", isOn: $enabled)
                    .onChange(of: enabled) { _, _ in
                        // The guest button reads the app group in another
                        // process; flush it so a double tap sees the change.
                        LCUtils.appGroupUserDefault?.synchronize()
                    }
            } footer: {
                Text("开启后，双击辅助触控打开堆叠后台；卡片显示应用当前界面（缩小显示），图标在左上角。关闭后双击不再响应。")
            }
            Section("卡片动画示例") {
                TDStackDemoView()
                    .frame(height: 260)
                    .listRowInsets(EdgeInsets())
            }
        }
        .navigationTitle("堆叠后台")
        .navigationBarTitleDisplayMode(.inline)
    }
}

/// A small, self-contained preview of the deck: three cards resting behind the
/// front one, rising as the selection moves. It uses the same geometry as the
/// real deck, so the example matches what the double tap opens.
private struct TDStackDemoView: View {
    @State private var selected = 0
    private let names = ["音乐", "浏览器", "笔记"]

    var body: some View {
        GeometryReader { proxy in
            let width = min(200, proxy.size.width * 0.55)
            let height = min(200, proxy.size.height * 0.7)
            let stride = max(1, width * 0.42)
            ZStack {
                ForEach(Array(names.enumerated()), id: \.offset) { index, name in
                    let distance = CGFloat(index - selected)
                    let depth = min(2, abs(distance))
                    RoundedRectangle(cornerRadius: 18, style: .continuous)
                        .fill(LinearGradient(colors: [.blue.opacity(0.75), .purple.opacity(0.65)],
                                             startPoint: .topLeading, endPoint: .bottomTrailing))
                        .overlay(alignment: .topLeading) {
                            HStack(spacing: 6) {
                                RoundedRectangle(cornerRadius: 5).fill(.white.opacity(0.9))
                                    .frame(width: 16, height: 16)
                                Text(name).font(.caption2.bold()).foregroundStyle(.white)
                            }
                            .padding(8)
                        }
                        .frame(width: width, height: height)
                        .scaleEffect(1 - depth * 0.06)
                        .offset(x: distance * stride, y: depth * 12)
                        .zIndex(Double(names.count) - Double(abs(distance)))
                        .shadow(radius: 8, y: 4)
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .onAppear {
            withAnimation(.spring(response: 0.6, dampingFraction: 0.75).repeatForever(autoreverses: true)) {
                selected = names.count - 1
            }
        }
    }
}
