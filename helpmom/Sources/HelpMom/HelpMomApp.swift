import AppKit
import SwiftUI

@main
enum Main {
    static func main() {
        // `HelpMom --selftest` — проверка отчёта, разбора имён сбоев, ссылок и хранения во временной папке.
        if CommandLine.arguments.contains("--selftest") { exit(SelfTest.run() ? 0 : 1) }
        // `HelpMom --report` — собрать отчёт на этом Mac и напечатать его (ничего не сохраняется).
        if CommandLine.arguments.contains("--report") {
            let sem = DispatchSemaphore(value: 0)
            Task.detached {
                let r = await Collector.collect()
                print(r.text(includeSerial: false))
                sem.signal()
            }
            sem.wait()
            return
        }
        HelpMomApp.main()
    }
}

struct HelpMomApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var delegate
    @State private var state = AppState(demo: CommandLine.arguments.contains("--demo"))

    var body: some Scene {
        Window("HelpMom", id: "main") {
            ContentView()
                .environment(state)
                .environment(\.locale, L10n.locale)
                .environment(\.layoutDirection, L10n.layoutDirection)
                .frame(minWidth: 900, minHeight: 600)
                .task { LaunchOptions.apply(to: state) }
        }
        .defaultSize(width: 1060, height: 720)
        .commands {
            CommandGroup(after: .sidebar) {
                ForEach(Pane.allCases) { p in
                    Button(p.title) { state.section = p }
                        .keyboardShortcut(KeyEquivalent(Character("\(p.rawValue + 1)")))
                }
                Divider()
                Button("Обновить отчёт") { state.refresh() }.keyboardShortcut("r")
                Button("Скопировать отчёт") { state.copyReport() }.keyboardShortcut("c", modifiers: [.command, .shift])
                Divider()
            }
        }
    }
}

final class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.regular)  // и при запуске без .app (swift run)
        NSApp.activate(ignoringOtherApps: true)
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { true }
}

/// `--section 2` — открыть раздел (1…3); `--serial` — с серийным номером; `--edit` — форма нового помощника.
enum LaunchOptions {
    @MainActor static func apply(to state: AppState) {
        let args = CommandLine.arguments
        func value(_ flag: String) -> String? {
            guard let i = args.firstIndex(of: flag), i + 1 < args.count else { return nil }
            return args[i + 1]
        }
        if let n = value("--section").flatMap(Int.init), let p = Pane(rawValue: n - 1) { state.section = p }
        if args.contains("--serial") { state.includeSerial = true }
        if args.contains("--edit") { state.editing = Helper(name: "") }
    }
}
