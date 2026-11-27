import Foundation

// Отчёт «что у меня за Mac и что с ним». Сбор — в Collector.swift, здесь только данные, выводы и текст,
// чтобы их можно было проверить в `--selftest` на выдуманных значениях.

enum Level: Int, Comparable, Sendable {
    case ok, warn, bad

    static func < (a: Level, b: Level) -> Bool { a.rawValue < b.rawValue }

    var mark: String {
        switch self {
        case .ok: "✅"
        case .warn: "⚠️"
        case .bad: "❗"
        }
    }
}

enum MemoryPressure: Sendable {
    case normal, warning, critical, unknown

    /// `kern.memorystatus_vm_pressure_level`: 1 — норма, 2 — предупреждение, 4 — критично.
    init(sysctl v: Int64?) {
        switch v {
        case 1: self = .normal
        case 2: self = .warning
        case 4: self = .critical
        default: self = .unknown
        }
    }

    var title: String {
        switch self {
        case .normal: String(localized: "нагрузка нормальная")
        case .warning: String(localized: "памяти не хватает")
        case .critical: String(localized: "памяти сильно не хватает")
        case .unknown: String(localized: "нет данных")
        }
    }
}

struct BatterySummary: Sendable, Equatable {
    var percent: Int
    var charging: Bool
    var pluggedIn: Bool
    var cycles: Int?
    /// Полная ёмкость относительно заводской, %.
    var health: Double?
    var serviceRecommended = false

    var powerState: String {
        charging ? String(localized: "заряжается") : (pluggedIn ? String(localized: "от сети") : String(localized: "от батареи"))
    }
}

struct NetworkSummary: Sendable, Equatable {
    /// Есть ли подключение к сети (Wi-Fi/кабель) по мнению macOS.
    var connected: Bool
    /// «Wi-Fi», «Кабель», «iPhone (режим модема)»…
    var interface: String?
    var localIP: String?
    /// Отвечает ли интернет (nil — не проверяли).
    var internet: Bool?
}

struct ProcessUsage: Sendable, Equatable {
    var name: String
    var cpu: Double
    var memory: Int64
}

struct CrashEvent: Sendable, Equatable {
    enum Kind: Sendable { case crash, hang, panic, memory }
    var app: String
    var date: Date
    var kind: Kind
}

struct SystemReport: Sendable {
    var collectedAt = Date()
    var computerName: String?
    var userName: String?
    var modelName = "Mac"
    var modelID: String?
    var chip: String?
    var memory: Int64?
    var serial: String?
    var osVersion = ""
    var osBuild: String?
    var bootTime: Date?
    var diskTotal: Int64?
    var diskFree: Int64?
    var memoryPressure: MemoryPressure = .unknown
    var swapUsed: Int64?
    var battery: BatterySummary?
    var network: NetworkSummary?
    var topProcesses: [ProcessUsage] = []
    var crashes: [CrashEvent] = []
    /// Ожидающие обновления (из сохранённого списка macOS); nil — неизвестно.
    var updates: [String]?

    var uptime: TimeInterval? { bootTime.map { collectedAt.timeIntervalSince($0) } }

    var osName: String {
        let major = Int(osVersion.split(separator: ".").first ?? "") ?? 0
        let names = [13: "Ventura", 14: "Sonoma", 15: "Sequoia", 26: "Tahoe"]
        return names[major].map { "macOS \(osVersion) \($0)" } ?? "macOS \(osVersion)"
    }

    var diskFreeFraction: Double? {
        guard let t = diskTotal, t > 0, let f = diskFree else { return nil }
        return Double(f) / Double(t)
    }
}

// MARK: - Выводы («светофор»)

struct Finding: Identifiable, Sendable, Equatable {
    var id: String
    var level: Level
    var title: String
    var advice: String
}

