import SwiftUI
import UIKit

// 沙盒容器 · 应用详情页（v0.3.784 重做）
//
// 用户 2026-11-08 指定参考「应用管理 / 应用信息」那套布局（PiliPlus 截图），并点名
// 三处病：①「浏览包体目录」蓝底蓝字、「重签包体」绿底绿字、「重建可写目录」灰底蓝字
// = 三个大色块堆在页中（同时违反 m32253「功能行文字不得擅自加颜色」）；②标题居中
// inline，不像「应用信息」那种左对齐大标题；③底部说明被主 App 的 TabBar 盖住一半.
//
// 改后：标题走导航栏 large（左对齐）；页内只有信息卡（左标题 / 右灰色值），
// 动作全部收进本页自己的悬浮玻璃丸底栏（图标着色、文字一律主色），
// 底栏用 safeAreaInset 挂底部 ⇒ 内容自动避让，说明不会再被盖.

struct SandboxAppDetailView: View {
    let app: SandboxApp
    /// 容器目录有变化（新建可写目录 / 删除）时回调，让列表页重扫.
    var onChange: () -> Void = {}

    @Environment(\.dismiss) private var dismiss

    @State private var showBrowser = false
    @State private var showShare = false
    @State private var showDeleteConfirm = false
    /// 已锁定应用的二次确认（与列表页同一口径：锁定只拦破坏性动作）.
    @State private var showLockedDeleteConfirm = false
    @State private var dataExists = false
    @State private var busy = false
    @State private var resigning = false
    /// 运行环境判定结果（JIT / JITLess / 不可用）. `nil` = 还没判定完.
    @State private var runtime: SandboxRuntimeSnapshot?
    /// 容器清单与激活项. 由 `reloadContainers()` 从登记重扫，不直接读 `app`：
    /// `app` 是列表页传进来的快照，本页改了容器它也还是旧的.
    @State private var containers: [SandboxContainerRef] = []
    @State private var activeContainer: String?
    /// 待删除 / 待重命名的容器（两个 alert 各自一个目标，互不干扰）.
    @State private var deleteContainerTarget: SandboxContainerRef?
    @State private var renameContainerTarget: SandboxContainerRef?
    @State private var renameText = ""

    var body: some View {
        List {
            content
        }
        .listStyle(.plain)
        // 真间距 (owner 2026-11-08 截图病点: 卡片互相贴死): plain List 的 section 间
        // 默认 0 距, 必须显式给 (iOS 17+ API, 部署目标 18.0).
        .listSectionSpacing(12)
        .scrollContentBackground(.hidden)
        .background(AppTheme.surfaceBase)
        .navigationTitle(app.displayName)
        .navigationBarTitleDisplayMode(.large)
        .safeAreaInset(edge: .bottom, spacing: 0) { detailBar }
        .toolbar { detailToolbar }
        .sheet(isPresented: $showBrowser) { browserSheet }
        .sheet(isPresented: $showShare) { ShareSheet(items: [URL(fileURLWithPath: app.appPath)]) }
        .confirmationDialog("删除 \(app.displayName) 及其全部容器？", isPresented: $showDeleteConfirm, titleVisibility: .visible) {
            Button("删除应用", role: .destructive) {
                // 锁定项多一道确认：先让这枚退场，隔一帧再抬下一枚，否则系统会吞掉后一枚.
                if app.isLocked {
                    Task { @MainActor in
                        // 400ms > 系统 dialog 退场动画（约 0.3s）：早于此抬起会被前一枚吞掉.
                        try? await Task.sleep(for: .milliseconds(400))
                        showLockedDeleteConfirm = true
                    }
                } else {
                    removeWholeApp()
                }
            }
            Button("取消", role: .cancel) {}
        } message: {
            Text("包体与全部容器一起移除，不可恢复.")
        }
        .confirmationDialog(lockedDeleteTitle, isPresented: $showLockedDeleteConfirm, titleVisibility: .visible) {
            Button("仍然删除", role: .destructive) { removeWholeApp() }
            Button("取消", role: .cancel) {}
        } message: {
            Text("删除会移除包体与全部容器，不可恢复.")
        }
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
        .overlay {
            if busy {
                AppBusyOverlay(title: "正在处理…", style: .card)
            }
        }
        .onAppear { refreshDataState() }
        .task {
            await loadRuntime()
            await reloadContainers()
        }
        .toastHost()
    }

