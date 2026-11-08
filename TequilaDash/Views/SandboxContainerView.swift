import SwiftUI
import UIKit
import UniformTypeIdentifiers

// 沙盒容器 · 列表页（v0.3.785 改版）
//
// 用户原话（2026-11-08）：「UI 界面很诡异和别扭，界面也很丑」「这个界面底栏自己独立一个，
// 不要用默认界面的底栏了」，并指定参考「应用管理 / 应用信息」那套布局.
//
// 本轮改的是什么（对照真机截图）：
// 1. 网格换成**整宽横幅行**：LCAppListView 自己也是 `LazyVStack { ForEach { LCAppBanner } }`
//    （图标网格来自另一个项目 LCGridLayout，不是它的应用列表）. 单格网格会把一格孤零零
//    摆在左半屏，横幅整宽铺满就没有这个问题.
// 2. 行内缩不再清零：改前 `rowInList` 把 `listRowInsets` 抹成 0，空态图标与分段标题的
//    竖条被顶到屏幕左缘、贴边半个字. 现在左右统一 `AppTheme.pageInset`.
// 3. 底栏「导入」换成「设置」：导入仍走右上角工具栏按钮（用户要的入口没丢），
//    设置先给一个占位 sheet，不放假开关.
//
// 目录口径不变：Documents/SandboxApps/Applications/<app>.app 放包体，
// Documents/SandboxApps/Data/Application/<UUID> 放可写家目录（HOME / CFFIXED_USER_HOME）.

/// 容器应用图标缓存：从 Caches/SandboxContainerIcons/<bundleId>.png 读一次就常驻.
///
/// 与 JITAppIconLoader 同一诉求（列表里几十格同时解码），但来源是本机文件，
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
        // 连续圆角：AppIcon 口径 8/36 ≈ 0.2222，与 LCAppBanner 的 16/60 视觉一致.
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

/// 列表页与详情页共用的容器动作（重签 / 删除）.
///
/// 抽成一处只为「列表长按菜单」和「详情页底栏」不各写一份重签流程：
/// 引擎调用是同步抛错的，跨线程搬运必须显式 `Task.detached`，
/// 返回值只用 `(Bool, String)` 与 `RemoveResult`（都是 Sendable），不把 `Error` 搬过 actor 边界.
enum SandboxContainerActions {
    /// 整包重签. 返回（是否成功, 结果文案），文案由调用方播报.
    static func resign(_ app: SandboxApp) async -> (ok: Bool, text: String) {
        await Task.detached(priority: .userInitiated) { () -> (ok: Bool, text: String) in
            do {
                return (true, try SandboxResigner.resign(app).summary)
            } catch {
                return (false, "重签失败：" + error.localizedDescription)
            }
        }.value
    }

    /// 删除容器（包体 + 可写目录）.
    static func remove(_ app: SandboxApp) async -> SandboxContainerStore.RemoveResult {
        await Task.detached(priority: .userInitiated) {
            SandboxContainerStore.remove(app)
        }.value
    }
}

/// 沙盒容器列表页：左对齐大标题 + 整宽横幅列表 + 本页自己的悬浮底栏.
struct SandboxContainerView: View {
    @Environment(\.dismiss) private var dismiss

    @State private var apps: [SandboxApp] = []
    @State private var isLoading = false
    @State private var isImporting = false
    @State private var isResigning = false
    @State private var searchText = ""
    @State private var showImporter = false
    @State private var showSettings = false
    @State private var deleteTarget: SandboxApp?
    /// 已锁定应用的二次确认目标：第一道确认走 `deleteTarget`，锁定项再走这一道.
    @State private var lockedDeleteTarget: SandboxApp?
    @State private var dataTarget: SandboxApp?
    @State private var shareTarget: SandboxApp?
    /// 详情走 `navigationDestination(item:)` 而不是行内 NavigationLink：
    /// 后者在 List 里会被系统注入一个 disclosure 箭头，孤零零挂在行右侧（真机病点）.
    @State private var selectedApp: SandboxApp?

    /// 排序持久化. 键名沿用本仓「模块.项」点号惯例（LC 用 `LCAppSortType`）.
    @AppStorage("SandboxContainer.AppSort") private var sortRaw = SandboxAppSort.defaultOrder.rawValue

