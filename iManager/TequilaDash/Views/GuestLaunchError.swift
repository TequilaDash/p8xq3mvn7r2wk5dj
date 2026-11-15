import Foundation
import SwiftUI
import UIKit

/// 访客启动失败遗言的读取与呈现 (LC LCTabView.swift 同构).
///
/// 写入侧在 TequilaDashLiveProcess/LC/LCBootstrap.m: 两条失败路都落盘共享 suite
/// (exceptionHandler 崩溃路 :679 + invokeAppMain 返回路 :835), 配 lastGuestLaunchErrorUptime
/// 单调时间戳 (systemUptime). 本文件只管读侧: 读完即清 (LC LCTabView.swift:170 removeObject 同款).
/// 旁源 = LC 老键 "error" (suite 反射不出时的唯一遗言, 沿用 App 层旧约).
enum GuestLaunchError {
    /// LCSharedUtils.appGroupID 的 Swift 反射读取: LC/ 源码编进主 target,
    /// 房规反射调用不新增编译期符号 (LaunchGuest.m / WallpaperView 同款). 反射不出就不弹, 不猜 suite.
    private static var lcSharedSuiteName: String? {
        guard let cls = NSClassFromString("LCSharedUtils") as? NSObject.Type else { return nil }
        return cls.perform(NSSelectorFromString("appGroupID"))?.takeUnretainedValue() as? String
    }

    /// LC 的 UserDefaults.lcShared() 等价物 (LCUtilsExtension): 同一 appGroupID suite.
    static var sharedDefaults: UserDefaults? {
        lcSharedSuiteName.flatMap { UserDefaults(suiteName: $0) }
    }

    /// 读完即清. 返回 nil = 无遗言.
    ///
    /// 陈旧守卫: 存的 uptime 比现在还大 = 上次开机的旧遗言, 不弹也不清
    /// (留在盘上给 SSH 直读 plist 取证, 下次启动由新记录覆盖).
    static func consumeLastLaunchError() -> String? {
        var message = ""
        if let shared = sharedDefaults {
            let stored = shared.string(forKey: "lastGuestLaunchError") ?? ""
            let storedUptime = shared.double(forKey: "lastGuestLaunchErrorUptime") ?? 0
            guard storedUptime <= ProcessInfo.processInfo.systemUptime else { return nil }
            if !stored.isEmpty {
                message = stored
                shared.removeObject(forKey: "lastGuestLaunchError")
                shared.removeObject(forKey: "lastGuestLaunchErrorUptime")
            }
        }
        if let legacy = UserDefaults.standard.string(forKey: "error") {
            UserDefaults.standard.removeObject(forKey: "error")
            if message.isEmpty {
                message = legacy
            }
        }
        // 无 app group 时的唯一可靠信号 (本仓适配): 宿主重启前落的 pending 标记文件.
        // 写入侧 = Engine/LaunchGuest.m, 清除侧 = LCBootstrap.m（临门一脚前）.
        // 文件仍在 = 上次重启进访客后在启动阶段就退出了, 一个字的遗言都来不及留.
        let host = UserDefaults.standard
        if let marker = host.string(forKey: "TDGuestLaunchMarker") {
            let stillPending = FileManager.default.fileExists(atPath: marker)
            host.removeObject(forKey: "TDGuestLaunchMarker")
            if stillPending {
                if message.isEmpty {
                    let guestName = host.string(forKey: "TDLastGuestName") ?? "访客应用"
                    message = """
                    上次启动 \(guestName) 时, 访客进程在启动阶段退出 (没有异常遗言).

                    标记文件仍在: \(marker)
                    可能原因: 沙盒接管失败 / dyld 注入失败 / 访客二进制架构不符.
                    排查: 控制台过滤 "LCBootstrap" 与 "step" 看最后停在哪一步.
                    """
                }
                try? FileManager.default.removeItem(atPath: marker)
            }
        }
        return message.isEmpty ? nil : message
    }
}

/// LC LCTabView.swift:63-96 同款 sheet: 等宽 12pt + 可选中 + 左上 ShareLink + 右上「好」.
///
/// 本仓部署目标 iOS 18 (project.yml deploymentTarget), ShareLink 恒可用,
/// 免 LC 的 `#available(iOS 16)` 分支 (LC :75-86 的 Button 分支是给 iOS 15 的).
struct GuestLaunchErrorSheet: View {
    let text: String
    // 本仓适配 (2026-11-12): 上游 LC 的「好」按钮是空闭包 `Button("好") {}`，
    // 依赖 .sheet 的下滑手势关闭；本仓 sheet 被更上层 presentation 干扰时手势失效，
    // owner 实测「点了没反应」。显式 dismiss。
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationView {
            ScrollView {
                Text(text)
                    .font(.system(size: 12).monospaced())
                    .fixedSize(horizontal: false, vertical: false)
                    .textSelection(.enabled)
            }
            .frame(maxWidth: .infinity)
            .padding(.horizontal)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    // LC 同款: 有翻译层日志文件优先分享日志, 否则分享错误串 (LCTabView.swift:74-86).
                    if let log = GuestLaunchError.sharedDefaults?.url(forKey: "LC32BitTranslationLayerLogFile") {
                        ShareLink(item: log)
                    } else {
                        ShareLink(item: text)
                    }
                }
                ToolbarItem(placement: .topBarTrailing) {
                    Button("好") { dismiss() }
                }
            }
            .navigationTitle("错误")
            .navigationBarTitleDisplayMode(.inline)
        }
    }
}
