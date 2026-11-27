import AppKit
import Observation
import SwiftUI

enum SidebarSection: String, Hashable, CaseIterable {
    case smart, junk, large, uninstaller, maintenance
}

@Observable @MainActor
final class AppState {
    var section: SidebarSection = .smart
    var disk: DiskInfo
    var fullDiskAccess: Bool
    let junk: JunkStore
    let large: LargeFilesStore
    let apps: UninstallerStore
    let maintenance: MaintenanceStore
    private let demo: Bool

    init(demo: Bool = false) {
        self.demo = demo
        disk = demo ? DiskInfo(total: 256_000_000_000, available: 38_000_000_000) : .current()
        fullDiskAccess = !demo && FullDiskAccess.granted
        junk = JunkStore(demo: demo)
        large = LargeFilesStore(demo: demo)
        apps = UninstallerStore(demo: demo)
        maintenance = MaintenanceStore(demo: demo)
    }

    func refreshSystem() {
        guard !demo else { return }
        disk = DiskInfo.current()
        fullDiskAccess = FullDiskAccess.granted
    }
}

// MARK: - Мусор

@Observable @MainActor
final class JunkStore {
    private let demo: Bool
    init(demo: Bool = false) { self.demo = demo }
    enum Phase: Equatable { case idle, scanning, ready, cleaning, done }

    let categories = Catalog.all
    var phase: Phase = .idle
    var results: [String: CategoryResult] = [:]
    var selected: Set<String> = []
    var report: CleanReport?
    var cleanedCount = 0
    var cleaningTotal = 0
    var focusedCategory: String?

    var found: [JunkCategory] { categories.filter { !(results[$0.id]?.items.isEmpty ?? true) } }
    var denied: [URL] { categories.flatMap { results[$0.id]?.denied ?? [] } }
    var totalFound: Int64 { results.values.reduce(0) { $0 + $1.total } }
    var totalSelected: Int64 { allItems.filter { selected.contains($0.id) }.reduce(0) { $0 + $1.size } }
    var selectedCount: Int { allItems.filter { selected.contains($0.id) }.count }
    private var allItems: [JunkItem] { results.values.flatMap(\.items) }

    /// Корзина закрыта системой (нет полного доступа к диску) — предлагаем очистить её через Finder.
    var trashDenied: Bool { results["trash"]?.denied.isEmpty == false }
    var finderTrashMessage: String?

    func emptyTrashViaFinder() async {
        guard !demo else { return }
        let r = await Task.detached { Shell.finderEmptyTrash() }.value
        finderTrashMessage = r.ok ? String(localized: "Корзина очищена.") : String(localized: "Не получилось: \(r.output)")
    }

    func items(_ c: JunkCategory) -> [JunkItem] { results[c.id]?.items ?? [] }
    func total(_ c: JunkCategory) -> Int64 { results[c.id]?.total ?? 0 }
    func selectedSize(_ c: JunkCategory) -> Int64 {
        items(c).filter { selected.contains($0.id) }.reduce(0) { $0 + $1.size }
    }

    /// true — отмечено всё, false — ничего, nil — частично.
    func state(_ c: JunkCategory) -> Bool? {
        let ids = items(c).map(\.id)
        let n = ids.filter { selected.contains($0) }.count
        return n == 0 ? false : (n == ids.count ? true : nil)
    }

    /// Включение категории отмечает всё, кроме помеченного (запущенные приложения) — их только вручную.
    func toggle(_ c: JunkCategory) {
        let its = items(c)
        let safe = its.filter(\.preselected).map(\.id)
        if its.contains(where: { selected.contains($0.id) }) {
            selected.subtract(its.map(\.id))
        } else {
            selected.formUnion(safe.isEmpty ? its.map(\.id) : safe)
        }
    }

    func toggle(_ item: JunkItem) {
        if selected.contains(item.id) { selected.remove(item.id) } else { selected.insert(item.id) }
    }

