import AppKit
import Observation
import SwiftUI

enum SidebarSection: String, Hashable, CaseIterable {
    case map, dupes, disks
}

@Observable @MainActor
final class AppState {
    var section: SidebarSection = .map
    var disk = DiskInfo.current()
    var fullDiskAccess = FullDiskAccess.granted
    let map = MapStore()
    let dupes = DupesStore()
    let volumes = VolumesStore()

    func refreshSystem() {
        disk = DiskInfo.current()
        fullDiskAccess = FullDiskAccess.granted
    }

    /// Открыть карту диска для тома или папки и сразу начать сканирование.
    func openMap(_ url: URL) {
        section = .map
        map.target = url
        Task { await map.scan(fullDiskAccess: fullDiskAccess) }
    }
}

// MARK: - Карта диска

@Observable @MainActor
final class MapStore {
    enum Phase: Equatable { case idle, scanning, ready }

    var target: URL = Paths.home
    var phase: Phase = .idle
    var progress = ScanProgress.Snapshot()
    var started = Date()
    var elapsed: TimeInterval = 0
    var root: FSNode?
    var focus: FSNode?
    var selected: FSNode?
    var message: String?
    /// Растёт при каждом изменении дерева (FSNode — не @Observable).
    var revision = 0

    @ObservationIgnored private var scanner: ScanProgress?
    @ObservationIgnored private var cacheKey: (ObjectIdentifier, Int)?
    @ObservationIgnored private var cachedSegments: [SunSegment] = []

    var targetTitle: String {
        if target.path == "/" { return DiskScanner.volumeName("/") ?? "Macintosh HD" }
        if target.path == Paths.home.path { return "Домашняя папка" }
        return target.lastPathComponent
    }

    func scan(fullDiskAccess: Bool) async {
        if phase == .scanning { return }
        phase = .scanning
        message = nil
        progress = .init()
        started = Date()
        let p = ScanProgress()
        scanner = p
        var options = DiskScanner.Options()
        options.fullDiskAccess = fullDiskAccess
        let s = DiskScanner(root: target, progress: p, options: options)
        let ticker = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .milliseconds(120))
                guard let self else { return }
                self.progress = p.snapshot
                self.elapsed = Date().timeIntervalSince(self.started)
            }
        }
        let tree = await withCheckedContinuation { (c: CheckedContinuation<FSNode, Never>) in
            DispatchQueue.global(qos: .userInitiated).async { c.resume(returning: s.run()) }
        }
        ticker.cancel()
        progress = p.snapshot
        elapsed = Date().timeIntervalSince(started)
        scanner = nil
        if p.isCancelled {
            phase = root == nil ? .idle : .ready
            return
        }
        root = tree
        focus = tree
        selected = nil
        revision += 1
        phase = .ready
    }

    func cancel() { scanner?.cancel() }

    func drill(_ node: FSNode) {
        guard node.canDrill else { selected = node; return }
        focus = node
        selected = nil
    }

    func up() {
        guard let f = focus, let p = f.parent else { return }
        focus = p
        selected = f
    }

    /// Прыжок по хлебным крошкам.
    func jump(_ node: FSNode) {
        let old = focus
        focus = node
        selected = old.flatMap { o in o.chain.first { $0.parent === node } }
    }

    func trash(_ node: FSNode) {
        do {
            let size = node.size, parent = node.parent
            let focusInside = focus?.chain.contains { $0 === node } ?? false
            try SizeTree.trash(node)
            if let s = selected, s === node || s.chain.contains(where: { $0 === node }) { selected = nil }
            if focusInside { focus = parent ?? root }
            message = "«\(node.name)» в Корзине, освобождено \(Fmt.bytes(size))"
            revision += 1
        } catch {
            message = "Не удалось перенести «\(node.name)»: \(error.localizedDescription)"
        }
    }

    /// Сегменты солнечной диаграммы для текущего фокуса (кэш до следующего изменения дерева).
    func segments() -> [SunSegment] {
        guard let focus else { return [] }
        let key = (focus.id, revision)
        if let k = cacheKey, k.0 == key.0, k.1 == key.1 { return cachedSegments }
        cachedSegments = Sunburst.layout(focus)
        cacheKey = key
        return cachedSegments
    }
}

