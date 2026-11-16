import SwiftUI
import UIKit

private struct IManagerConsoleLogFile: Identifiable {
    let name: String
    let body: String
    var id: String { name }
}

struct IManagerConsoleLogView: View {
    private static var directories: [String] {
        var dirs: [String] = []
        if let group = FileManager.default.containerURL(forSecurityApplicationGroupIdentifier: LCSharedUtils.appGroupID()) {
            dirs.append(group.appendingPathComponent("LiveContainer/ConsoleLog").path)
        }
        dirs.append(NSHomeDirectory() + "/Documents/ConsoleLog")
        return dirs
    }

    @State private var files: [String] = []
    @State private var opened: IManagerConsoleLogFile?
    @State private var selected: Set<String> = []
    @State private var selecting = false

    var body: some View {
        List(selection: $selected) {
            if files.isEmpty {
                Text("暂无日志。启动访客或发生崩溃后会写入 ConsoleLog。")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }
            ForEach(files, id: \.self) { name in
                HStack {
                    if selecting {
                        Image(systemName: selected.contains(name) ? "checkmark.circle.fill" : "circle")
                            .foregroundStyle(selected.contains(name) ? .accentColor : .secondary)
                    }
                    Button {
                        if selecting {
                            toggle(name)
                        } else {
                            open(name)
                        }
                    } label: {
                        Label(name, systemImage: name.hasPrefix("crash-") ? "exclamationmark.triangle" : "doc.text")
                    }
                }
            }
        }
        .navigationTitle("ConsoleLog")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                if selecting {
                    Button(selected.count == files.count ? "取消全选" : "全选") {
                        if selected.count == files.count {
                            selected.removeAll()
                        } else {
                            selected = Set(files)
                        }
                    }
                } else {
                    Button("选择") { selecting = true }
                }
            }
            ToolbarItem(placement: .topBarTrailing) {
                if selecting {
                    Menu {
                        Button("导出所选") { exportSelected() }
                            .disabled(selected.isEmpty)
                        Button("删除所选", role: .destructive) { deleteSelected() }
                            .disabled(selected.isEmpty)
                    } label: {
                        Image(systemName: "ellipsis.circle")
                    }
                } else {
                    Button("刷新") { refresh() }
                }
            }
        }
        .onAppear { refresh() }
        .sheet(item: $opened) { file in
            NavigationStack {
                ScrollView {
                    Text(file.body)
                        .font(.system(.footnote, design: .monospaced))
                        .textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding()
                }
                .navigationTitle(file.name)
                .navigationBarTitleDisplayMode(.inline)
                .toolbar {
                    if let url = fileURL(file.name) {
                        // 分享真实文件, 而不是把内容当文本发出去.
                        ShareLink(item: url) {
                            Image(systemName: "square.and.arrow.up")
                        }
                    }
                    Button("关闭") { opened = nil }
                }
            }
        }
    }


    private func toggle(_ name: String) {
        if selected.contains(name) {
            selected.remove(name)
        } else {
            selected.insert(name)
        }
    }

    private func fileURL(_ name: String) -> URL? {
        for directory in Self.directories {
            let path = directory + "/" + name
            if FileManager.default.fileExists(atPath: path) {
                return URL(fileURLWithPath: path)
            }
        }
        return nil
    }

    private func exportSelected() {
        // 单文件导出文件本身; 多文件导出 ConsoleLog 文件夹.
        if selected.count == 1, let name = selected.first, let url = fileURL(name) {
            presentShare(url)
        } else if let directory = Self.directories.first(where: { FileManager.default.fileExists(atPath: $0) }) {
            presentShare(URL(fileURLWithPath: directory))
        }
    }

    private func presentShare(_ url: URL) {
        let controller = UIActivityViewController(activityItems: [url], applicationActivities: nil)
        guard let scene = UIApplication.shared.connectedScenes.compactMap({ $0 as? UIWindowScene }).first,
              let root = scene.keyWindow?.rootViewController else { return }
        var presenter = root
        while let presented = presenter.presentedViewController { presenter = presented }
        presenter.present(controller, animated: true)
    }

    private func deleteSelected() {
        let fm = FileManager.default
        for name in selected {
            for directory in Self.directories {
                try? fm.removeItem(atPath: directory + "/" + name)
            }
        }
        selected.removeAll()
        selecting = false
        refresh()
    }

    private func refresh() {
        var names = Set<String>()
        for directory in Self.directories {
            try? FileManager.default.createDirectory(atPath: directory, withIntermediateDirectories: true)
            let list = (try? FileManager.default.contentsOfDirectory(atPath: directory)) ?? []
            names.formUnion(list.filter { $0.hasSuffix(".log") })
        }
        files = names.sorted(by: >)
        selected = selected.intersection(names)
    }

    private func open(_ name: String) {
        guard let url = fileURL(name) else {
            opened = IManagerConsoleLogFile(name: name, body: "无法读取该文件")
            return
        }
        let body = (try? String(contentsOf: url, encoding: .utf8)) ?? "无法读取该文件"
        opened = IManagerConsoleLogFile(name: name, body: body)
    }
}

