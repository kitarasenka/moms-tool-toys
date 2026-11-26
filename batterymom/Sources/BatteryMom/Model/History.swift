import Foundation

// История батареи: раз в минуту, пока BatteryMom запущен (в том числе с закрытым окном), в
// ~/Library/Application Support/BatteryMom/history.jsonl дописывается строка JSON. Хранится 30 дней.

struct HistoryRecord: Codable, Sendable, Identifiable, Equatable {
    /// Время замера.
    var t: Date
    /// Заряд, %.
    var p: Int
    /// Заряжается.
    var c: Bool
    /// Подключён адаптер.
    var a: Bool
    /// Потребление Mac, Вт.
    var w: Double?
    /// Мощность через батарею, Вт (плюс — заряд, минус — разряд).
    var bw: Double?
    /// Температура батареи, °C.
    var tc: Double?
    /// Циклы перезарядки.
    var cyc: Int?

    var id: Date { t }

    init(t: Date, p: Int, c: Bool, a: Bool, w: Double? = nil, bw: Double? = nil, tc: Double? = nil, cyc: Int? = nil) {
        self.t = t; self.p = p; self.c = c; self.a = a
        self.w = w.map(Self.round1); self.bw = bw.map(Self.round1); self.tc = tc.map(Self.round1); self.cyc = cyc
    }

    init(_ b: BatteryInfo, at t: Date = Date()) {
        self.init(t: t, p: b.percent, c: b.isCharging, a: b.externalConnected,
                  w: b.consumption, bw: b.batteryPower, tc: b.temperature, cyc: b.cycleCount)
    }

    private static func round1(_ v: Double) -> Double { (v * 10).rounded() / 10 }
}

final class HistoryStore: @unchecked Sendable {
    static let shared = HistoryStore(directory: FileManager.default
        .urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        .appendingPathComponent("BatteryMom", isDirectory: true))

    static let retentionDays = 30
    /// Перерыв дольше этого — «дыра» в графике (BatteryMom не был запущен или Mac спал).
    static let gap: TimeInterval = 3 * 60

    let fileURL: URL
    private let queue = DispatchQueue(label: "batterymom.history", qos: .utility)
    private var lastTrim: Date?

    private static let encoder: JSONEncoder = {
        let e = JSONEncoder()
        e.dateEncodingStrategy = .secondsSince1970
        e.outputFormatting = [.sortedKeys]
        return e
    }()

    private static let decoder: JSONDecoder = {
        let d = JSONDecoder()
        d.dateDecodingStrategy = .secondsSince1970
        return d
    }()

    init(directory: URL) {
        fileURL = directory.appendingPathComponent("history.jsonl")
    }

    /// Дописать строку (синхронно на своей очереди). Раз в 6 часов заодно чистит старое.
    func append(_ r: HistoryRecord) {
        queue.sync {
            let fm = FileManager.default
            try? fm.createDirectory(at: fileURL.deletingLastPathComponent(), withIntermediateDirectories: true)
            guard var line = try? Self.encoder.encode(r) else { return }
            line.append(0x0A)
            if let h = try? FileHandle(forWritingTo: fileURL) {
                defer { try? h.close() }
                _ = try? h.seekToEnd()
                try? h.write(contentsOf: line)
            } else {
                try? line.write(to: fileURL, options: .atomic)
            }
            if lastTrim.map({ r.t.timeIntervalSince($0) > 6 * 3600 }) ?? true {
                lastTrim = r.t
                trimLocked(now: r.t)
            }
        }
    }

    func load(since: Date? = nil) -> [HistoryRecord] {
        queue.sync { readLocked().filter { since == nil || $0.t >= since! } }
    }

    /// Оставить только последние `retentionDays` дней.
    func trim(now: Date = Date()) { queue.sync { trimLocked(now: now) } }

    private func readLocked() -> [HistoryRecord] {
        guard let data = try? Data(contentsOf: fileURL) else { return [] }
        var out: [HistoryRecord] = []
        for line in data.split(separator: 0x0A, omittingEmptySubsequences: true) {
            if let r = try? Self.decoder.decode(HistoryRecord.self, from: Data(line)) { out.append(r) }
        }
        return out.sorted { $0.t < $1.t }
    }