    // MARK: - 内容分段

    /// 各段独立成属性：本仓 CI 已四次实证「视图构造 + 多层修饰」堆在同一条 body 里
    /// 会 `unable to type-check this expression in reasonable time`.
    ///
    /// 竖向间距一套数值（owner 2026-11-08 要求全页统一；横向上一轮已修好）：
    /// 卡片头行下 8 / 卡内行竖向 7 / 组小标题上 8 下 4 —— 不再混用 2/4/5/12.
    @ViewBuilder
    private var content: some View {
        identitySection
        statusSection
        storageSection
        notesSection
    }


    /// 首卡：大图标 + 名称 + Bundle ID，随后「左标题 / 右灰色值」三行（参考图范式）.
    private var identitySection: some View {
        Section {
            identityCard
        }
    }

    private var identityCard: some View {
        VStack(alignment: .leading, spacing: 0) {
            identityHead
            infoRow("Bundle ID", app.id)
            infoRow("版本", versionText)
            infoRow("包体大小", app.sizeText)
            infoRow("安装时间", installedText)
        }
        .padding(AppMetrics.cardPadding)
        .background(RoundedRectangle(cornerRadius: AppRadius.card, style: .continuous)
                    .fill(AppSurface.card))
        .rowInList
    }

    /// 运行环境：JIT 是否生效、要不要走 JITLess、有没有开发证书.
    ///
    /// 判定本身来自 `SandboxRuntimeStatus.snapshot()`（csops + systemhook 探测 + 证书盘查），
    /// 这里只负责展示 —— 不给启动按钮：容器内启动还没接（见 `notesCard`）.
    private var statusSection: some View {
        Section {
            statusCard
        }
    }

    private var statusCard: some View {
        VStack(alignment: .leading, spacing: 0) {
            statusRows
        }
        .padding(AppMetrics.cardPadding)
        .background(RoundedRectangle(cornerRadius: AppRadius.card, style: .continuous)
                    .fill(AppSurface.card))
        .rowInList
    }

    /// 首行小标题 + 模式一行 + 结论一行. 三处的字都取快照自己的字符串，不另写文案.
    @ViewBuilder
    private var statusRows: some View {
        statusHead
        infoRow("模式", runtime?.mode.label ?? "判定中")
        if let runtime {
            AppHairline()
            statusDetail(runtime.detail)
        }
    }

    /// 卡片首行的小标题（与 `notesCard` 同形）：`infoRow` 自带**前置**发丝，
    /// 没有这一行，卡片顶部会多出一条悬空的线.
    private var statusHead: some View {
        Label("运行环境", systemImage: "bolt")
            .font(AppFont.footnote)
            .foregroundStyle(.primary)
            .padding(.bottom, 8)
    }

    private func statusDetail(_ text: String) -> some View {
        Text(text)
            .font(AppFont.caption)
            .foregroundStyle(.secondary)
            .fixedSize(horizontal: false, vertical: true)
            .padding(.vertical, 7)
            .textSelection(.enabled)
    }

