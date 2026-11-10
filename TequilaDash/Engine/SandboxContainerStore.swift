import Foundation

// 沙盒容器 · 引擎
//
// 目录模型照 LiveContainer（不是照它的注入模型）：
//   · 一个 IPA 进来 → 解包到 Documents/SandboxApps/Applications/<名字>.app
//   · 每次安装配一个独立元数据家目录 Documents/SandboxApps/Data/Application/<UUID>/
//   · 清单**不落台账**，一律由磁盘现状推导（与 ImportedPackageList 同一取向）
//
// 边界（重要）：
//   · 本文件只做「容器目录 + 导入 + 体检 + 删除」，**不启动访客进程**。启动要复刻
//     LiveContainer 的进程内 dlopen + LC_MAIN 跳转（getAppEntryPoint / overwriteMainNSBundle /
//     CFFIXED_USER_HOME 那一整套），属独立阶段，见 02_审计与报告/修复记录/sandbox-container.md。
//   · 加密包（FairPlay，主二进制 cryptid != 0）**直接拒收**：LiveContainer 同样拒收
//     （LCAppInfo.m:341 "The app you tried to install is encrypted. Please provide decrypted app."），
//     理由一致 —— 解密后的代码页在无 JIT 的进程里无法映射执行。
//   · 不做整包重签：ZSign 只暴露单文件签名入口（zsign_sign_file_with_cert），整包还要自己
//     递归 PlugIns / Frameworks 并重写 _CodeSignature/CodeResources，属独立阶段。

// MARK: - 元数据模型

/// 一个应用的一份元数据家目录（LiveContainer 的 `LCContainer` 同型）。
///
/// `folderName` 就是 Data/Application/ 下的 UUID 目录名，是这份容器的**磁盘身份**；
/// `name` 是用户起的显示名（LCContainer.name），两者都可以改，改的只是登记 / 目录里的
/// info plist，目录名本身不动 —— 动目录名会让已经写进 guest Preferences 的路径失效.
struct SandboxContainerRef: Identifiable, Hashable, Sendable {
    /// Data/Application/<folderName> 的目录名（UUID）.
    let folderName: String
    /// 用户可见名字. 没起过名时 = folderName 的前 8 位（LiveContainer 迁移旧 dataUUID 时
    /// 直接把 UUID 当名字，这里取短一点，列表里不至于撑成一整行）.
    let name: String

    var id: String { folderName }
}

/// 一个沙盒容器里的应用。
///
/// `id` 取 bundleId —— 列表横幅、`navigationDestination(item:)`、图标缓存都按它认人，
/// 所以身份**不能**挪到容器上（一份 App 有多份容器，bundleId 才是「这个 App」）。
///
/// 同一个 bundleId 曾经只允许一份容器；该约束已由 owner 决定解除（照 LiveContainer 完整移植：
/// 一个 App 可以有多份互相隔离的元数据目录）。多份并存后「用户点的是哪一份」
/// 由**登记里的 activeDataUUID 指针**唯一确定，即 `activeContainer` / `dataPath`，
/// 不再是「同 bundleId 只能有一份」这种靠唯一性隐式消歧。
struct SandboxApp: Identifiable, Hashable, Sendable {
    let id: String                 // bundleId
    let displayName: String
    let bundleVersion: String?
    let executable: String?
    let appPath: String            // .../Applications/<名字>.app
    /// **当前激活**容器（`activeContainer`）的目录路径；没有容器时为 nil.
    let dataPath: String?
    let installedAt: Date?
    let sizeBytes: Int64
    /// 锁定：删除容器前必须先过一道确认（LCAppInfo.isLocked 同口径）.
    let isLocked: Bool
    /// 隐藏：锁定的**子选项**（LCAppSettingsView:220-231）—— `isHidden` 为真时 `isLocked` 必为真.
    let isHidden: Bool
    /// 该应用的全部元数据容器（按登记顺序，新容器在后）.
    let containers: [SandboxContainerRef]
    /// 当前激活容器的 `folderName`；没有容器时 nil.
    let activeContainer: String?

