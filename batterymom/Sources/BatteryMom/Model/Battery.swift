import Foundation
import IOKit
import IOKit.ps

// Встроенная батарея: IORegistry (AppleSmartBattery) + IOPowerSources (то, что показывает строка меню macOS).
// Разбор отделён от чтения (`BatteryInfo.parse`), чтобы его можно было проверить на заготовленных словарях.

struct AdapterInfo: Sendable, Equatable {
    var watts: Int?
    var name: String
    var manufacturer: String?
}

struct BatteryInfo: Sendable, Equatable {
    enum State: Sendable, Equatable {
        case charging, charged, pluggedNotCharging, onBattery

        var title: String {
            switch self {
            case .charging: String(localized: "Заряжается")
            case .charged: String(localized: "Заряжен")
            case .pluggedNotCharging: String(localized: "Подключён к питанию, зарядка на паузе")
            case .onBattery: String(localized: "От батареи")
            }
        }

        var short: String {
            switch self {
            case .charging: String(localized: "заряжается")
            case .charged: String(localized: "заряжен")
            case .pluggedNotCharging: String(localized: "от сети")
            case .onBattery: String(localized: "от батареи")
            }
        }
    }

    var percent: Int
    var isCharging: Bool
    var externalConnected: Bool
    var fullyCharged: Bool
    /// nil — macOS ещё считает (или неприменимо).
    var minutesToFull: Int?
    var minutesToEmpty: Int?
    var cycleCount: Int?
    var designCycleCount: Int = 1000
    /// мА·ч
    var designCapacity: Int?
    var maxCapacity: Int?
    var currentCapacity: Int?
    var healthRaw: String?
    var serviceRecommended = false
    /// °C
    var temperature: Double?
    /// В
    var voltage: Double?
    /// А: плюс — заряд, минус — разряд.
    var amperage: Double?
    /// Вт, сколько потребляет весь Mac (есть на Apple silicon).
    var systemLoad: Double?
    var adapter: AdapterInfo?
    var manufactureDate: Date?
    var serial: String?
    var lowPowerMode = false
    var optimizedChargingEngaged: Bool?

    var state: State {
        if isCharging { return .charging }
        if externalConnected { return fullyCharged || percent >= 100 ? .charged : .pluggedNotCharging }
        return .onBattery
    }

    /// Вт через батарею: плюс — заряжается, минус — разряжается.
    var batteryPower: Double? {
        guard let voltage, let amperage else { return nil }
        return voltage * amperage
    }

    /// Сколько тратит Mac прямо сейчас.
    var consumption: Double? {
        if let systemLoad, systemLoad > 0 { return systemLoad }
        if let p = batteryPower, p < 0 { return -p }
        return nil
    }

    /// Текущая полная ёмкость относительно заводской, %.
    var health: Double? {
        guard let d = designCapacity, d > 0, let m = maxCapacity, m > 0 else { return nil }
        return min(100, Double(m) / Double(d) * 100)
    }

    var conditionTitle: String { serviceRecommended ? String(localized: "Рекомендуется обслуживание") : String(localized: "Нормальное") }

    static func healthVerdict(_ h: Double) -> String {
        switch h {
        case 90...: String(localized: "Отличное — батарея почти как новая")
        case 80..<90: String(localized: "Хорошее — обычный износ")
        case 70..<80: String(localized: "Заметный износ — держит заряд меньше, чем раньше")
        default: String(localized: "Сильный износ — стоит подумать о замене")
        }
    }

    /// Строка «осталось / до полного».
    var timeText: String? {
        switch state {
        case .charging: return minutesToFull.map { String(localized: "До полного: \(Fmt.minutes($0))") } ?? String(localized: "До полного: подсчёт…")
        case .onBattery: return minutesToEmpty.map { String(localized: "Осталось: \(Fmt.minutes($0))") } ?? String(localized: "Осталось: подсчёт…")
        case .charged, .pluggedNotCharging: return nil
        }
    }
}

// MARK: - Разбор

