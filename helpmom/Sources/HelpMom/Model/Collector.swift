import Foundation
import IOKit
import IOKit.ps
import Network
import SystemConfiguration

// Сбор отчёта на этом Mac. Всё — локально и быстро (sysctl, IOKit, `ps`), без разрешений TCC:
// папки пользователя (Рабочий стол, Документы, Загрузки) не читаются. В сеть уходит только один `ping`
// до 1.1.1.1 — проверить, есть ли интернет.

enum Collector {
    static func collect() async -> SystemReport {
        async let net = network()
        var r = SystemReport()
        r.computerName = SCDynamicStoreCopyComputerName(nil, nil) as String?
        let full = NSFullUserName()
        r.userName = full.isEmpty ? nil : full
        hardware(&r)
        let v = ProcessInfo.processInfo.operatingSystemVersion
        r.osVersion = v.patchVersion > 0 ? "\(v.majorVersion).\(v.minorVersion).\(v.patchVersion)" : "\(v.majorVersion).\(v.minorVersion)"
        r.osBuild = Sysctl.string("kern.osversion")
        r.bootTime = Sysctl.bootTime()
        if let vals = try? URL(fileURLWithPath: "/").resourceValues(forKeys: [.volumeTotalCapacityKey, .volumeAvailableCapacityForImportantUsageKey]) {
            r.diskTotal = vals.volumeTotalCapacity.map(Int64.init)
            r.diskFree = vals.volumeAvailableCapacityForImportantUsage
        }
        r.memoryPressure = MemoryPressure(sysctl: Sysctl.int("kern.memorystatus_vm_pressure_level"))
        r.swapUsed = Sysctl.swapUsed()
        r.battery = battery()
        r.topProcesses = topProcesses()
        r.crashes = CrashReports.scan(dirs: CrashReports.defaultDirs, since: Date().addingTimeInterval(-7 * 86_400))
        r.updates = pendingUpdates()
        r.network = await net
        r.collectedAt = Date()
        return r
    }

    // MARK: Железо

    static func hardware(_ r: inout SystemReport) {
        r.modelID = Sysctl.string("hw.model")
        r.chip = Sysctl.string("machdep.cpu.brand_string")
        r.memory = Sysctl.int("hw.memsize")
        r.modelName = marketingName() ?? r.modelID.map(friendlyFamily) ?? "Mac"
        let expert = IOServiceGetMatchingService(kIOMainPortDefault, IOServiceMatching("IOPlatformExpertDevice"))
        if expert != 0 {
            r.serial = IORegistryEntryCreateCFProperty(expert, kIOPlatformSerialNumberKey as CFString, kCFAllocatorDefault, 0)?
                .takeRetainedValue() as? String
            IOObjectRelease(expert)
        }
    }

    /// «MacBook Pro (16-inch, 2021)»: на Apple silicon — из дерева устройств, на Intel — из кэша «Информации о системе».
    static func marketingName() -> String? {
        let entry = IORegistryEntryFromPath(kIOMainPortDefault, "IODeviceTree:/product")
        if entry != 0 {
            defer { IOObjectRelease(entry) }
            if let data = IORegistryEntryCreateCFProperty(entry, "product-name" as CFString, kCFAllocatorDefault, 0)?
                .takeRetainedValue() as? Data {
                let s = String(decoding: data, as: UTF8.self).trimmingCharacters(in: CharacterSet(charactersIn: "\0").union(.whitespaces))
                if !s.isEmpty { return s }
            }
        }
        let plist = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Preferences/com.apple.SystemProfiler.plist")
        if let d = NSDictionary(contentsOf: plist), let names = d["CPU Names"] as? [String: String], let n = names.values.first {
            return n
        }
        return nil
    }

    static func friendlyFamily(_ id: String) -> String {
        for (prefix, name) in [("MacBookPro", "MacBook Pro"), ("MacBookAir", "MacBook Air"), ("MacBook", "MacBook"),
                               ("iMac", "iMac"), ("Macmini", "Mac mini"), ("MacPro", "Mac Pro")] where id.hasPrefix(prefix) {
            return name
        }
        return "Mac"
    }

    // MARK: Батарея