    var sizeText: String { IPADownloadLibrary.sizeText(sizeBytes) }

    /// 当前激活容器的显示名（横幅上那一行；LCAppBannerView.swift:147 同位置）.
    var activeContainerName: String? {
        guard let activeContainer else { return nil }
        return containers.first { $0.folderName == activeContainer }?.name
    }

    /// 元数据家目录是否已就绪（没有 = 还没启动过）。
    var hasDataHome: Bool {
        guard let dataPath else { return false }
        return FileManager.default.fileExists(atPath: dataPath)
    }
}

/// 容器根下的持久化登记：只记**磁盘推不出来的那几项**（安装时间、元数据目录 UUID）。
///
/// 原则同 ImportedPackageList：能扫出来的绝不再存一份，存了就必须容忍它缺失 / 损坏
/// （读不出就当没有，绝不因此让列表变空）。
///
/// 锁定 / 隐藏也在这里，因为它们是**磁盘上没有真源的用户开关**：显示名和安装时间还能
/// 从 Info.plist / 目录日期扫回来，这两个只能由用户点出来，不存就必然丢。
///
/// 容器的**名字**不在这里 —— 它写在容器目录自己的 `SandboxContainerInfo.plist` 里
/// （LCContainerInfo.plist 同位置），删目录即删名字，不会留下孤儿条目。
private struct SandboxRegistry {
    struct Entry {
        var displayName: String?
        /// 该应用的全部容器目录名（旧版本只有单值 `dataUUID`，读的时候自动迁移）.
        var dataUUIDs: [String] = []
        /// 当前激活容器；必须落在 `dataUUIDs` 里，否则读的时候回落第一个.
        var activeDataUUID: String?
        var installedAt: Date?
        /// 锁定状态（缺省 = 未锁定）.
        var isLocked: Bool = false
        /// 隐藏状态（缺省 = 不隐藏）. 隐藏是锁定的子选项，只能经
        /// `SandboxContainerStore.setAccess` 写入，由它维持「隐藏 ⇒ 锁定」.
        var isHidden: Bool = false
    }

    var entries: [String: Entry] = [:]

    static func load(from url: URL) -> SandboxRegistry {
        var reg = SandboxRegistry()
        guard let data = try? Data(contentsOf: url),
              let plist = try? PropertyListSerialization.propertyList(from: data, options: [], format: nil),
              let root = plist as? [String: Any],
              let apps = root["apps"] as? [String: Any] else { return reg }
        for (bundleId, raw) in apps {
            guard let dict = raw as? [String: Any] else { continue }
            // 迁移：单值 dataUUID（v0.3.785 及以前）→ 单元素数组 + 激活它就是它.
            // 读不出就当没有，绝不让这一条登记消失.
            let legacy = dict["dataUUID"] as? String
            let listed = (dict["dataUUIDs"] as? [String]) ?? []
            // 去重（保留首次出现顺序）：`folderName` 就是 `SandboxContainerRef.id`，
            // 手工改坏的 plist 里重复一个 UUID 会让 ForEach 拿到重复 id，SwiftUI 行身份撞车.
            var seenUUIDs: Set<String> = []
            let uuids = (listed.isEmpty ? [legacy].compactMap { $0 } : listed).filter {
                !$0.isEmpty && seenUUIDs.insert($0).inserted
            }
            let storedActive = dict["activeDataUUID"] as? String
            // 激活指针必须落在去重后的数组里，否则回落第一份 —— 死指针会让 UI 显示
            // 一个已经不存在的「使用中」容器.
            let active = uuids.contains(storedActive ?? "") ? storedActive : uuids.first
            reg.entries[bundleId] = Entry(
                displayName: dict["displayName"] as? String,
                dataUUIDs: uuids,
                activeDataUUID: active,
                installedAt: dict["installedAt"] as? Date,
                isLocked: dict["isLocked"] as? Bool ?? false,
                isHidden: dict["isHidden"] as? Bool ?? false
            )
        }
        return reg
    }

