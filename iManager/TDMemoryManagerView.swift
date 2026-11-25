import Darwin
import SwiftUI
import UIKit

// libproc bindings not exposed to Swift on iOS SDK; declare locally.
@_silgen_name("proc_pidpath")
func proc_pidpath(_ pid: Int32, _ buffer: UnsafeMutablePointer<CChar>?, _ buffersize: UInt32) -> Int32

// Use Darwin's C layout, not a hand-written Swift struct with missing fields.
// The libproc entry point writes the SDK-defined RUSAGE_INFO_V2 bytes.
@_silgen_name("proc_pid_rusage")
private func tdProcPIDRusage(_ pid: Int32, _ flavor: Int32, _ buffer: UnsafeMutableRawPointer) -> Int32

/// iManager > 实验性 > 内存管理.
/// Uses live host controllers plus compatible guest registrations, never
/// pretends that sysctl can enumerate every jailed process. Memory is physical
/// footprint; unreadable measurements are not reported as a measured zero.
@available(iOS 15.0, *)
struct TDMemoryManagerView: View {
    private static let unitKey = "TDMemoryUnit" // "MB" | "GB"

    @AppStorage("TDMemoryUnit", store: LCUtils.appGroupUserDefault)
    private var unit: String = "MB"

    @State private var entries: [ProcEntry] = []
    @State private var hostEntry: ProcEntry?
    @State private var refreshTimer: Timer?

    struct ProcEntry: Identifiable {
        let pid: Int32
        let name: String
        let rssBytes: UInt64
        var readable: Bool = true
        var id: Int32 { pid }
    }

    var body: some View {
        List {
            Section {
                Picker("单位", selection: $unit) {
                    Text("MB").tag("MB")
                    Text("GB").tag("GB")
                }
                .pickerStyle(.segmented)
                .onChange(of: unit) { _, _ in LCUtils.appGroupUserDefault.synchronize() }
            } footer: {
                Text("单位同时用于堆叠后台右上角的内存胶囊。")
            }
            Section {

                if let host = hostEntry {
                    HStack {
                        Image(systemName: "app.fill")
                        Text(host.name)
                        Spacer()
                        Text(host.readable ? Self.fmt(host.rssBytes, unit: unit) : "不可读取")
                            .monospacedDigit()
                            .foregroundStyle(.secondary)
                    }
                }
                ForEach(entries) { e in
                    HStack {
                        Text("#\(e.pid)")
                            .font(.footnote.monospacedDigit())
                            .foregroundStyle(.secondary)
                            .frame(width: 64, alignment: .leading)
                        Text(e.name)
                        Spacer()
                        Text(e.readable ? Self.fmt(e.rssBytes, unit: unit) : "不可读取")
                            .monospacedDigit()
                            .foregroundStyle(.secondary)
                    }
                }
                if entries.isEmpty && hostEntry == nil {
                    Text("未发现可读的运行进程。")
                        .foregroundStyle(.secondary)
                }
            } header: {
                Text("当前运行的程序")
            } footer: {
                Text("内存为物理内存占用（physical footprint）。列表来自容器中的运行访客；权限不足时显示不可读取。")
            }
        }
        .navigationTitle("内存管理")
        .navigationBarTitleDisplayMode(.inline)
        .onAppear(perform: refresh)
        .onDisappear {
            refreshTimer?.invalidate()
            refreshTimer = nil
        }
        .refreshable { refresh() }
    }

    @MainActor
    private func refresh() {
        let snapshot = Self.snapshot(knownGuests: Self.liveGuestProcesses())
        hostEntry = snapshot.host
        entries = snapshot.guests
        if refreshTimer == nil {
            refreshTimer = Timer.scheduledTimer(withTimeInterval: 3.0, repeats: true) { _ in
                MainActor.assumeIsolated {
                    let next = Self.snapshot(knownGuests: Self.liveGuestProcesses())
                    hostEntry = next.host
                    entries = next.guests
                }
            }
        }
    }

    static func fmt(_ bytes: UInt64, unit: String) -> String {
        if unit == "GB" {
            let gb = Double(bytes) / (1024 * 1024 * 1024)
            return String(format: "%.2f GB", gb)
        }
        let mb = Double(bytes) / (1024 * 1024)
        return String(format: "%.1f MB", mb)
    }

