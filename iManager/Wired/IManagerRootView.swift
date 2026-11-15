//
//  IManagerRootView.swift
//  iManager
//
//  iManager 入口页（zcontainer 设置 → iManager）。功能按模块分组，逐步接线。
//

import SwiftUI

struct IManagerRootView: View {
    var body: some View {
        List {
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