    static func battery() -> BatterySummary? {
        guard let info = IOPSCopyPowerSourcesInfo()?.takeRetainedValue(),
              let list = IOPSCopyPowerSourcesList(info)?.takeRetainedValue() as? [CFTypeRef] else { return nil }
        var src: [String: Any]?
        for ps in list {
            if let d = IOPSGetPowerSourceDescription(info, ps)?.takeUnretainedValue() as? [String: Any],
               d[kIOPSTypeKey] as? String == kIOPSInternalBatteryType {
                src = d
            }
        }
        guard let s = src, (s[kIOPSIsPresentKey] as? Bool) != false,
              let cur = s[kIOPSCurrentCapacityKey] as? Int, let mx = s[kIOPSMaxCapacityKey] as? Int, mx > 0 else { return nil }
        var b = BatterySummary(percent: Int((Double(cur) / Double(mx) * 100).rounded()),
                               charging: s[kIOPSIsChargingKey] as? Bool ?? false,
                               pluggedIn: s[kIOPSPowerSourceStateKey] as? String == kIOPSACPowerValue)
        if let cond = s["BatteryHealthCondition"] as? String, !cond.isEmpty { b.serviceRecommended = true }
        let svc = IOServiceGetMatchingService(kIOMainPortDefault, IOServiceMatching("AppleSmartBattery"))
        if svc != 0 {
            defer { IOObjectRelease(svc) }
            var props: Unmanaged<CFMutableDictionary>?
            if IORegistryEntryCreateCFProperties(svc, &props, kCFAllocatorDefault, 0) == KERN_SUCCESS,
               let r = props?.takeRetainedValue() as? [String: Any] {
                b.cycles = r["CycleCount"] as? Int
                b.health = batteryHealth(r)
            }
        }
        return b
    }

    /// Полная ёмкость / заводская. На Apple silicon MaxCapacity — в процентах, мА·ч — в NominalChargeCapacity.
    static func batteryHealth(_ r: [String: Any]) -> Double? {
        guard let design = r["DesignCapacity"] as? Int, design > 0 else { return nil }
        let full = (r["NominalChargeCapacity"] as? Int) ?? (r["AppleRawMaxCapacity"] as? Int)
            ?? ((r["MaxCapacity"] as? Int).flatMap { $0 > 100 ? $0 : nil })
        guard let full, full > 0 else { return nil }
        return min(100, Double(full) / Double(design) * 100)
    }

    // MARK: Сеть

    static func network() async -> NetworkSummary {
        let path: NWPath? = await withCheckedContinuation { cont in
            let m = NWPathMonitor()
            let q = DispatchQueue(label: "helpmom.path")
            let once = Once()
            m.pathUpdateHandler = { p in if once.fire() { m.cancel(); cont.resume(returning: p) } }
            m.start(queue: q)
            q.asyncAfter(deadline: .now() + 2) { if once.fire() { m.cancel(); cont.resume(returning: nil) } }
        }
        guard let path, path.status == .satisfied else {
            return NetworkSummary(connected: false, interface: nil, localIP: nil, internet: nil)
        }
        let iface = path.availableInterfaces.first { path.usesInterfaceType($0.type) } ?? path.availableInterfaces.first
        let kind: String?
        switch iface?.type {
        case .wifi?: kind = "Wi-Fi"
        case .wiredEthernet?: kind = String(localized: "Кабель")
        case .cellular?: kind = String(localized: "Мобильная сеть")
        default: kind = iface.map { _ in path.isExpensive ? String(localized: "iPhone (режим модема)") : String(localized: "Сеть") }
        }
        let ip = iface.flatMap { localIPv4(interface: $0.name) }
        let ping = await Task.detached { Shell.run("/sbin/ping", ["-c", "1", "-t", "3", "-q", "1.1.1.1"], timeout: 5) != nil }.value
        return NetworkSummary(connected: true, interface: kind, localIP: ip, internet: ping)
    }

    static func localIPv4(interface: String) -> String? {
        var head: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&head) == 0, let first = head else { return nil }
        defer { freeifaddrs(head) }
        for p in sequence(first: first, next: { $0.pointee.ifa_next }) {
            let a = p.pointee
            guard String(cString: a.ifa_name) == interface, let sa = a.ifa_addr, sa.pointee.sa_family == UInt8(AF_INET) else { continue }
            var host = [CChar](repeating: 0, count: Int(NI_MAXHOST))
            if getnameinfo(sa, socklen_t(sa.pointee.sa_len), &host, socklen_t(host.count), nil, 0, NI_NUMERICHOST) == 0 {
                return String(cString: host)
            }
        }
        return nil
    }

    // MARK: Процессы

    static func topProcesses(limit: Int = 5) -> [ProcessUsage] {
        guard let out = Shell.run("/bin/ps", ["-Ao", "pcpu=,rss=,comm="]) else { return [] }
        return ProcessParser.top(psOutput: out, limit: limit, exclude: ["ps", ProcessInfo.processInfo.processName])
    }

    // MARK: Обновления

    /// Список, который macOS сама сохраняет после фоновой проверки (без обращения к серверам Apple).
    static func pendingUpdates() -> [String]? {
        guard let d = NSDictionary(contentsOfFile: "/Library/Preferences/com.apple.SoftwareUpdate.plist") else { return nil }
        guard let list = d["RecommendedUpdates"] as? [[String: Any]] else {
            return (d["LastRecommendedUpdatesAvailable"] as? Int) == 0 ? [] : nil
        }
        return list.compactMap { ($0["Display Name"] as? String)?.replacingOccurrences(of: "\u{00a0}", with: " ") }
    }
}

