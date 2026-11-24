//
//  iManagerSettingsPage.swift
//  iManager — zcontainer-test2 源码块
//
//  iManager 在 zContainer 设置里的**唯一入口**，下面是它的二级界面：
//    · 补丁管理   iManagerPatches.swift       （修补类改动 + 撤销编号）
//    · 辅助触控   iManagerAssistiveTouch.swift（上游 Home 键的设置界面）
//
//  【引入方式（极致最小化）】上游 Settings 只加两处：
//    1. SettingsPage 枚举加一个 case iManager
//    2. SettingsRootSections 加一行 SettingsPageLink(page: .iManager)
//    3. SettingsPageView 的 switch 加一个 case → IManagerSettingsPage()
//  以及 SettingsPage+Row 的 title / rowIcon 各一个 case。
//  其余全部在本文件与两个二级界面文件里。
//
//  【纪律】iManager 只放「我们自己的代码」。上游文件永远只有
//  import + 少量调用点，方便跟随上游同步。
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
                        icon: "bandage",
                        color: .orange,
                        title: "补丁管理",
                        detail: "\(IManagerPatchRegistry.all.filter { !$0.isRetired }.count) 项修补"
                    )
                }

                NavigationLink {
                    IManagerAssistiveTouchPage()
                } label: {
                    IManagerRow(
                        icon: "hand.tap",
                        color: .blue,
                        title: "辅助触控",
                        detail: "主屏按键的显示与大小"
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
        HStack(spacing: 12) {
            Image(systemName: icon)
                .font(.system(size: 15, weight: .semibold))
                .foregroundStyle(.white)
                .frame(width: 28, height: 28)
                .background(color, in: RoundedRectangle(cornerRadius: 7, style: .continuous))

            Text(title)

            Spacer(minLength: 8)

            Text(detail)
                .font(.footnote)
                .foregroundStyle(.secondary)
        }
        .padding(.vertical, 2)
    }
}
