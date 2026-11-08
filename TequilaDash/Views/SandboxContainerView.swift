import SwiftUI
import UIKit
import UniformTypeIdentifiers

// 沙盒容器 · 列表页（v0.3.784 重做）
//
// 用户原话（2026-11-08）：「UI 界面很诡异和别扭，界面也很丑」「这个界面底栏自己独立一个，
// 不要用默认界面的底栏了」，并指定参考「应用管理 / 应用信息」那套布局.
//
// 改前的病（真机截图实测）：
// 1. 底部还是主 App 的 TabBar（主页/更多）⇒ 入口从 NavigationLink 改成 fullScreenCover，
//    由 SandboxHostView 自带一条导航栈（与 RootView:75-80 承载模块同一手段）.
// 2. hero 三胶囊 + 「容器应用/共 N 个」+ 两行说明把一页拉碎 ⇒ 全删，
//    标题交给导航栏 large（左对齐大标题，与参考图一致），页内只剩网格.
// 3. 网格里只有一格却占满左半 + 格子右边孤零一个 chevron.right ⇒ 根因是
//    NavigationLink 在 List 行内被系统注入 disclosure indicator，改 Button + 
//    navigationDestination(item:) 后系统不再插箭头；格子同时去掉卡片底，
//    只留图标 + 两行文字（LCGridLayout 的纯图标网格语言）.
// 4. 底部操作改本页自己的悬浮玻璃丸（导入 / 刷新 / 回主页），走 safeAreaInset，
//    内容自动避让，不再出现「说明被底栏盖住一半」.
//
// 目录口径不变：Documents/SandboxApps/Applications/<app>.app 放包体，
// Documents/SandboxApps/Data/Application/<UUID> 放可写家目录（HOME / CFFIXED_USER_HOME）.

/// 容器应用图标缓存：从 Caches/SandboxContainerIcons/<bundleId>.png 读一次就常驻.
///
/// 与 JITAppIconLoader 同一诉求（网格里几十格同时解码），但来源是本机文件，
/// 因此不需要异步队列，读到了就塞进内存缓存.
final class SandboxIconLoader: @unchecked Sendable {
    static let shared = SandboxIconLoader()

    private let lock = NSLock()
    private var cache: [String: UIImage] = [:]

    /// 已有缓存直接返回（主线程安全：只读字典，命中即返回不可变 UIImage）.
    func cached(for bundleId: String) -> UIImage? {
        lock.lock()
        defer { lock.unlock() }
        return cache[bundleId]
    }

    /// 读磁盘并缓存（放后台线程调用）. 读不到不写负缓存：图标是可再生资源，
    /// 用户重新导入或下次刷新就可能有了，缓存 nil 会让它永远显示占位图.
    func load(for bundleId: String) -> UIImage? {
        if let hit = cached(for: bundleId) { return hit }
        let url = SandboxContainerStore.iconFileURL(bundleId: bundleId)
        guard let data = try? Data(contentsOf: url), let image = UIImage(data: data) else { return nil }
        lock.lock()
        cache[bundleId] = image
        lock.unlock()
        return image
    }

    func forget(_ bundleId: String) {
        lock.lock()
        cache.removeValue(forKey: bundleId)
        lock.unlock()
    }
}

/// 容器应用图标（无图标时回落 SF Symbol 虚线方块，与 JITAppIconView 同形）.
struct SandboxAppIconView: View {
    let bundleID: String
    var size: CGFloat = 60

    @State private var icon: UIImage?

    var body: some View {
        Group {
            if let icon {
                Image(uiImage: icon)
                    .resizable()
            } else {
                Image(systemName: "app.dashed")
                    .resizable()
                    .aspectRatio(contentMode: .fit)
                    .foregroundStyle(.tertiary)
                    .padding(size * 0.18)
            }
        }
        .frame(width: size, height: size)
        // 连续圆角：LCGridLayout 实测比例 0.2237，本仓 AppIcon 口径 8/36 ≈ 0.2222，取本仓值.
        .background(Color(.secondarySystemBackground))
        .clipShape(RoundedRectangle(cornerRadius: size * (8.0 / 36.0), style: .continuous))
        .task(id: bundleID) {
            guard icon == nil else { return }
            let loaded = await Task.detached(priority: .userInitiated, operation: {
                SandboxIconLoader.shared.load(for: bundleID)
            }).value
            if let loaded { icon = loaded }
        }
    }
}

