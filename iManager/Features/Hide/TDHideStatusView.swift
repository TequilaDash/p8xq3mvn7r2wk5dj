import SwiftUI

/// 隐藏状态面板 (2026-11-14): 自动检测隐藏体系每一层的钩子状态, 零操作.
///
/// 用户需求原话: "我要的是隐藏/面板展示钩子状态哪些层面已经做好隐藏".
/// 替代"实验性-虚拟进程"页里的手动操作感 —— 本页只读, 全自动刷新.
///
/// 数据源 = TDVRootConfig 纯 C 导出 (同 target, 桥接头已引 VRoot/TDVRootConfig.h):
/// 各层门控 getter 是唯一真值来源 —— 不读 plist 推断, 读的是**运行时已捕获**的
/// 门控状态 (TDVRootInstallIfRequested 求值后的内存值), 与访客进程实际看到的一致.
/// 注意: 本页运行在宿主进程 (LCUI framework), 门控 env 是 per-访客透传的,
/// 宿主进程里读到的是"当前宿主进程的配置捕获态" —— 对 per-app 开关显示
/// plist 键位置, 引导用户去 per-app 设置 (面板不猜).
struct TDHideStatusView: View {
    /// 层状态模型
    struct LayerRow: Identifiable {
        let id: String
        let icon: String            // SF Symbol
        let title: String           // 层名
        let detail: String          // 一句话: 这层做什么
        let state: State
        let howToEnable: String     // 关闭时的开启方法 (per-app 键名)
        let note: String            // 附加说明 (伪值表条目数等)

        enum State {
            case active             // 绿: 门控开, 钩子在工作
            case builtIn            // 蓝: 常开层 (无门控, 恒生效)
            case off                // 灰: 有实现但该访客/宿主未开
            case pending            // 黄: 实现已进仓但需对方 harness 接透传
        }
    }

    @State private var rows: [LayerRow] = []
    @State private var expanded: Set<String> = []

    var body: some View {
        List {
            Section {
                ForEach(rows) { row in
                    layerRow(row)
                }
            } header: {
                Text("隐藏层状态")
            } footer: {
                Text("绿 = 本进程钩子已生效; 蓝 = 恒开; 灰 = 需在对应沙盒容器的 per-app 设置里打开; 黄 = 实现已就绪等待接线. 本页只读, 每 2 秒自动刷新.")
            }
            Section {
                Text(coverageSummary)
                    .font(.caption)
                    .foregroundColor(.secondary)
            } header: {
                Text("覆盖面小结")
            }
        }
        .navigationTitle("隐藏状态")
        .navigationBarTitleDisplayMode(.inline)
        .task {
            reload()
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: 2_000_000_000)
                reload()
            }
        }
    }

    // MARK: - 行视图

    @ViewBuilder
    private func layerRow(_ row: LayerRow) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 8) {
                Image(systemName: row.icon)
                    .foregroundColor(color(for: row.state))
                    .frame(width: 22)
                Text(row.title)
                    .font(.body)
                Spacer()
                stateBadge(row.state)
            }
            Text(row.detail)
                .font(.caption)
                .foregroundColor(.secondary)
            if expanded.contains(row.id) {
                VStack(alignment: .leading, spacing: 2) {
                    if !row.howToEnable.isEmpty {
                        Text("开启方法: \(row.howToEnable)")
                            .font(.caption2)
                            .foregroundColor(.secondary)
                    }
                    if !row.note.isEmpty {
                        Text(row.note)
                            .font(.caption2)
                            .foregroundColor(.secondary)
                    }
                }
                .padding(.top, 2)
            }
        }
        .contentShape(Rectangle())
        .onTapGesture {
            withAnimation(.easeInOut(duration: 0.15)) {
                if expanded.contains(row.id) {
                    expanded.remove(row.id)
                } else {
                    expanded.insert(row.id)
                }
            }
        }
    }

    private func stateBadge(_ state: LayerRow.State) -> some View {
        Text(label(for: state))
            .font(.caption2)
            .padding(.horizontal, 8)
            .padding(.vertical, 3)
            .background(color(for: state).opacity(0.18))
            .foregroundColor(color(for: state))
            .clipShape(Capsule())
    }

    private func color(for state: LayerRow.State) -> Color {
        switch state {
        case .active: return .green
        case .builtIn: return .blue
        case .off: return .gray
        case .pending: return .orange
        }
    }

    private func label(for state: LayerRow.State) -> String {
        switch state {
        case .active: return "已生效"
        case .builtIn: return "恒开"
        case .off: return "未开启"
        case .pending: return "待接线"
        }
    }

    // MARK: - 检测 (运行时真值)

    private func reload() {
        rows = TDHideStatusProvider.currentRows()
    }

    private var coverageSummary: String {
        let active = rows.filter { $0.state == .active }.count
        let builtIn = rows.filter { $0.state == .builtIn }.count
        let pending = rows.filter { $0.state == .pending }.count
        let off = rows.filter { $0.state == .off }.count
        return "已生效 \(active) + 恒开 \(builtIn) / 待接线 \(pending) / 未覆盖 \(off). 待接线项 = 实现已进仓 (7f95823/691c07b), 等 launcher 透传键 (secTaskSpoof/csopsSpoof) 落地后变绿."
    }
}
