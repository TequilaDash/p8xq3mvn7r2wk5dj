import SwiftUI
import UIKit

// 沙盒容器 · 应用管理页 (PiliPlus「应用信息」同构: 卡片 + 卡外小节头).
//
// 视觉骨架照搬 PiliPlus 应用信息页:
//   卡 1 = 身份 (大图标 + 名称 + 版本, 卡内无其它行);
//   卡 2 = 概览 (存储占用 / 安装时间 / 运行环境, 有详情才给 chevron);
//   卡 3 = 锁定 (锁定/隐藏, 卡外节头);
//   卡 4 = 容器 (容器清单, 卡外节头, 原「数据与容器」整节迁入);
//   卡 5 = 操作 (启动/重签/浏览/分享/重建/删除).
// 联网管理节 (禁止联网) 已按 owner 指令整体删除: 蜂窝/断网属「更多-蜂窝隧道支持」
// 二级页 (CellularSupportView), 与应用管理无关. TDNetBlock-<bundleId> 写入面只剩
// SandboxContainerView 的启动路径 (读旧值落 TDGuestNetBlock, 行为不回归).
// 数据层不变: SandboxApp / SandboxContainerStore (LC 用 LCAppModel/LCAppInfo,
// 字段一一映射: bundleId/版本 ↔ 只读行; 容器清单 ↔ containers; 锁定/隐藏 ↔ setAccess).
// 旧 SandboxAppDetailView 的独有动作 (重签/浏览包体/重建数据/分享/删除) 收进「操作」卡.

/// 容器锁定的本机认证 (与列表页同一份实现, 列表页容器视图里的 handleAuth 同口径).
/// 全仓唯一声明 (SandboxContainerView 的同名 private 声明已删, 防重复符号).
/// - Parameter pendingMarkerPath: 「启动进行中」标记文件路径 (访客容器根下). 见 Engine/LaunchGuest.m.
@_silgen_name("TDLaunchGuestRestart")
func TDLaunchGuestRestart(_ pendingMarkerPath: NSString?)

struct SandboxAppSettingsView: View {
    let app: SandboxApp
    /// 容器/登记有变化时回调, 让列表页重扫.
    var onChange: () -> Void = {}

    @Environment(\.dismiss) private var dismiss

    @State private var containers: [SandboxContainerRef] = []
    @State private var activeContainer: String?
    @State private var isLocked = false
    @State private var isHidden = false
    @State private var dataExists = false
    @State private var busy = false
    @State private var resigning = false
    @State private var showBrowser = false
    @State private var showShare = false
    @State private var showDeleteConfirm = false
    @State private var deleteContainerTarget: SandboxContainerRef?
    @State private var renameContainerTarget: SandboxContainerRef?
    @State private var renameText = ""

    var body: some View {
        List {
            identityCard
            overviewCard
            lockCard
            containerCard
            actionCard
        }
        .listStyle(.plain)
        .listSectionSpacing(12)
        .scrollContentBackground(.hidden)
        .background(AppTheme.surfaceBase)
        .navigationTitle(app.displayName)
        .navigationBarTitleDisplayMode(.large)
        .sheet(isPresented: $showBrowser) { browserSheet }
        .sheet(isPresented: $showShare) { ShareSheet(items: [URL(fileURLWithPath: app.appPath)]) }
        .confirmationDialog(deleteContainerTitle, isPresented: deleteContainerBinding, titleVisibility: .visible) {
            Button("删除", role: .destructive) {
                if let target = deleteContainerTarget { removeContainer(target) }
            }
            Button("取消", role: .cancel) { deleteContainerTarget = nil }
        } message: {
            Text("只删这一份可写目录，包体与其它容器不动.")
        }
        .alert("重命名容器", isPresented: renameContainerBinding) {
            TextField("容器名称", text: $renameText)
            Button("保存") { commitRename() }
            Button("取消", role: .cancel) { renameContainerTarget = nil }
        } message: {
            Text("只改显示名，目录名不动.")
        }
        .confirmationDialog("删除 \(app.displayName) 及其全部容器？", isPresented: $showDeleteConfirm, titleVisibility: .visible) {
            Button("删除应用", role: .destructive) { removeWholeApp() }
            Button("取消", role: .cancel) {}
        } message: {
            Text("包体与全部容器一起移除，不可恢复.")
        }
        .overlay {
            if busy { AppBusyOverlay(title: "正在处理…", style: .card) }
        }
        .onAppear { refreshState() }
        .toastHost()
    }

