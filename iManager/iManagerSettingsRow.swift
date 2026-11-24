//
//  iManagerSettingsRow.swift
//  iManager — zcontainer-test2 源码块
//
//  Settings 根列表里 iManager 那一行的图标与文字。
//
//  【为什么不改上游 SettingsIcon】上游的 SettingsIcon 只接受 SF Symbol 或
//  IconServices 的 graphic icon 类型，画不了自定义图形。为了一个图标去改上游
//  组件会扩大同步面，所以本块自己画这一行的 label，外观与 SettingsRow 对齐
//  （同样的图标尺寸、同样的 LabeledContent 布局）。
//
//  【图标】浅蓝底 + 白色云朵 + 蓝色 </>，即 iManager 的标记。
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

/// iManager 的标记：浅蓝圆角方块上，白色云朵里嵌一个蓝色 </>。
struct IManagerMark: View {
    /// 与上游 SettingsDesign.iconSize 一致，随文字大小缩放。
    @ScaledMetric(relativeTo: .body) private var size: Double = 29

    var body: some View {
        ZStack {
            RoundedRectangle(cornerRadius: size * 0.23, style: .continuous)
                .fill(
                    LinearGradient(
                        colors: [
                            Color(red: 0.78, green: 0.87, blue: 0.99),
                            Color(red: 0.72, green: 0.83, blue: 0.98),
                        ],
                        startPoint: .top,
                        endPoint: .bottom
                    )
                )

            // 云朵：白色填充，略微压扁，占图标约七成宽。
            Image(systemName: "cloud.fill")
                .resizable()
                .scaledToFit()
                .foregroundStyle(.white)
                .frame(width: size * 0.72, height: size * 0.52)
                .offset(y: size * 0.02)

            // </>：蓝色，压在云朵中央。
            Image(systemName: "chevron.left.forwardslash.chevron.right")
                .resizable()
                .scaledToFit()
                .foregroundStyle(Color(red: 0.20, green: 0.42, blue: 0.95))
                .frame(width: size * 0.42, height: size * 0.30)
                .offset(y: size * 0.03)
        }
        .frame(width: size, height: size)
        .accessibilityHidden(true)
    }
}
