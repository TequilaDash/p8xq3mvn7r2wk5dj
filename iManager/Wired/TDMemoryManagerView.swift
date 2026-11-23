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
                .onChange(of: unit) { _ in LCUtils.appGroupUserDefault.synchronize() }
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
        var out = Snapshot()
        // sysctl({CTL_KERN, KERN_PROC, KERN_PROC_ALL, 0}) — same-uid visibility.
        var mib: [Int32] = [CTL_KERN, KERN_PROC, KERN_PROC_ALL, 0]
        var size: UInt = 0
        let rc0 = mib.withUnsafeMutableBufferPointer { p in
            sysctl(p.baseAddress, 4, nil, &size, nil, 0)
        }
        guard rc0 == 0, size > 0 else { return out }
        var procs = [kinfo_proc](repeating: kinfo_proc(), count: Int(size) / MemoryLayout<kinfo_proc>.stride + 8)
        let rc = mib.withUnsafeMutableBufferPointer { p in
            procs.withUnsafeMutableBytes { raw in
                sysctl(p.baseAddress, 4, raw.baseAddress, &size, nil, 0)
            }
        }
        guard rc == 0 else { return out }
        let count = Int(size) / MemoryLayout<kinfo_proc>.stride

        var seen = Set<pid_t>()
        for i in 0..<count {
            let p = procs[i]
            let pid = p.kp_proc.p_pid
            guard pid > 0, seen.insert(pid).inserted else { continue }
            var path = [CChar](repeating: 0, count: Int(MAXPATHLEN))
            let n = proc_pidpath(pid, &path, UInt32(MAXPATHLEN))
            let name: String
            if n > 0 {
                name = String(cString: path).split(separator: "/").last.map(String.init) ?? String(cString: path)
            } else {
                let comm = withUnsafeBytes(of: p.kp_proc.p_comm) { raw -> String in
                    let buf = raw.bindMemory(to: CChar.self)
                    return String(cString: Array(buf.prefix(while: { $0 != 0 })))
                }
                name = comm.isEmpty ? "#\(pid)" : comm
            }
            var rss: UInt64 = 0
            var info = rusage_info_v2()
            if proc_pid_rusage(pid, RUSAGE_INFO_V2, &info) == 0 {
                rss = info.ri_phys_footprint // bytes, same source Xcode reports
            }
            let entry = ProcEntry(pid: pid, name: name, rssBytes: rss)
            let isHost = !isGuestPath(path)
            if isHost && out.host == nil { out.host = entry } else { out.guests.append(entry) }
        }
        out.guests.sort { $0.rssBytes > $1.rssBytes }
        return out
    }

    private static func isGuestPath(_ path: [CChar]) -> Bool {
        let s = String(cString: path)
        // Guests run from the LiveProcess extension or a guest bundle under
        // the container Documents/Applications directory.
        return s.contains("LiveProcess") || s.contains("/Documents/Applications/")
    }
}
