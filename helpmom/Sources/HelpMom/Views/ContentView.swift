import SwiftUI

struct ContentView: View {
    @Environment(AppState.self) private var state

    var body: some View {
        @Bindable var state = state
        let selection = Binding<Pane?>(get: { state.section }, set: { if let v = $0 { state.section = v } })

        NavigationSplitView {
            List(selection: selection) {
                ForEach(Pane.allCases) { p in
                    Label(p.title, systemImage: p.icon)
                        .font(.title3)
                        .padding(.vertical, 4)
                        .tag(p)
                }
            }
            .navigationSplitViewColumnWidth(min: 200, ideal: 230, max: 280)
            .safeAreaInset(edge: .bottom) { SidebarStatus().padding(10) }
        } detail: {
            Group {
                switch state.section {
                case .report: ReportView()
                case .call: CallView()
                case .problems: ProblemsView()
                }
            }
            .fillAvailable()
            .navigationTitle(state.section.title)
        }
        .overlay(alignment: .bottom) {
            if let t = state.toast {
                ToastView(text: t).padding(.bottom, 18).transition(.move(edge: .bottom).combined(with: .opacity))
            }
        }
        .animation(.spring(duration: 0.3), value: state.toast)
        .sheet(item: $state.editing) { h in HelperEditor(helper: h).environment(state) }
    }
}

/// Внизу боковой панели — итог отчёта одной строкой.
struct SidebarStatus: View {
    @Environment(AppState.self) private var state

    var body: some View {
        HStack(spacing: 8) {
            if let r = state.report {
                Image(systemName: r.overall.symbol).foregroundStyle(r.overall.color).font(.title3)
                VStack(alignment: .leading, spacing: 1) {
                    Text(r.headline).font(.caption.weight(.semibold))
                    Text(state.demo ? "Демо-режим" : "Проверено в \(r.collectedAt.formatted(date: .omitted, time: .shortened))")
                        .font(.caption2).foregroundStyle(.secondary)
                }
            } else {
                ProgressView().controlSize(.small)
                Text("Проверяю Mac…").font(.caption)
            }
            Spacer(minLength: 0)
        }
        .padding(10)
        .background(.background.secondary.opacity(0.7), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
    }
}
