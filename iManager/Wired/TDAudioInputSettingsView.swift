import SwiftUI
import UniformTypeIdentifiers

struct TDAudioInputSettingsView: View {
    private static var defaults: UserDefaults? {
        UserDefaults(suiteName: LCSharedUtils.appGroupID())
    }

    @State private var enabled: Bool = {
        (Self.defaults?.object(forKey: "TDAudioInputBridge") as? Bool) ?? false
    }()
    @State private var showLog = false

    var body: some View {
        List {
            Section {
                demoCard
                    .listRowInsets(EdgeInsets())
                    .listRowBackground(Color.clear)
            }

            Section {
                Toggle("记录访客音频会话日志", isOn: $enabled)
                    .onChange(of: enabled) { _, value in
                        Self.defaults?.set(value, forKey: "TDAudioInputBridge")
                        Self.defaults?.synchronize()
                        CFNotificationCenterPostNotification(CFNotificationCenterGetDarwinNotifyCenter(),
                                                             CFNotificationName("com.td.audioBridge.settingChanged" as CFString),
                                                             nil, nil, true)
                    }
            }
        }
        .navigationTitle("音频会话诊断")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Button {
                    showLog = true
                } label: {
                    Image(systemName: "doc.text.magnifyingglass")
                }
            }
        }
        .sheet(isPresented: $showLog) {
            TDAudioBridgeLogView()
        }
    }

    private var demoCard: some View {
        HStack(spacing: 16) {
            Image(systemName: enabled ? "waveform" : "waveform.slash")
                .font(.system(size: 32, weight: .medium))
                .foregroundStyle(enabled ? Color.green : Color.secondary)
            VStack(alignment: .leading, spacing: 6) {
                Text(enabled ? "会话诊断日志已开启" : "会话诊断日志已关闭")
                    .font(.headline)
                Text("只记录访客 AVAudioSession 调用；不传输麦克风音频。")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }
            Spacer(minLength: 0)
        }
        .frame(maxWidth: .infinity, minHeight: 110, alignment: .leading)
        .padding(20)
        .background(enabled ? Color.green.opacity(0.10) : Color.secondary.opacity(0.08),
                    in: RoundedRectangle(cornerRadius: 20, style: .continuous))
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
    }
}

/// 仅查看当前访客进程的 AVAudioSession 诊断日志，不包含跨进程音频传输。
/// 文件位于 app group 的 TDAudioBridge/bridge.log。
struct TDAudioBridgeLogView: View {
    @Environment(\.dismiss) private var dismiss
    @State private var logText = ""
    @State private var showExporter = false

    private static var logURL: URL? {
        guard let groupID = LCSharedUtils.appGroupID() as String?,
              let groupURL = FileManager.default.containerURL(forSecurityApplicationGroupIdentifier: groupID) else { return nil }
        let dir = groupURL.appendingPathComponent("TDAudioBridge", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir.appendingPathComponent("bridge.log")
    }

    private func reload() {
        guard let url = Self.logURL, let text = try? String(contentsOf: url, encoding: .utf8) else {
            logText = ""
            return
        }
        logText = text
    }

    var body: some View {
        NavigationStack {
            Group {
                if logText.isEmpty {
                    ContentUnavailableView("暂无音频会话日志", systemImage: "waveform.badge.mic")
                } else {
                    ScrollView {
                        Text(logText)
                            .font(.system(.footnote, design: .monospaced))
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .padding()
                    }
                }
            }
            .navigationTitle("音频会话日志")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button("关闭") { dismiss() }
                }
                ToolbarItemGroup(placement: .topBarTrailing) {
                    Button {
                        showExporter = true
                    } label: {
                        Image(systemName: "square.and.arrow.up")
                    }
                    .disabled(logText.isEmpty)
                    Button(role: .destructive) {
                        if let url = Self.logURL {
                            try? FileManager.default.removeItem(at: url)
                            reload()
                        }
                    } label: {
                        Image(systemName: "trash")
                    }
                    .disabled(logText.isEmpty)
                }
            }
            .onAppear { reload() }
            .fileExporter(isPresented: $showExporter,
                          document: TextFileDocument(text: logText),
                          contentType: .plainText,
                          defaultFilename: "audio-session-diagnostics.log") { _ in }
        }
    }
}

struct TextFileDocument: FileDocument {
    static var readableContentTypes: [UTType] { [.plainText] }
    var text: String
    init(text: String) { self.text = text }
    init(configuration: ReadConfiguration) throws {
        text = String(data: configuration.file.regularFileContents ?? Data(), encoding: .utf8) ?? ""
    }
    func fileWrapper(configuration: WriteConfiguration) throws -> FileWrapper {
        FileWrapper(regularFileWithContents: text.data(using: .utf8) ?? Data())
    }
}
