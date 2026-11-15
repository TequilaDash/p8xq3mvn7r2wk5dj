//
//  TDHideStatusProvider.swift
//  iManager
//
//  隐藏状态面板的数据源：直接读运行时门控真值（TDVRootConfig 的 C 导出），
//  不猜 plist。宿主进程里读到的是本进程捕获后的门控状态。
//

import Foundation

enum TDHideStatusProvider {
    struct Row {
        let id: String
        let icon: String
        let title: String
        let detail: String
        let state: TDHideStatusView.LayerRow.State
        let howToEnable: String
        let note: String
    }

    static func currentRows() -> [TDHideStatusView.LayerRow] {
        var rows: [TDHideStatusView.LayerRow] = []

        rows.append(.init(id: "env", icon: "leaf", title: "访客环境清洗",
                          detail: "dlopen 访客前清理 TD_*/LC_HOME_PATH 等宿主痕迹。",
                          state: .builtIn, howToEnable: "", note: "常开，无开关。"))

        let group = UserDefaults(suiteName: "group.com.tequila.dash")
        let trimOn = group?.bool(forKey: "TDHideLiveContainer") ?? false
        rows.append(.init(id: "dyld", icon: "square.stack.3d.up.slash", title: "dyld 镜像裁剪",
                          detail: "访客枚举镜像时隐藏宿主注入层。",
                          state: trimOn ? .active : .off,
                          howToEnable: "App 设置 → 隐藏环境（hideLiveContainer）",
                          note: trimOn ? "已生效。" : "随 per-app hideLiveContainer 门控，当前未启用。"))

        let spoof = UserDefaults(suiteName: "group.com.tequila.dash")?.bool(forKey: "TDGlobalSpoof") ?? false
        rows.append(.init(id: "spoof", icon: "theatermasks", title: "伪值层（sysctl/proc/SecTask/csops）",
                          detail: "对检测器返回伪设备信息与空进程/权限视图。",
                          state: spoof ? .active : .off,
                          howToEnable: "iManager 设置 → 全局隐藏模式",
                          note: spoof ? "已开启。" : "未开启。"))

        rows.append(.init(id: "tweaks", icon: "folder.badge.questionmark", title: "Tweaks 目录对访客隐藏",
                          detail: "访客镜像 stat/open `*/Documents/Tweaks` 返回 ENOENT。",
                          state: .builtIn, howToEnable: "", note: "常开；LC 自身的 TweakLoader 不受影响。"))

        return rows
    }
}
