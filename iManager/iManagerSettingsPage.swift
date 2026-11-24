//
//  iManagerSettingsPage.swift
//  iManager — zcontainer-test2 源码块
//
//  iManager 在 zContainer 设置里的**唯一入口**，下面是它的二级界面：
//    · 补丁管理   iManagerPatches.swift       （修补类改动 + 撤销编号）
//    · 辅助触控   iManagerAssistiveTouch.swift（全局悬浮 Home 键 + 设置）
//
//  【UI 统一】上游设置页**不写** listStyle：靠 List 默认样式 + 引用点的
//  .settingsPageMargins() 得到与 Settings 一致的卡片边距。本页照做 ——
//  显式加 .listStyle(.insetGrouped) 反而会破坏 SettingsPageMargins 的测量，
//  卡片贴边（犯过两次，别再犯）。
//
//  【引入方式（极致最小化）】上游 Settings 只加这几处：
//    1. SettingsPage 枚举加 case iManager
//    2. SettingsRootSections 加一行 SettingsPageLink(page: .iManager)
//    3. SettingsPageView 的 switch 加 case → IManagerSettingsPage()
//    4. SettingsPage+Row 的 title 给个名字（图标由本块自绘，见 iManagerSettingsRow.swift）
//    5. SettingsSearch 的 pages 列表加 .iManager，settings(on:) 加空分支
//

import SwiftUI

/// iManager 的总页面：列出所有二级界面。
struct IManagerSettingsPage: View {
    var body: some View {
        List {
            Section {
                NavigationLink {
                    IManagerPatchesPage()
                } label: {
                    IManagerRow(
                        icon: "bandage.fill",
                        color: .orange,
                        title: "补丁管理",
                        detail: "\(IManagerPatchRegistry.active.count) 项修补"
                    )
                }

                NavigationLink {
                    IManagerAssistiveTouchPage()
                } label: {
                    IManagerRow(
                        icon: "hand.tap.fill",
                        color: .blue,
                        title: "辅助触控",
                        detail: IManagerAssistiveTouch.isEnabled ? "已启用" : "未启用"
                    )
                }
            } footer: {
                Text("这里是我们对上游 zContainer 的全部改动。每项修补都有编号，上游自己修掉后按编号撤销。")
                    .font(.footnote)
            }
        }
        .navigationTitle("iManager")
        .navigationBarTitleDisplayMode(.inline)
    }
}

/// iManager 二级界面的一行：图标 + 标题 + 右侧说明。
private struct IManagerRow: View {
    let icon: String
    let color: Color
    let title: String
    let detail: String

    var body: some View {
        LabeledContent {
            Text(detail)
                .font(.footnote)
                .foregroundStyle(.secondary)
        } label: {
            Label {
                Text(title)
            } icon: {
                SettingsIcon(systemImage: icon, color: color)
            }
        }
    }
}
