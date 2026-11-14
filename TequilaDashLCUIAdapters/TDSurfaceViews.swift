import SwiftUI

/// Tier B-1 Surface-lite 调试页: 虚拟进程表 (pid / name / state / kind / 真 kill).
///
/// 数据源 = TDProcTable (ObjC, 编在主 App 二进制与扩展进程; 本 framework 不编它,
/// 链接期 -U 允许未定义符号, 运行时从主可执行文件解析 —— 同 RBSTarget/LCAppInfo 模式).
///
/// 语义 (TDProcTable.h parity 注记):
///   · kill 按钮 = 真 kill(pid, SIGKILL), 且只对表内 running 条目放行 (越界护栏);
///   · 退出状态 = 扩展侧 atexit 自报 + 表内 kill(pid, 0) 轮询收口, 无假实现;
///   · 表持久化在 Documents/TDSurface/proc_table.json, 崩溃/重启后 reconcile 重建.
struct TDSurfaceView: View {
    @State private var rows: [SurfaceRow] = []
    @State private var statusText = ""
    @State private var busyPid: Int32?

    /// 列表行模型 —— ForEach 身份键用结构体 (元组不支持 key path, objc_bridge_guard R2 同因).
    struct SurfaceRow: Identifiable {
        let id: String          // pid-kind 组合, 同 pid 两条目不撞键
        let pid: Int32
        let name: String
        let detail: String      // bundleId + containerUUID
        let kindLabel: String
        let running: Bool
        let stateLabel: String
        let note: String
        let when: String
    }

    var body: some View {
        List {
            Section {
                ForEach(rows) { row in
                    TDSurfaceRowView(row: row, busy: busyPid == row.pid) {
                        kill(row)
                    }
                }
            } header: {
                Text("进程")
            } footer: {
                Text("kill = 真 kill(pid, SIGKILL), 只对本表登记的进程放行; 退出状态由扩展 atexit 与宿主轮询收口.")
            }
            if !statusText.isEmpty {
                Section {
                    Text(statusText)
                        .font(.caption)
                        .foregroundColor(.secondary)
                }
            }
        }
        .navigationTitle("虚拟进程")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Button {
                    reload()
                } label: {
                    Image(systemName: "arrow.clockwise")
                }
            }
            ToolbarItem(placement: .topBarTrailing) {
                Button("清除已退出") {
                    clearExited()
                }
                .font(.footnote)
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
        let table = TDProcTable.shared
        table.reconcile()
        rows = table.listEntries().map { entry in
            let kindLabel: String
            switch entry.kind {
            case .hostExtension: kindLabel = "扩展"
            case .guestVisitor: kindLabel = "访客"
            default: kindLabel = "?"
            }
            let detailParts = [entry.bundleId, entry.containerUUID].filter { !$0.isEmpty }
            let when: String
            if entry.state == .exited, entry.exitedAt > 0 {
                when = "退出 " + Self.formatter.string(from: Date(timeIntervalSince1970: entry.exitedAt))
            } else {
                when = "登记 " + Self.formatter.string(from: Date(timeIntervalSince1970: entry.registeredAt))
            }
            return SurfaceRow(
                id: "\(entry.pid)-\(entry.kind.rawValue)",
                pid: entry.pid,
                name: entry.name.isEmpty ? "(未命名)" : entry.name,
                detail: detailParts.joined(separator: " / "),
                kindLabel: kindLabel,
                running: entry.state == .running,
                stateLabel: entry.state == .running ? "running" : "exited",
                note: entry.exitNote,
                when: when
            )
        }
    }

    private func kill(_ row: SurfaceRow) {
        guard row.running else { return }
        busyPid = row.pid
        do {
            try TDProcTable.shared.killPid(row.pid)
            statusText = "SIGKILL 已发送: pid \(row.pid)"
        } catch {
            statusText = "kill 失败: \(error.localizedDescription)"
        }
        busyPid = nil
        reload()
    }

    private func clearExited() {
        let table = TDProcTable.shared
        for row in rows where !row.running {
            try? table.removePid(row.pid)
        }
        reload()
    }

    private static let formatter: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "HH:mm:ss"
        return f
    }()
}

/// 单行: 名称 + 种类徽标 / pid 与容器详情 / 状态圆点 + kill 按钮.
private struct TDSurfaceRowView: View {
    let row: TDSurfaceView.SurfaceRow
    let busy: Bool
    let onKill: () -> Void

    var body: some View {
        HStack(alignment: .center, spacing: 12) {
            Circle()
                .fill(row.running ? Color.green : Color.gray)
                .frame(width: 8, height: 8)
            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 6) {
                    Text(row.name)
                        .font(.body)
                        .fontWeight(.semibold)
                        .lineLimit(1)
                    Text(row.kindLabel)
                        .font(.caption2)
                        .padding(.horizontal, 6)
                        .padding(.vertical, 2)
                        .background(Capsule().fill(Color(uiColor: .secondarySystemBackground)))
                }
                Text("pid \(row.pid) - \(row.stateLabel) - \(row.when)")
                    .font(.caption)
                    .foregroundColor(.secondary)
                if !row.detail.isEmpty {
                    Text(row.detail)
                        .font(.caption2)
                        .foregroundColor(.secondary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                }
                if !row.note.isEmpty {
                    Text(row.note)
                        .font(.caption2)
                        .foregroundColor(.secondary)
                        .lineLimit(2)
                }
            }
            Spacer(minLength: 8)
            if row.running {
                Button(action: onKill) {
                    if busy {
                        ProgressView()
                    } else {
                        Text("kill")
                            .font(.caption)
                            .monospaced()
                    }
                }
                .buttonStyle(.bordered)
                .disabled(busy)
            }
        }
        .padding(.vertical, 2)
    }
}