    /// 图标 + 名称两行. 单独抽出来让 identityCard 的 body 只剩属性引用.
    private var identityHead: some View {
        HStack(alignment: .center, spacing: 12) {
            SandboxAppIconView(bundleID: app.id, size: 64)
            VStack(alignment: .leading, spacing: 4) {
                Text(app.displayName)
                    .font(AppFont.title3)
                    .foregroundStyle(.primary)
                    .lineLimit(2)
                if let executableSubtitle {
                    Text(executableSubtitle)
                        .font(AppFont.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
            }
            Spacer(minLength: 8)
        }
        .padding(.bottom, 8)
    }

    /// 主二进制名只在**与显示名不同**时才出现：同名再写一行就是同一行字重复（真机截图病点）.
    private var executableSubtitle: String? {
        guard let executable = app.executable, executable != app.displayName else { return nil }
        return executable
    }

    /// 目录与可写家目录状态.
    private var storageSection: some View {
        Section {
            storageCard
        }
    }

    private var storageCard: some View {
        VStack(alignment: .leading, spacing: 0) {
            storageRows
        }
        .padding(AppMetrics.cardPadding)
        .background(RoundedRectangle(cornerRadius: AppRadius.card, style: .continuous)
                    .fill(AppSurface.card))
        .rowInList
    }

    /// 目录卡：包体目录 + 容器清单 + 新建入口.
    ///
    /// 多容器后「可写目录」不再是一行路径，而是一组可切换的容器（照 LCContainerView 的
    /// 每容器一页收成一行一容器）：只有一份时不摆切换器，界面与改前一样简洁.
    @ViewBuilder
    private var storageRows: some View {
        SandboxPathRow(title: "包体目录", path: app.appPath)
        AppHairline()
        containerRows
    }

    /// 容器区：没有容器只给空态 + 新建；有一份只给一行路径；多份才展开成清单.
    @ViewBuilder
    private var containerRows: some View {
        if containers.isEmpty {
            emptyContainerRow
            newContainerRow
        } else if containers.count == 1 {
            singleContainerRow
            newContainerRow
        } else {
            containerListHeader
            containerList
            newContainerRow
        }
    }

    /// 多容器清单单独一段：`ForEach` 不直接写在 `containerRows` 的 if 分支里，
    /// 免得同一处堆两种视图构造（本仓 CI 四次实证会超时）.
    private var containerList: some View {
        ForEach(containers) { container in
            containerRow(container)
        }
    }

    /// 单容器：就是原来那一行路径 + 状态徽章，不多一个控件.
    private var singleContainerRow: some View {
        VStack(alignment: .leading, spacing: 0) {
            if let container = containers.first {
                SandboxPathRow(title: "可写目录", path: containerPath(container))
            }
            AppHairline()
            dataStatusRow
        }
    }

    private var containerListHeader: some View {
        HStack(spacing: 8) {
            Text("元数据容器")
                .font(AppFont.caption)
                .foregroundStyle(.secondary)
            Spacer(minLength: 4)
            Text("\(containers.count) 个")
                .font(AppFont.caption)
                .foregroundStyle(.secondary)
        }
        .padding(.top, 8)
        .padding(.bottom, 4)
    }

    /// 一行一个容器：名字 + 目录名 + 激活徽章，右侧菜单给切换 / 重命名 / 删除.
    private func containerRow(_ container: SandboxContainerRef) -> some View {
        SandboxContainerRow(container: container,
                            isActive: container.folderName == activeContainer,
                            onSwitch: { switchContainer(container) },
                            onRename: { beginRename(container) },
                            onDelete: { deleteContainerTarget = container })
    }

    private var emptyContainerRow: some View {
        HStack(spacing: 8) {
            Text("可写目录")
                .font(AppFont.caption)
                .foregroundStyle(.secondary)
            Spacer(minLength: 4)
            SizePill(text: "未创建", tint: AppTheme.pending, level: .compact)
        }
        .padding(.vertical, 7)
    }

    /// 新建容器：真入口（引擎侧真建目录），不是占位.
    private var newContainerRow: some View {
        Button {
            AppHaptics.tap()
            createContainer()
        } label: {
            Label("新建容器", systemImage: "plus.circle")
                .font(AppFont.caption)
                .foregroundStyle(.primary)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.vertical, 7)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(busy)
        .accessibilityLabel("新建容器")
    }

    private var dataStatusRow: some View {
        HStack(spacing: 8) {
            Text("可写目录状态")
                .font(AppFont.caption)
                .foregroundStyle(.secondary)
            Spacer(minLength: 4)
            SizePill(text: dataExists ? "已就绪" : "未就绪",
                     tint: dataExists ? AppTheme.success : AppTheme.pending,
                     level: .compact)
        }
        .padding(.vertical, 7)
    }

    private func containerPath(_ container: SandboxContainerRef) -> String {
        SandboxContainerStore.containerPath(folderName: container.folderName)
    }

    /// 说明收成一行 footnote（改前是三段长文，被底栏盖掉一半）.
    private var notesSection: some View {
        Section {
            notesCard
        }
    }

    private var notesCard: some View {
        VStack(alignment: .leading, spacing: 8) {
            Label("容器管理", systemImage: "info.circle")
                .font(AppFont.footnote)
                .foregroundStyle(.primary)
            Text("本页管理包体与可写目录. 重签只遍历 .app 内的 64 位 Mach-O 就地签名，不重打包 IPA.")
                .font(AppFont.caption)
                .foregroundStyle(.secondary)
            Text("容器内启动需要未加密包并配合 JIT 或 JITLess 重签，后续版本接入.")
                .font(AppFont.caption)
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(AppMetrics.cardPadding)
        .background(RoundedRectangle(cornerRadius: AppRadius.card, style: .continuous)
                    .fill(AppSurface.card))
        .rowInList
    }

    // MARK: - 导航栏与底栏

    /// 破坏性动作与分享收进右上角菜单，页面主体只留信息.
    @ToolbarContentBuilder
    private var detailToolbar: some ToolbarContent {
        ToolbarItem(placement: .navigationBarTrailing) {
            Menu {
                Button {
                    AppHaptics.tap()
                    showShare = true
                } label: {
                    Label("分享包体", systemImage: "square.and.arrow.up")
                }
                Button(role: .destructive) {
                    AppHaptics.tap()
                    showDeleteConfirm = true
                } label: {
                    Label("删除应用", systemImage: "trash")
                }
            } label: {
                Image(systemName: "ellipsis.circle")
            }
        }
    }

    /// 本页自己的悬浮玻璃丸底栏：三个动作，图标着色、文字一律主色.
    ///
    /// 改前这里是页中三颗 TintedButtonStyle 大按钮（蓝底蓝字 / 绿底绿字 / 灰底蓝字），
    /// 用户 2026-11-08 点名「为什么要加颜色文字」，且 m32253 已定硬规则：
    /// 功能行文字不得擅自加颜色 —— 着色只给图标.
    private var detailBar: some View {
        SandboxFloatingBar {
            SandboxBarCell(title: "目录", symbol: "folder", tint: AppTheme.categoryDevice) {
                AppHaptics.tap()
                showBrowser = true
            }
            SandboxBarDivider()
            SandboxBarCell(title: "重签", symbol: "hammer", tint: AppTheme.success, disabled: resigning) {
                AppHaptics.tap()
                resignBundle()
            }
            SandboxBarDivider()
            SandboxBarCell(title: dataExists ? "重建数据" : "创建数据",
                           symbol: dataExists ? "arrow.counterclockwise" : "checkmark.seal",
                           tint: AppTheme.accent, disabled: busy) {
                AppHaptics.tap()
                if dataExists { rebuildDataHome() } else { createDataHome() }
            }
        }
    }

    // MARK: - 取值

    private var versionText: String {
        app.bundleVersion ?? "未登记"
    }

    private var installedText: String {
        guard let installedAt = app.installedAt else { return "未登记" }
        return installedAt.formatted(date: .abbreviated, time: .shortened)
    }

    private var lockedDeleteTitle: String {
        "「\(app.displayName)」已锁定. 仍要删除容器？"
    }

    // MARK: - 组件

    /// 「左标题 / 右值」一行，行间发丝分隔（参考图范式：值一律灰色右对齐，不做彩色文字）.
    private func infoRow(_ label: String, _ value: String) -> some View {
        VStack(spacing: 0) {
            AppHairline()
            HStack(alignment: .top, spacing: 8) {
                Text(label)
                    .font(AppFont.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                Spacer(minLength: 4)
                Text(value)
                    .font(AppFont.caption)
                    .foregroundStyle(.primary)
                    .lineLimit(2)
                    .multilineTextAlignment(.trailing)
                    .textSelection(.enabled)
            }
            .padding(.vertical, 7)
        }
    }

    @ViewBuilder
    private var browserSheet: some View {
        NavigationStack {
            FileBrowserView(rootPath: app.appPath, title: "包体目录")
        }
    }

    // MARK: - 容器确认框

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

    private func refreshDataState() {
        dataExists = app.hasDataHome
    }

    /// 判定放后台线程：csops / access / 证书目录各是一次系统调用，不值当占主线程.
    ///
    /// 返回值 `SandboxRuntimeSnapshot` 是 Sendable 值类型，不把任何对象搬过 actor 边界.
    private func loadRuntime() async {
        let snapshot = await Task.detached(priority: .userInitiated) {
            SandboxRuntimeStatus.snapshot()
        }.value
        runtime = snapshot
    }

    /// 从登记重扫该应用的容器清单. 扫盘放后台线程（与列表页 `reload()` 同一取向）.
    private func reloadContainers() async {
        let bundleId = app.id
        let found = await Task.detached(priority: .userInitiated) {
            SandboxContainerStore.scan().first { $0.id == bundleId }
        }.value
        containers = found?.containers ?? []
        activeContainer = found?.activeContainer
        dataExists = found?.hasDataHome ?? false
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

    /// 删单份容器：结果按真实返回上报（删不掉不许说「已删除」）.
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

    /// 建第一份容器（只有「一份都没有」时才走这里；多份的入口是 `createContainer()`）.
    private func createDataHome() {
        guard !busy else { return }
        busy = true
        Task {
            let outcome = await Task.detached(priority: .userInitiated) {
                Result {
                    guard let fresh = SandboxContainerStore.scan().first(where: { $0.id == app.id }) else {
                        throw ContainerActionError.appGone
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
                ToastCenter.shared.show("已创建可写目录", seconds: 2.6)
            case .failure(let error):
                ToastCenter.shared.show(error.localizedDescription, seconds: 4.0)
            }
        }
    }

    /// 重建**当前激活**容器的可写目录（清访客数据，容器名字留着）.
    ///
    /// 必须重扫再清：`app` 是列表页传进来的快照，本页切换过容器后它的 `dataPath`
    /// 指向的是**上一份**，照它清会清错容器.
    private func rebuildDataHome() {
        guard !busy else { return }
        busy = true
        Task {
            let outcome = await Task.detached(priority: .userInitiated) {
                Result {
                    guard let fresh = SandboxContainerStore.scan().first(where: { $0.id == app.id }) else {
                        throw ContainerActionError.appGone
                    }
                    try SandboxContainerStore.resetDataHome(for: fresh)
                    return try SandboxContainerStore.makeDataHome(for: fresh)
                }
            }.value
            busy = false
            switch outcome {
            case .success:
                AppHaptics.success()
                await reloadContainers()
                onChange()
                ToastCenter.shared.show("可写目录已重建", seconds: 2.6)
            case .failure(let error):
                ToastCenter.shared.show(error.localizedDescription, seconds: 4.0)
            }
        }
    }

    /// 整包重签. 结果按真实返回上报，签失败不许说「已重签」.
    private func resignBundle() {
        guard !resigning else { return }
        resigning = true
        Task {
            let outcome = await SandboxContainerActions.resign(app)
            resigning = false
            if outcome.ok {
                AppHaptics.success()
                LoginLogger.shared.log("[完成] 容器重签 \(app.displayName) \(outcome.text)")
            }
            ToastCenter.shared.show(outcome.text, seconds: outcome.ok ? 3.0 : 4.4)
        }
    }

    /// 删**整个 App**：包体 + 全部容器（与 `removeContainer(_:)` 删单份容器区分开）.
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
                // 删不掉必须如实上报：报「已删除」而列表里还在是欺骗.
                ToastCenter.shared.show(message, seconds: 4.0)
            }
        }
    }
}

// MARK: - 路径行

/// 目录路径一行：标题在上，等宽路径在下.
///
/// 路径**单行中间省略**（改前 `lineLimit(2)` + 中间省略，长路径会在第二行折出
/// 「...pps/Applications/Gnoix.app」这种半截断口）. 右侧复制按钮把整条路径原样写进剪贴板，
/// 长按仍可选中文本.
struct SandboxPathRow: View {
    let title: String
    let path: String

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(title)
                .font(AppFont.caption)
                .foregroundStyle(.secondary)
            HStack(spacing: 8) {
                pathText
                Spacer(minLength: 4)
                copyButton
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.vertical, 7)
    }

    private var pathText: some View {
        Text(path)
            .font(.system(.caption, design: .monospaced))
            .lineLimit(1)
            .truncationMode(.middle)
            .textSelection(.enabled)
    }

    private var copyButton: some View {
        Button {
            AppHaptics.tap()
            UIPasteboard.general.string = path
            ToastCenter.shared.show("已复制路径")
        } label: {
            Image(systemName: "doc.on.doc")
                .font(AppFont.caption)
                .foregroundStyle(AppTheme.accent)
        }
        .buttonStyle(.plain)
        .accessibilityLabel("复制路径")
    }
}

// MARK: - 容器行

/// 一份元数据容器一行：名字 + 激活徽章 + 目录名，右侧菜单给切换 / 重命名 / 删除.
///
/// 与 `SandboxPathRow` 的区别：那个是「一条路径 + 复制」，这个是「一份容器 + 三个动作」，
/// 所以不塞进同一个组件里（塞进去就要给 `SandboxPathRow` 加一堆可选参数）.
struct SandboxContainerRow: View {
    let container: SandboxContainerRef
    let isActive: Bool
    var onSwitch: () -> Void
    var onRename: () -> Void
    var onDelete: () -> Void

    var body: some View {
        HStack(alignment: .center, spacing: 8) {
            labelStack
            Spacer(minLength: 4)
            if isActive {
                SizePill(text: "使用中", tint: AppTheme.success, level: .compact)
            }
            menuButton
        }
        .padding(.vertical, 7)
    }

    /// 名字 + 目录名. 文字一律主色 / 次色，不做彩色.
    private var labelStack: some View {
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
                .textSelection(.enabled)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var menuButton: some View {
        Menu {
            if !isActive {
                Button {
                    onSwitch()
                } label: {
                    Label("设为使用中", systemImage: "checkmark.circle")
                }
            }
            Button {
                onRename()
            } label: {
                Label("重命名", systemImage: "pencil")
            }
            Button(role: .destructive) {
                onDelete()
            } label: {
                Label("删除此容器", systemImage: "trash")
            }
        } label: {
            Image(systemName: "ellipsis.circle")
                .font(AppFont.caption)
                .foregroundStyle(.secondary)
        }
        .accessibilityLabel("容器操作")
    }
}

// MARK: - 容器动作错误

/// 容器动作的失败原因（文案直接进 Toast，不许空串）.
enum ContainerActionError: LocalizedError {
    /// 扫盘已经找不到这个 App（包体被别处删了）.
    case appGone

    var errorDescription: String? {
        switch self {
        case .appGone: return "包体已经不在了，请回列表刷新."
        }
    }
}
