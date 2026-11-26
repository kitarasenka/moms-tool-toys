import AppKit
import Observation
import SwiftUI

/// Состояние приложения: история, запись буфера, пауза, быстрая панель.
@MainActor
@Observable
final class AppState {
    let demo: Bool
    let prefs: Preferences
    @ObservationIgnored let history: History
    /// Общий буфер обмена; в демо-режиме — nil (буфер не читается и не меняется).
    @ObservationIgnored private let pasteboard: NSPasteboard?

    var items: [ClipItem] = []
    var filter: ClipFilter = .all
    var query = ""
    var selection: UUID?
    var paused = false
    var pauseUntil: Date?
    var access: PasteAccess = .unsupported
    var lastEvent: String?
    var showSettings = false
    var hotkeyFailed = false

    @ObservationIgnored private var tracker: ChangeTracker?
    @ObservationIgnored private var timer: Timer?
    @ObservationIgnored private var saveTask: Task<Void, Never>?
    @ObservationIgnored private var ticks = 0
    @ObservationIgnored private var started = false
    @ObservationIgnored private let hotKey = HotKey()
    @ObservationIgnored private(set) var panel: QuickPanelController?

    init(demo: Bool) {
        self.demo = demo
        if demo {
            let dir = FileManager.default.temporaryDirectory.appendingPathComponent("clipmom-demo-\(UUID().uuidString)")
            history = History(store: HistoryStore(dir: dir))
            prefs = Preferences(defaults: nil)
            pasteboard = nil
        } else {
            history = History(store: HistoryStore(dir: HistoryStore.defaultDir))
            prefs = Preferences(defaults: .standard)
            pasteboard = .general
        }
        DispatchQueue.main.async { self.start() }
    }

    var store: HistoryStore { history.store }
    var isRecording: Bool { !paused && pauseUntil == nil }

    var visibleItems: [ClipItem] {
        let q = query.trimmingCharacters(in: .whitespaces)
        return items.filter { filter.matches($0) && (q.isEmpty || $0.searchText.localizedCaseInsensitiveContains(q)) }
    }

    var selectedItem: ClipItem? { items.first { $0.id == selection } }

    func count(_ f: ClipFilter) -> Int { items.filter(f.matches).count }

    // MARK: Запуск

    func start() {
        guard !started else { return }
        started = true
        history.limits = prefs.limits
        if demo {
            DemoData.fill(history)
            access = .notAsked
        } else {
            try? history.store.prepare()
            history.load()
            history.trim()
        }
        sync()
        if let pb = pasteboard {
            // Запоминаем текущий changeCount: то, что лежало в буфере до запуска, не читаем.
            tracker = ChangeTracker(current: pb.changeCount)
            refreshAccess()
            let t = Timer(timeInterval: 0.5, repeats: true) { [weak self] _ in
                MainActor.assumeIsolated { self?.tick() }
            }
            RunLoop.main.add(t, forMode: .common)
            timer = t
        }
        panel = QuickPanelController(state: self)
        HotKey.onPress = { [weak self] in self?.panel?.toggle() }
        if prefs.hotkeyEnabled { setHotkey(true) }
    }

    func refreshAccess() {
        guard let pb = pasteboard else { return }
        access = PasteAccess.of(pb)  // свойство, а не чтение содержимого — запроса не вызывает
    }

