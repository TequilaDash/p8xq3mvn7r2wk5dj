import Foundation

enum TDHideStatusProvider {
    static func currentRows() -> [TDHideStatusView.LayerRow] {
        let globalOn = globalHideEnabled()
        let (enabled, total) = dyldTrimCoverage()
        let dyldState: TDHideStatusView.LayerRow.State
        let dyldTitle: String
        if globalOn {
            dyldState = .active
            dyldTitle = "dyld 镜像裁剪 (全局生效)"
        } else if total == 0 || enabled == 0 {
            dyldState = .off
            dyldTitle = "dyld 镜像裁剪 (0/\(total))"
        } else if enabled == total {
            dyldState = .active
            dyldTitle = "dyld 镜像裁剪 (\(enabled)/\(total))"
        } else {
            dyldState = .partial
            dyldTitle = "dyld 镜像裁剪 (\(enabled)/\(total))"
        }
        let envSpoof = envSpoofEnabled()
        return [
            .init(id: "env", icon: "leaf", title: "访客环境清洗", state: .builtIn),
            .init(id: "dyld", icon: "square.stack.3d.up.slash", title: dyldTitle, state: dyldState),
            .init(id: "spoof", icon: "theatermasks",
                  title: envSpoof ? "伪值层 (环境伪值已开启)" : "伪值层 (环境伪值已关闭)",
                  state: envSpoof ? .active : .off),
            .init(id: "tweaks", icon: "folder.badge.questionmark", title: "Tweaks 目录隐藏", state: .builtIn),
        ]
    }

    // 与 LCBootstrap 读取同一个 app group 键; 缺省为开启.
    private static func envSpoofEnabled() -> Bool {
        guard let defaults = UserDefaults(suiteName: LCSharedUtils.appGroupID()) else { return true }
        return (defaults.object(forKey: "TDEnvSpoof") as? Bool) ?? true
    }

    private static func globalHideEnabled() -> Bool {
        guard let path = TDHostHomeDocumentsPath() else { return false }
        let flagPath = String(cString: path) + "/TDGlobalHide"
        return (try? String(contentsOfFile: flagPath, encoding: .utf8)) == "1"
    }

    private static func dyldTrimCoverage() -> (Int, Int) {
        let fm = FileManager.default
        guard let path = TDHostHomeDocumentsPath() else { return (0, 0) }
        let appsDir = URL(fileURLWithPath: String(cString: path))
            .appendingPathComponent("Applications", isDirectory: true)
        guard let entries = try? fm.contentsOfDirectory(at: appsDir, includingPropertiesForKeys: nil) else {
            return (0, 0)
        }
        var enabled = 0
        var total = 0
        for entry in entries {
            let plist = entry.appendingPathComponent("LCAppInfo.plist")
            guard let info = NSDictionary(contentsOf: plist) else { continue }
            total += 1
            if info["hideLiveContainer"] as? Bool == true { enabled += 1 }
        }
        return (enabled, total)
    }
}
