import AppKit
import SwiftUI
import Observation

enum Pane: String, CaseIterable, Identifiable {
    case desktop, downloads, journal

    var id: String { rawValue }
    var title: String {
        switch self {
        case .desktop: String(localized: "Рабочий стол")
        case .downloads: String(localized: "Загрузки")
        case .journal: String(localized: "Журнал")
        }
    }
    var icon: String {
        switch self {
        case .desktop: "menubar.dock.rectangle"
        case .downloads: "arrow.down.circle"
        case .journal: "clock.arrow.circlepath"
        }
    }
    var key: KeyEquivalent { KeyEquivalent(Character("\((Pane.allCases.firstIndex(of: self) ?? 0) + 1)")) }
}

enum DLFilter: String, CaseIterable, Identifiable {
    case all, installers, installed, old, large

    var id: String { rawValue }
    var title: String {
        switch self {
        case .all: String(localized: "Всё")
        case .installers: String(localized: "Установщики")
        case .installed: String(localized: "Уже установлено")
        case .old: String(localized: "Давно не открывали")
        case .large: String(localized: "Крупные")
        }
    }
    var short: String {
        switch self {
        case .all: String(localized: "Всё")
        case .installers: String(localized: "Установщики")
        case .installed: String(localized: "Установлено")
        case .old: String(localized: "Давно")
        case .large: String(localized: "Крупные")
        }
    }
}

struct Banner: Equatable {
    var text: String
    var isError = false
    var showJournal = false
}

@MainActor @Observable
final class AppState {
    let demo: Bool
    let roots: Roots
    var pane: Pane = .desktop
    var banner: Banner?

    // Рабочий стол
    var desktop: [Entry] = []
    var desktopScanned = false
    var desktopDenied = false
    var desktopBusy = false
    var tidyGroups: Set<DeskGroup> = []

    // Загрузки
    var downloads: [Entry] = []
    var downloadsScanned = false
    var downloadsDenied = false
    var downloadsBusy = false
    var dlFilter: DLFilter = .all
    var dlSelected: Set<String> = []

    // Журнал
    let journal: Journal
    private(set) var journalVersion = 0  // журнал — не @Observable: дёргаем это поле после изменений

    // Настройки
    var screenshotsBase: URL {
        didSet { if !demo { UserDefaults.standard.set(screenshotsBase.path, forKey: "screenshotsBase") } }
    }
    var oldDays: Int {
        didSet { if !demo { UserDefaults.standard.set(oldDays, forKey: "oldDays") } }
    }
    /// Куда сейчас сохраняются новые снимки экрана; nil — на Рабочий стол.
    var captureLocation: String?

    init(demo: Bool) {
        self.demo = demo
        if demo {
            roots = Roots(home: URL(fileURLWithPath: "/Users/mama"),
                          desktop: URL(fileURLWithPath: "/Users/mama/Desktop"),
                          downloads: URL(fileURLWithPath: "/Users/mama/Downloads"))
            journal = Journal(url: nil)
            screenshotsBase = roots.defaultScreenshots
            oldDays = 90
            captureLocation = nil
        } else {
            roots = .real
            journal = Journal(url: roots.appSupport.appendingPathComponent("log.json"))
            let d = UserDefaults.standard
            screenshotsBase = d.string(forKey: "screenshotsBase").map { URL(fileURLWithPath: $0, isDirectory: true) }
                ?? roots.defaultScreenshots
            let days = d.integer(forKey: "oldDays")
            oldDays = [30, 90, 180, 365].contains(days) ? days : 90
            captureLocation = ScreenshotLocation.current()
        }
    }

    func pretty(_ url: URL) -> String { Paths.pretty(url, home: roots.home) }
    func pretty(_ path: String) -> String { pretty(URL(fileURLWithPath: path)) }

    // MARK: Открытие разделов

