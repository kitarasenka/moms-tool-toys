import SwiftUI

struct PermissionsView: View {
    @Environment(AppState.self) private var state
    @State private var resetEntry: TCCEntry?

    var body: some View {
        let p = state.permissions
        Group {
            if p.phase != .ready {
                LoadingView(text: "Читаю базы разрешений…")
            } else if !p.snapshot.userReadable && !p.snapshot.systemReadable {
                onboarding
            } else {
                content.fillAvailable()
            }
        }
        .navigationTitle("Разрешения")
        .toolbar {
            ToolbarItem {
                Button { Task { await p.load() } } label: { Label("Обновить", systemImage: "arrow.clockwise") }
                    .help("Перечитать разрешения (⌘R)")
            }
        }
        .alert("Сбросить разрешение?", isPresented: Binding(get: { resetEntry != nil }, set: { if !$0 { resetEntry = nil } }),
               presenting: resetEntry) { e in
            Button("Сбросить", role: .destructive) { Task { await p.reset(e) } }
            Button("Отменить", role: .cancel) {}
        } message: { e in
            Text("«\(e.info.title)» для \(p.name(e)) вернётся в исходное состояние. Приложение потеряет доступ и при следующей попытке спросит разрешение снова — тогда можно будет ответить заново.")
        }
    }

    // MARK: Без полного доступа

    private var onboarding: some View {
        ScrollView {
            VStack(spacing: 22) {
                Image(systemName: "hand.raised.circle")
                    .font(.system(size: 64, weight: .light))
                    .foregroundStyle(Brand.gradient)
                    .shadow(color: Brand.cyan.opacity(0.5), radius: 14)
                Text("Кто и к чему имеет доступ").font(.title.weight(.semibold))
                Text("macOS хранит выданные разрешения в закрытой базе. Чтобы PrivacyMom смог её прочитать (только прочитать — ничего не меняя), включите для него «Полный доступ к диску».")
                    .foregroundStyle(.secondary).multilineTextAlignment(.center).frame(maxWidth: 520)
                Button { FullDiskAccess.openSettings() } label: { Text("Открыть\nнастройки") }
                    .buttonStyle(GlowButtonStyle(diameter: 130))
                    .padding(.vertical, 6)
                Card {
                    VStack(alignment: .leading, spacing: 8) {
                        Text("Как включить").font(.headline)
                        step(1, "В открывшемся окне «Полный доступ к диску» найдите PrivacyMom и включите переключатель. Если его нет в списке — нажмите «+» и выберите PrivacyMom.app.")
                        step(2, "macOS может попросить пароль или Touch ID — это нормально.")
                        step(3, "Вернитесь в PrivacyMom: он сам перечитает разрешения. Если ничего не изменилось — перезапустите приложение.")
                    }
                }
                .frame(maxWidth: 560)
                Card {
                    VStack(alignment: .leading, spacing: 8) {
                        Text("Что появится").font(.headline)
                        Text("Какие приложения могут включать камеру и микрофон, записывать экран, видеть все файлы, следить за клавиатурой, управлять другими программами, читать контакты, календари и фото — с датой, когда разрешение выдали, и кнопкой «Сбросить».")
                            .font(.callout).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                        Text("Пока доступа нет, работают разделы «Сейчас» (кто включил камеру и микрофон), «Браузеры» (кроме Safari) и «Сети Wi-Fi».")
                            .font(.callout).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                    }
                }
                .frame(maxWidth: 560)
            }
            .padding(36)
            .frame(maxWidth: .infinity)
        }
    }