    func save(to url: URL) {
        var apps: [String: Any] = [:]
        for (bundleId, entry) in entries {
            var dict: [String: Any] = [:]
            dict["displayName"] = entry.displayName
            dict["dataUUIDs"] = entry.dataUUIDs
            dict["activeDataUUID"] = entry.activeDataUUID
            dict["installedAt"] = entry.installedAt
            dict["isLocked"] = entry.isLocked
            dict["isHidden"] = entry.isHidden
            apps[bundleId] = dict
        }
        let root: [String: Any] = ["version": 2, "apps": apps]
        guard let data = try? PropertyListSerialization.data(fromPropertyList: root,
                                                             format: .xml,
                                                             options: 0) else { return }
        try? data.write(to: url, options: .atomic)
    }
}

// MARK: - 容器根与清单

enum SandboxContainerStore {

    /// 容器根：`Documents/`（**与 LC 上游 `LCPath.docPath` 完全一致**）.
    ///
    /// v0.3.801 根因修复: 原先是 `Documents/SandboxApps/`, 与 LC 的 `LCPath.docPath`
    /// (= `Documents/`, vendor/LiveContainer/LiveContainerSwiftUI/Utilities/Shared.swift:15)
    /// 差一层前缀, 导致同一份容器出现两套路径:
    ///   · ObjC 访客启动读 `LC_HOME_PATH` → `Documents/SandboxApps/Applications/...`
    ///   · LC 原生 UI 读 `LCPath.docPath`   → `Documents/Applications/...`
    /// 列表看不到可启动的 App、安装落到另一处 —— 这是「逻辑不通」的真正根因.
    /// 对齐到 `Documents/` 后, LC 的 `LCTabView`/`LCAppListView` 可以零改动直接接管,
    /// 且 ObjC 侧 `LC_HOME_PATH` 也指向同一处 (HostGuestEntry.m 同步改).
    ///
    /// 放 Documents 下（不是 Caches）的理由与 Imports 一致：用户能在「文件」App 里看见、
    /// 能用 Finder 拷走整份容器；Caches 会被系统在空间紧张时清掉，容器被清等于装的应用凭空消失。
    static var root: URL {
        URL(fileURLWithPath: FileSystemRoots.appDocuments, isDirectory: true)
    }

    /// 旧版容器根（v0.3.800 及之前）. 仅用于一次性迁移, 不要在新代码里引用.
    static var legacyRoot: URL {
        root.appendingPathComponent("SandboxApps", isDirectory: true)
    }

    /// 把旧 `Documents/SandboxApps/` 的内容搬进 `Documents/`（幂等, 只搬一次）.
    ///
    /// 搬的是 LC 布局的三个子目录 + 登记文件; 目标已存在则不覆盖（避免破坏新装的应用）.
    /// 迁移完保留空目录（不删）, 万一回滚旧版本还能找到东西.
    static func migrateLegacyLayoutIfNeeded() {
        let fm = FileManager.default
        let legacy = legacyRoot
        guard fm.fileExists(atPath: legacy.path) else { return }
        for name in ["Applications", "Data", "Tweaks", "containers.plist"] {
            let src = legacy.appendingPathComponent(name)
            guard fm.fileExists(atPath: src.path) else { continue }
            let dst = root.appendingPathComponent(name)
            if fm.fileExists(atPath: dst.path) { continue }
            try? fm.moveItem(at: src, to: dst)
            LoginLogger.shared.log("[迁移] 容器布局 SandboxApps/\(name) → \(name)")
        }
    }


    static var applicationsDirectory: URL { root.appendingPathComponent("Applications", isDirectory: true) }
    static var dataDirectory: URL { root.appendingPathComponent("Data/Application", isDirectory: true) }
    static var registryURL: URL { root.appendingPathComponent("containers.plist") }

    static func ensureRoot() throws {
        let fm = FileManager.default
        for dir in [root, applicationsDirectory, dataDirectory] where !fm.fileExists(atPath: dir.path) {
            try fm.createDirectory(at: dir, withIntermediateDirectories: true)
        }
    }