    /// 当前排序（`sortRaw` 读不出已知值时回落默认，绝不因为坏值让列表空掉）.
    private var sort: SandboxAppSort {
        SandboxAppSort(rawValue: sortRaw) ?? .defaultOrder
    }

    private var searchQuery: String {
        searchText.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
    }

    /// 搜索框常驻（.always）—— 本页容器是 List，系统会把搜索框计入内容安全区，
    /// swift_searchbar_guard S1 因此放行；缩卡由 .avoidSearchZoom() 压制（HARD-RULES 30）.
    ///
    /// 隐藏项的处理顺序不能反：**先**按关键词过滤，**再**排除隐藏 —— 搜索框有字时隐藏项
    /// 照常露面（LC 的隐藏是「藏起来」不是「删掉」），空查询时它们才真正退出主列表.
    private var filteredApps: [SandboxApp] {
        let query = searchQuery
        let matched = query.isEmpty
            ? apps
            : apps.filter {
                $0.displayName.lowercased().contains(query) || $0.id.lowercased().contains(query)
            }
        let visible = query.isEmpty ? matched.filter { !$0.isHidden } : matched
        return sort.applied(to: visible)
    }

    var body: some View {
        page
            .sheet(item: $dataTarget) { app in dataBrowserSheet(app) }
            .sheet(item: $shareTarget) { app in shareSheet(app) }
            .sheet(isPresented: $showSettings) { settingsSheet }
            .confirmationDialog(lockedDeletePromptText, isPresented: lockedDeleteBinding,
                                titleVisibility: .visible) {
                Button("仍然删除", role: .destructive) {
                    if let target = lockedDeleteTarget { remove(target) }
                }
                Button("取消", role: .cancel) { lockedDeleteTarget = nil }
            } message: {
                Text(lockedDeletePromptText)
            }
    }