    private func step(_ n: Int, _ text: String) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Text("\(n)").font(.caption.weight(.bold)).foregroundStyle(.white)
                .frame(width: 18, height: 18).background(Circle().fill(Brand.gradient))
            Text(text).font(.callout).fixedSize(horizontal: false, vertical: true)
        }
    }

    // MARK: Список

    private var content: some View {
        @Bindable var p = state.permissions
        let groups = p.groups
        let shown = p.focused.map { f in groups.filter { $0.id == f } } ?? groups
        return VStack(spacing: 0) {
            VStack(spacing: 10) {
                if !p.snapshot.userReadable || !p.snapshot.systemReadable {
                    Text("Прочитана только \(p.snapshot.userReadable ? "пользовательская" : "системная") база — часть разрешений может не показываться.")
                        .font(.caption).foregroundStyle(.orange)
                }
                highlights
                if let m = p.message { MessageBar(text: m) { p.message = nil } }
            }
            .padding(12)
            Divider()
            HStack(spacing: 0) {
                serviceList(groups).frame(width: 260)
                Divider()
                entryList(shown).frame(maxWidth: .infinity)
            }
            .frame(maxHeight: .infinity)
        }
        .searchable(text: $p.search, placement: .toolbar, prompt: "Приложение или служба")
    }

    private var highlights: some View {
        let s = state.permissions.snapshot
        return HStack(spacing: 10) {
            StatTile(icon: "camera.fill", title: "доступ к камере", value: "\(s.granted("kTCCServiceCamera"))")
            StatTile(icon: "mic.fill", title: "к микрофону", value: "\(s.granted("kTCCServiceMicrophone"))")
            StatTile(icon: "rectangle.dashed.badge.record", title: "запись экрана", value: "\(s.granted("kTCCServiceScreenCapture"))")
            StatTile(icon: "internaldrive.fill", title: "полный доступ к диску", value: "\(s.granted("kTCCServiceSystemPolicyAllFiles"))")
        }
    }

    private func serviceList(_ groups: [ServiceGroup]) -> some View {
        @Bindable var p = state.permissions
        return VStack(spacing: 0) {
            List(selection: $p.focused) {
                Label("Все службы", systemImage: "square.grid.2x2")
                    .badge(groups.reduce(0) { $0 + $1.entries.count })
                    .tag(String?.none)
                Section("Службы") {
                    ForEach(groups) { g in
                        HStack(spacing: 8) {
                            Image(systemName: g.service.icon).foregroundStyle(Brand.blue).frame(width: 20)
                            Text(g.service.title).lineLimit(1)
                            Spacer()
                            Text("\(g.grantedCount)").monospacedDigit().foregroundStyle(.secondary)
                                .help("Разрешено приложений")
                        }
                        .tag(Optional(g.id))
                    }
                }
            }
            Divider()
            Toggle("Показывать запрещённые", isOn: $p.showDenied)
                .toggleStyle(.switch).controlSize(.small)
                .padding(10)
        }
    }

    private func entryList(_ groups: [ServiceGroup]) -> some View {
        Group {
            if groups.isEmpty {
                EmptyStateView(icon: "checkmark.shield", title: "Ничего не найдено",
                               text: state.permissions.search.isEmpty ? "Ни одно приложение не получало таких разрешений." : "Попробуйте другой запрос.") {}
            } else {
                List {
                    ForEach(groups) { g in
                        Section {
                            ForEach(g.entries) { e in EntryRow(entry: e) { resetEntry = e } }
                        } header: {
                            Label(g.service.title, systemImage: g.service.icon)
                        }
                    }
                }
            }
        }
    }
}

private struct EntryRow: View {
    @Environment(AppState.self) private var state
    let entry: TCCEntry
    let onReset: () -> Void

    var body: some View {
        let app = AppResolver.resolve(entry.client, isPath: entry.clientIsPath)
        HStack(spacing: 10) {
            AppIconView(url: app.url, size: 26)
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 6) {
                    Text(app.name).fontWeight(.medium).lineLimit(1)
                    if let t = entry.target {
                        let target = AppResolver.resolve(t, isPath: t.hasPrefix("/"))
                        Image(systemName: "arrow.right").font(.caption).foregroundStyle(.secondary)
                        AppIconView(url: target.url, size: 16)
                        Text(target.name).lineLimit(1).foregroundStyle(.secondary)
                    }
                }
                Text(entry.clientIsPath ? Paths.pretty(entry.client) : entry.client)
                    .font(.caption).foregroundStyle(.secondary).lineLimit(1).truncationMode(.middle)
            }
            Spacer()
            Pill(text: entry.auth.title, color: entry.auth.isGranted ? .green : .secondary)
            Text(Fmt.date(entry.modified)).font(.caption).foregroundStyle(.secondary).monospacedDigit()
                .frame(width: 92, alignment: .trailing)
                .help("Когда изменено разрешение")
            Button { FullDiskAccess.open(pane: entry.info.pane) } label: { Image(systemName: "gearshape") }
                .buttonStyle(.borderless)
                .help("Открыть в Настройках")
            Menu {
                Button("Открыть в Настройках") { FullDiskAccess.open(pane: entry.info.pane) }
                Button("Сбросить разрешение…", action: onReset)
                    .disabled(TCCReset.arguments(for: entry) == nil)
                if let u = app.url { Button("Показать в Finder") { Paths.reveal(u) } }
            } label: { Image(systemName: "ellipsis.circle") }
                .menuStyle(.borderlessButton).menuIndicator(.hidden).fixedSize()
        }
        .padding(.vertical, 2)
        .contextMenu {
            Button("Открыть в Настройках") { FullDiskAccess.open(pane: entry.info.pane) }
            Button("Сбросить разрешение…", action: onReset).disabled(TCCReset.arguments(for: entry) == nil)
        }
    }
}
