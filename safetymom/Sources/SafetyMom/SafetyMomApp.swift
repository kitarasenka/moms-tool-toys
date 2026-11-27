import AppKit
import SwiftUI

@main
enum Main {
    static func main() {
        let args = CommandLine.arguments
        // `SafetyMom --selftest` — разбор ответов системы и браузерные профили на временных файлах.
        if args.contains("--selftest") { SelfTest.run() }
        // `SafetyMom --checks` — те же проверки в Терминале (только чтение).
        if args.contains("--checks") { CLI.checks(); return }
        SafetyMomApp.main()
    }
}

struct SafetyMomApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var delegate
    @State private var state = AppState(demo: CommandLine.arguments.contains("--demo"))

    var body: some Scene {
        Window("SafetyMom", id: "main") {
            ContentView()
                .environment(state)
                .environment(\.locale, L10n.locale)
                .environment(\.layoutDirection, L10n.layoutDirection)
                .frame(minWidth: 900, minHeight: 580)
                .task { LaunchOptions.apply(to: state) }
        }
        .defaultSize(width: 1060, height: 720)
        .commands {
            CommandGroup(after: .sidebar) {
                ForEach(Array(SidebarSection.allCases.enumerated()), id: \.element) { i, s in
                    Button(s.title) { state.section = s }
                        .keyboardShortcut(KeyEquivalent(Character("\(i + 1)")))
                }
                Divider()
                Button("Проверить снова") { state.refreshAll() }.keyboardShortcut("r")
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

/// `open SafetyMom.app --args --section browsers --tab extensions` — открыть раздел (checks|browsers|network)
/// и вкладку браузеров (notifications|extensions).
enum LaunchOptions {
    @MainActor static func apply(to state: AppState) {
        let args = CommandLine.arguments
        func value(_ flag: String) -> String? {
            guard let i = args.firstIndex(of: flag), i + 1 < args.count else { return nil }
            return args[i + 1]
        }
        if let s = value("--section").flatMap(SidebarSection.init(rawValue:)) { state.section = s }
        if let t = value("--tab").flatMap(BrowserTab.init(rawValue:)) { state.browserTab = t }
    }
}

enum CLI {
    static func checks() {
        let sem = DispatchSemaphore(value: 0)
        Task.detached {
            let list = await SystemChecks.runAll()
            for c in list {
                let mark = ["✓", "?", "!", "✗"][c.level.rawValue]
                print("\(mark) \(c.title): \(c.status)")
            }
            let n = NetworkScanner.scan()
            print(String(localized: "Прокси: \(n.proxies.isEmpty ? String(localized: "нет") : n.proxies.map { "\($0.kind) \($0.address)" }.joined(separator: ", "))"))
            print("DNS: \(n.dns.map { "\($0.address) [\($0.level)]" }.joined(separator: ", "))")
            print(String(localized: "hosts: \(n.hosts.count) нестандартных строк; профили: \(n.profiles.count); MDM: \(n.mdm.map { $0 ? String(localized: "да") : String(localized: "нет") } ?? "?")"))
            for b in BrowserScanner.reports(fullDiskAccess: FullDiskAccess.granted) {
                print(String(localized: "\(b.def.name): профилей \(b.profiles.count), расширений \(b.extensions.count), уведомления разрешены \(b.notifications.count) ")
                      + b.notifications.map { "\($0.host)[\($0.level)]" }.joined(separator: " "))
                for e in b.extensions where e.level != .ok {
                    print("   \(e.level == .danger ? "✗" : "!") \(e.name) (\(e.profile)): \(e.flags.map(\.title).joined(separator: ", "))")
                }
            }
            sem.signal()
        }
        sem.wait()
    }
}
