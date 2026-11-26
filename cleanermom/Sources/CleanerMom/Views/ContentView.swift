import SwiftUI

struct ContentView: View {
    @Environment(AppState.self) private var state

    var body: some View {
        @Bindable var state = state
        let section = Binding<SidebarSection?>(get: { state.section }, set: { if let v = $0 { state.section = v } })

        NavigationSplitView {
            List(selection: section) {
                Label("Умная очистка", systemImage: "sparkles")
                    .tag(SidebarSection.smart)
                Section("Очистка") {
                    Label("Мусор", systemImage: "trash.circle")
                        .badge(state.junk.phase == .ready || state.junk.phase == .done
                               ? Text(Fmt.bytes(state.junk.totalFound)) : nil)
                        .tag(SidebarSection.junk)
                }
                Section("Место") {
                    Label("Крупные файлы", systemImage: "doc.on.doc")
                        .tag(SidebarSection.large)
                    Label("Деинсталлятор", systemImage: "xmark.app")
                        .tag(SidebarSection.uninstaller)
                }
                Section("Mac") {
                    Label("Обслуживание", systemImage: "wrench.and.screwdriver")
                        .tag(SidebarSection.maintenance)
                }
            }
            .navigationSplitViewColumnWidth(min: 190, ideal: 210, max: 260)
            .safeAreaInset(edge: .bottom) { DiskGauge(disk: state.disk).padding(12) }
        } detail: {
            switch state.section {
            case .smart: SmartCleanView()
            case .junk: JunkView()
            case .large: LargeFilesView()
            case .uninstaller: UninstallerView()
            case .maintenance: MaintenanceView()
            }
        }
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
            state.refreshSystem()
        }
    }
}
