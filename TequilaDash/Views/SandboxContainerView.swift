import SwiftUI
import UIKit
import UniformTypeIdentifiers

// LC 多任务虚拟窗口入口. 不用 `import LiveContainerSwiftUI`: 主 App 导入该模块会把 framework 的
// ObjC 头拉进同一翻译单元, 与已有桥接头重复定义枚举 (LCUtils.h 的 Unknown / LCAppInfo.h 的
// Disabled, CI run 42657238035 实测). 走纯 C 符号, house rule 同 TDLaunchGuestRestart.
// 返回 1 = 已建窗, 0 = 无宿主 rootVC / 控制器初始化失败.
@_silgen_name("TDMultitaskOpenVirtualWindow")
func TDMultitaskOpenVirtualWindow(_ displayName: NSString, _ bundleId: NSString, _ dataUUID: NSString) -> Int32

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
                // 用户点「重签包体」= 明确要求重签, 强制走完整签名（不套用启动前的跳过判断）.
                return (true, try SandboxResigner.resign(app, force: true).summary)
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
    /// LC dynamicColors 键: 关掉时横幅回落卡片底色 (设置页「界面」节真连线).
    @AppStorage("dynamicColors") var bannerDynamicColors = true

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
        if let containerUUID = app.activeContainer {
            // LC 同款多任务入口 (虚拟窗口路径): 内部用 LC 默认模式的
            // DecoratedAppSceneViewController 手工建窗, 不依赖 SwiftUI openWindow/WindowGroup.
            Button {
                let opened = TDMultitaskOpenVirtualWindow(app.displayName as NSString,
                                                          app.id as NSString,
                                                          containerUUID as NSString) != 0
                if !opened {
                    ToastCenter.shared.show("虚拟窗口启动失败", seconds: 3.0)
                }
            } label: {
                Label("在新窗口打开", systemImage: "rectangle.on.rectangle")
            }
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
