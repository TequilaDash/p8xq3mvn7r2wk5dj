//
//  iManagerSettingsRow.swift
//  iManager — zcontainer-test2 源码块
//
//  Settings 根列表里 iManager 那一行的图标。
//
//  【为什么自绘】上游 SettingsIcon 只接受 SF Symbol 或 IconServices 的
//  graphic icon 类型，画不了这个标记。为了一个图标去改上游组件会扩大同步面。
//
//  【外观】照用户给的图：浅蓝紫渐变底，白色磨砂玻璃云朵（厚边、高光、
//  柔和落影），云朵内三段彩色管状 </>：
//    <  青绿 → 蓝
//    /  蓝 → 紫
//    >  紫 → 橙粉
//  每段有圆角端头、内高光和底部阴影，像玻璃管。
//

import SwiftUI

/// iManager 在 Settings 根列表里的一行。
struct IManagerSettingsRow: View {
    var body: some View {
        LabeledContent {
            EmptyView()
        } label: {
            Label {
                Text("iManager")
            } icon: {
                IManagerMark()
            }
        }
    }
}

/// iManager 的标记：浅蓝紫渐变底 + 玻璃云朵 + 彩色管状 </>。
struct IManagerMark: View {
    /// 与上游 SettingsDesign.iconSize 一致，随文字大小缩放。
    @ScaledMetric(relativeTo: .body) private var size: Double = 29

    var body: some View {
        ZStack {
            // 底：左上淡粉 → 右下淡蓝的柔和渐变
            RoundedRectangle(cornerRadius: size * 0.23, style: .continuous)
                .fill(
                    LinearGradient(
                        colors: [
                            Color(red: 0.93, green: 0.90, blue: 0.99),
                            Color(red: 0.85, green: 0.92, blue: 1.00),
                        ],
                        startPoint: .topLeading,
                        endPoint: .bottomTrailing
                    )
                )

            // 玻璃云朵
            cloud
                .frame(width: size * 0.80, height: size * 0.56)

            // 彩色管状 </>
            glassChevrons
                .frame(width: size * 0.50, height: size * 0.26)
                .offset(y: size * 0.01)
        }
        .frame(width: size, height: size)
        .accessibilityHidden(true)
    }

    /// 磨砂玻璃云朵：厚白边 + 内部淡蓝白 + 顶部高光 + 落影。
    private var cloud: some View {
        ZStack {
            // 外发光/落影
            Image(systemName: "cloud.fill")
                .resizable()
                .scaledToFit()
                .foregroundStyle(Color(red: 0.62, green: 0.70, blue: 0.92).opacity(0.30))
                .blur(radius: size * 0.035)
                .offset(y: size * 0.025)

            // 厚白边：比内层略大
            Image(systemName: "cloud.fill")
                .resizable()
                .scaledToFit()
                .foregroundStyle(
                    LinearGradient(
                        colors: [.white, Color(white: 0.94)],
                        startPoint: .top,
                        endPoint: .bottom
                    )
                )

            // 内层：淡蓝白，制造玻璃厚度
            Image(systemName: "cloud.fill")
                .resizable()
                .scaledToFit()
                .foregroundStyle(
                    LinearGradient(
                        colors: [
                            Color(red: 0.97, green: 0.99, blue: 1.00),
                            Color(red: 0.88, green: 0.94, blue: 1.00),
                        ],
                        startPoint: .top,
                        endPoint: .bottom
                    )
                )
                .padding(size * 0.045)

            // 顶部高光弧
            Image(systemName: "cloud.fill")
                .resizable()
                .scaledToFit()
                .foregroundStyle(
                    LinearGradient(
                        colors: [.white.opacity(0.95), .white.opacity(0)],
                        startPoint: .top,
                        endPoint: .center
                    )
                )
                .scaleEffect(x: 0.86, y: 0.72, anchor: .top)
                .padding(size * 0.045)
                .blendMode(.plusLighter)
        }
    }

    /// 三段彩色玻璃管组成的 `</>`，每段有圆头、内高光、底部阴影。
    private var glassChevrons: some View {
        HStack(spacing: size * 0.035) {
            glassStroke(
                systemName: "chevron.left",
                top: Color(red: 0.40, green: 0.92, blue: 0.66),
                bottom: Color(red: 0.42, green: 0.62, blue: 0.95),
                width: size * 0.155,
                height: size * 0.22
            )
            glassStroke(
                systemName: "slash",
                top: Color(red: 0.40, green: 0.72, blue: 0.98),
                bottom: Color(red: 0.66, green: 0.38, blue: 0.95),
                width: size * 0.105,
                height: size * 0.26
            )
            glassStroke(
                systemName: "chevron.right",
                top: Color(red: 0.66, green: 0.40, blue: 0.95),
                bottom: Color(red: 0.98, green: 0.58, blue: 0.52),
                width: size * 0.155,
                height: size * 0.22
            )
        }
    }

    /// 一根玻璃管：渐变主体 + 顶部内高光 + 底部柔和阴影。
    private func glassStroke(systemName: String,
                             top: Color,
                             bottom: Color,
                             width: Double,
                             height: Double) -> some View {
        Image(systemName: systemName)
            .resizable()
            .scaledToFit()
            .foregroundStyle(
                LinearGradient(colors: [top, bottom], startPoint: .top, endPoint: .bottom)
            )
            .overlay {
                // 内高光：同形状的白色，只留顶部一条
                Image(systemName: systemName)
                    .resizable()
                    .scaledToFit()
                    .foregroundStyle(
                        LinearGradient(
                            colors: [.white.opacity(0.75), .white.opacity(0)],
                            startPoint: .top,
                            endPoint: .center
                        )
                    )
                    .blendMode(.plusLighter)
            }
            .frame(width: width, height: height)
            .shadow(color: bottom.opacity(0.45), radius: size * 0.02, y: size * 0.012)
    }
}