    /// 容器目录里那份 info plist 的文件名（LCContainerInfo.plist 同位置）：只存容器自己的
    /// 显示名，删目录即删名字，不产生孤儿登记.
    static let containerInfoFileName = "SandboxContainerInfo.plist"

    /// 访客 App 期望的子目录（LiveContainer 同样预建，缺了会在首次写缓存时崩）.
    static let containerSubdirectories = ["Library/Caches", "Library/Cookies", "Documents", "SystemData"]

    // MARK: 清单（扫盘推导）

    /// 扫容器目录，返回全部应用（按安装时间倒序，读不出时间排最后）。
    ///
    /// 每一项都必须有磁盘证据：Applications/<x>.app/Info.plist 能读出 CFBundleIdentifier 才算一条；
    /// 读不出就跳过并记日志（半截目录 / 用户手动改坏的情况），**绝不凭空补一条**。
    static func scan() -> [SandboxApp] {
        let fm = FileManager.default
        guard let names = try? fm.contentsOfDirectory(atPath: applicationsDirectory.path) else { return [] }
        let registry = SandboxRegistry.load(from: registryURL)
        var apps: [SandboxApp] = []
        // 一个 bundleId 只能出一条：`id` 就是 bundleId，`ForEach` 与
        // `navigationDestination(item:)` 都按它认人，重复 id 会让 SwiftUI 行身份撞车.
        // 正常流程下同一 bundleId 只有一份 .app（导入时覆盖），这里兜的是用户手工拷进来的情况.
        var seen: Set<String> = []
        for name in names.sorted() where name.hasSuffix(".app") {
            let appPath = applicationsDirectory.appendingPathComponent(name, isDirectory: true).path
            guard let info = readInfoPlist(appBundlePath: appPath),
                  let bundleId = info["CFBundleIdentifier"] as? String,
                  !bundleId.isEmpty else {
                LoginLogger.shared.log("[沙盒容器] 跳过无法识别的容器目录：\(name)", category: .general)
                continue
            }
            guard seen.insert(bundleId).inserted else {
                LoginLogger.shared.log("[沙盒容器] 同一 bundleId 有多份包体，只认第一份：\(name)",
                                       category: .general)
                continue
            }
            let entry = registry.entries[bundleId]
            let containers = (entry?.dataUUIDs ?? []).map {
                SandboxContainerRef(folderName: $0, name: containerName(folderName: $0))
            }
            let active = entry?.activeDataUUID.flatMap { id in
                containers.contains { $0.folderName == id } ? id : nil
            } ?? containers.first?.folderName
            let registeredName = entry?.displayName ?? ""
            let displayName = registeredName.isEmpty
                ? ((info["CFBundleDisplayName"] as? String)
                   ?? (info["CFBundleName"] as? String)
                   ?? (name as NSString).deletingPathExtension)
                : registeredName
            apps.append(SandboxApp(
                id: bundleId,
                displayName: displayName,
                bundleVersion: info["CFBundleShortVersionString"] as? String,
                executable: info["CFBundleExecutable"] as? String,
                appPath: appPath,
                dataPath: active.map { containerPath(folderName: $0) },
                installedAt: entry?.installedAt ?? directoryDate(appPath),
                sizeBytes: directorySize(appPath),
                // 隐藏是锁定的子选项：登记里若只有 isHidden（手工改坏的 plist），仍然算锁定.
                isLocked: (entry?.isLocked ?? false) || (entry?.isHidden ?? false),
                isHidden: entry?.isHidden ?? false,
                containers: containers,
                activeContainer: active
            ))
        }
        return apps.sorted {
            switch ($0.installedAt, $1.installedAt) {
            case let (l?, r?): return l > r
            case (_?, nil): return true
            case (nil, _?): return false
            default: return $0.displayName.localizedStandardCompare($1.displayName) == .orderedAscending
            }
        }
    }

    /// 读容器内 Info.plist（纯读取，不改字节）。
    static func readInfoPlist(appBundlePath: String) -> [String: Any]? {
        let url = URL(fileURLWithPath: appBundlePath, isDirectory: true)
            .appendingPathComponent("Info.plist")
        guard let data = try? Data(contentsOf: url),
              let plist = try? PropertyListSerialization.propertyList(from: data, options: [], format: nil)
        else { return nil }
        return plist as? [String: Any]
    }

