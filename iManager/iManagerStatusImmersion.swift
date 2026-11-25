//
//  iManagerStatusImmersion.swift
//  iManager
//
//  状态栏沉浸：主屏幕隐藏状态栏，让壁纸铺到顶部。
//
//  【为什么这样拆】
//  用户要求所有改动集中在 iManager、极致最小化触碰上游。真正生效的点在
//  上游 HomeScreenView 的 homeStatusBarHidden(...)，那里只能加 1 行调用；
//  读取偏好、设置界面都在本文件里。
//
//  【键】LCStatusBarImmersion（app group，与旧版 iManager 相同，便于迁移）
//

import SwiftUI

/// 主屏幕状态栏沉浸开关。
enum IManagerStatusBarImmersion {
    /// 偏好键。沿用旧版键名，老用户设置不丢。
    static let key = "LCStatusBarImmersion"

    /// 当前是否开启。上游 HomeScreenView 每帧读它，所以改完立刻生效。
    static var isOn: Bool {
        LCUtils.appGroupUserDefault.bool(forKey: key)
    }
}

/// 「状态栏沉浸」设置页。
struct IManagerStatusImmersionPage: View {
    @AppStorage(IManagerStatusBarImmersion.key, store: LCUtils.appGroupUserDefault)
    private var isOn = false

    var body: some View {
        List {
            Section {
                Toggle("主屏幕隐藏状态栏", isOn: $isOn)
            } footer: {
                Text("仅作用于 zContainer 的主屏幕，让壁纸铺到屏幕最顶部。访客应用和多任务窗口保持各自的状态栏。")
                    .font(.footnote)
            }
        }
        .listStyle(.insetGrouped)
        .navigationTitle("状态栏沉浸")
        .navigationBarTitleDisplayMode(.inline)
    }
}
