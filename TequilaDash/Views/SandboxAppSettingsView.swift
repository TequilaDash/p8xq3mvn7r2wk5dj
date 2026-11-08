import SwiftUI
import UIKit

// 沙盒容器 · 应用管理页 (LCAppSettingsView 的本仓同构, v0.3.793).
//
// LC 分节结构照搬: 身份 → 数据/容器 → 锁定(→隐藏子选项) → 操作.
// 数据层用本仓的 SandboxApp / SandboxContainerStore (LC 用 LCAppModel/LCAppInfo,
// 字段一一映射: bundleId/版本 ↔ 只读行; 容器清单 ↔ containers; 锁定/隐藏 ↔ setAccess).
// 旧 SandboxAppDetailView 的独有动作 (重签/浏览包体/重建数据/分享/删除) 收进「操作」节,
// 旧页面从导航退役.

/// 容器锁定的本机认证 (与列表页同一份实现, 列表页容器视图里的 handleAuth 同口径).
/// 全仓唯一声明 (SandboxContainerView 的同名 private 声明已删, 防重复符号).
@_silgen_name("TDLaunchGuestRestart")
func TDLaunchGuestRestart()

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
            identitySection
            containerSection
            networkSection
            lockSection
            actionSection
        }
        .listStyle(.plain)
        .listSectionSpacing(12)
        .scrollContentBackground(.hidden)
        .background(AppTheme.surfaceBase)
        .navigationTitle(app.displayName)
        .navigationBarTitleDisplayMode(.inline)
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

    // MARK: - 身份

    private var identitySection: some View {
        Section {
            infoRow("Bundle ID", app.id)
            infoRow("版本", app.bundleVersion ?? "未登记")
            infoRow("安装时间", installedText)
        } header: {
            Text("身份")
        }
    }

    // MARK: - 容器

    private var containerSection: some View {
        Section {
            containerRows
        } header: {
            Text("数据与容器")
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
                    .font(.system(.caption2, design: .monospaced))
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

    // MARK: - 锁定

    private var lockSection: some View {
        Section {
            Toggle(isOn: lockBinding) {
                Text("锁定 App")
            }
            if isLocked {
                Toggle(isOn: hideBinding) {
                    Text("隐藏 App")
                }
            }
        } header: {
            Text("锁定")
        } footer: {
            Text("锁定/解锁与进入都要 Face ID 或密码; 隐藏是锁定的子选项, 隐藏后搜索可找回.")
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

    // MARK: - 联网管理

    private var netBlockBinding: Binding<Bool> {
        Binding(
            get: { UserDefaults.standard.bool(forKey: "TDNetBlock-\(app.id)") },
            set: { UserDefaults.standard.set($0, forKey: "TDNetBlock-\(app.id)") }
        )
    }

    private var networkSection: some View {
        Section {
            Toggle(isOn: netBlockBinding) {
                Text("禁止联网")
            }
        } header: {
            Text("联网管理")
        } footer: {
            Text("开启后该容器应用的对外 TCP 连接在启动时被拦截 (connect 返回 EPERM). 重新启动应用后生效.")
        }
    }

    // MARK: - 操作

    private var actionSection: some View {
        Section {
            launchRow
            resignRow
            browseRow
            shareRow
            rebuildRow
            deleteRow
        } header: {
            Text("操作")
        }
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

    /// 「左标题 / 右值」一行 (LC: Bundle ID 行同形, 值一律主色右对齐).
    private func infoRow(_ label: String, _ value: String) -> some View {
        HStack(alignment: .top, spacing: 8) {
            Text(label)
                .font(AppFont.caption)
                .foregroundStyle(.secondary)
            Spacer(minLength: 4)
            Text(value)
                .font(AppFont.caption)
                .foregroundStyle(.primary)
                .lineLimit(2)
                .multilineTextAlignment(.trailing)
                .textSelection(.enabled)
        }
        .padding(.vertical, 4)
    }

    private func containerMenuButton(_ container: SandboxContainerRef) -> some View {
        containerMenu(container)
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
        let defaults = UserDefaults.standard
        defaults.set((app.appPath as NSString).lastPathComponent, forKey: "selected")
        defaults.set(uuid, forKey: "selectedContainer")
        defaults.set(app.displayName, forKey: "TDLastGuestName")
        defaults.set(app.id, forKey: "TDLastGuestBundleId")
        defaults.set(UserDefaults.standard.bool(forKey: "TDNetBlock-\(app.id)"), forKey: "TDGuestNetBlock")
        ToastCenter.shared.show("正在启动 \(app.displayName)…", seconds: 3.0)
        TDLaunchGuestRestart()
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
