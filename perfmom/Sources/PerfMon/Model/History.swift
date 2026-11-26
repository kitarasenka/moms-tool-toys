import Darwin
import Foundation

// История нагрузки: раз в минуту в ~/Library/Application Support/PerfMon/History/ дописывается строка
// JSON (YYYY-MM-DD.jsonl) со средними/пиковыми значениями и топом процессов, а в YYYY-MM-DD.processes.json
// хранятся суточные итоги по приложениям. Пишется, пока PerfMon запущен (в том числе со скрытым окном).

struct HistoryTop: Codable, Hashable, Sendable {
    let name: String
    let path: String
    let value: Double
}

struct HistoryPoint: Codable, Identifiable, Sendable {
    /// Начало минуты.
    let t: Date
    /// Сколько секунд этой минуты реально покрыто замерами.
    let dur: Double
    let cpu: Double
    let cpuMax: Double
    let cpuUser: Double
    let cpuSystem: Double
    let mem: Double
    let memMax: Double
    let memTotal: Double
    let pressure: Int
    let swap: Double
    let netIn: Double
    let netOut: Double
    let diskRead: Double
    let diskWrite: Double
    let topCPU: [HistoryTop]
    let topMem: [HistoryTop]

    var id: Date { t }
}

/// Суточные итоги по приложению (helper-процессы складываются в своё приложение).
struct ProcessDayStat: Codable, Identifiable, Sendable {
    let key: String
    var name: String
    var path: String
    var cpuSeconds: Double = 0
    var maxMemory: Double = 0
    var netBytes: Double = 0
    var diskBytes: Double = 0
    var activeSeconds: Double = 0

    var id: String { key }
}

enum HistoryFiles {
    static let directory: URL = {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        return base.appendingPathComponent("PerfMon/History", isDirectory: true)
    }()

    static let retentionDays = 30

    private static let dayFormatter: DateFormatter = {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = "yyyy-MM-dd"
        return f
    }()

    static func dayKey(_ date: Date) -> String { dayFormatter.string(from: date) }
    static func date(fromKey key: String) -> Date? { dayFormatter.date(from: key) }
    static func pointsURL(_ day: String) -> URL { directory.appendingPathComponent("\(day).jsonl") }
    static func processesURL(_ day: String) -> URL { directory.appendingPathComponent("\(day).processes.json") }

    /// Дни, за которые есть записи (новые первыми).
    static func availableDays() -> [Date] {
        let files = (try? FileManager.default.contentsOfDirectory(atPath: directory.path)) ?? []
        return files.filter { $0.hasSuffix(".jsonl") }
            .compactMap { date(fromKey: String($0.dropLast(6))) }
            .sorted(by: >)
    }

    static func pruneOld() {
        guard let cutoff = Calendar.current.date(byAdding: .day, value: -retentionDays, to: Date()) else { return }
        let fm = FileManager.default
        for file in (try? fm.contentsOfDirectory(atPath: directory.path)) ?? [] {
            let key = String(file.prefix(10))
            if let d = date(fromKey: key), d < cutoff {
                try? fm.removeItem(at: directory.appendingPathComponent(file))
            }
        }
    }
}

final class HistoryRecorder: @unchecked Sendable {
    static let shared = HistoryRecorder()

    private let queue = DispatchQueue(label: "perfmon.history", qos: .utility)
    private let encoder: JSONEncoder = {
        let e = JSONEncoder()
        e.dateEncodingStrategy = .secondsSince1970
        return e
    }()

    // Накопители текущей минуты.
    private var minuteStart: Date?
    private var samples = 0
    private var covered: Double = 0
    private var sum = (cpu: 0.0, user: 0.0, system: 0.0, mem: 0.0, swap: 0.0, netIn: 0.0, netOut: 0.0, dRead: 0.0, dWrite: 0.0)
    private var peak = (cpu: 0.0, mem: 0.0, pressure: 1)
    private var memTotal: Double = 0
    private var minuteProcs: [String: (name: String, path: String, cpuSum: Double, mem: Double)] = [:]

    // Суточные итоги.
    private var day = ""
    private var dayStats: [String: ProcessDayStat] = [:]
    private var lastIngest: Date?
    private var groupCache: [pid_t: (start: Double, key: String, name: String, path: String)] = [:]

    init() {
        queue.async {
            try? FileManager.default.createDirectory(at: HistoryFiles.directory, withIntermediateDirectories: true)
            HistoryFiles.pruneOld()
        }
    }

    func ingest(system: SystemSnapshot, processes: [ProcessRecord]) {
        let now = Date()
        queue.async { self.accumulate(now: now, s: system, procs: processes) }
    }

    /// Сохранить незавершённую минуту (при выходе из приложения).
    func flushNow() {
        queue.sync {
            if let m = minuteStart { flush(minute: m) }
            minuteStart = nil
        }
    }

