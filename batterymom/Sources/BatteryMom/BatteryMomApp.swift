import AppKit
import SwiftUI

@main
enum Main {
    static func main() {
        let args = CommandLine.arguments
        // `BatteryMom --status` — батарея и устройства в консоль, без окна.
        if args.contains("--status") { CLI.status(); return }
        // `BatteryMom --energy` — топ приложений по энергопотреблению.
        if args.contains("--energy") { CLI.energy(); return }
        // `BatteryMom --selftest` — разборщики на заготовленных выводах и история во временной папке.
        if args.contains("--selftest") { exit(SelfTest.run() ? 0 : 1) }
        BatteryMomApp.main()
    }
}

struct BatteryMomApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var delegate
    @State private var state = AppState()

    var body: some Scene {
        Window("BatteryMom", id: "main") {
            ContentView()
                .environment(state)
                .frame(minWidth: 900, minHeight: 600)
                .task {
                    LaunchOptions.apply(to: state)
                    state.start()
                }
        }
        .defaultSize(width: 1080, height: 720)
        .commands {
            CommandGroup(after: .sidebar) {
                Button("Батарея") { state.section = .battery }.keyboardShortcut("1")
                Button("История") { state.section = .history }.keyboardShortcut("2")
                Button("Расход приложений") { state.section = .energy }.keyboardShortcut("3")
                Button("Устройства") { state.section = .devices }.keyboardShortcut("4")
                Divider()
                Button("Обновить") { Task { await state.refreshAll() } }.keyboardShortcut("r")
                Divider()
            }
        }

        // Значок в строке меню: при закрытом окне BatteryMom продолжает работать и записывать историю.
        MenuBarExtra {
            MenuBarContent(state: state)
        } label: {
            MenuBarLabel(battery: state.battery)
        }
    }
}

final class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.regular)  // нужно при запуске без .app (swift run)
        NSApp.activate(ignoringOtherApps: true)
    }

    /// Окно можно закрыть — запись истории продолжится, BatteryMom остаётся в строке меню.
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { false }
}

struct MenuBarLabel: View {
    let battery: BatteryInfo?

    var body: some View {
        if let b = battery {
            Image(systemName: BatterySymbol.name(b))
            Text("\(b.percent) %")
        } else {
            Image(systemName: "powerplug")
        }
    }
}

enum BatterySymbol {
    static func name(_ b: BatteryInfo) -> String {
        if b.isCharging { return "battery.100percent.bolt" }
        switch b.percent {
        case ..<13: return "battery.0percent"
        case ..<38: return "battery.25percent"
        case ..<63: return "battery.50percent"
        case ..<88: return "battery.75percent"
        default: return "battery.100percent"
        }
    }
}

struct MenuBarContent: View {
    let state: AppState
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        if let b = state.battery {
            Text("Заряд: \(b.percent) % — \(b.state.short)")
            if let t = b.timeText { Text(t) }
            if let h = b.health {
                Text("Здоровье: \(Int(h.rounded())) %" + (b.cycleCount.map { ", циклов: \($0)" } ?? ""))
            }
            if let w = b.consumption { Text("Потребление: \(Fmt.watts(w))") }
            if let t = b.temperature { Text("Температура: \(Fmt.number(t)) °C") }
        } else {
            Text("Встроенной батареи нет")
        }
        let devs = state.devices.filter(\.connected)
        if !devs.isEmpty {
            Divider()
            ForEach(devs) { d in Text("\(d.name): \(d.levelsText)") }
        }
        Divider()
        Button("Открыть BatteryMom") { show(.battery) }
        Button("Расход приложений") { show(.energy) }
        Button("Устройства") { show(.devices) }
        Divider()
        Button("Завершить BatteryMom") { NSApp.terminate(nil) }
            .keyboardShortcut("q")
    }

    private func show(_ section: SidebarSection) {
        state.section = section
        openWindow(id: "main")
        NSApp.activate(ignoringOtherApps: true)
    }
}

/// `open BatteryMom.app --args --section devices [--no-battery]`. Разделы: battery, history, energy, devices.
enum LaunchOptions {
    @MainActor static func apply(to state: AppState) {
        let args = CommandLine.arguments
        if let i = args.firstIndex(of: "--section"), i + 1 < args.count,
           let s = SidebarSection(rawValue: args[i + 1]) { state.section = s }
        if args.contains("--no-battery") { state.simulateNoBattery = true }
    }
}
