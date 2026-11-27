import Foundation

// Батареи Bluetooth-устройств. Источники не требуют разрешений macOS (CoreBluetooth спросил бы — не используем):
//  • `ioreg -r -k BatteryPercent -a` — Magic Mouse / Keyboard / Trackpad и другие HID-устройства (живые данные);
//  • `system_profiler SPBluetoothDataType -json` — AirPods и наушники (левый/правый/футляр), а также
//    последний известный заряд отключённых устройств.

struct DeviceBattery: Identifiable, Sendable, Hashable {
    enum Kind: String, Sendable {
        case mouse, keyboard, trackpad, airpods, airpodsMax, headphones, speaker, gamepad, other

        var symbol: String {
            switch self {
            case .mouse: "magicmouse"
            case .keyboard: "keyboard"
            case .trackpad: "rectangle.and.hand.point.up.left"
            case .airpods: "airpods"
            case .airpodsMax: "airpodsmax"
            case .headphones: "headphones"
            case .speaker: "hifispeaker"
            case .gamepad: "gamecontroller"
            case .other: "dot.radiowaves.left.and.right"
            }
        }

        var title: String {
            switch self {
            case .mouse: String(localized: "Мышь")
            case .keyboard: String(localized: "Клавиатура")
            case .trackpad: String(localized: "Трекпад")
            case .airpods, .airpodsMax, .headphones: String(localized: "Наушники")
            case .speaker: String(localized: "Колонка")
            case .gamepad: String(localized: "Геймпад")
            case .other: String(localized: "Устройство")
            }
        }
    }

    struct Level: Hashable, Sendable {
        /// nil — единственная батарея; иначе «Левый», «Правый», «Футляр».
        var label: String?
        var percent: Int
    }

    var id: String
    var name: String
    var kind: Kind
    var levels: [Level]
    var connected: Bool
    var charging = false
    var address: String?

    var lowest: Int { levels.map(\.percent).min() ?? 0 }

    /// «Л 7 % · П 10 % · футляр 68 %» или «75 %».
    var levelsText: String {
        levels.map { l in
            let short = l.label.map { [String(localized: "Левый"): String(localized: "Л"), String(localized: "Правый"): String(localized: "П"), String(localized: "Футляр"): String(localized: "футляр")][$0] ?? $0 }
            return (short.map { "\($0) " } ?? "") + "\(l.percent) %"
        }.joined(separator: " · ")
    }
}

enum DeviceScanner {
    static func scan() -> [DeviceBattery] {
        let io = Shell.run("/usr/sbin/ioreg", ["-r", "-k", "BatteryPercent", "-a"], timeout: 10)
        let sp = Shell.run("/usr/sbin/system_profiler", ["SPBluetoothDataType", "-json"], timeout: 25)
        return merge(hid: parseIoreg(io.output), bluetooth: parseProfiler(sp.output))
    }

    // MARK: ioreg

    static func parseIoreg(_ data: Data) -> [DeviceBattery] {
        guard !data.isEmpty,
              let list = try? PropertyListSerialization.propertyList(from: data, format: nil) as? [[String: Any]]
        else { return [] }
        var out: [DeviceBattery] = []
        var seen = Set<String>()
        for d in list {
            guard let pct = BatteryInfo.int(d["BatteryPercent"]) else { continue }
            let name = (d["Product"] as? String) ?? (d["Name"] as? String) ?? String(localized: "Устройство")
            let address = (d["DeviceAddress"] as? String).map(normalizeAddress)
            let key = address ?? name
            guard seen.insert(key).inserted else { continue }  // одно устройство бывает в нескольких сервисах
            let flags = BatteryInfo.int(d["BatteryStatusFlags"]) ?? 0
            out.append(DeviceBattery(id: "hid:" + key, name: name, kind: kind(name: name, minorType: nil),
                                     levels: [.init(label: nil, percent: clamp(pct))], connected: true,
                                     charging: flags & 0x3 == 0x3, address: address))
        }
        return out
    }

    // MARK: system_profiler

    static func parseProfiler(_ data: Data) -> [DeviceBattery] {
        guard !data.isEmpty,
              let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let controllers = root["SPBluetoothDataType"] as? [[String: Any]] else { return [] }
        var out: [DeviceBattery] = []
        for c in controllers {
            for (section, connected) in [("device_connected", true), ("device_not_connected", false)] {
                for entry in (c[section] as? [[String: Any]]) ?? [] {
                    for (name, value) in entry {
                        guard let props = value as? [String: Any] else { continue }
                        let levels = levelKeys.compactMap { key, label -> DeviceBattery.Level? in
                            guard let s = props[key] as? String, let p = percent(s) else { return nil }
                            return .init(label: label, percent: p)
                        }
                        guard !levels.isEmpty else { continue }
                        let address = (props["device_address"] as? String).map(normalizeAddress)
                        out.append(DeviceBattery(id: "bt:" + (address ?? name), name: name,
                                                 kind: kind(name: name, minorType: props["device_minorType"] as? String),
                                                 levels: levels, connected: connected, address: address))
                    }
                }
            }
        }
        return out
    }

    private static let levelKeys: [(String, String?)] = [
        ("device_batteryLevelMain", nil), ("device_batteryLevel", nil),
        ("device_batteryLevelLeft", String(localized: "Левый")), ("device_batteryLevelRight", String(localized: "Правый")),
        ("device_batteryLevelCase", String(localized: "Футляр")),
    ]

    /// Живые данные ioreg важнее; из system_profiler добавляем то, чего в ioreg нет.
    static func merge(hid: [DeviceBattery], bluetooth: [DeviceBattery]) -> [DeviceBattery] {
        var out = hid
        let addresses = Set(hid.compactMap(\.address)), names = Set(hid.map { $0.name.lowercased() })
        for d in bluetooth {
            if let a = d.address, addresses.contains(a) { continue }
            if names.contains(d.name.lowercased()) { continue }
            out.append(d)
        }
        return out.sorted {
            $0.connected != $1.connected ? $0.connected : $0.name.localizedStandardCompare($1.name) == .orderedAscending
        }
    }

    static func kind(name: String, minorType: String?) -> DeviceBattery.Kind {
        let n = name.lowercased(), t = (minorType ?? "").lowercased()
        if n.contains("airpods max") || n.contains("max ap") { return .airpodsMax }
        if n.contains("airpods") { return .airpods }
        if n.contains("mouse") || n.contains("мыш") || t.contains("mouse") { return .mouse } // l10n:skip
        if n.contains("trackpad") || n.contains("трекпад") || t.contains("trackpad") { return .trackpad } // l10n:skip
        if n.contains("keyboard") || n.contains("клавиатур") || t.contains("keyboard") { return .keyboard } // l10n:skip
        if t.contains("headphone") || t.contains("headset") || n.contains("наушник") || n.contains("buds") { return .headphones } // l10n:skip
        if t.contains("speaker") { return .speaker }
        if t.contains("gamepad") || t.contains("joystick") || n.contains("controller") { return .gamepad }
        return .other
    }

    /// «68 %» → 68.
    static func percent(_ s: String) -> Int? {
        let digits = s.prefix { $0.isNumber }
        return Int(digits).map(clamp)
    }

    /// «88-10-32-0e-a8-29» и «88:10:32:0E:A8:29» → одинаково.
    static func normalizeAddress(_ s: String) -> String {
        s.uppercased().replacingOccurrences(of: "-", with: ":")
    }

    private static func clamp(_ v: Int) -> Int { min(100, max(0, v)) }
}
