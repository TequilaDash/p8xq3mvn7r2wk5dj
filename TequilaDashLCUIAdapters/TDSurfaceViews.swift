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
    @State private var showRootfsPicker = false
    @State private var rootfsBusy = false
    @State private var rootfsStatus = ""

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
            // 隐藏状态总览 (2026-11-14): 置顶, 自动检测, 零操作 —— 用户主诉求.
            TDHideStatusSection()
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
        .fileImporter(isPresented: $showRootfsPicker,
                      allowedContentTypes: [.data],
                      allowsMultipleSelection: false) { result in
            guard case let .success(urls) = result, let url = urls.first else { return }
            unpackRootfs(from: url)
        }
        .safeAreaInset(edge: .bottom) {
            // rootfs 解包是运维操作, 不是日常交互 —— 收进折叠区 (用户反馈: "还要我去操作的?").
            DisclosureGroup {
                VStack(spacing: 8) {
                    Button {
                        showRootfsPicker = true
                    } label: {
                        Label("解包 rootfs 归档 (tar → .jbroot-*)", systemImage: "shippingbox.fill")
                            .frame(maxWidth: .infinity)
                    }
                    .buttonStyle(.borderedProminent)
                    .disabled(rootfsBusy)
                    if !rootfsStatus.isEmpty {
                        Text(rootfsStatus)
                            .font(.caption)
                            .foregroundColor(.secondary)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                }
                .padding(.vertical, 4)
            } label: {
                Label("运维工具 (rootfs 解包)", systemImage: "wrench.and.screwdriver")
                    .font(.footnote)
            }
            .padding(.horizontal)
            .padding(.bottom, 8)
        }
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

    private func unpackRootfs(from url: URL) {
        rootfsBusy = true
        rootfsStatus = "解包中…"
        let src = url.startAccessingSecurityScopedResource()
        defer { if src { url.stopAccessingSecurityScopedResource() } }
        DispatchQueue.global(qos: .userInitiated).async {
            let options: TDRootfsUnpackOptions = [.resignWithHostIdentity, .symredirect]
            let result = try? TDRootfsUnpack.unpackArchive(at: url,
                                                          destinationURL: nil,
                                                          options: options)
            DispatchQueue.main.async {
                rootfsBusy = false
                if let result {
                    rootfsStatus = "完成 jbroot=\(result.jbrootURL.path) 条目=\(result.entryCount) macho=\(result.machoCount) 重签=\(result.resignedCount) 改写=\(result.symredirectedCount)"
                } else {
                    rootfsStatus = "解包失败 (详见 exploit.log)"
                }
            }
        }
    }
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

/// 隐藏状态总览 Section (TDSurfaceView 置顶): 完整面板在 TDHideStatusView.swift,
/// 这里是嵌入宿主 List 的紧凑版 —— 只显示每层一行 (图标+名+徽标), 点击展开详情.
struct TDHideStatusSection: View {
    @State private var rows: [TDHideStatusView.LayerRow] = []
    @State private var expanded: Set<String> = []

    var body: some View {
        Section {
            ForEach(rows) { row in
                compactRow(row)
            }
        } header: {
            Text("隐藏状态 (自动检测)")
        } footer: {
            Text("绿=已生效 蓝=恒开 灰=未开启 黄=待接线. 点击行展开说明与开启方法.")
        }
        .task {
            reload()
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: 2_000_000_000)
                reload()
            }
        }
    }

    private func compactRow(_ row: TDHideStatusView.LayerRow) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            HStack(spacing: 8) {
                Image(systemName: row.icon)
                    .foregroundColor(color(for: row.state))
                    .frame(width: 20)
                Text(row.title)
                    .font(.subheadline)
                Spacer()
                Text(badgeLabel(row.state))
                    .font(.caption2)
                    .padding(.horizontal, 7)
                    .padding(.vertical, 2)
                    .background(color(for: row.state).opacity(0.18))
                    .foregroundColor(color(for: row.state))
                    .clipShape(Capsule())
            }
            if expanded.contains(row.id) {
                Text(row.detail)
                    .font(.caption)
                    .foregroundColor(.secondary)
                if !row.howToEnable.isEmpty {
                    Text("开启: \(row.howToEnable)")
                        .font(.caption2)
                        .foregroundColor(.secondary)
                }
                if !row.note.isEmpty {
                    Text(row.note)
                        .font(.caption2)
                        .foregroundColor(.secondary)
                }
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

    private func reload() {
        // 与 TDHideStatusView 同一套运行时真值; 这里复制精简逻辑 (不共享 State 类).
        rows = TDHideStatusProvider.currentRows()
    }

    private func color(for state: TDHideStatusView.LayerRow.State) -> Color {
        switch state {
        case .active: return .green
        case .builtIn: return .blue
        case .off: return .gray
        case .pending: return .orange
        }
    }

    private func badgeLabel(_ state: TDHideStatusView.LayerRow.State) -> String {
        switch state {
        case .active: return "已生效"
        case .builtIn: return "恒开"
        case .off: return "未开启"
        case .pending: return "待接线"
        }
    }
}

