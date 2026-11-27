import CoreAudio
import CoreMediaIO
import Foundation

// MARK: - Датчики: кто сейчас включён
//
// Оба API только спрашивают у системы «работает ли устройство где-нибудь» — сами устройства не
// открываются, поэтому разрешения на камеру и микрофон не нужны и запросов на экране не бывает.

enum SensorKind: String, Codable, Sendable {
    case camera, microphone

    var title: String { self == .camera ? String(localized: "Камера") : String(localized: "Микрофон") }
    var icon: String { self == .camera ? "camera.fill" : "mic.fill" }
}

struct SensorDevice: Identifiable, Sendable, Equatable {
    var kind: SensorKind
    var uid: String
    var name: String
    var running: Bool

    var id: String { "\(kind.rawValue)|\(uid)" }
}

enum Sensors {
    static func all() -> [SensorDevice] { cameras() + microphones() }

    // MARK: Камеры (CoreMediaIO)

    static func cameras() -> [SensorDevice] {
        var addr = CMIOObjectPropertyAddress(
            mSelector: CMIOObjectPropertySelector(kCMIOHardwarePropertyDevices),
            mScope: CMIOObjectPropertyScope(kCMIOObjectPropertyScopeGlobal),
            mElement: CMIOObjectPropertyElement(0))
        let system = CMIOObjectID(kCMIOObjectSystemObject)
        var size: UInt32 = 0
        guard CMIOObjectGetPropertyDataSize(system, &addr, 0, nil, &size) == noErr, size > 0 else { return [] }
        var ids = [CMIOObjectID](repeating: 0, count: Int(size) / MemoryLayout<CMIOObjectID>.size)
        var used: UInt32 = 0
        guard CMIOObjectGetPropertyData(system, &addr, 0, nil, size, &used, &ids) == noErr else { return [] }
        return ids.map { id in
            SensorDevice(kind: .camera,
                         uid: cmioString(id, kCMIODevicePropertyDeviceUID) ?? "\(id)",
                         name: cmioString(id, kCMIOObjectPropertyName) ?? String(localized: "Камера \(id)"),
                         running: cmioUInt32(id, kCMIODevicePropertyDeviceIsRunningSomewhere) != 0)
        }
    }

    private static func cmioAddress(_ selector: Int) -> CMIOObjectPropertyAddress {
        CMIOObjectPropertyAddress(mSelector: CMIOObjectPropertySelector(selector),
                                  mScope: CMIOObjectPropertyScope(kCMIOObjectPropertyScopeWildcard),
                                  mElement: CMIOObjectPropertyElement(kCMIOObjectPropertyElementWildcard))
    }

    private static func cmioUInt32(_ id: CMIOObjectID, _ selector: Int) -> UInt32 {
        var addr = cmioAddress(selector)
        var value: UInt32 = 0
        var used: UInt32 = 0
        let size = UInt32(MemoryLayout<UInt32>.size)
        guard CMIOObjectGetPropertyData(id, &addr, 0, nil, size, &used, &value) == noErr else { return 0 }
        return value
    }

    private static func cmioString(_ id: CMIOObjectID, _ selector: Int) -> String? {
        var addr = cmioAddress(selector)
        var value: Unmanaged<CFString>?
        var used: UInt32 = 0
        let size = UInt32(MemoryLayout<Unmanaged<CFString>?>.size)
        guard CMIOObjectGetPropertyData(id, &addr, 0, nil, size, &used, &value) == noErr,
              let v = value else { return nil }
        return v.takeRetainedValue() as String
    }

    // MARK: Микрофоны (CoreAudio)

    static func microphones() -> [SensorDevice] {
        var addr = AudioObjectPropertyAddress(mSelector: kAudioHardwarePropertyDevices,
                                              mScope: kAudioObjectPropertyScopeGlobal,
                                              mElement: kAudioObjectPropertyElementMain)
        let system = AudioObjectID(kAudioObjectSystemObject)
        var size: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(system, &addr, 0, nil, &size) == noErr, size > 0 else { return [] }
        var ids = [AudioObjectID](repeating: 0, count: Int(size) / MemoryLayout<AudioObjectID>.size)
        guard AudioObjectGetPropertyData(system, &addr, 0, nil, &size, &ids) == noErr else { return [] }
        return ids.filter(hasInput).map { id in
            SensorDevice(kind: .microphone,
                         uid: audioString(id, kAudioDevicePropertyDeviceUID) ?? "\(id)",
                         name: audioString(id, kAudioObjectPropertyName) ?? String(localized: "Микрофон \(id)"),
                         running: audioUInt32(id, kAudioDevicePropertyDeviceIsRunningSomewhere) != 0)
        }
    }

