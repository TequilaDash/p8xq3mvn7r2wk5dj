//
//  iManagerSettingsRow.swift
//  iManager — zcontainer-test2 源码块
//
//  Settings 根列表里 iManager 那一行的图标与文字。
//
//  【图标来源】直接使用打包进 bundle 的 PNG（iManager/Resources/IManagerIcon.png），
//  与旧线 IManagerIconView 完全一致的做法：Bundle 里取文件、UIImage(contentsOfFile:)、
//  圆角裁切。**不自绘** —— 用户给的图就是这张，画出来的永远不如原图。
//
//  【打包】该 PNG 通过 pbxproj 里 iManager 同步组带进 LiveContainerSwiftUI
//  framework 的 Resources，运行时用 Bundle(for:) 定位。
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
                IManagerIconView(size: 29)
            }
        }
    }
}

/// iManager 的图标：bundle 里的 IManagerIcon.png，圆角裁切。
/// 与旧线 IManagerIconView 同一实现，只是找不到图时退回单色块。
struct IManagerIconView: View {
    var size: CGFloat = 29

    var body: some View {
        Group {
            if let image = Self.image {
                Image(uiImage: image)
                    .resizable()
                    .scaledToFill()
            } else {
                RoundedRectangle(cornerRadius: size * 0.23, style: .continuous)
                    .fill(Color.accentColor)
            }
        }
        .frame(width: size, height: size)
        .clipShape(RoundedRectangle(cornerRadius: size * 0.23, style: .continuous))
    }

    private final class BundleToken {}

    private static let image: UIImage? = {
        let bundle = Bundle(for: BundleToken.self)
        guard let url = bundle.url(forResource: "IManagerIcon", withExtension: "png") else { return nil }
        return UIImage(contentsOfFile: url.path)
    }()
}