    // MARK: - 身份 (卡 1: 图标 + 名称 + 版本)

    private var identityCard: some View {
        Section {
            HStack(spacing: 14) {
                SandboxAppIconView(bundleID: app.id, size: 64)
                VStack(alignment: .leading, spacing: 4) {
                    Text(app.displayName)
                        .font(AppFont.headline)
                        .foregroundStyle(.primary)
                        .lineLimit(2)
                    if let version = app.bundleVersion {
                        Text("版本：\(version)")
                            .font(AppFont.caption)
                            .foregroundStyle(.secondary)
                    }
                }
            }
            .padding(.vertical, 6)
        }
    }

    // MARK: - 概览 (卡 2: 标签/值行, 有详情才给 chevron)

    private var overviewCard: some View {
        Section {
            infoRow(label: "存储占用", value: app.sizeText)
            infoRow(label: "安装时间", value: installedText)
            infoRow(label: "Bundle ID", value: app.id)
        }
    }

    // MARK: - 锁定 (卡 3, 卡外节头)

    private var lockCard: some View {
        Section {
            lockRows
        } header: {
            Text("权限相关")
        } footer: {
            Text("锁定/解锁与进入都要 Face ID 或密码; 隐藏是锁定的子选项, 隐藏后搜索可找回.")
        }
    }

    @ViewBuilder
    private var lockRows: some View {
        Toggle(isOn: lockBinding) {
            Text("锁定 App")
        }
        if isLocked {
            Toggle(isOn: hideBinding) {
                Text("隐藏 App")
            }
        }
    }

    /// 锁定开关: 走与本仓 LCAppSettings 同口径的认证 + setAccess (隐藏⇒锁定由引擎侧维持).
    private var lockBinding: Binding<Bool> {
        Binding(
            get: { isLocked },
            set: { newValue in toggleLock(app, to: newValue) }
        )
    }

    private var hideBinding: Binding<Bool> {
        Binding(
            get: { isHidden },
            set: { newValue in toggleHide(app, to: newValue) }
        )
    }

    // MARK: - 容器 (卡 4, 卡外节头; 原「数据与容器」整节迁入)

    private var containerCard: some View {
        Section {
            containerRows
        } header: {
            Text("容器管理")
        } footer: {
            Text("访客的家目录按激活容器隔离; 切换后 Launch 即用新容器.")
        }
    }

    @ViewBuilder
    private var containerRows: some View {
        if containers.isEmpty {
            emptyContainerRow
            newContainerRow
        } else {
            ForEach(containers) { container in
                containerRow(container)
            }
            newContainerRow
        }
    }

    private func containerRow(_ container: SandboxContainerRef) -> some View {
        HStack(spacing: 8) {
            VStack(alignment: .leading, spacing: 2) {
                Text(container.name)
                    .font(AppFont.caption)
                    .foregroundStyle(.primary)
                    .lineLimit(1)
                Text(container.folderName)
                    .font(AppFont.numberSmall)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }
            Spacer(minLength: 4)
            if container.folderName == activeContainer {
                SizePill(text: "使用中", tint: AppTheme.success, level: .compact)
            }
            containerMenu(container)
        }
        .padding(.vertical, 4)
        .contentShape(Rectangle())
        .onTapGesture { switchContainer(container) }
    }

    private func containerMenu(_ container: SandboxContainerRef) -> some View {
        Menu {
            if container.folderName != activeContainer {
                Button { switchContainer(container) } label: { Label("设为使用中", systemImage: "checkmark.circle") }
            }
            Button { beginRename(container) } label: { Label("重命名", systemImage: "pencil") }
            Button(role: .destructive) { deleteContainerTarget = container } label: { Label("删除此容器", systemImage: "trash") }
        } label: {
            Image(systemName: "ellipsis.circle")
                .font(AppFont.caption)
                .foregroundStyle(.secondary)
        }
        .accessibilityLabel("容器操作")
    }

    private var emptyContainerRow: some View {
        HStack(spacing: 8) {
            Text("可写目录")
                .font(AppFont.caption)
                .foregroundStyle(.secondary)
            Spacer(minLength: 4)
            SizePill(text: "未创建", tint: AppTheme.pending, level: .compact)
        }
        .padding(.vertical, 4)
    }

