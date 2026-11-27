import SwiftUI

struct ContentView: View {
    @Environment(AppState.self) private var state

    var body: some View {
        let section = Binding<SidebarSection?>(get: { state.section }, set: { if let v = $0 { state.section = v } })

        NavigationSplitView {
            List(selection: section) {
                Section("Проверка Mac") {
                    ForEach(SidebarSection.allCases, id: \.self) { s in
                        Label {
                            HStack {
                                Text(s.title)
                                Spacer()
                                if let l = state.level(of: s) {
                                    Circle().fill(l.color).frame(width: 8, height: 8)
                                        .help(l.title)
                                }
                            }
                        } icon: {
                            Image(systemName: s.icon)
                        }
                        .tag(s)
                    }
                }
            }
            .navigationSplitViewColumnWidth(min: 190, ideal: 210, max: 260)
            .safeAreaInset(edge: .bottom) { SidebarFooter().padding(12) }
        } detail: {
            switch state.section {
            case .checks: ChecksView()
            case .browsers: BrowsersView()
            case .network: NetworkView()
            }
        }
        .task { await state.runChecks() }
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
            state.didBecomeActive()
        }
    }
}

/// Внизу боковой панели: когда проверяли, есть ли полный доступ к диску.
private struct SidebarFooter: View {
    @Environment(AppState.self) private var state

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 8) {
                Image(systemName: state.fullDiskAccess ? "checkmark.shield.fill" : "lock.shield")
                    .foregroundStyle(state.fullDiskAccess ? AnyShapeStyle(Brand.gradient) : AnyShapeStyle(.orange))
                VStack(alignment: .leading, spacing: 1) {
                    Text("Полный доступ к диску").font(.caption)
                    Text(state.fullDiskAccess ? String(localized: "есть") : String(localized: "нет — Safari не проверить"))
                        .font(.caption2).foregroundStyle(.secondary)
                }
                Spacer(minLength: 0)
            }
            .contentShape(Rectangle())
            .onTapGesture { if !state.fullDiskAccess { FullDiskAccess.openSettings() } }
            .help(state.fullDiskAccess ? String(localized: "SafetyMom видит настройки Safari") : String(localized: "Нажмите, чтобы открыть настройки"))
            if state.demo {
                Text("Демо-режим: выдуманные данные").font(.caption2).foregroundStyle(.secondary)
            } else if let t = state.checkedAt {
                Text("Проверено в \(Fmt.time(t))").font(.caption2).foregroundStyle(.secondary)
            }
        }
        .padding(10)
        .background(.background.secondary.opacity(0.6), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
    }
}
