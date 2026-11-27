import SwiftUI

struct CallView: View {
    @Environment(AppState.self) private var state

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                if state.helpers.isEmpty {
                    Card {
                        EmptyStateView(icon: "person.crop.circle.badge.plus", title: "Кого звать на помощь?",
                                       text: "Добавьте того, кто обычно помогает с компьютером: сына, дочь, внука. Тогда позвонить или отправить отчёт — одна кнопка.") {
                            BigButton(title: "Добавить помощника", icon: "plus", prominent: true) { state.editing = Helper(name: "") }
                        }
                    }
                } else {
                    ForEach(state.helpers) { h in HelperCard(helper: h) }
                    Button { state.editing = Helper(name: "") } label: {
                        Label("Добавить ещё одного помощника", systemImage: "plus.circle")
                    }
                    .buttonStyle(.link)
                }
                ScreenShareCard()
            }
            .padding(20)
            .frame(maxWidth: 1000, alignment: .leading)
            .frame(maxWidth: .infinity)
        }
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                Button { state.editing = Helper(name: "") } label: { Label("Добавить помощника", systemImage: "person.badge.plus") }
                    .help("Добавить помощника")
            }
        }
    }
}

struct HelperCard: View {
    @Environment(AppState.self) private var state
    let helper: Helper
    @State private var confirmDelete = false

    var body: some View {
        let apple = helper.appleHandle
        let tg = helper.telegramName
        Card {
            VStack(alignment: .leading, spacing: 14) {
                HStack(spacing: 14) {
                    Text(helper.initials)
                        .font(.system(size: 24, weight: .bold, design: .rounded))
                        .foregroundStyle(.white)
                        .frame(width: 56, height: 56)
                        .background(Brand.gradient, in: Circle())
                    VStack(alignment: .leading, spacing: 3) {
                        Text(helper.name.isEmpty ? "Без имени" : helper.name).font(.title2.weight(.semibold))
                        Text(contacts).foregroundStyle(.secondary).lineLimit(1)
                    }
                    Spacer()
                    Menu {
                        Button("Изменить…") { state.editing = helper }
                        Button("Удалить…", role: .destructive) { confirmDelete = true }
                    } label: { Image(systemName: "ellipsis.circle").font(.title2) }
                    .menuStyle(.borderlessButton)
                    .menuIndicator(.hidden)
                    .fixedSize()
                }
                FlowRow {
                    BigButton(title: "Видеозвонок FaceTime", icon: "video.fill", prominent: true, disabled: apple == nil) {
                        state.faceTime(helper, audio: false)
                    }
                    BigButton(title: "Аудиозвонок", icon: "phone.fill", disabled: apple == nil) { state.faceTime(helper, audio: true) }
                    BigButton(title: "Написать", icon: "message.fill", disabled: apple == nil) { state.message(helper) }
                    if tg != nil {
                        BigButton(title: "Telegram", icon: "paperplane.fill") { state.telegram(helper) }
                    }
                    BigButton(title: "Отправить отчёт", icon: "doc.text.fill",
                              disabled: apple == nil && tg == nil && Contact.email(helper.email) == nil) { state.sendReport(to: helper) }
                }
                if apple == nil {
                    Text("Для FaceTime и Сообщений нужен телефон или e-mail Apple ID — нажмите ⋯ → «Изменить…».")
                        .font(.callout).foregroundStyle(.secondary)
                }
            }
        }
        .confirmationDialog("Удалить \(helper.name) из списка?", isPresented: $confirmDelete) {
            Button("Удалить", role: .destructive) { state.delete(helper) }
        }
    }

    private var contacts: String {
        var parts: [String] = []
        if !helper.phone.isEmpty { parts.append(helper.phone) }
        if !helper.email.isEmpty { parts.append(helper.email) }
        if let t = helper.telegramName { parts.append("@\(t)") }
        return parts.isEmpty ? "контакты не указаны" : parts.joined(separator: " · ")
    }
}