    func scan() async {
        guard !demo else { return }
        phase = .scanning
        report = nil
        let ctx = ScanContext.current()
        let cats = categories
        results = await Task.detached(priority: .userInitiated) {
            await JunkScanner.scan(cats, context: ctx)
        }.value
        selected = []
        for c in categories where c.defaultOn {
            selected.formUnion(items(c).filter(\.preselected).map(\.id))
        }
        if focusedCategory == nil || found.first(where: { $0.id == focusedCategory }) == nil {
            focusedCategory = found.first?.id
        }
        phase = .ready
    }

    func clean() async {
        guard !demo else { return }
        var batch: [(item: JunkItem, mode: RemovalMode)] = []
        for c in categories {
            for item in items(c) where selected.contains(item.id) { batch.append((item, c.mode)) }
        }
        guard !batch.isEmpty else { return }
        phase = .cleaning
        cleanedCount = 0
        cleaningTotal = batch.count
        let r = await Task.detached(priority: .userInitiated) {
            Cleaner.remove(batch) { n in Task { @MainActor in self.cleanedCount = n } }
        }.value
        let removed = Set(r.removed)
        for (id, var res) in results {
            res.items.removeAll { removed.contains($0.id) }
            results[id] = res
        }
        selected.subtract(removed)
        report = r
        phase = .done
    }

    /// Что уйдёт в Корзину, а что удалится сразу — для текста подтверждения.
    var selectionSummary: (delete: Int, trash: Int) {
        var d = 0, t = 0
        for c in categories {
            let n = items(c).filter { selected.contains($0.id) }.count
            if c.mode == .delete { d += n } else { t += n }
        }
        return (d, t)
    }
}

// MARK: - Крупные файлы

@Observable @MainActor
final class LargeFilesStore {
    private let demo: Bool
    init(demo: Bool = false) { self.demo = demo }
    enum Age: String, CaseIterable, Identifiable {
        case any, halfYear, year
        var title: String {
            switch self {
            case .any: String(localized: "Любые")
            case .halfYear: String(localized: "Не менялись полгода")
            case .year: String(localized: "Не менялись больше года")
            }
        }
        var id: String { rawValue }
        var cutoff: Date? {
            switch self {
            case .any: nil
            case .halfYear: Date().addingTimeInterval(-182 * 86_400)
            case .year: Date().addingTimeInterval(-365 * 86_400)
            }
        }
    }

    var files: [LargeFile] = []
    var scanning = false
    var scanned = false
    var seen = 0
    var minSize: Int64 = 100_000_000
    var age: Age = .any
    var search = ""
    var selected: Set<String> = []
    var sortOrder = [KeyPathComparator(\LargeFile.size, order: .reverse)]
    var lastReport: LargeFileScanner.TrashReport?

    var visible: [LargeFile] {
        let cutoff = age.cutoff
        let q = search.trimmingCharacters(in: .whitespaces)
        return files.filter { f in
            f.size >= minSize
                && (cutoff == nil || (f.modified ?? .distantPast) < cutoff!)
                && (q.isEmpty || f.url.path.localizedCaseInsensitiveContains(q))
        }.sorted(using: sortOrder)
    }

    var selectedFiles: [LargeFile] { files.filter { selected.contains($0.id) } }

    func scan() async {
        guard !demo else { return }
        scanning = true
        seen = 0
        let r = await Task.detached(priority: .userInitiated) {
            LargeFileScanner.scan { n in Task { @MainActor in self.seen = n } }
        }.value
        files = r
        selected = []
        scanning = false
        scanned = true
    }

    func trashSelected() async {
        guard !demo else { return }
        let batch = selectedFiles
        let r = await Task.detached { LargeFileScanner.trash(batch) }.value
        let removed = Set(r.removed)
        files.removeAll { removed.contains($0.id) }
        selected.subtract(removed)
        lastReport = r
    }
}

// MARK: - Деинсталлятор