    /// 页面主体单独抽出来：三个 sheet 挂在 body 上，body 自己只剩四次属性 / 闭包引用，
    /// 把类型推断面留在 `page` 一处（本仓 CI 四次实证「修饰符堆叠」会超时）.
    private var page: some View {
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
                // 锁定项要多一道确认：第一道只把目标交给二次确认，不直接删.
                // 两枚 confirmationDialog 同一轮里连着弹，系统会把后一枚吞掉（本仓
                // ModuleManagerView 的同一处理也是先让前一枚退场），故隔一帧再抬第二枚.
                guard let target = deleteTarget else { return }
                deleteTarget = nil
                if target.isLocked {
                    Task { @MainActor in
                        // 400ms > 系统 dialog 退场动画（约 0.3s）：早于此抬起会被前一枚吞掉.
                        try? await Task.sleep(for: .milliseconds(400))
                        lockedDeleteTarget = target
                    }
                } else {
                    remove(target)
                }
            }
            Button("取消", role: .cancel) {}
        } message: {
            Text(deletePromptText)
        }
        .overlay {
            if isImporting {
                AppBusyOverlay(title: "正在导入…", style: .card)
            } else if isResigning {
                AppBusyOverlay(title: "正在重签…", style: .card)
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
        appSection
    }

    @ViewBuilder
    private var stateSection: some View {
        if isLoading && apps.isEmpty {
            loadingRow
        } else if apps.isEmpty {
            emptyRow
        } else if filteredApps.isEmpty {
            // 搜索框为空而列表空 = 容器全被隐藏；有查询词才是「没匹配上」.
            if searchQuery.isEmpty { allHiddenRow } else { noMatchRow }
        }
    }

    private var loadingRow: some View {
        Section {
            AppLoadingRow(title: "正在读取容器目录…", level: .page)
                .padding(.vertical, 12)
                .rowInList
        }
    }

    private var emptyRow: some View {
        Section {
            AppStateSection(state: .empty("还没有容器应用",
                                       message: "点右上角「导入」选择一个未加密的 IPA. 加密包（App Store 直接下载的那种）装不进来.",
                                       icon: "square.stack.3d.up"),
                            wrapsSection: false)
                .padding(.vertical, 12)
                .rowInList
        }
    }

    private var noMatchRow: some View {
        Section {
            AppStateSection(state: .empty("没有匹配的应用", message: "换个关键词试试.", icon: "magnifyingglass"),
                            wrapsSection: false)
                .padding(.vertical, 12)
                .rowInList
        }
    }

    /// 全部容器都被隐藏时的空态：不冒充「没有匹配」（此时搜索框是空的）.
    private var allHiddenRow: some View {
        Section {
            AppStateSection(state: .empty("容器都已隐藏",
                                          message: "锁定后隐藏的容器不进主列表. 在搜索框输入名称或 Bundle ID 就能找到它们.",
                                          icon: "eye.slash"),
                           wrapsSection: false)
                .padding(.vertical, 12)
                .rowInList
        }
    }

    @ViewBuilder
    private var appSection: some View {
        if !apps.isEmpty && !filteredApps.isEmpty {
            Section {
                sectionHeader
                appRows
            }
        }
    }

    private var sectionHeader: some View {
        AppSectionHeader("容器应用", subtitle: "\(filteredApps.count) 个", symbol: "square.grid.3x3",
                         tint: AppModule.store.tint)
            .padding(.top, 4)
            .padding(.bottom, 10)
            .rowInList
    }

    /// 一行一个横幅：整宽卡片，不再走网格（网格只剩一格时会孤零零贴在左半屏）.
    private var appRows: some View {
        ForEach(filteredApps) { app in
            banner(app)
        }
    }

    private func banner(_ app: SandboxApp) -> some View {
        SandboxAppBanner(app: app,
                         onSelect: { selectedApp = app },
                         onOpenData: { dataTarget = app },
                         onShare: { shareTarget = app },
                         onResign: { resign(app) },
                         onDelete: { deleteTarget = app },
                         onToggleLock: { setAccess(app, locked: !app.isLocked) },
                         onToggleHide: { setAccess(app, locked: true, hidden: !app.isHidden) },
                         onSelectContainer: { container in switchContainer(app, to: container) })
            .padding(.bottom, 10)
            .rowInList
    }

    // MARK: - 导航栏与底栏

    /// 导入入口留在导航栏（底栏的「导入」已让位给「设置」）.
    @ToolbarContentBuilder
    private var listToolbar: some ToolbarContent {
        ToolbarItem(placement: .navigationBarTrailing) {
            Button {
                AppHaptics.tap()
                showImporter = true
            } label: {
                Image(systemName: "square.and.arrow.down")
            }
            .disabled(isImporting)
        }
    }

    /// 本页独立的悬浮玻璃丸底栏（用户点名不要主 App 的 TabBar）.
    private var listBar: some View {
        SandboxFloatingBar {
            SandboxBarCell(title: "设置", symbol: "gearshape", tint: AppModule.settings.tint) {
                AppHaptics.tap()
                showSettings = true
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

    // MARK: - 弹出层

    /// 设置页：只放**真能生效**的一项 —— 列表排序. 改前这里是「设置待接入」空态，
    /// 换成排序选择器，不放假开关.
    private var settingsSheet: some View {
        NavigationStack {
            List {
                sortSection
            }
            .listStyle(.plain)
            .scrollContentBackground(.hidden)
            .background(AppTheme.surfaceBase)
            .navigationTitle("设置")
            .navigationBarTitleDisplayMode(.inline)
        }
    }

    /// 排序一项，落 `@AppStorage`，关掉再开仍是上次的选择.
    ///
    /// 标题行与选择器拆成两个属性：本仓 CI 四次实证「视图构造 + 多层修饰」堆在一起会超时.
    private var sortSection: some View {
        Section {
            sortHeader
            sortPicker
        }
    }

    private var sortHeader: some View {
        AppSectionHeader("排序", subtitle: "容器列表顺序", symbol: "arrow.up.arrow.down.circle",
                         tint: AppModule.store.tint)
            .padding(.top, 4)
            .padding(.bottom, 10)
            .rowInList
    }

    private var sortPicker: some View {
        Picker("排序方式", selection: $sortRaw) {
            ForEach(SandboxAppSort.allCases) { option in
                Label(option.title, systemImage: option.symbol).tag(option.rawValue)
            }
        }
        .pickerStyle(.menu)
        .rowInList
    }

    /// 可写目录浏览器：只在 `dataPath` 真存在时打开，不拿包体目录冒充.
    @ViewBuilder
    private func dataBrowserSheet(_ app: SandboxApp) -> some View {
        if let dataPath = app.dataPath {
            NavigationStack {
                FileBrowserView(rootPath: dataPath, title: "数据目录")
            }
        }
    }

    private func shareSheet(_ app: SandboxApp) -> some View {
        ShareSheet(items: [URL(fileURLWithPath: app.appPath)])
    }

    // MARK: - 删除确认

    private var deletePromptText: String {
        "删除 \(deleteTarget?.displayName ?? "") 的容器？包体与可写目录一起移除，不可恢复."
    }

    private var deleteDialogBinding: Binding<Bool> {
        Binding(get: { deleteTarget != nil },
              set: { if !$0 { deleteTarget = nil } })
    }

    /// 锁定项的二次确认文案. 说清「已锁定」这件事，不重复第一道的措辞.
    private var lockedDeletePromptText: String {
        "「\(lockedDeleteTarget?.displayName ?? "")」已锁定. 删除会移除包体与可写目录，不可恢复."
    }

    private var lockedDeleteBinding: Binding<Bool> {
        Binding(get: { lockedDeleteTarget != nil },
              set: { if !$0 { lockedDeleteTarget = nil } })
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
        lockedDeleteTarget = nil
        Task {
            let result = await SandboxContainerActions.remove(app)
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

    /// 整包重签（长按菜单入口），流程与详情页共用 `SandboxContainerActions`.
    private func resign(_ app: SandboxApp) {
        guard !isResigning else { return }
        isResigning = true
        Task {
            let outcome = await SandboxContainerActions.resign(app)
            isResigning = false
            if outcome.ok { AppHaptics.success() }
            ToastCenter.shared.show(outcome.text, seconds: 3.2)
        }
    }

    /// 锁定 / 隐藏落登记（隐藏是锁定的子选项，由引擎侧维持「隐藏 ⇒ 锁定」）.
    ///
    /// 只改登记不动磁盘，写完重扫一次让列表拿到新标志 —— 不做本地猜测式更新，
    /// 免得界面与 plist 不一致. plist 读写放后台线程（与 `reload()` 同一取向）.
    private func setAccess(_ app: SandboxApp, locked: Bool, hidden: Bool = false) {
        AppHaptics.tap()
        Task {
            await Task.detached(priority: .userInitiated) {
                SandboxContainerStore.setAccess(for: app, locked: locked, hidden: hidden)
            }.value
            await reload()
        }
    }

    /// 从横幅菜单切换激活容器：只改登记指针，写完重扫让横幅的「容器」一行跟着变.
    private func switchContainer(_ app: SandboxApp, to container: SandboxContainerRef) {
        guard container.folderName != app.activeContainer else { return }
        AppHaptics.tap()
        let bundleId = app.id
        let folderName = container.folderName
        Task {
            await Task.detached(priority: .userInitiated) {
                guard let fresh = SandboxContainerStore.scan().first(where: { $0.id == bundleId }) else { return }
                SandboxContainerStore.setActiveContainer(for: fresh, folderName: folderName)
            }.value
            await reload()
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

// MARK: - 横幅行

/// 一行一个容器应用：整宽卡片 + 大图标 + 名称 / 版本 / 大小.
///
/// 形态照 LCAppListView 的 `LCAppBanner`（它自己就是整宽横幅，不是图标网格）：
/// 图标在左、文字栈紧随其后、右侧留白. 本仓不摆「运行」按钮 —— 容器内启动还没接，
/// 放假按钮等于假入口；详情页已写明启动待接入.
///
/// 用 `Button` + 容器级 `navigationDestination(item:)` 而不是行内 `NavigationLink`：
/// 后者会让系统在行右侧再注入一个 disclosure 箭头.
struct SandboxAppBanner: View {
    let app: SandboxApp
    var onSelect: () -> Void
    var onOpenData: () -> Void
    var onShare: () -> Void
    var onResign: () -> Void
    var onDelete: () -> Void
    /// 锁定开关（LCAppSettingsView:220-225 同口径）.
    var onToggleLock: () -> Void
    /// 隐藏开关 —— **锁定的子选项**（LCAppSettingsView:227-235），只在已锁定时出现在菜单里.
    var onToggleHide: () -> Void
    /// 从横幅菜单切换激活容器（LCAppBannerViewController.swift:140-151 同位置）.
    var onSelectContainer: (SandboxContainerRef) -> Void

    var body: some View {
        Button(action: onSelect) {
            bannerLabel
        }
        .buttonStyle(.plain)
        .appPressable(scale: 0.98)
        .contextMenu { menu }
    }

    /// 卡片本体. 单独抽出来，`label:` 闭包就只是一次属性引用.
    private var bannerLabel: some View {
        HStack(spacing: 12) {
            SandboxAppIconView(bundleID: app.id, size: 60)
            titleStack
            Spacer(minLength: 8)
        }
        .padding(AppMetrics.cardPadding)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: AppRadius.card, style: .continuous)
                .fill(AppSurface.card)
        )
        .contentShape(RoundedRectangle(cornerRadius: AppRadius.card, style: .continuous))
    }

    /// 名称 / 版本与 Bundle ID / 激活容器 / 包体大小. 文字一律主色与次色，不做彩色.
    ///
    /// 激活容器一行照 LCAppBannerView.swift:147（`containerLabel`）：没有容器时写「未创建」，
    /// 不隐藏这一行 —— 藏起来会让「有容器 / 没容器」的横幅长得不一样，列表看着忽高忽低.
    private var titleStack: some View {
        VStack(alignment: .leading, spacing: 3) {
            nameRow
            Text(versionLine)
                .font(AppFont.caption)
                .foregroundStyle(.secondary)
                .lineLimit(1)
            Text(containerLine)
                .font(AppFont.caption)
                .foregroundStyle(.secondary)
                .lineLimit(1)
            Text(app.sizeText)
                .font(AppFont.footnote)
                .foregroundStyle(.secondary)
                .lineLimit(1)
        }
    }

    /// 「容器：<名字>」或「容器：未创建」；多份时带份数.
    private var containerLine: String {
        guard let name = app.activeContainerName else { return "容器：未创建" }
        guard app.containers.count > 1 else { return "容器：" + name }
        return "容器：" + name + "（共 \(app.containers.count) 份）"
    }

    /// 名称一行 + 锁定标记（与 LCAppBanner 同形：锁着才挂锁，隐藏时不挂）.
    private var nameRow: some View {
        HStack(spacing: 5) {
            Text(app.displayName)
                .font(AppFont.headline)
                .foregroundStyle(.primary)
                .lineLimit(1)
            if app.isLocked {
                Image(systemName: "lock.fill")
                    .font(AppFont.caption)
                    .foregroundStyle(.secondary)
                    .accessibilityLabel("已锁定")
            }
        }
    }

    private var versionLine: String {
        let version = app.bundleVersion ?? "版本未登记"
        return version + " · " + app.id
    }

    /// 长按菜单：只放真能跑通的项. 「打开数据目录」仅在可写目录已建时出现；
    /// 「隐藏」仅在已锁定时出现（隐藏是锁定的子选项，不另开一条独立状态机）.
    ///
    /// 容器切换只在**多于一份**时出现（LCAppBannerViewController.swift:140 同一门槛）：
    /// 只有一份时给一个「切换」子菜单是纯噪音.
    @ViewBuilder
    private var menu: some View {
        if app.hasDataHome {
            Button {
                onOpenData()
            } label: {
                Label("打开数据目录", systemImage: "folder")
            }
        }
        if app.containers.count > 1 {
            containerPickerMenu
        }
        Button {
            onResign()
        } label: {
            Label("重签包体", systemImage: "hammer")
        }
        Button {
            onShare()
        } label: {
            Label("分享包体", systemImage: "square.and.arrow.up")
        }
        lockMenuButton
        if app.isLocked {
            hideMenuButton
        }
        Button(role: .destructive) {
            onDelete()
        } label: {
            Label("删除容器", systemImage: "trash")
        }
    }

    /// 容器切换子菜单：每份一行，当前那份打勾.
    private var containerPickerMenu: some View {
        Menu {
            ForEach(app.containers) { container in
                Button {
                    onSelectContainer(container)
                } label: {
                    if container.folderName == app.activeContainer {
                        Label(container.name, systemImage: "checkmark")
                    } else {
                        Text(container.name)
                    }
                }
            }
        } label: {
            Label("切换容器", systemImage: "square.stack")
        }
    }

    /// 锁定 / 解锁. 只读动作（打开目录 / 重签 / 分享）不受锁影响，只有删除要多一道确认.
    private var lockMenuButton: some View {
        Button {
            onToggleLock()
        } label: {
            Label(app.isLocked ? "解除锁定" : "锁定", systemImage: "lock.fill")
        }
    }

    private var hideMenuButton: some View {
        Button {
            onToggleHide()
        } label: {
            Label(app.isHidden ? "取消隐藏" : "隐藏", systemImage: "eye.slash")
        }
    }
}

// MARK: - 行内修饰

/// List 行三件套（页边距 / 透明底 / 无分隔线）.
///
/// 左右内缩取 `AppTheme.pageInset`：改前抹成 0，空态图标与分段标题的竖条会被顶到屏幕
/// 左缘、贴边半个字（真机截图病点）. 纵向留白交给各段自己加，标题与首行才贴得紧.
extension View {
    var rowInList: some View {
        self
            .listRowInsets(EdgeInsets(top: 0, leading: AppTheme.pageInset,
                                      bottom: 0, trailing: AppTheme.pageInset))
            .listRowBackground(Color.clear)
            .listRowSeparator(.hidden)
    }
}

// MARK: - 排序

/// 容器列表排序（照 LCAppSortManager 的 `AppSortType` 取子集）.
///
/// 只保留**有真实字段支撑**的四档：LC 的 `.lastLaunched` 需要每个 App 的 `lastLaunched`
/// 时间戳，本仓没有启动链路（容器内启动还没接），也就没有写它的地方 —— 造一个永远为 nil
/// 的字段等于给用户一个假选项，故不实现；`.custom` 需要拖拽改序的编辑界面，同理不实现.
///
/// `.defaultOrder` 就是 `SandboxContainerStore.scan()` 的原始顺序（安装时间新 → 旧）.
enum SandboxAppSort: String, CaseIterable, Identifiable {
    case defaultOrder = "default"
    case alphabetical = "alphabetical"
    case reverseAlphabetical = "reverse_alphabetical"
    case installationDate = "installationDate"

    var id: String { rawValue }

    var title: String {
        switch self {
        case .defaultOrder: return "默认"
        case .alphabetical: return "名称 A → Z"
        case .reverseAlphabetical: return "名称 Z → A"
        case .installationDate: return "安装时间"
        }
    }

    /// 与 LC 同形（ellipsis / chevron.down / chevron.up / square.and.arrow.down）.
    var symbol: String {
        switch self {
        case .defaultOrder: return "ellipsis"
        case .alphabetical: return "chevron.down"
        case .reverseAlphabetical: return "chevron.up"
        case .installationDate: return "square.and.arrow.down"
        }
    }

    /// 应用排序. 只改展示顺序，不动 `scan()` 的原始数组.
    func applied(to apps: [SandboxApp]) -> [SandboxApp] {
        switch self {
        case .defaultOrder:
            return apps
        case .alphabetical:
            return apps.sorted {
                $0.displayName.localizedStandardCompare($1.displayName) == .orderedAscending
            }
        case .reverseAlphabetical:
            return apps.sorted {
                $0.displayName.localizedStandardCompare($1.displayName) == .orderedDescending
            }
        case .installationDate:
            // LC 同口径：有安装时间的按新 → 旧，读不出时间的排最后.
            let dated = apps.filter { $0.installedAt != nil }.sorted {
                ($0.installedAt?.timeIntervalSinceReferenceDate ?? 0)
                    > ($1.installedAt?.timeIntervalSinceReferenceDate ?? 0)
            }
            let undated = apps.filter { $0.installedAt == nil }
            return dated + undated
        }
    }
}
