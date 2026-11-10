import SwiftUI
import UIKit

// 沙盒容器 · 独立底栏宿主（v0.3.784 / v0.3.801 改为 LC 原生 UI）
//
// 用户要求（2026-11-08）：「这个界面底栏自己独立一个，不要用默认界面的底栏了」.
// 主页入口因此从 NavigationLink 改成 fullScreenCover（与 RootView:75-80 承载模块同一手段）——
// push 进同一条 NavigationStack 时底部仍是主 App 的 TabBar，只有整屏覆盖才盖得住.
//
// v0.3.801 用户要求（2026-11-10）：「沙盒容器我说清楚 简直是一坨屎… 我让你移植过来
// 你不要自己自创了」—— 因此本页**不再渲染自创的 SandboxContainerView**，
// 改为直接承载 LC 上游原生 UI（LCTabView → LCAppListView / LCSettingsView / LCTweaksView），
// 容器根已对齐 `Documents/`（与 `LCPath.docPath` 同源），所以 LC 的列表天然看得见访客 App.

/// 沙盒容器整屏宿主：承载 LC 原生 UI.
///
/// **不要**在外面再包 NavigationStack —— 上游 `LiveContainerSwiftUIApp.body` 是直接
/// `LCTabView()` 当根（App/LiveContainerSwiftUIApp.swift:105-108），而 LCTabView 内部
/// 自己用 `NavigationView`（Views/LCTabView.swift:64）。两层导航叠加会导致
/// 子页返回按钮层级错乱（真机实测「返回上一级」行为异常）。
struct SandboxHostView: View {
    var body: some View {
        LCUIHostView()
            .ignoresSafeArea(edges: .bottom)
    }
}

/// LC 原生 UI 的宿主包装.
///
/// 走 `NSClassFromString("TDLCUIHost")` 反射：宿主不能 `import LiveContainerSwiftUI`
/// （会与宿主桥接头重复定义枚举，CI run 42657238035 实测），而 `LCTabView` 是 SwiftUI View，
/// 不能用 `@_silgen_name`。反射拿不到就显示明确说明，不留空白页。
struct LCUIHostView: View {
    var body: some View {
        if let controller = Self.makeController() {
            LCUIViewControllerView(controller: controller)
        } else {
            ContentUnavailableView(
                "沙盒容器不可用",
                systemImage: "exclamationmark.triangle",
                description: Text("LiveContainerSwiftUI framework 未链接到本构建")
            )
        }
    }

    private static func makeController() -> UIViewController? {
        guard let cls = NSClassFromString("TDLCUIHost") as? NSObject.Type else { return nil }
        let sel = NSSelectorFromString("makeTabViewController")
        guard cls.responds(to: sel),
              let value = cls.perform(sel)?.takeUnretainedValue() as? UIViewController else {
            return nil
        }
        return value
    }
}

/// UIViewController 承载（UIKit 生命周期交给 controller 自己）.
private struct LCUIViewControllerView: UIViewControllerRepresentable {
    let controller: UIViewController

    func makeUIViewController(context: Context) -> UIViewController {
        controller
    }

    func updateUIViewController(_ uiViewController: UIViewController, context: Context) {}
}

/// 玻璃丸里的一格：图标着色 + 主色小标签.
///
/// 独立成类型是为了让两个底栏的 body 各自只是一次属性引用 ——
/// 本仓 CI 已四次实证「视图构造 + 多层修饰」堆在同一条 body 里会
/// `unable to type-check this expression in reasonable time`.
struct SandboxBarCell: View {
    let title: String
    let symbol: String
    var tint: Color = AppTheme.accent
    var disabled: Bool = false
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            VStack(spacing: 4) {
                Image(systemName: symbol)
                    .font(.system(size: 17, weight: .medium))
                    .foregroundStyle(tint)
                    .frame(height: 21)
                Text(title)
                    .font(AppFont.tabLabel)
                    .foregroundStyle(.primary)
                    .lineLimit(1)
            }
            .frame(maxWidth: .infinity)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .appPressable(scale: 0.94)
        .disabled(disabled)
        .opacity(disabled ? 0.4 : 1)
    }
}


/// 悬浮玻璃丸容器：横向等分的若干 `SandboxBarCell`，中间用发丝分隔.
///
/// 用 `safeAreaInset(edge: .bottom)` 挂在页面底部 —— 这样列表内容会自动避让，
/// 不会再出现「说明文字被底栏盖住一半」（真机截图病点）.
struct SandboxFloatingBar<Cells: View>: View {
    @Environment(\.colorScheme) private var colorScheme
    @ViewBuilder var cells: Cells

    var body: some View {
        bar
    }

    /// 单独抽出来：body 只剩一次属性引用，避免整条修饰链进类型推断爆炸区（本仓 CI 已四次实证）.
    private var bar: some View {
        HStack(spacing: 0) {
            cells
        }
        .padding(.vertical, 9)
        .padding(.horizontal, 10)
        .appGlassCapsule()
        .overlay(Capsule().strokeBorder(AppSurface.cardBorder, lineWidth: 0.5))
        .appRaisedShadow(colorScheme)
        .padding(.horizontal, AppTheme.pageInset)
        .padding(.bottom, 6)
    }
}

/// 底栏分隔发丝（竖向）.
struct SandboxBarDivider: View {
    var body: some View {
        Rectangle()
            .fill(AppSurface.cardBorder)
            .frame(width: 0.5, height: 26)
    }
}