/// Срабатывает один раз (для продолжения, которое могут вызвать и монитор сети, и таймаут).
final class Once: @unchecked Sendable {
    private var done = false
    private let lock = NSLock()
    func fire() -> Bool {
        lock.lock(); defer { lock.unlock() }
        if done { return false }
        done = true
        return true
    }
}

// MARK: - Разбор `ps`

enum ProcessParser {
    /// Строки `pcpu rss comm` (comm — полный путь). Помощники приложений складываются в своё приложение:
    /// «…/Google Chrome.app/…/Google Chrome Helper (Renderer)» → «Google Chrome».
    static func top(psOutput: String, limit: Int, exclude: Set<String> = ["ps"]) -> [ProcessUsage] {
        var map: [String: ProcessUsage] = [:]
        for line in psOutput.split(separator: "\n") {
            var rest = Substring(line).drop { $0 == " " }
            let c = rest.prefix { $0 != " " }
            rest = rest.dropFirst(c.count).drop { $0 == " " }
            let m = rest.prefix { $0 != " " }
            let path = rest.dropFirst(m.count).drop { $0 == " " }
            guard !path.isEmpty, let cpu = Double(c.replacingOccurrences(of: ",", with: ".")), let rss = Int64(m) else { continue }
            let name = appName(path: String(path))
            if exclude.contains(name) { continue }
            var u = map[name] ?? ProcessUsage(name: name, cpu: 0, memory: 0)
            u.cpu += cpu
            u.memory += rss * 1024
            map[name] = u
        }
        return Array(map.values.sorted { ($0.cpu, $0.memory) > ($1.cpu, $1.memory) }.prefix(limit))
    }

    static func appName(path: String) -> String {
        if let r = path.range(of: ".app/") {
            let before = path[..<r.lowerBound]
            return String(before.split(separator: "/").last ?? Substring(path))
        }
        return (path as NSString).lastPathComponent
    }
}

// MARK: - Отчёты о сбоях

enum CrashReports {
    static var defaultDirs: [URL] {
        let home = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Logs/DiagnosticReports")
        let sys = URL(fileURLWithPath: "/Library/Logs/DiagnosticReports")
        return [home, home.appendingPathComponent("Retired"), sys, sys.appendingPathComponent("Retired")]
    }

    /// Только имена файлов и даты — содержимое отчётов не читается.
    static func scan(dirs: [URL], since: Date) -> [CrashEvent] {
        var seen = Set<String>()
        var out: [CrashEvent] = []
        let fm = FileManager.default
        for dir in dirs {
            guard let names = try? fm.contentsOfDirectory(atPath: dir.path) else { continue }
            for name in names where !seen.contains(name) {
                seen.insert(name)
                guard var e = parse(fileName: name) else { continue }
                if e.date == .distantPast {
                    let attrs = try? fm.attributesOfItem(atPath: dir.appendingPathComponent(name).path)
                    e.date = attrs?[.modificationDate] as? Date ?? .distantPast
                }
                if e.date >= since { out.append(e) }
            }
        }
        return out.sorted { $0.date > $1.date }
    }

    private static let stamp: DateFormatter = {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = "yyyy-MM-dd-HHmmss"
        return f
    }()

    /// «Safari-2026-11-20-101010.ips» → Safari, сбой; «JetsamEvent-…ips» → нехватка памяти;
    /// «panic-full-….panic» → перезагрузка из-за сбоя; служебные (.diag, ExcUserFault, Sandbox…) — nil.
    static func parse(fileName: String) -> CrashEvent? {
        if fileName.hasPrefix(".") { return nil }
        let ext = (fileName as NSString).pathExtension.lowercased()
        let base = (fileName as NSString).deletingPathExtension
        var app = base
        var date = Date.distantPast
        if let m = base.firstMatch(of: #/^(.+?)[-_](\d{4}-\d{2}-\d{2}-\d{6})/#) {
            app = String(m.1)
            date = stamp.date(from: String(m.2)) ?? .distantPast
        }
        let kind: CrashEvent.Kind
        switch ext {
        case "panic":
            kind = .panic
        case "hang", "spin":
            kind = .hang
        case "ips", "crash":
            if app.hasPrefix("panic") || app.hasPrefix("Kernel") { kind = .panic }
            else if app.hasPrefix("JetsamEvent") { kind = .memory }
            else if ["ExcUserFault", "Sandbox", "stacks", "LowBattery", "WiFi", "Bluetooth", "Siri"].contains(where: { app.hasPrefix($0) }) { return nil }
            else { kind = .crash }
        default:
            return nil
        }
        if kind == .panic { app = "macOS" }
        if kind == .memory { app = String(localized: "Память") }
        if app.hasPrefix("ExcUserFault_") { return nil }
        return CrashEvent(app: app, date: date, kind: kind)
    }
}
