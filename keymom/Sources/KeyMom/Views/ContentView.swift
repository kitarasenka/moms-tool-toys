import SwiftUI

struct ContentView: View {
    @Environment(AppState.self) private var state
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        @Bindable var state = state
        let sel = Binding<Page?>(get: { state.section }, set: { if let v = $0 { state.section = v } })

        NavigationSplitView {
            List(selection: sel) {
                ForEach(Page.allCases) { s in
                    Label(s.title, systemImage: s.icon).tag(s)
                }
            }
            .navigationSplitViewColumnWidth(min: 190, ideal: 210, max: 260)
            .safeAreaInset(edge: .bottom) { StatusCard().padding(10) }
        } detail: {
            Group {
                switch state.section {
                case .guide: GuideView()
                case .convert: ConverterView()
                case .settings: SettingsView()
                }
            }
            .fillAvailable()
            .navigationTitle(state.section.title)
        }
        .onAppear {
            let open = openWindow
            AppDelegate.openMain = { open(id: "main") }
        }
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
            state.axTrusted = Accessibility.trusted
            state.pasteAccess = PasteAccess.current()
        }
    }
}

/// Внизу боковой панели: текущая раскладка, Caps Lock, разрешение.
struct StatusCard: View {
    @Environment(AppState.self) private var state

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 8) {
                Text(state.current?.flag ?? "⌨️").font(.system(size: 22))
                VStack(alignment: .leading, spacing: 0) {
                    Text(state.current?.code ?? "—").font(.system(size: 17, weight: .bold, design: .rounded))
                    Text(state.current?.name ?? String(localized: "Раскладка неизвестна")).font(.caption2).foregroundStyle(.secondary).lineLimit(1)
                }
                Spacer(minLength: 0)
            }
            row(state.capsOn ? "capslock.fill" : "capslock", state.capsOn ? String(localized: "Caps Lock включён") : String(localized: "Caps Lock выключен"),
                state.capsOn ? .orange : .secondary)
            if !state.demo {
                row(state.axTrusted ? "checkmark.circle.fill" : "exclamationmark.triangle.fill",
                    state.axTrusted ? String(localized: "Исправление по \(state.prefs.hotkey.symbols.joined())␣ готово") : String(localized: "Нет «Универсального доступа»"),
                    state.axTrusted ? .green : .orange)
            }
        }
        .padding(10)
        .background(.background.secondary.opacity(0.7), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
    }

    private func row(_ icon: String, _ text: String, _ color: Color) -> some View {
        HStack(spacing: 6) {
            Image(systemName: icon).foregroundStyle(color).frame(width: 16)
            Text(text).font(.caption).lineLimit(2)
        }
    }
}
