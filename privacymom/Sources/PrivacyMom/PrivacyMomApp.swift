import AppKit
import SwiftUI

@main
enum Main {
    static func main() {
        let args = CommandLine.arguments
        // Консольные режимы — только чтение (кроме --selftest, который работает во временной папке).
        if args.contains("--permissions") { CLI.permissions(); return }
        if args.contains("--sensors") { CLI.sensors(); return }
        if args.contains("--browsers") { CLI.browsers(); return }
        if args.contains("--selftest") { SelfTest.run() }
        PrivacyMomApp.main()
    }
}

struct PrivacyMomApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var delegate
    @State private var state = AppState()

    var body: some Scene {
        Window("PrivacyMom", id: "main") {
            ContentView()
                .environment(state)
                .frame(minWidth: 900, minHeight: 580)
                .task { LaunchOptions.apply(to: state) }
        }
        .defaultSize(width: 1080, height: 700)
        .commands {
            CommandGroup(after: .sidebar) {
                ForEach(Array(SidebarSection.allCases.enumerated()), id: \.element) { i, s in
                    Button(s.title) { state.section = s }
                        .keyboardShortcut(KeyEquivalent(Character("\(i + 1)")))
                }
                Divider()
                Button("Обновить") {
                    Task {
                        state.refreshSystem()
                        switch state.section {
                        case .permissions: await state.permissions.load()
                        case .now: await state.sensors.poll()
                        case .browsers: await state.browsers.load(fullDiskAccess: state.fullDiskAccess)
                        case .wifi: await state.wifi.load()
                        }
                    }
                }
                .keyboardShortcut("r")
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

/// `open PrivacyMom.app --args --section browsers` — открыть раздел (permissions, now, browsers, wifi).
enum LaunchOptions {
    @MainActor static func apply(to state: AppState) {
        let args = CommandLine.arguments
        if let i = args.firstIndex(of: "--section"), i + 1 < args.count,
           let s = SidebarSection(rawValue: args[i + 1]) { state.section = s }
    }
}

// MARK: - Консольные проверки (только чтение)

enum CLI {
    static func permissions() {
        let s = TCCReader.snapshot()
        guard s.userReadable || s.systemReadable else {
            print("нет полного доступа к диску — базы разрешений не прочитать")
            for e in s.errors { print("  \(e)") }
            return
        }
        for e in s.errors { print("! \(e)") }
        print("Прочитано: пользовательская база — \(s.userReadable ? "да" : "нет"), системная — \(s.systemReadable ? "да" : "нет"); записей: \(s.entries.count)")
        let groups = Dictionary(grouping: s.entries, by: \.service)
            .sorted { (TCCService.lookup($0.key).order, $0.key) < (TCCService.lookup($1.key).order, $1.key) }
        for (key, list) in groups {
            let allowed = list.filter(\.auth.isGranted).count
            let title = TCCService.lookup(key).title.padding(toLength: 34, withPad: " ", startingAt: 0)
            print("\(title) разрешено: \(allowed), запрещено: \(list.count - allowed)")
        }
        let c = { (k: String) in s.granted("kTCCService" + k) }
        print("Доступ к камере: \(c("Camera")), к микрофону: \(c("Microphone")), запись экрана: \(c("ScreenCapture")), полный доступ к диску: \(c("SystemPolicyAllFiles"))")
    }

    static func sensors() {
        let all = Sensors.all()
        for kind in [SensorKind.camera, .microphone] {
            let list = all.filter { $0.kind == kind }
            print("\(kind.title): \(list.contains(where: \.running) ? "ВКЛЮЧЕНА(О)" : "выключено") — устройств: \(list.count)")
            for d in list { print("    \(d.running ? "●" : "○") \(d.name)") }
        }
    }

    static func browsers() {
        let fda = FullDiskAccess.granted
        let list = BrowserScanner.installedReports(fullDiskAccess: fda)
        print("Полный доступ к диску: \(fda ? "да" : "нет")")
        for r in list {
            let prof = r.profiles.isEmpty ? "" : " · профилей: \(r.profiles.count)"
            print("\(r.def.name)\(r.running ? " (запущен)" : "")\(prof)")
            for k in BrowserDataKind.allCases {
                let t = r.target(k)
                let v = t.unavailable.map { "— \($0.count > 60 ? String($0.prefix(60)) + "…" : $0)" }
                    ?? "\(Fmt.bytes(t.size)) (\(Fmt.count(t.files.count, "файл", "файла", "файлов")))"
                print("    \(k.title.padding(toLength: 8, withPad: " ", startingAt: 0)) \(v)")
            }
        }
    }
}
