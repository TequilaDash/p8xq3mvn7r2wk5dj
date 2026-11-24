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
//    2. 旧线 MultitaskStackManager.shared.present() —— test2 还没有堆叠后台
//       这个类（后面要接过来）。双击**保留**，走 onDoublePress 回调，
//       接堆叠后台时只需在引用点赋值，本文件不用改。
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
    /// 是否启用全局悬浮键。
    static let enabledKey = "iManagerAssistiveTouchEnabled"
    /// 按钮中心的归一化位置（0...1，相对屏幕宽高）。
    static let positionXKey = "iManagerAssistiveTouchX"
    static let positionYKey = "iManagerAssistiveTouchY"
    /// 空闲淡化后的不透明度。
    static let idleAlphaKey = "iManagerAssistiveTouchIdleAlpha"
    /// 默认值：右下偏上，与 iOS 辅助触控的初始位置接近。
    static let defaultX = 0.88
    static let defaultY = 0.62
    static let defaultIdleAlpha = 0.4
    /// 按钮尺寸，与上游 HomeDesign.homeButtonSize 一致（52pt）。
    static let buttonSize: CGFloat = 52
    /// 空闲多久开始淡化。
    static let idleDelay: TimeInterval = 3

    /// 当前是否启用，供别的页面显示状态。
    static var isEnabled: Bool {
        LCUtils.appGroupUserDefault.bool(forKey: enabledKey)
    }
}

// MARK: - 悬浮按钮

/// 画在悬浮窗里的按钮本身：直接用上游的 HomeButton，只外加拖动、淡化和定位。
/// 不自己画圆——上游 HomeButton 已有正确的玻璃、双环和按压反馈，自绘会与
/// 主屏上那个按钮长得不一样。
private struct IManagerAssistiveTouchButton: View {
    /// 单击时执行。
    let action: () -> Void
    /// 双击时执行（旧线是进多任务堆叠；test2 的堆叠后台接进来后在此赋值）。
    let doubleAction: () -> Void
    /// 归一化位置，双向绑定，拖动后写回。
    @Binding var position: CGPoint
    /// 空闲淡化后的不透明度。
    let idleAlpha: Double
    @State private var dimmed = false
    @State private var dimGeneration = 0
    @State private var dragStart: CGPoint?

    var body: some View {
        GeometryReader { proxy in
            let size = HomeDesign.homeButtonSize
            // 留出半个按钮的边距，按钮永远不会被裁掉一半。
            let margin = size / 2 + 6
            let usableWidth = max(proxy.size.width - margin * 2, 1)
            let usableHeight = max(proxy.size.height - margin * 2, 1)

            let center = CGPoint(
                x: margin + min(max(position.x, 0), 1) * usableWidth,
                y: margin + min(max(position.y, 0), 1) * usableHeight
            )

            HomeButton(action: {
                undim()
                action()
            })
            // 与旧线完全一致的修饰符顺序（顺序错了界面就点不动）：
            //   手势 → background 占位视图 → position → opacity → 拖动手势
            // 手势和 background 必须在 position 之前，否则作用在撑满父容器的
            // 视图上；拖动放最后但必须是 simultaneousGesture，不能抢占触摸。
            .highPriorityGesture(
                TapGesture(count: 2)
                    .exclusively(before: TapGesture(count: 1))
                    .onEnded { tap in
                        switch tap {
                        case .first(_):
                            // 双击：进多任务堆叠（旧线 MultitaskStackManager.present）。
                            undim()
                            doubleAction()
                        case .second(_):
                            // 单击：回主屏（旧线 action()）。
                            undim()
                            action()
                        }
                    }
            )
            .background(IManagerHitRegion())
            .position(center)
            .opacity(dimmed ? max(0.15, min(1, idleAlpha)) : 1)
            .animation(.easeOut(duration: 0.35), value: dimmed)
            .simultaneousGesture(
                DragGesture(minimumDistance: 6)
                    .onChanged { value in
                        if dragStart == nil {
                            dragStart = position
                            undim()
                        }
                        guard let base = dragStart else { return }
                        let dx = value.translation.width / usableWidth
                        let dy = value.translation.height / usableHeight
                        position = CGPoint(
                            x: min(max(base.x + dx, 0), 1),
                            y: min(max(base.y + dy, 0), 1)
                        )
                    }
                    .onEnded { _ in
                        dragStart = nil
                        scheduleDim()
                    }
            )
            .onAppear(perform: scheduleDim)
        }
    }

    private func undim() {
        dimGeneration += 1
        dimmed = false
    }

    private func scheduleDim() {
        dimGeneration += 1
        let generation = dimGeneration
        dimmed = false
        DispatchQueue.main.asyncAfter(deadline: .now() + IManagerAssistiveTouch.idleDelay) {
            guard generation == dimGeneration else { return }
            dimmed = true
        }
    }
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
    /// 双击按钮要做什么。旧线是进多任务堆叠；test2 的堆叠后台接进来后
    /// 在引用点赋 MultitaskStackManager.shared.present 即可，本文件不用改。
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
    }

    /// 按当前设置决定显示还是隐藏悬浮窗。可重复调用。
    func attach() {
        let defaults = LCUtils.appGroupUserDefault
        guard defaults.bool(forKey: IManagerAssistiveTouch.enabledKey) else {
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
            if #available(iOS 16.0, *) {
                MultitaskDockManager.shared.minimizeAllWindows()
            }
            self?.onPress?()
        }, onDoublePress: { [weak self] in
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
            idleAlpha: idleAlpha
        )
        .background(Color.clear)
    }
}

// MARK: - 设置界面

/// 「辅助触控」设置页。
struct IManagerAssistiveTouchPage: View {
    @AppStorage(IManagerAssistiveTouch.enabledKey, store: LCUtils.appGroupUserDefault)
    private var isEnabled = false
    @AppStorage(IManagerAssistiveTouch.idleAlphaKey, store: LCUtils.appGroupUserDefault)
    private var idleAlpha = IManagerAssistiveTouch.defaultIdleAlpha
    @AppStorage(IManagerAssistiveTouch.positionXKey, store: LCUtils.appGroupUserDefault)
    private var savedX = IManagerAssistiveTouch.defaultX
    @AppStorage(IManagerAssistiveTouch.positionYKey, store: LCUtils.appGroupUserDefault)
    private var savedY = IManagerAssistiveTouch.defaultY

    var body: some View {
        List {
            Section {
                Toggle("启用辅助触控", isOn: $isEnabled)
                    .onChange(of: isEnabled) { _, _ in
                        IManagerAssistiveTouchController.shared.settingsChanged()
                    }
            } footer: {
                Text("在主屏、设置和访客应用里始终显示一个可拖动的圆形按钮，单击回到 zContainer 主界面。")
                    .font(.footnote)
            }

            if isEnabled {
                Section {
                    VStack(alignment: .leading, spacing: 6) {
                        HStack {
                            Text("空闲淡化")
                            Spacer()
                            Text("\(Int((idleAlpha * 100).rounded()))%")
                                .foregroundStyle(.secondary)
                                .monospacedDigit()
                        }
                        Slider(value: $idleAlpha, in: 0.15...1.0, step: 0.05)
                    }
                } footer: {
                    Text("空闲 \(Int(IManagerAssistiveTouch.idleDelay)) 秒后按钮会变淡；这里是变淡后的不透明度。")
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
        .navigationTitle("辅助触控")
        .navigationBarTitleDisplayMode(.inline)
    }
}
