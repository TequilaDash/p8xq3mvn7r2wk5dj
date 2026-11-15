//
//  IManagerRootView.swift
//  iManager
//
//  iManager 入口页（zcontainer 设置 → iManager）。功能按模块分组，逐步接线。
//

import SwiftUI

struct IManagerRootView: View {
    @State private var globalSpoof =
        UserDefaults(suiteName: "group.com.tequila.dash")?.bool(forKey: "TDGlobalSpoof") ?? false
    private let groupDefaults = UserDefaults(suiteName: "group.com.tequila.dash")

    var body: some View {
        List {
            Section {
                Toggle("全局隐藏模式", isOn: $globalSpoof)
                .onChange(of: globalSpoof) { nv in
                    groupDefaults?.set(nv, forKey: "TDGlobalSpoof")
                }
            } header: {
                Text("隐藏")
            }

            Section {
                NavigationLink {
                    TDHideStatusView()
                } label: {
                    Label("隐藏状态", systemImage: "eye.slash")
                }
                NavigationLink {
                    ExploitLogView()
                } label: {
                    Label("exploit 日志", systemImage: "doc.text.magnifyingglass")
                }
            } header: {
                Text("诊断")
            }
        }
        .navigationTitle("iManager")
        .navigationBarTitleDisplayMode(.inline)
    }
}
