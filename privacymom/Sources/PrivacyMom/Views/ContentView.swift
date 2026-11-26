import SwiftUI

struct ContentView: View {
    @Environment(AppState.self) private var state

    var body: some View {
        let section = Binding<SidebarSection?>(get: { state.section }, set: { if let v = $0 { state.section = v } })

        NavigationSplitView {
            List(selection: section) {
                Section("Доступ") {
                    Label(SidebarSection.permissions.title, systemImage: SidebarSection.permissions.icon)
                        .badge(state.permissions.phase == .ready && state.fullDiskAccess
                               ? Text("\(state.permissions.snapshot.entries.filter(\.auth.isGranted).count)") : nil)
                        .tag(SidebarSection.permissions)
                    Label {
                        HStack {
                            Text(SidebarSection.now.title)
                            if state.sensors.anyCamera || state.sensors.anyMic {
                                Spacer()
                                Circle().fill(.red).frame(width: 8, height: 8)
                                    .shadow(color: .red.opacity(0.7), radius: 4)
                                    .help("Камера или микрофон сейчас включены")
                            }
                        }
                    } icon: {
                        Image(systemName: SidebarSection.now.icon)
                    }
                    .tag(SidebarSection.now)
                }
                Section("Следы") {
                    Label(SidebarSection.browsers.title, systemImage: SidebarSection.browsers.icon)
                        .tag(SidebarSection.browsers)
                    Label(SidebarSection.wifi.title, systemImage: SidebarSection.wifi.icon)
                        .badge(state.wifi.phase == .ready ? Text("\(state.wifi.networks.count)") : nil)
                        .tag(SidebarSection.wifi)
                }
            }
            .navigationSplitViewColumnWidth(min: 190, ideal: 210, max: 260)
            .safeAreaInset(edge: .bottom) { AccessStatus().padding(12) }
        } detail: {
            switch state.section {
            case .permissions: PermissionsView()
            case .now: NowView()
            case .browsers: BrowsersView()
            case .wifi: WifiView()
            }
        }
        .task {
            state.sensors.start()
            await state.permissions.load()
        }
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
            state.refreshSystem()
        }
    }
}

/// Внизу боковой панели: есть ли полный доступ к диску.
private struct AccessStatus: View {
    @Environment(AppState.self) private var state

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: state.fullDiskAccess ? "checkmark.shield.fill" : "lock.shield")
                .foregroundStyle(state.fullDiskAccess ? AnyShapeStyle(Brand.gradient) : AnyShapeStyle(.orange))
            VStack(alignment: .leading, spacing: 1) {
                Text("Полный доступ к диску").font(.caption)
                Text(state.fullDiskAccess ? "есть" : "нет — часть данных скрыта")
                    .font(.caption2).foregroundStyle(.secondary)
            }
            Spacer(minLength: 0)
        }
        .padding(10)
        .background(.background.secondary.opacity(0.6), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
        .onTapGesture { if !state.fullDiskAccess { FullDiskAccess.openSettings() } }
        .help(state.fullDiskAccess ? "PrivacyMom видит базы разрешений и данные Safari" : "Нажмите, чтобы открыть настройки")
    }
}
