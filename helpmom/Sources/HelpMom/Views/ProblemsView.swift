import SwiftUI

/// Шпаргалки простым языком: шаги + кнопки, которые сразу открывают нужное.
struct Problem: Identifiable {
    enum Action: Hashable {
        case tool(SiblingTool)
        case settings(String, String)   // pane, подпись
        case app(String, String)        // путь, подпись
        case forceQuit
        case restart
        case callHelp
    }

    let id: String
    let icon: String
    let tint: Color
    let title: String
    let steps: [String]
    let actions: [Action]

    static let all: [Problem] = [
        Problem(id: "internet", icon: "wifi.exclamationmark", tint: .blue, title: "Не работает интернет", steps: [
            "Посмотрите на значок Wi-Fi вверху справа: если он пустой — щёлкните и выберите свою сеть.",
            "Выключите и снова включите Wi-Fi в том же меню.",
            "Перезагрузите роутер: выньте вилку из розетки, подождите 30 секунд, включите и подождите 2–3 минуты.",
            "Не помогло — в WifiMom видно, виноват Wi-Fi дома или провайдер.",
        ], actions: [.tool(.wifi), .settings(SystemLinks.wifi, "Настройки Wi-Fi")]),
        Problem(id: "slow", icon: "tortoise", tint: .orange, title: "Mac тормозит", steps: [
            "Закройте приложения, которыми не пользуетесь: ⌘Q в каждом.",
            "В браузере закройте лишние вкладки — каждая ест память.",
            "Перезагрузите Mac, если давно этого не делали.",
            "Посмотрите, кто грузит Mac, в PerfMom или «Мониторинге системы».",
        ], actions: [.tool(.perf), .app(SystemLinks.activityMonitor, "Мониторинг системы"), .restart]),
        Problem(id: "space", icon: "externaldrive.badge.exclamationmark", tint: .purple, title: "Мало места на диске", steps: [
            "Очистите Корзину: правый щелчок по Корзине в Dock → «Очистить Корзину».",
            "Загляните в «Загрузки»: старые установщики (.dmg) и скачанные видео можно удалить.",
            "CleanerMom уберёт кэши и мусор одной кнопкой, DiskMom покажет, что занимает место.",
        ], actions: [.tool(.cleaner), .tool(.disk), .tool(.desktop), .settings(SystemLinks.storage, "Хранилище")]),
        Problem(id: "scam", icon: "exclamationmark.shield", tint: .red, title: "Окна «ваш Mac заражён!»", steps: [
            "**Не звоните** по номерам из таких окон и **ничего не скачивайте** — это мошенники.",
            "Закройте вкладку ⌘W. Если не закрывается — завершите браузер принудительно (кнопка ниже).",
            "Если такие уведомления всплывают сами — какой-то сайт получил разрешение на уведомления. Отключите его в настройках уведомлений или в SafetyMom.",
            "Если что-то уже установили или сообщили пароль — сразу позовите помощника.",
        ], actions: [.forceQuit, .tool(.safety), .settings(SystemLinks.notifications, "Уведомления"), .callHelp]),
        Problem(id: "layout", icon: "keyboard", tint: .teal, title: "Пишет не теми буквами", steps: [
            "Переключить язык: **Control + Пробел** или клавиша 🌐 (Fn) внизу слева.",
            "Флажок или буквы вверху справа показывают текущий язык.",
            "Если пропал русский — в настройках клавиатуры: «Источники ввода» → «Изменить…» → «+» → Русская.",
            "БОЛЬШИЕ БУКВЫ — выключите Caps Lock (клавиша с лампочкой слева).",
            "KeyMom умеет исправлять текст, набранный не в той раскладке.",
        ], actions: [.tool(.key), .settings(SystemLinks.keyboard, "Настройки клавиатуры")]),
        Problem(id: "frozen", icon: "hourglass", tint: .indigo, title: "Приложение зависло", steps: [
            "Подождите минуту — иногда оно просто занято.",
            "Нажмите **⌥ Option + ⌘ Command + Esc**, выберите зависшее приложение и «Завершить принудительно».",
            "Или нажмите кнопку ниже — HelpMom покажет список приложений.",
            "Несохранённое в этом приложении может пропасть.",
        ], actions: [.forceQuit]),
        Problem(id: "screenshot", icon: "camera.viewfinder", tint: .green, title: "Как сделать снимок экрана", steps: [
            "**⇧ Shift + ⌘ Command + 3** — весь экран.",
            "**⇧ Shift + ⌘ Command + 4** — выделите мышью нужный кусок.",
            "**⇧ Shift + ⌘ Command + 5** — панель со всеми вариантами и записью видео.",
            "Снимок появится на Рабочем столе — его можно отправить помощнику.",
        ], actions: [.app(SystemLinks.screenshot, "Снимок экрана")]),
        Problem(id: "restart", icon: "power", tint: .gray, title: "Перезагрузить Mac", steps: [
            "Сохраните открытые документы.",
            "Меню  (яблоко вверху слева) → «Перезагрузить…» → «Перезагрузить».",
            "Если Mac совсем не отвечает — держите кнопку питания 10 секунд, потом включите снова.",
        ], actions: [.restart]),
    ]
}

