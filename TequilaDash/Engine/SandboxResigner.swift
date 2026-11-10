//
//  SandboxResigner.swift
//  TequilaDash
//
//  沙盒容器整包重签（v0.3.782）
//  —— 照 LiveContainer 的做法：遍历 .app 内所有 64 位 Mach-O 逐个就地重签，
//  不生成 _CodeSignature/CodeResources、不重打包 IPA。
//  真机事实依据：LC 的 ZSigner signWithAppPath 只把 filesToSign 交给
//  signMachOPathArr，Sign 的 Info.plist hash 与 CodeResources 传空串，
//  系统照样允许容器内加载。
//
//  证书来源：DeveloperCertStore（本机创建或 p12 导入的真开发证书）。
//  与 zsign_sign_file_with_cert 共用同一套前置自愈、UUID 扰动、换 inode 与后置自洽校验。
//

import Foundation

enum SandboxResignError: LocalizedError {
    case noCertificate
    case notADirectory(String)
    case noMachO(String)
    case tempFailure(String)
    case partial(failed: Int, firstPath: String)
    case failed(String)

    var errorDescription: String? {
        switch self {
        case .noCertificate:
            return "没有可用的签名证书. 请先到「更多 → 证书管理」创建或导入 p12."
        case .notADirectory(let path):
            return "包体路径不是目录: \(path)"
        case .noMachO(let path):
            return "包体里没有可签名的 64 位 Mach-O: \(path)"
        case .tempFailure(let detail):
            return "临时文件准备失败: \(detail)"
        case .partial(let failed, let firstPath):
            return "有 \(failed) 个文件签名失败，首个: \(firstPath)"
        case .failed(let detail):
            return "重签失败: \(detail)"
        }
    }
}

struct SandboxResignResult: Sendable {
    let signed: Int
    let failed: Int
    let logPath: String?
    /// true = 签名仍有效, 按 LC 上游口径跳过了重签 (LCAppInfo.m:369-380).
    var skipped: Bool = false

    var summary: String {
        if skipped {
            return "签名有效，已跳过重签"
        }
        if failed == 0 {
            return "已重签 \(signed) 个 Mach-O"
        }
        return "已重签 \(signed) 个，失败 \(failed) 个"
    }
}

enum SandboxResigner {
    /// 对一个容器应用整包重签.
    /// - Parameters:
    ///   - app: 容器内的应用（用 app.appPath 与 app.id）.
    ///   - useMainIdentifier: 传 true 时签名 identifier 用本 App 的 bundle id
    ///     （iOS 27 真机实锤：dlopen 的库 identifier 必须与主程序一致）.
    ///     容器安装场景保持 false，用访客自己的 bundle id.
    ///   - force: false = 先按 LC 上游口径验签, 系统认为有效就跳过整包重签
    ///     （vendor/LiveContainer/LiveContainerSwiftUI/Models/LCAppInfo.m:369-380:
    ///      `if(!forceSign) { if(checkCodeSignature(executablePath)) return; }`）.
    ///     安装/换证书等场景传 true 强制重签.
    static func resign(_ app: SandboxApp,
                       useMainIdentifier: Bool = false,
                       force: Bool = false,
                       debugLog: URL? = nil) throws -> SandboxResignResult {
        let bundleId = useMainIdentifier
            ? (Bundle.main.bundleIdentifier ?? app.id)
            : app.id
        return try resign(appPath: app.appPath, bundleId: bundleId, force: force, debugLog: debugLog)
    }

