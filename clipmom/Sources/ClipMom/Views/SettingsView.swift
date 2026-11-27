import AppKit
import SwiftUI
import UniformTypeIdentifiers

struct SettingsView: View {
    @Environment(AppState.self) private var state
    @Environment(\.dismiss) private var dismiss
    @State private var loginOn = LoginItem.enabled
    @State private var loginMessage: String?
    @State private var axTrusted = AutoPaste.trusted
    @State private var confirmClear = false
    @State private var newBundleID = ""

    var body: some View {
        let prefs = state.prefs
        @Bindable var p = prefs
        VStack(spacing: 0) {
            HStack {
                Image(systemName: "gearshape.fill").foregroundStyle(Brand.gradient)
                Text("Настройки ClipMom").font(.title3.weight(.semibold))
                Spacer()
            }
            .padding(16)
            Divider()
            Form {
                Section("Запись") {
                    Toggle("Записывать буфер обмена", isOn: Binding(get: { state.isRecording }, set: { _ in state.togglePause() }))
                    Picker("Хранить записей", selection: $p.maxCount) {
                        ForEach([50, 100, 300, 500, 1000], id: \.self) { Text("\($0)").tag($0) }
                    }
                    Picker("Хранить дней", selection: $p.maxDays) {
                        ForEach([1, 7, 30, 90, 365], id: \.self) { Text("\($0)").tag($0) }
                    }
                    Text("Закреплённые записи хранятся всегда. Не записываются: текст больше 1 МБ, картинки больше 20 МБ, пароли и данные, помеченные приложением как скрытые или временные.")
                        .font(.caption).foregroundStyle(.secondary)
                }
                Section("Доступ к буферу обмена") {
                    LabeledContent("Состояние", value: state.access.title)
                    HStack {
                        Text("«Конфиденциальность и безопасность → Вставка из других приложений» → ClipMom → «Разрешить».")
                            .font(.caption).foregroundStyle(.secondary)
                        Spacer()
                        Button("Открыть") { PasteAccess.openSettings() }
                    }
                }
                Section("Быстрая панель") {
                    QuickPanelIllustration()
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 4)
                    Toggle("Открывать по ⇧⌘V из любого приложения",
                           isOn: Binding(get: { p.hotkeyEnabled }, set: { state.setHotkey($0) }))
                    if state.hotkeyFailed {
                        Text("Сочетание ⇧⌘V уже занято другим приложением.").font(.caption).foregroundStyle(.orange)
                    }
                    Toggle("Вставлять сразу", isOn: Binding(get: { p.autoPaste }, set: { state.setAutoPaste($0); axTrusted = AutoPaste.trusted }))
                    if p.autoPaste {
                        HStack {
                            Image(systemName: axTrusted ? "checkmark.circle.fill" : "exclamationmark.triangle.fill")
                                .foregroundStyle(axTrusted ? .green : .orange)
                            Text(axTrusted ? LocalizedStringKey("Универсальный доступ разрешён — выбранное вставится в приложение, где вы были.")
                                           : "Нужен «Универсальный доступ» для ClipMom, иначе запись только копируется.")
                                .font(.caption).foregroundStyle(.secondary)
                            Spacer()
                            if !axTrusted { Button("Открыть") { AutoPaste.openSettings() } }
                        }
                    }
                }
                Section("Строка меню и Dock") {
                    Toggle("Показывать значок в Dock", isOn: Binding(get: { p.showInDock }, set: { state.setShowInDock($0) }))
                    Group {
                        if p.showInDock {
                            Text("Выключите, чтобы ClipMom жил только в строке меню вверху экрана (значок \(Image(systemName: "list.clipboard"))) и не занимал место в Dock.")
                        } else {
                            Text("ClipMom живёт в строке меню вверху экрана: значок \(Image(systemName: "list.clipboard")) → «Открыть ClipMom», «Настройки…». Быстрая панель — ⇧⌘V.")
                        }
                    }
                    .font(.caption).foregroundStyle(.secondary)
                }
                Section("Автозапуск") {
                    Toggle("Запускать ClipMom при входе в систему", isOn: Binding(get: { loginOn }, set: { on in
                        loginMessage = LoginItem.set(on)
                        loginOn = LoginItem.enabled
                    }))
                    LabeledContent("Состояние", value: LoginItem.statusText)
                    if let m = loginMessage { Text(m).font(.caption).foregroundStyle(.orange) }
                }
                Section {
                    ForEach(p.excluded) { app in
                        HStack {
                            appIcon(app.bundleID)
                            VStack(alignment: .leading, spacing: 1) {
                                Text(app.name)
                                Text(app.bundleID).font(.caption).foregroundStyle(.secondary)
                            }
                            Spacer()
                            Button { p.excluded.removeAll { $0.id == app.id } } label: { Image(systemName: "minus.circle") }
                                .buttonStyle(.borderless)
                                .help("Убрать из списка")
                        }
                    }
                    HStack {
                        Button("Добавить приложение…") { pickApp() }
                        TextField("", text: $newBundleID, prompt: Text("или bundle id"))
                            .onSubmit(addBundleID)
                        Button("Вернуть по умолчанию") { p.excluded = ExcludedApp.defaults }
                    }
                } header: {
                    Text("Не записывать из приложений")
                } footer: {
                    Text("Что скопировано в этих приложениях, ClipMom даже не читает.").font(.caption).foregroundStyle(.secondary)
                }
                Section("Хранилище") {
                    LabeledContent("Папка", value: state.demo ? String(localized: "временная (демо)") : "~/Library/Application Support/ClipMom")
                    HStack {
                        Button("Показать в Finder") { NSWorkspace.shared.activateFileViewerSelecting([state.store.historyURL]) }
                        Spacer()
                        Button("Очистить историю…", role: .destructive) { confirmClear = true }
                    }
                    Text("Всё хранится только на этом Mac, в сеть ничего не отправляется.").font(.caption).foregroundStyle(.secondary)
                }
            }
            .formStyle(.grouped)
            Divider()
            HStack {
                Spacer()
                Button("Готово") { dismiss() }.keyboardShortcut(.defaultAction)
            }
            .padding(12)
        }
        .frame(width: 560, height: 640)
        .onChange(of: p.maxCount) { state.applyLimits() }
        .onChange(of: p.maxDays) { state.applyLimits() }
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
            axTrusted = AutoPaste.trusted
            loginOn = LoginItem.enabled
        }
        .confirmationDialog("Очистить историю?", isPresented: $confirmClear) {
            Button("Удалить всё, кроме закреплённых", role: .destructive) { state.clear(keepPinned: true) }
            Button("Удалить всё, включая закреплённые", role: .destructive) { state.clear(keepPinned: false) }
            Button("Отменить", role: .cancel) {}
        } message: {
            Text("Записи и картинки удалятся с диска без возможности восстановления.")
        }
    }

    @ViewBuilder private func appIcon(_ id: String) -> some View {
        if let img = AppIcons.icon(for: id) {
            Image(nsImage: img).resizable().frame(width: 22, height: 22)
        } else {
            Image(systemName: "app.dashed").font(.title3).foregroundStyle(.secondary).frame(width: 22, height: 22)
        }
    }

    private func pickApp() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.application]
        panel.directoryURL = URL(fileURLWithPath: "/Applications")
        panel.allowsMultipleSelection = true
        panel.prompt = String(localized: "Добавить")
        guard panel.runModal() == .OK else { return }
        for url in panel.urls {
            if let app = AppIcons.appInfo(at: url), state.prefs.isExcluded(app.bundleID) == nil {
                state.prefs.excluded.append(app)
            }
        }
    }

    private func addBundleID() {
        let id = newBundleID.trimmingCharacters(in: .whitespaces)
        guard !id.isEmpty, state.prefs.isExcluded(id) == nil else { return }
        let name = NSWorkspace.shared.urlForApplication(withBundleIdentifier: id).flatMap(AppIcons.appInfo(at:))?.name ?? id
        state.prefs.excluded.append(ExcludedApp(bundleID: id, name: name))
        newBundleID = ""
    }
}