    private func trimLocked(now: Date) {
        let cutoff = now.addingTimeInterval(-Double(Self.retentionDays) * 86400)
        let all = readLocked()
        let keep = all.filter { $0.t >= cutoff }
        guard keep.count != all.count else { return }
        var data = Data()
        for r in keep {
            if let line = try? Self.encoder.encode(r) { data.append(line); data.append(0x0A) }
        }
        try? data.write(to: fileURL, options: .atomic)
    }
}

// MARK: - Анализ

/// Точка графика: среднее за интервал; `segment` меняется после «дыры» — линии не соединяются через неё.
struct ChartPoint: Identifiable, Sendable {
    var t: Date
    var percent: Double
    var power: Double?
    var batteryPower: Double?
    var charging: Bool
    var segment: Int
    var id: Date { t }
}

struct DaySummary: Identifiable, Sendable, Equatable {
    var day: Date
    var recorded: TimeInterval
    var onBattery: TimeInterval
    /// Сколько процентов израсходовано от батареи (сумма падений).
    var drained: Int
    var cyclesDelta: Int?
    var minPercent: Int
    var maxPercent: Int
    var id: Date { day }
}

enum HistoryAnalysis {
    /// Усреднение по корзинам `bucket` секунд.
    static func points(_ records: [HistoryRecord], bucket: TimeInterval) -> [ChartPoint] {
        guard !records.isEmpty else { return [] }
        let groups = Dictionary(grouping: records) { floor($0.t.timeIntervalSince1970 / bucket) }
        var out: [ChartPoint] = []
        for key in groups.keys.sorted() {
            let g = groups[key]!
            let ws = g.compactMap(\.w), bws = g.compactMap(\.bw)
            out.append(ChartPoint(t: Date(timeIntervalSince1970: key * bucket + bucket / 2),
                                  percent: Double(g.map(\.p).reduce(0, +)) / Double(g.count),
                                  power: ws.isEmpty ? nil : ws.reduce(0, +) / Double(ws.count),
                                  batteryPower: bws.isEmpty ? nil : bws.reduce(0, +) / Double(bws.count),
                                  charging: g.contains(where: \.c), segment: 0))
        }
        var seg = 0
        let maxGap = max(HistoryStore.gap, bucket * 2.5)
        for i in out.indices {
            if i > 0, out[i].t.timeIntervalSince(out[i - 1].t) > maxGap { seg += 1 }
            out[i].segment = seg
        }
        return out
    }

    /// Итоги по дням (последние `days`, новые первыми).
    static func days(_ records: [HistoryRecord], days: Int = 7, now: Date = Date(), calendar: Calendar = .current) -> [DaySummary] {
        let today = calendar.startOfDay(for: now)
        let byDay = Dictionary(grouping: records) { calendar.startOfDay(for: $0.t) }
        var out: [DaySummary] = []
        for offset in 0..<days {
            guard let day = calendar.date(byAdding: .day, value: -offset, to: today),
                  let recs = byDay[day]?.sorted(by: { $0.t < $1.t }), !recs.isEmpty else { continue }
            var recorded: TimeInterval = 0, onBattery: TimeInterval = 0, drained = 0
            for (prev, cur) in zip(recs, recs.dropFirst()) {
                let dt = cur.t.timeIntervalSince(prev.t)
                guard dt > 0, dt <= HistoryStore.gap else { continue }
                recorded += dt
                if !prev.a { onBattery += dt }
                if !cur.a, cur.p < prev.p { drained += prev.p - cur.p }
            }
            let cycles = recs.compactMap(\.cyc)
            out.append(DaySummary(day: day, recorded: recorded, onBattery: onBattery, drained: drained,
                                  cyclesDelta: cycles.isEmpty ? nil : (cycles.max()! - cycles.min()!),
                                  minPercent: recs.map(\.p).min()!, maxPercent: recs.map(\.p).max()!))
        }
        return out
    }
}