    private func accumulate(now: Date, s: SystemSnapshot, procs: [ProcessRecord]) {
        let minute = Date(timeIntervalSince1970: floor(now.timeIntervalSince1970 / 60) * 60)
        if let m = minuteStart, m != minute { flush(minute: m) }
        if minuteStart != minute { resetMinute(minute) }

        // Интервал между замерами; большой разрыв (сон, пауза) не засчитываем как работу.
        let dt = lastIngest.map { now.timeIntervalSince($0) }.flatMap { $0 > 0 && $0 <= 15 ? $0 : nil } ?? 0
        lastIngest = now

        let dayKey = HistoryFiles.dayKey(now)
        if dayKey != day { switchDay(to: dayKey) }

        samples += 1
        covered += dt
        sum.cpu += s.cpuTotal
        sum.user += s.cpuUser
        sum.system += s.cpuSystem
        sum.mem += Double(s.memUsed)
        sum.swap += Double(s.swapUsed)
        sum.netIn += s.netIn
        sum.netOut += s.netOut
        sum.dRead += s.diskRead
        sum.dWrite += s.diskWrite
        peak.cpu = max(peak.cpu, s.cpuTotal)
        peak.mem = max(peak.mem, Double(s.memUsed))
        peak.pressure = max(peak.pressure, s.memPressure)
        memTotal = Double(s.memTotal)

        // Группируем по приложению (суммы внутри тика), затем копим.
        var tick: [String: (name: String, path: String, cpu: Double, mem: Double, net: Double, disk: Double)] = [:]
        var nextCache: [pid_t: (start: Double, key: String, name: String, path: String)] = [:]
        for r in procs where r.pid > 0 {
            let start = r.startTime?.timeIntervalSince1970 ?? 0
            let g: (start: Double, key: String, name: String, path: String)
            if let c = groupCache[r.pid], c.start == start { g = c } else {
                let (key, name, path) = Self.group(r)
                g = (start, key, name, path)
            }
            nextCache[r.pid] = g
            let net = (r.netIn ?? 0) + (r.netOut ?? 0)
            let disk = (r.diskRead ?? 0) + (r.diskWrite ?? 0)
            if r.cpu == 0 && net == 0 && disk == 0 && r.memory < 50_000_000 && tick[g.key] == nil { continue }
            var e = tick[g.key] ?? (g.name, g.path, 0, 0, 0, 0)
            e.cpu += r.cpu
            e.mem += Double(r.memory)
            e.net += net
            e.disk += disk
            tick[g.key] = e
        }
        groupCache = nextCache

        for (key, e) in tick {
            var m = minuteProcs[key] ?? (e.name, e.path, 0, 0)
            m.cpuSum += e.cpu
            m.mem = max(m.mem, e.mem)
            minuteProcs[key] = m

            var d = dayStats[key] ?? ProcessDayStat(key: key, name: e.name, path: e.path)
            d.cpuSeconds += e.cpu / 100 * dt
            d.maxMemory = max(d.maxMemory, e.mem)
            d.netBytes += e.net * dt
            d.diskBytes += e.disk * dt
            if e.cpu > 0.5 { d.activeSeconds += dt }
            dayStats[key] = d
        }
    }

    private func resetMinute(_ minute: Date) {
        minuteStart = minute
        samples = 0
        covered = 0
        sum = (0, 0, 0, 0, 0, 0, 0, 0, 0)
        peak = (0, 0, 1)
        minuteProcs.removeAll(keepingCapacity: true)
    }

    private func flush(minute: Date) {
        guard samples > 0 else { return }
        let n = Double(samples)
        let tops = minuteProcs.map { (key: $0.key, v: $0.value) }
        let topCPU = tops.map { HistoryTop(name: $0.v.name, path: $0.v.path, value: $0.v.cpuSum / n) }
            .filter { $0.value >= 0.5 }.sorted { $0.value > $1.value }.prefix(5)
        let topMem = tops.map { HistoryTop(name: $0.v.name, path: $0.v.path, value: $0.v.mem) }
            .sorted { $0.value > $1.value }.prefix(5)

        let point = HistoryPoint(
            t: minute, dur: max(covered, min(60, n * 2)),
            cpu: sum.cpu / n, cpuMax: peak.cpu, cpuUser: sum.user / n, cpuSystem: sum.system / n,
            mem: sum.mem / n, memMax: peak.mem, memTotal: memTotal, pressure: peak.pressure, swap: sum.swap / n,
            netIn: sum.netIn / n, netOut: sum.netOut / n, diskRead: sum.dRead / n, diskWrite: sum.dWrite / n,
            topCPU: Array(topCPU), topMem: Array(topMem)
        )
        let dayKey = HistoryFiles.dayKey(minute)
        if var line = try? encoder.encode(point) {
            line.append(0x0A)
            append(line, to: HistoryFiles.pointsURL(dayKey))
        }
        saveDayStats()
    }

    private func append(_ data: Data, to url: URL) {
        let fm = FileManager.default
        if !fm.fileExists(atPath: url.path) {
            try? fm.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            fm.createFile(atPath: url.path, contents: data)
            return
        }
        guard let h = try? FileHandle(forWritingTo: url) else { return }
        defer { try? h.close() }
        _ = try? h.seekToEnd()
        try? h.write(contentsOf: data)
    }

