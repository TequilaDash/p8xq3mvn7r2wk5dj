import SwiftUI
import UIKit

// 沙盒容器 · 独立底栏宿主（v0.3.784）
//
// 用户要求（2026-11-08）：「这个界面底栏自己独立一个，不要用默认界面的底栏了」.
// 主页入口因此从 NavigationLink 改成 fullScreenCover（与 RootView:75-80 承载模块同一手段）——
// push 进同一条 NavigationStack 时底部仍是主 App 的 TabBar，只有整屏覆盖才盖得住.
//
// 底栏形态照参考图（PiliPlus「应用信息」）：屏幕底部一颗悬浮玻璃丸，
// 内含「图标 + 10pt 标签」等分列，图标着色、文字一律主色（不做彩色文字）.

/// 沙盒容器整屏宿主：自带导航栈，容器页与详情页都在这条栈里走.
struct SandboxHostView: View {
    var body: some View {
        NavigationStack {
            SandboxContainerView()
        }
    }
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

