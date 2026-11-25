//
//  iManagerAssistiveTouch.swift
//  iManager — zcontainer-test2 源码块
//
//  「辅助触控」：全局悬浮 Home 键的宿主侧实现 + 设置界面。
//
//  【为什么要自己实现】上游只在特定位置画 Home 键（主屏、搜索结果、设置侧栏、
//  访客应用内），没有任何"始终显示、可拖动"的全局按钮。上游那套开关
//  （LCShowHomeButtonInApps）只决定"应用内显示"，开了也没有全局可拖按钮，
//  所以用户开了"没有用"。
//
//  【与旧线 TDAssistiveTouch 的关系：按旧线行为移植，适配 test2 的 API】
//  旧线（Zcontainer 分支 46f4b5aa 的 AppRootView.swift）里那套行为：
//    单击回主屏、双击进多任务、拖动改位置、空闲淡化、只盖按钮区域。
//  移植到 test2 时逐项核对过依赖，只有两处需要适配：
//    1. 旧线 HomeButton(action:showsGlass:) —— test2 的 HomeButton 只有 action 参数，
//       玻璃效果由 homeButtonGlass() 内部固定，不需要参数。
//    2. 旧线 MultitaskStackManager.shared.present() —— 堆叠后台已从旧线移植
//       （iManager/MultitaskStackView.swift），双击直接调用它。
//  其余依赖 test2 都有：MultitaskDockManager.shared.minimizeAllWindows(except:)、
//  HomeDesign.homeButtonSize、HomeScreenModel.goHome()。
//
//  旧线两个自身缺陷，本块不重复：
//    a. 它监听 UIWindow.didBecomeVisibleNotification 来重挂窗口，而它自己显示
//       窗口又会发同一个通知 —— 靠 `if note.object is TDHostHomeOverlayWindow`
//       挡递归，但窗口重建期间这个判断不成立，仍可能自我触发。
//    b. 它把按钮位置存成"相对右上角的偏移"，坐标原点跟着按钮默认位置变，
//       老存档需要 `hasSavedPlacement` 分支兼容。
//
//  【本块做法】
//    · 只监听真正需要的三个通知：scene 激活、scene 断开、进后台；
//      显示窗口时不发这些通知，天然没有递归。
//    · 位置存**归一化比例**（0...1），换机型、转屏都不跑偏，也不需要兼容分支。
//    · 按钮用上游 HomeButton，外观与主屏上那个完全一致（不自己画圆）。
//    · 单击 = 回主屏并最小化多任务窗口（同旧线 lcHostHomePressed 的效果）。
//    · 拖动可改位置；空闲 3 秒淡化，点一下恢复。
//    · 窗口 hitTest 只让按钮区域接收触摸，其余全部穿透，所以能盖在 alert 之上
//      而不挡它。
//
//  【引用点】LiveContainerSwiftUI/App/AppRootView.swift 两行：
//      .onAppear { IManagerAssistiveTouchController.shared.attach() }
//      并在设置页里打开 IManagerAssistiveTouchPage
//  上游 AppRootView 不持有本块的任何状态。
//

import SwiftUI
import UIKit

// MARK: - 偏好键

/// 辅助触控的偏好键。全部存在 app group，宿主与访客都能读。
enum IManagerAssistiveTouch {
    /// 显示模式，与旧线 TDAssistiveTouchMode 同义：
    ///   "default" = 保持现状（沿用上游 LCShowHomeButtonInApps 与每 App 开关）
    ///   "always"  = 始终显示（任何界面都显示同一个可拖动按钮）
    static let modeKey = "iManagerAssistiveTouchMode"
    static let modeDefault = "default"
    static let modeAlways = "always"
    /// 按钮中心的归一化位置（0...1，相对屏幕宽高）。
    static let positionXKey = "iManagerAssistiveTouchX"
    static let positionYKey = "iManagerAssistiveTouchY"
    /// 空闲淡化后的不透明度。
    static let idleAlphaKey = "iManagerAssistiveTouchIdleAlpha"
    /// 是否启用空闲淡化。
    static let idleDimKey = "iManagerAssistiveTouchIdleDim"
    /// 默认值：右下偏上，与 iOS 辅助触控的初始位置接近。
    static let defaultX = 0.88
    static let defaultY = 0.62
    static let defaultIdleAlpha = 0.4
    /// 按钮尺寸，与上游 HomeDesign.homeButtonSize 一致（52pt）。
    static let buttonSize: CGFloat = 52
    /// 空闲多久开始淡化。
    static let idleDelay: TimeInterval = 3

