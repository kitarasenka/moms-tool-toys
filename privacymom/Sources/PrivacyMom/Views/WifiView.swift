import SwiftUI

struct WifiView: View {
    @Environment(AppState.self) private var state
    @State private var confirm = false
    @State private var search = ""

    var body: some View {
        let w = state.wifi
        Group {
            if w.phase != .ready {
                LoadingView(text: "Читаю запомненные сети…")
            } else if w.device == nil || w.error != nil {
                EmptyStateView(icon: "wifi.slash", title: "Список сетей недоступен", text: w.error ?? "Wi-Fi не найден.") {
                    Button("Повторить") { Task { await w.load() } }
                }
            } else {
                content.fillAvailable()
            }
        }
        .navigationTitle("Сети Wi-Fi")
        .task { if w.phase == .idle { await w.load() } }
        .toolbar {
            ToolbarItem {
                Button { Task { await w.load() } } label: { Label("Обновить", systemImage: "arrow.clockwise") }
                    .help("Перечитать список (⌘R)")
            }
        }
        .alert(w.selection.count == 1 ? "Забыть сеть «\(w.selection.first!)»?" : "Забыть \(Fmt.count(w.selection.count, "сеть", "сети", "сетей"))?",
               isPresented: $confirm) {
            Button("Забыть", role: .destructive) { Task { await w.forgetSelected() } }
            Button("Отменить", role: .cancel) {}
        } message: {
            Text(forgetText)
        }
    }

    private var forgetText: String {
        let w = state.wifi
        var t = "Mac перестанет подключаться к \(w.selection.count == 1 ? "этой сети" : "этим сетям") сам. Чтобы вернуться, придётся снова выбрать сеть и ввести пароль."
        if let c = w.current, w.selection.contains(c) { t += "\n\nСреди выбранных — текущая сеть «\(c)»: соединение может прерваться." }
        t += "\n\nmacOS попросит пароль администратора. Если включена «Связка ключей iCloud», сеть может вернуться с iPhone."
        return t
    }

    private var filtered: [String] {
        let q = search.trimmingCharacters(in: .whitespaces)
        return q.isEmpty ? state.wifi.networks : state.wifi.networks.filter { $0.localizedCaseInsensitiveContains(q) }
    }

    private var content: some View {
        @Bindable var w = state.wifi
        return VStack(spacing: 0) {
            VStack(alignment: .leading, spacing: 10) {
                HStack(spacing: 10) {
                    StatTile(icon: "wifi", title: "запомненных сетей", value: "\(w.networks.count)")
                    StatTile(icon: "checkmark.circle.fill", title: "подключено сейчас",
                             value: w.current ?? (w.currentChecked ? "—" : "…"))
                }
                Text("Mac помнит каждую сеть, к которой подключался, и подключается к ней сам, если увидит рядом. Старые сети кафе, гостиниц и вокзалов лучше забыть.")
                    .font(.callout).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                if let m = w.message { MessageBar(text: m) { w.message = nil } }
            }
            .padding(12)
            Divider()
            List(selection: $w.selection) {
                Section("Устройство \(w.device ?? "") — сначала самые приоритетные") {
                    ForEach(filtered, id: \.self) { ssid in
                        HStack(spacing: 10) {
                            Image(systemName: ssid == w.current ? "wifi" : "wifi")
                                .foregroundStyle(ssid == w.current ? AnyShapeStyle(Brand.gradient) : AnyShapeStyle(.secondary))
                                .frame(width: 20)
                            Text(ssid).lineLimit(1)
                            if ssid == w.current { Pill(text: "подключено", color: .green) }
                            Spacer()
                        }
                        .tag(ssid)
                        .contextMenu {
                            Button("Забыть…") { w.selection = [ssid]; confirm = true }
                        }
                    }
                }
            }
            .frame(maxHeight: .infinity)
            Divider()
            HStack {
                Text(w.selection.isEmpty ? "Выберите сети (⌘ или ⇧ — несколько)" : "Выбрано: \(Fmt.count(w.selection.count, "сеть", "сети", "сетей"))")
                    .foregroundStyle(.secondary)
                Spacer()
                if w.forgetting { ProgressView().controlSize(.small) }
                Button("Забыть") { confirm = true }
                    .buttonStyle(GlowCapsuleStyle())
                    .disabled(w.selection.isEmpty || w.forgetting)
                    .keyboardShortcut(.delete, modifiers: [])
            }
            .padding(12)
            .background(.bar)
        }
        .searchable(text: $search, placement: .toolbar, prompt: "Имя сети")
    }
}
