import AppKit
import Foundation

// MARK: - Тома

struct VolumeInfo: Identifiable, Sendable {
    enum Kind: String, Sendable {
        case internalDisk = "Встроенный"
        case external = "Внешний"
        case network = "Сетевой"
        case diskImage = "Образ диска"

        var symbol: String {
            switch self {
            case .internalDisk: return "internaldrive.fill"
            case .external: return "externaldrive.fill"
            case .network: return "server.rack"
            case .diskImage: return "opticaldiscdrive.fill"
            }
        }
    }

    enum Health: Sendable {
        case ok, failing, unsupported, unknown
    }

    let url: URL
    var name: String
    var total: Int64
    var available: Int64
    var format: String
    var kind: Kind
    var isRoot: Bool
    var isReadOnly: Bool
    var canEject: Bool
    var isRemovable: Bool
    var device: String?
    var bus: String?
    var health: Health = .unknown
    var solidState: Bool?

    var id: String { url.path }
    var used: Int64 { max(0, total - available) }
    var usedFraction: Double { total > 0 ? Double(used) / Double(total) : 0 }
}

enum Volumes {
    private static let keys: [URLResourceKey] = [
        .volumeLocalizedNameKey, .volumeTotalCapacityKey, .volumeAvailableCapacityKey,
        .volumeAvailableCapacityForImportantUsageKey, .volumeLocalizedFormatDescriptionKey,
        .volumeIsInternalKey, .volumeIsRemovableKey, .volumeIsEjectableKey, .volumeIsLocalKey,
        .volumeIsRootFileSystemKey, .volumeIsReadOnlyKey,
    ]

    /// Все видимые подключённые тома. Сведения о физическом диске — из `diskutil info -plist`
    /// (без прав администратора; для сетевых томов не запрашиваются).
    static func list(withDiskInfo: Bool = true) -> [VolumeInfo] {
        let urls = FileManager.default.mountedVolumeURLs(includingResourceValuesForKeys: keys,
                                                         options: [.skipHiddenVolumes]) ?? []
        var out: [VolumeInfo] = []
        for url in urls {
            guard let v = try? url.resourceValues(forKeys: Set(keys)) else { continue }
            let isRoot = v.volumeIsRootFileSystem == true || url.path == "/"
            let isLocal = v.volumeIsLocal ?? true
            let isInternal = v.volumeIsInternal ?? false
            var info = VolumeInfo(
                url: url,
                name: v.volumeLocalizedName ?? url.lastPathComponent,
                total: Int64(v.volumeTotalCapacity ?? 0),
                available: isRoot ? (v.volumeAvailableCapacityForImportantUsage ?? Int64(v.volumeAvailableCapacity ?? 0))
                    : Int64(v.volumeAvailableCapacity ?? 0),
                format: v.volumeLocalizedFormatDescription ?? "—",
                kind: !isLocal ? .network : (isInternal ? .internalDisk : .external),
                isRoot: isRoot,
                isReadOnly: v.volumeIsReadOnly ?? false,
                canEject: !isRoot && (v.volumeIsEjectable == true || v.volumeIsRemovable == true || !isLocal || !isInternal),
                isRemovable: v.volumeIsRemovable ?? false)
            if withDiskInfo && isLocal, let d = diskutilInfo(url.path) { apply(d, to: &info) }
            out.append(info)
        }
        // Загрузочный — первым, дальше по имени.
        return out.sorted { $0.isRoot != $1.isRoot ? $0.isRoot : $0.name.localizedStandardCompare($1.name) == .orderedAscending }
    }

    static func diskutilInfo(_ path: String) -> [String: Any]? {
        let r = Shell.run("/usr/sbin/diskutil", ["info", "-plist", path])
        guard r.ok else { return nil }
        return (try? PropertyListSerialization.propertyList(from: r.output, format: nil)) as? [String: Any]
    }

    static func apply(_ d: [String: Any], to info: inout VolumeInfo) {
        info.device = d["DeviceIdentifier"] as? String
        info.bus = d["BusProtocol"] as? String
        info.solidState = d["SolidState"] as? Bool
        let virtual = (d["VirtualOrPhysical"] as? String) == "Virtual"
        if info.bus == "Disk Image" || (virtual && !(d["Internal"] as? Bool ?? false) && info.kind == .external) {
            info.kind = .diskImage
        }
        switch d["SMARTStatus"] as? String {
        case "Verified": info.health = .ok
        case "Failing", "About to Fail": info.health = .failing
        case "Not Supported": info.health = .unsupported
        default: info.health = info.kind == .diskImage ? .unsupported : .unknown
        }
    }

    /// Отключить том (и извлечь носитель, если это возможно).
    static func eject(_ url: URL) throws {
        try NSWorkspace.shared.unmountAndEjectDevice(at: url)
    }
}

// MARK: - Загрузочный диск

struct DiskInfo: Sendable {
    var total: Int64 = 0
    var available: Int64 = 0
    var used: Int64 { max(0, total - available) }

    static func current() -> DiskInfo {
        let keys: Set<URLResourceKey> = [.volumeTotalCapacityKey, .volumeAvailableCapacityForImportantUsageKey]
        guard let v = try? URL(fileURLWithPath: "/").resourceValues(forKeys: keys) else { return DiskInfo() }
        return DiskInfo(total: Int64(v.volumeTotalCapacity ?? 0),
                        available: v.volumeAvailableCapacityForImportantUsage ?? 0)
    }
}