    /// 当前是否处于"始终显示"模式，供别的页面显示状态。
    static var isAlwaysOn: Bool {
        (LCUtils.appGroupUserDefault.string(forKey: modeKey) ?? modeDefault) == modeAlways
    }
}

// MARK: - 悬浮按钮

/// 画在悬浮窗里的按钮本身。
/// 结构与旧线 TDGlobalHomeOverlay 完全一致：
///   · HomeButton 的 action 传**空**，单击由 TapGesture 处理 ——
///     否则 Button 自己在抬手时就触发，拖动也会回主屏（这是之前一直修不好的根因）。
///   · TapGesture 在手指移动超过阈值时会自动失败，所以拖动不会触发单击。
///   · scheduleDim / onChange 挂在外层 GeometryReader 上，与旧线同位置。
private struct IManagerAssistiveTouchButton: View {
    /// 单击时执行。
    let action: () -> Void
    /// 双击时执行（旧线是进多任务堆叠；堆叠后台接进来后在此赋值）。
    let doubleAction: () -> Void
    /// 归一化位置，双向绑定，拖动后写回。
    @Binding var position: CGPoint
    /// 空闲淡化后的不透明度。
    let idleAlpha: Double
    /// 是否启用空闲淡化。关闭时按钮永远全不透明。
    let idleDim: Bool

    @State private var dimmed = false
    @State private var dimGeneration = 0
    @State private var dragStart: CGPoint?

    var body: some View {
        GeometryReader { proxy in
            let size = HomeDesign.homeButtonSize
            let margin = size / 2 + 6
            let usableWidth = max(proxy.size.width - margin * 2, 1)
            let usableHeight = max(proxy.size.height - margin * 2, 1)

            let center = CGPoint(
                x: margin + min(max(position.x, 0), 1) * usableWidth,
                y: margin + min(max(position.y, 0), 1) * usableHeight
            )

            HomeButton(action: {})
                .highPriorityGesture(
                    TapGesture(count: 2)
                        .exclusively(before: TapGesture(count: 1))
                        .onEnded { tap in
                            switch tap {
                            case .first(_):
                                // 双击：进多任务堆叠。
                                doubleAction()
                                scheduleDim()
                            case .second(_):
                                // 单击：回主屏。
                                action()
                                scheduleDim()
                            }
                        }
                )
                .accessibilityAction {
                    action()
                    scheduleDim()
                }
                .background(IManagerHitRegion())
                .position(center)
                .opacity(dimmed && idleDim ? max(0.15, min(1.0, idleAlpha)) : 1)
                .simultaneousGesture(
                    DragGesture(minimumDistance: 4)
                        .onChanged { value in
                            if dragStart == nil {
                                dragStart = position
                                dimmed = false
                            }
                            guard let base = dragStart else { return }
                            position = CGPoint(
                                x: min(max(base.x + value.translation.width / usableWidth, 0), 1),
                                y: min(max(base.y + value.translation.height / usableHeight, 0), 1)
                            )
                        }
                        .onEnded { _ in
                            dragStart = nil
                            scheduleDim()
                        }
                )
        }
        // 与旧线同位置：scheduleDim 与三个 onChange 挂在外层。
        .onAppear(perform: scheduleDim)
        .onChange(of: idleDim) { _, _ in scheduleDim() }
        .onChange(of: idleAlpha) { _, _ in scheduleDim() }
    }

    private func scheduleDim() {
        dimGeneration += 1
        let generation = dimGeneration
        dimmed = false
        guard idleDim else { return }
        DispatchQueue.main.asyncAfter(deadline: .now() + IManagerAssistiveTouch.idleDelay) {
            guard generation == dimGeneration else { return }
            dimmed = true
        }
    }
}

extension Notification.Name {
    /// 辅助触控设置改变（同进程内）。
    static let iManagerAssistiveTouchSettingsChanged = Notification.Name("iManagerAssistiveTouchSettingsChanged")
}

// MARK: - 悬浮窗

/// 只在按钮区域接收触摸，其余区域完全穿透的窗口。
/// 这样它能盖在 alert 之上，又不会挡住 alert 自己的按钮。
private final class IManagerAssistiveTouchWindow: UIWindow {
    /// 按钮那块区域，由 IManagerHitRegion 在布局时回写（旧线做法）。
    weak var buttonRegion: UIView?

