import SwiftUI
import UniformTypeIdentifiers

struct TDAudioInputSettingsView: View {
    private static var defaults: UserDefaults? {
        UserDefaults(suiteName: LCSharedUtils.appGroupID())
    }

    @State private var enabled: Bool = {
        (Self.defaults?.object(forKey: "TDAudioInputBridge") as? Bool) ?? false
    }()
    @State private var animate = false
    @State private var showLog = false

    var body: some View {
        List {
            Section {
                demoCard
                    .listRowInsets(EdgeInsets())
                    .listRowBackground(Color.clear)
            }

            Section {
                Toggle("修复音频输入", isOn: $enabled)
                    .onChange(of: enabled) { _, value in
                        Self.defaults?.set(value, forKey: "TDAudioInputBridge")
                        Self.defaults?.synchronize()
                        CFNotificationCenterPostNotification(CFNotificationCenterGetDarwinNotifyCenter(),
                                                             CFNotificationName("com.td.audioBridge.settingChanged" as CFString),
                                                             nil, nil, true)
                    }
            }
        }
        .navigationTitle("修复音频输入")
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
        .onAppear { animate = true }
    }

    private var demoCard: some View {
        ZStack {
            RoundedRectangle(cornerRadius: 20, style: .continuous)
                .fill(enabled ? AnyShapeStyle(Color.green.opacity(0.12)) : AnyShapeStyle(Color.red.opacity(0.10)))
            HStack(spacing: 16) {
                beforeAfterCard
                Spacer()
                micGlyph
            }
            .padding(20)
        }
        .frame(height: 170)
        .clipShape(RoundedRectangle(cornerRadius: 20, style: .continuous))
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
    }

    private var beforeAfterCard: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 8) {
                Image(systemName: enabled ? "checkmark.circle.fill" : "xmark.circle.fill")
                    .foregroundStyle(enabled ? Color.green : Color.red)
                    .font(.title3)
                Text(enabled ? "after" : "before")
                    .font(.title3.bold())
                    .monospaced()
            }
            HStack(spacing: 6) {
                ForEach(0..<5, id: \.self) { i in
                    Capsule()
                        .fill(enabled ? Color.green : Color.red)
                        .frame(width: 5, height: waveHeight(index: i))
                        .animation(.easeInOut(duration: 0.6).repeatForever(autoreverses: true).delay(Double(i) * 0.12),
                                   value: animate && enabled)
                }
            }
            Text(enabled ? "宿主桥接输入 ✓" : "无输入 ✗")
                .font(.footnote)
                .foregroundStyle(.secondary)
        }
    }

    private func waveHeight(index: Int) -> CGFloat {
        let levels: [CGFloat] = [10, 22, 34, 20, 12]
        return animate && enabled ? levels[index] : 8
    }

    private var micGlyph: some View {
        Image(systemName: enabled ? "mic.badge.checkmark" : "mic.slash")
            .font(.system(size: 40, weight: .medium))
            .foregroundStyle(enabled ? Color.green : Color.red)
    }
}

/// 音频桥独立日志：app group 根 TDAudioBridge/bridge.log，右上角弹窗查看，
/// 带导出（分享）与删除。不与 ConsoleLog/exploit 日志混用。
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
                    ContentUnavailableView("暂无音频桥日志", systemImage: "waveform.badge.mic")
                } else {
                    ScrollView {
                        Text(logText)
                            .font(.system(.footnote, design: .monospaced))
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .padding()
                    }
                }
            }
            .navigationTitle("音频桥日志")
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
                          defaultFilename: "audio-bridge.log") { _ in }
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
