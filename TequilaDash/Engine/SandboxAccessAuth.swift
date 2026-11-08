import LocalAuthentication

// 沙盒容器 · 锁定认证（owner 2026-11-08: 锁定不能是摆设, 要 Face ID / 密码）
//
// 统一走 `.deviceOwnerAuthentication`（生物识别失败自动回落锁屏密码）——
// 该 policy 不要求 Info.plist 的 NSFaceIDUsageDescription（那是 faceID-only policy 的口径,
// 交接包 02_未完成的活.md 第 7 条已核过）.
//
// LC 同位参照：LCAppListView.swift:540 在启动锁定应用前先验证（isLocked && !isHiddenAppUnlocked）；
// 本仓容器内启动未接线, 认证闸门先落在「进详情页 / 锁定切换 / 隐藏切换」三个入口上.

/// 容器锁定的本机认证入口. 结果三态全部如实上报（不可用 ≠ 拒绝）.
enum SandboxAccessAuth {
    enum Outcome: Equatable {
        /// 验证通过.
        case success
        /// 用户拒绝 / 验证失败.
        case failed
        /// 设备没设锁屏密码, `.deviceOwnerAuthentication` 无法评估 —— 此时锁定不可开,
        /// 否则用户上锁之后就永远解不开了.
        case unavailable
    }

    /// 弹系统认证. `reason` 直接展示在系统弹窗里, 要写清「验证以做什么」.
    ///
    /// LAContext 整个生命周期留在 detached 闭包里, 过 actor 边界的只有 Outcome 值 ——
    /// SWIFT_STRICT_CONCURRENCY: complete 下合法（与 SandboxContainerActions 同一取向）.
    static func authenticate(reason: String) async -> Outcome {
        await Task.detached(priority: .userInitiated) { () -> Outcome in
            let context = LAContext()
            var evalError: NSError?
            guard context.canEvaluatePolicy(.deviceOwnerAuthentication, error: &evalError) else {
                return .unavailable
            }
            do {
                _ = try await context.evaluatePolicy(.deviceOwnerAuthentication, localizedReason: reason)
                return .success
            } catch {
                return .failed
            }
        }.value
    }
}
