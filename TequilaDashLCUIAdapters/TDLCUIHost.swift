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

    /// M44: 沙盒容器 = LC 独占原生窗口 (TDLCWindowController). 供宿主反射调用.
    @objc public static func showSandboxWindow() {
        TDLCWindowController.shared.show()
    }

    /// 供宿主反射调用: 返回包好 LC 原生 UI 的 UIViewController.
    @objc public static func makeTabViewController() -> UIViewController {
        // 标记「由本仓宿主承载」：LC 原生导航栏据此显示返回键（M30）.
        UserDefaults.standard.set(true, forKey: "TDHostedSandbox")
        // 本仓适配 (M34, 2026-11-13): LC 各页的导航栏背景一律透明 ——
        // 否则顶部会出现一条与内容分层明显的白色/材质条（owner 明确要求永久移除）.
        // 只改 UINavigationBar 外观，不动按钮与布局.
        let clear = UINavigationBarAppearance()
        clear.configureWithTransparentBackground()
        clear.shadowColor = .clear
        clear.backgroundColor = .clear
        UINavigationBar.appearance().standardAppearance = clear
        UINavigationBar.appearance().scrollEdgeAppearance = clear
        UINavigationBar.appearance().compactAppearance = clear
        UINavigationBar.appearance().isTranslucent = true
        loadAppsIntoSharedModel()

        // 上游 LCTabView 还声明了 `@EnvironmentObject var sceneDelegate: SceneDelegate`
        // （Views/LCTabView.swift:17）。上游由系统 scene 配置注入
        // （App/AppDelegate.swift:36-40 `configuration.delegateClass = SceneDelegate.self`）。
        // 本仓宿主是 xcodegen 工程、入口在 HostGuestEntry.m，不接管 scene 配置，
        // 因此在 framework 内直接提供一个实例 —— 该类在 framework 模块内可见，
        // 且它的 `window` 为 nil 时 `closeDuplicatedWindow()` 走 else 分支（不崩）。
        // ⚠️ 必须给 sceneDelegate 一个**真实的 window**：
        // LC 的 DocModifier（Utilities/ViewExtensions.swift:105）与
        // TextFieldAlertModifier（:155）都写
        //     sceneDelegate.window?.rootViewController?.present(...)
        // 裸实例的 window 恒 nil → `?.` 短路 → **所有导入/输入弹窗点了没反应**
        // （真机实测：沙盒容器里「+ → 从 IPA 安装」完全静默）.
        // 上游靠系统 scene 配置给这个 window（App/AppDelegate.swift:36-40）；
        // 本仓在 framework 内注入，就显式指向宿主 key window.
        let sceneDelegate = SceneDelegate()
        sceneDelegate.window = TDLCWindowController.shared.isVisible || TDLCWindowController.shared.hostViewController != nil ? TDLCWindowController.shared.hostViewController?.view.window ?? Self.makePresenterWindow() : Self.makePresenterWindow()
        let root = LCTabView()
            .environmentObject(DataManager.shared.model)
            .environmentObject(LCAppSortManager.shared)
            .environmentObject(sceneDelegate)
        let controller = UIHostingController(rootView: root)
        controller.title = "沙盒容器"
        controller.view.backgroundColor = UIColor.systemGroupedBackground
        return controller
    }

    /// 供 `SceneDelegate.window` 用的**转发窗口**.
    ///
    /// 为什么不能直接用宿主 key window：本页在 `fullScreenCover` 里，
    /// 宿主 rootViewController 已有 `presentedViewController`，直接 `present` 会被
    /// 系统拒绝（"Attempt to present ... which is already presenting"）。
    /// 也不能用裸实例（window = nil 时 `?.` 短路，点了完全没反应）。
    ///
    /// 做法：造一个**离屏窗口**，rootViewController 是只重写 `present` 的代理 ——
    /// LC 的 `sceneDelegate.window?.rootViewController?.present(...)` 会走到代理，
    /// 代理再转给当前最顶层可见控制器。代理不调用 super，因此不需要真实窗口层级。
    private static func makePresenterWindow() -> UIWindow {
        // ⚠️ 故意**不挂 windowScene**（真机实测 2026-11-13）：
        // LC 有两处拿 `sceneDelegate.window?.windowScene?.session` 去「销毁场景」：
        //   · LCTabView.swift:149 `closeDuplicatedWindow()` —— 本页每次出现都会跑，
        //     mainWindowOpened 为 true 时直接 requestSceneSessionDestruction。
        //   · MultitaskAppWindow.swift:226 `requestSceneDestruction()`。
        // 本仓只有 TD 这一个 scene；一旦把宿主 scene 的 session 交出去，这两处销毁的
        // 就是宿主自己的场景 → 表现为「再次进入沙盒容器界面整个消失」/「多任务只有 UI 没内容」。
        // 上游能这么做是因为 LC 自己是 App 本体、其 window 就是主场景。
        // 因此这里给一个**无 scene** 的离屏窗口：session 恒 nil，两处销毁都变成静默 no-op。
        // 多任务的 dock 与 guest 窗口走 `UIApplication.shared.connectedScenes.first`
        // （MultitaskDockView.swift:592/775），不依赖本窗口的 windowScene。
        let window = UIWindow(frame: .zero)
        window.frame = .zero
        window.rootViewController = PresenterProxyViewController()
        return window
    }

    /// 顶层可 present 的控制器（沿 presentedViewController 链向下走到底）.
    fileprivate static func topPresenter() -> UIViewController? {
        let scenes = UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }
        var root: UIViewController?
        for scene in scenes {
            if let key = scene.windows.first(where: { $0.isKeyWindow })?.rootViewController {
                root = key
                break
            }
            if root == nil, let any = scene.windows.first?.rootViewController { root = any }
        }
        var top = root
        while let presented = top?.presentedViewController { top = presented }
        return top
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

/// 只重写 `present` 的代理控制器：把 LC 的 present 请求转给当前最顶层可见控制器.
///
/// LC 的 `DocModifier` / `TextFieldAlertModifier` 都写
/// `sceneDelegate.window?.rootViewController?.present(...)`；
/// 本仓把 `window` 指向这个离屏窗口，于是 present 落到这里再转发。
/// 不调用 `super.present` —— 这个控制器不在任何窗口层级里，自己 present 会失败.
final class PresenterProxyViewController: UIViewController {

    override func present(_ viewControllerToPresent: UIViewController,
                          animated flag: Bool,
                          completion: (() -> Void)? = nil) {
        guard let target = TDLCUIHost.topPresenter() else {
            // 没有可用宿主时退到自身（离屏窗口仍能承载，只是不可见）.
            super.present(viewControllerToPresent, animated: flag, completion: completion)
            return
        }
        target.present(viewControllerToPresent, animated: flag, completion: completion)
    }
}