struct ProblemsView: View {
    @Environment(AppState.self) private var state
    @State private var showForceQuit = false
    @State private var confirmRestart = false

    var body: some View {
        ScrollView {
            LazyVGrid(columns: [GridItem(.adaptive(minimum: 360), spacing: 14, alignment: .top)], spacing: 14) {
                ForEach(Problem.all) { p in card(p) }
            }
            .padding(20)
        }
        .sheet(isPresented: $showForceQuit) { ForceQuitSheet().environment(state) }
        .confirmationDialog("Перезагрузить Mac?", isPresented: $confirmRestart) {
            Button("Показать окно перезагрузки") {
                if state.demo { state.show("В демо Mac не перезагружается") } else { SystemLinks.showRestartDialog() }
            }
        } message: {
            Text("macOS ещё раз спросит и предложит сохранить документы.")
        }
    }

    private func card(_ p: Problem) -> some View {
        Card {
            VStack(alignment: .leading, spacing: 10) {
                HStack(spacing: 10) {
                    Image(systemName: p.icon)
                        .font(.title2)
                        .foregroundStyle(.white)
                        .frame(width: 40, height: 40)
                        .background(p.tint.gradient, in: RoundedRectangle(cornerRadius: 10, style: .continuous))
                    Text(p.title).font(.title3.weight(.semibold))
                }
                ForEach(Array(p.steps.enumerated()), id: \.offset) { i, s in StepRow(n: i + 1, text: s) }
                FlowRow(spacing: 8) {
                    ForEach(p.actions, id: \.self) { a in button(a) }
                }
                .padding(.top, 4)
            }
        }
    }

    @ViewBuilder
    private func button(_ a: Problem.Action) -> some View {
        switch a {
        case .tool(let t):
            ToolButton(tool: t)
        case .settings(let pane, let title):
            Button { SystemLinks.settings(pane) } label: { Label(title, systemImage: "gearshape") }
        case .app(let path, let title):
            Button { SystemLinks.openApp(path) } label: { Label(title, systemImage: "arrow.up.forward.app") }
        case .forceQuit:
            Button { showForceQuit = true } label: { Label("Завершить зависшее…", systemImage: "xmark.octagon") }
        case .restart:
            Button { confirmRestart = true } label: { Label("Перезагрузить…", systemImage: "arrow.clockwise.circle") }
        case .callHelp:
            Button { state.section = .call } label: { Label("Позвать на помощь", systemImage: "person.2.wave.2") }
                .tint(Brand.blue)
                .buttonStyle(.borderedProminent)
        }
    }
}

/// Своё окно «Принудительно завершить»: обычные приложения пользователя, по одному.
struct ForceQuitSheet: View {
    @Environment(AppState.self) private var state
    @Environment(\.dismiss) private var dismiss
    @State private var target: AppState.RunningApp?
    @State private var tick = 0

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Какое приложение зависло?").font(.title2.weight(.semibold))
            Text("Приложение закроется сразу, без вопроса о сохранении. Несохранённое в нём пропадёт.")
                .foregroundStyle(.secondary)
            let apps = state.runningApps
            List(apps) { a in
                HStack(spacing: 10) {
                    if let icon = a.icon { Image(nsImage: icon).resizable().frame(width: 28, height: 28) }
                    Text(a.name).font(.title3)
                    Spacer()
                    Button("Завершить") { target = a }
                }
                .padding(.vertical, 2)
            }
            .id(tick)
            .frame(height: 320)
            HStack {
                Spacer()
                Button("Готово") { dismiss() }.keyboardShortcut(.defaultAction)
            }
        }
        .padding(20)
        .frame(width: 480)
        .confirmationDialog("Принудительно завершить «\(target?.name ?? "")»?",
                            isPresented: Binding(get: { target != nil }, set: { if !$0 { target = nil } })) {
            Button("Завершить принудительно", role: .destructive) {
                if let t = target { state.forceQuit(t) }
                target = nil
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { tick += 1 }
            }
        }
    }
}