    // MARK: - process enumeration

    struct Snapshot {
        var host: ProcEntry?
        var guests: [ProcEntry] = []
    }

    @MainActor
    private static func liveGuestProcesses() -> [Int32: String] {
        guard #available(iOS 16.0, *) else { return [:] }
        var result: [Int32: String] = [:]
        var visited = Set<ObjectIdentifier>()
        @MainActor func visit(_ controller: UIViewController) {
            guard visited.insert(ObjectIdentifier(controller)).inserted else { return }
            if let app = controller as? AppSceneViewController, app.pid > 0,
               !app.isTerminated, !app.isUserTerminating {
                result[app.pid] = app.bundleId ?? "#\(app.pid)"
            }
            for child in controller.children { visit(child) }
            if let presented = controller.presentedViewController { visit(presented) }
        }
        for scene in UIApplication.shared.connectedScenes.compactMap({ $0 as? UIWindowScene }) {
            for window in scene.windows {
                if let root = window.rootViewController { visit(root) }
            }
        }
        for app in MultitaskDockManager.shared.apps {
            if let decorated = app.view?._viewDelegate() as? DecoratedAppSceneViewController { visit(decorated) }
        }
        return result
    }

    /// 访客自己上报的 footprint（宿主读别的进程会被内核拒绝）。
    nonisolated static func reportedFootprint(pid: Int32) -> UInt64? {
        guard pid > 0 else { return nil }
        let defaults = LCUtils.appGroupUserDefault
        guard let value = defaults.object(forKey: "TDLiveGuestMem.\(pid)") as? NSNumber else { return nil }
        let bytes = value.uint64Value
        return bytes > 0 ? bytes : nil
    }

    nonisolated static func footprint(pid: Int32) -> UInt64? {
        if let reported = reportedFootprint(pid: pid) { return reported }
        guard pid > 0 else { return nil }
        var info = Darwin.rusage_info_v2()
        let result = withUnsafeMutablePointer(to: &info) {
            tdProcPIDRusage(pid, 2, UnsafeMutableRawPointer($0))
        }
        guard result == 0 else { return nil }
        return info.ri_phys_footprint
    }

    static func snapshot(knownGuests: [Int32: String] = [:]) -> Snapshot {
        // Host-owned controller metadata wins over stale/failed guest defaults.
        var out = Snapshot()
        let defaults = LCUtils.appGroupUserDefault
        // 访客是另一个进程写这张表，先同步一次再读，否则拿到的是旧缓存。
        defaults.synchronize()
        var registry = (defaults.dictionary(forKey: "TDLiveGuestPids") as? [String: [String: Any]]) ?? [:]
        let prefix = "TDLiveGuestPid."
        for (key, value) in defaults.dictionaryRepresentation() where key.hasPrefix(prefix) {
            if let meta = value as? [String: Any] {
                registry[String(key.dropFirst(prefix.count))] = meta
            }
        }
        for (pid, name) in knownGuests { registry[String(pid)] = ["bundleId": name] }
        let hostPID = Int32(getpid())
        let hostBytes = footprint(pid: hostPID)
        let host = ProcEntry(pid: hostPID, name: "zContainer（宿主）", rssBytes: hostBytes ?? 0, readable: hostBytes != nil)
        var guests: [ProcEntry] = []
        var seen = Set<Int32>()
        for (key, meta) in registry {
            guard let pid = Int32(key), pid > 0, pid != host.pid, seen.insert(pid).inserted else { continue }
            if kill(pid, 0) != 0 && errno == ESRCH { continue }
            let rss = footprint(pid: pid)
            var name = (meta["bundleId"] as? String).flatMap { $0.isEmpty ? nil : $0 } ?? "#\(pid)"
            var path = [CChar](repeating: 0, count: Int(MAXPATHLEN))
            if proc_pidpath(pid, &path, UInt32(MAXPATHLEN)) > 0 {
                name = String(cString: path).split(separator: "/").last.map(String.init) ?? name
            }
            guests.append(ProcEntry(pid: pid, name: name, rssBytes: rss ?? 0, readable: rss != nil))
        }
        guests.sort { $0.rssBytes > $1.rssBytes }
        out.host = host
        out.guests = guests
        return out
    }

}
