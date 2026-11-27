import AppKit
import Observation
import SwiftUI

enum SidebarSection: String, Hashable, CaseIterable {
    case permissions, now, browsers, wifi

    var title: String {
        switch self {
        case .permissions: String(localized: "Разрешения")
        case .now: String(localized: "Сейчас")
        case .browsers: String(localized: "Браузеры")
        case .wifi: String(localized: "Сети Wi-Fi")
        }
    }

    var icon: String {
        switch self {
        case .permissions: "hand.raised"
        case .now: "dot.radiowaves.left.and.right"
        case .browsers: "safari"
        case .wifi: "wifi"
        }
    }
}

@Observable @MainActor
final class AppState {
    var section: SidebarSection = .permissions
    var fullDiskAccess: Bool
    let permissions: PermissionsStore
    let sensors: SensorStore
    let browsers: BrowserStore
    let wifi: WifiStore
    private let demo: Bool

    init(demo: Bool = false) {
        self.demo = demo
        fullDiskAccess = !demo && FullDiskAccess.granted
        permissions = PermissionsStore(demo: demo)
        sensors = SensorStore(demo: demo)
        browsers = BrowserStore(demo: demo)
        wifi = WifiStore(demo: demo)
    }

    /// При возвращении в приложение: доступ могли выдать в Настройках — перечитываем.
    func refreshSystem() {
        guard !demo else { return }
        let was = fullDiskAccess
        fullDiskAccess = FullDiskAccess.granted
        if fullDiskAccess != was || permissions.phase == .ready { Task { await permissions.load() } }
        if fullDiskAccess != was { Task { await browsers.load(fullDiskAccess: fullDiskAccess) } }
        else { browsers.refreshRunning() }
    }
}

// MARK: - Разрешения

struct ServiceGroup: Identifiable {
    var service: TCCService
    var entries: [TCCEntry]
    var id: String { service.key }
    var grantedCount: Int { entries.filter(\.auth.isGranted).count }
}

@Observable @MainActor
final class PermissionsStore {
    private let demo: Bool
    init(demo: Bool = false) {
        self.demo = demo
        if demo { phase = .ready }
    }
    enum Phase: Equatable { case idle, loading, ready }

    var phase: Phase = .idle
    var snapshot = TCCSnapshot()
    var focused: String?
    var search = ""
    var showDenied = true
    var message: String?

    var groups: [ServiceGroup] {
        let q = search.trimmingCharacters(in: .whitespaces).lowercased()
        let filtered = snapshot.entries.filter { e in
            (showDenied || e.auth.isGranted) &&
            (q.isEmpty || e.client.lowercased().contains(q) || name(e).lowercased().contains(q) || e.info.title.lowercased().contains(q))
        }
        return Dictionary(grouping: filtered, by: \.service)
            .map { ServiceGroup(service: TCCService.lookup($0.key),
                                entries: $0.value.sorted { name($0).localizedStandardCompare(name($1)) == .orderedAscending }) }
            .sorted { ($0.service.order, $0.service.title) < ($1.service.order, $1.service.title) }
    }

    func name(_ e: TCCEntry) -> String { AppResolver.resolve(e.client, isPath: e.clientIsPath).name }

    func load() async {
        guard !demo else { return }
        if phase != .ready { phase = .loading }
        let s = await Task.detached { TCCReader.snapshot() }.value
        snapshot = s
        phase = .ready
    }

    func reset(_ e: TCCEntry) async {
        guard !demo else { return }
        let r = await Task.detached { TCCReset.reset(e) }.value
        let who = name(e)
        if r.ok {
            message = String(localized: "Разрешение «\(e.info.title)» для \(who) сброшено. При следующей попытке приложение спросит снова.")
        } else {
            message = String(localized: "Не удалось сбросить (\(r.output.isEmpty ? String(localized: "ошибка tccutil") : r.output)). Откройте «Настройки» и выключите \(who) там.")
        }
        await load()
    }
}

// MARK: - Датчики

@Observable @MainActor
final class SensorStore {
    private let demo: Bool
    init(demo: Bool = false) {
        self.demo = demo
        if demo {
            devices = [SensorDevice(kind: .camera, uid: "camera", name: "FaceTime HD Camera", running: false)]
            lastPoll = .now
        }
    }
    var devices: [SensorDevice] = []
    var events: [SensorEvent] = []
    var lastPoll: Date?
    /// Когда устройство включилось (для «работает N мин»).
    var onSince: [String: Date] = [:]
    private var log = SensorLog()
    private var started = false

    var cameras: [SensorDevice] { devices.filter { $0.kind == .camera } }
    var microphones: [SensorDevice] { devices.filter { $0.kind == .microphone } }
    var anyCamera: Bool { cameras.contains(where: \.running) }
    var anyMic: Bool { microphones.contains(where: \.running) }

