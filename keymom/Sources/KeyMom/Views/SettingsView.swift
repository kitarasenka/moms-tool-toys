import SwiftUI

struct SettingsView: View {
    @Environment(AppState.self) private var state
    @State private var loginOn = LoginItem.enabled
    @State private var loginMessage: String?

    var body: some View {
        @Bindable var p = state.prefs
        Form {
            Section("Исправление раскладки") {
                Toggle("Исправлять по сочетанию клавиш в любом приложении",
                       isOn: Binding(get: { p.hotkeyEnabled }, set: { state.setHotkeyEnabled($0) }))
                Picker("Сочетание", selection: Binding(get: { p.hotkey }, set: { state.setHotkey($0) })) {
                    ForEach(HotkeyPreset.allCases) { Text($0.title).tag($0) }
                }
                .disabled(!p.hotkeyEnabled)
                if state.hotkeyFailed {
                    Text("Это сочетание уже занято другим приложением — выберите другое.")
                        .font(.caption).foregroundStyle(.orange)
                }
                Toggle("После исправления переключать раскладку", isOn: $p.switchLayout)
                Picker("Русская раскладка", selection: $p.variant) {
                    ForEach(VariantChoice.allCases) { Text($0.title).tag($0) }
                }
                Text(variantNote).font(.caption).foregroundStyle(.secondary)
            }

            Section("Разрешения") {
                HStack {
                    Image(systemName: state.axTrusted ? "checkmark.circle.fill" : "exclamationmark.triangle.fill")
                        .foregroundStyle(state.axTrusted ? .green : .orange)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(state.axTrusted ? String(localized: "Универсальный доступ разрешён") : String(localized: "Универсальный доступ не разрешён"))
                        Text("Нужен, чтобы заменять текст в других приложениях. После пересборки KeyMom разрешение иногда приходится выдать заново: выключите и снова включите KeyMom в списке.")
                            .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                    }
                    Spacer()
                    if !state.axTrusted { Button("Разрешить…") { state.askTrust() } }
                    Button("Открыть") { Accessibility.openSettings() }
                }
                LabeledContent("Буфер обмена (запасной способ)") {
                    HStack {
                        Text(state.pasteAccess.title).foregroundStyle(state.pasteAccess == .denied ? .orange : .secondary)
                        Button("Открыть") { PasteAccess.openSettings() }
                    }
                }
                Text("Где приложение не отдаёт текст напрямую (часть браузеров, Telegram, Slack), KeyMom копирует слово через буфер обмена и сразу возвращает в буфер то, что там было. Чтобы macOS не спрашивала каждый раз: «Вставка из других приложений» → KeyMom → «Разрешить».")
                    .font(.caption).foregroundStyle(.secondary)
            }

            Section("Индикатор раскладки") {
                Picker("В строке меню", selection: $p.indicator) {
                    ForEach(IndicatorStyle.allCases) { Text($0.title).tag($0) }
                }
                Toggle("Показывать «RU» / «EN» у курсора при смене раскладки", isOn: $p.layoutHUD)
                HStack {
                    Text("Включены: \(state.enabledNames)")
                        .font(.caption).foregroundStyle(.secondary)
                    Spacer()
                    Button("Настройки клавиатуры…") { InputSources.openSettings() }
                }
            }

            Section("Caps Lock") {
                Toggle("Подсказка у курсора, когда включаете Caps Lock", isOn: $p.capsHUD)
                Toggle("Предупреждать в поле пароля, если включён Caps Lock", isOn: $p.capsPasswordWarning)
            }

            Section("Приложение") {
                Toggle("Показывать значок в Dock", isOn: Binding(get: { p.showInDock }, set: { state.setShowInDock($0) }))
                if !p.showInDock {
                    Text("KeyMom живёт только в строке меню — окно открывается оттуда или повторным запуском.")
                        .font(.caption).foregroundStyle(.secondary)
                }
                Toggle("Запускать при входе в систему", isOn: Binding(get: { loginOn }, set: { on in
                    loginMessage = LoginItem.set(on)
                    loginOn = LoginItem.enabled
                }))
                .disabled(state.demo)
                LabeledContent("Автозапуск", value: LoginItem.statusText)
                if let m = loginMessage { Text(m).font(.caption).foregroundStyle(.orange) }
            }
        }
        .formStyle(.grouped)
    }

    private var variantNote: String {
        String(localized: "Сейчас используется «\(state.variant.title)». От неё зависит, где точка и запятая: в «ПК» они справа внизу (как на Windows), в варианте Apple — на Shift+6 и Shift+7.")
    }
}

extension AppState {
    var enabledNames: String {
        let names = InputSources.enabled().map(\.name).filter { !$0.isEmpty }
        return names.isEmpty ? "—" : names.joined(separator: ", ")
    }
}
