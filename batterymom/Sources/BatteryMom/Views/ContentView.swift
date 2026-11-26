import SwiftUI

struct ContentView: View {
    @Environment(AppState.self) private var state

    var body: some View {
        let section = Binding<SidebarSection?>(get: { state.section }, set: { if let v = $0 { state.section = v } })

        NavigationSplitView {
            List(selection: section) {
                Section("Mac") {
                    Label("Батарея", systemImage: state.battery.map(BatterySymbol.name) ?? "powerplug")
                        .badge(state.battery.map { Text("\($0.percent) %") })
                        .tag(SidebarSection.battery)
                    Label("История", systemImage: "chart.xyaxis.line")
                        .tag(SidebarSection.history)
                    Label("Расход приложений", systemImage: "bolt.horizontal.circle")
                        .tag(SidebarSection.energy)
                }
                Section("Аксессуары") {
                    Label("Устройства", systemImage: "headphones")
                        .badge(state.devices.filter(\.connected).count)
                        .tag(SidebarSection.devices)
                }
            }
            .navigationSplitViewColumnWidth(min: 190, ideal: 210, max: 260)
            .safeAreaInset(edge: .bottom) { SidebarBattery(battery: state.battery).padding(12) }
        } detail: {
            switch state.section {
            case .battery: BatteryView()
            case .history: HistoryView()
            case .energy: EnergyView()
            case .devices: DevicesView()
            }
        }
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
            state.refreshBattery()
        }
    }
}

/// Экран для Mac без встроенной батареи — с переходом в разделы, которые всё равно работают.
struct NoBatteryView: View {
    @Environment(AppState.self) private var state

    var body: some View {
        EmptyStateView(icon: "powerplug",
                       title: "У этого Mac нет встроенной батареи",
                       text: "Он работает от сети. BatteryMom всё равно покажет заряд беспроводных мышей, клавиатур и наушников и то, какие приложения больше всего нагружают Mac.") {
            HStack {
                Button("Устройства") { state.section = .devices }
                Button("Расход приложений") { state.section = .energy }
            }
            .controlSize(.large)
        }
    }
}