/// 沙盒容器列表页：左对齐大标题 + 纯图标网格 + 本页自己的悬浮底栏.
struct SandboxContainerView: View {
    @Environment(\.dismiss) private var dismiss

    @State private var apps: [SandboxApp] = []
    @State private var isLoading = false
    @State private var isImporting = false
    @State private var searchText = ""
    @State private var showImporter = false
    @State private var deleteTarget: SandboxApp?
    /// 详情走 `navigationDestination(item:)` 而不是行内 NavigationLink：
    /// 后者在 List 里会被系统注入一个 disclosure 箭头，孤零零挂在格子右边（真机病点 3）.
    @State private var selectedApp: SandboxApp?

    /// 搜索框常驻（.always）—— 本页容器是 List，系统会把搜索框计入内容安全区，
    /// swift_searchbar_guard S1 因此放行；缩卡由 .avoidSearchZoom() 压制（HARD-RULES 30）.
    private var filteredApps: [SandboxApp] {
        let query = searchText.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !query.isEmpty else { return apps }
        return apps.filter {
            $0.displayName.lowercased().contains(query) || $0.id.lowercased().contains(query)
        }
    }

    /// 分块的**下标起点**（每 24 个一节）.
    ///
    /// 与 LaunchAppsView 同一诉求：整网格塞进一个 List 行时 LazyVGrid 会被全量物化，
    /// 进场瞬间几十格齐发 `.task` 会卡顿（2026-11-01 用户报告），所以照样分节.
    /// 但**不在 ForEach 里现算** `stride(from:to:by:)` + `min` + 区间下标：CI 两次实证
    /// （99f27c7 → :149:37、2140ad9 → :168:81）`unable to type-check this expression in
    /// reasonable time` —— 切片交给 `chunk(at:)`，网格交给独立子视图 `SandboxAppGridRow`，
    /// 三处各自单独过类型检查.
    private var chunkStarts: [Int] {
        var starts: [Int] = []
        var index = 0
        let total = filteredApps.count
        while index < total {
            starts.append(index)
            index += 24
        }
        return starts
    }

    private func chunk(at start: Int) -> [SandboxApp] {
        let list = filteredApps
        let end = Swift.min(start + 24, list.count)
        return Array(list[start..<end])
    }

    var body: some View {
        List {
            content
        }
        .listStyle(.plain)
        .scrollContentBackground(.hidden)
        .background(AppTheme.surfaceBase)
        .navigationTitle("沙盒容器")
        .navigationBarTitleDisplayMode(.large)
        .searchable(text: $searchText, placement: .navigationBarDrawer(displayMode: .always), prompt: "搜索应用或 Bundle ID")
        .avoidSearchZoom()
        .safeAreaInset(edge: .bottom, spacing: 0) { listBar }
        .toolbar { listToolbar }
        .navigationDestination(item: $selectedApp) { app in
            SandboxAppDetailView(app: app, onChange: { Task { await reload() } })
        }
        .documentPicker(isPresented: $showImporter, allowedTypes: [UTType(filenameExtension: "ipa") ?? .data]) { urls in
            for url in urls { importOne(url) }
        }
        .confirmationDialog(deletePromptText, isPresented: deleteDialogBinding, titleVisibility: .visible) {
            Button("删除容器", role: .destructive) {
                if let target = deleteTarget { remove(target) }
            }
            Button("取消", role: .cancel) {}
        } message: {
            Text(deletePromptText)
        }
        .overlay {
            if isImporting {
                AppBusyOverlay(title: "正在导入…", style: .card)
            }
        }
        .onAppear {
            if apps.isEmpty {
                Task { await reload() }
            }
        }
        .toastHost()
    }

    // MARK: - 内容分段

    /// 三段各自独立：本仓 CI 已四次实证「视图构造 + 多层修饰」堆在同一条 body 里
    /// 会 `unable to type-check this expression in reasonable time`（99f27c7 :149、8aedc22 :136）.
    @ViewBuilder
    private var content: some View {
        stateSection
        gridSection
    }

    @ViewBuilder
    private var stateSection: some View {
        if isLoading && apps.isEmpty {
            loadingRow
        } else if apps.isEmpty {
            emptyRow
        } else if filteredApps.isEmpty {
            noMatchRow
        }
    }