    // MARK: 元数据家目录

    /// 容器目录的绝对路径（`folderName` 就是目录名）.
    static func containerPath(folderName: String) -> String {
        dataDirectory.appendingPathComponent(folderName, isDirectory: true).path
    }

    /// 容器显示名：写在容器目录自己的 info plist 里（LCContainerInfo.plist 同位置），
    /// 读不出就回落 UUID 前 8 位 —— 目录在手，名字丢了也不至于让这一行变空.
    static func containerName(folderName: String) -> String {
        let url = dataDirectory.appendingPathComponent(folderName, isDirectory: true)
            .appendingPathComponent(containerInfoFileName)
        if let data = try? Data(contentsOf: url),
           let plist = try? PropertyListSerialization.propertyList(from: data, options: [], format: nil),
           let dict = plist as? [String: Any],
           let name = dict["name"] as? String,
           !name.isEmpty {
            return name
        }
        return String(folderName.prefix(8))
    }

    /// 取（必要时新建）该应用**当前激活**容器的家目录。
    ///
    /// 目录名用 UUID（不用 bundleId）：LiveContainer 同型，理由是访客 App 会把 bundleId
    /// 当成自己的标识写进 Preferences / 缓存路径，目录名与 bundleId 脱钩后，用户重装同款
    /// App 可以拿到全新元数据目录而不与旧元数据混在一起。
    ///
    /// 多容器下的语义（启动器 SandboxLauncher 依赖它）：返回**激活**那一份；一份都没有时
    /// 建一份并激活它；登记指向的目录已被删掉时补一个新 UUID 并改激活指针。
    @discardableResult
    static func makeDataHome(for app: SandboxApp) throws -> URL {
        try ensureRoot()
        var registry = SandboxRegistry.load(from: registryURL)
        var entry = registry.entries[app.id] ?? SandboxRegistry.Entry()
        // 激活指针有效且目录还在 ⇒ 直接用它（幂等路径，启动器每次启动都走这里）.
        if let active = entry.activeDataUUID, entry.dataUUIDs.contains(active) {
            let existing = dataDirectory.appendingPathComponent(active, isDirectory: true)
            if FileManager.default.fileExists(atPath: existing.path) { return existing }
            // 目录被删了：把死指针摘掉，下面按「没有可用容器」处理.
            entry.dataUUIDs.removeAll { $0 == active }
            entry.activeDataUUID = nil
        }
        // 指针为空但登记里还有别的容器（手工改过的 plist）：认领第一个目录还在的，
        // 不新建 —— 凭空多一份容器会让用户以为自己点错了.
        if entry.activeDataUUID == nil {
            let alive = entry.dataUUIDs.first {
                FileManager.default.fileExists(atPath: containerPath(folderName: $0))
            }
            if let alive {
                entry.activeDataUUID = alive
                entry.dataUUIDs.removeAll { !FileManager.default.fileExists(atPath: containerPath(folderName: $0)) }
                registry.entries[app.id] = entry
                registry.save(to: registryURL)
                return dataDirectory.appendingPathComponent(alive, isDirectory: true)
            }
        }
        let folderName = try provisionContainer(folderName: UUID().uuidString, name: nil,
                                                bundleId: app.id)
        entry.dataUUIDs.append(folderName)
        entry.activeDataUUID = folderName
        entry.displayName = entry.displayName ?? app.displayName
        entry.installedAt = entry.installedAt ?? app.installedAt
        registry.entries[app.id] = entry
        registry.save(to: registryURL)
        return dataDirectory.appendingPathComponent(folderName, isDirectory: true)
    }

