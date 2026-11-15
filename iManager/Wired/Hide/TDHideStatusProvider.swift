import Foundation

enum TDHideStatusProvider {
    static func currentRows() -> [TDHideStatusView.LayerRow] {
        let globalOn = UserDefaults.standard.bool(forKey: "TDGlobalSpoof")
        let (enabled, total) = dyldTrimCoverage()
        let dyldState: TDHideStatusView.LayerRow.State
        let dyldTitle: String
        if globalOn {
            dyldState = .active
            dyldTitle = "dyld 镜像裁剪 (全局生效)"
        } else {
            if total == 0 || enabled == 0 {
                dyldState = .off
            } else if enabled == total {
                dyldState = .active
            } else {
                dyldState = .partial
            }
            dyldTitle = "dyld 镜像裁剪 (\(enabled)/\(total))"
        }
        let spoofOn = UserDefaults.standard.bool(forKey: "TDGlobalSpoof")

        return [
            .init(id: "env", icon: "leaf", title: "访客环境清洗", state: .builtIn),
            .init(id: "dyld", icon: "square.stack.3d.up.slash",
                  title: dyldTitle, state: dyldState),
            .init(id: "spoof", icon: "theatermasks",
                  title: "伪值层", state: spoof ? .active : .off),
            .init(id: "tweaks", icon: "folder.badge.questionmark",
                  title: "Tweaks 目录隐藏", state: .builtIn),
        ]
    }

    private static func dyldTrimCoverage() -> (Int, Int) {
        let fm = FileManager.default
        let appsDir = URL(fileURLWithPath: NSHomeDirectory())
            .appendingPathComponent("Documents/Applications", isDirectory: true)
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
