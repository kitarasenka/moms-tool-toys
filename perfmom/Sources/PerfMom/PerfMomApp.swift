import AppKit
import SwiftUI

@main
enum Main {
    static func main() {
        // `PerfMom --selftest` — снять два замера и вывести сводку в консоль (проверка без UI).
        if CommandLine.arguments.contains("--selftest-launchd") {
            SelfTest.launchd()
            return
        }
        if CommandLine.arguments.contains("--selftest") {
            SelfTest.run()
            return
        }
        PerfMomApp.main()
    }
}

struct PerfMomApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var delegate
    @State private var state = AppState()

    var body: some Scene {
        Window("PerfMom", id: "main") {
            ContentView()
                .environment(state)
                .frame(minWidth: 1000, minHeight: 620)
                .task {
                    LaunchOptions.apply(to: state)
                    state.monitor.start()
                }
        }
        .defaultSize(width: 1380, height: 840)
        .commands { AppCommands(state: state) }

        // Значок в строке меню: при закрытом окне PerfMom продолжает работать и записывать историю.
        MenuBarExtra {
            MenuBarContent(state: state)
        } label: {
            Image(systemName: "gauge.with.dots.needle.33percent")
            Text("\(Int(state.monitor.system.cpuTotal.rounded())) %")
        }
    }
}

final class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationDidFinishLaunching(_ notification: Notification) {
        // Нужно, когда бинарник запущен без .app-бандла (swift run).
        NSApp.setActivationPolicy(.regular)
        NSApp.activate(ignoringOtherApps: true)
    }

    /// Окно можно закрыть — запись истории продолжится, PerfMom остаётся в строке меню.
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { false }

    func applicationWillTerminate(_ notification: Notification) {
        HistoryRecorder.shared.flushNow()
        NetworkMonitor.shared.stop()
    }
}

struct AppCommands: Commands {
    let state: AppState

    var body: some Commands {
        CommandGroup(after: .sidebar) {
            Button("Обзор") { state.section = .overview }
                .keyboardShortcut("1", modifiers: .command)
            Button("Процессы") { state.section = .processes }
                .keyboardShortcut("2", modifiers: .command)
            Button("Дерево процессов") { state.section = .tree }
                .keyboardShortcut("3", modifiers: .command)
            Button("История") { state.section = .history }
                .keyboardShortcut("6", modifiers: .command)
            Button("Автозагрузка") { state.section = .startup }
                .keyboardShortcut("4", modifiers: .command)
            Button("Безопасность") { state.section = .security }
                .keyboardShortcut("5", modifiers: .command)
            Divider()
            Button("Показать/скрыть инспектор") { state.showInspector.toggle() }
                .keyboardShortcut("i", modifiers: .command)
            Button("Обновить сейчас") { Task { await state.monitor.refresh() } }
                .keyboardShortcut("r", modifiers: .command)
            Button(state.monitor.paused ? "Возобновить обновление" : "Приостановить обновление") {
                state.monitor.paused.toggle()
            }
            .keyboardShortcut("p", modifiers: [.command, .shift])
            Divider()
        }

        CommandMenu("Процесс") {
            Button("Завершить…") { state.request(.terminate) }
                .keyboardShortcut("q", modifiers: [.command, .option])
            Button("Завершить принудительно…") { state.request(.forceQuit) }
                .keyboardShortcut("q", modifiers: [.command, .option, .shift])
            Button("Завершить вместе с дочерними…") { state.request(.terminate, includeChildren: true) }
            Divider()
            Button("Приостановить") { state.request(.suspend) }
            Button("Продолжить") { state.request(.resume) }
            Divider()
            Button("Показать цепочку запуска") {
                if let pid = state.selectedPID { state.showChain(pid) }
            }
            .keyboardShortcut("l", modifiers: .command)
            Button("Показать в дереве процессов") {
                if let pid = state.selectedPID { state.revealInTree(pid) }
            }
            .keyboardShortcut("t", modifiers: [.command, .shift])
            Button("Показать в Finder") {
                if let pid = state.selectedPID, let r = state.monitor.byPID[pid] { AppState.revealInFinder(r.path) }
            }
            .keyboardShortcut("r", modifiers: [.command, .shift])
        }
    }
}