@Observable @MainActor
final class UninstallerStore {
    private let demo: Bool
    init(demo: Bool = false) {
        self.demo = demo
        loaded = demo
    }
    var apps: [AppInfo] = []
    var sizes: [String: Int64] = [:]
    var loading = false
    var loaded = false
    var search = ""
    var sortBySize = true
    var selection: String?
    var leftovers: [Leftover] = []
    var leftoversFor: String?
    var selectedLeftovers: Set<String> = []
    var loadingLeftovers = false
    var working = false
    var message: String?

    var visible: [AppInfo] {
        let q = search.trimmingCharacters(in: .whitespaces)
        let list = q.isEmpty ? apps : apps.filter {
            $0.name.localizedCaseInsensitiveContains(q) || $0.bundleID.localizedCaseInsensitiveContains(q)
        }
        guard sortBySize else { return list }
        return list.sorted { (sizes[$0.id] ?? 0) > (sizes[$1.id] ?? 0) }
    }

    var current: AppInfo? { apps.first { $0.id == selection } }

    func load() async {
        guard !demo else { return }
        loading = true
        apps = await Task.detached { AppScanner.installedApps() }.value
        loading = false
        loaded = true
        let list = apps
        // Размеры считаем по одному в фоне — большие приложения считаются секунды.
        for app in list {
            let s = await Task.detached(priority: .utility) { DiskSize.allocated(app.url) }.value
            sizes[app.id] = s
        }
    }

    func select(_ id: String?) async {
        guard !demo else { return }
        selection = id
        leftovers = []
        selectedLeftovers = []
        leftoversFor = id
        guard let app = current else { return }
        loadingLeftovers = true
        let found = await Task.detached { AppScanner.leftovers(for: app) }.value
        guard leftoversFor == app.id else { return }
        loadingLeftovers = false
        leftovers = found
        selectedLeftovers = Set(found.map(\.id))
    }

    var isRunning: Bool {
        guard let app = current else { return false }
        return !NSRunningApplication.runningApplications(withBundleIdentifier: app.bundleID).isEmpty
    }

    func uninstall() async {
        guard !demo else { return }
        guard let app = current else { return }
        working = true
        defer { working = false }
        // Закрываем приложение, если открыто, и ждём до 10 секунд.
        let running = NSRunningApplication.runningApplications(withBundleIdentifier: app.bundleID)
        running.forEach { $0.terminate() }
        for _ in 0..<20 where running.contains(where: { !$0.isTerminated }) {
            try? await Task.sleep(for: .milliseconds(500))
        }
        if running.contains(where: { !$0.isTerminated }) {
            message = String(localized: "\(app.name) не закрылся. Закройте его вручную и попробуйте снова.")
            return
        }
        let chosen = leftovers.filter { selectedLeftovers.contains($0.id) }
        let size = sizes[app.id] ?? 0
        let r = await Task.detached { AppScanner.uninstall(app, appSize: size, leftovers: chosen) }.value
        if r.failures.isEmpty {
            message = String(localized: "\(app.name) удалён в Корзину, освободится \(Fmt.bytes(r.freed)) после её очистки.")
        } else {
            message = String(localized: "Удалено не всё:\n") + r.failures.joined(separator: "\n")
        }
        if !FileManager.default.fileExists(atPath: app.url.path) {
            apps.removeAll { $0.id == app.id }
            selection = nil
            leftovers = []
        }
    }
}

// MARK: - Обслуживание

@Observable @MainActor
final class MaintenanceStore {
    private let demo: Bool
    init(demo: Bool = false) { self.demo = demo }
    enum Status: Equatable {
        case idle, running
        case done(Date)
        case failed(String)
    }

    var status: [String: Status] = [:]

    func run(_ task: MaintenanceTask) async {
        guard !demo else { return }
        status[task.id] = .running
        let r = await Task.detached(priority: .userInitiated) { task.run() }.value
        status[task.id] = r.ok ? .done(Date()) : .failed(r.output.isEmpty ? String(localized: "Не получилось") : r.output)
    }
}
