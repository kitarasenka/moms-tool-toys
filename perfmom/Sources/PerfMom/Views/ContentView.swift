import SwiftUI

struct ContentView: View {
    @Environment(AppState.self) private var state

    var body: some View {
        @Bindable var state = state
        let sectionBinding = Binding<SidebarSection?>(
            get: { state.section },
            set: { if let v = $0 { state.section = v } }
        )

        NavigationSplitView {
            List(selection: sectionBinding) {
                Section("Мониторинг") {
                    Label("Обзор", systemImage: "gauge.with.dots.needle.33percent")
                        .tag(SidebarSection.overview)
                    Label("Процессы", systemImage: "list.bullet.rectangle")
                        .badge(state.monitor.processes.count)
                        .tag(SidebarSection.processes)
                    Label("Дерево процессов", systemImage: "point.3.filled.connected.trianglepath.dotted")
                        .tag(SidebarSection.tree)
                    Label("История", systemImage: "chart.xyaxis.line")
                        .tag(SidebarSection.history)
                }
                Section("Система") {
                    Label("Автозагрузка", systemImage: "power")
                        .tag(SidebarSection.startup)
                    Label("Безопасность", systemImage: "shield.lefthalf.filled")
                        .badge(state.riskyCount)
                        .tag(SidebarSection.security)
                }
            }
            .navigationSplitViewColumnWidth(min: 190, ideal: 210, max: 280)
            .safeAreaInset(edge: .bottom) {
                SidebarGauges().padding(12)
            }
        } detail: {
            Group {
                switch state.section {
                case .overview: OverviewView()
                case .processes: ProcessListView()
                case .tree: ProcessTreeView()
                case .history: HistoryView()
                case .startup: StartupView()
                case .security: SecurityView()
                }
            }
            .inspector(isPresented: Binding(
                // В «Автозагрузке» инспектор процессов не нужен — отдаём место таблице.
                get: { state.showInspector && state.section != .startup && state.section != .history },
                set: { state.showInspector = $0 }
            )) {
                InspectorView()
                    .inspectorColumnWidth(min: 340, ideal: 400, max: 620)
                    .toolbar {
                        ToolbarItem {
                            Button {
                                state.showInspector.toggle()
                            } label: {
                                Label("Инспектор", systemImage: "sidebar.trailing")
                            }
                            .help("Показать или скрыть инспектор (⌘I)")
                        }
                    }
            }
        }
        .searchable(text: $state.search, placement: .toolbar, prompt: "Имя, PID, путь или пользователь")
        .toolbar {
            ToolbarItemGroup(placement: .primaryAction) {
                Button {
                    state.request(.terminate)
                } label: {
                    Label("Завершить процесс", systemImage: "xmark.octagon")
                }
                .disabled(state.selectedPID == nil)
                .help("Завершить выбранный процесс (⌥⌘Q)")

                Button {
                    state.monitor.paused.toggle()
                } label: {
                    Label(state.monitor.paused ? String(localized: "Продолжить") : String(localized: "Пауза"),
                          systemImage: state.monitor.paused ? "play.fill" : "pause.fill")
                }
                .help(state.monitor.paused ? String(localized: "Возобновить обновление") : String(localized: "Приостановить обновление"))

                Menu {
                    Picker("Частота обновления", selection: Bindable(state.monitor).interval) {
                        Text("Каждые 0,5 с").tag(0.5)
                        Text("Каждую секунду").tag(1.0)
                        Text("Каждые 2 с").tag(2.0)
                        Text("Каждые 5 с").tag(5.0)
                    }
                    .pickerStyle(.inline)
                } label: {
                    Label("Частота обновления", systemImage: "timer")
                }
                .help("Частота обновления")
            }
        }
        .alert(state.pendingAction?.title ?? "",
               isPresented: Binding(get: { state.pendingAction != nil }, set: { if !$0 { state.pendingAction = nil } }),
               presenting: state.pendingAction) { p in
            Button(p.action.title, role: .destructive) { state.perform(p) }
            Button("Отменить", role: .cancel) {}
        } message: { p in
            Text(p.message)
        }
        .alert(state.alert?.title ?? "",
               isPresented: Binding(get: { state.alert != nil }, set: { if !$0 { state.alert = nil } }),
               presenting: state.alert) { a in
            if let retry = a.retryAsAdmin {
                Button("Ввести пароль администратора") { state.performAsAdmin(retry) }
                Button("Отменить", role: .cancel) {}
            } else {
                Button("OK", role: .cancel) {}
            }
        } message: { a in
            Text(a.message)
        }
    }
}

struct SidebarGauges: View {
    @Environment(AppState.self) private var state

    var body: some View {
        let s = state.monitor.system
        VStack(alignment: .leading, spacing: 10) {
            gauge(String(localized: "ЦП"), value: s.cpuTotal / 100, text: "\(Fmt.percent(s.cpuTotal)) %", tint: .blue)
            gauge(String(localized: "Память"), value: Double(s.memUsed) / Double(max(s.memTotal, 1)),
                  text: Fmt.bytes(s.memUsed), tint: s.memPressure >= 4 ? .red : (s.memPressure >= 2 ? .yellow : .green))
        }
        .padding(10)
        .background(.background.secondary.opacity(0.6), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
    }

    private func gauge(_ title: String, value: Double, text: String, tint: Color) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Text(title).foregroundStyle(.secondary)
                Spacer()
                Text(text).monospacedDigit()
            }
            .font(.caption)
            ProgressView(value: min(max(value, 0), 1))
                .progressViewStyle(.linear)
                .tint(tint)
                .controlSize(.small)
        }
    }
}