struct MenuBarContent: View {
    let state: AppState
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        let s = state.monitor.system
        Text("ЦП: \(Fmt.percent(s.cpuTotal)) %")
        Text("Память: \(Fmt.bytes(s.memUsed)) из \(Fmt.bytes(s.memTotal))")
        Text("Сеть: ↓ \(Fmt.rate(s.netIn))  ↑ \(Fmt.rate(s.netOut))")
        Divider()
        Button("Открыть PerfMom") { show(.processes) }
        Button("История за сегодня") { show(.history) }
        Divider()
        Button("Завершить PerfMom") { NSApp.terminate(nil) }
            .keyboardShortcut("q")
    }

    private func show(_ section: SidebarSection) {
        state.section = section
        openWindow(id: "main")
        NSApp.activate(ignoringOtherApps: true)
    }
}

/// Аргументы запуска: `open PerfMom.app --args --pid 123 --tab chain --section tree`
enum LaunchOptions {
    @MainActor
    static func apply(to state: AppState) {
        let args = CommandLine.arguments
        func value(_ flag: String) -> String? {
            guard let i = args.firstIndex(of: flag), i + 1 < args.count else { return nil }
            return args[i + 1]
        }
        if let s = value("--section") {
            switch s {
            case "overview": state.section = .overview
            case "tree": state.section = .tree
            case "startup": state.section = .startup
            case "security": state.section = .security
            case "history": state.section = .history
            default: state.section = .processes
            }
        }
        if let p = value("--pid"), let pid = pid_t(p) { state.select(pid) }
        if value("--startup-tab") == "login" { state.startupTab = .loginItems }
        if let t = value("--tab") {
            let map: [String: InspectorTab] = ["summary": .summary, "chain": .chain, "files": .files,
                                               "modules": .modules, "launch": .launch]
            if let tab = map[t] { state.inspectorTab = tab }
        }
    }
}

enum SelfTest {
    /// Проверяет включение/выключение автозапуска на временном агенте и удаляет его.
    static func launchd() {
        let label = "local.perfmom.selftest"
        let path = NSHomeDirectory() + "/Library/LaunchAgents/\(label).plist"
        let plist: [String: Any] = ["Label": label, "ProgramArguments": ["/bin/sleep", "600"], "RunAtLoad": true]
        let data = try! PropertyListSerialization.data(fromPropertyList: plist, format: .xml, options: 0)
        FileManager.default.createFile(atPath: path, contents: data)
        defer {
            _ = try? LaunchControl.run(["bootout", "gui/\(getuid())/\(label)"])
            try? FileManager.default.removeItem(atPath: path)
            print("Временный агент удалён")
        }
        func state() -> String {
            guard let j = StartupScanner.scanJobs().first(where: { $0.label == label }) else { return "не найден" }
            return "enabled=\(j.enabled) pid=\(j.pid.map(String.init) ?? "-") trigger=«\(j.trigger)» vendor=«\(j.vendor)»"
        }
        let sem = DispatchSemaphore(value: 0)
        Task.detached {
            guard let job = StartupScanner.scanJobs().first(where: { $0.label == label }) else { sem.signal(); return }
            print("Найден:            ", state())
            try? await LaunchControl.setEnabled(job, enabled: true)
            print("После включения:   ", state())
            try? await LaunchControl.setEnabled(job, enabled: false)
            print("После выключения:  ", state())
            try? await LaunchControl.setEnabled(job, enabled: true)
            print("Снова включён:     ", state())
            sem.signal()
        }
        sem.wait()
    }

