import SwiftUI
import UIKit

/// 沙盒容器 → 设置 → 右上角「日志」的入口.
///
/// LC 的原生设置页在 `LiveContainerSwiftUI` 框架里，不能 import 主 App 的类型，
/// 所以这里用 `NSClassFromString("TDLogPanelHost")` 反射取主 App 提供的控制器；
/// 取不到就显示明确说明，不留空白页.
struct TDLogPanelSheet: View {
    var body: some View {
        Group {
            if let controller = Self.makeController() {
                TDLogPanelContainer(controller: controller)
            } else {
                ContentUnavailableView(
                    "日志面板不可用",
                    systemImage: "exclamationmark.triangle",
                    description: Text("主 App 未提供 TDLogPanelHost")
                )
            }
        }
        .ignoresSafeArea(edges: .bottom)
    }

    private static func makeController() -> UIViewController? {
        guard let cls = NSClassFromString("TDLogPanelHost") as? NSObject.Type else { return nil }
        let sel = NSSelectorFromString("makeViewController")
        guard cls.responds(to: sel),
              let value = cls.perform(sel)?.takeUnretainedValue() as? UIViewController else {
            return nil
        }
        return value
    }
}

private struct TDLogPanelContainer: UIViewControllerRepresentable {
    let controller: UIViewController

    func makeUIViewController(context: Context) -> UIViewController { controller }
    func updateUIViewController(_ uiViewController: UIViewController, context: Context) {}
}