    /// Сканируем только открытый раздел и только когда его открыли.
    func paneOpened() {
        switch pane {
        case .desktop: if !desktopScanned && !desktopBusy { scanDesktop() }
        case .downloads: if !downloadsScanned && !downloadsBusy { scanDownloads() }
        case .journal: break
        }
    }

    func refresh() {
        switch pane {
        case .desktop: scanDesktop()
        case .downloads: scanDownloads()
        case .journal: journalVersion += 1
        }
        if !demo { captureLocation = ScreenshotLocation.current() }
    }

    func scanDesktop() {
        if demo {
            if !desktopScanned { desktop = Demo.desktop(roots) }
            desktopScanned = true
            return
        }
        desktopBusy = true
        let root = roots.desktop
        Task {
            let r = await Task.detached { Result { try Scanner.scan(root) } }.value
            apply(r, to: \.desktop, denied: \.desktopDenied)
            desktopScanned = true
            desktopBusy = false
        }
    }

    func scanDownloads() {
        if demo {
            if !downloadsScanned { downloads = Demo.downloads(roots) }
            downloadsScanned = true
            return
        }
        downloadsBusy = true
        let root = roots.downloads, home = roots.home
        Task {
            let r = await Task.detached {
                Result { try Scanner.scan(root, installed: Installed.list(in: Installed.standardDirs(home: home))) }
            }.value
            apply(r, to: \.downloads, denied: \.downloadsDenied)
            dlSelected.formIntersection(downloads.map(\.id))
            downloadsScanned = true
            downloadsBusy = false
        }
    }

    private func apply(_ r: Result<[Entry], Error>, to list: ReferenceWritableKeyPath<AppState, [Entry]>,
                       denied: ReferenceWritableKeyPath<AppState, Bool>) {
        switch r {
        case .success(let items):
            self[keyPath: list] = items
            self[keyPath: denied] = false
        case .failure(let e):
            self[keyPath: list] = []
            if (e as? ScanError) == .denied { self[keyPath: denied] = true } else {
                banner = Banner(text: String(localized: "Не получилось прочитать папку: \(e.localizedDescription)"), isError: true)
            }
        }
    }

    static func openFilesAndFoldersSettings() {
        NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_FilesAndFolders")!)
    }

    // MARK: Рабочий стол

    func entries(_ g: DeskGroup) -> [Entry] { desktop.filter { $0.group == g } }
    var screenshots: [Entry] { entries(.screenshots).sorted { $0.shotDate > $1.shotDate } }

    /// Сколько снимков уедет в какую папку месяца (свежие — сверху).
    var screenshotPlan: [(month: String, count: Int)] {
        var counts: [String: Int] = [:]
        for e in screenshots { counts[Organizer.monthFolder(for: e.shotDate), default: 0] += 1 }
        return counts.sorted { $0.key > $1.key }.map { ($0.key, $0.value) }
    }

    func organizeScreenshots() {
        let base = screenshotsBase
        let items = screenshots.map {
            ($0.url, demo ? base.appendingPathComponent(Organizer.monthFolder(for: $0.shotDate), isDirectory: true)
                          : Organizer.monthDir(in: base, for: $0.shotDate))
        }
        let place = pretty(base)
        runMoves(items) { n in String(localized: "Переложено \(n) снимков экрана в «\(place)». Вернуть можно в журнале.") }
    }

    var tidyCandidates: [Entry] {
        desktop.filter { $0.group != .screenshots && tidyGroups.contains($0.group) }
    }

    func tidyOthers() {
        let inbox = roots.inbox
        let items = tidyCandidates.map {
            ($0.url, Paths.folder(in: inbox, localized: $0.group.folderName, russian: $0.group.russianFolderName))
        }
        let place = pretty(inbox)
        runMoves(items) { n in String(localized: "Переложено \(n) объектов в «\(place)». Вернуть можно в журнале.") }
        tidyGroups = []
    }

