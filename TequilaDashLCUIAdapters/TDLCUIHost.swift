import SwiftUI
import UIKit

/// 把 LC 上游原生 UI 接到本仓 —— **完全照上游 `LiveContainerSwiftUIApp` 的方式**，
/// 不额外发明任何东西.
///
/// 上游的接线（vendor/LiveContainer/LiveContainerSwiftUI/App/LiveContainerSwiftUIApp.swift）:
///   · `init()` 扫 `LCPath.bundlePath` 填 `DataManager.shared.model`（:19-101）
///   · `body` 里 `LCTabView()` + `.environmentObject(DataManager.shared.model)`
///     + `.environmentObject(LCAppSortManager.shared)`（:105-108）
///   · `LCTabView` 内部自己 `.environmentObject(downloadHelper)`（Views/LCTabView.swift:53）
///   · `SceneDelegate` 由 `AppDelegate.application(_:configurationForConnecting:)`
///     设 `configuration.delegateClass = SceneDelegate.self`（App/AppDelegate.swift:36-40）
///     交给系统创建，SwiftUI 因此把它放进环境 —— 所以上游**不需要**手动注入 sceneDelegate.
///
/// 本文件只做两件事: ①复刻 init 的扫描 ②用上游同样的两个 environmentObject 包 LCTabView.
/// sceneDelegate 由本仓 `LCUIAppDelegate`（见 AppDelegate 桥）配 delegateClass 提供.
@objc(TDLCUIHost)
public final class TDLCUIHost: NSObject {

    /// 供宿主反射调用: 返回包好 LC 原生 UI 的 UIViewController.
    @objc public static func makeTabViewController() -> UIViewController {
        loadAppsIntoSharedModel()

        let root = LCTabView()
            .environmentObject(DataManager.shared.model)
            .environmentObject(LCAppSortManager.shared)
        let controller = UIHostingController(rootView: root)
        controller.title = "沙盒容器"
        return controller
    }

    /// 复刻上游 `LiveContainerSwiftUIApp.init()` 的扫描（:19-101）.
    ///
    /// 与上游唯一差异: 路径走 `LCPathBridge`（= 本仓 `Documents/`, 与 ObjC 侧
    /// `LC_HOME_PATH` 同源）；上游直接用 `LCPath`（写死 `Documents/`）。
    /// 两边目录口径一致后，这里就是逐行照搬。
    private static func loadAppsIntoSharedModel() {
        let fm = FileManager.default
        let model = DataManager.shared.model
        try? LCPathBridge.ensureLayout()

        var tempApps: [LCAppModel] = []
        var tempArm32: [LCAppModel] = []
        var tempHidden: [LCAppModel] = []
        var tempURLSchemes: Set<String>? = model.multiLCStatus != 2 ? Set() : nil

        if let appDirs = try? fm.contentsOfDirectory(atPath: LCPathBridge.applications.path) {
            for appDir in appDirs where appDir.hasSuffix(".app") {
                let path = LCPathBridge.applications.appendingPathComponent(appDir).path
                guard let info = LCAppInfo(bundlePath: path) else { continue }
                info.relativeBundlePath = appDir
                info.isShared = false
                let appModel = LCAppModel(appInfo: info)
                if info.isHidden {
                    tempHidden.append(appModel)
                } else {
                    tempApps.append(appModel)
                    tempURLSchemes?.formUnion(info.urlSchemes() as? [String] ?? [])
                }
                if info.is32bitEmulator {
                    tempArm32.append(appModel)
                }
            }
        }

        model.apps = tempApps
        model.arm32EmuApps = tempArm32
        model.hiddenApps = tempHidden
        model.appDataFolderNames = subdirectories(at: LCPathBridge.dataApplication)
        model.tweakFolderNames = subdirectories(at: LCPathBridge.tweaks)
        if let tempURLSchemes {
            UserDefaults.lcShared().set(Array(tempURLSchemes), forKey: "LCGuestURLSchemes")
        }
    }

    private static func subdirectories(at url: URL) -> [String] {
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
