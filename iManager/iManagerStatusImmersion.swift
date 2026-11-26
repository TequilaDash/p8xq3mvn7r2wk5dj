//
//  iManagerStatusImmersion.swift
//  iManager
//
//  隐藏状态栏。键 LCStatusBarImmersion（app group）。
//  生效点在上游 HomeScreenView 的 homeStatusBarHidden(...)，1 行。
//

import SwiftUI

enum IManagerStatusBarImmersion {
    static let key = "LCStatusBarImmersion"

    static var isOn: Bool {
        LCUtils.appGroupUserDefault.bool(forKey: key)
    }
}

struct IManagerStatusImmersionPage: View {
    @AppStorage(IManagerStatusBarImmersion.key, store: LCUtils.appGroupUserDefault)
    private var isOn = false

    var body: some View {
        List {
            Section {
                Toggle("隐藏状态栏", isOn: $isOn)
            }
        }
        .listStyle(.insetGrouped)
        .navigationTitle("隐藏状态栏")
        .navigationBarTitleDisplayMode(.inline)
    }
}
