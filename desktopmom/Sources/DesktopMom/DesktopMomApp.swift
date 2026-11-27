import AppKit
import SwiftUI

@main
enum Main {
    static func main() {
        // `DesktopMom --selftest` — проверки на временной песочнице: настоящие Рабочий стол и Загрузки не трогаются.
        if CommandLine.arguments.contains("--selftest") { SelfTest.run(); return }
        DesktopMomApp.main()
    }
}

struct DesktopMomApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var delegate
    @State private var state: AppState

    init() {
        // `--demo` — выдуманные файлы в памяти: ни одна папка на диске не читается и не меняется.
        _state = State(initialValue: AppState(demo: CommandLine.arguments.contains("--demo")))
    }

    var body: some Scene {
        Window("DesktopMom", id: "main") {
            ContentView()
                .environment(state)
                .environment(\.locale, L10n.locale)
                .environment(\.layoutDirection, L10n.layoutDirection)
                .frame(minWidth: 960, minHeight: 600)
                .task { LaunchOptions.apply(to: state) }
        }
        .defaultSize(width: 1140, height: 740)
        .commands {
            CommandGroup(after: .sidebar) {
                ForEach(Pane.allCases) { p in
                    Button(p.title) { state.pane = p }.keyboardShortcut(p.key)
                }
                Divider()
                Button("Обновить") { state.refresh() }.keyboardShortcut("r")
                Divider()
            }
        }
    }
}

final class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.regular)  // нужно и при запуске без .app (swift run)
        NSApp.activate(ignoringOtherApps: true)
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { true }
}

/// `--pane downloads` (desktop|downloads|journal), `--filter old` (all|installers|installed|old|large),
/// `--select-suggested` — отметить предложенное в Загрузках, `--organize` — в демо сразу разложить снимки.
enum LaunchOptions {
    @MainActor static func apply(to state: AppState) {
        let args = CommandLine.arguments
        func value(_ flag: String) -> String? {
            guard let i = args.firstIndex(of: flag), i + 1 < args.count else { return nil }
            return args[i + 1]
        }
        if let p = value("--pane").flatMap(Pane.init(rawValue:)) { state.pane = p }
        if let f = value("--filter").flatMap(DLFilter.init(rawValue:)) { state.dlFilter = f }
        state.paneOpened()
        guard state.demo else { return }
        if args.contains("--select-suggested") { state.scanDownloads(); state.selectSuggested() }
        if args.contains("--organize") { state.scanDesktop(); state.organizeScreenshots() }
    }
}
