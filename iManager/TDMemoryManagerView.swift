import Darwin
import SwiftUI

// libproc bindings not exposed to Swift on iOS SDK; declare locally.
@_silgen_name("proc_pidpath")
func proc_pidpath(_ pid: Int32, _ buffer: UnsafeMutablePointer<CChar>?, _ buffersize: UInt32) -> Int32

struct rusage_info_v2 {
    var ri_uuid: (UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8)
    var ri_user_time: UInt64
    var ri_system_time: UInt64
    var ri_pkg_idle_wkups: UInt64
    var ri_interrupt_wkups: UInt64
    var ri_pageins: UInt64
    var ri_wired_size: UInt64
    var ri_resident_size: UInt64
    var ri_phys_footprint: UInt64
    var ri_user_time64: UInt64
    var ri_system_time64: UInt64
    var ri_pkg_idle_wkups64: UInt64
    var ri_interrupt_wkups64: UInt64
    var ri_pagesize: Int32
    var ri_reserved: (UInt32, UInt32)
    init() {
        ri_uuid = (0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0)
        ri_user_time = 0; ri_system_time = 0; ri_pkg_idle_wkups = 0
        ri_interrupt_wkups = 0; ri_pageins = 0; ri_wired_size = 0
        ri_resident_size = 0; ri_phys_footprint = 0
        ri_user_time64 = 0; ri_system_time64 = 0
        ri_pkg_idle_wkups64 = 0; ri_interrupt_wkups64 = 0
        ri_pagesize = 0; ri_reserved = (0, 0)
    }
}
@_silgen_name("proc_pid_rusage")
func proc_pid_rusage(_ pid: Int32, _ flavor: Int32, _ buffer: UnsafeMutablePointer<rusage_info_v2>?) -> Int32

private let RUSAGE_INFO_V2: Int32 = 2

/// iManager > 实验性 > 内存管理.
/// Lists guest (and host) processes with their resident memory usage, using
/// sysctl KERN_PROC + proc_pid_rusage. Jailed processes of the same uid are
/// visible to proc_listallpids on iOS for same-team processes; anything the
/// kernel hides simply does not appear. Unit display (MB/GB) is user-settable
/// and shared with the deck memory capsule via app-group defaults.
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
                        Text(Self.fmt(host.rssBytes, unit: unit))
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
                        Text(Self.fmt(e.rssBytes, unit: unit))
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
                Text("内存为物理内存占用（resident）。同 uid 之外的进程内核不暴露，这里只列容器可见进程。")
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

    private func refresh() {
        let snapshot = Self.snapshot()
        hostEntry = snapshot.host
        entries = snapshot.guests
        if refreshTimer == nil {
            refreshTimer = Timer.scheduledTimer(withTimeInterval: 3.0, repeats: true) { _ in
                let next = Self.snapshot()
                DispatchQueue.main.async {
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

    static func snapshot() -> Snapshot {
        // jailed 下列不出全系统进程表（sysctl KERN_PROC_ALL 无权限，实测为空）。
        // 进程来源 = 宿主自身 + 访客会话登记表：TweakLoader constructor 启动时把
        // pid/bundleId 写进 app group "TDLiveGuestPids"；这里 kill(pid,0) 探活过滤死项，
        // 再逐个 proc_pid_rusage 取 physical footprint（同 uid 进程内核允许）。
        var out = Snapshot()
        let defaults = LCUtils.appGroupUserDefault
        let registry = (defaults.dictionary(forKey: "TDLiveGuestPids") as? [String: [String: Any]]) ?? [:]
        var host = ProcEntry(pid: Int32(getpid()), name: "zContainer（宿主）", rssBytes: 0)
        var info = rusage_info_v2()
        if proc_pid_rusage(host.pid, RUSAGE_INFO_V2, &info) == 0 {
            host = ProcEntry(pid: host.pid, name: host.name, rssBytes: info.ri_phys_footprint)
        }
        var guests: [ProcEntry] = []
        var seen = Set<Int32>()
        for (key, meta) in registry {
            guard let pid = Int32(key), pid > 0, pid != host.pid, seen.insert(pid).inserted else { continue }
            if kill(pid, 0) != 0 && errno == ESRCH { continue }
            var rss: UInt64 = 0
            var rinfo = rusage_info_v2()
            if proc_pid_rusage(pid, RUSAGE_INFO_V2, &rinfo) == 0 {
                rss = rinfo.ri_phys_footprint
            }
            var name = (meta["bundleId"] as? String).flatMap { $0.isEmpty ? nil : $0 } ?? "#\(pid)"
            var path = [CChar](repeating: 0, count: Int(MAXPATHLEN))
            if proc_pidpath(pid, &path, UInt32(MAXPATHLEN)) > 0 {
                name = String(cString: path).split(separator: "/").last.map(String.init) ?? name
            }
            guests.append(ProcEntry(pid: pid, name: name, rssBytes: rss))
        }
        guests.sort { $0.rssBytes > $1.rssBytes }
        out.host = host
        out.guests = guests
        return out
    }

}