// MARK: - Дубликаты

@Observable @MainActor
final class DupesStore {
    enum Phase: Equatable { case idle, scanning, ready }

    static let defaultFolders = ["Downloads", "Documents", "Desktop", "Pictures"].map { Paths.inHome($0) }

    var folders: [URL] = DupesStore.defaultFolders
    var minSize: Int64 = 1_000_000
    var phase: Phase = .idle
    var progress = DupProgress.Snapshot()
    var groups: [DupGroup] = []
    var selected: Set<String> = []
    var warning: String?
    var report: DupSelection.TrashResult?
    var elapsed: TimeInterval = 0

    @ObservationIgnored private var job: DupProgress?

    var totalReclaimable: Int64 { groups.reduce(0) { $0 + $1.reclaimable } }
    var toTrash: [DupFile] { DupSelection.safeToTrash(groups, selected: selected) }
    var selectedSize: Int64 { toTrash.reduce(0) { $0 + $1.size } }

    func scan() async {
        if phase == .scanning { return }
        phase = .scanning
        warning = nil
        report = nil
        let p = DupProgress()
        job = p
        let roots = folders, min = minSize
        let started = Date()
        let ticker = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .milliseconds(120))
                self?.progress = p.snapshot
            }
        }
        let found = await withCheckedContinuation { (c: CheckedContinuation<[DupGroup], Never>) in
            DispatchQueue.global(qos: .userInitiated).async { c.resume(returning: DupFinder.find(roots: roots, minSize: min, progress: p)) }
        }
        ticker.cancel()
        job = nil
        elapsed = Date().timeIntervalSince(started)
        if p.isCancelled { phase = groups.isEmpty ? .idle : .ready; return }
        groups = found
        selected = DupSelection.apply(.keepNewest, to: found)
        phase = .ready
    }

    func cancel() { job?.cancel() }

    func apply(_ rule: DupSelection.Rule) {
        selected = DupSelection.apply(rule, to: groups)
        warning = nil
    }

    func toggle(_ f: DupFile, in g: DupGroup) {
        if selected.contains(f.id) {
            selected.remove(f.id)
            warning = nil
        } else if DupSelection.canSelect(f, in: g, selected: selected) {
            selected.insert(f.id)
            warning = nil
        } else {
            NSSound.beep()
            warning = "Все копии «\(g.name)» отметить нельзя — хотя бы одна должна остаться."
        }
    }

    func trashSelected() async {
        let groups = self.groups, selected = self.selected
        let r = await Task.detached { DupSelection.trash(groups, selected: selected) }.value
        self.groups = DupSelection.removing(r.trashed, from: self.groups)
        self.selected.subtract(r.trashed.map(\.id))
        report = r
    }

    func addFolder() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = true
        panel.prompt = "Добавить"
        guard panel.runModal() == .OK else { return }
        for u in panel.urls where !folders.contains(u) { folders.append(u) }
    }
}

// MARK: - Диски

@Observable @MainActor
final class VolumesStore {
    var volumes: [VolumeInfo] = []
    var loading = false
    var message: String?
    var ejecting: Set<String> = []

    func refresh() async {
        loading = true
        volumes = await Task.detached { Volumes.list() }.value
        loading = false
    }

    func eject(_ v: VolumeInfo) async {
        ejecting.insert(v.id)
        let url = v.url
        let err: String? = await Task.detached {
            do { try Volumes.eject(url); return nil } catch { return error.localizedDescription }
        }.value
        ejecting.remove(v.id)
        message = err.map { "Не удалось извлечь «\(v.name)»: \($0)" } ?? "«\(v.name)» можно отключать."
        await refresh()
    }
}