    override var canBecomeKey: Bool { false }

    /// 这个透明窗口不能影响状态栏的几何与样式。
    @objc(_canAffectStatusBarAppearance)
    func iManagerCanAffectStatusBarAppearance() -> Bool { false }

    override func hitTest(_ point: CGPoint, with event: UIEvent?) -> UIView? {
        // 命中时再换算，拖动时 SwiftUI 祖先移动、这块标记自己没重新布局，
        // 缓存的矩形会滞后（旧线踩过）。
        guard let region = buttonRegion, region.window === self,
              region.bounds.contains(region.convert(point, from: self)) else { return nil }
        return super.hitTest(point, with: event)
    }
}

/// 旧线 TDOverlayHitRegion 的同款：一个不接收触摸的占位视图，
/// 布局到哪就把自己交给窗口当命中区域，其余区域窗口一律穿透。
private struct IManagerHitRegion: UIViewRepresentable {
    func makeUIView(context: Context) -> UIView {
        let view = RegionView()
        view.isUserInteractionEnabled = false
        view.backgroundColor = .clear
        return view
    }

    func updateUIView(_ view: UIView, context: Context) {}

    static func dismantleUIView(_ view: UIView, coordinator: ()) {
        (view as? RegionView)?.clearInteractiveRegion()
    }

    private final class RegionView: UIView {
        weak var overlayWindow: IManagerAssistiveTouchWindow?

        override func didMoveToWindow() {
            super.didMoveToWindow()
            clearInteractiveRegion()
            overlayWindow = window as? IManagerAssistiveTouchWindow
            overlayWindow?.buttonRegion = self
        }

        func clearInteractiveRegion() {
            if overlayWindow?.buttonRegion === self {
                overlayWindow?.buttonRegion = nil
            }
            overlayWindow = nil
        }
    }
}

// MARK: - 控制器

/// 管理那个唯一的悬浮窗：跟随前台场景，场景消失就藏起来。
@MainActor
final class IManagerAssistiveTouchController {
    static let shared = IManagerAssistiveTouchController()

    private var window: IManagerAssistiveTouchWindow?
    private var observers: [NSObjectProtocol] = []
    /// 单击按钮要做什么，由引用点设置（通常是回主屏）。
    var onPress: (() -> Void)?
    /// 双击按钮的额外动作。堆叠后台已接（双击直接 present），这里留给调用方扩展。
    var onDoublePress: (() -> Void)?