    private var loadingRow: some View {
        AppLoadingRow(title: "正在读取容器目录…", level: .page)
            .rowInList
    }

    private var emptyRow: some View {
        AppStateSection(state: .empty("还没有容器应用",
                                   message: "点下方「导入」选择一个未加密的 IPA. 加密包（App Store 直接下载的那种）装不进来.",
                                   icon: "square.stack.3d.up"))
            .rowInList
    }

    private var noMatchRow: some View {
        AppStateSection(state: .empty("没有匹配的应用", message: "换个关键词试试.", icon: "magnifyingglass"))
            .rowInList
    }

    @ViewBuilder
    private var gridSection: some View {
        if !apps.isEmpty && !filteredApps.isEmpty {
            Section {
                gridHeader
                gridRows
            }
        }
    }

    private var gridHeader: some View {
        AppSectionHeader("容器应用", subtitle: "\(filteredApps.count) 个", symbol: "square.grid.3x3",
                         tint: AppModule.store.tint)
            .rowInList
    }

    private var gridRows: some View {
        ForEach(chunkStarts, id: \.self) { start in
            gridRow(at: start)
        }
    }

    private func gridRow(at start: Int) -> some View {
        SandboxAppGridRow(chunk: chunk(at: start),
                          onSelect: { app in selectedApp = app },
                          onDelete: { app in deleteTarget = app },
                          onDetailChange: { Task { await reload() } })
            .rowInList
    }

    // MARK: - 导航栏与底栏

    /// 导航栏只留一个「导入」入口，其余动作全在底部自己的悬浮栏里.
    @ToolbarContentBuilder
    private var listToolbar: some ToolbarContent {
        ToolbarItem(placement: .navigationBarTrailing) {
            Button {
                AppHaptics.tap()
                showImporter = true
            } label: {
                Image(systemName: "square.and.arrow.down")
            }
        }
    }

    /// 本页独立的悬浮玻璃丸底栏（用户点名不要主 App 的 TabBar）.
    private var listBar: some View {
        SandboxFloatingBar {
            SandboxBarCell(title: "导入", symbol: "square.and.arrow.down",
                           tint: AppModule.store.tint, disabled: isImporting) {
                AppHaptics.tap()
                showImporter = true
            }
            SandboxBarDivider()
            SandboxBarCell(title: "刷新", symbol: "arrow.clockwise", tint: AppTheme.accent) {
                AppHaptics.tap()
                Task { await reload() }
            }
            SandboxBarDivider()
            SandboxBarCell(title: "回主页", symbol: "house", tint: AppTheme.accent) {
                AppHaptics.tap()
                dismiss()
            }
        }
    }

    // MARK: - 删除确认

    private var deletePromptText: String {
        "删除 \(deleteTarget?.displayName ?? "") 的容器？包体与可写目录一起移除，不可恢复."
    }

    private var deleteDialogBinding: Binding<Bool> {
        Binding(get: { deleteTarget != nil },
              set: { if !$0 { deleteTarget = nil } })
    }

    // MARK: - 行为

    /// 扫盘放后台线程：容器目录可能上百个，主线程扫会卡住进场动画.
    private func reload() async {
        isLoading = true
        let found = await Task.detached(priority: .userInitiated) {
            SandboxContainerStore.scan()
        }.value
        apps = found
        isLoading = false
    }

    /// 删除结果按真实返回上报. 删不掉不许说「已删除」.
    private func remove(_ app: SandboxApp) {
        deleteTarget = nil
        Task {
            let result = await Task.detached(priority: .userInitiated) {
                SandboxContainerStore.remove(app)
            }.value
            switch result {
            case .removed:
                AppHaptics.success()
                SandboxIconLoader.shared.forget(app.id)
                await reload()
                ToastCenter.shared.show("已删除 \(app.displayName)", seconds: 3.0)
            case .notFound:
                await reload()
                ToastCenter.shared.show("容器已经不在了", seconds: 2.6)
            case .failed(let message):
                ToastCenter.shared.show("删除失败：\(message)", seconds: 4.0)
            }
        }
    }

