import AppKit
import SwiftUI

@main
enum Main {
    static func main() {
        let args = CommandLine.arguments
        // `DiskMom --selftest` — дубликаты и Корзина на временной песочнице.
        if args.contains("--selftest") { SelfTest.run(); return }
        // `DiskMom --scan <папка> [--fm]` — 10 самых больших объектов и время (--fm: сверка с FileManager).
        if let p = CLI.value("--scan") { SelfTest.scan(p, compare: args.contains("--fm")); return }
        // `DiskMom --dupes <папка> [--min байт]` — группы дубликатов, ничего не удаляя.
        if let p = CLI.value("--dupes") { SelfTest.dupes(p, min: CLI.value("--min").flatMap(Int64.init) ?? 1_000_000); return }
        // `DiskMom --volumes` — подключённые тома.
        if args.contains("--volumes") { SelfTest.volumes(); return }
        DiskMomApp.main()
    }
}

enum CLI {
    static func value(_ flag: String) -> String? {
        let args = CommandLine.arguments
        guard let i = args.firstIndex(of: flag), i + 1 < args.count else { return nil }
        return args[i + 1]
    }

    static func values(_ flag: String) -> [String] {
        let args = CommandLine.arguments
        return args.indices.filter { args[$0] == flag && $0 + 1 < args.count }.map { args[$0 + 1] }
    }
}

struct DiskMomApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var delegate
    @State private var state = AppState(demo: CommandLine.arguments.contains("--demo"))

    var body: some Scene {
        Window("DiskMom", id: "main") {
            ContentView()
                .environment(state)
                .environment(\.locale, L10n.locale)
                .environment(\.layoutDirection, L10n.layoutDirection)
                .frame(minWidth: 960, minHeight: 620)
                .task { await LaunchOptions.apply(to: state) }
        }
        .defaultSize(width: 1180, height: 760)
        .commands {
            CommandGroup(after: .sidebar) {
                Button("Карта диска") { state.section = .map }.keyboardShortcut("1")
                Button("Дубликаты") { state.section = .dupes }.keyboardShortcut("2")
                Button("Диски") { state.section = .disks }.keyboardShortcut("3")
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

/// `open DiskMom.app --args --section map --path /Applications --autoscan [--drill 1]`
/// `open DiskMom.app --args --section dupes --folder <папка> [--folder …] [--min 100000] --autoscan`
/// Разделы: map, dupes, disks. Только поиск, без удаления.
enum LaunchOptions {
    @MainActor static func apply(to state: AppState) async {
        if let s = CLI.value("--section").flatMap(SidebarSection.init(rawValue:)) { state.section = s }
        if let p = CLI.value("--path") { state.map.target = URL(fileURLWithPath: (p as NSString).expandingTildeInPath) }
        let folders = CLI.values("--folder")
        if !folders.isEmpty { state.dupes.folders = folders.map { URL(fileURLWithPath: ($0 as NSString).expandingTildeInPath) } }
        if let m = CLI.value("--min").flatMap(Int64.init) { state.dupes.minSize = m }
        if let out = CLI.value("--snapshot") { Snapshot.schedule(to: out) }
        guard CommandLine.arguments.contains("--autoscan") else { return }
        switch state.section {
        case .map:
            await state.map.scan(fullDiskAccess: state.fullDiskAccess)
            for _ in 0..<(CLI.value("--drill").flatMap(Int.init) ?? 0) {
                if let n = state.map.focus?.children.first(where: \.canDrill) { state.map.drill(n) }
            }
        case .dupes: await state.dupes.scan()
        case .disks: break
        }
    }
}

/// `--snapshot <файл.png> [--snapshot-delay 3]` — сохранить картинку своего окна и выйти. Для проверки вёрстки
/// и переводов без доступа к экрану (рисует сам себя, `screencapture` не нужен).
enum Snapshot {
    @MainActor static func schedule(to path: String) {
        let delay = CLI.value("--snapshot-delay").flatMap(Double.init) ?? 3
        DispatchQueue.main.asyncAfter(deadline: .now() + delay) {
            save(to: path)
            NSApp.terminate(nil)
        }
    }

    @MainActor static func save(to path: String) {
        guard let w = NSApp.windows.first(where: { $0.isVisible && $0.contentView != nil }),
              let v = w.contentView?.superview ?? w.contentView,
              let rep = v.bitmapImageRepForCachingDisplay(in: v.bounds) else { return }
        v.cacheDisplay(in: v.bounds, to: rep)
        try? rep.representation(using: .png, properties: [:])?.write(to: URL(fileURLWithPath: path))
    }
}
