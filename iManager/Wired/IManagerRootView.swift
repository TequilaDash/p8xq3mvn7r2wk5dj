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
                NavigationLink {
                    TDStatusImmersionSettingsView()
                } label: {
                    Label("状态栏沉浸", systemImage: "rectangle.topthird.inset.filled")
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
        .onChange(of: envSpoof) { nv in
            Self.sharedDefaults?.set(nv, forKey: "TDEnvSpoof")
            Self.sharedDefaults?.synchronize()
        }
        .onChange(of: crashSignals) { nv in
            Self.sharedDefaults?.set(nv, forKey: "TDConsoleSignals")
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
    @AppStorage("TDAppStackClearAllEnabled", store: LCUtils.appGroupUserDefault)
    private var clearAllEnabled = true
    @AppStorage("TDAppStackBackground", store: LCUtils.appGroupUserDefault)
    private var backgroundSource = "app"
    @AppStorage("TDAppStackBlur", store: LCUtils.appGroupUserDefault)
    private var backgroundBlur = 12.0

    var body: some View {
        List {
            Section {
                Toggle("堆叠后台", isOn: $enabled)
                    .onChange(of: enabled) { _, _ in
                        LCUtils.appGroupUserDefault.synchronize()
                    }
                Toggle("全部清除", isOn: $clearAllEnabled)
                    .onChange(of: clearAllEnabled) { _, _ in
                        LCUtils.appGroupUserDefault.synchronize()
                    }
            }
            Section {
                Picker("背景", selection: $backgroundSource) {
                    Text("跟随壁纸").tag("wallpaper")
                    Text("跟随应用").tag("app")
                }
                .pickerStyle(.segmented)
                .onChange(of: backgroundSource) { _, _ in
                    LCUtils.appGroupUserDefault.synchronize()
                }
                HStack {
                    Text("背景模糊")
                    Slider(value: $backgroundBlur, in: 0...30, step: 1)
                        .onChange(of: backgroundBlur) { _, _ in
                            LCUtils.appGroupUserDefault.synchronize()
                        }
                    Text("\(Int(backgroundBlur))")
                        .monospacedDigit()
                        .foregroundStyle(.secondary)
                }
            }
            Section {
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
