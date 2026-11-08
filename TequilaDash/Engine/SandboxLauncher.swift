//
//  SandboxLauncher.swift
//  TequilaDash
//
//  沙盒容器 · 启动环境（M2）：只给启动链用
//
//  硬约束：本文件**只允许**由「准备启动访客进程」那条链调用，**绝不**能在 App 初始化 /
//  启动早期调用 —— setenv 是进程全局的，提前改掉 CFFIXED_USER_HOME / HOME 会把宿主 App
//  自己的存储（偏好、缓存、Documents）重定向进容器目录，且进程内无法真正撤销.
//
//  移植自 LiveContainer 的 LCBootstrap.m:437-482（家目录块），逐条对齐：
//    · 家目录/tmp 先删旧条目，再 symlink 到进程 TMPDIR（:437-439）
//    · setenv("CFFIXED_USER_HOME", home, 1) / setenv("HOME", home, 1)（:472-473）
//    · **不动 TMPDIR**（:474-475 注释给了理由，见 prepareEnvironment 内）
//    · 预建 Library/Caches、Library/Cookies、Documents、SystemData（:478-482）
//
//  本文件不建家目录：目录模型、建目录、子目录清单都在 SandboxContainerStore，
//  这里只复用它的符号，不另抄一份清单，也不在这里凭空造容器.

import Foundation
#if canImport(Glibc)
import Glibc
#elseif canImport(Darwin)
import Darwin
#endif

enum SandboxLauncher {

    /// 启动环境准备失败的原因.
    ///
    /// 模块里已有的错误类型都不合适：`SandboxImportService.Failure` 绑导入、
    /// `SandboxResignError` 绑重签、`SandboxEscapeError` 绑沙盒扩展签发，语义各属另一条链.
    /// 这里单开一个，只服务「准备访客进程环境」.
    enum LaunchError: Error, LocalizedError, Sendable {
        /// 该应用一份元数据容器都没有（先经 SandboxContainerStore.makeDataHome 建好）.
        case noDataHome(String)
        /// 登记里指向的容器目录不在盘上.
        case dataHomeMissing(String)
        /// 进程环境里没有 TMPDIR：没有可指向的真 tmp，不做假兜底.
        case missingTMPDIR
        /// 删不掉家目录下 tmp 位置的旧条目.
        case tmpLinkCleanupFailed(String, String)
        /// 建 tmp 符号链接失败（附 errno 文本）.
        case tmpSymlinkFailed(String, String)

        var errorDescription: String? {
            switch self {
            case .noDataHome(let name):
                return "「\(name)」还没有可写目录. 先建好元数据容器，再准备启动环境."
            case .dataHomeMissing(let path):
                return "元数据容器目录不在了：\(path). 重新创建后再启动."
            case .missingTMPDIR:
                return "进程环境里没有 TMPDIR，无法给容器建 tmp."
            case .tmpLinkCleanupFailed(let path, let detail):
                return "清不掉旧 tmp 条目：\(path). \(detail)"
            case .tmpSymlinkFailed(let path, let detail):
                return "建 tmp 符号链接失败：\(path). \(detail)"
            }
        }
    }

    /// 一次准备改动了什么（回滚依据）.
    struct PreparedEnvironment: Sendable {
        /// 一个环境变量被覆盖前的样子.
        struct PriorValue: Sendable {
            let name: String
            /// 之前是否设置过. false ⇒ 回滚要 unsetenv，而不是写回空串.
            let existed: Bool
            let value: String?
        }

        /// 访客家目录（即 setenv 写进去的值）.
        let homePath: String
        /// 被覆盖的两个环境变量的原始值.
        let priorValues: [PriorValue]
        /// 我们建出来的 tmp 符号链接，回滚时删掉.
        let tmpLinkPath: String
        /// tmp 位置原本有没有条目：有的话它已被删，回滚也恢复不了，仅作记录.
        let replacedTmpEntry: Bool
    }