    private init() {
        let center = NotificationCenter.default
        // 只监听这三种。显示自己的窗口不会发它们，所以不存在自我触发。
        for name in [
            UIScene.didActivateNotification,
            UIScene.didDisconnectNotification,
            UIScene.didEnterBackgroundNotification,
        ] {
            observers.append(center.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.attach() }
            })
        }
        // 设置页改完值后发一个本地通知，让悬浮窗重建 rootView，
        // 否则窗口里的 @AppStorage 可能拿不到最新值（旧线用 CFNotificationCenter 做同一件事）。
        observers.append(center.addObserver(forName: .iManagerAssistiveTouchSettingsChanged,
                                            object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.rebuildRootView() }
        })
    }

    /// 重建悬浮窗里的 SwiftUI 树，让 @AppStorage 读到最新设置。
    private func rebuildRootView() {
        guard let overlay = window else { return }
        LCUtils.appGroupUserDefault.synchronize()
        let host = UIHostingController(rootView: AnyView(rootView()))
        host.view.backgroundColor = .clear
        host.view.isOpaque = false
        overlay.rootViewController = host
    }

    /// 按当前设置决定显示还是隐藏悬浮窗。可重复调用。
    func attach() {
        let defaults = LCUtils.appGroupUserDefault
        let mode = defaults.string(forKey: IManagerAssistiveTouch.modeKey) ?? IManagerAssistiveTouch.modeDefault
        // 只有"始终显示"才挂全局悬浮窗；"保持现状"沿用上游各处自己的按钮。
        guard mode == IManagerAssistiveTouch.modeAlways else {
            window?.isHidden = true
            return
        }

        let scenes = UIApplication.shared.connectedScenes
            .compactMap { $0 as? UIWindowScene }
            .filter { $0.session.role == .windowApplication }

        // 只跟一个前台场景走。找不到合适的场景就藏起来，绝不为多场景再开一个窗。
        guard let scene = scenes.first(where: { $0.activationState == .foregroundActive })
                ?? scenes.first(where: { $0.activationState == .foregroundInactive }),
              !scene.coordinateSpace.bounds.isEmpty,
              scene.windows.contains(where: {
                  !($0 is IManagerAssistiveTouchWindow) && !$0.isHidden &&
                  $0.windowLevel == .normal && $0.rootViewController != nil
              })
        else {
            window?.isHidden = true
            return
        }

        if let existing = window {
            if existing.windowScene !== scene { existing.windowScene = scene }
            existing.frame = scene.coordinateSpace.bounds
            existing.windowLevel = overlayLevel(in: scene)
            existing.isHidden = false
            return
        }

        let overlay = IManagerAssistiveTouchWindow(windowScene: scene)
        overlay.frame = scene.coordinateSpace.bounds
        overlay.windowLevel = overlayLevel(in: scene)
        overlay.backgroundColor = .clear
        // UIHostingController 的 view 默认是不透明白底；只清 window 的
        // backgroundColor 不够，必须连 host.view 一起清，否则整个屏幕被
        // 一块白板盖住，只露出按钮。
        let host = UIHostingController(rootView: AnyView(rootView()))
        host.view.backgroundColor = .clear
        host.view.isOpaque = false
        overlay.rootViewController = host
        // 先持有再显示：窗口可见性回调可能是同步的。
        window = overlay
        overlay.isHidden = false
    }

    /// 设置页改了开关后调用。
    func settingsChanged() {
        LCUtils.appGroupUserDefault.synchronize()
        NotificationCenter.default.post(name: .iManagerAssistiveTouchSettingsChanged, object: nil)
        attach()
    }

    private func overlayLevel(in scene: UIWindowScene) -> UIWindow.Level {
        let highest = scene.windows
            .filter { !($0 is IManagerAssistiveTouchWindow) && !$0.isHidden && $0.alpha > 0 && $0.rootViewController != nil }
            .map { $0.windowLevel.rawValue }
            .max() ?? UIWindow.Level.normal.rawValue
        // 盖在 alert 之上，但因为 hitTest 只认按钮区域，不会挡住 alert。
        return UIWindow.Level(rawValue: max(UIWindow.Level.alert.rawValue + 2, highest + 1))
    }

    private func rootView() -> some View {
        IManagerAssistiveTouchRoot(onPress: { [weak self] in
            // 同旧线 lcHostHomePressed：先把多任务窗口收起来，再回主屏。
            // 最近任务的 deck 是独立窗口，必须先拆掉，否则它继续盖着主屏，
            // 表现就是"点了辅助触控什么也没发生"。
            MultitaskStackManager.shared.dismissDeckForHome()
            if #available(iOS 16.0, *) {
                MultitaskDockManager.shared.minimizeAllWindows()
            }
            self?.onPress?()
        }, onDoublePress: { [weak self] in
            // 双击：打开最近任务（旧线 MultitaskStackManager.shared.present()）。
            MultitaskStackManager.shared.present()
            self?.onDoublePress?()
        })
    }
}

/// 悬浮窗里的根视图：读设置、画按钮、回写位置。
private struct IManagerAssistiveTouchRoot: View {
    let onPress: () -> Void
    let onDoublePress: () -> Void

    @AppStorage(IManagerAssistiveTouch.positionXKey, store: LCUtils.appGroupUserDefault)
    private var savedX = IManagerAssistiveTouch.defaultX
    @AppStorage(IManagerAssistiveTouch.positionYKey, store: LCUtils.appGroupUserDefault)
    private var savedY = IManagerAssistiveTouch.defaultY
    @AppStorage(IManagerAssistiveTouch.idleAlphaKey, store: LCUtils.appGroupUserDefault)
    private var idleAlpha = IManagerAssistiveTouch.defaultIdleAlpha
    @AppStorage(IManagerAssistiveTouch.idleDimKey, store: LCUtils.appGroupUserDefault)
    private var idleDim = true

    var body: some View {
        IManagerAssistiveTouchButton(
            action: onPress,
            doubleAction: onDoublePress,
            position: Binding(
                get: { CGPoint(x: savedX, y: savedY) },
                set: { newValue in
                    savedX = newValue.x
                    savedY = newValue.y
                }
            ),
            idleAlpha: idleAlpha,
            idleDim: idleDim
        )
        .background(Color.clear)
    }
}

// MARK: - 设置界面