/// 检测逻辑提供者: TDHideStatusView 与 TDHideStatusSection 共用同一份运行时真值,
/// 避免"面板两处检测逻辑漂移".
enum TDHideStatusProvider {
    static func currentRows() -> [TDHideStatusView.LayerRow] {
        var out: [TDHideStatusView.LayerRow] = []
        let vrootOn = TDVRootIsEnabled()
        let dyldTrim = TDVDyldTrimEnabled()
        let sysctlSpoof = TDVSysctlSpoofEnabled()
        let secTaskSpoof = TDVSecTaskSpoofEnabled()
        let csopsSpoof = TDVCsopsSpoofEnabled()

        out.append(.init(id: "vroot", icon: "externaldrive.connected.to.line.below",
            title: "L1 路径虚拟化 (vroot)",
            detail: "把 /usr /bin /etc 等系统路径重定向进沙盒容器私有根; 访客读系统目录看到的都是容器内副本.",
            state: vrootOn ? .active : .off,
            howToEnable: vrootOn ? "" : "对应容器 → App 设置 → TDVRoot = path/full",
            note: vrootOn ? "根: \(String(cString: TDVRootRootPath()))  模式: \(TDVRootCurrentMode() == .full ? "full(含 uid 伪 0)" : "path")" : ""))
        out.append(.init(id: "dyldTrim", icon: "list.bullet.rectangle",
            title: "L2 dyld 镜像清单裁剪",
            detail: "访客枚举已加载镜像时隐藏宿主 bundle 与 LC/ZSign/TweakLoader 注入层条目.",
            state: dyldTrim ? .active : .off,
            howToEnable: dyldTrim ? "" : "对应容器 → App 设置 → 隐藏 LiveContainer",
            note: dyldTrim ? "宿主目录前缀 + 8 特征串过滤, 整行删除" : "默认关 = 与上游 LC 行为一致"))
        out.append(.init(id: "envScrub", icon: "terminal",
            title: "L3 访客环境变量清洗",
            detail: "dlopen 访客前 unset TD_*/LC_HOME_PATH/LP_HOME_PATH, getenv 探测不到注入痕迹.",
            state: .builtIn, howToEnable: "",
            note: "扩展路径与访客路径同点执行"))
        out.append(.init(id: "sysctl", icon: "cpu",
            title: "L4 sysctl 伪值表",
            detail: "sysctlbyname 查 kern.bootargs 等键返回伪值 (bootargs 非空 = 越狱实锤).",
            state: sysctlSpoof ? .active : .pending,
            howToEnable: sysctlSpoof ? "" : "per-app sysctlSpoof 开关",
            note: "默认仅 bootargs→空 (设备无关); 机型/版本键不默认伪化, TD_SYSCTL_<NAME> 可覆盖"))
        out.append(.init(id: "secTask", icon: "key.horizontal",
            title: "L5 SecTask entitlement 隐藏",
            detail: "访客读宿主私有 entitlement (get-task-allow / com.apple.private.*) 返回 NULL.",
            state: secTaskSpoof ? .active : .pending,
            howToEnable: secTaskSpoof ? "" : "per-app secTaskSpoof (透传待接线)",
            note: "合法键恒透传, 宿主自身功能不受影响"))
        out.append(.init(id: "csops", icon: "signature",
            title: "L6 代码签名标志伪化",
            detail: "csops 查询清除 CS_GET_TASK_ALLOW (可被调试) 与 CS_DEBUGGED (调试器已附加) 位.",
            state: csopsSpoof ? .active : .pending,
            howToEnable: csopsSpoof ? "" : "per-app csopsSpoof (透传待接线)",
            note: "TD_CSOPS_KEEP_DEBUGGED=1 保留调试器位 (宿主 JIT 探测链路依赖)"))
        out.append(.init(id: "tweaksHide", icon: "eye.slash",
            title: "L7 Tweaks 目录隐藏",
            detail: "访客镜像对 */Documents/Tweaks 的访问返回 ENOENT (fail-closed).",
            state: .builtIn, howToEnable: "", note: "M37b"))
        out.append(.init(id: "uncovered", icon: "exclamationmark.triangle",
            title: "L8 尚未覆盖的检测面",
            detail: "mach task_info (TASK_DYLD_INFO 直读 dyld 镜像表, interpose 拦不住, 需 fishhook); CFPreferences 域隔离 (org.tequila.* defaults 仍可见); 静态 LC_LOAD_DYLIB 依赖树 (patched Reveil 口径, 运行时裁剪无效).",
            state: .off, howToEnable: "(第三批改造项)", note: "展开看逐项说明"))
        return out
    }
}