    /// 给该应用新建一份**额外**的元数据容器，并把它设为激活（LCAppModel:222-224 同口径）.
    @discardableResult
    static func createDataContainer(for app: SandboxApp, name: String? = nil) throws -> SandboxContainerRef {
        try ensureRoot()
        var registry = SandboxRegistry.load(from: registryURL)
        var entry = registry.entries[app.id] ?? SandboxRegistry.Entry()
        let folderName = try provisionContainer(folderName: UUID().uuidString, name: name,
                                                bundleId: app.id)
        entry.dataUUIDs.append(folderName)
        entry.activeDataUUID = folderName
        entry.displayName = entry.displayName ?? app.displayName
        entry.installedAt = entry.installedAt ?? app.installedAt
        registry.entries[app.id] = entry
        registry.save(to: registryURL)
        return SandboxContainerRef(folderName: folderName, name: containerName(folderName: folderName))
    }

    /// 切换激活容器（只改指针，不动任何目录）.
    static func setActiveContainer(for app: SandboxApp, folderName: String) {
        var registry = SandboxRegistry.load(from: registryURL)
        guard var entry = registry.entries[app.id], entry.dataUUIDs.contains(folderName) else { return }
        entry.activeDataUUID = folderName
        registry.entries[app.id] = entry
        registry.save(to: registryURL)
    }

    /// 重命名一份容器（写容器目录里的 info plist；目录名不动，见 `SandboxContainerRef` 注释）.
    static func renameDataContainer(for app: SandboxApp, folderName: String, to newName: String) {
        let trimmed = newName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        var registry = SandboxRegistry.load(from: registryURL)
        guard let entry = registry.entries[app.id], entry.dataUUIDs.contains(folderName) else { return }
        let dir = dataDirectory.appendingPathComponent(folderName, isDirectory: true)
        guard FileManager.default.fileExists(atPath: dir.path) else { return }
        let url = dir.appendingPathComponent(containerInfoFileName)
        var dict: [String: Any] = ["name": trimmed]
        if let data = try? Data(contentsOf: url),
           let plist = try? PropertyListSerialization.propertyList(from: data, options: [], format: nil),
           let existing = plist as? [String: Any] {
            dict = existing
            dict["name"] = trimmed
        }
        guard let data = try? PropertyListSerialization.data(fromPropertyList: dict,
                                                             format: .xml,
                                                             options: 0) else { return }
        try? data.write(to: url, options: .atomic)
    }

    /// 删除**单份**元数据容器（与 `remove(_:)` 删整个 App 是两回事）.
    ///
    /// 删的是激活那一份时，指针顺移到剩下的第一份；一份不剩就置空 —— 此时 App 仍在列表里，
    /// 详情页显示「没有容器」，可以再建.
    static func deleteDataContainer(for app: SandboxApp, folderName: String) -> RemoveResult {
        var registry = SandboxRegistry.load(from: registryURL)
        guard var entry = registry.entries[app.id], entry.dataUUIDs.contains(folderName) else {
            return .notFound
        }
        let dir = dataDirectory.appendingPathComponent(folderName, isDirectory: true)
        let fm = FileManager.default
        var existed = false
        if fm.fileExists(atPath: dir.path) {
            existed = true
            do {
                try fm.removeItem(at: dir)
            } catch {
                // 目录删不掉就不动登记：登记与磁盘不一致比「删了个假的」更难查.
                return .failed(error.localizedDescription)
            }
        }
        entry.dataUUIDs.removeAll { $0 == folderName }
        if entry.activeDataUUID == folderName {
            entry.activeDataUUID = entry.dataUUIDs.first
        }
        registry.entries[app.id] = entry
        registry.save(to: registryURL)
        return existed ? .removed : .notFound
    }