extension BatteryInfo {
    /// `registry` — свойства AppleSmartBattery, `source` — описание InternalBattery из IOPowerSources,
    /// `adapterDetails` — IOPSCopyExternalPowerAdapterDetails. nil — батареи нет.
    static func parse(registry: [String: Any]?, source: [String: Any]?, adapterDetails: [String: Any]?) -> BatteryInfo? {
        let r = registry ?? [:], s = source ?? [:]
        if registry == nil && source == nil { return nil }
        if bool(r["BatteryInstalled"]) == false || bool(s["Is Present"]) == false { return nil }

        // Процент: IOPowerSources даёт его одинаково на Intel и Apple silicon.
        var percent: Int?
        if let cur = int(s["Current Capacity"]), let mx = int(s["Max Capacity"]), mx > 0 {
            percent = Int((Double(cur) / Double(mx) * 100).rounded())
        } else if let cur = int(r["CurrentCapacity"]), let mx = int(r["MaxCapacity"]), mx > 0 {
            percent = Int((Double(cur) / Double(mx) * 100).rounded())  // на Intel оба в мА·ч, на Apple silicon оба в %
        }
        guard let percent else { return nil }

        var b = BatteryInfo(percent: min(100, max(0, percent)),
                            isCharging: bool(s["Is Charging"]) ?? bool(r["IsCharging"]) ?? false,
                            externalConnected: bool(r["ExternalConnected"]) ?? (s["Power Source State"] as? String == "AC Power"),
                            fullyCharged: bool(r["FullyCharged"]) ?? bool(s["Is Charged"]) ?? false)

        // Время: в IOPowerSources — минуты (0 — неприменимо, −1 — считается). В реестре 65535 — нет данных.
        func minutes(_ ps: String, _ reg: String) -> Int? {
            if let v = int(s[ps]) { return v > 0 ? v : nil }
            if let v = int(r[reg]), v > 0, v < 65535 { return v }
            return nil
        }
        b.minutesToFull = minutes("Time to Full Charge", "AvgTimeToFull")
        b.minutesToEmpty = minutes("Time to Empty", "AvgTimeToEmpty")

        b.cycleCount = int(r["CycleCount"])
        b.designCycleCount = int(s["DesignCycleCount"]) ?? int(r["DesignCycleCount9C"]) ?? 1000
        b.designCapacity = int(r["DesignCapacity"])
        // Apple silicon: MaxCapacity/CurrentCapacity — проценты, ёмкость в мА·ч лежит в Nominal/AppleRaw*.
        // Intel: MaxCapacity/CurrentCapacity — уже мА·ч (AppleRaw* тоже есть на новых моделях).
        let regMax = int(r["MaxCapacity"]), regCur = int(r["CurrentCapacity"])
        let percentMode = (regMax ?? 0) <= 100
        b.maxCapacity = int(r["NominalChargeCapacity"]) ?? int(r["AppleRawMaxCapacity"]) ?? (percentMode ? nil : regMax)
        b.currentCapacity = int(r["AppleRawCurrentCapacity"]) ?? (percentMode ? nil : regCur)

        let health = s["BatteryHealth"] as? String
        let condition = (s["BatteryHealthCondition"] as? String).flatMap { $0.isEmpty ? nil : $0 }
        b.healthRaw = condition ?? health
        b.serviceRecommended = condition != nil
            || (health != nil && health != "Good")
            || (int(r["PermanentFailureStatus"]) ?? 0) != 0

        if let t = double(r["Temperature"]), t > 0 { b.temperature = t / 100 }
        if let v = double(r["Voltage"]) ?? double(r["AppleRawBatteryVoltage"]), v > 0 { b.voltage = v / 1000 }
        if let a = signed(r["Amperage"]) ?? signed(r["InstantAmperage"]) { b.amperage = Double(a) / 1000 }
        if let tele = r["PowerTelemetryData"] as? [String: Any], let load = double(tele["SystemLoad"]), load > 0 {
            b.systemLoad = load / 1000
        }

        if b.externalConnected {
            let a = adapterDetails ?? (r["AdapterDetails"] as? [String: Any]) ?? [:]
            let name = (a["Name"] as? String) ?? (a["Description"] as? String).map(prettyAdapter) ?? String(localized: "Адаптер питания")
            b.adapter = AdapterInfo(watts: int(a["Watts"]).flatMap { $0 > 0 ? $0 : nil }, name: name,
                                    manufacturer: a["Manufacturer"] as? String)
        }

        b.manufactureDate = int(r["ManufactureDate"]).flatMap(decodePackedDate)
        b.serial = (r["Serial"] as? String) ?? (s["Hardware Serial Number"] as? String)
        b.lowPowerMode = bool(s["LPM Active"]) ?? false
        b.optimizedChargingEngaged = bool(s["Optimized Battery Charging Engaged"])
        return b
    }