    func start() {
        guard !demo, !started else { return }
        started = true
        events = log.load()
        Task {
            while !Task.isCancelled {
                await poll()
                try? await Task.sleep(for: .seconds(2))
            }
        }
    }

    func poll() async {
        guard !demo else { return }
        let new = await Task.detached { Sensors.all() }.value
        let now = Date()
        let changes = SensorDiff.events(old: devices, new: new, at: now)
        for e in changes {
            log.append(e)
            events.append(e)
        }
        for d in new {
            if d.running { if onSince[d.id] == nil { onSince[d.id] = now } } else { onSince[d.id] = nil }
        }
        devices = new
        lastPoll = now
    }

    func clearLog() {
        guard !demo else { return }
        try? FileManager.default.removeItem(at: log.url)
        events = []
    }
}

// MARK: - Браузеры

@Observable @MainActor
final class BrowserStore {
    private let demo: Bool
    init(demo: Bool = false) {
        self.demo = demo
        if demo {
            phase = .ready
            reports = BrowserDef.all.filter { $0.id == "safari" || $0.id == "chrome" }
                .map { BrowserReport(def: $0, running: false, profiles: [], targets: [:]) }
        }
    }
    enum Phase: Equatable { case idle, loading, ready }

    var phase: Phase = .idle
    var reports: [BrowserReport] = []
    var busy: String?
    var message: String?

    func load(fullDiskAccess: Bool) async {
        guard !demo else { return }
        if phase != .ready { phase = .loading }
        reports = await Task.detached { BrowserScanner.installedReports(fullDiskAccess: fullDiskAccess) }.value
        phase = .ready
    }

    func refreshRunning() {
        for i in reports.indices { reports[i].running = BrowserScanner.isRunning(reports[i].def) }
    }

    func clean(_ r: BrowserReport, _ kind: BrowserDataKind, fullDiskAccess: Bool) async {
        guard !demo else { return }
        busy = "\(r.id)|\(kind.rawValue)"
        let target = r.target(kind)
        let res = await Task.detached { BrowserScanner.clean(r.def, target) }.value
        busy = nil
        if res.failures.isEmpty {
            message = String(localized: "\(r.def.name): \(kind.title.lowercased()) — \(kind.toTrash ? String(localized: "в Корзине") : String(localized: "удалено")) (\(Fmt.files(res.removed)), \(Fmt.bytes(res.freed))).")
        } else {
            message = String(localized: "\(r.def.name): не всё получилось — ") + res.failures.prefix(3).joined(separator: "; ")
        }
        await load(fullDiskAccess: fullDiskAccess)
    }
}

// MARK: - Wi-Fi

@Observable @MainActor
final class WifiStore {
    private let demo: Bool
    init(demo: Bool = false) {
        self.demo = demo
        if demo {
            phase = .ready
            device = "en0"
            networks = ["Home Wi-Fi", "Guest Wi-Fi"]
            current = networks.first
            currentChecked = true
        }
    }
    enum Phase: Equatable { case idle, loading, ready }

    var phase: Phase = .idle
    var device: String?
    var networks: [String] = []
    var current: String?
    var currentChecked = false
    var selection: Set<String> = []
    var error: String?
    var message: String?
    var forgetting = false

    func load() async {
        guard !demo else { return }
        if phase != .ready { phase = .loading }
        let (dev, list, err) = await Task.detached { () -> (String?, [String], String?) in
            guard let d = WifiNetworks.device() else { return (nil, [], String(localized: "Wi-Fi на этом Mac не найден.")) }
            let r = WifiNetworks.preferred(device: d)
            return (d, r.ok ? WifiNetworks.parsePreferred(r.output) : [], r.ok ? nil : r.output)
        }.value
        device = dev
        networks = list
        error = err
        selection = selection.intersection(list)
        phase = .ready
        if !currentChecked {
            current = await Task.detached { WifiNetworks.current() }.value
            currentChecked = true
        }
    }

    func forgetSelected() async {
        guard !demo, let dev = device else { return }
        forgetting = true
        let names = networks.filter { selection.contains($0) }
        var done: [String] = []
        var failed: [String] = []
        for ssid in names {
            let r = await Task.detached { WifiNetworks.forget(ssid, device: dev) }.value
            if r.ok { done.append(ssid) } else {
                failed.append("«\(ssid)»: \(r.output)")
                if r.output == String(localized: "Отменено") { break }
            }
        }
        forgetting = false
        selection = []
        message = (done.isEmpty ? "" : String(localized: "Забыто: \(done.map { "«\($0)»" }.joined(separator: ", ")). "))
            + (failed.isEmpty ? "" : String(localized: "Не получилось: ") + failed.joined(separator: "; "))
        await load()
    }
}
