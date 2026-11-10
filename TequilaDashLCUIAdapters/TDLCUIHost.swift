import SwiftUI
import UIKit

/// 把 LC 上游原生 UI（`LCTabView` / `LCAppListView` / `LCSettingsView`）接到本仓.
///
/// 为什么需要这一层而不是直接 `import` 用:
/// 宿主不能 `import LiveContainerSwiftUI`（会把 framework 的 ObjC 头拉进同一翻译单元,
/// 与宿主桥接头重复定义枚举, CI run 42657238035 实测）; 而 `LCTabView` 是 SwiftUI View,
/// 不能用 `@_silgen_name` 调. 所以本文件编进 **framework**, 用 `@objc` 暴露一个
/// 返回 `UIViewController` 的工厂, 宿主用 `NSClassFromString` 反射拿.
///
/// 依赖的三个环境对象（缺一个就首帧崩）:
///   · `SharedModel`      — LCTabView/LCAppListView/LCSettingsView 全部 @EnvironmentObject
///   · `LCAppSortManager` — LCAppListView 的排序
///   · `DownloadHelper`   — LCAppListView 的下载进度
///
/// 数据填充: 上游在 `LiveContainerSwiftUIApp.init` 里扫 `LCPath.bundlePath` 填
/// `SharedModel.apps`（App/LiveContainerSwiftUIApp.swift:19-101）. 本桥接复刻同一段,
/// 但容器根用 `LCPathBridge`（指向本仓 `Documents/`, 与 ObjC 侧 `LC_HOME_PATH` 同源）.
@objc(TDLCUIHost)
public final class TDLCUIHost: NSObject {

    /// 供宿主反射调用: 返回包好 LC 原生 UI 的 UIViewController.
    @objc public static func makeTabViewController() -> UIViewController {
        let model = DataManager.shared.model
        model.apps = scanApps()
        model.appDataFolderNames = scanSubdirectories(at: LCPathBridge.dataApplication)
        model.tweakFolderNames = scanSubdirectories(at: LCPathBridge.tweaks)

        let root = LCTabView()
            .environmentObject(model)
            .environmentObject(LCAppSortManager.shared)
            .environmentObject(DownloadHelper())
        let controller = UIHostingController(rootView: root)
        controller.title = "沙盒容器"
        return controller
    }

    /// 复刻 `LiveContainerSwiftUIApp.init` 的扫描（App/LiveContainerSwiftUIApp.swift:19-101）.
    ///
    /// 只做本仓需要的部分: 扫 `Applications/*.app` → `LCAppInfo` → `LCAppModel`;
    /// 隐藏的进 `hiddenApps`, 32 位进 `arm32EmuApps`; 其余进 `apps`.
    private static func scanApps() -> [LCAppModel] {
        let fm = FileManager.default
        try? LCPathBridge.ensureLayout()
        guard let names = try? fm.contentsOfDirectory(atPath: LCPathBridge.applications.path) else {
            return []
        }
        var visible: [LCAppModel] = []
        var hidden: [LCAppModel] = []
        var arm32: [LCAppModel] = []
        for name in names where name.hasSuffix(".app") {
            let path = LCPathBridge.applications.appendingPathComponent(name).path
            guard let info = LCAppInfo(bundlePath: path) else { continue }
            info.relativeBundlePath = name
            info.isShared = false
            let model = LCAppModel(appInfo: info)
            if info.isHidden {
                hidden.append(model)
            } else {
                visible.append(model)
            }
            if info.is32bitEmulator {
                arm32.append(model)
            }
        }
        DataManager.shared.model.hiddenApps = hidden
        DataManager.shared.model.arm32EmuApps = arm32
        return visible
    }

    private static func scanSubdirectories(at url: URL) -> [String] {
        let fm = FileManager.default
        try? fm.createDirectory(at: url, withIntermediateDirectories: true)
        guard let names = try? fm.contentsOfDirectory(atPath: url.path) else { return [] }
        return names.filter { name in
            var isDir: ObjCBool = false
            let full = url.appendingPathComponent(name).path
            return fm.fileExists(atPath: full, isDirectory: &isDir) && isDir.boolValue
        }
    }
}
