import Darwin
import SwiftUI

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
            Section("当前运行的程序") {
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
        var size: UInt32 = 0
        // sysctl({CTL_KERN, KERN_PROC, KERN_PROC_ALL, 0}) — same-uid visibility.
        var mib: [Int32] = [CTL_KERN, KERN_PROC, KERN_PROC_ALL, 0]
        guard sysctl(&mib, 4, nil, &size, nil, 0) == 0, size > 0 else { return out }
        var count = Int(size) / MemoryLayout<kinfo_proc>.stride
        var procs = [kinfo_proc](repeating: kinfo_proc(), count: count + 8)
        size &= ~UInt32(MemoryLayout<kinfo_proc>.size - 1)
        guard sysctl(&mib, 4, &procs, &size, nil, 0) == 0 else { return out }
        count = Int(size) / MemoryLayout<kinfo_proc>.stride

        var seen = Set<pid_t>()
        for i in 0..<count {
            let p = procs[i]
            let pid = p.kp_proc.p_pid
            guard pid > 0, seen.insert(pid).inserted else { continue }
            // Only processes in our own session (same uid) are measurable.
            if p.kp_eproc.e_pcred.p_ruid != getuid() { continue }
            var path = [CChar](repeating: 0, count: Int(MAXPATHLEN))
            let n = proc_pidpath(pid, &path, UInt32(MAXPATHLEN))
            let name: String
            if n > 0 {
                name = String(cString: path).split(separator: "/").last.map(String.init) ?? String(cString: path)
            } else {
                name = String(cString: p.kp_proc.p_comm)
            }
            var rss: UInt64 = 0
            var info = rusage_info_t()
            if proc_pid_rusage(pid, RUSAGE_INFO_V2, &info) == 0 {
                rss = UInt64(info.ri_phys_footprint) // bytes, exactly what Xcode reports
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