    /// `done(n)` — итог «Переложено n … в «…»» с правильной формой числа на языке приложения.
    private func runMoves(_ items: [(URL, URL)], done: @escaping (Int) -> String) {
        guard !items.isEmpty else { return }
        if demo {
            let moved = Set(items.map(\.0))
            let log = items.map { src, dir in
                LogEntry(date: .now, action: .moved, from: src.path, to: dir.appendingPathComponent(src.lastPathComponent).path)
            }
            desktop.removeAll { moved.contains($0.url) }
            journal.add(log)
            journalVersion += 1
            banner = Banner(text: done(items.count), showJournal: true)
            return
        }
        let root = roots.desktop, home = roots.home
        desktopBusy = true
        Task {
            let r = await Task.detached { Organizer.move(items.map { (source: $0.0, destDir: $0.1) }, root: root, home: home) }.value
            record(r, action: .moved)
            var text = done(r.done.count)
            if !r.failures.isEmpty { text += " " + String(localized: "Не получилось: \(r.failures.count) — \(r.failures[0].reason).") }
            banner = Banner(text: text, isError: r.done.isEmpty, showJournal: !r.done.isEmpty)
            scanDesktop()
        }
    }

    private func record(_ r: OpResult, action: LogEntry.Action) {
        journal.add(r.done.map { LogEntry(date: .now, action: action, from: $0.from.path, to: $0.to?.path) })
        journalVersion += 1
    }

    // MARK: Куда сохранять новые снимки экрана

    var captureGoesToBase: Bool {
        guard let c = captureLocation else { return false }
        return Paths.canonical(URL(fileURLWithPath: c)) == Paths.canonical(screenshotsBase)
            || URL(fileURLWithPath: c).standardizedFileURL == screenshotsBase.standardizedFileURL
    }

    var captureTitle: String {
        guard let c = captureLocation else { return String(localized: "на Рабочий стол") }
        return String(localized: "в «\(pretty(c))»")
    }

    func saveNewScreenshotsToBase() {
        if demo { captureLocation = screenshotsBase.path; return }
        if ScreenshotLocation.set(screenshotsBase) {
            captureLocation = ScreenshotLocation.current()
            banner = Banner(text: String(localized: "Новые снимки экрана будут сохраняться в «\(pretty(screenshotsBase))»."))
        } else {
            banner = Banner(text: String(localized: "Не получилось поменять настройку снимков экрана."), isError: true)
        }
    }

    func resetScreenshotLocation() {
        if demo { captureLocation = nil; return }
        _ = ScreenshotLocation.reset()
        captureLocation = ScreenshotLocation.current()
        banner = Banner(text: String(localized: "Новые снимки экрана снова сохраняются на Рабочий стол."))
    }

    func chooseScreenshotsBase() {
        let p = NSOpenPanel()
        p.canChooseDirectories = true
        p.canChooseFiles = false
        p.canCreateDirectories = true
        p.directoryURL = screenshotsBase.deletingLastPathComponent()
        p.prompt = String(localized: "Выбрать")
        p.message = String(localized: "Куда складывать снимки экрана (внутри будут папки по месяцам)")
        guard p.runModal() == .OK, let url = p.url else { return }
        guard demo || Paths.isStrictlyInside(url, roots.home) else {
            banner = Banner(text: String(localized: "Выберите папку внутри своей домашней папки."), isError: true)
            return
        }
        guard demo || !Paths.isStrictlyInside(url, roots.desktop) && Paths.canonical(url) != Paths.canonical(roots.desktop) else {
            banner = Banner(text: String(localized: "Папка для снимков не должна быть на самом Рабочем столе."), isError: true)
            return
        }
        screenshotsBase = url
    }

    // MARK: Загрузки

    func downloads(_ f: DLFilter) -> [Entry] {
        switch f {
        case .all: downloads
        case .installers: downloads.filter { $0.isInstaller || $0.installedMatch != nil }
        case .installed: downloads.filter { $0.installedMatch != nil }
        case .old: downloads.filter { $0.isOld(days: oldDays) }
        case .large: downloads.filter(\.isLarge)
        }
    }