extension SystemReport {
    var findings: [Finding] {
        var out: [Finding] = []
        let gb: Int64 = 1_000_000_000

        if let free = diskFree, let frac = diskFreeFraction {
            if free < 10 * gb || frac < 0.05 {
                out.append(Finding(id: "disk", level: .bad, title: String(localized: "Почти не осталось места на диске (\(Fmt.bytes(free)))"),
                                   advice: String(localized: "Mac может тормозить и не ставить обновления. Удалите ненужное или откройте CleanerMom.")))
            } else if free < 25 * gb || frac < 0.10 {
                out.append(Finding(id: "disk", level: .warn, title: String(localized: "Мало места на диске (\(Fmt.bytes(free)))"),
                                   advice: String(localized: "Стоит освободить место: Корзина, Загрузки, старые видео.")))
            }
        }
        if let up = uptime {
            let days = Int(up / 86_400)
            if days >= 30 {
                out.append(Finding(id: "uptime", level: .bad, title: String(localized: "Mac не перезагружали \(Fmt.days(days))"),
                                   advice: String(localized: "Перезагрузите Mac: меню  → «Перезагрузить…». Это лечит многие странности.")))
            } else if days >= 7 {
                out.append(Finding(id: "uptime", level: .warn, title: String(localized: "Mac не перезагружали \(Fmt.days(days))"),
                                   advice: String(localized: "Перезагрузка раз в неделю помогает, если Mac стал медленнее.")))
            }
        }
        switch memoryPressure {
        case .critical:
            out.append(Finding(id: "memory", level: .bad, title: String(localized: "Сильно не хватает памяти"),
                               advice: String(localized: "Закройте лишние вкладки и приложения, особенно браузеры.")))
        case .warning:
            out.append(Finding(id: "memory", level: .warn, title: String(localized: "Памяти не хватает"),
                               advice: String(localized: "Закройте то, чем сейчас не пользуетесь.")))
        default: break
        }
        if let b = battery {
            if b.serviceRecommended {
                out.append(Finding(id: "battery", level: .bad, title: String(localized: "Батарее нужно обслуживание"),
                                   advice: String(localized: "macOS рекомендует заменить батарею — покажите это помощнику.")))
            } else if let h = b.health, h < 80 {
                out.append(Finding(id: "battery", level: .warn, title: String(localized: "Батарея изношена (\(Fmt.percent(h)) от новой)"),
                                   advice: String(localized: "Держит заряд меньше, чем раньше. Это нормально для старого Mac.")))
            }
        }
        if let n = network {
            if !n.connected {
                out.append(Finding(id: "network", level: .bad, title: String(localized: "Нет подключения к сети"),
                                   advice: String(localized: "Проверьте Wi-Fi в правом верхнем углу экрана.")))
            } else if n.internet == false {
                out.append(Finding(id: "network", level: .bad, title: String(localized: "Wi-Fi есть, а интернета нет"),
                                   advice: String(localized: "Перезагрузите роутер: выключите его из розетки на 30 секунд.")))
            }
        }
        if crashes.contains(where: { $0.kind == .panic }) {
            out.append(Finding(id: "panic", level: .bad, title: String(localized: "Mac сам перезагружался из-за сбоя"),
                               advice: String(localized: "Это бывает редко. Если повторяется — покажите отчёт помощнику.")))
        }
        let apps = crashGroups.filter { $0.kind == .crash || $0.kind == .hang }
        if let worst = apps.first, worst.count >= 3 {
            out.append(Finding(id: "crash", level: .warn, title: String(localized: "«\(worst.app)» часто вылетает (\(Fmt.times(worst.count)) за неделю)"),
                               advice: String(localized: "Обновите это приложение или переустановите его.")))
        }
        if let u = updates, !u.isEmpty {
            out.append(Finding(id: "updates", level: .warn, title: String(localized: "Есть обновления: \(u.prefix(3).joined(separator: ", "))"),
                               advice: String(localized: "Установите их в «Системные настройки → Основные → Обновление ПО».")))
        }
        return out.sorted { $0.level > $1.level }
    }

    var overall: Level { findings.map(\.level).max() ?? .ok }

    var headline: String {
        switch overall {
        case .ok: String(localized: "Всё в порядке")
        case .warn: String(localized: "Есть на что посмотреть")
        case .bad: String(localized: "Нужна помощь")
        }
    }

    struct CrashGroup: Equatable {
        var app: String
        var kind: CrashEvent.Kind
        var count: Int
        var last: Date

        var title: String {
            switch kind {
            case .crash: String(localized: "\(app) — вылетало")
            case .hang: String(localized: "\(app) — зависало")
            case .panic: String(localized: "Mac перезагружался из-за сбоя")
            case .memory: String(localized: "Не хватало памяти")
            }
        }
    }