    /// 准备访客进程的家目录环境：tmp 符号链接 + 两个环境变量 + 四个子目录.
    ///
    /// 只改进程级环境变量与容器目录，不动任何视图状态、不启任何进程.
    /// - Throws: `LaunchError`（没有家目录 / TMPDIR 缺失 / tmp 链接建不出来）.
    static func prepareEnvironment(for app: SandboxApp) throws -> PreparedEnvironment {
        // 1) 家目录只认登记里已经激活的那一份（SandboxApp.dataPath）。没有就报错，
        //    绝不在这里新建 —— 建目录 + 写登记是 SandboxContainerStore.makeDataHome 的职责，
        //    启动链上游必须先调它（SandboxRuntimeStatus.canLaunch 也是同一门槛）。
        guard let dataPath = app.dataPath else {
            throw LaunchError.noDataHome(app.displayName)
        }
        // hasDataHome 就是「dataPath 非空且目录在盘上」，直接复用，不重写这个判据.
        guard app.hasDataHome else {
            throw LaunchError.dataHomeMissing(dataPath)
        }
        let home = URL(fileURLWithPath: dataPath, isDirectory: true)
        let homePath = home.path
        let fm = FileManager.default

        // 2) tmp：先删旧条目再 symlink 到进程 TMPDIR（LCBootstrap.m:437-439）.
        //    不用 fileExists 判存在：悬空符号链接它也返回 false，那种旧条目会留着让 symlink
        //    报 EEXIST. 先 unlink（连链接本身一起删），ENOENT 就是本来没有；只有旧条目是
        //    真目录时才回落到 FileManager —— libc remove() 删不掉非空目录.
        let tmpDir = getenv("TMPDIR").map { String(cString: $0) } ?? ""
        guard !tmpDir.isEmpty else { throw LaunchError.missingTMPDIR }
        let tmpLinkPath = home.appendingPathComponent("tmp").path
        var replaced = false
        if unlink(tmpLinkPath) == 0 {
            replaced = true
        } else if errno != ENOENT {
            // 不是「本来没有」⇒ 旧条目在（真目录 / 权限不足），交给 FileManager 再试一次.
            do {
                try fm.removeItem(atPath: tmpLinkPath)
                replaced = true
            } catch {
                throw LaunchError.tmpLinkCleanupFailed(tmpLinkPath, error.localizedDescription)
            }
        }
        guard symlink(tmpDir, tmpLinkPath) == 0 else {
            let code = errno
            throw LaunchError.tmpSymlinkFailed(tmpLinkPath, String(cString: strerror(code)))
        }

        // 3) 记下原值再覆盖（第三参数 1 = 覆盖，与 LCBootstrap.m:472-473 同参数）.
        //    TMPDIR 刻意**不改**：有的 App 靠直接删 tmp 目录清缓存，tmp 换成符号链接后
        //    那个目录删不掉也重建不回来（LC #1040 / #1125）；还有 App 会抱怨 tmp 是符号
        //    链接（#884）. 所以只把 家目录/tmp 指过去，进程 TMPDIR 保持系统原值.
        let priorValues = [capture("CFFIXED_USER_HOME"), capture("HOME")]
        // setenv 只在名字非法时失败，这里两个名字都是常量，同 LC 一样不看返回值.
        _ = setenv("CFFIXED_USER_HOME", homePath, 1)
        _ = setenv("HOME", homePath, 1)

        // 4) 四个子目录（LCBootstrap.m:478-482 同一组；缺了访客 App 首次写缓存会崩）.
        //    清单只认 store 的单一来源常量 `containerSubdirectories`，本文件不重写这串字面量.
        //    真正建容器目录的那个 helper（provisionContainer）是 private，且会顺带新建一份
        //    容器 —— 启动链不该在这时造容器，所以这里只按同一份清单补目录.
        for sub in SandboxContainerStore.containerSubdirectories {
            try? fm.createDirectory(at: home.appendingPathComponent(sub, isDirectory: true),
                                    withIntermediateDirectories: true)
        }

        return PreparedEnvironment(homePath: homePath,
                                   priorValues: priorValues,
                                   tmpLinkPath: tmpLinkPath,
                                   replacedTmpEntry: replaced)
    }

    /// 回滚：环境变量还原成准备前的样子（原来不存在就 unsetenv），并清掉我们建的 tmp 链接.
    ///
    /// 只回滚进程环境与 tmp 链接；容器目录与登记不回滚 —— 那是持久化数据，
    /// 由 SandboxContainerStore 管，删掉反而是破坏.
    static func rollback(_ prepared: PreparedEnvironment) {
        for prior in prepared.priorValues {
            if prior.existed, let value = prior.value {
                _ = setenv(prior.name, value, 1)
            } else {
                _ = unsetenv(prior.name)
            }
        }
        // 不用先 fileExists：悬空的符号链接它会返回 false，但同样得清掉.
        try? FileManager.default.removeItem(atPath: prepared.tmpLinkPath)
    }

    /// 读一个环境变量的当前值（含「是否设置过」），供回滚精确还原.
    private static func capture(_ name: String) -> PreparedEnvironment.PriorValue {
        if let raw = getenv(name) {
            return PreparedEnvironment.PriorValue(name: name,
                                                  existed: true,
                                                  value: String(cString: raw))
        }
        return PreparedEnvironment.PriorValue(name: name, existed: false, value: nil)
    }
}
