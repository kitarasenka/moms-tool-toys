import SwiftUI

/// «Как пользоваться»: картинка «было → сочетание → стало», шаги, поле «Попробуйте», про индикатор и Caps Lock.
struct GuideView: View {
    @Environment(AppState.self) private var state
    @FocusState private var tryFocused: Bool

    var body: some View {
        @Bindable var state = state
        let preset = state.prefs.hotkey
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                PermissionCard()

                VStack(alignment: .leading, spacing: 4) {
                    Text("Напечатали не в той раскладке? Не стирайте!").font(.title2.weight(.semibold))
                    Text("KeyMom переделает «ghbdtn» в «привет» (и «руддщ» в «hello») одним нажатием — в любом приложении.")
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }

                FixIllustration(preset: preset, variant: state.variant).frame(maxWidth: .infinity)

                VStack(alignment: .leading, spacing: 10) {
                    step(1, "Заметили абракадабру — сразу нажмите **\(preset.title)**. Курсор должен стоять сразу после неправильного слова.")
                    step(2, "Исправится **последнее слово**. Нужно несколько слов или целая фраза — сначала выделите их мышкой, потом нажмите сочетание.")
                    step(3, "Раскладка сама переключится на нужный язык — можно печатать дальше. Нажмёте сочетание ещё раз — слово вернётся как было.")
                }

                Card {
                    VStack(alignment: .leading, spacing: 10) {
                        Label("Попробуйте здесь", systemImage: "hand.point.right.fill").font(.headline)
                        HStack {
                            TextField("Напечатайте «ghbdtn» и нажмите \(preset.title)", text: $state.tryText)
                                .textFieldStyle(.roundedBorder)
                                .font(.system(size: 16))
                                .focused($tryFocused)
                                .onSubmit { state.fixTryField() }
                            Button("Исправить") { state.fixTryField() }
                                .buttonStyle(.borderedProminent).tint(Brand.blue)
                                .disabled(state.tryText.isEmpty)
                        }
                        if let f = state.lastFix {
                            Label(f, systemImage: "checkmark.circle.fill").font(.callout).foregroundStyle(.green).lineLimit(2)
                        }
                    }
                }

                HStack(alignment: .top, spacing: 14) {
                    Card {
                        VStack(alignment: .leading, spacing: 8) {
                            Label("Какой сейчас язык", systemImage: "menubar.rectangle").font(.headline)
                            MenuBarIllustration(code: state.current?.code ?? "RU", caps: false)
                            Text("Вверху экрана, в строке меню, всегда видно текущую раскладку. При переключении у курсора на миг появляется «RU» или «EN».")
                                .font(.callout).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                        }
                    }
                    Card {
                        VStack(alignment: .leading, spacing: 8) {
                            Label("Caps Lock", systemImage: "capslock.fill").font(.headline)
                            MenuBarIllustration(code: state.current?.code ?? "RU", caps: true)
                            Text("Если нечаянно нажали ⇪, KeyMom подскажет. А в поле пароля покажет заметное предупреждение — чтобы пароль не «перестал подходить».")
                                .font(.callout).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                        }
                    }
                }

                if !state.prefs.hotkeyEnabled {
                    Label("Сочетание выключено — включите его в настройках.", systemImage: "exclamationmark.triangle.fill")
                        .foregroundStyle(.orange)
                } else if state.hotkeyFailed {
                    Label("Сочетание \(preset.title) занято другим приложением — выберите другое в настройках.",
                          systemImage: "exclamationmark.triangle.fill")
                        .foregroundStyle(.orange)
                }
            }
            .padding(24)
            .frame(maxWidth: 760, alignment: .leading)
            .frame(maxWidth: .infinity)
        }
    }

    private func step(_ n: Int, _ text: LocalizedStringKey) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 10) {
            Text("\(n)")
                .font(.caption.weight(.bold))
                .foregroundStyle(.white)
                .frame(width: 20, height: 20)
                .background(Brand.gradient, in: Circle())
                .alignmentGuide(.firstTextBaseline) { $0[VerticalAlignment.center] + 4 }
            Text(text).fixedSize(horizontal: false, vertical: true)
        }
    }
}

/// Картинка: поле с «Ghbdtn? rfr ltkf&» → клавиши → поле с «Привет, как дела?».
struct FixIllustration: View {
    let preset: HotkeyPreset
    var variant: RussianVariant = .pc

    var body: some View {
        VStack(spacing: 14) {
            HStack(spacing: 12) {
                // Знаки препинания зависят от русской раскладки — показываем так, как будет у этого пользователя.
                fakeField(LayoutConverter.convert("Привет, как дела?", direction: .toEnglish, variant: variant), wrong: true)
                Image(systemName: "arrow.right").font(.title2.weight(.semibold)).foregroundStyle(Brand.blue)
                fakeField("Привет, как дела?", wrong: false)
            }
            HStack(spacing: 10) {
                Text("нажмите").font(.callout).foregroundStyle(.secondary)
                HotkeyKeys(preset: preset, size: 0.85)
            }
        }
        .padding(18)
        .background(Brand.cyan.opacity(0.08), in: RoundedRectangle(cornerRadius: 16, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 16, style: .continuous).strokeBorder(Brand.blue.opacity(0.2)))
    }

    private func fakeField(_ text: String, wrong: Bool) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 5) {
                Circle().fill(.red.opacity(0.8)).frame(width: 7)
                Circle().fill(.yellow.opacity(0.9)).frame(width: 7)
                Circle().fill(.green.opacity(0.8)).frame(width: 7)
                Spacer()
                Text(wrong ? "EN" : "RU").font(.caption2.weight(.bold)).foregroundStyle(.secondary)
            }
            HStack(spacing: 1) {
                Text(text)
                    .font(.system(size: 17))
                    .underline(wrong, pattern: .dot, color: .red)
                Rectangle().fill(Brand.blue).frame(width: 2, height: 20)
                Spacer(minLength: 0)
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 6)
            .background(.background, in: RoundedRectangle(cornerRadius: 6))
            .overlay(RoundedRectangle(cornerRadius: 6).strokeBorder(wrong ? Color.red.opacity(0.5) : Color.green.opacity(0.6)))
        }
        .padding(10)
        .frame(maxWidth: 260)
        .background(.background.secondary, in: RoundedRectangle(cornerRadius: 10, style: .continuous))
        .shadow(color: .black.opacity(0.1), radius: 4, y: 2)
    }
}

/// Кусочек строки меню с индикатором KeyMom.
struct MenuBarIllustration: View {
    let code: String
    let caps: Bool

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: "wifi")
            Image(systemName: "battery.75percent")
            Text(caps ? "\(code) ⇪" : code)
                .font(.system(size: 12, weight: .bold, design: .rounded))
                .padding(.horizontal, 6).padding(.vertical, 2)
                .background(caps ? Color.orange.opacity(0.35) : Brand.cyan.opacity(0.3), in: RoundedRectangle(cornerRadius: 4))
            Text("Чт 10:30").font(.system(size: 12))
        }
        .font(.system(size: 12))
        .padding(.horizontal, 10).padding(.vertical, 5)
        .frame(maxWidth: .infinity, alignment: .trailing)
        .background(.background, in: RoundedRectangle(cornerRadius: 6))
        .overlay(RoundedRectangle(cornerRadius: 6).strokeBorder(.separator))
    }
}
