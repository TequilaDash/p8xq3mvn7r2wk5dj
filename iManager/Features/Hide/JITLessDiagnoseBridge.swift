import SwiftUI
import UIKit

/// 把 framework 内的 `LCJITLessDiagnoseView` 暴露给宿主 (LC 同款 JIT-less 诊断页).
///
/// 为什么需要: `LCJITLessDiagnoseView` 是 framework 内的 internal SwiftUI View, 上游只在
/// `LCSettingsView` 里 NavigationLink 进去 (LCSettingsView.swift:113,140). 本仓宿主不渲染
/// 上游设置页, 若不补入口, 那条诊断路径 (以及它依赖的 Frameworks/TestJITLess.dylib) 就是死件.
///
/// 为什么用 @objc 类而不是 public Swift 类型: 宿主不能 `import LiveContainerSwiftUI`
/// (会与宿主桥接头重复定义枚举, CI run 42657238035 实测), 只能经 NSClassFromString 反射拿
/// UIViewController. 返回类型是 UIKit 的, 不泄漏 framework 的 Swift 类型.
///
/// `LCJITLessDiagnoseView` 读 `@EnvironmentObject SharedModel`, 必须注入 DataManager 单例,
/// 否则首帧崩 (Shared.swift:109).
@objc(TDJITLessDiagnoseHost)
public final class TDJITLessDiagnoseHost: NSObject {
    @objc public static func makeViewController() -> UIViewController {
        let root = LCJITLessDiagnoseView()
            .environmentObject(DataManager.shared.model)
        let controller = UIHostingController(rootView: root)
        controller.title = "JIT-less 诊断"
        controller.navigationItem.title = "JIT-less 诊断"
        return controller
    }
}
