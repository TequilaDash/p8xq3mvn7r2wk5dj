import UIKit
import SwiftUI

/// 宿主侧悬浮球: 显示在所有 scene 之上, 可拖拽, 空闲淡出.
/// 设置存 app group, 与 iManager 实验性开关共用.
@objcMembers
final class TDAssistiveTouch: NSObject {
    private static var windows: [String: UIWindow] = [:]
    private static let enabledKey = "TDAssistiveTouch"
    private static let globalKey = "TDAssistiveTouchGlobal"
    private static let positionKey = "TDAssistiveTouchPosition"

    private static var defaults: UserDefaults? {
        UserDefaults(suiteName: LCSharedUtils.appGroupID())
    }

    static var isEnabled: Bool {
        (defaults?.object(forKey: enabledKey) as? Bool) ?? false
    }

    static var isGlobal: Bool {
        (defaults?.object(forKey: globalKey) as? Bool) ?? true
    }

    /// 依据设置安装/移除悬浮球. scene 连上或回到前台时调用.
    @objc static func sync() {
        DispatchQueue.main.async {
            removeAll()
            guard isEnabled else { return }
            let scenes = UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }
            let targets: [UIWindowScene] = isGlobal
                ? scenes
                : Array(scenes.filter { $0.activationState == .foregroundActive }.prefix(1))
            for scene in targets { attach(to: scene) }
        }
    }

    private static func removeAll() {
        for (_, window) in windows {
            window.isHidden = true
            window.rootViewController = nil
        }
        windows.removeAll()
    }

    private static func attach(to scene: UIWindowScene) {
        let key = scene.session.persistentIdentifier
        if windows[key] != nil { return }
        let window = TDAssistiveTouchWindow(windowScene: scene)
        window.windowLevel = .statusBar + 1
        window.backgroundColor = .clear
        let controller = TDAssistiveTouchController()
        controller.onClose = { sync() }
        window.interactiveView = controller.ball
        window.rootViewController = controller
        windows[key] = window
        window.isHidden = false
    }
}

/// 只让悬浮球本身接收触摸, 其余区域把事件透给下层窗口 (访客界面).
private final class TDAssistiveTouchWindow: UIWindow {
    weak var interactiveView: UIView?
    override func hitTest(_ point: CGPoint, with event: UIEvent?) -> UIView? {
        guard let target = interactiveView, !target.isHidden, target.alpha > 0.05 else { return nil }
        let local = target.convert(point, from: self)
        guard target.bounds.contains(local) else { return nil }
        return super.hitTest(point, with: event)
    }
}

private final class TDAssistiveTouchController: UIViewController, UIGestureRecognizerDelegate {
    var onClose: (() -> Void)?

    let ball = UIButton(type: .custom)
    private var idleTimer: Timer?
    private var lastCenter: CGPoint = .zero

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = .clear
        ball.frame = CGRect(x: 0, y: 0, width: 54, height: 54)
        ball.layer.cornerRadius = 27
        ball.layer.cornerCurve = .continuous
        ball.backgroundColor = UIColor.secondarySystemBackground.withAlphaComponent(0.92)
        ball.layer.shadowColor = UIColor.black.cgColor
        ball.layer.shadowOpacity = 0.22
        ball.layer.shadowRadius = 6
        ball.layer.shadowOffset = CGSize(width: 0, height: 2)
        ball.setImage(UIImage(systemName: "circle.grid.cross"), for: .normal)
        ball.tintColor = .label
        ball.addTarget(self, action: #selector(tapped), for: .touchUpInside)
        view.addSubview(ball)

        let pan = UIPanGestureRecognizer(target: self, action: #selector(panned(_:)))
        pan.delegate = self
        ball.addGestureRecognizer(pan)

        if let saved = UserDefaults(suiteName: LCSharedUtils.appGroupID())?.dictionary(forKey: "TDAssistiveTouchPosition"),
           let x = saved["x"] as? CGFloat, let y = saved["y"] as? CGFloat {
            lastCenter = CGPoint(x: x, y: y)
        }
        scheduleIdleFade()
    }

    override func viewDidLayoutSubviews() {
        super.viewDidLayoutSubviews()
        if lastCenter == .zero {
            lastCenter = CGPoint(x: view.bounds.maxX - 70, y: view.bounds.midY)
        }
        clamp(into: view.bounds.size)
        ball.center = lastCenter
    }

    private func clamp(into size: CGSize) {
        let half = ball.bounds.width / 2
        lastCenter.x = min(max(lastCenter.x, half + 8), size.width - half - 8)
        lastCenter.y = min(max(lastCenter.y, half + 60), size.height - half - 8)
    }

    @objc private func panned(_ gesture: UIPanGestureRecognizer) {
        let translation = gesture.translation(in: view)
        lastCenter.x += translation.x
        lastCenter.y += translation.y
        clamp(into: view.bounds.size)
        ball.center = lastCenter
        gesture.setTranslation(.zero, in: view)
        ball.alpha = 1
        if gesture.state == .ended {
            UserDefaults(suiteName: LCSharedUtils.appGroupID())?.set(["x": lastCenter.x, "y": lastCenter.y], forKey: "TDAssistiveTouchPosition")
            scheduleIdleFade()
        }
    }

    @objc private func tapped() {
        ball.alpha = 1
        scheduleIdleFade()
        let sheet = UIAlertController(title: nil, message: nil, preferredStyle: .actionSheet)
        sheet.addAction(UIAlertAction(title: "打开 ConsoleLog", style: .default) { [weak self] _ in
            let controller = UIHostingController(rootView: IManagerConsoleLogView())
            controller.modalPresentationStyle = .pageSheet
            self?.present(controller, animated: true)
        })
        sheet.addAction(UIAlertAction(title: "关闭悬浮球", style: .destructive) { _ in
            UserDefaults(suiteName: LCSharedUtils.appGroupID())?.set(false, forKey: "TDAssistiveTouch")
            TDAssistiveTouch.sync()
        })
        sheet.addAction(UIAlertAction(title: "取消", style: .cancel))
        if let popover = sheet.popoverPresentationController {
            popover.sourceView = ball
            popover.sourceRect = ball.bounds
        }
        present(sheet, animated: true)
    }

    private func scheduleIdleFade() {
        idleTimer?.invalidate()
        idleTimer = Timer.scheduledTimer(withTimeInterval: 3.5, repeats: false) { [weak self] _ in
            UIView.animate(withDuration: 0.35) { self?.ball.alpha = 0.32 }
        }
    }

}
