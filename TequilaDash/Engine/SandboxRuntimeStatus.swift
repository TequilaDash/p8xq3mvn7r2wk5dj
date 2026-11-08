//
//  SandboxRuntimeStatus.swift
//  TequilaDash
//
//  容器内启动的前置判定（LiveContainer 同口径）：JIT 是否已生效、是否必须走 JITLess、
//  开发证书是否就绪. 判据全部来自上游 LCBootstrap.m:85-102 与 :256-270 的实测逻辑，
//  不靠猜：
//    · csops(getpid(), CS_OPS_STATUS, &flags, 4) 读自身代码签名标志，CS_DEBUGGED(0x10000000)
//      是「调试器已附加并生效」的内核级判据（桥接头 :18-22 已声明 csops，v0.3.8 起就在用）；
//      iOS 27 beta 实锤：mmap MAP_JIT 成功但执行仍被 CODESIGNING Invalid Page 杀，
//      所以不能用 mmap 探测代替 csops.
//    · access("/usr/lib/systemhook.dylib", R_OK) == 0 ⇒ 已越狱（上游同一判据，排在 csops 之前）.
//    · iOS 26 起无证书时上游直接拒绝 JIT 路径（invokeAppMain:258-260），必须 JITLess.
//    · 有证书（DeveloperCertStore.hasCert）时上游跳过 JIT 检查走 JITLess 重签.
//
//  本文件只做**只读判定**，不改任何状态、不启任何进程；启动器（M2-M5）接它做门禁.

import Foundation
import UIKit

/// 容器运行机制的三态判定结果.
enum SandboxJITMode: String, Sendable {
    /// JIT 已生效（StikDebug/debugserver 附加，或已越狱）—— 未加密包可直接跑.
    case jit
    /// 需要 JITLess：iOS 26+ 且无 JIT，或用户显式选了证书重签路线.
    case jitLess
    /// 两条路都不通：既没 JIT 也没证书.
    case unavailable

    var label: String {
        switch self {
        case .jit: return "JIT"
        case .jitLess: return "JITLess"
        case .unavailable: return "不可用"
        }
    }
}

/// 一次判定的完整快照（值类型，可跨线程传）.
struct SandboxRuntimeSnapshot: Sendable {
    /// 自身是否带 CS_DEBUGGED.
    let debuggerAttached: Bool
    /// /usr/lib/systemhook.dylib 可读 ⇒ 越狱环境.
    let jailbreakDetected: Bool
    /// iOS 26 及以上：无 JIT 时上游硬拒.
    let requiresJITLessByOS: Bool
    /// 开发证书 + 私钥是否都在盘上.
    let hasDeveloperCert: Bool
    /// 最终模式.
    let mode: SandboxJITMode
    /// 一句话结论，直接进 UI.
    let detail: String

    /// 能不能启动容器内的 guest.
    var canLaunch: Bool { mode != .unavailable }
}

enum SandboxRuntimeStatus {

    /// CS_DEBUGGED：调试器已附加（上游 utils.h:CS_DEBUGGED 0x10000000）.
    private static let csDebugged: UInt32 = 0x10000000
    /// CS_OPS_STATUS = 0，csops 的唯一用到的 ops 值.
    private static let csOpsStatus: UInt32 = 0
    /// 上游判越狱用的同一个路径.
    private static let systemhookPath = "/usr/lib/systemhook.dylib"

    /// 读自身 csflags. csops 返回 -1 时 flags 保持 0（等价「无 JIT」），不抛错.
    static func codeSignFlags() -> UInt32 {
        var flags: UInt32 = 0
        // csops 失败返回 -1 且 flags 保持 0，等价「无 JIT」，不需要额外分支
        _ = csops(getpid(), csOpsStatus, &flags, MemoryLayout<UInt32>.size)
        return flags
    }

    /// JIT 是否已生效（上游 checkJITEnabled 的等价实现，去掉 LCIgnoreJITOnLaunch 开关）.
    static func isJITEnabled() -> Bool {
        if access(systemhookPath, R_OK) == 0 { return true }
        return (codeSignFlags() & csDebugged) != 0
    }

    /// iOS 26+ 无证书时上游硬拒 JIT 路线 ⇒ 我们必须照搬这个门槛，不许给用户假希望.
    static func requiresJITLessByOS() -> Bool {
        if #available(iOS 26.0, *) { return true }
        return false
    }

    /// 完整判定. hasCert 从主线程外读是安全的（DeveloperCertStore 头注 :14-17 已约定
    /// 后台线程只读这两个 Bool）.
    static func snapshot() -> SandboxRuntimeSnapshot {
        let jailbreak = jailbreakDetectedNow()
        let debuggerAttached = (codeSignFlags() & csDebugged) != 0
        let jit = debuggerAttached || jailbreak
        let osNeedsJITLess = requiresJITLessByOS()
        let hasCert = DeveloperCertStore.shared.hasCert

        var mode: SandboxJITMode = .unavailable
        var detail = ""
        if jit {
            mode = .jit
            detail = jailbreak ? "越狱环境已接管，JIT 可直接用." : "JIT 已生效（调试器已附加）."
        } else if hasCert {
            mode = .jitLess
            detail = "无 JIT，走 JITLess：用开发证书重签 guest 后加载.";
        } else if osNeedsJITLess {
            mode = .unavailable
            detail = "iOS 26 起无 JIT 必须走 JITLess，请先在「证书管理」里准备好开发证书.";
        } else {
            mode = .unavailable
            detail = "JIT 未生效且无开发证书：先用「启动应用」页给本 App 开 JIT，或导入证书.";
        }

        return SandboxRuntimeSnapshot(debuggerAttached: debuggerAttached,
                                        jailbreakDetected: jailbreak,
                                        requiresJITLessByOS: osNeedsJITLess,
                                        hasDeveloperCert: hasCert,
                                        mode: mode,
                                        detail: detail)
    }

    private static func jailbreakDetectedNow() -> Bool {
        return access(systemhookPath, R_OK) == 0
    }

    /// 单个容器是否具备启动条件（在运行机制判定之上叠加包体判定）.
    /// 返回 (可否, 原因). 原因直接进 UI，不许空串.
    static func canLaunch(_ app: SandboxApp) -> (Bool, String) {
        let snap = snapshot()
        if !app.hasDataHome {
            return (false, "还没有可写目录：先点「创建可写目录」.")
        }
        if app.executable == nil {
            return (false, "包体里找不到主可执行文件，重新导入试试.")
        }
        if !snap.canLaunch {
            return (false, snap.detail)
        }
        return (true, snap.detail)
    }
}
