import SwiftUI
import UIKit

/// 沙盒容器专属日志：`Documents/sandbox.log`（512KB 轮转）.
///
/// 只记录沙盒容器自己的事（呈现方式、多任务窗口 adopt/挂载/退出、LC 容器生命周期），
/// 与「更多 → 日志」「exploit 日志」完全分开（owner 明确要求）.
final class SandboxLog: ObservableObject, @unchecked Sendable {
    static let shared = SandboxLog()

    private let lock = NSLock()
    private let maxBytes = 512 * 1024

    var fileURL: URL {
        let docs = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first
        return (docs ?? URL(fileURLWithPath: NSTemporaryDirectory()))
            .appendingPathComponent("sandbox.log")
    }

    func log(_ message: String) {
        lock.lock()
        defer { lock.unlock() }
        let line = "[\(Self.formatter.string(from: Date()))] \(message)\n"
        let url = fileURL
        if let size = try? FileManager.default.attributesOfItem(atPath: url.path)[.size] as? Int,
           size > maxBytes {
            try? FileManager.default.removeItem(at: url)
        }
        if let handle = try? FileHandle(forWritingTo: url) {
            defer { try? handle.close() }
            handle.seekToEndOfFile()
            handle.write(Data(line.utf8))
        } else {
            try? Data(line.utf8).write(to: url)
        }
    }

    func all() -> String {
        lock.lock()
        defer { lock.unlock() }
        return (try? String(contentsOf: fileURL, encoding: .utf8)) ?? ""
    }

    func clear() {
        lock.lock()
        defer { lock.unlock() }
        try? FileManager.default.removeItem(at: fileURL)
    }

    private static let formatter: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "HH:mm:ss.SSS"
        return f
    }()
}

/// 供 ObjC（TDGuestOverlay / LCUtils）调用.
@_cdecl("TDSandboxLogAppend")
public func TDSandboxLogAppend(_ message: UnsafePointer<CChar>?) {
    guard let message else { return }
    SandboxLog.shared.log(String(cString: message))
}

/// 沙盒容器日志页 —— 沿用既有日志板块的模样（标题「日志」、右上关闭、最近行数 + 刷新 + 等宽文本区）.
struct TDSandboxLogView: View {
    @Environment(\.dismiss) private var dismiss
    @State private var text = ""

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Text("全部日志").font(.footnote).foregroundColor(.secondary)
                Spacer()
                Button("刷新") { reload() }
                Button("清空", role: .destructive) { SandboxLog.shared.clear(); reload() }
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 8)

            ScrollView {
                Text(text.isEmpty ? "（暂无日志）" : text)
                    .font(.system(.caption, design: .monospaced))
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .textSelection(.enabled)
                    .padding(12)
            }
            .background(Color(uiColor: .secondarySystemBackground))
            .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
            .padding(.horizontal, 16)
            .padding(.bottom, 16)
        }
        .navigationTitle("日志")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Button("关闭") { dismiss() }
                    .buttonStyle(.bordered)
                    .clipShape(Capsule())
            }
        }
        .task {
            reload()
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: 2_000_000_000)
                reload()
            }
        }
    }

    private func reload() {
        // 全部日志（owner 要求）：不再截到最近 300 行；文件有 512KB 轮转上限.
        text = SandboxLog.shared.all()
    }
}

/// 沙盒容器 → 设置 →「实验性功能」二级页.
struct TDSandboxExperimentalView: View {
    /// true = 从下往上弹出（fullScreenCover）；false = 原生平滑推入（push，支持左滑返回）.
    @AppStorage("TDPresentSandboxAsSheet") private var presentAsSheet = false

    var body: some View {
        List {
            Section {
                Toggle(isOn: $presentAsSheet) {
                    VStack(alignment: .leading, spacing: 4) {
                        Text("从下往上呈现")
                        Text(presentAsSheet ? "当前：弹出的方式（可下拉关闭）"
                                            : "当前：原生平滑推入（可左滑返回）")
                            .font(.caption)
                            .foregroundColor(.secondary)
                    }
                }
            } header: {
                Text("呈现方式")
            } footer: {
                Text("从下往上：像一张卡片从底部弹出；原生平滑：系统标准推入动画，支持左滑返回。")
            }

            Section {
                PresentStyleFigure(modal: presentAsSheet)
                    .frame(height: 150)
                    .listRowInsets(EdgeInsets())
                    .listRowBackground(Color.clear)
            } header: {
                Text("图例")
            }
        }
        .navigationTitle("实验性功能")
        .navigationBarTitleDisplayMode(.inline)
    }
}

/// 图例：两种呈现方式的示意（纯 SwiftUI 绘制，不依赖图片资源）.
private struct PresentStyleFigure: View {
    let modal: Bool

    var body: some View {
        GeometryReader { geo in
            ZStack {
                RoundedRectangle(cornerRadius: 14, style: .continuous)
                    .fill(Color(uiColor: .secondarySystemBackground))
                if modal {
                    VStack {
                        Spacer()
                        RoundedRectangle(cornerRadius: 18, style: .continuous)
                            .fill(Color(uiColor: .systemBackground))
                            .frame(height: geo.size.height * 0.66)
                            .overlay(alignment: .top) {
                                Capsule()
                                    .fill(Color(uiColor: .tertiaryLabel))
                                    .frame(width: 40, height: 5)
                                    .padding(.top, 8)
                            }
                            .shadow(radius: 8, y: -4)
                            .padding(.horizontal, 14)
                    }
                } else {
                    RoundedRectangle(cornerRadius: 18, style: .continuous)
                        .fill(Color(uiColor: .systemBackground))
                        .padding(14)
                        .overlay(alignment: .topLeading) {
                            Image(systemName: "chevron.backward")
                                .font(.headline)
                                .padding(.leading, 24)
                                .padding(.top, 20)
                        }
                }
            }
            .overlay(alignment: .bottomTrailing) {
                Text(modal ? "从下往上" : "原生平滑")
                    .font(.caption2.weight(.semibold))
                    .padding(.horizontal, 10)
                    .padding(.vertical, 6)
                    .background(.ultraThinMaterial, in: Capsule())
                    .padding(12)
            }
        }
    }
}