//
//  MainWindow.swift
//  LiveContainerSwiftUI
//

import UIKit

/// Finds zContainer's main window, the one showing the Home Screen, for the
/// code that adds views to it or presents over it: multitasking's virtual
/// windows and their dock, and app windows launched from Objective-C. On iPad
/// several scenes can be connected at once, such as an app's own window or a
/// second zContainer window about to close, so the first connected scene could
/// be any of them. HomeRouter records the scene it accepts as the main window.
@objc final class MainWindow: NSObject {
    /// The scene HomeRouter accepted as the main window, until it disconnects.
    static weak var scene: UIWindowScene?

    /// The visible app-level window in the accepted Home Screen scene. Overlay
    /// and guest windows must never become the dock's geometry/parent source.
    @objc static var window: UIWindow? {
        func appWindow(in scene: UIWindowScene) -> UIWindow? {
            let windows = scene.windows.lazy.filter {
                !$0.isHidden && $0.alpha > 0 && $0.windowLevel == .normal && $0.rootViewController != nil
            }
            return windows.first(where: { $0.isKeyWindow }) ?? windows.first
        }
        if let scene {
            return appWindow(in: scene)
        }
        return UIApplication.shared.connectedScenes.lazy
            .compactMap { $0 as? UIWindowScene }
            .filter { $0.activationState == .foregroundActive && $0.session.role == .windowApplication }
            .compactMap { appWindow(in: $0) }
            .first
    }

    /// Whether a scene is the main window's, or could be: before HomeRouter
    /// has accepted a scene, any scene counts, so the first window to open
    /// isn't left out while it lays out.
    static func isMain(_ candidate: UIWindowScene?) -> Bool {
        guard let scene else {
            return true
        }
        return scene === candidate
    }
}

/// Keep the Home Screen and virtual windows in separate view trees under one
/// UIKit parent. A child of Home cannot have its view outside Home's subtree.
final class MultitaskRootViewController: UIViewController {
    let homeController: UIViewController
    let windowsController: UIViewController

    init(home: UIViewController, windows: UIViewController) {
        homeController = home
        windowsController = windows
        super.init(nibName: nil, bundle: nil)
    }

    required init?(coder: NSCoder) { return nil }

    override func loadView() {
        view = UIView()
        for controller in [homeController, windowsController] {
            addChild(controller)
            controller.view.frame = view.bounds
            controller.view.autoresizingMask = [.flexibleWidth, .flexibleHeight]
            view.addSubview(controller.view)
            controller.didMove(toParent: self)
        }
    }

    override func viewDidLayoutSubviews() {
        super.viewDidLayoutSubviews()
        homeController.view.frame = view.bounds
        windowsController.view.frame = view.bounds
    }

    override var childForStatusBarStyle: UIViewController? { homeController }
    override var childForStatusBarHidden: UIViewController? { homeController }
    override var childForHomeIndicatorAutoHidden: UIViewController? { homeController }
    override var childForScreenEdgesDeferringSystemGestures: UIViewController? { homeController }
    override var supportedInterfaceOrientations: UIInterfaceOrientationMask { homeController.supportedInterfaceOrientations }
}