    /// Каждые 0,5 с: сравниваем только `changeCount`; содержимое читаем лишь после смены.
    private func tick() {
        guard let pb = pasteboard, var tr = tracker else { return }
        ticks += 1
        if let until = pauseUntil, until <= .now {
            pauseUntil = nil
            lastEvent = "Запись снова включена"
        }
        if ticks % 10 == 0 { refreshAccess() }
        if ticks % 7200 == 0 { applyLimits() }  // раз в час — сроки хранения

        let change = tr.check(pb.changeCount)
        tracker = tr
        guard change == .external else { return }
        guard isRecording else { lastEvent = "Не записано: пауза"; return }

        let front = NSWorkspace.shared.frontmostApplication
        let source = SourceApp(bundleID: front?.bundleIdentifier, name: front?.localizedName)
        if let ex = prefs.isExcluded(source.bundleID) {
            lastEvent = "Не записано: скопировано в «\(ex.name)»"
            return
        }
        guard access.canAutoRead else {
            lastEvent = access == .denied ? "Не записано: доступ к буферу запрещён" : "Не записано: macOS спрашивает доступ"
            return
        }
        // Метки «пароль/временное» видны по списку типов — до чтения содержимого.
        if let reason = PasteboardReader.skipReason(types: pb.types ?? []) {
            lastEvent = "Не записано: \(reason)"
            return
        }
        let result = PasteboardReader.read(pb)
        refreshAccess()
        switch result {
        case .captured(let c):
            do {
                let item = try history.ingest(c, source: source)
                lastEvent = "Записано: \(item.title.prefix(40))"
                sync()
                scheduleSave()
            } catch {
                lastEvent = "Ошибка записи: \(error.localizedDescription)"
            }
        case .skipped(let reason):
            lastEvent = "Не записано: \(reason)"
        case .nothing:
            break
        }
    }

    // MARK: Действия

    func copy(_ item: ClipItem, paste: Bool = false) {
        if let pb = pasteboard {
            let cc = PasteboardWriter.write(item, to: pb, store: history.store)
            tracker?.markOwnWrite(cc)
            lastEvent = "Скопировано: \(item.title.prefix(40))"
        } else {
            lastEvent = "Демо: буфер обмена не тронут"
        }
        history.touch(item.id)
        sync()
        scheduleSave()
        if paste && prefs.autoPaste && AutoPaste.trusted && !demo {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.15) { AutoPaste.pressCommandV() }
        }
    }

    func togglePin(_ item: ClipItem) {
        history.setPinned(item.id, !item.pinned)
        sync()
        scheduleSave()
    }

    func delete(_ item: ClipItem) {
        if let i = visibleItems.firstIndex(where: { $0.id == item.id }), selection == item.id {
            let list = visibleItems
            selection = i + 1 < list.count ? list[i + 1].id : (i > 0 ? list[i - 1].id : nil)
        }
        history.remove(item.id)
        sync()
        scheduleSave()
    }

    func clear(keepPinned: Bool) {
        history.clear(keepPinned: keepPinned)
        sync()
        scheduleSave()
        lastEvent = keepPinned ? "История очищена (закреплённые остались)" : "История очищена"
    }

    func togglePause() {
        if isRecording { paused = true } else { paused = false; pauseUntil = nil }
    }

    func pauseFiveMinutes() {
        paused = false
        pauseUntil = Date.now.addingTimeInterval(5 * 60)
    }

    func applyLimits() {
        history.limits = prefs.limits
        if !history.trim().isEmpty {
            sync()
            scheduleSave()
        }
    }

    func setHotkey(_ on: Bool) {
        prefs.hotkeyEnabled = on
        if on { hotkeyFailed = !hotKey.register() } else { hotKey.unregister(); hotkeyFailed = false }
    }

    func setAutoPaste(_ on: Bool) {
        prefs.autoPaste = on
        if on && !AutoPaste.trusted { AutoPaste.requestTrust() }
    }

    // MARK: Служебное

    private func sync() {
        items = history.items
        if let s = selection, !items.contains(where: { $0.id == s }) { selection = nil }
    }

    private func scheduleSave() {
        saveTask?.cancel()
        saveTask = Task { [history] in
            try? await Task.sleep(for: .milliseconds(400))
            guard !Task.isCancelled else { return }
            try? history.save()
        }
    }

    func flush() {
        saveTask?.cancel()
        try? history.save()
        if demo { try? FileManager.default.removeItem(at: history.store.dir) }
    }
}
