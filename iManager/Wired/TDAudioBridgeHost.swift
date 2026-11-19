import Foundation
import AVFoundation
/// 实验 → 修复音频输入：宿主侧桥。guest（LiveProcess 扩展）没有麦克风 TCC
/// 权限与前台 scene，控制面（AVAudioSession 激活/麦克风授权）由宿主代答；
/// 结果写回 app group。数据面不动。
enum TDAudioBridgeHost {
    private static var defaults: UserDefaults? {
        UserDefaults(suiteName: LCSharedUtils.appGroupID())
    }

    /// 在宿主 App 启动时装一次；iManager 初始化时调用。
    static func install() {
        CFNotificationCenterAddObserver(
            CFNotificationCenterGetDarwinNotifyCenter(),
            nil,
            TDAudioBridgeDarwinCallback,
            "com.td.audioBridge.request" as CFString,
            nil,
            .deliverImmediately
        )
        CFNotificationCenterAddObserver(
            CFNotificationCenterGetDarwinNotifyCenter(),
            nil,
            TDAudioBridgeDarwinCallback,
            "com.td.audioBridge.requestMic" as CFString,
            nil,
            .deliverImmediately
        )
    }

    private static func handleRequests() {
        guard let defaults = defaults, let request = defaults.object(forKey: "TDAudioBridgeRequest") as? [String: Any] else { return }
        defaults.removeObject(forKey: "TDAudioBridgeRequest")
        let session = AVAudioSession.sharedInstance()
        var ok = false
        if let category = request["category"] as? String {
            ok = (try? session.setCategory(AVAudioSession.Category(rawValue: category), options: AVAudioSession.CategoryOptions(rawValue: (request["options"] as? UInt) ?? 0))) != nil
        } else if let active = request["active"] as? Bool {
            ok = (try? session.setActive(active, options: [])) != nil || !active
        }
        defaults.set(ok, forKey: "TDAudioBridgeResult")
    }

    private static func handleMicRequest() {
        guard let defaults = defaults else { return }
        defaults.removeObject(forKey: "TDAudioBridgeRequestMic")
        AVAudioSession.sharedInstance().requestRecordPermission { granted in
            defaults.set(granted, forKey: "TDAudioBridgeMicGranted")
        }
    }
}

private func TDAudioBridgeDarwinCallback(
    _ center: CFNotificationCenter?,
    _ observer: UnsafeMutableRawPointer?,
    _ name: CFNotificationName?,
    _ object: UnsafeRawPointer?,
    _ userInfo: CFDictionary?
) {
    guard let name = name else { return }
    let raw = name.rawValue as String?
    DispatchQueue.main.async {
        switch raw {
        case "com.td.audioBridge.request": TDAudioBridgeHost.handleRequests()
        case "com.td.audioBridge.requestMic": TDAudioBridgeHost.handleMicRequest()
        default: break
        }
    }
}