/// Кнопки в несколько строк, если не помещаются.
struct FlowRow: Layout {
    var spacing: CGFloat = 10

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let rows = arrange(width: proposal.width ?? .infinity, subviews: subviews)
        return CGSize(width: proposal.width ?? rows.map(\.width).max() ?? 0,
                      height: rows.map(\.height).reduce(0, +) + spacing * CGFloat(max(rows.count - 1, 0)))
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        var y = bounds.minY
        for row in arrange(width: bounds.width, subviews: subviews) {
            var x = bounds.minX
            for i in row.items {
                let s = subviews[i].sizeThatFits(.unspecified)
                subviews[i].place(at: CGPoint(x: x, y: y), proposal: ProposedViewSize(s))
                x += s.width + spacing
            }
            y += row.height + spacing
        }
    }

    private struct Row { var items: [Int] = []; var width: CGFloat = 0; var height: CGFloat = 0 }

    private func arrange(width: CGFloat, subviews: Subviews) -> [Row] {
        var rows: [Row] = [Row()]
        for (i, v) in subviews.enumerated() {
            let s = v.sizeThatFits(.unspecified)
            if !rows[rows.count - 1].items.isEmpty, rows[rows.count - 1].width + spacing + s.width > width { rows.append(Row()) }
            var r = rows[rows.count - 1]
            r.width += (r.items.isEmpty ? 0 : spacing) + s.width
            r.height = max(r.height, s.height)
            r.items.append(i)
            rows[rows.count - 1] = r
        }
        return rows
    }
}

struct ScreenShareCard: View {
    var body: some View {
        Card {
            VStack(alignment: .leading, spacing: 12) {
                SectionTitle(text: "Показать экран помощнику", icon: "rectangle.on.rectangle")
                Text("Помощник увидит ваш экран и подскажет, куда нажимать. Управлять Mac он сможет, только если вы разрешите.")
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                StepRow(n: 1, text: "Позвоните помощнику по **FaceTime** — кнопкой «Видеозвонок» выше.")
                StepRow(n: 2, text: "Когда он ответит, нажмите в строке меню вверху экрана зелёный значок **FaceTime** (камера).")
                StepRow(n: 3, text: "Выберите **«Поделиться экраном»** (квадрат с человечком) и щёлкните по экрану или окну, которое нужно показать.")
                StepRow(n: 4, text: "Чтобы перестать показывать — снова значок FaceTime → **«Остановить общий доступ»**.")
                HStack {
                    Button { SystemLinks.openApp(SystemLinks.faceTime) } label: { Label("Открыть FaceTime", systemImage: "video") }
                    Button { SystemLinks.openApp(SystemLinks.screenSharing) } label: { Label("Приложение «Общий экран»", systemImage: "rectangle.inset.filled.on.rectangle") }
                        .help("Помощник может сам подключиться к вашему экрану по Apple ID — вам придёт запрос, нажмите «Принять»")
                    Button { SystemLinks.settings(SystemLinks.sharing) } label: { Label("Настройки общего доступа", systemImage: "gearshape") }
                }
                .padding(.top, 4)
            }
        }
    }
}

// MARK: - Добавление и изменение помощника

struct HelperEditor: View {
    @Environment(AppState.self) private var state
    @Environment(\.dismiss) private var dismiss
    @State var helper: Helper

    var body: some View {
        let isNew = !state.helpers.contains { $0.id == helper.id }
        VStack(alignment: .leading, spacing: 16) {
            Text(isNew ? "Новый помощник" : "Изменить помощника").font(.title2.weight(.semibold))
            Form {
                TextField("Имя", text: $helper.name, prompt: Text("Например, Маша"))
                field("Телефон", text: $helper.phone, prompt: "+7 999 123-45-67",
                      hint: helper.phone.isEmpty || Contact.phone(helper.phone) != nil ? nil : "Похоже, это не номер телефона")
                field("E-mail (Apple ID)", text: $helper.email, prompt: "masha@icloud.com",
                      hint: helper.email.isEmpty || Contact.email(helper.email) != nil ? nil : "Проверьте адрес")
                field("Telegram", text: $helper.telegram, prompt: "@masha",
                      hint: helper.telegram.isEmpty || Contact.telegram(helper.telegram) != nil ? nil : "Имя в Telegram: латиница, цифры и _, от 4 знаков")
            }
            .formStyle(.grouped)
            Text("Телефон или e-mail нужен для FaceTime и Сообщений, Telegram — по желанию. Список хранится только на этом Mac.")
                .font(.callout).foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            HStack {
                Spacer()
                Button("Отмена", role: .cancel) { dismiss() }.keyboardShortcut(.cancelAction)
                Button(isNew ? "Добавить" : "Сохранить") {
                    helper.name = helper.name.trimmingCharacters(in: .whitespaces)
                    state.save(helper)
                    dismiss()
                }
                .keyboardShortcut(.defaultAction)
                .disabled(helper.name.trimmingCharacters(in: .whitespaces).isEmpty)
            }
        }
        .padding(20)
        .frame(width: 480)
    }

    private func field(_ title: String, text: Binding<String>, prompt: String, hint: String?) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            TextField(title, text: text, prompt: Text(prompt))
            if let hint { Text(hint).font(.caption).foregroundStyle(.orange) }
        }
    }
}
