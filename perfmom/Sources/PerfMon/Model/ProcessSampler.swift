import Darwin
import Foundation

/// Снимает список процессов и их потребление. Не потокобезопасен — вызывается с одной serial-очереди.
final class ProcessSampler: @unchecked Sendable {
    private struct Previous {
        var start: UInt64
        var cpu: Double
        var read: UInt64?
        var write: UInt64?
    }

    private var previous: [pid_t: Previous] = [:]
    private var pathCache: [pid_t: (start: UInt64, path: String)] = [:]
    private var userCache: [uid_t: String] = [:]
    private var lastTime: Double = 0
    private let myUID = getuid()

    func sample() -> [ProcessRecord] {
        let now = MachTime.now()
        let dt = lastTime > 0 ? now - lastTime : 0
        lastTime = now

        let kinfos = Self.allProcesses()
        let network = NetworkMonitor.shared.snapshot()
        var psStats: [pid_t: PSReader.Stat]?
        var nextPrevious: [pid_t: Previous] = [:]
        var nextPaths: [pid_t: (start: UInt64, path: String)] = [:]
        nextPrevious.reserveCapacity(kinfos.count)
        nextPaths.reserveCapacity(kinfos.count)

        var result: [ProcessRecord] = []
        result.reserveCapacity(kinfos.count)

        for kp in kinfos {
            let pid = kp.kp_proc.p_pid
            let tv = kp.kp_proc.p_un.__p_starttime
            let startKey = UInt64(max(0, tv.tv_sec)) &* 1_000_000 &+ UInt64(max(0, tv.tv_usec))
            let uid = kp.kp_eproc.e_ucred.cr_uid

            let path: String
            if let cached = pathCache[pid], cached.start == startKey {
                path = cached.path
            } else {
                path = Self.executablePath(pid)
            }
            nextPaths[pid] = (startKey, path)

            let comm = cString(tuple: kp.kp_proc.p_comm)
            let name = path.isEmpty ? comm : (path as NSString).lastPathComponent
            let start = tv.tv_sec > 0 ? Date(timeIntervalSince1970: Double(tv.tv_sec) + Double(tv.tv_usec) / 1e6) : nil

            var rec = ProcessRecord(
                pid: pid,
                ppid: kp.kp_eproc.e_ppid,
                uid: uid,
                user: userName(uid),
                name: name.isEmpty ? "(pid \(pid))" : name,
                path: path,
                startTime: start,
                state: ProcState(pStat: kp.kp_proc.p_stat)
            )

            var cpuSeconds: Double?
            var readTotal: UInt64?
            var writeTotal: UInt64?

            var ru = rusage_info_v4()
            let ok = withUnsafeMutablePointer(to: &ru) { ptr in
                ptr.withMemoryRebound(to: rusage_info_t?.self, capacity: 1) {
                    proc_pid_rusage(pid, RUSAGE_INFO_V4, $0)
                }
            } == 0

            if ok {
                cpuSeconds = Double(ru.ri_user_time &+ ru.ri_system_time) * MachTime.secondsPerTick
                rec.memory = ru.ri_phys_footprint
                readTotal = ru.ri_diskio_bytesread
                writeTotal = ru.ri_diskio_byteswritten
                rec.diskReadTotal = readTotal
                rec.diskWriteTotal = writeTotal
                rec.diskRead = 0
                rec.diskWrite = 0

                var ti = proc_taskinfo()
                let size = Int32(MemoryLayout<proc_taskinfo>.size)
                if proc_pidinfo(pid, PROC_PIDTASKINFO, 0, &ti, size) == size {
                    rec.threads = Int(ti.pti_threadnum)
                }
            } else {
                // Чужой процесс: libproc закрыт, но setuid-утилита ps отдаёт CPU-время и RSS.
                if psStats == nil { psStats = PSReader.stats() }
                if let st = psStats?[pid] {
                    cpuSeconds = st.cpuSeconds
                    rec.memory = st.rss
                }
                rec.restricted = uid != myUID
            }

            if let cpuSeconds {
                rec.cpuTime = cpuSeconds
                if let p = previous[pid], p.start == startKey, dt > 0 {
                    rec.cpu = max(0, (cpuSeconds - p.cpu) / dt * 100)
                    if let r = readTotal, let pr = p.read, r >= pr { rec.diskRead = Double(r - pr) / dt }
                    if let w = writeTotal, let pw = p.write, w >= pw { rec.diskWrite = Double(w - pw) / dt }
                }
                nextPrevious[pid] = Previous(start: startKey, cpu: cpuSeconds, read: readTotal, write: writeTotal)
            }

            if let network {
                let n = network[pid]
                rec.netIn = n?.rateIn ?? 0
                rec.netOut = n?.rateOut ?? 0
                rec.netInTotal = n?.bytesIn ?? 0
                rec.netOutTotal = n?.bytesOut ?? 0
            }

            result.append(rec)
        }

        previous = nextPrevious
        pathCache = nextPaths
        return result
    }