    /// 直接按路径重签（详情页/调试用）.
    static func resign(appPath: String,
                       bundleId: String,
                       force: Bool = false,
                       debugLog: URL? = nil) throws -> SandboxResignResult {
        // LC 上游同款跳过判断: 主可执行文件的签名被系统接受就不再重签.
        // 与 LCAppInfo.m:369-380 逐字对齐 —— LC 只验主可执行文件, 不遍历包内所有 Mach-O.
        if !force, let skipped = skipIfSignatureValid(appPath: appPath, bundleId: bundleId) {
            return skipped
        }
        guard let material = DeveloperCertStore.shared.certMaterial() else {
            throw SandboxResignError.noCertificate
        }
        var errBuf = [CChar](repeating: 0, count: 512)
        let errCapacity = Int32(errBuf.count)
        var signed: Int32 = 0
        var failed: Int32 = 0
        let rc: Int32 = material.certPem.withUnsafeBytes { certBuf -> Int32 in
            material.keyPem.withUnsafeBytes { keyBuf -> Int32 in
                guard let certPtr = certBuf.baseAddress?.assumingMemoryBound(to: CChar.self),
                      let keyPtr = keyBuf.baseAddress?.assumingMemoryBound(to: CChar.self) else {
                    return -1
                }
                return appPath.withCString { appC in
                    bundleId.withCString { bidC in
                        material.teamId.withCString { teamC in
                            errBuf.withUnsafeMutableBufferPointer { errPtr -> Int32 in
                                zsign_resign_app(appC, bidC,
                                                 certPtr, Int32(material.certPem.count),
                                                 keyPtr, Int32(material.keyPem.count),
                                                 debugLog?.path, teamC,
                                                 &signed, &failed,
                                                 errPtr.baseAddress, errCapacity)
                            }
                        }
                    }
                }
            }
        }
        let detail = String(cString: errBuf)
        switch rc {
        case 0:
            LoginLogger.shared.log("[完成] 沙盒容器重签 \(bundleId) 成功 \(signed) 个 Mach-O")
            return SandboxResignResult(signed: Int(signed), failed: 0, logPath: debugLog?.path)
        case 1:
            LoginLogger.shared.log("[失败] 沙盒容器重签 \(bundleId) 部分失败 \(failed) 个，\(detail)")
            throw SandboxResignError.partial(failed: Int(failed), firstPath: detail)
        case -2:
            throw SandboxResignError.notADirectory(appPath)
        case -3:
            throw SandboxResignError.noMachO(appPath)
        case -4:
            throw SandboxResignError.tempFailure(detail.isEmpty ? "未知" : detail)
        default:
            LoginLogger.shared.log("[失败] 沙盒容器重签 \(bundleId) rc=\(rc) \(detail)")
            throw SandboxResignError.failed(detail.isEmpty ? "rc=\(rc)" : detail)
        }
    }

    /// LC 上游 `patchExecAndSignIfNeed` 的跳过判断（LCAppInfo.m:369-380 逐字对齐）.
    ///
    /// LC 原文只验**主可执行文件**一个 Mach-O：读 Info.plist 的 CFBundleExecutable，
    /// 拼出 `<appPath>/<exe>`，交给 `checkCodeSignature`（内核 fcntl 验签）。
    /// 通过 = 系统已接受这份签名，无需重签，直接放行。
    ///
    /// 返回非 nil = 可跳过（调用方直接返回该结果）；nil = 需要重签.
    private static func skipIfSignatureValid(appPath: String,
                                             bundleId: String) -> SandboxResignResult? {
        let infoPath = (appPath as NSString).appendingPathComponent("Info.plist")
        guard let info = NSDictionary(contentsOfFile: infoPath),
              let exe = info["CFBundleExecutable"] as? String, !exe.isEmpty else {
            // 读不到 Info.plist / 没有 CFBundleExecutable: 不跳过, 交给重签路径报错.
            return nil
        }
        let exePath = (appPath as NSString).appendingPathComponent(exe)
        guard FileManager.default.fileExists(atPath: exePath) else { return nil }
        guard exePath.withCString({ checkCodeSignature($0) }) else { return nil }
        LoginLogger.shared.log("[跳过] \(bundleId) 签名仍有效，跳过重签直接启动")
        return SandboxResignResult(signed: 0, failed: 0, logPath: nil, skipped: true)
    }
}