    /// 新建容器: 真入口 (引擎侧真建目录), 不是占位.
    private var newContainerRow: some View {
        Button {
            AppHaptics.tap()
            createContainer()
        } label: {
            Label("新建容器", systemImage: "plus.circle")
                .font(AppFont.caption)
                .foregroundStyle(.primary)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.vertical, 4)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(busy)
    }

    // MARK: - 操作 (卡 5, 卡外节头; 底部三枚动作 = 文件里既有的语义, 不新增)

    private var actionCard: some View {
        Section {
            actionRows
        } header: {
            Text("操作")
        } footer: {
            Text("启动 = 激活容器重签后进访客; 重建/新建容器都在容器管理节.")
        }
    }

    @ViewBuilder
    private var actionRows: some View {
        launchRow
        resignRow
        browseRow
        shareRow
        rebuildRow
        deleteRow
    }

    private var launchRow: some View {
        Button {
            AppHaptics.tap()
            launchGuest()
        } label: {
            Label("启动", systemImage: "play.fill")
                .frame(maxWidth: .infinity, alignment: .leading)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(busy || containers.isEmpty)
    }

    private var resignRow: some View {
        Button {
            AppHaptics.tap()
            resignBundle()
        } label: {
            Label(resigning ? "正在重签…" : "重签包体", systemImage: "hammer")
                .frame(maxWidth: .infinity, alignment: .leading)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(resigning)
    }

    private var browseRow: some View {
        Button {
            AppHaptics.tap()
            showBrowser = true
        } label: {
            Label("浏览包体目录", systemImage: "folder")
                .frame(maxWidth: .infinity, alignment: .leading)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    private var shareRow: some View {
        Button {
            AppHaptics.tap()
            showShare = true
        } label: {
            Label("分享包体", systemImage: "square.and.arrow.up")
                .frame(maxWidth: .infinity, alignment: .leading)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    private var rebuildRow: some View {
        Button {
            AppHaptics.tap()
            rebuildDataHome()
        } label: {
            Label(dataExists ? "重建可写目录" : "创建可写目录", systemImage: "arrow.counterclockwise")
                .frame(maxWidth: .infinity, alignment: .leading)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(busy)
    }

    private var deleteRow: some View {
        Button(role: .destructive) {
            AppHaptics.tap()
            showDeleteConfirm = true
        } label: {
            Label("删除应用", systemImage: "trash")
                .frame(maxWidth: .infinity, alignment: .leading)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    // MARK: - 组件

    /// 「左标签 / 右值」一行 (PiliPlus 概览卡同形: 值一律次要色右对齐).
    private func infoRow(label: String, value: String) -> some View {
        HStack(alignment: .top, spacing: 8) {
            Text(label)
                .font(AppFont.caption)
                .foregroundStyle(.secondary)
            Spacer(minLength: 4)
            Text(value)
                .font(AppFont.caption)
                .foregroundStyle(.secondary)
                .lineLimit(2)
                .multilineTextAlignment(.trailing)
                .textSelection(.enabled)
        }
        .padding(.vertical, 4)
    }

    @ViewBuilder
    private var browserSheet: some View {
        NavigationStack {
            FileBrowserView(rootPath: app.appPath, title: "包体目录")
        }
    }

    // MARK: - 取值

    private var installedText: String {
        guard let installedAt = app.installedAt else { return "未登记" }
        return installedAt.formatted(date: .abbreviated, time: .shortened)
    }

    private var deleteContainerTitle: String {
        "删除容器「\(deleteContainerTarget?.name ?? "")」？"
    }

    private var deleteContainerBinding: Binding<Bool> {
        Binding(get: { deleteContainerTarget != nil },
                set: { if !$0 { deleteContainerTarget = nil } })
    }

    private var renameContainerBinding: Binding<Bool> {
        Binding(get: { renameContainerTarget != nil },
                set: { if !$0 { renameContainerTarget = nil } })
    }

    // MARK: - 行为

    private func refreshState() {
        dataExists = app.hasDataHome
        isLocked = app.isLocked
        isHidden = app.isHidden
        Task { await reloadContainers() }
    }

    private func reloadContainers() async {
        let bundleId = app.id
        let found = await Task.detached(priority: .userInitiated) {
            SandboxContainerStore.scan().first { $0.id == bundleId }
        }.value
        containers = found?.containers ?? []
        activeContainer = found?.activeContainer
        isLocked = found?.isLocked ?? false
        isHidden = found?.isHidden ?? false
        dataExists = found?.hasDataHome ?? false
    }

    /// LC 主路启动: 无容器**自动建容器** (LC 首启同款), 有容器直接重启进访客.
    private func launchGuest() {
        guard !busy else { return }
        if activeContainer == nil {
            busy = true
            Task {
                await Task.detached(priority: .userInitiated) {
                    if let fresh = SandboxContainerStore.scan().first(where: { $0.id == app.id }) {
                        try? SandboxContainerStore.makeDataHome(for: fresh)
                    }
                }.value
                await reloadContainers()
                busy = false
                launchGuest()
            }
            return
        }
        guard let uuid = activeContainer else { return }
        AppHaptics.tap()
        busy = true
        ToastCenter.shared.show("正在为 \(app.displayName) 重签…", seconds: 8.0)
        Task {
            let outcome = await Task.detached(priority: .userInitiated) {
                Result { try SandboxResigner.resign(app, useMainIdentifier: true) }
            }.value
            busy = false
            switch outcome {
            case .success:
                let defaults = UserDefaults.standard
                defaults.set((app.appPath as NSString).lastPathComponent, forKey: "selected")
                defaults.set(uuid, forKey: "selectedContainer")
                defaults.set(app.displayName, forKey: "TDLastGuestName")
                defaults.set(app.id, forKey: "TDLastGuestBundleId")
                defaults.set(false, forKey: "TDGuestNetBlock")
                ToastCenter.shared.show("正在启动 \(app.displayName)…", seconds: 3.0)
                // 标记文件落在访客容器根 (与 LCBootstrap 的 newHomePath 同处), 供下次启动
                // 判定上次是否崩在启动阶段.
                let markerPath = app.dataPath.map {
                    ($0 as NSString).appendingPathComponent(".td_guest_launch_pending")
                }
                TDLaunchGuestRestart(markerPath as NSString?)
            case .failure(let error):
                ToastCenter.shared.show("重签失败: \(error.localizedDescription)", seconds: 6.0)
            }
        }
    }

    /// 认证结果统一落地 (与列表页 handleAuth 同口径).
    @discardableResult
    private func handleAuth(_ outcome: SandboxAccessAuth.Outcome) -> Bool {
        switch outcome {
        case .success:
            return true
        case .failed:
            ToastCenter.shared.show("验证未通过", seconds: 2.6)
            return false
        case .unavailable:
            ToastCenter.shared.show("此设备未设置锁屏密码，无法验证", seconds: 3.0)
            return false
        }
    }

    private func toggleLock(_ app: SandboxApp, to newValue: Bool) {
        Task {
            let verb = newValue ? "锁定" : "解除锁定"
            let outcome = await SandboxAccessAuth.authenticate(reason: "验证以\(verb)「\(app.displayName)」")
            if handleAuth(outcome) {
                await applyAccess(locked: newValue, hidden: isHidden && newValue)
            }
        }
    }

    private func toggleHide(_ app: SandboxApp, to newValue: Bool) {
        Task {
            let outcome = await SandboxAccessAuth.authenticate(reason: "验证以更改「\(app.displayName)」的隐藏状态")
            if handleAuth(outcome) {
                await applyAccess(locked: true, hidden: newValue)
            }
        }
    }

    /// 落登记 + 重扫 (隐藏⇒锁定由引擎侧 setAccess 维持).
    private func applyAccess(locked: Bool, hidden: Bool) async {
        let snapshot = app
        await Task.detached(priority: .userInitiated) {
            SandboxContainerStore.setAccess(for: snapshot, locked: locked, hidden: hidden)
        }.value
        await reloadContainers()
        onChange()
    }

    private func switchContainer(_ container: SandboxContainerRef) {
        guard container.folderName != activeContainer else { return }
        let bundleId = app.id
        let folderName = container.folderName
        AppHaptics.tap()
        Task {
            await Task.detached(priority: .userInitiated) {
                guard let fresh = SandboxContainerStore.scan().first(where: { $0.id == bundleId }) else { return }
                SandboxContainerStore.setActiveContainer(for: fresh, folderName: folderName)
            }.value
            await reloadContainers()
            onChange()
        }
    }

    private func createContainer() {
        guard !busy else { return }
        busy = true
        Task {
            let outcome = await Task.detached(priority: .userInitiated) {
                Result {
                    guard let fresh = SandboxContainerStore.scan().first(where: { $0.id == app.id }) else {
                        throw ContainerActionError.appGone
                    }
                    return try SandboxContainerStore.createDataContainer(for: fresh)
                }
            }.value
            busy = false
            switch outcome {
            case .success(let container):
                AppHaptics.success()
                await reloadContainers()
                onChange()
                ToastCenter.shared.show("已新建容器「\(container.name)」", seconds: 2.8)
            case .failure(let error):
                ToastCenter.shared.show(error.localizedDescription, seconds: 4.0)
            }
        }
    }

    private func beginRename(_ container: SandboxContainerRef) {
        renameText = container.name
        renameContainerTarget = container
    }

    private func commitRename() {
        guard let target = renameContainerTarget else { return }
        let newName = renameText
        renameContainerTarget = nil
        Task {
            await Task.detached(priority: .userInitiated) {
                guard let fresh = SandboxContainerStore.scan().first(where: { $0.id == app.id }) else { return }
                SandboxContainerStore.renameDataContainer(for: fresh,
                                                          folderName: target.folderName,
                                                          to: newName)
            }.value
            await reloadContainers()
            onChange()
        }
    }

    private func removeContainer(_ container: SandboxContainerRef) {
        deleteContainerTarget = nil
        Task {
            let result = await Task.detached(priority: .userInitiated) {
                guard let fresh = SandboxContainerStore.scan().first(where: { $0.id == app.id }) else {
                    return SandboxContainerStore.RemoveResult.notFound
                }
                return SandboxContainerStore.deleteDataContainer(for: fresh, folderName: container.folderName)
            }.value
            await reloadContainers()
            onChange()
            switch result {
            case .removed:
                AppHaptics.success()
                ToastCenter.shared.show("已删除容器「\(container.name)」", seconds: 2.8)
            case .notFound:
                ToastCenter.shared.show("容器目录已经不在了", seconds: 2.6)
            case .failed(let message):
                ToastCenter.shared.show("删除失败：\(message)", seconds: 4.0)
            }
        }
    }

    private func rebuildDataHome() {
        guard !busy else { return }
        busy = true
        Task {
            let outcome = await Task.detached(priority: .userInitiated) {
                Result {
                    guard let fresh = SandboxContainerStore.scan().first(where: { $0.id == app.id }) else {
                        throw ContainerActionError.appGone
                    }
                    if dataExists {
                        try SandboxContainerStore.resetDataHome(for: fresh)
                    }
                    return try SandboxContainerStore.makeDataHome(for: fresh)
                }
            }.value
            busy = false
            switch outcome {
            case .success:
                AppHaptics.success()
                await reloadContainers()
                onChange()
                ToastCenter.shared.show(dataExists ? "可写目录已重建" : "已创建可写目录", seconds: 2.6)
            case .failure(let error):
                ToastCenter.shared.show(error.localizedDescription, seconds: 4.0)
            }
        }
    }

    private func resignBundle() {
        guard !resigning else { return }
        resigning = true
        Task {
            let outcome = await SandboxContainerActions.resign(app)
            resigning = false
            if outcome.ok { AppHaptics.success() }
            ToastCenter.shared.show(outcome.text, seconds: outcome.ok ? 3.0 : 4.4)
        }
    }

    private func removeWholeApp() {
        busy = true
        Task {
            let result = await SandboxContainerActions.remove(app)
            busy = false
            switch result {
            case .removed:
                AppHaptics.success()
                SandboxIconLoader.shared.forget(app.id)
                onChange()
                dismiss()
                ToastCenter.shared.show("已删除 \(app.displayName)", seconds: 3.0)
            case .notFound:
                onChange()
                dismiss()
                ToastCenter.shared.show("目录已不存在，登记已清理", seconds: 3.0)
            case .failed(let message):
                ToastCenter.shared.show(message, seconds: 4.0)
            }
        }
    }
}
