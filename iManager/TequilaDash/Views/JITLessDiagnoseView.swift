import SwiftUI
import UIKit

/// JIT-less 诊断页的宿主包装 (真实内容 = framework 内的 `LCJITLessDiagnoseView`).
///
/// 走 NSClassFromString 反射取 UIViewController: 宿主不能 `import LiveContainerSwiftUI`
/// (会与宿主桥接头重复定义枚举, CI run 42657238035 实测), 所以只能按类名反射.
/// 反射不到 = framework 没链进来, 显示缺失说明而不是空白页 (不留假入口).
struct JITLessDiagnoseView: View {
    var body: some View {
        if let controller = makeController() {
            DiagnoseControllerView(controller: controller)
                .ignoresSafeArea()
        } else {
            ContentUnavailableView("JIT-less 诊断不可用",
                                   systemImage: "exclamationmark.triangle",
                                   description: Text("LiveContainerSwiftUI framework 未链接到本构建"))
        }
    }

    private func makeController() -> UIViewController? {
        guard let cls = NSClassFromString("TDJITLessDiagnoseHost") as? NSObject.Type else {
            return nil
        }
        let sel = NSSelectorFromString("makeViewController")
        guard cls.responds(to: sel),
              let value = cls.perform(sel)?.takeUnretainedValue() as? UIViewController else {
            return nil
        }
        return value
    }
}

/// UIViewController 承载 (UIKit 生命周期交给 controller 自己, SwiftUI 只借位).
private struct DiagnoseControllerView: UIViewControllerRepresentable {
    let controller: UIViewController

    func makeUIViewController(context: Context) -> UIViewController {
        // 套一层 UINavigationController: LCJITLessDiagnoseView 自带 Form 与 toolbar,
        // 但没有导航栏时标题无处显示.
        UINavigationController(rootViewController: controller)
    }

    func updateUIViewController(_ uiViewController: UIViewController, context: Context) {}
}
