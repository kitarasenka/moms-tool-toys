import AppKit
import SwiftUI

@main
enum Main {
    static func main() {
        // `KeyMom --selftest` — таблицы раскладок, направление, буфер на отдельном (не общем!) буфере, сочетания.
        if CommandLine.arguments.contains("--selftest") { SelfTest.run(); return }
        KeyMomApp.main()
    }
}

struct KeyMomApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var delegate
    @State private var state: AppState

    init() {
        // `--demo` — настройки только в памяти, сочетание не регистрируется, чужие окна не меняются.
        let s = AppState(demo: CommandLine.arguments.contains("--demo"))
        _state = State(initialValue: s)
        AppDelegate.state = s
    }

    var body: some Scene {
        Window("KeyMom", id: "main") {
            ContentView()
                .environment(state)
                .environment(\.locale, Locale(identifier: "ru_RU"))
                .frame(minWidth: 820, minHeight: 560)
                .task { LaunchOptions.apply(to: state) }
        }
        .defaultSize(width: 980, height: 720)
        .commands {
            CommandGroup(replacing: .appSettings) {
                Button("Настройки…") { state.section = .settings }.keyboardShortcut(",")
            }
            CommandGroup(after: .sidebar) {
                ForEach(Array(Page.allCases.enumerated()), id: \.element) { i, s in
                    Button(s.title) { state.section = s }
                        .keyboardShortcut(KeyEquivalent(Character("\(i + 1)")), modifiers: .command)
                }
                Divider()
            }
            CommandGroup(replacing: .help) {
                Button("Как пользоваться KeyMom") { state.section = .guide }
            }
        }

        // Строка меню: текущая раскладка и Caps Lock. Окно можно закрыть — KeyMom продолжит работать.
        MenuBarExtra {
            MenuBarContent(state: state)
        } label: {
            MenuBarLabel(state: state)
        }
    }
}

struct MenuBarLabel: View {
    let state: AppState

    var body: some View {
        let cur = state.current
        switch state.prefs.indicator {
        case .icon:
            Image(systemName: state.capsOn ? "capslock.fill" : "keyboard")
        case .flag:
            Text((cur?.flag ?? "⌨️") + (state.capsOn ? " ⇪" : ""))
        case .code:
            Text((cur?.code ?? "—") + (state.capsOn ? " ⇪" : ""))
        }
    }
}

final class AppDelegate: NSObject, NSApplicationDelegate {
    static var state: AppState?
    /// Действие SwiftUI `openWindow(id: "main")`, запомненное окном при первом показе.
    static var openMain: (() -> Void)?

    func applicationDidFinishLaunching(_ notification: Notification) {
        AppState.applyDockPolicy(Self.state?.prefs.showInDock ?? true)
        NSApp.activate(ignoringOtherApps: true)
    }

    /// Окно закрыто — KeyMom остаётся в строке меню и продолжает слушать сочетание.
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { false }

    /// Щелчок по значку в Dock или повторный запуск из лаунчера при закрытом окне — показать окно.
    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        if !flag { Self.openMain?() }
        return true
    }
}

struct MenuBarContent: View {
    let state: AppState
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        Text("Раскладка: \(state.current?.name ?? "—")")
        if state.capsOn { Text("⇪ Caps Lock включён") }
        if let f = state.lastFix { Text("Последнее: \(f.count > 40 ? String(f.prefix(39)) + "…" : f)") }
        Divider()
        Button("Исправить раскладку (\(state.prefs.hotkey.title))") {
            // После закрытия меню фокус возвращается в приложение, где вы печатали.
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.25) { Task { await state.fixLayout() } }
        }
        Button("Исправить текст…") { open(.convert) }
        Button("Как пользоваться…") { open(.guide) }
        Divider()
        Button("Открыть KeyMom") { open(nil) }
        Button("Настройки…") { open(.settings) }
        Button("Завершить KeyMom") { NSApp.terminate(nil) }
            .keyboardShortcut("q")
    }

    /// Без значка в Dock окно открывается только отсюда — поэтому сразу активируем KeyMom.
    private func open(_ s: Page?) {
        if let s { state.section = s }
        openWindow(id: "main")
        NSApp.activate(ignoringOtherApps: true)
    }
}

/// `open KeyMom.app --args --demo --section convert` (guide|convert|settings); `--hud caps|layout|warning|success` —
/// показать плашку у курсора; `--no-dock` — только строка меню; `--close-window` — закрыть окно.
enum LaunchOptions {
    @MainActor static func apply(to state: AppState) {
        let args = CommandLine.arguments
        func value(_ flag: String) -> String? {
            guard let i = args.firstIndex(of: flag), i + 1 < args.count else { return nil }
            return args[i + 1]
        }
        if let s = value("--section").flatMap(Page.init(rawValue:)) { state.section = s }
        if args.contains("--no-dock") { state.setShowInDock(false) }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
            if value("--hud") != nil { state.pinnedHUD = true }
            switch value("--hud") {
            case "caps": state.flash.show(HUDMessage(title: "Caps Lock", flag: "⇪", subtitle: "Включён — буквы будут ЗАГЛАВНЫЕ", style: .caps), duration: 30)
            case "warning": state.warning.show(HUDMessage(title: "Включён Caps Lock", flag: "⚠️", subtitle: "Пароль может не подойти — нажмите ⇪, чтобы выключить", style: .warning), duration: 30)
            case "success": state.flash.show(HUDMessage(title: "RU", flag: "🇷🇺", subtitle: "Исправлено: привет", style: .success), duration: 30)
            case "layout": state.flash.show(HUDMessage(title: "RU", flag: "🇷🇺", subtitle: "Русская – ПК", style: .layout), duration: 30)
            default: break
            }
            if args.contains("--close-window") {
                NSApp.windows.first { $0.isVisible && !($0 is NSPanel) && $0.styleMask.contains(.titled) }?.close()
            }
        }
    }
}
