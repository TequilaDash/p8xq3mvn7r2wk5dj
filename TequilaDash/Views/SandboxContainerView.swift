import SwiftUI
import UIKit
import UniformTypeIdentifiers

// TDLaunchGuestRestart 的全仓唯一 @_silgen_name 声明在 SandboxAppSettingsView.swift (防重复符号).

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
    /// LC dynamicColors 键: 关掉时横幅回落卡片底色 (设置页「界面」节真连线).
    @AppStorage("dynamicColors") var bannerDynamicColors = true

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
    /// 底栏「源 / 模块」预留页的承载（nil = 不弹）.
    @State private var placeholderSlot: SandboxSlot?
    /// LC 设置同款键: 动态配色 (横幅染色跟随) / 启动忽略 JIT (LCBootstrap checkJITEnabled 真读)
    @AppStorage("dynamicColors") var dynamicColors = true
    @AppStorage("LCIgnoreJITOnLaunch") var ignoreJITOnLaunch = false
    @State private var developerMode = false
    /// 模块页: Tweaks 目录真实清单 + 导入
    @State private var tweakFiles: [String] = []
    @State private var showTweakImporter = false
    /// 蜂窝区状态 (设置页 onAppear 从 UserDefaults 同步)
    @State private var cellularEnabled = false
    @State private var cellularMode: CellularTunnelManager.ToggleMode = .auto
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
            .sheet(item: $placeholderSlot) { slot in slotSheet(slot) }
            .sheet(isPresented: $showTweakImporter) {
                documentPicker(isPresented: $showTweakImporter,
                               allowedTypes: [UTType(filenameExtension: "dylib") ?? .data]) { urls in
                    importTweaks(urls)
                }
            }
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
        // 真间距: 与详情页同口径 (卡片之间 12pt, 不再贴死).
        .listSectionSpacing(12)
        .scrollContentBackground(.hidden)
        .background(AppTheme.surfaceBase)
        .navigationTitle("沙盒容器")
        .navigationBarTitleDisplayMode(.large)
        .searchable(text: $searchText, placement: .navigationBarDrawer(displayMode: .always), prompt: "搜索应用或 Bundle ID")
        .avoidSearchZoom()
        .safeAreaInset(edge: .bottom, spacing: 0) { listBar }
        .toolbar { listToolbar }
        .navigationDestination(item: $selectedApp) { app in
            // 应用管理 (LCAppSettingsView 同构): 横幅/图标点击的落点,
            // 旧 SandboxAppDetailView 从导航退役 (独有动作已收进新页的操作节).
            SandboxAppSettingsView(app: app, onChange: { Task { await reload() } })
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
                         onSelect: { openDetail(app) },
                         onLaunch: { launchGuestOrOpenDetail(app) },
                         onOpenData: { dataTarget = app },
                         onShare: { shareTarget = app },
                         onResign: { resign(app) },
                         onDelete: { deleteTarget = app },
                         onToggleLock: { toggleLock(app) },
                         onToggleHide: { toggleHide(app) },
                         onSelectContainer: { container in switchContainer(app, to: container) })
            .padding(.bottom, 10)
            .rowInList
    }

    // MARK: - 导航栏与底栏

    /// 左上 = 返回主页（owner 2026-11-08: 底栏「回主页」让位给「模块」，返回动作挪到左上）；
    /// 右上 = 导入 + 刷新两个平级 item（AppListView.swift:535,543 同形，不用玻璃胶囊组）.
    ///
    /// 本页是 SandboxHostView 的栈根（SandboxHostView.swift:14-20，整页由 HomeView 的
    /// fullScreenCover 盖出），没有系统返回键可隐 —— leading 放返回键不触碰 HARD-RULES 24
    /// （那条禁的是「隐藏系统返回键 + 自定义返回」）.
    @ToolbarContentBuilder
    private var listToolbar: some ToolbarContent {
        ToolbarItem(placement: .navigationBarLeading) {
            Button {
                AppHaptics.tap()
                dismiss()
            } label: {
                Image(systemName: "chevron.left")
            }
            .accessibilityLabel("返回主页")
        }
        ToolbarItem(placement: .navigationBarTrailing) {
            Button {
                AppHaptics.tap()
                showImporter = true
            } label: {
                Image(systemName: "square.and.arrow.down")
            }
            .disabled(isImporting)
        }
        ToolbarItem(placement: .navigationBarTrailing) {
            Button {
                AppHaptics.tap()
                Task { await reload() }
            } label: {
                Image(systemName: "arrow.clockwise")
            }
            .accessibilityLabel("刷新")
        }
    }

    /// 本页独立的悬浮玻璃丸底栏（用户点名不要主 App 的 TabBar）.
    ///
    /// 三槽顺序 owner 拍板固定：设置 / 源 / 模块（2026-11-08 原话：回主页挪左上、刷新挪右上，
    /// 腾出的两格给「源」「模块」）。源 / 模块先给预留页（诚实空态，不放假开关）.
    private var listBar: some View {
        SandboxFloatingBar {
            SandboxBarCell(title: "设置", symbol: "gearshape", tint: AppModule.settings.tint) {
                AppHaptics.tap()
                showSettings = true
            }
            SandboxBarDivider()
            SandboxBarCell(title: "源", symbol: "shippingbox", tint: AppModule.store.tint) {
                AppHaptics.tap()
                placeholderSlot = .sources
            }
            SandboxBarDivider()
            SandboxBarCell(title: "模块", symbol: "puzzlepiece.extension", tint: AppTheme.accent) {
                AppHaptics.tap()
                placeholderSlot = .modules
            }
        }
    }

    // MARK: - 弹出层

    /// 设置页：只放**真能生效**的一项 —— 列表排序. 改前这里是「设置待接入」空态，
    /// 换成排序选择器，不放假开关.
    /// 设置页: LCSettingsView 同构 (证书 → 界面 → 通知 → 关于 → 开发者),
    /// 蜂窝区 = 本仓等效 LC 的 JIT 启用器配置; 排序留底部 (列表页设置).
    private var settingsSheet: some View {
        NavigationStack {
            List {
                Section {
                    NavigationLink {
                        CertificateView()
                    } label: {
                        Text(UserDefaults.standard.string(forKey: "LCCertificatePassword") != nil
                             ? "查看 / 移除证书" : "导入证书 (JITLess 需要)")
                    }
                } header: {
                    Text("证书 (JITLess)")
                } footer: {
                    Text("iOS 26 起无 JIT 必须走 JITLess: 导入 p12 开发证书后, 访客以重签+钩子方式运行.")
                }
                Section {
                    Toggle("蜂窝隧道支持", isOn: $cellularEnabled)
                        .onChange(of: cellularEnabled) { newValue in
                            UserDefaults.standard.set(newValue, forKey: CellularTunnelManager.enabledKey)
                        }
                    if cellularEnabled {
                        Picker("关蜂窝方式", selection: $cellularMode) {
                            ForEach(CellularTunnelManager.ToggleMode.allCases, id: \.self) { mode in
                                Text(mode.label).tag(mode)
                            }
                        }
                        .onChange(of: cellularMode) { newValue in
                            CellularTunnelManager.shared.toggleMode = newValue
                        }
                    }
                } header: {
                    Text("蜂窝网络")
                } footer: {
                    Text("蜂窝下使用本地隧道需开此开关 (本仓等效 LC 的 JIT 启用器配置).")
                }
                Section {
                    Toggle("动态配色", isOn: $dynamicColors)
                } header: {
                    Text("界面")
                } footer: {
                    Text("横幅背景与应用图标主色联动 (LCAppBannerView 的 dynamicColors 同款).")
                }
                Section {
                    Button {
                        AppHaptics.tap()
                        UNUserNotificationCenter.current().removeAllDeliveredNotifications()
                        ToastCenter.shared.show("已清除通知", seconds: 2.0)
                    } label: {
                        Text("清除通知")
                    }
                }
                Section {
                    HStack {
                        Image(systemName: "link")
                        Button("LiveContainer/LiveContainer") {
                            if let url = URL(string: "https://github.com/LiveContainer/LiveContainer") {
                                UIApplication.shared.open(url)
                            }
                        }
                    }
                    infoRow("版本", Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "?")
                        .onTapGesture { count in
                            if count >= 5 { developerMode = true }
                        }
                } header: {
                    Text("关于")
                } footer: {
                    Text("沙盒容器基于 LiveContainer (GPL) 移植.")
                }
                if developerMode {
                    Section {
                        Toggle("启动 App 时忽略 JIT 检查", isOn: $ignoreJITOnLaunch)
                    } header: {
                        Text("开发者")
                    } footer: {
                        Text("LCBootstrap 的 checkJITEnabled 读取本键; 供 JITLess 调试.")
                    }
                }
                sortSection
            }
            .listStyle(.plain)
            .listSectionSpacing(12)
            .scrollContentBackground(.hidden)
            .background(AppTheme.surfaceBase)
            .navigationTitle("设置")
            .navigationBarTitleDisplayMode(.inline)
            .onAppear {
                cellularEnabled = UserDefaults.standard.bool(forKey: CellularTunnelManager.enabledKey)
                cellularMode = CellularTunnelManager.shared.toggleMode
            }
        }
    }

    private func infoRow(_ label: String, _ value: String) -> some View {
        HStack {
            Text(label).font(AppFont.caption).foregroundStyle(.secondary)
            Spacer(minLength: 4)
            Text(value).font(AppFont.caption).foregroundStyle(.primary)
        }
    }

    /// Tweaks 目录 = SandboxApps/Tweaks (LCBootstrap docPath/Tweaks 同款, 已 setenv 挂给访客).
    private var tweaksDirectory: URL {
        URL(fileURLWithPath: NSHomeDirectory())
            .appendingPathComponent("Documents/SandboxApps/Tweaks", isDirectory: true)
    }

    private func reloadTweaks() {
        let dir = tweaksDirectory
        let names = (try? FileManager.default.contentsOfDirectory(atPath: dir.path)) ?? []
        tweakFiles = names.filter { $0.hasSuffix(".dylib") }.sorted()
    }

    private func importTweaks(_ urls: [URL]) {
        let fm = FileManager.default
        try? fm.createDirectory(at: tweaksDirectory, withIntermediateDirectories: true)
        for url in urls {
            let dest = tweaksDirectory.appendingPathComponent(url.lastPathComponent)
            try? fm.removeItem(at: dest)
            try? fm.copyItem(at: url, to: dest)
        }
        reloadTweaks()
        ToastCenter.shared.show("已导入 \(urls.count) 个模块", seconds: 2.6)
    }

    /// 源 / 模块页: 模块 = Tweaks 目录真实清单 (LC_GLOBAL_TWEAKS_FOLDER 同款路径);
    /// 源 = LC 的 AltStore 源机制, 需下载管线, 诚实说明不放假列表.
    @ViewBuilder
    private func slotSheet(_ slot: SandboxSlot) -> some View {
        if slot == .modules {
            modulesSheet
        } else {
            sourcesSheet
        }
    }

    /// 模块页: SandboxApps/Tweaks/*.dylib 真实目录清单 + 导入.
    private var modulesSheet: some View {
        NavigationStack {
            List {
                Section {
                    if tweakFiles.isEmpty {
                        Text("暂无模块. 点右上角导入 .dylib, 文件按 LC 约定落入全局 Tweaks 目录.")
                            .font(AppFont.caption)
                            .foregroundStyle(.secondary)
                    }
                    ForEach(tweakFiles, id: \.self) { name in
                        Label(name, systemImage: "puzzlepiece.extension")
                    }
                } header: {
                    Text("全局模块 (Tweaks)")
                } footer: {
                    Text("目录: Documents/SandboxApps/Tweaks (LC_GLOBAL_TWEAKS_FOLDER 同款, 已挂给访客). dylib 注入装载器 (TweakLoader) 下一版接入.")
                }
            }
            .listStyle(.plain)
            .listSectionSpacing(12)
            .scrollContentBackground(.hidden)
            .background(AppTheme.surfaceBase)
            .navigationTitle("模块")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .navigationBarTrailing) {
                    Button {
                        AppHaptics.tap()
                        showTweakImporter = true
                    } label: {
                        Image(systemName: "square.and.arrow.down")
                    }
                }
            }
        }
        .onAppear { reloadTweaks() }
    }

    /// 源页: LC 的源 = AltStore source JSON (浏览+装包管线), 本仓还没有该管线 —— 诚实说明.
    private var sourcesSheet: some View {
        NavigationStack {
            List {
                Section {
                    AppStateSection(state: .empty("源功能管线接入中",
                                                  message: "LC 的「源」= AltStore source JSON (远程应用清单 + 下载安装). 该管线依赖下载与装包链路, 接入后此处列出源并可直接装包到容器.",
                                                  icon: "shippingbox"),
                                    wrapsSection: false)
                        .padding(.vertical, 12)
                        .rowInList
                }
            }
            .listStyle(.plain)
            .scrollContentBackground(.hidden)
            .background(AppTheme.surfaceBase)
            .navigationTitle("源")
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
        LabeledContent {
            Picker("排序方式", selection: $sortRaw) {
                ForEach(SandboxAppSort.allCases) { option in
                    Label(option.title, systemImage: option.symbol).tag(option.rawValue)
                }
            }
            .pickerStyle(.menu)
            .labelsHidden()
            .fixedSize()
        } label: {
            Text("排序方式")
        }
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

    /// LC 主路 (owner 2026-11-08: 「点 App 即启动」, 不是多任务那条): 写 LC 键 →
    /// 重启自身 → 新进程 main() 分岔进 LiveContainerMain. 无可用容器时不假启动,
    /// 照旧进详情页引导建容器; 长按菜单的「详情」入口不变.
    private func launchGuestOrOpenDetail(_ app: SandboxApp) {
        guard let uuid = app.activeContainer else {
            // LC 首启同款: 无容器先自动建, 建好再启动 (不把用户甩到管理页).
            AppHaptics.tap()
            ToastCenter.shared.show("正在为 \(app.displayName) 创建容器…", seconds: 2.5)
            Task {
                await Task.detached(priority: .userInitiated) {
                    if let fresh = SandboxContainerStore.scan().first(where: { $0.id == app.id }) {
                        try? SandboxContainerStore.makeDataHome(for: fresh)
                    }
                }.value
                if let fresh = await SandboxContainerStore.scan().first(where: { $0.id == app.id }) {
                    launchGuestOrOpenDetail(fresh)
                } else {
                    selectedApp = app
                }
            }
            return
        }
        AppHaptics.tap()
        busy = true
        ToastCenter.shared.show("正在为 \(app.displayName) 重签…", seconds: 8.0)
        let snapshot = app
        let netBlock = UserDefaults.standard.bool(forKey: "TDNetBlock-\(app.id)")
        Task {
            let outcome = await Task.detached(priority: .userInitiated) {
                Result { try SandboxResigner.resign(snapshot, useMainIdentifier: true) }
            }.value
            busy = false
            switch outcome {
            case .success:
                let defaults = UserDefaults.standard
                defaults.set((snapshot.appPath as NSString).lastPathComponent, forKey: "selected")
                defaults.set(uuid, forKey: "selectedContainer")
                defaults.set(snapshot.displayName, forKey: "TDLastGuestName")
                defaults.set(snapshot.id, forKey: "TDLastGuestBundleId")
                defaults.set(netBlock, forKey: "TDGuestNetBlock")
                ToastCenter.shared.show("正在启动 \(snapshot.displayName)…", seconds: 3.0)
                TDLaunchGuestRestart()
            case .failure(let error):
                ToastCenter.shared.show("重签失败: \(error.localizedDescription)", seconds: 6.0)
            }
        }
    }

    /// 进入已锁定应用的详情页先过本机认证（LC 同位：LCAppListView.swift:540 在启动锁定应用前
    /// 验证；本仓容器内启动未接线，对应入口 = 详情页）. 认证不过不进页，不做本地放行.
    private func openDetail(_ app: SandboxApp) {
        guard app.isLocked else {
            selectedApp = app
            return
        }
        Task {
            let outcome = await SandboxAccessAuth.authenticate(
                reason: "验证以打开已锁定的「\(app.displayName)」")
            if handleAuth(outcome) { selectedApp = app }
        }
    }

    /// 锁定切换（上锁 / 解锁都验一次，owner 2026-11-08: 锁定不能是摆设）.
    private func toggleLock(_ app: SandboxApp) {
        Task {
            let verb = app.isLocked ? "解除锁定" : "锁定"
            let outcome = await SandboxAccessAuth.authenticate(
                reason: "验证以\(verb)「\(app.displayName)」")
            if handleAuth(outcome) { setAccess(app, locked: !app.isLocked) }
        }
    }

    /// 隐藏是锁定的子选项 —— 同一道认证闸门.
    private func toggleHide(_ app: SandboxApp) {
        Task {
            let outcome = await SandboxAccessAuth.authenticate(
                reason: "验证以更改「\(app.displayName)」的隐藏状态")
            if handleAuth(outcome) { setAccess(app, locked: true, hidden: !app.isHidden) }
        }
    }

    /// 认证结果统一落地：不可用（未设锁屏密码）与拒绝都如实播报，只有成功才放行动作.
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
/// LC 横幅逐项对齐 (LCAppBannerView.swift): 高 88 / 圆角 22 连续 / 背景染图标主色 50% /
/// 图标 60(r16, 点击=应用管理) / 详情栈(名称16 bold + 锁徽章 → 版本·BundleID 12 → 容器 11) /
/// 右侧「启动」胶囊 70×32(主色满底白 16 bold, 点击=启动访客) / 可读文字色按底色自动算.
/// 徽章口径同 LC (:150-157): 锁定且未隐藏才挂锁徽; JIT 徽章无数据源, 不放假徽章.
struct SandboxAppBanner: View {
    let app: SandboxApp
    /// 应用管理 (整卡 / 图标点击; LC: 横幅点击开 LCAppSettingsView).
    var onSelect: () -> Void
    /// 启动 (右侧胶囊钮; LCAppBannerView 的 runControl).
    var onLaunch: () -> Void
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

    /// LC 横幅常量 (LCAppBannerView.swift:10/45/104-107/113-116).
    private static let bannerHeight: CGFloat = 88
    private static let bannerRadius: CGFloat = 22

    @State private var icon: UIImage?

    var body: some View {
        bannerBody
            .contextMenu { menu }
            .task(id: app.id) {
                guard icon == nil else { return }
                let loaded = await Task.detached(priority: .userInitiated) {
                    SandboxIconLoader.shared.load(for: app.id)
                }.value
                if let loaded { icon = loaded }
            }
    }

    /// 横幅本体: 图标(点击=应用管理) + 详情栈 + 「启动」胶囊(点击=启动).
    /// 内层 onTapGesture 优先于外层 —— 图标与胶囊各自成靶, 其余区域整卡进应用管理.
    private var bannerBody: some View {
        HStack(spacing: 10) {
            iconView
                .onTapGesture { onSelect() }
            detailStack
            Spacer(minLength: 8)
            runControl
        }
        .padding(.horizontal, 14)
        .frame(maxWidth: .infinity, minHeight: Self.bannerHeight, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: Self.bannerRadius, style: .continuous)
                .fill(bannerBackground)
        )
        .contentShape(RoundedRectangle(cornerRadius: Self.bannerRadius, style: .continuous))
        .onTapGesture { onSelect() }
        // 长按预览钉在卡片圆角上：不钉的话 List 行的预览带整行底板，卡片像从行里
        // 浮出来（owner 2026-11-08 截图点的「脱离卡片」）.
        .contentShape(.contextMenuPreview, RoundedRectangle(cornerRadius: Self.bannerRadius, style: .continuous))
    }

    /// 图标 (60×60, r16 连续; 无图标回落虚线方块, 与 SandboxAppIconView 同形).
    private var iconView: some View {
        Group {
            if let icon {
                Image(uiImage: icon)
                    .resizable()
            } else {
                Image(systemName: "app.dashed")
                    .resizable()
                    .aspectRatio(contentMode: .fit)
                    .foregroundStyle(.tertiary)
                    .padding(11)
            }
        }
        .frame(width: 60, height: 60)
        .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
        .contentShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
    }

    /// 详情栈: 名称(16 bold) + 徽章 → 版本·BundleID(12) → 容器(11).
    /// 行距 1 (LCAppBannerView.swift:84).
    private var detailStack: some View {
        VStack(alignment: .leading, spacing: 1) {
            HStack(spacing: 8) {
                Text(app.displayName)
                    .font(.system(size: 16, weight: .bold))
                    .foregroundStyle(.primary)
                    .lineLimit(1)
                if app.isLocked && !app.isHidden {
                    lockBadge
                }
                Spacer(minLength: 0)
            }
            Text(versionLine)
                .font(.system(size: 12))
                .foregroundStyle(readableText)
                .lineLimit(1)
            Text(containerLine)
                .font(.system(size: 11))
                .foregroundStyle(readableText)
                .lineLimit(1)
        }
    }

    /// 锁徽章 (LCAppBannerBadgeView 同形: 16×16 圆角 8, 白 8pt 图标).
    private var lockBadge: some View {
        Image(systemName: "lock.fill")
            .font(.system(size: 8))
            .foregroundStyle(.white)
            .frame(width: 16, height: 16)
            .background(RoundedRectangle(cornerRadius: 8).fill(Color.orange))
            .accessibilityLabel("已锁定")
    }

    /// 「启动」胶囊 (LCAppBannerRunControl 同形: 70×32, 满色底, 白 16 bold, 长字缩放).
    private var runControl: some View {
        Button(action: onLaunch) {
            Text("启动")
                .font(.system(size: 16, weight: .bold))
                .foregroundStyle(.white)
                .lineLimit(1)
                .minimumScaleFactor(0.1)
                .frame(width: 70, height: 32)
        }
        .background(Capsule().fill(runColor))
        .contentShape(Capsule())
        .accessibilityLabel("启动 \(app.displayName)")
    }

    /// 图标主色 (LCAppBannerView.swift:177-228 同算法: 1×1 采样平均色, 暗+不饱和回落 systemRed,
    /// 亮度抬到 ≥0.3).
    private var bannerHue: Color {
        guard let cgImage = icon?.cgImage else { return AppTheme.accent }
        var pixel = [UInt8](repeating: 0, count: 4)
        let context = CGContext(
            data: &pixel, width: 1, height: 1, bitsPerComponent: 8, bytesPerRow: 4,
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        )
        context?.draw(cgImage, in: CGRect(x: 0, y: 0, width: 1, height: 1))
        let average = UIColor(
            red: CGFloat(pixel[0]) / 255, green: CGFloat(pixel[1]) / 255,
            blue: CGFloat(pixel[2]) / 255, alpha: 1
        )
        var hue: CGFloat = 0, saturation: CGFloat = 0, brightness: CGFloat = 0, alpha: CGFloat = 0
        average.getHue(&hue, saturation: &saturation, brightness: &brightness, alpha: &alpha)
        if brightness < 0.1 && saturation < 0.1 { return Color(.systemRed) }
        // 注意 SwiftUI 的 Color 是 opacity 不是 alpha (UIColor 才用 alpha, run 42483354081 实锤)
        return Color(hue: hue, saturation: saturation, brightness: max(brightness, 0.3), opacity: 1)
    }

    /// 背景 = 主色 50% (LC:159-161); 无图标或关掉动态配色回落卡片底色.
    private var bannerBackground: Color {
        (icon == nil || !bannerDynamicColors) ? AppSurface.card : bannerHue.opacity(0.5)
    }

    /// 启动钮 = 主色满色 (LC:162-167 的 accentColor 满色底).
    private var runColor: Color {
        (icon == nil || !bannerDynamicColors) ? AppTheme.accent : bannerHue
    }

    /// 可读文字色 (LC readableTextColor.swift:230-260 同算法: 主色与系统底色对半混, 按亮度 ±0.4).
    private var readableText: Color {
        var red: CGFloat = 0, green: CGFloat = 0, blue: CGFloat = 0, alpha: CGFloat = 0
        UIColor(bannerHue).getRed(&red, green: &green, blue: &blue, alpha: &alpha)
        var bgRed: CGFloat = 0, bgGreen: CGFloat = 0, bgBlue: CGFloat = 0, bgAlpha: CGFloat = 0
        UIColor.systemBackground.getRed(&bgRed, green: &bgGreen, blue: &bgBlue, alpha: &bgAlpha)
        let mixedRed = 0.5 * red + 0.5 * bgRed
        let mixedGreen = 0.5 * green + 0.5 * bgGreen
        let mixedBlue = 0.5 * blue + 0.5 * bgBlue
        let brightness = 0.2126 * mixedRed + 0.7152 * mixedGreen + 0.0722 * mixedBlue
        let offset: CGFloat = brightness < 0.5 ? 0.4 : -0.4
        return Color(
            red: min(max(mixedRed + offset, 0), 1),
            green: min(max(mixedGreen + offset, 0), 1),
            blue: min(max(mixedBlue + offset, 0), 1)
        )
    }

    /// 「容器：<名字>」或「容器：未创建」；多份时带份数 (LCAppBannerView.swift:147 同口径:
    /// 没容器写「未创建」不藏行).
    private var containerLine: String {
        guard let name = app.activeContainerName else { return "容器：未创建" }
        guard app.containers.count > 1 else { return "容器：" + name }
        return "容器：" + name + "（共 \(app.containers.count) 份）"
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
        // 详情 = LC 菜单的 per-app Settings 项（LCAppBannerViewController.swift:198-203）.
        Button {
            onSelect()
        } label: {
            Label("详情", systemImage: "info.circle")
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

// MARK: - 底栏预留槽

/// 底栏「源 / 模块」的预留页参数. 两页都还没有引擎支撑 —— 只立入口，不放假内容.
enum SandboxSlot: String, Identifiable {
    case sources
    case modules

    var id: String { rawValue }

    var title: String {
        switch self {
        case .sources: return "源"
        case .modules: return "模块"
        }
    }

    var symbol: String {
        switch self {
        case .sources: return "shippingbox"
        case .modules: return "puzzlepiece.extension"
        }
    }

    var emptyTitle: String {
        switch self {
        case .sources: return "源功能预留中"
        case .modules: return "模块功能预留中"
        }
    }

    var message: String {
        switch self {
        case .sources: return "安装源（仓库）管理页在此预留，后续版本接入."
        case .modules: return "Tweak 模块管理页在此预留，后续版本接入."
        }
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