/// 「辅助触控」设置页。照旧线 TDAssistiveTouchSettingsView 的功能做：
/// 模式选择（保持现状 / 始终显示）、空闲淡化开关与程度、复位位置。
struct IManagerAssistiveTouchPage: View {
    @AppStorage(IManagerAssistiveTouch.modeKey, store: LCUtils.appGroupUserDefault)
    private var mode = IManagerAssistiveTouch.modeDefault
    @AppStorage(IManagerAssistiveTouch.idleAlphaKey, store: LCUtils.appGroupUserDefault)
    private var idleAlpha = IManagerAssistiveTouch.defaultIdleAlpha
    @AppStorage(IManagerAssistiveTouch.idleDimKey, store: LCUtils.appGroupUserDefault)
    private var idleDim = true
    @AppStorage(IManagerAssistiveTouch.positionXKey, store: LCUtils.appGroupUserDefault)
    private var savedX = IManagerAssistiveTouch.defaultX
    @AppStorage(IManagerAssistiveTouch.positionYKey, store: LCUtils.appGroupUserDefault)
    private var savedY = IManagerAssistiveTouch.defaultY

    var body: some View {
        List {
            Section {
                previewCard
                    .listRowInsets(EdgeInsets())
                    .listRowBackground(Color.clear)
            }

            Section {
                Picker("显示方式", selection: $mode) {
                    Text("保持现状").tag(IManagerAssistiveTouch.modeDefault)
                    Text("始终显示").tag(IManagerAssistiveTouch.modeAlways)
                }
                .pickerStyle(.inline)
                .labelsHidden()
            } footer: {
                Text("保持现状：沿用「外观 → 应用内显示主屏按键」和每个 App 自己的开关，行为与加入本页前一致。始终显示：任何界面、包括桌面都显示同一个可拖动的辅助触控按钮，单击返回 zContainer 主界面。")
                    .font(.footnote)
            }

            if mode == IManagerAssistiveTouch.modeAlways {
                Section {
                    Toggle("空闲时淡化", isOn: $idleDim)
                    if idleDim {
                        VStack(alignment: .leading, spacing: 6) {
                            HStack {
                                Text("淡化程度")
                                Spacer()
                                Text("\(Int((idleAlpha * 100).rounded()))%")
                                    .foregroundStyle(.secondary)
                                    .monospacedDigit()
                            }
                            Slider(value: $idleAlpha, in: 0.15...1.0, step: 0.05)
                        }
                    }
                } footer: {
                    Text("空闲 \(Int(IManagerAssistiveTouch.idleDelay)) 秒后按钮会变淡；这里的百分比是变淡后的不透明度。关闭后按钮始终保持全不透明。")
                        .font(.footnote)
                }

                Section {
                    Button("复位按钮位置") {
                        savedX = IManagerAssistiveTouch.defaultX
                        savedY = IManagerAssistiveTouch.defaultY
                    }
                } footer: {
                    Text("也可以直接拖动屏幕上的按钮改位置，位置会被记住。")
                        .font(.footnote)
                }
            }
        }
        .listStyle(.insetGrouped)
        .navigationTitle("辅助触控")
        .navigationBarTitleDisplayMode(.inline)
        .onChange(of: mode) { _, _ in
            IManagerAssistiveTouchController.shared.settingsChanged()
        }
        .onChange(of: idleDim) { _, _ in
            IManagerAssistiveTouchController.shared.settingsChanged()
        }
        .onChange(of: idleAlpha) { _, _ in
            IManagerAssistiveTouchController.shared.settingsChanged()
        }
    }

    /// 按当前设置画一个示意按钮，让选项的效果立刻看得见。
    private var previewCard: some View {
        VStack(spacing: 10) {
            ZStack {
                Circle()
                    .fill(.ultraThinMaterial)
                    .overlay { Circle().fill(Color.black.opacity(0.38)) }
                    .overlay { Circle().strokeBorder(Color.white.opacity(0.28), lineWidth: 1) }
                    .overlay {
                        Circle()
                            .strokeBorder(Color.white.opacity(0.88), lineWidth: HomeDesign.homeButtonSize * 0.045)
                            .frame(width: HomeDesign.homeButtonSize * 0.54, height: HomeDesign.homeButtonSize * 0.54)
                    }
                    .frame(width: HomeDesign.homeButtonSize, height: HomeDesign.homeButtonSize)
            }
            .frame(height: HomeDesign.homeButtonSize + 12)

            Text("示意：实际按钮画在屏幕上，外观与主屏 Home 键一致")
                .font(.caption2)
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 8)
    }
}
