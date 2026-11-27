import SwiftUI

struct ContentView: View {
    @Environment(AppState.self) private var state
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        @Bindable var state = state
        let filter = Binding<ClipFilter?>(get: { state.filter }, set: { if let v = $0 { state.filter = v } })

        NavigationSplitView {
            List(selection: filter) {
                Section("История") {
                    ForEach(ClipFilter.allCases) { f in
                        Label(f.title, systemImage: f.icon)
                            .badge(state.count(f))
                            .tag(f)
                    }
                }
            }
            .navigationSplitViewColumnWidth(min: 180, ideal: 200, max: 250)
            .safeAreaInset(edge: .bottom) { RecordingCard().padding(10) }
        } content: {
            HistoryListView()
                .navigationSplitViewColumnWidth(min: 300, ideal: 360, max: 520)
        } detail: {
            DetailView()
        }
        .searchable(text: $state.query, placement: .toolbar, prompt: "Поиск в истории")
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                Button { state.showSettings = true } label: { Label("Настройки", systemImage: "gearshape") }
                    .help("Настройки ClipMom (⌘,)")
            }
        }
        .sheet(isPresented: $state.showSettings) { SettingsView().environment(state) }
        .sheet(isPresented: $state.showGuide) { GuideSheet().environment(state) }
        .onAppear {
            let open = openWindow
            AppDelegate.openMain = { open(id: "main") }
        }
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
            state.refreshAccess()
        }
    }
}

/// Внизу боковой панели: идёт ли запись, пауза, последнее событие.
struct RecordingCard: View {
    @Environment(AppState.self) private var state

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 6) {
                Circle().fill(state.isRecording ? Color.green : Color.orange).frame(width: 8, height: 8)
                Text(statusText).font(.caption.weight(.semibold))
                Spacer(minLength: 0)
            }
            if let e = state.lastEvent {
                Text(e).font(.caption2).foregroundStyle(.secondary).lineLimit(2)
            }
            HStack(spacing: 6) {
                Button(state.isRecording ? "Пауза" : "Продолжить") { state.togglePause() }
                if state.isRecording {
                    Button("5 мин") { state.pauseFiveMinutes() }.help("Не записывать 5 минут")
                }
            }
            .controlSize(.small)
        }
        .padding(10)
        .background(.background.secondary.opacity(0.7), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
    }

    private var statusText: String {
        if state.demo { return "Демо-режим" }
        if let u = state.pauseUntil { return "Пауза до \(u.formatted(date: .omitted, time: .shortened))" }
        if state.paused { return "Запись на паузе" }
        if !state.access.canAutoRead { return "Нет доступа к буферу" }
        return "Запись идёт"
    }
}

struct HistoryListView: View {
    @Environment(AppState.self) private var state

    var body: some View {
        @Bindable var state = state
        let list = state.visibleItems
        Group {
            if list.isEmpty {
                if !state.query.isEmpty {
                    EmptyStateView(icon: "magnifyingglass", title: "Ничего не нашлось",
                                   text: "Попробуйте другое слово или фильтр «Всё».")
                } else if state.items.isEmpty {
                    EmptyStateView(icon: "list.clipboard", title: "История пока пуста",
                                   text: "Скопируйте что-нибудь (⌘C) — оно появится здесь. Быстрая панель — ⇧⌘V.")
                } else {
                    EmptyStateView(icon: state.filter.icon, title: "Здесь пусто",
                                   text: state.filter == .pinned ? "Закрепите важное — оно не удалится со временем."
                                                                 : "В этом разделе пока ничего нет.")
                }
            } else {
                TimelineView(.periodic(from: .now, by: 30)) { tl in
                    List(selection: $state.selection) {
                        ForEach(list) { item in
                            ClipRow(item: item, now: tl.date).tag(item.id)
                        }
                    }
                    .contextMenu(forSelectionType: UUID.self) { ids in
                        if let id = ids.first, let item = state.items.first(where: { $0.id == id }) {
                            Button("Скопировать") { state.copy(item) }
                            Button(item.pinned ? "Открепить" : "Закрепить") { state.togglePin(item) }
                            Divider()
                            Button("Удалить", role: .destructive) { state.delete(item) }
                        }
                    } primaryAction: { ids in
                        if let id = ids.first, let item = state.items.first(where: { $0.id == id }) { state.copy(item) }
                    }
                    .onDeleteCommand { if let item = state.selectedItem { state.delete(item) } }
                }
            }
        }
        .navigationTitle(state.filter.title)
        .navigationSubtitle(subtitle(list.count))
    }

    private func subtitle(_ n: Int) -> String {
        let m10 = n % 10, m100 = n % 100
        let word = m10 == 1 && m100 != 11 ? "запись" : ((2...4).contains(m10) && !(12...14).contains(m100) ? "записи" : "записей")
        return "\(n) \(word)"
    }
}

struct ClipRow: View {
    let item: ClipItem
    var now: Date = .now

    var body: some View {
        HStack(spacing: 10) {
            ClipIcon(item: item)
            VStack(alignment: .leading, spacing: 3) {
                Text(item.title)
                    .lineLimit(2)
                    .truncationMode(.tail)
                HStack(spacing: 4) {
                    SourceIcon(bundleID: item.sourceID, size: 13)
                    Text([item.sourceName, Fmt.ago(item.date, now: now)].compactMap { $0 }.joined(separator: " · "))
                        .lineLimit(1)
                }
                .font(.caption)
                .foregroundStyle(.secondary)
            }
            Spacer(minLength: 4)
            if item.pinned {
                Image(systemName: "pin.fill").font(.caption).foregroundStyle(Brand.blue)
                    .accessibilityLabel("Закреплено")
            }
        }
        .padding(.vertical, 3)
    }
}
