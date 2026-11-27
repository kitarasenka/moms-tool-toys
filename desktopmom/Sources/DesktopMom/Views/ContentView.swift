import SwiftUI

struct ContentView: View {
    @Environment(AppState.self) private var state

    var body: some View {
        let pane = Binding<Pane?>(get: { state.pane }, set: { if let v = $0 { state.pane = v } })
        NavigationSplitView {
            List(selection: pane) {
                Section("Порядок") {
                    ForEach(Pane.allCases) { p in
                        Label(p.title, systemImage: p.icon)
                            .badge(state.badgeCount[p] ?? 0)
                            .tag(p)
                    }
                }
            }
            .navigationSplitViewColumnWidth(min: 190, ideal: 210, max: 260)
            .safeAreaInset(edge: .bottom) {
                if state.demo {
                    Label("Демо: выдуманные файлы", systemImage: "theatermasks")
                        .font(.caption).foregroundStyle(.secondary)
                        .padding(10).frame(maxWidth: .infinity, alignment: .leading)
                }
            }
        } detail: {
            VStack(spacing: 0) {
                if let b = state.banner {
                    BannerView(banner: b)
                    Divider()
                }
                Group {
                    switch state.pane {
                    case .desktop: DesktopView()
                    case .downloads: DownloadsView()
                    case .journal: JournalView()
                    }
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
            .fillAvailable()
            .toolbar {
                ToolbarItem(placement: .primaryAction) {
                    Button { state.refresh() } label: { Label("Обновить", systemImage: "arrow.clockwise") }
                        .help("Посмотреть заново (⌘R)")
                }
            }
        }
        .onChange(of: state.pane) { state.paneOpened() }
    }
}