    /// Сбои, сгруппированные по приложению: чаще всего — первыми.
    var crashGroups: [CrashGroup] {
        var map: [String: CrashGroup] = [:]
        for c in crashes {
            let key = "\(c.app)|\(c.kind)"
            var g = map[key] ?? CrashGroup(app: c.app, kind: c.kind, count: 0, last: c.date)
            g.count += 1
            g.last = max(g.last, c.date)
            map[key] = g
        }
        return map.values.sorted { ($0.count, $0.last) > ($1.count, $1.last) }
    }
}

// MARK: - Текст отчёта (для мессенджера)

extension SystemReport {
    func text(includeSerial: Bool) -> String {
        var l: [String] = []
        l.append(String(localized: "Отчёт HelpMom — \(Fmt.dateTime(collectedAt))"))
        if let c = computerName {
            l.append(String(localized: "Компьютер: \(c)") + (userName.map { String(localized: ", пользователь \($0)") } ?? ""))
        }
        l.append("")
        l.append("\(overall.mark) \(headline)")
        for f in findings { l.append("\(f.level.mark) \(f.title). \(f.advice)") }
        l.append("")
        l.append("Mac: \(modelName)" + (modelID.map { " (\($0))" } ?? ""))
        var hw: [String] = []
        if let chip { hw.append(String(localized: "Процессор: \(chip)")) }
        if let memory { hw.append(String(localized: "Память: \(Fmt.bytes(memory, binary: true))")) }
        if !hw.isEmpty { l.append(hw.joined(separator: " · ")) }
        if includeSerial, let serial { l.append(String(localized: "Серийный номер: \(serial)")) }
        l.append(String(localized: "Система: \(osName)") + (osBuild.map { " (\($0))" } ?? ""))
        if let up = uptime { l.append(String(localized: "Работает без перезагрузки: \(Fmt.uptime(up))")) }
        if let free = diskFree, let total = diskTotal, let frac = diskFreeFraction {
            l.append(String(localized: "Диск: свободно \(Fmt.bytes(free)) из \(Fmt.bytes(total)) (\(Fmt.percent(frac * 100)))"))
        }
        l.append(String(localized: "Память: \(memoryPressure.title)")
                 + (swapUsed.flatMap { $0 > 0 ? String(localized: ", своп \(Fmt.bytes($0))") : nil } ?? ""))
        if let b = battery {
            var s = String(localized: "Батарея: \(Fmt.percent(Double(b.percent))), \(b.powerState)")
            if let h = b.health { s += String(localized: "; здоровье \(Fmt.percent(h))") }
            if let c = b.cycles { s += ", \(Fmt.cycles(c))" }
            if b.serviceRecommended { s += String(localized: "; рекомендуется обслуживание") }
            l.append(s)
        }
        if let n = network {
            var s: String
            if !n.connected { s = String(localized: "Сеть: не подключено") } else {
                s = String(localized: "Сеть: \(n.interface ?? String(localized: "подключено"))")
                switch n.internet {
                case true?: s += String(localized: ", интернет есть")
                case false?: s += String(localized: ", интернет не отвечает")
                case nil: break
                }
                if let ip = n.localIP { s += String(localized: "; адрес \(ip)") }
            }
            l.append(s)
        }
        if !topProcesses.isEmpty {
            l.append("")
            l.append(String(localized: "Больше всего грузят процессор:"))
            for (i, p) in topProcesses.enumerated() {
                l.append(String(localized: "  \(i + 1). \(p.name) — \(Fmt.percent(p.cpu)) ЦП, \(Fmt.bytes(p.memory))"))
            }
        }
        l.append("")
        let groups = crashGroups
        if groups.isEmpty {
            l.append(String(localized: "Сбоев приложений за 7 дней: нет"))
        } else {
            l.append(String(localized: "Сбои за 7 дней:"))
            for g in groups.prefix(8) {
                l.append(String(localized: "  \(g.title): \(Fmt.times(g.count)), последний \(Fmt.dayMonth(g.last))"))
            }
        }
        if let u = updates {
            l.append(u.isEmpty ? String(localized: "Обновления: всё установлено")
                               : String(localized: "Ждут установки: \(u.joined(separator: ", "))"))
        }
        return l.joined(separator: "\n")
    }
}