    private static func hasInput(_ id: AudioObjectID) -> Bool {
        var addr = AudioObjectPropertyAddress(mSelector: kAudioDevicePropertyStreams,
                                              mScope: kAudioObjectPropertyScopeInput,
                                              mElement: kAudioObjectPropertyElementMain)
        var size: UInt32 = 0
        return AudioObjectGetPropertyDataSize(id, &addr, 0, nil, &size) == noErr && size > 0
    }

    private static func audioUInt32(_ id: AudioObjectID, _ selector: AudioObjectPropertySelector) -> UInt32 {
        var addr = AudioObjectPropertyAddress(mSelector: selector, mScope: kAudioObjectPropertyScopeGlobal,
                                              mElement: kAudioObjectPropertyElementMain)
        var value: UInt32 = 0
        var size = UInt32(MemoryLayout<UInt32>.size)
        guard AudioObjectGetPropertyData(id, &addr, 0, nil, &size, &value) == noErr else { return 0 }
        return value
    }

    private static func audioString(_ id: AudioObjectID, _ selector: AudioObjectPropertySelector) -> String? {
        var addr = AudioObjectPropertyAddress(mSelector: selector, mScope: kAudioObjectPropertyScopeGlobal,
                                              mElement: kAudioObjectPropertyElementMain)
        var value: Unmanaged<CFString>?
        var size = UInt32(MemoryLayout<Unmanaged<CFString>?>.size)
        guard AudioObjectGetPropertyData(id, &addr, 0, nil, &size, &value) == noErr, let v = value else { return nil }
        return v.takeRetainedValue() as String
    }
}

// MARK: - Журнал включений

struct SensorEvent: Codable, Identifiable, Sendable, Equatable {
    var t: Date
    var kind: SensorKind
    var device: String
    var on: Bool

    var id: String { "\(t.timeIntervalSince1970)|\(kind.rawValue)|\(device)|\(on)" }
}

/// Журнал в ~/Library/Application Support/PrivacyMom/sensors.jsonl — по событию в строке.
struct SensorLog {
    var url: URL = Paths.ownData.appendingPathComponent("sensors.jsonl")
    static let keepDays = 7

    private static let encoder: JSONEncoder = {
        let e = JSONEncoder()
        e.dateEncodingStrategy = .iso8601
        e.outputFormatting = [.sortedKeys]
        return e
    }()

    private static let decoder: JSONDecoder = {
        let d = JSONDecoder()
        d.dateDecodingStrategy = .iso8601
        return d
    }()

    /// События за последние `keepDays` дней (старые строки при этом вычищаются из файла).
    func load(now: Date = Date()) -> [SensorEvent] {
        guard let data = try? Data(contentsOf: url) else { return [] }
        let cutoff = now.addingTimeInterval(-Double(Self.keepDays) * 86_400)
        var all: [SensorEvent] = []
        var dropped = 0
        for line in data.split(separator: UInt8(ascii: "\n")) where !line.isEmpty {
            guard let e = try? Self.decoder.decode(SensorEvent.self, from: Data(line)) else { dropped += 1; continue }
            if e.t >= cutoff { all.append(e) } else { dropped += 1 }
        }
        if dropped > 0 { rewrite(all) }
        return all
    }

    func append(_ e: SensorEvent) {
        guard var line = try? Self.encoder.encode(e) else { return }
        line.append(UInt8(ascii: "\n"))
        try? FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        if let h = try? FileHandle(forWritingTo: url) {
            defer { try? h.close() }
            _ = try? h.seekToEnd()
            try? h.write(contentsOf: line)
        } else {
            try? line.write(to: url, options: .atomic)
        }
    }

    private func rewrite(_ events: [SensorEvent]) {
        var data = Data()
        for e in events {
            if let l = try? Self.encoder.encode(e) { data.append(l); data.append(UInt8(ascii: "\n")) }
        }
        try? data.write(to: url, options: .atomic)
    }
}

/// Сравнивает два опроса и возвращает включения/выключения.
enum SensorDiff {
    static func events(old: [SensorDevice], new: [SensorDevice], at t: Date) -> [SensorEvent] {
        let before = Dictionary(old.map { ($0.id, $0.running) }, uniquingKeysWith: { a, _ in a })
        var out: [SensorEvent] = []
        for d in new {
            let was = before[d.id] ?? false
            if was != d.running { out.append(SensorEvent(t: t, kind: d.kind, device: d.name, on: d.running)) }
        }
        // Устройство пропало (отключили), когда было включено.
        let now = Set(new.map(\.id))
        for d in old where d.running && !now.contains(d.id) {
            out.append(SensorEvent(t: t, kind: d.kind, device: d.name, on: false))
        }
        return out
    }
}