    /// 导入 IPA：解包 + 加密判定 + 覆盖安装全在引擎侧，这里只负责遮罩与结果播报.
    ///
    /// 不传 `progress:` —— 引擎侧回调是 `@Sendable (String) -> Void`，从 View 结构体里
    /// 传闭包会跨 actor 捕获 self，`SWIFT_STRICT_CONCURRENCY: complete` 下不合法（v0.3.781 已踩过）.
    private func importOne(_ url: URL) {
        guard !isImporting else { return }
        isImporting = true
        Task {
            let outcome = await Task.detached(priority: .userInitiated) {
                Result { try SandboxImportService.importIPA(at: url) }
            }.value
            isImporting = false
            switch outcome {
            case .success(let result):
                AppHaptics.success()
                await reload()
                let head = result.replaced
                    ? "已覆盖安装 \(result.app.displayName)"
                    : "已导入 \(result.app.displayName)"
                let text = result.warning.map { head + "；" + $0 } ?? head
                ToastCenter.shared.show(text, seconds: 3.4)
            case .failure(let error):
                ToastCenter.shared.show(error.localizedDescription, seconds: 4.0)
            }
        }
    }
}

// MARK: - 网格子视图

/// 一屏网格（最多 24 格）.
///
/// 独立成类型只为把类型检查面切开：CI 两次实证 `AppAdaptiveGrid(items: chunk) { … }`
/// 与外层 List / ForEach / 修饰符写在同一个 `body` 里会
/// `unable to type-check this expression in reasonable time`（99f27c7 → :149:37、
/// 2140ad9 → :168:81）. 放进自己的 `body` 后，外层只剩一个 `SandboxAppGridRow(...)`
/// 调用，推断深度立刻回落.
struct SandboxAppGridRow: View {
    let chunk: [SandboxApp]
    var onSelect: (SandboxApp) -> Void = { _ in }
    var onDelete: (SandboxApp) -> Void = { _ in }
    var onDetailChange: () -> Void = {}

    var body: some View {
        AppAdaptiveGrid(items: chunk, minimum: 92, spacing: 12) { app in
            SandboxAppTile(app: app, onSelect: onSelect, onDelete: onDelete,
                           onDetailChange: onDetailChange)
        }
    }
}

/// 网格里的一格：图标 + 名称 + 版本. 点击进详情，长按删除.
///
/// 用 `Button` + 容器级 `navigationDestination(item:)` 而不是行内 `NavigationLink`：
/// 后者会让系统在行右侧注入一个 disclosure 箭头，孤零零挂在格子右边（真机病点 3）.
/// 同一条反馈还嫌「格子有卡片底、只有一格时占满左半很怪」—— 因此去掉卡片底，
/// 只留图标 + 两行文字（LCGridLayout 的纯图标网格语言），点击态交给 appPressable.
struct SandboxAppTile: View {
    let app: SandboxApp
    var onSelect: (SandboxApp) -> Void
    var onDelete: (SandboxApp) -> Void
    var onDetailChange: () -> Void

    var body: some View {
        Button {
            AppHaptics.tap()
            onSelect(app)
        } label: {
            tileLabel
        }
        .buttonStyle(.plain)
        .appPressable(scale: 0.94)
        .contextMenu {
            Button(role: .destructive) {
                onDelete(app)
            } label: {
                Label("删除容器", systemImage: "trash")
            }
        }
    }

    /// 图标 + 两行文字. 单独抽出来，`label:` 闭包就只是一次属性引用.
    private var tileLabel: some View {
        VStack(spacing: 8) {
            SandboxAppIconView(bundleID: app.id, size: 60)
            Text(app.displayName)
                .font(AppFont.caption)
                .foregroundStyle(.primary)
                .lineLimit(2)
                .multilineTextAlignment(.center)
                .frame(maxWidth: .infinity)
            Text(app.bundleVersion ?? app.id)
                .font(AppFont.caption)
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .frame(maxWidth: .infinity)
        }
        .padding(.vertical, 10)
        .frame(maxWidth: .infinity)
        .contentShape(Rectangle())
    }
}

// MARK: - 行内修饰

/// List 行三件套（无内缩 / 透明底 / 无分隔线）. 抽成一个扩展是为了让每个分支的
/// 表达式只剩「一次构造 + 一次属性引用」，把类型推断面压到最小（见 `content` 上方注释）.
extension View {
    var rowInList: some View {
        self
            .listRowInsets(EdgeInsets())
            .listRowBackground(Color.clear)
            .listRowSeparator(.hidden)
    }
}
