import AppKit
import SwiftUI

@main
enum Main {
    static func main() {
        let args = CommandLine.arguments
        // `CleanerMom --scan` — найти мусор и вывести сводку, ничего не удаляя.
        if args.contains("--scan") { SelfTest.scan(); return }
        // `CleanerMom --selftest-clean` — проверка удаления на временной песочнице.
        if args.contains("--selftest-clean") { SelfTest.clean(); return }
        // `CleanerMom --apps` — приложения и найденные следы (без удаления).
        if args.contains("--apps") { SelfTest.apps(); return }
        CleanerMomApp.main()
    }
}

struct CleanerMomApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var delegate
    @State private var state = AppState(demo: CommandLine.arguments.contains("--demo"))

    var body: some Scene {
        Window("CleanerMom", id: "main") {
            ContentView()
                .environment(state)
                .environment(\.locale, L10n.locale)
                .environment(\.layoutDirection, L10n.layoutDirection)
                .frame(minWidth: 940, minHeight: 600)
                .task { await LaunchOptions.apply(to: state) }
        }
        .defaultSize(width: 1120, height: 720)
        .commands {
            CommandGroup(after: .sidebar) {
                Button("Умная очистка") { state.section = .smart }.keyboardShortcut("1")
                Button("Мусор") { state.section = .junk }.keyboardShortcut("2")
                Button("Крупные файлы") { state.section = .large }.keyboardShortcut("3")
                Button("Деинсталлятор") { state.section = .uninstaller }.keyboardShortcut("4")
                Button("Обслуживание") { state.section = .maintenance }.keyboardShortcut("5")
                Divider()
                Button("Сканировать заново") { Task { await state.junk.scan(); state.refreshSystem() } }
                    .keyboardShortcut("r")
                    .disabled(state.junk.phase == .scanning || state.junk.phase == .cleaning)
                Divider()
            }
        }
    }
}

final class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.regular)  // нужно при запуске без .app (swift run)
        NSApp.activate(ignoringOtherApps: true)
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { true }
}

/// `open CleanerMom.app --args --section junk --autoscan` — открыть раздел и сразу запустить поиск
/// (только поиск, без удаления). Разделы: smart, junk, large, uninstaller, maintenance.
enum LaunchOptions {
    @MainActor static func apply(to state: AppState) async {
        let args = CommandLine.arguments
        if let i = args.firstIndex(of: "--section"), i + 1 < args.count,
           let s = SidebarSection(rawValue: args[i + 1]) { state.section = s }
        guard args.contains("--autoscan") else { return }
        switch state.section {
        case .large: await state.large.scan()
        case .uninstaller: break  // список грузится сам при открытии раздела
        default: await state.junk.scan()
        }
    }
}

// MARK: - Проверки из консоли

enum SelfTest {
    static func scan() {
        // Контекст берём здесь, на главном потоке: дальше он заблокирован ожиданием семафора.
        let ctx = MainActor.assumeIsolated { ScanContext.current() }
        let sema = DispatchSemaphore(value: 0)
        Task.detached {
            let res = await JunkScanner.scan(Catalog.all, context: ctx)
            var total: Int64 = 0
            for c in Catalog.all {
                let r = res[c.id] ?? CategoryResult()
                total += r.total
                let denied = r.denied.isEmpty ? "" : String(localized: "  нет доступа: \(r.denied.map(\.lastPathComponent).joined(separator: ", "))")
                print(String(localized: "\(c.title.padding(toLength: 32, withPad: " ", startingAt: 0)) \(Fmt.bytes(r.total).padding(toLength: 10, withPad: " ", startingAt: 0)) \(r.items.count) шт.\(denied)"))
                for i in r.items.prefix(3) {
                    print("    \(Fmt.bytes(i.size).padding(toLength: 10, withPad: " ", startingAt: 0)) \(i.title)\(i.note.map { "  [\($0)]" } ?? "")")
                }
            }
            print(String(localized: "Итого: \(Fmt.bytes(total)); полный доступ к диску: \(FullDiskAccess.granted ? String(localized: "да") : String(localized: "нет"))"))
            sema.signal()
        }
        sema.wait()
    }

    static func apps() {
        let list = AppScanner.installedApps()
        print(String(localized: "Приложений (не Apple): \(list.count)"))
        for a in list.prefix(8) {
            let l = AppScanner.leftovers(for: a, measure: false)  // размеры контейнеров требуют согласия TCC
            print(String(localized: "  \(a.name) [\(a.bundleID)] — следов: \(l.count)"))
            for x in l.prefix(4) { print("      \(x.kind): \(Paths.pretty(x.url))") }
        }
    }

    /// Песочница во временной папке: удаляем внутри корня, проверяем, что объекты вне корня не трогаются.
    static func clean() {
        let fm = FileManager.default
        let sandbox = Paths.tmp.appendingPathComponent("cleanermom-selftest-\(UUID().uuidString)", isDirectory: true)
        let root = sandbox.appendingPathComponent("Caches", isDirectory: true)
        let outside = sandbox.appendingPathComponent("keep.txt")
        try! fm.createDirectory(at: root.appendingPathComponent("app.one/sub"), withIntermediateDirectories: true)
        try! Data(repeating: 1, count: 200_000).write(to: root.appendingPathComponent("app.one/sub/blob"))
        try! Data(repeating: 2, count: 50_000).write(to: root.appendingPathComponent("file.two"))
        try! Data("keep".utf8).write(to: outside)
        defer { try? fm.removeItem(at: sandbox) }

        func item(_ url: URL, root: URL, measure: Bool = true) -> JunkItem {
            JunkItem(url: url, root: root, size: measure ? DiskSize.allocated(url) : 0,
                     title: url.lastPathComponent, subtitle: nil, note: nil)
        }
        let good = [item(root.appendingPathComponent("app.one"), root: root),
                    item(root.appendingPathComponent("file.two"), root: root)]
        let bad = [item(outside, root: root),                       // не внутри корня
                   item(root, root: root),                          // сам корень
                   item(Paths.home.appendingPathComponent("Documents"), root: Paths.home, measure: false)]  // корень = дом
        let r = Cleaner.remove(good.map { ($0, .delete) } + bad.map { ($0, .delete) })

        var ok = true
        func expect(_ cond: Bool, _ msg: String) { print((cond ? "✓ " : "✗ ") + msg); ok = ok && cond }
        expect(!fm.fileExists(atPath: good[0].url.path), String(localized: "папка внутри корня удалена"))
        expect(!fm.fileExists(atPath: good[1].url.path), String(localized: "файл внутри корня удалён"))
        expect(fm.fileExists(atPath: outside.path), String(localized: "файл вне корня не тронут"))
        expect(fm.fileExists(atPath: root.path), String(localized: "сам корень не удалён"))
        expect(fm.fileExists(atPath: Paths.home.appendingPathComponent("Documents").path), String(localized: "~/Documents не тронута"))
        expect(r.failures.count == 3, String(localized: "три небезопасных объекта отклонены (\(r.failures.count))"))
        expect(r.freed > 200_000, String(localized: "освобождено \(Fmt.bytes(r.freed))"))
        print(ok ? String(localized: "Всё в порядке") : String(localized: "ЕСТЬ ОШИБКИ"))
        exit(ok ? 0 : 1)
    }
}
