//
//  iManagerRecentTasks.swift
//  iManager — zcontainer-test2 源码块
//
//  「最近任务样式」设置页 + 堆叠后台的开关。
//
//  【本块负责什么】
//    · 设置页 UI（纵向排布 / 横向排布 两个示意图、显示内存信息开关、模糊预览图入口）
//    · 写入偏好键，供 MultitaskStackView 读取
//  【不负责什么】
//    · 堆叠视图本体在 iManager/MultitaskStackView.swift（从旧线移植）
//
//  【横向排布】示意图先给出来，实际切换留入口：layoutKey 写入了，
//  MultitaskStackView 里暂未按它分支（后续研究）。这样开关不会假装生效。
//

import SwiftUI

/// 最近任务（堆叠后台）的偏好键与取值。
enum IManagerRecentTasks {
    /// 排布方式：stack（纵向）/ row（横向）。
    static let layoutKey = "iManagerRecentTasksLayout"
    static let layoutStack = "stack"
    static let layoutRow = "row"
    /// 卡片上是否显示内存占用。**沿用堆叠实际读取的键**。
    static let showMemoryKey = "TDAppStackShowMemory"
    /// 卡片预览是否模糊（保护隐私）。**沿用堆叠实际读取的键**。
    static let blurPreviewKey = "TDAppStackBlur"
    /// Dock 栏样式：clear（透明/玻璃）/ frosted（磨砂，默认）。
    static let dockStyleKey = "TDAppStackDockStyle"
    static let dockStyleClear = "clear"
    static let dockStyleFrosted = "frosted"
    /// 是否启用堆叠后台。**沿用旧线的键 TDAppStackEnabled**，
    /// 因为 MultitaskStackView.swift（从旧线移植）读的就是这个键。
    static let enabledKey = "TDAppStackEnabled"

    static var isEnabled: Bool {
        MultitaskStackManager.isEnabled
    }
    static var showsMemory: Bool {
        LCUtils.appGroupUserDefault.object(forKey: showMemoryKey) as? Bool ?? true
    }
    static var blursPreview: Bool {
        LCUtils.appGroupUserDefault.bool(forKey: blurPreviewKey)
    }
    static var dockStyle: String {
        LCUtils.appGroupUserDefault.string(forKey: dockStyleKey) ?? dockStyleFrosted
    }
    static var layout: String {
        LCUtils.appGroupUserDefault.string(forKey: layoutKey) ?? layoutStack
    }
}

/// 「最近任务样式」设置页。
struct IManagerRecentTasksPage: View {
    // 旧线缺省为 true（键未写入时 isEnabled 返回 true），这里保持一致。
    @AppStorage(MultitaskStackManager.enabledKey, store: LCUtils.appGroupUserDefault)
    private var isEnabled = true
    @AppStorage(IManagerRecentTasks.layoutKey, store: LCUtils.appGroupUserDefault)
    private var layout = IManagerRecentTasks.layoutStack
    @AppStorage(IManagerRecentTasks.showMemoryKey, store: LCUtils.appGroupUserDefault)
    private var showsMemory = true
    @AppStorage(IManagerRecentTasks.blurPreviewKey, store: LCUtils.appGroupUserDefault)
    private var blursPreview = false
    @AppStorage(IManagerRecentTasks.dockStyleKey, store: LCUtils.appGroupUserDefault)
    private var dockStyle = IManagerRecentTasks.dockStyleFrosted