    static func run() {
        let ps = ProcessSampler(), ss = SystemSampler()
        NetworkMonitor.shared.start()
        _ = ps.sample(); _ = ss.sample()
        Thread.sleep(forTimeInterval: 3.0)
        let procs = ps.sample(), sys = ss.sample()
        let restricted = procs.filter(\.restricted).count
        print("Процессов: \(procs.count), закрытых (через ps): \(restricted)")
        print("ЦП: \(Fmt.percent(sys.cpuTotal))% (user \(Fmt.percent(sys.cpuUser)), sys \(Fmt.percent(sys.cpuSystem))), ядер: \(sys.perCore.count)")
        print("Память: \(Fmt.bytes(sys.memUsed)) / \(Fmt.bytes(sys.memTotal)), app \(Fmt.bytes(sys.memApp)), wired \(Fmt.bytes(sys.memWired)), compressed \(Fmt.bytes(sys.memCompressed))")
        print("Сеть всего: ↓\(Fmt.bytes(sys.netInTotal)) ↑\(Fmt.bytes(sys.netOutTotal)); диск: r \(Fmt.bytes(sys.diskReadTotal)) w \(Fmt.bytes(sys.diskWriteTotal))")
        print("Топ по ЦП:")
        for p in procs.sorted(by: { $0.cpu > $1.cpu }).prefix(6) {
            print("  \(p.pid)\t\(Fmt.percent(p.cpu))%\t\(Fmt.bytes(p.memory))\tthr \(p.threads.map(String.init) ?? "-")\t\(p.restricted ? "[ps]" : "")\t\(p.name)")
        }
        let net = procs.filter { $0.netInTotal != nil }
        print("Сеть по процессам: \(net.isEmpty ? "недоступна" : "\(procs.filter { ($0.netInTotal ?? 0) + ($0.netOutTotal ?? 0) > 0 }.count) процессов с трафиком")")
        for p in procs.sorted(by: { $0.netTotalRate > $1.netTotalRate }).prefix(5) {
            print("  \(p.pid)\t↓\(Fmt.rate(p.netIn)) ↑\(Fmt.rate(p.netOut))\tвсего ↓\(Fmt.bytes(p.netInTotal ?? 0)) ↑\(Fmt.bytes(p.netOutTotal ?? 0))\t\(p.restricted ? "[root]" : "")\t\(p.name)")
        }
        NetworkMonitor.shared.stop()
        let me = getpid()
        var chain: [String] = []
        var cur: pid_t? = me
        let map = Dictionary(procs.map { ($0.pid, $0) }, uniquingKeysWith: { a, _ in a })
        while let c = cur, let r = map[c], chain.count < 20 {
            chain.append("\(r.name)(\(r.pid))")
            cur = r.ppid == r.pid ? nil : r.ppid
        }
        print("Цепочка selftest: " + chain.reversed().joined(separator: " → "))
        let d = DetailsLoader.load(pid: me, path: map[me]?.path ?? "")
        print("Свои детали: args \(d.arguments.count), env \(d.environment.count), files \(d.files.count), modules \(d.modules.count), cwd \(d.cwd ?? "-"), responsible \(d.responsiblePID.map(String.init) ?? "-")")
        print("  модули по типам: " + ModuleKind.allCases.map { k in "\(k.title): \(d.modules.filter { $0.kind == k }.count)" }.joined(separator: ", "))
        if let arg = CommandLine.arguments.last, let p = Int32(arg), let r = map[p] {
            let dd = DetailsLoader.load(pid: p, path: r.path)
            for m in dd.modules.prefix(25) { print("   [\(m.kind.title)] \(m.path)") }
            print("   files: \(dd.files.count), sockets: \(dd.files.filter { $0.kind == .socket }.map(\.title).prefix(5))")
        }
        var annotated = procs
        let analyzer = SecurityAnalyzer()
        for _ in 0..<30 { analyzer.annotate(&annotated) } // бюджет проверки подписей — 40 путей за проход
        let byLevel = Dictionary(grouping: annotated, by: { $0.security.level })
        print("Безопасность: " + RiskLevel.allCases.reversed().map { "\($0.title): \(byLevel[$0]?.count ?? 0)" }.joined(separator: ", "))
        for p in annotated.filter({ $0.security.level >= .info }).sorted(by: { $0.security.score > $1.security.score }).prefix(14) {
            print("  [\(p.security.score)] \(p.name) (\(p.pid)) — \(p.security.signer) — " + p.security.findings.map(\.title).joined(separator: "; "))
        }
        for path in [Bundle.main.executablePath ?? "", "/Applications/Telegram.app/Contents/MacOS/Telegram", "/opt/homebrew/bin/watchman"]
            where FileManager.default.fileExists(atPath: path) {
            let t0 = Date()
            let v = SecurityAnalyzer.deepVerify(path: path)
            print("  глубокая проверка \((path as NSString).lastPathComponent): \(v.message) (\(String(format: "%.1f", Date().timeIntervalSince(t0))) с)")
        }
        let jobs = StartupScanner.scanJobs()
        print("Автозагрузка: служб \(jobs.count), с автозапуском \(jobs.filter(\.startsAutomatically).count), выключено \(jobs.filter { !$0.enabled }.count), без файла программы \(jobs.filter { $0.program != nil && !$0.programExists }.count)")
        for j in jobs.prefix(6) {
            print("  [\(j.scope.short)] \(j.enabled ? "вкл " : "выкл") \(j.label) — \(j.trigger) — \(j.vendor)\(j.pid.map { " — PID \($0)" } ?? "")")
        }
        if let launchd = map[1] {
            let ld = DetailsLoader.load(pid: 1, path: launchd.path)
            print("launchd: path \(launchd.path), files available \(ld.filesAvailable), signing \(ld.signing?.summary ?? "-"), args \(ld.arguments)")
        }
    }
}