    private func switchDay(to key: String) {
        if !day.isEmpty { saveDayStats() }
        day = key
        dayStats = [:]
        // Продолжаем итоги, если приложение перезапускали в течение дня.
        if let data = try? Data(contentsOf: HistoryFiles.processesURL(key)),
           let list = try? JSONDecoder().decode([ProcessDayStat].self, from: data) {
            dayStats = Dictionary(list.map { ($0.key, $0) }, uniquingKeysWith: { a, _ in a })
        }
    }

    private func saveDayStats() {
        guard !day.isEmpty else { return }
        // Мелочь не храним: только то, что заметно нагружало систему.
        let list = dayStats.values.filter { $0.cpuSeconds >= 1 || $0.netBytes >= 1_000_000 || $0.maxMemory >= 100_000_000 }
        if let data = try? encoder.encode(Array(list)) {
            try? data.write(to: HistoryFiles.processesURL(day), options: .atomic)
        }
    }

    static func group(_ r: ProcessRecord) -> (key: String, name: String, path: String) {
        if let app = PathTools.outermostApp(r.path) {
            return (app, ((app as NSString).lastPathComponent as NSString).deletingPathExtension, app)
        }
        if !r.path.isEmpty { return (r.path, r.name, r.path) }
        return (r.name, r.name, "")
    }
}

// MARK: - Чтение

struct HistoryDay: Sendable {
    let date: Date
    let points: [HistoryPoint]
    let processes: [ProcessDayStat]

    var recordedSeconds: Double { points.reduce(0) { $0 + $1.dur } }
}

enum HistoryLoader {
    static func load(_ date: Date) -> HistoryDay {
        let key = HistoryFiles.dayKey(date)
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .secondsSince1970
        var points: [HistoryPoint] = []
        if let data = try? Data(contentsOf: HistoryFiles.pointsURL(key)) {
            for line in data.split(separator: 0x0A) where !line.isEmpty {
                if let p = try? decoder.decode(HistoryPoint.self, from: Data(line)) { points.append(p) }
            }
        }
        var processes: [ProcessDayStat] = []
        if let data = try? Data(contentsOf: HistoryFiles.processesURL(key)),
           let list = try? decoder.decode([ProcessDayStat].self, from: data) {
            processes = list.sorted { $0.cpuSeconds > $1.cpuSeconds }
        }
        return HistoryDay(date: date, points: points.sorted { $0.t < $1.t }, processes: processes)
    }
}

/// Агрегат для графиков: интервал в несколько минут (весь день — 288 точек по 5 минут).
struct HistoryBucket: Identifiable, Sendable {
    let t: Date
    let segment: Int
    let cpu: Double
    let cpuMax: Double
    let cpuUser: Double
    let cpuSystem: Double
    let mem: Double
    let memMax: Double
    let memTotal: Double
    let netIn: Double
    let netOut: Double
    let diskRead: Double
    let diskWrite: Double
    let topCPU: [HistoryTop]
    let topMem: [HistoryTop]
    let minutes: Int

    var id: Date { t }

    static func make(from points: [HistoryPoint], minutes: Int) -> [HistoryBucket] {
        let size = Double(minutes * 60)
        let groups = Dictionary(grouping: points) { floor($0.t.timeIntervalSince1970 / size) * size }
        var result: [HistoryBucket] = []
        var segment = 0
        var prev: Double?
        for start in groups.keys.sorted() {
            // Разрыв больше двух интервалов — PerfMon не работал; начинаем новый отрезок линии.
            if let prev, start - prev > size * 2 { segment += 1 }
            prev = start
            let ps = groups[start] ?? []
            let w = ps.reduce(0) { $0 + max($1.dur, 1) }
            func avg(_ f: (HistoryPoint) -> Double) -> Double { ps.reduce(0) { $0 + f($1) * max($1.dur, 1) } / max(w, 1) }
            func mergeTops(_ f: (HistoryPoint) -> [HistoryTop], average: Bool) -> [HistoryTop] {
                var acc: [String: (String, String, Double)] = [:]
                for p in ps {
                    for t in f(p) {
                        let e = acc[t.path + t.name] ?? (t.name, t.path, 0)
                        acc[t.path + t.name] = (e.0, e.1, average ? e.2 + t.value / Double(ps.count) : max(e.2, t.value))
                    }
                }
                return acc.values.map { HistoryTop(name: $0.0, path: $0.1, value: $0.2) }
                    .sorted { $0.value > $1.value }.prefix(5).map { $0 }
            }
            result.append(HistoryBucket(
                t: Date(timeIntervalSince1970: start), segment: segment,
                cpu: avg(\.cpu), cpuMax: ps.map(\.cpuMax).max() ?? 0,
                cpuUser: avg(\.cpuUser), cpuSystem: avg(\.cpuSystem),
                mem: avg(\.mem), memMax: ps.map(\.memMax).max() ?? 0, memTotal: ps.last?.memTotal ?? 0,
                netIn: avg(\.netIn), netOut: avg(\.netOut), diskRead: avg(\.diskRead), diskWrite: avg(\.diskWrite),
                topCPU: mergeTops(\.topCPU, average: true), topMem: mergeTops(\.topMem, average: false),
                minutes: ps.count
            ))
        }
        return result
    }
}
