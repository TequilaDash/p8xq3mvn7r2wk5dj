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

    var body: some View {
        List {
            content
        }
        .listStyle(.plain)
        .scrollContentBackground(.hidden)
        .background(AppTheme.surfaceBase)
        .navigationTitle(app.displayName)
        .navigationBarTitleDisplayMode(.large)
        .safeAreaInset(edge: .bottom, spacing: 0) { detailBar }
        .toolbar { detailToolbar }
        .sheet(isPresented: $showBrowser) { browserSheet }
        .sheet(isPresented: $showShare) { ShareSheet(items: [URL(fileURLWithPath: app.appPath)]) }
        .confirmationDialog("删除 \(app.displayName) 的容器？", isPresented: $showDeleteConfirm, titleVisibility: .visible) {
            Button("删除容器", role: .destructive) {
                // 锁定项多一道确认：先让这枚退场，隔一帧再抬下一枚，否则系统会吞掉后一枚.
                if app.isLocked {
                    Task { @MainActor in
                        // 400ms > 系统 dialog 退场动画（约 0.3s）：早于此抬起会被前一枚吞掉.
                        try? await Task.sleep(for: .milliseconds(400))
                        showLockedDeleteConfirm = true
                    }
                } else {
                    removeContainer()
                }
            }
            Button("取消", role: .cancel) {}
        } message: {
            Text("包体与可写目录一起移除，不可恢复.")
        }
        .confirmationDialog(lockedDeleteTitle, isPresented: $showLockedDeleteConfirm, titleVisibility: .visible) {
            Button("仍然删除", role: .destructive) { removeContainer() }
            Button("取消", role: .cancel) {}
        } message: {
            Text("删除会移除包体与可写目录，不可恢复.")
        }
        .overlay {
            if busy {
                AppBusyOverlay(title: "正在处理…", style: .card)
            }
        }
        .onAppear { refreshDataState() }
        .task { await loadRuntime() }
        .toastHost()
    }

    // MARK: - 内容分段

    /// 各段独立成属性：本仓 CI 已四次实证「视图构造 + 多层修饰」堆在同一条 body 里
    /// 会 `unable to type-check this expression in reasonable time`.
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
            .padding(.bottom, 4)
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
        .padding(.bottom, 12)
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

    /// 目录两行 + 可写目录状态. 没有可写目录时不给假路径，只给「未创建」徽章.
    @ViewBuilder
    private var storageRows: some View {
        SandboxPathRow(title: "包体目录", path: app.appPath)
        AppHairline()
        if let dataPath = app.dataPath {
            SandboxPathRow(title: "可写目录", path: dataPath)
            AppHairline()
            dataStatusRow
        } else {
            dataMissingRow
        }
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
        .padding(.vertical, 8)
    }

    /// `dataPath == nil` 的空态：不给「Documents/SandboxApps/... （首次启动时创建）」这种
    /// 假装成路径的句子，只给一行「未创建」徽章.
    private var dataMissingRow: some View {
        HStack(spacing: 8) {
            Text("可写目录")
                .font(AppFont.caption)
                .foregroundStyle(.secondary)
            Spacer(minLength: 4)
            SizePill(text: "未创建", tint: AppTheme.pending, level: .compact)
        }
        .padding(.vertical, 8)
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
                    Label("删除容器", systemImage: "trash")
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

    private func createDataHome() {
        guard !busy else { return }
        busy = true
        Task {
            let outcome = await Task.detached(priority: .userInitiated) {
                Result { try SandboxContainerStore.makeDataHome(for: app) }
            }.value
            busy = false
            switch outcome {
            case .success:
                AppHaptics.success()
                // dataPath 是安装期登记的，新建目录后列表要重扫才拿得到路径.
                dataExists = true
                onChange()
                ToastCenter.shared.show("已创建可写目录", seconds: 2.6)
            case .failure(let error):
                ToastCenter.shared.show(error.localizedDescription, seconds: 4.0)
            }
        }
    }

    private func rebuildDataHome() {
        guard !busy else { return }
        busy = true
        Task {
            let outcome = await Task.detached(priority: .userInitiated) {
                Result {
                    try SandboxContainerStore.resetDataHome(for: app)
                    return try SandboxContainerStore.makeDataHome(for: app)
                }
            }.value
            busy = false
            switch outcome {
            case .success:
                AppHaptics.success()
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

    private func removeContainer() {
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
                ToastCenter.shared.show("已删除 \(app.displayName) 的容器", seconds: 3.0)
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
        .padding(.vertical, 5)
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
