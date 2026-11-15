import Foundation
import SwiftUI
import UIKit

/// 外部 IPA 打开入口 (文件 App / 分享面板 / Safari 下载 → 「用 TequilaDash 打开」).
///
/// 为什么需要: `Resources/Info.plist` 的 `CFBundleDocumentTypes` 早就在声明接收
/// `com.apple.itunes.ipa` (LSHandlerRank=Alternate), 但全仓没有 `onOpenURL` /
/// `application(_:open:options:)` 接收方 —— 系统会把 App 拉起来, 然后什么都不发生,
/// 用户看到的是「打开了但没反应」. 本文件补上接收侧, 直接走已有的
/// `SandboxImportService.importIPA` 落进沙盒容器, 不依赖 app group.
///
/// 为什么不用上游 ShareExtension: 那条路要真实 app group entitlement
/// (ShareExtension/ShareExtension.entitlements + LCSharedUtils.appGroupID),
/// 免费账号签不出; 而系统级「用 xx 打开」不需要 app group, 覆盖同一用户需求
/// (拿到一个 .ipa 想装进沙盒), 且走的是本仓已有的导入实现.
@MainActor
enum ExternalIPAOpenHandler {

    /// 从 onOpenURL 的 URL 处理一次打开事件. 非 IPA 一律忽略 (不误报).
    static func handle(_ url: URL) {
        guard let ipaURL = stageIncoming(url) else { return }
        ToastCenter.shared.show("正在导入 \(ipaURL.lastPathComponent)…", seconds: 8.0)
        Task {
            let outcome = await Task.detached(priority: .userInitiated) {
                Result { try SandboxImportService.importIPA(at: ipaURL) }
            }.value
            switch outcome {
            case .success(let result):
                AppHaptics.success()
                let head = result.replaced
                    ? "已覆盖安装 \(result.app.displayName)"
                    : "已导入 \(result.app.displayName)"
                let text = result.warning.map { head + "；" + $0 } ?? head
                ToastCenter.shared.show(text, seconds: 3.4)
                // 让沙盒容器页重扫: 导入是后台完成的, 列表靠这次通知刷新.
                NotificationCenter.default.post(name: .sandboxAppsDidChange, object: nil)
            case .failure(let error):
                ToastCenter.shared.show(error.localizedDescription, seconds: 4.5)
            }
        }
    }

    /// 把外部 URL 拷进本应用沙盒再交给导入器.
    ///
    /// 外部 URL 是 security-scoped (文件 App / 分享面板给的都是), 且导入器要求
    /// 「已在本应用沙盒内的路径」(`SandboxImportService.importIPA` 文档), 所以先拷贝.
    /// 返回 nil = 不是 IPA 或拷贝失败 (已提示).
    private static func stageIncoming(_ url: URL) -> URL? {
        let ext = url.pathExtension.lowercased()
        guard ext == "ipa" else {
            return nil
        }
        let scoped = url.startAccessingSecurityScopedResource()
        defer { if scoped { url.stopAccessingSecurityScopedResource() } }

        let fm = FileManager.default
        let dest = fm.temporaryDirectory
            .appendingPathComponent("Incoming-\(UUID().uuidString).ipa")
        do {
            if fm.fileExists(atPath: dest.path) {
                try fm.removeItem(at: dest)
            }
            try fm.copyItem(at: url, to: dest)
            return dest
        } catch {
            ToastCenter.shared.show("无法读取该 IPA: \(error.localizedDescription)", seconds: 4.5)
            return nil
        }
    }
}
