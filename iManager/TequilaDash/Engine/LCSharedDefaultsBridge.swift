import Foundation

/// 访问 LC 的 app group `UserDefaults`（`NSUserDefaults.lcSharedDefaults`）.
///
/// 为什么需要: LC 侧所有「跨进程共享」的键（`LCCertificatePassword`、`LCCertificateData`、
/// `LCMultitaskMode`、`LCSelected32BitEmulator` 等）都读
/// `NSUserDefaults.lcSharedDefaults` —— 实现在 `LCBootstrap.m:41-45`：
///     [[NSUserDefaults alloc] initWithSuiteName:[LCSharedUtils appGroupID]]
///
/// 本仓宿主是 Swift，不能 `import LiveContainerSwiftUI`（枚举重复定义，CI 42657238035），
/// 所以这里走 ObjC 运行时：取 `NSUserDefaults` 类的 `lcSharedDefaults` 类方法，
/// 拿不到（未链接/无 app group）就返回 nil，调用方回落 `standard`.
///
/// 语义与上游一致:
///   · 有 app group → 返回 group suite（与扩展共享）
///   · 无 app group → `appGroupID` 返回 "Unknown"，suite 仍能创建但仅本进程可见
///   · LC 未链接 → nil
enum LCSharedDefaultsBridge {

    /// LC 的共享 defaults；不可用时返回 nil.
    static func groupDefaults() -> UserDefaults? {
        guard let cls = NSClassFromString("NSUserDefaults") else { return nil }
        let sel = NSSelectorFromString("lcSharedDefaults")
        guard cls.responds(to: sel) else { return nil }
        // 类方法：用 metaclass 调用。Swift 里通过 `cls.perform` 会走实例方法查找，
        // 类方法要走 object_getClass(cls)。
        guard let meta = object_getClass(cls) as? NSObject.Type,
              meta.responds(to: sel) else { return nil }
        return meta.perform(sel)?.takeUnretainedValue() as? UserDefaults
    }
}
