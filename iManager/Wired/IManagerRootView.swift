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
                Toggle(isOn: $globalSpoof) {
                    VStack(alignment: .leading, spacing: 4) {
                        Text("全局隐藏模式")
                        Text(globalSpoof ? "所有沙盒 App 默认启用隐藏层（sysctl / SecTask / csops / proc / dyld）"
                                         : "逐 App 在各自设置里单独开启")
                            .font(.caption)
                            .foregroundColor(.secondary)
                    }
                }
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
            } footer: {
                Text("iManager 作为 zcontainer 内置功能运行；日志与门控状态都来自宿主进程的实时值。")
            }
        }
        .navigationTitle("iManager")
        .navigationBarTitleDisplayMode(.inline)
    }
}
