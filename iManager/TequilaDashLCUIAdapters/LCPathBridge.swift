import Foundation

/// LC 容器根路径的单一事实来源（本仓适配层）.
///
/// 为什么需要: 上游 `LCPath.docPath` 写死 `Documents/`（vendor/LiveContainer/
/// LiveContainerSwiftUI/Utilities/Shared.swift:15-23），而本仓把沙盒容器放在
/// `Documents/SandboxApps/`，并通过 `LC_HOME_PATH` 环境变量告诉 **ObjC 侧**
/// （HostGuestEntry.m:51-52 → LCBootstrap.m:281-289 的 docPath）.
///
/// 于是同一份数据出现两套路径:
///   · 访客启动 (ObjC) 读 `LC_HOME_PATH` → `Documents/SandboxApps/Applications/...`
///   · LC 原生 UI (Swift) 读 `LCPath.docPath` → `Documents/Applications/...`
/// 列表看不到访客能启动的 App，安装也落到另一处 —— 这就是「逻辑不通」的根因.
///
/// 本文件把 Swift 侧对齐到同一个环境变量，不改镜像（上游同步零冲突）.
/// 取值顺序与 LCBootstrap.m:281-289 逐条一致:
///   1. `LC_HOME_PATH`（宿主在启动访客前 setenv，也在 TDHostBoot 前置设置）
///   2. `HOME`（LCBootstrap 的回落）
///   3. `Documents/`（最终兜底，与上游默认一致）
enum LCPathBridge {

    /// 容器根. 与 ObjC 侧 `LCBootstrap` 的 docPath 同源.
    static let containerRoot: URL = {
        let env = ProcessInfo.processInfo.environment
        if let raw = env["LC_HOME_PATH"], !raw.isEmpty {
            return URL(fileURLWithPath: raw, isDirectory: true)
        }
        if let home = env["HOME"], !home.isEmpty {
            return URL(fileURLWithPath: home, isDirectory: true)
        }
        return FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).last!
    }()

    /// 宿主侧（非访客进程）用的容器根: **`Documents/`**.
    ///
    /// v0.3.814 修复: 原先这里拼了 `SandboxApps`，而 `SandboxContainerStore.root`
    /// 已改成 `Documents/`（对齐 LC 的 `LCPath.docPath`）。两套路径不一致导致:
    /// 导入写到 `Documents/Applications`，LC 原生 UI 却扫 `Documents/SandboxApps/Applications`
    /// → 装完能看见、杀后台重进列表空（真机截图实测）。
    ///
    /// 现在三处同源: `LCPath.docPath` = `SandboxContainerStore.root` = 本属性 = `Documents/`。
    static var hostContainerRoot: URL {
        FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).last!
    }

    static var applications: URL { hostContainerRoot.appendingPathComponent("Applications", isDirectory: true) }
    static var dataApplication: URL { hostContainerRoot.appendingPathComponent("Data/Application", isDirectory: true) }
    static var tweaks: URL { hostContainerRoot.appendingPathComponent("Tweaks", isDirectory: true) }

    /// vroot (Tier A) 的两个空壳目录: 契约与 Nyxian 的 `$croot/Documents/{rootfs,mntfs}` 同构.
    /// 这里只负责创建, 不负责解包 (rootfs 解包在切片 2 由宿主侧 libarchive 做).
    static var rootfs: URL { hostContainerRoot.appendingPathComponent("rootfs", isDirectory: true) }
    static var mntfs: URL { hostContainerRoot.appendingPathComponent("mntfs", isDirectory: true) }

    /// 确保 LC 期望的三层目录存在（上游 LiveContainerSwiftUIApp.init 同款做法）.
    static func ensureLayout() throws {
        let fm = FileManager.default
        for dir in [applications, dataApplication, tweaks, rootfs, mntfs] {
            if !fm.fileExists(atPath: dir.path) {
                try fm.createDirectory(at: dir, withIntermediateDirectories: true)
            }
        }
    }

}
