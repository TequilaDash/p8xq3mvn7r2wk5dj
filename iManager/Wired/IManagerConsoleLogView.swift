import SwiftUI

private struct IManagerConsoleLogFile: Identifiable {
    let name: String
    let body: String
    var id: String { name }
}

struct IManagerConsoleLogView: View {
    private static var directory: String? {
        guard let path = TDHostHomeDocumentsPath(), path[0] != 0 else { return nil }
        return String(cString: path) + "/ConsoleLog"
    }

    @State private var files: [String] = []
    @State private var opened: IManagerConsoleLogFile?

    var body: some View {
        List {
            if files.isEmpty {
                Text("暂无日志。启动访客或发生崩溃后会写入 Documents/ConsoleLog。")
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
        .navigationTitle("崩溃日志")
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
        guard let directory = Self.directory else {
            files = []
            return
        }
        try? FileManager.default.createDirectory(atPath: directory, withIntermediateDirectories: true)
        let names = (try? FileManager.default.contentsOfDirectory(atPath: directory)) ?? []
        files = names
            .filter { $0.hasSuffix(".log") }
            .sorted(by: >)
    }

    private func open(_ name: String) {
        guard let directory = Self.directory else { return }
        let path = directory + "/" + name
        let body = (try? String(contentsOfFile: path, encoding: .utf8)) ?? "无法读取该文件"
        opened = IManagerConsoleLogFile(name: name, body: body)
    }
}