    /// 建目录 + 四个访客 App 期望的子目录（LiveContainer 同样预建，缺了会在首次写缓存时崩）.
    ///
    /// 单点：`makeDataHome` 与 `createDataContainer` 都走这里，子目录清单只有一份.
    ///
    /// info plist 里同时记 `bundleId`（LC 的 LCContainerInfo.plist 记 appIdentifier 同位置）：
    /// 目录因此自带归属，删 App 时能扫出「登记已丢但目录还在」的残留.
    private static func provisionContainer(folderName: String, name: String?, bundleId: String) throws -> String {
        let home = dataDirectory.appendingPathComponent(folderName, isDirectory: true)
        try FileManager.default.createDirectory(at: home, withIntermediateDirectories: true)
        for sub in containerSubdirectories {
            try? FileManager.default.createDirectory(at: home.appendingPathComponent(sub, isDirectory: true),
                                                     withIntermediateDirectories: true)
        }
        let displayName = name?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let resolved = displayName.isEmpty ? String(folderName.prefix(8)) : displayName
        let info: [String: Any] = ["name": resolved, "bundleId": bundleId]
        if let data = try? PropertyListSerialization.data(fromPropertyList: info,
                                                          format: .xml,
                                                          options: 0) {
            try? data.write(to: home.appendingPathComponent(containerInfoFileName), options: .atomic)
        }
        return folderName
    }

    /// 清空元数据家目录（保留目录本身与登记）。清的是**激活**那一份.
    ///
    /// 「重建」的语义是清**访客数据**，不是把容器本身重造一遍：容器名字写在
    /// `SandboxContainerInfo.plist` 里，必须留住 —— 否则用户重命名过的容器会悄悄变回 UUID.
    static func resetDataHome(for app: SandboxApp) throws {
        guard let dataPath = app.dataPath else { return }
        let url = URL(fileURLWithPath: dataPath, isDirectory: true)
        guard FileManager.default.fileExists(atPath: url.path) else { return }
        let fm = FileManager.default
        let children = (try? fm.contentsOfDirectory(at: url, includingPropertiesForKeys: nil)) ?? []
        for child in children where child.lastPathComponent != containerInfoFileName {
            try fm.removeItem(at: child)
        }
        for sub in containerSubdirectories {
            try? fm.createDirectory(at: url.appendingPathComponent(sub, isDirectory: true),
                                    withIntermediateDirectories: true)
        }
    }

    // MARK: 登记与图标

    /// 记下安装时间与显示名（容器由 `makeDataHome` / `createDataContainer` 建）。
    ///
    /// 覆盖安装时**不清**容器列表：那是用户的元数据，重装包体不该带走它
    /// （与旧版「保留元数据目录」的取向一致，只是从一份变成多份）.
    static func registerInstall(bundleId: String, displayName: String, installedAt: Date) {
        var registry = SandboxRegistry.load(from: registryURL)
        var entry = registry.entries[bundleId] ?? SandboxRegistry.Entry()
        entry.displayName = displayName
        entry.installedAt = installedAt
        registry.entries[bundleId] = entry
        registry.save(to: registryURL)
    }

    /// 写入锁定 / 隐藏两个用户开关（只动登记，不碰磁盘）。
    ///
    /// 隐藏是锁定的**子选项**（LCAppSettingsView:220-235）：`hidden == true` 时强制
    /// `locked = true`；解锁则连带清掉隐藏（LC 的 `setLocked(false)` 同口径，解锁前先验身，
    /// 本仓没有生物识别入口，只由界面上的二次确认承担「确实是本人」这一步）。
    static func setAccess(for app: SandboxApp, locked: Bool, hidden: Bool) {
        var registry = SandboxRegistry.load(from: registryURL)
        var entry = registry.entries[app.id] ?? SandboxRegistry.Entry()
        if hidden {
            entry.isHidden = true
            entry.isLocked = true
        } else {
            entry.isHidden = false
            entry.isLocked = locked
        }
        registry.entries[app.id] = entry
        registry.save(to: registryURL)
    }

    /// 图标落盘位置：`Caches/SandboxContainerIcons/<bundleId>.png`。
    ///
    /// 放 Caches 而不是容器目录：图标是可再生资源，丢了下次从 app 包重新取即可；
    /// 放容器里会让「删 App」多一处要清，且用户用 Finder 拷容器时带一堆 png 很脏。
    static func iconFileURL(bundleId: String) -> URL {
        FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("SandboxContainerIcons", isDirectory: true)
            .appendingPathComponent(sanitize(bundleId) + ".png")
    }