    var body: some View {
        List {
            Section {
                Toggle("启用最近任务", isOn: $isEnabled)
            } footer: {
                Text("开启后，双击辅助触控按钮（或从多任务入口）打开最近任务，卡片可上滑关闭。")
                    .font(.footnote)
            }

            if isEnabled {
                Section {
                    HStack(alignment: .top, spacing: 16) {
                        layoutOption(IManagerRecentTasks.layoutStack, title: "纵向排布")
                        layoutOption(IManagerRecentTasks.layoutRow, title: "横向排布")
                    }
                    .padding(.vertical, 4)
                    .listRowInsets(EdgeInsets(top: 12, leading: 16, bottom: 12, trailing: 16))
                } header: {
                    Text("最近任务样式")
                } footer: {
                    Text("横向排布暂未启用，选中后仍是纵向；布局切换会随后续版本开放。")
                        .font(.footnote)
                }

                Section {
                    Toggle("显示内存信息", isOn: $showsMemory)
                } footer: {
                    Text("在最近任务右上角显示选中 App 的内存占用。")
                        .font(.footnote)
                }

                Section {
                    Picker("Dock 栏样式", selection: $dockStyle) {
                        Text("透明（玻璃）").tag(IManagerRecentTasks.dockStyleClear)
                        Text("磨砂").tag(IManagerRecentTasks.dockStyleFrosted)
                    }
                    .pickerStyle(.inline)
                    .labelsHidden()
                } header: {
                    Text("Dock 栏样式")
                } footer: {
                    Text("透明：玻璃质感，能看见背后的壁纸或应用。磨砂：默认的模糊底，与系统多任务栏一致。")
                        .font(.footnote)
                }

                Section {
                    Toggle("模糊预览图", isOn: $blursPreview)
                } footer: {
                    Text("将最近任务的卡片内容模糊处理，保护隐私安全。")
                        .font(.footnote)
                }
            }
        }
        .listStyle(.insetGrouped)
        .navigationTitle("最近任务样式")
        .navigationBarTitleDisplayMode(.inline)
    }

    /// 一个排布选项：示意图 + 标题，选中时蓝色描边。
    private func layoutOption(_ value: String, title: String) -> some View {
        Button {
            layout = value
        } label: {
            VStack(spacing: 8) {
                LayoutPreview(kind: value)
                    .frame(height: 150)
                    .overlay {
                        if layout == value {
                            RoundedRectangle(cornerRadius: 14, style: .continuous)
                                .strokeBorder(Color.accentColor, lineWidth: 2.5)
                        }
                    }
                Text(title)
                    .font(.subheadline)
                    .foregroundStyle(layout == value ? Color.accentColor : .secondary)
            }
        }
        .buttonStyle(.plain)
    }
}

/// 排布示意图：纯装饰，用色块画出卡片在屏幕上的排法。
private struct LayoutPreview: View {
    let kind: String

    var body: some View {
        GeometryReader { proxy in
            let w = proxy.size.width
            let h = proxy.size.height
            let cardRadius = w * 0.06

            ZStack {
                RoundedRectangle(cornerRadius: 14, style: .continuous)
                    .fill(
                        LinearGradient(
                            colors: [
                                Color(red: 0.36, green: 0.55, blue: 0.98),
                                Color(red: 0.55, green: 0.75, blue: 1.00),
                            ],
                            startPoint: .top,
                            endPoint: .bottom
                        )
                    )

                if kind == IManagerRecentTasks.layoutStack {
                    // 纵向：两张卡竖着叠，前排大后排露边
                    VStack(spacing: h * 0.06) {
                        card(width: w * 0.52, height: h * 0.30, radius: cardRadius)
                        card(width: w * 0.52, height: h * 0.30, radius: cardRadius)
                    }
                    .offset(y: h * 0.02)
                } else {
                    // 横向：一张大卡居中，两侧各露一条
                    HStack(spacing: w * 0.03) {
                        card(width: w * 0.16, height: h * 0.52, radius: cardRadius)
                        card(width: w * 0.40, height: h * 0.62, radius: cardRadius)
                        card(width: w * 0.16, height: h * 0.52, radius: cardRadius)
                    }
                }
            }
        }
    }

    private func card(width: CGFloat, height: CGFloat, radius: CGFloat) -> some View {
        RoundedRectangle(cornerRadius: radius, style: .continuous)
            .fill(Color.white.opacity(0.30))
    }
}