    private func userName(_ uid: uid_t) -> String {
        if let n = userCache[uid] { return n }
        var name = String(uid)
        if let pw = getpwuid(uid), let cName = pw.pointee.pw_name {
            name = String(cString: cName)
        }
        userCache[uid] = name
        return name
    }

    static func executablePath(_ pid: pid_t) -> String {
        // PROC_PIDPATHINFO_MAXSIZE = 4 * MAXPATHLEN; больший буфер ядро отвергает.
        var buf = [CChar](repeating: 0, count: 4 * Int(MAXPATHLEN))
        guard proc_pidpath(pid, &buf, UInt32(buf.count)) > 0 else { return "" }
        return cString(buf)
    }

    static func allProcesses() -> [kinfo_proc] {
        var mib: [Int32] = [CTL_KERN, KERN_PROC, KERN_PROC_ALL]
        let stride = MemoryLayout<kinfo_proc>.stride
        for _ in 0..<4 {
            var size = 0
            guard sysctl(&mib, 3, nil, &size, nil, 0) == 0 else { return [] }
            size += size / 8 + stride * 16
            var buf = [kinfo_proc](repeating: kinfo_proc(), count: size / stride)
            var bytes = buf.count * stride
            if sysctl(&mib, 3, &buf, &bytes, nil, 0) == 0 {
                return Array(buf.prefix(bytes / stride))
            }
            if errno != ENOMEM { return [] }
        }
        return []
    }
}

/// /bin/ps — setuid root, поэтому видит CPU и память всех процессов.
enum PSReader {
    struct Stat {
        var rss: UInt64
        var cpuSeconds: Double
    }

    static func stats() -> [pid_t: Stat] {
        guard let text = run(["-axo", "pid=,rss=,time="]) else { return [:] }
        var out: [pid_t: Stat] = [:]
        for line in text.split(separator: "\n") {
            let f = line.split(separator: " ", omittingEmptySubsequences: true)
            guard f.count >= 3, let pid = pid_t(f[0]), let rss = UInt64(f[1]) else { continue }
            out[pid] = Stat(rss: rss * 1024, cpuSeconds: parseTime(f[2]))
        }
        return out
    }

    /// Командная строка процесса (для чужих процессов, где KERN_PROCARGS2 недоступен).
    static func commandLine(_ pid: pid_t) -> String? {
        guard let text = run(["-o", "args=", "-p", String(pid)]) else { return nil }
        let s = text.trimmingCharacters(in: .whitespacesAndNewlines)
        return s.isEmpty ? nil : s
    }

    /// Формат ps: [дд-][чч:]мм:сс.сс
    static func parseTime(_ s: Substring) -> Double {
        var days = 0.0
        var rest = s
        if let dash = s.firstIndex(of: "-") {
            days = Double(s[..<dash]) ?? 0
            rest = s[s.index(after: dash)...]
        }
        var total = 0.0
        for part in rest.split(separator: ":") { total = total * 60 + (Double(part) ?? 0) }
        return days * 86_400 + total
    }

    private static func run(_ args: [String]) -> String? {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/bin/ps")
        p.arguments = args
        let pipe = Pipe()
        p.standardOutput = pipe
        p.standardError = FileHandle.nullDevice
        do { try p.run() } catch { return nil }
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        p.waitUntilExit()
        return String(decoding: data, as: UTF8.self)
    }
}