    var visibleDownloads: [Entry] { downloads(dlFilter) }

    /// Что DesktopMom предлагает убрать: установщики уже установленных приложений и давно не нужные установщики.
    var suggested: [Entry] {
        downloads.filter { $0.installedMatch != nil || ($0.isInstaller && $0.isOld(days: oldDays)) }
    }

    func selectSuggested() { dlSelected.formUnion(suggested.map(\.id)) }

    var selectedDownloads: [Entry] { downloads.filter { dlSelected.contains($0.id) } }
    var selectedSize: Int64 { selectedDownloads.reduce(0) { $0 + $1.size } }

    func trashSelected() {
        let list = selectedDownloads
        guard !list.isEmpty else { return }
        let freed = Fmt.bytes(list.reduce(0) { $0 + $1.size })
        if demo {
            let gone = Set(list.map(\.id))
            journal.add(list.map { LogEntry(date: .now, action: .trashed, from: $0.url.path,
                                            to: roots.home.appendingPathComponent(".Trash/\($0.name)").path) })
            journalVersion += 1
            downloads.removeAll { gone.contains($0.id) }
            dlSelected = []
            banner = Banner(text: String(localized: "В Корзину перенесено \(Fmt.files(list.count)), \(freed). Освободится после очистки Корзины."),
                            showJournal: true)
            return
        }
        let root = roots.downloads
        downloadsBusy = true
        Task {
            let r = await Task.detached { Organizer.trash(list.map(\.url), root: root) }.value
            record(r, action: .trashed)
            var text = String(localized: "В Корзину перенесено \(Fmt.files(r.done.count)). Место освободится после очистки Корзины.")
            if !r.failures.isEmpty { text += " " + String(localized: "Не получилось: \(r.failures.count) — \(r.failures[0].reason).") }
            banner = Banner(text: text, isError: r.done.isEmpty, showJournal: !r.done.isEmpty)
            dlSelected = []
            scanDownloads()
        }
    }

    // MARK: Журнал

    var journalEntries: [LogEntry] {
        _ = journalVersion
        return journal.entries.reversed()
    }

    func canUndo(_ e: LogEntry) -> Bool {
        _ = journalVersion
        return demo ? !e.undone : Journal.canUndo(e, home: roots.home)
    }

    func undo(_ e: LogEntry) {
        if demo {
            journal.markUndone(e.id)
            journalVersion += 1
            banner = Banner(text: String(localized: "«\(e.name)» вернулся на место."))
            return
        }
        do {
            try Journal.undo(e, home: roots.home)
            journal.markUndone(e.id)
            journalVersion += 1
            let place = pretty(URL(fileURLWithPath: e.from).deletingLastPathComponent())
            banner = Banner(text: String(localized: "«\(e.name)» вернулся в «\(place)»."))
            desktopScanned = false
            downloadsScanned = false
        } catch {
            banner = Banner(text: String(localized: "Не получилось вернуть «\(e.name)»: \(Organizer.reason(error))."), isError: true)
        }
    }

    func reveal(_ e: LogEntry) {
        let path = e.undone ? e.from : (e.to ?? e.from)
        reveal(URL(fileURLWithPath: path))
    }

    func reveal(_ url: URL) {
        guard !demo else { banner = Banner(text: String(localized: "В демо файлы выдуманные — Finder не откроется.")); return }
        if Paths.exists(url) { NSWorkspace.shared.activateFileViewerSelecting([url]) } else {
            let dir = url.deletingLastPathComponent()
            if Paths.exists(dir) { NSWorkspace.shared.open(dir) }
        }
    }

    func clearJournal() {
        journal.clear()
        journalVersion += 1
    }

    var badgeCount: [Pane: Int] {
        [.desktop: screenshots.count, .downloads: suggested.count, .journal: 0]
    }
}
