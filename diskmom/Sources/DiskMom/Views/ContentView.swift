import AppKit
import SwiftUI

struct ContentView: View {
    @Environment(AppState.self) private var state

    var body: some View {
        let section = Binding<SidebarSection?>(get: { state.section }, set: { if let v = $0 { state.section = v } })
        let isRightToLeft = L10n.layoutDirection == .rightToLeft

        NavigationSplitView {
            List(selection: section) {
                Section("Место") {
                    Label("Карта диска", systemImage: "chart.pie")
                        .badge(state.map.root.map { Text(Fmt.bytes($0.size)) })
                        .tag(SidebarSection.map)
                    Label("Дубликаты", systemImage: "doc.on.doc")
                        .badge(state.dupes.phase == .ready && state.dupes.totalReclaimable > 0
                               ? Text(Fmt.bytes(state.dupes.totalReclaimable)) : nil)
                        .tag(SidebarSection.dupes)
                }
                Section("Mac") {
                    Label("Диски", systemImage: "externaldrive")
                        .badge(state.volumes.volumes.count > 1 ? Text("\(state.volumes.volumes.count)") : nil)
                        .tag(SidebarSection.disks)
                }
            }
            .navigationSplitViewColumnWidth(
                min: isRightToLeft ? 220 : 190,
                ideal: isRightToLeft ? 245 : 210,
                max: isRightToLeft ? 275 : 260
            )
            .safeAreaInset(edge: .bottom) { DiskGauge(disk: state.disk).padding(12) }
        } detail: {
            switch state.section {
            case .map: DiskMapView()
            case .dupes: DuplicatesView()
            case .disks: VolumesView()
            }
        }
        .task { await state.volumes.refresh() }
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
            state.refreshSystem()
        }
        .onReceive(NSWorkspace.shared.notificationCenter.publisher(for: NSWorkspace.didMountNotification)) { _ in volumesChanged() }
        .onReceive(NSWorkspace.shared.notificationCenter.publisher(for: NSWorkspace.didUnmountNotification)) { _ in volumesChanged() }
        .onReceive(NSWorkspace.shared.notificationCenter.publisher(for: NSWorkspace.didRenameVolumeNotification)) { _ in volumesChanged() }
    }

    private func volumesChanged() {
        state.refreshSystem()
        Task { await state.volumes.refresh() }
    }
}