    /// Дата в формате Smart Battery (Intel): ((год − 1980) << 9) | (месяц << 5) | день.
    /// На Apple silicon поле устроено иначе (не задокументировано) — там дату не показываем.
    static func decodePackedDate(_ v: Int) -> Date? {
        guard v > 0, v < 65536 else { return nil }
        let day = v & 31, month = (v >> 5) & 15, year = 1980 + (v >> 9)
        guard (1...31).contains(day), (1...12).contains(month), (2005...2100).contains(year) else { return nil }
        return Calendar(identifier: .gregorian).date(from: DateComponents(year: year, month: month, day: day))
    }

    private static func prettyAdapter(_ d: String) -> String {
        switch d.lowercased() {
        case "pd charger": String(localized: "Зарядка USB-C")
        case "magsafe": "MagSafe"
        default: d
        }
    }

    static func int(_ v: Any?) -> Int? { (v as? NSNumber)?.intValue }
    static func double(_ v: Any?) -> Double? { (v as? NSNumber)?.doubleValue }
    /// Отрицательный ток ioreg иногда отдаёт как огромное беззнаковое — берём битовый шаблон Int64.
    static func signed(_ v: Any?) -> Int64? {
        guard let n = v as? NSNumber else { return nil }
        return Int64(bitPattern: n.uint64Value)
    }
    static func bool(_ v: Any?) -> Bool? {
        if let b = v as? Bool { return b }
        if let n = v as? NSNumber { return n.boolValue }
        if let s = v as? String { return ["yes", "true", "1"].contains(s.lowercased()) }
        return nil
    }
}

// MARK: - Чтение

enum BatteryReader {
    static func read() -> BatteryInfo? {
        BatteryInfo.parse(registry: registry(), source: powerSource(), adapterDetails: adapter())
    }

    static func registry() -> [String: Any]? {
        let service = IOServiceGetMatchingService(kIOMainPortDefault, IOServiceMatching("AppleSmartBattery"))
        guard service != 0 else { return nil }
        defer { IOObjectRelease(service) }
        var props: Unmanaged<CFMutableDictionary>?
        guard IORegistryEntryCreateCFProperties(service, &props, kCFAllocatorDefault, 0) == KERN_SUCCESS,
              let dict = props?.takeRetainedValue() as? [String: Any] else { return nil }
        return dict
    }

    static func powerSource() -> [String: Any]? {
        guard let info = IOPSCopyPowerSourcesInfo()?.takeRetainedValue(),
              let list = IOPSCopyPowerSourcesList(info)?.takeRetainedValue() as? [CFTypeRef] else { return nil }
        for ps in list {
            if let d = IOPSGetPowerSourceDescription(info, ps)?.takeUnretainedValue() as? [String: Any],
               d["Type"] as? String == "InternalBattery" {
                return d
            }
        }
        return nil
    }

    static func adapter() -> [String: Any]? {
        IOPSCopyExternalPowerAdapterDetails()?.takeRetainedValue() as? [String: Any]
    }
}

/// Мгновенное уведомление macOS о смене источника питания (подключили/отключили зарядку, изменился процент).
enum PowerEvents {
    nonisolated(unsafe) static var handler: (() -> Void)?
    nonisolated(unsafe) private static var source: CFRunLoopSource?

    static func start(_ onChange: @escaping () -> Void) {
        guard source == nil else { return }
        handler = onChange
        guard let src = IOPSNotificationCreateRunLoopSource({ _ in PowerEvents.handler?() }, nil)?.takeRetainedValue()
        else { return }
        source = src
        CFRunLoopAddSource(CFRunLoopGetMain(), src, .defaultMode)
    }
}
