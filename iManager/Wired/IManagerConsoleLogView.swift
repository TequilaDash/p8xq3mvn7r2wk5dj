import SwiftUI
import UIKit

private struct IManagerConsoleLogFile: Identifiable {
    let url: URL
    let source: String
    var name: String { url.lastPathComponent }
    var id: URL { url }
}

private struct IManagerConsoleLogDocument: Identifiable {
    let file: IManagerConsoleLogFile
    let body: String
    var id: URL { file.id }
}

struct IManagerConsoleLogView: View {
    private static var directories: [(source: String, url: URL)] {
        var dirs: [(source: String, url: URL)] = []
        if let group = FileManager.default.containerURL(forSecurityApplicationGroupIdentifier: LCSharedUtils.appGroupID()) {
            dirs.append(("共享目录", group.appendingPathComponent("LiveContainer/ConsoleLog", isDirectory: true)))
        }
        dirs.append(("宿主目录", URL(fileURLWithPath: NSHomeDirectory(), isDirectory: true)
            .appendingPathComponent("Documents/ConsoleLog", isDirectory: true)))
        return dirs
    }

    @State private var files: [IManagerConsoleLogFile] = []
    @State private var opened: IManagerConsoleLogDocument?
    @State private var selected: Set<URL> = []
    @State private var selecting = false

    var body: some View {
        List {
            if files.isEmpty {
                Text("暂无日志。启动访客或发生崩溃后会写入 ConsoleLog。")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }
            ForEach(files) { file in
                HStack(spacing: 10) {
                    if selecting {
                        Image(systemName: selected.contains(file.id) ? "checkmark.circle.fill" : "circle")
                            .foregroundStyle(selected.contains(file.id) ? Color.accentColor : Color.secondary)
                    }
                    VStack(alignment: .leading, spacing: 4) {
                        Label(file.name, systemImage: file.name.hasPrefix("crash-") ? "exclamationmark.triangle" : "doc.text")
                        Text(file.source)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    Spacer()
                }
                .contentShape(Rectangle())
                .onTapGesture {
                    if selecting {
                        if selected.contains(file.id) { selected.remove(file.id) } else { selected.insert(file.id) }
                    } else {
                        open(file)
                    }
                }
            }
        }
        .navigationTitle("ConsoleLog")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .topBarLeading) {
                if selecting {
                    Button(selected.count == files.count ? "取消全选" : "全选") {
                        if selected.count == files.count { selected.removeAll() } else { selected = Set(files.map(\.id)) }
                    }
                }
            }
            ToolbarItem(placement: .topBarTrailing) {
                Menu {
                    if selecting {
                        Button("导出") { exportSelected() }.disabled(selected.isEmpty)
                        Button("删除", role: .destructive) { deleteSelected() }.disabled(selected.isEmpty)
                        Button("完成") { selecting = false; selected.removeAll() }
                    } else {
                        Button("选择") { selecting = true }
                        Button("刷新") { refresh() }
                    }
                } label: {
                    Image(systemName: "ellipsis.circle")
                }
            }
        }
        .onAppear { refresh() }
        .sheet(item: $opened) { document in
            NavigationStack {
                ScrollView {
                    Text(document.body)
                        .font(.system(.footnote, design: .monospaced))
                        .textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding()
                }
                .navigationTitle(document.file.name)
                .navigationBarTitleDisplayMode(.inline)
                .toolbar {
                    ShareLink(item: document.file.url) { Image(systemName: "square.and.arrow.up") }
                    Button("关闭") { opened = nil }
                }
            }
        }
    }


    private func exportSelected() {
        if selected.count == 1, let url = selected.first {
            presentShare(url)
            return
        }
        let stamp = ISO8601DateFormatter().string(from: Date()).replacingOccurrences(of: ":", with: "-")
        let exportDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("ConsoleLog-\(stamp)-\(UUID().uuidString)", isDirectory: true)
        let fm = FileManager.default
        // 同名日志按来源分目录导出, 不再因文件名相同而覆盖或漏掉其中一份.
        for file in files where selected.contains(file.id) {
            let sourceDir = exportDir.appendingPathComponent(file.source, isDirectory: true)
            try? fm.createDirectory(at: sourceDir, withIntermediateDirectories: true)
            try? fm.copyItem(at: file.url, to: sourceDir.appendingPathComponent(file.name))
        }
        presentShare(exportDir)
    }

    private func presentShare(_ url: URL) {
        let controller = UIActivityViewController(activityItems: [url], applicationActivities: nil)
        guard let scene = UIApplication.shared.connectedScenes.compactMap({ $0 as? UIWindowScene })
            .first(where: { $0.activationState == .foregroundActive }),
              let root = (scene.windows.first(where: \.isKeyWindow) ?? scene.windows.first(where: { !$0.isHidden }))?.rootViewController else { return }
        var presenter = root
        while let presented = presenter.presentedViewController { presenter = presented }
        if let popover = controller.popoverPresentationController {
            popover.sourceView = presenter.view
            popover.sourceRect = CGRect(x: presenter.view.bounds.midX, y: presenter.view.bounds.maxY, width: 0, height: 0)
            popover.permittedArrowDirections = []
        }
        presenter.present(controller, animated: true)
    }

    private func deleteSelected() {
        let fm = FileManager.default
        for url in selected {
            try? fm.removeItem(at: url)
        }
        selected.removeAll()
        selecting = false
        refresh()
    }

    private func refresh() {
        var discovered: [URL: IManagerConsoleLogFile] = [:]
        let fm = FileManager.default
        for directory in Self.directories {
            try? fm.createDirectory(at: directory.url, withIntermediateDirectories: true)
            let list = (try? fm.contentsOfDirectory(at: directory.url,
                includingPropertiesForKeys: [.isRegularFileKey])) ?? []
            for url in list {
                let name = url.lastPathComponent
                guard name.hasSuffix(".log") || (name.hasPrefix("imagemap-") && name.hasSuffix(".txt")),
                      (try? url.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile) == true else { continue }
                let file = IManagerConsoleLogFile(url: url.standardizedFileURL, source: directory.source)
                discovered[file.id] = file
            }
        }
        files = discovered.values.sorted {
            $0.name == $1.name ? $0.url.path < $1.url.path : $0.name > $1.name
        }
        selected = selected.intersection(Set(discovered.keys))
    }

    private func open(_ file: IManagerConsoleLogFile) {
        let body = (try? String(contentsOf: file.url, encoding: .utf8)) ?? "无法读取该文件"
        opened = IManagerConsoleLogDocument(file: file, body: body)
    }
}
