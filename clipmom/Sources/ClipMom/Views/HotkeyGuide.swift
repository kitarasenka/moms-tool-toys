import SwiftUI

/// «Как вызвать ClipMom»: картинка быстрой панели поверх чужого окна и короткая инструкция.
/// Показывается справа, пока ничего не выбрано, в справке (меню «Справка», строка меню) и в настройках.
struct HotkeyGuide: View {
    @Environment(AppState.self) private var state
    var showActions = true

    var body: some View {
        let prefs = state.prefs
        VStack(alignment: .leading, spacing: 16) {
            VStack(alignment: .leading, spacing: 4) {
                Text("Быстрая панель — поверх любого приложения").font(.title3.weight(.semibold))
                Text("Не нужно открывать окно ClipMom: история вызывается там, где вы сейчас печатаете.")
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            QuickPanelIllustration()
                .frame(maxWidth: .infinity)

            VStack(alignment: .leading, spacing: 10) {
                step(1, "Нажмите **⇧⌘V** в любом приложении — браузере, почте, Word, мессенджере. Панель появится у курсора.")
                step(2, "Начните печатать, чтобы найти нужное. **↑ ↓** — выбрать, **⌘1…⌘9** — сразу одна из первых девяти записей.")
                step(3, prefs.autoPaste
                     ? "**↩** — ClipMom сам вставит выбранное туда, где вы были. **Esc** — закрыть."
                     : "**↩** — запись вернётся в буфер обмена, остаётся нажать **⌘V**. **Esc** — закрыть.")
                step(4, "Значок \(Image(systemName: "list.clipboard")) в строке меню вверху экрана — последние 10 записей в один щелчок, даже когда окно закрыто.")
            }

            if !prefs.hotkeyEnabled {
                warning("Сочетание ⇧⌘V выключено — включите его в настройках.")
            } else if state.hotkeyFailed {
                warning("Сочетание ⇧⌘V занято другим приложением — панель открывается из строки меню.")
            }

            if showActions {
                HStack {
                    Button {
                        state.showGuide = false
                        DispatchQueue.main.async { state.panel?.show() }
                    } label: {
                        Label("Попробовать", systemImage: "rectangle.and.text.magnifyingglass")
                    }
                    .buttonStyle(.borderedProminent)
                    .tint(Brand.blue)
                    Button("Настройки…") {
                        // Один лист закрывается, другой открывается следом — не в том же такте.
                        let wasSheet = state.showGuide
                        state.showGuide = false
                        DispatchQueue.main.asyncAfter(deadline: .now() + (wasSheet ? 0.35 : 0)) { state.showSettings = true }
                    }
                }
            }
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

    private func warning(_ text: LocalizedStringKey) -> some View {
        Label(text, systemImage: "exclamationmark.triangle.fill")
            .font(.callout)
            .foregroundStyle(.orange)
    }
}

/// Справка отдельным листом (меню «Справка», строка меню).
struct GuideSheet: View {
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(spacing: 0) {
            ScrollView { HotkeyGuide().padding(22) }
            Divider()
            HStack {
                Spacer()
                Button("Готово") { dismiss() }.keyboardShortcut(.defaultAction)
            }
            .padding(12)
        }
        .frame(width: 500, height: 600)
    }
}

/// Рисунок: окно какого-то приложения, поверх — быстрая панель ClipMom, внизу — клавиши ⇧ ⌘ V.
struct QuickPanelIllustration: View {
    private let rows: [(icon: String, title: String)] = [
        ("text.alignleft", String(localized: "Адрес доставки: ул. Лесная, 5")),
        ("link", "maps.apple.com/?q=…"),
        ("photo", String(localized: "Снимок экрана")),
        ("doc", String(localized: "Отчёт за ноябрь.pdf")),
    ]

    var body: some View {
        ZStack(alignment: .topLeading) {
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .fill(LinearGradient(colors: [Brand.cyan.opacity(0.28), Brand.blue.opacity(0.38)],
                                     startPoint: .topLeading, endPoint: .bottomTrailing))
            appWindow
                .frame(width: 236, height: 148)
                .offset(x: 18, y: 18)
            panel
                .frame(width: 214)
                .offset(x: 168, y: 54)
            HStack(spacing: 6) {
                Keycap("⇧")
                Keycap("⌘")
                Keycap("V")
                Text("из любого приложения")
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(.white)
                    .shadow(color: .black.opacity(0.25), radius: 1, y: 1)
                    .padding(.leading, 4)
            }
            .offset(x: 18, y: 180)
        }
        .frame(width: 400, height: 228)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Быстрая панель ClipMom поверх окна другого приложения, открывается сочетанием Shift Command V")
    }

    /// Окно «чужого» приложения: заголовок, строки текста, курсор.
    private var appWindow: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 5) {
                ForEach([Color.red, .yellow, .green], id: \.self) { c in
                    Circle().fill(c.opacity(0.85)).frame(width: 8, height: 8)
                }
                Spacer()
            }
            .padding(.horizontal, 9)
            .frame(height: 20)
            .background(Color(nsColor: .windowBackgroundColor))
            Divider()
            VStack(alignment: .leading, spacing: 8) {
                line(150)
                line(190)
                line(120)
                HStack(spacing: 1) {
                    Text("Привезите, пожалуйста, на").font(.system(size: 9)).foregroundStyle(.secondary)
                    Rectangle().fill(Brand.blue).frame(width: 1.5, height: 11)
                }
            }
            .padding(12)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            .background(Color(nsColor: .textBackgroundColor))
        }
        .clipShape(RoundedRectangle(cornerRadius: 9, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 9, style: .continuous).strokeBorder(.separator))
        .shadow(color: .black.opacity(0.15), radius: 6, y: 3)
    }

    private func line(_ w: CGFloat) -> some View {
        RoundedRectangle(cornerRadius: 2).fill(.quaternary).frame(width: w, height: 6)
    }

    /// Уменьшенная копия настоящей панели ⇧⌘V.
    private var panel: some View {
        VStack(spacing: 0) {
            HStack(spacing: 5) {
                Image(systemName: "magnifyingglass").font(.system(size: 9)).foregroundStyle(.secondary)
                Text("Поиск в истории").font(.system(size: 10)).foregroundStyle(.tertiary)
                Spacer()
                Text("⇧⌘V").font(.system(size: 8).monospaced()).foregroundStyle(.tertiary)
            }
            .padding(.horizontal, 9)
            .frame(height: 24)
            Divider()
            VStack(spacing: 1) {
                ForEach(Array(rows.enumerated()), id: \.offset) { i, r in
                    let selected = i == 0
                    HStack(spacing: 6) {
                        ZStack {
                            RoundedRectangle(cornerRadius: 4, style: .continuous).fill(Brand.gradient)
                            Image(systemName: r.icon).font(.system(size: 7, weight: .semibold)).foregroundStyle(.white)
                        }
                        .frame(width: 16, height: 16)
                        .overlay {
                            if selected {
                                RoundedRectangle(cornerRadius: 4, style: .continuous).strokeBorder(.white.opacity(0.6))
                            }
                        }
                        Text(r.title).font(.system(size: 9.5)).lineLimit(1)
                            .foregroundStyle(selected ? .white : .primary)
                        Spacer(minLength: 2)
                        Text("⌘\(i + 1)").font(.system(size: 8).monospaced())
                            .foregroundStyle(selected ? AnyShapeStyle(.white.opacity(0.85)) : AnyShapeStyle(.tertiary))
                    }
                    .padding(.horizontal, 6)
                    .frame(height: 22)
                    .background {
                        if selected { RoundedRectangle(cornerRadius: 5, style: .continuous).fill(Brand.gradient) }
                    }
                }
            }
            .padding(4)
        }
        .background(.regularMaterial)
        .background(Color(nsColor: .windowBackgroundColor).opacity(0.6))
        .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 10, style: .continuous).strokeBorder(.separator))
        .shadow(color: .black.opacity(0.28), radius: 12, y: 6)
    }
}

private struct Keycap: View {
    let key: String
    init(_ key: String) { self.key = key }

    var body: some View {
        Text(key)
            .font(.system(size: 15, weight: .semibold))
            .frame(width: 32, height: 30)
            .background(Color(nsColor: .controlBackgroundColor), in: RoundedRectangle(cornerRadius: 7, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: 7, style: .continuous).strokeBorder(.separator))
            .shadow(color: .black.opacity(0.22), radius: 0, y: 2)
    }
}