    /// 写入图标（覆盖旧图）。
    static func storeIcon(_ data: Data, bundleId: String) {
        let url = iconFileURL(bundleId: bundleId)
        try? FileManager.default.createDirectory(at: url.deletingLastPathComponent(),
                                                 withIntermediateDirectories: true)
        try? data.write(to: url, options: .atomic)
    }

    /// 读回图标（没有就 nil，调用方回落 SF Symbol）。
    static func icon(for bundleId: String) -> Data? {
        try? Data(contentsOf: iconFileURL(bundleId: bundleId))
    }

    /// bundleId 里只有 `.` 与字母数字，但仍然过一遍净化：它是文件名，不是标识符。
    private static func sanitize(_ raw: String) -> String {
        FileNameRules.sanitize(raw) ?? raw
    }

    // MARK: 删除

    enum RemoveResult: Equatable {
        case removed
        case notFound
        case failed(String)
    }

    /// 删除该应用：app 包 + **全部**元数据家目录 + 登记项。
    ///
    /// 返回**真实结果**（同 IPADownloadLibrary.RemoveResult 的取向）：删不掉必须如实上报，
    /// 不许报「已删除」然后列表里还在。
    ///
    /// 容器清单在**删除这一刻**从登记 + 磁盘重新推导，不用调用方传进来的 `app.containers`：
    /// `app` 是页面进入时的快照，用户在详情页新建的容器不在里面，照快照删会留下一个
    /// 登记已清、任何列表都不再显示的孤儿目录。另外补扫一遍 Data/Application 下
    /// info plist 记着本 bundleId 的容器，兜住「目录在但登记已丢」的残留。
    static func remove(_ app: SandboxApp) -> RemoveResult {
        let fm = FileManager.default
        var anyExisted = false
        var failure: String?
        let registry = SandboxRegistry.load(from: registryURL)
        let registered = (registry.entries[app.id]?.dataUUIDs ?? []).map {
            containerPath(folderName: $0)
        }
        let known = Set(registered.map { URL(fileURLWithPath: $0).lastPathComponent })
        let orphans = orphanContainerFolders(bundleId: app.id)
            .filter { !known.contains($0) }
            .map { containerPath(folderName: $0) }
        let targets = ([app.appPath] + registered + orphans).filter { fm.fileExists(atPath: $0) }
        for path in targets {
            anyExisted = true
            do {
                try fm.removeItem(atPath: path)
            } catch {
                failure = error.localizedDescription
            }
        }
        if failure == nil {
            var fresh = registry
            if fresh.entries.removeValue(forKey: app.id) != nil {
                fresh.save(to: registryURL)
            }
        }
        if let failure { return .failed(failure) }
        return anyExisted ? .removed : .notFound
    }

    /// 扫 Data/Application 下 info plist 里 `bundleId` 等于本 App 的容器目录名.
    ///
    /// 用于删除时兜残留：登记是唯一真源，但真源也可能被用户手动改坏，磁盘上多出来的
    /// 那一份同样得清掉，否则它会永远占着空间且不出现在任何界面.
    private static func orphanContainerFolders(bundleId: String) -> [String] {
        let fm = FileManager.default
        guard let names = try? fm.contentsOfDirectory(atPath: dataDirectory.path) else { return [] }
        return names.filter { name in
            let url = dataDirectory.appendingPathComponent(name, isDirectory: true)
                .appendingPathComponent(containerInfoFileName)
            guard let data = try? Data(contentsOf: url),
                  let plist = try? PropertyListSerialization.propertyList(from: data,
                                                                          options: [],
                                                                          format: nil),
                  let dict = plist as? [String: Any] else { return false }
            return (dict["bundleId"] as? String) == bundleId
        }
    }

    // MARK: 磁盘量

    /// 容器包体积（只统计 app 包本身，不含元数据目录 —— 元数据目录在详情页单列）。
    private static func directorySize(_ path: String) -> Int64 {
        (try? FileService().countTree(at: path))?.bytes ?? 0
    }

    private static func directoryDate(_ path: String) -> Date? {
        (try? FileManager.default.attributesOfItem(atPath: path))?[.creationDate] as? Date
    }
}
