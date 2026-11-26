import AppKit
import SwiftUI

@main
enum Main {
    static func main() {
        // `ClipMom --selftest` — проверка записи на отдельном (не общем!) буфере и хранилища во временной папке.
        if CommandLine.arguments.contains("--selftest") { SelfTest.run(); return }
        ClipMomApp.main()
    }
}

struct ClipMomApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var delegate
    @State private var state: AppState

    init() {
        // `--demo` — образцы записей в памяти: настоящая история и буфер обмена не трогаются.
        let s = AppState(demo: CommandLine.arguments.contains("--demo"))
        _state = State(initialValue: s)
        AppDelegate.state = s
    }

    var body: some Scene {
        Window("ClipMom", id: "main") {
            ContentView()
                .environment(state)
                .environment(\.locale, Locale(identifier: "ru_RU"))
                .frame(minWidth: 900, minHeight: 540)
                .task { LaunchOptions.apply(to: state) }
        }
        .defaultSize(width: 1080, height: 680)
        .commands {
            CommandGroup(replacing: .appSettings) {
                Button("Настройки…") { state.showSettings = true }.keyboardShortcut(",")
            }
            CommandGroup(after: .sidebar) {
                Button(state.isRecording ? "Приостановить запись" : "Возобновить запись") { state.togglePause() }
                    .keyboardShortcut("p", modifiers: [.command, .shift])
                Button("Не записывать 5 минут") { state.pauseFiveMinutes() }
                Divider()
                Button("Быстрая панель") { state.panel?.toggle() }
                Divider()
            }
        }

        // Значок в строке меню: окно можно закрыть — ClipMom продолжит записывать историю.
        MenuBarExtra {
            MenuBarContent(state: state)
        } label: {
            Image(systemName: state.isRecording ? "list.clipboard" : "pause.circle")
        }
    }
}

final class AppDelegate: NSObject, NSApplicationDelegate {
    static var state: AppState?
    /// Действие SwiftUI `openWindow(id: "main")`, запомненное окном при первом показе.
    static var openMain: (() -> Void)?

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.regular)  // нужно при запуске без .app (swift run)
        NSApp.activate(ignoringOtherApps: true)
    }

    /// Окно закрыто — запись продолжается, ClipMom остаётся в строке меню.
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { false }

    /// Щелчок по значку в Dock или повторный запуск из лаунчера при закрытом окне — показать окно.
    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        if !flag { Self.openMain?() }
        return true
    }

    func applicationWillTerminate(_ notification: Notification) {
        MainActor.assumeIsolated { Self.state?.flush() }
    }
}

struct MenuBarContent: View {
    let state: AppState
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        let recent = Array(state.items.prefix(10))
        if recent.isEmpty {
            Text("История пуста")
        } else {
            ForEach(Array(recent.enumerated()), id: \.element.id) { i, item in
                Button {
                    state.copy(item)
                } label: {
                    Label(menuTitle(item), systemImage: item.pinned ? "pin.fill" : item.kind.icon)
                }
                .keyboardShortcut(i < 9 ? KeyboardShortcut(KeyEquivalent(Character("\(i + 1)")), modifiers: []) : nil)
            }
        }
        Divider()
        if let until = state.pauseUntil {
            Text("Пауза до \(until.formatted(date: .omitted, time: .shortened))")
        }
        Button(state.isRecording ? "Приостановить запись" : "Возобновить запись") { state.togglePause() }
        if state.isRecording {
            Button("Не записывать 5 минут") { state.pauseFiveMinutes() }
        }
        Divider()
        Button("Открыть ClipMom") {
            openWindow(id: "main")
            NSApp.activate(ignoringOtherApps: true)
        }
        Button("Завершить ClipMom") { NSApp.terminate(nil) }
            .keyboardShortcut("q")
    }

    private func menuTitle(_ item: ClipItem) -> String {
        let t = item.title.replacingOccurrences(of: "\t", with: " ")
        return t.count > 48 ? String(t.prefix(47)) + "…" : t
    }
}

/// `open ClipMom.app --args --demo --panel` — сразу показать быструю панель; `--settings` — настройки;
/// `--filter link` — фильтр (all|text|link|image|files|pinned); `--select 2` — выделить запись;
/// `--close-window` — закрыть окно (проверка, что ClipMom живёт в строке меню и открывается снова).
enum LaunchOptions {
    @MainActor static func apply(to state: AppState) {
        let args = CommandLine.arguments
        func value(_ flag: String) -> String? {
            guard let i = args.firstIndex(of: flag), i + 1 < args.count else { return nil }
            return args[i + 1]
        }
        if let f = value("--filter").flatMap(ClipFilter.init(rawValue:)) { state.filter = f }
        if args.contains("--settings") { state.showSettings = true }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) {
            if let n = value("--select").flatMap(Int.init), n < state.visibleItems.count {
                state.selection = state.visibleItems[n].id
            }
            if args.contains("--panel") { state.panel?.show() }
            // Для проверки повторного открытия: закрыть окно, затем `open -b local.clipmom`.
            if args.contains("--close-window") {
                NSApp.windows.first { $0.isVisible && !($0 is NSPanel) && $0.styleMask.contains(.titled) }?.close()
            }
        }
    }
}
