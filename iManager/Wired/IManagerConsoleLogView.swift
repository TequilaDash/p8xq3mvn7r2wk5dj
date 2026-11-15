import SwiftUI

private struct IManagerConsoleLogFile: Identifiable {
    let name: String
    let body: String
    var id: String { name }
}

struct IManagerConsoleLogView: View {
    // 宿主 App 与 LiveProcess 都写 app group; 旧版本把日志写在 Documents, 两处都读.
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

    var body: some View {
        List {
            if files.isEmpty {
                Text("暂无日志。启动访客或发生崩溃后会写入 ConsoleLog。")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }
            ForEach(files, id: \.self) { name in
                Button {
                    open(name)
                } label: {
                    Label(name, systemImage: name.hasPrefix("crash-") ? "exclamationmark.triangle" : "doc.text")
                }
            }
        }
        .navigationTitle("ConsoleLog")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            Button("刷新") { refresh() }
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
                    ShareLink(item: file.body) {
                        Image(systemName: "square.and.arrow.up")
                    }
                    Button("关闭") { opened = nil }
                }
            }
        }
    }

    private func refresh() {
        var names = Set<String>()
        for directory in Self.directories {
            try? FileManager.default.createDirectory(atPath: directory, withIntermediateDirectories: true)
            let list = (try? FileManager.default.contentsOfDirectory(atPath: directory)) ?? []
            names.formUnion(list.filter { $0.hasSuffix(".log") })
        }
        files = names.sorted(by: >)
    }

    private func open(_ name: String) {
        for directory in Self.directories {
            let path = directory + "/" + name
            if let body = try? String(contentsOfFile: path, encoding: .utf8) {
                opened = IManagerConsoleLogFile(name: name, body: body)
                return
            }
        }
        opened = IManagerConsoleLogFile(name: name, body: "无法读取该文件")
    }
}
