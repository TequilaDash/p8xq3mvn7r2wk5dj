//
//  iManagerAssistiveTouch.swift
//  iManager — zcontainer-test2 源码块
//
//  iManager 设置页的「辅助触控」二级界面。
//
//  【为什么不照抄旧线】旧线 TDAssistiveTouchSettingsView 有自己的模式开关
//  （TDAssistiveTouchMode = default/always）、自己的空闲淡化参数、以及配套的
//  宿主悬浮窗实现。那套东西有三个问题，直接搬会带进 test2：
//
//    1. 它和上游已有的开关**重叠**：上游 AppearanceSettingsView 有
//       "LCShowHomeButtonInApps"（外观 → 应用内显示主屏按键），每 App 还有
//       自己的 uiShowsHomeButton。旧线那个 "always" 模式会盖过这两层，
//       导致用户在别处关了、这里又强行显示 —— 状态互相打架。
//    2. 它依赖自己的宿主悬浮窗（旧的 TDAssistiveTouch 实现），而 test2 的
//       上游已经有完整的 HomeButton + HomeEdgeButton + SettingsSidebarHomeButton
//       一套；再挂一套窗口会出现两个按钮。
//    3. 它的偏好键写在 app group 里但只有旧线读，搬到 test2 后是死键。
//
//  【本块做法】只做**上游已有能力的设置界面**，不新增渲染路径：
//    · 复用上游的 "LCShowHomeButtonInApps"（同一个 AppStorage 键，改这里
//      等于改上游那一项，不会打架）；
//    · 加一个"按钮大小"滑杆，写入 iManager 自己的键，由本块提供给上游
//      HomeDesign.homeButtonSize 使用（见 iManagerHomeButtonSize）；
//    · 其余（每 App 开关、iPad 边位）沿用上游，本页只做只读说明。
//
//  【依赖】上游 SharedModel.isPhone、LCUtils.appGroupUserDefault、
//  HomeDesign.homeButtonSize（由引用点读取本块的值）。
//

import SwiftUI

/// iManager 提供的 Home 键尺寸覆盖值。
/// 上游 HomeDesign.homeButtonSize 是 `static let 52.0`，本块不改它的定义，
/// 而是在引用点改成 `iManagerHomeButtonSize`（读这个键，缺省就是 52）。
enum IManagerHomeButton {
    /// 与上游 HomeDesign.homeButtonSize 的缺省值保持一致。
    static let defaultSize: Double = 52.0
    /// 设置页写入的键，存在 app group 里，宿主与访客都能读到。
    static let sizeKey = "iManagerHomeButtonSize"
    /// 允许的尺寸范围。上限不设太大，避免盖住半个屏幕。
    static let sizeRange: ClosedRange<Double> = 40.0...72.0
}

/// 「辅助触控」页面。
struct IManagerAssistiveTouchPage: View {
    /// 上游那一项：应用内是否显示主屏按键。用同一个键，不另立门户。
    @AppStorage("LCShowHomeButtonInApps") private var showsInApps = false
    /// 本块新增：按钮尺寸。
    @AppStorage(IManagerHomeButton.sizeKey, store: LCUtils.appGroupUserDefault)
    private var buttonSize = IManagerHomeButton.defaultSize

    var body: some View {
        List {
            Section {
                previewCard
                    .listRowInsets(EdgeInsets())
                    .listRowBackground(Color.clear)
            }

            Section {
                Toggle("应用内显示主屏按键", isOn: $showsInApps)
            } footer: {
                Text("这一项和「外观 → 应用内显示主屏按键」是同一个开关，改哪个都一样。每个 App 还能单独再关一次。")
                    .font(.footnote)
            }

            Section {
                VStack(alignment: .leading, spacing: 6) {
                    HStack {
                        Text("按钮大小")
                        Spacer()
                        Text("\(Int(buttonSize.rounded())) pt")
                            .foregroundStyle(.secondary)
                            .monospacedDigit()
                    }
                    Slider(
                        value: $buttonSize,
                        in: IManagerHomeButton.sizeRange,
                        step: 2
                    )
                }
            } footer: {
                Text("缺省 \(Int(IManagerHomeButton.defaultSize)) pt，与上游一致。改动即时生效，不需要重启。")
                    .font(.footnote)
            }

            Section {
                LabeledContent("位置", value: SharedModel.isPhone ? "屏幕底部" : "随 iPad 方向变化")
                LabeledContent("外观", value: "跟随系统，始终深色玻璃")
            } footer: {
                Text("位置和外观沿用上游 Home 键的实现，本页不改它们。")
                    .font(.footnote)
            }
        }
        .navigationTitle("辅助触控")
        .navigationBarTitleDisplayMode(.inline)
    }

    /// 按当前尺寸画一个示意按钮，让滑杆的效果立刻看得见。
    private var previewCard: some View {
        VStack(spacing: 10) {
            ZStack {
                Circle()
                    .fill(.ultraThinMaterial)
                    .overlay {
                        Circle().fill(Color.black.opacity(0.35))
                    }
                    .overlay {
                        Circle().strokeBorder(Color.white.opacity(0.25), lineWidth: 1)
                    }
                    .frame(width: buttonSize, height: buttonSize)

                Circle()
                    .strokeBorder(Color.white.opacity(0.85), lineWidth: max(1.5, buttonSize * 0.045))
                    .frame(width: buttonSize * 0.56, height: buttonSize * 0.56)
            }
            .frame(height: IManagerHomeButton.sizeRange.upperBound + 12)

            Text("示意：实际按钮画在屏幕上，外观以上游实现为准")
                .font(.caption2)
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 8)
    }
}
