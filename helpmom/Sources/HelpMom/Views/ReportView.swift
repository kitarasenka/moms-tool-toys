import SwiftUI

struct ReportView: View {
    @Environment(AppState.self) private var state

    var body: some View {
        if let r = state.report {
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    VerdictCard(report: r)
                    actions
                    InfoGrid(report: r)
                    HStack(alignment: .top, spacing: 16) {
                        ProcessesCard(report: r)
                        CrashesCard(report: r)
                    }
                    preview
                }
                .padding(20)
                .frame(maxWidth: 1000, alignment: .leading)
                .frame(maxWidth: .infinity)
            }
        } else {
            VStack(spacing: 12) {
                ProgressView().controlSize(.large)
                Text("Проверяю Mac…").font(.title3)
                Text("Это займёт пару секунд").foregroundStyle(.secondary)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }

    private var actions: some View {
        @Bindable var state = state
        return VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 10) {
                BigButton(title: "Скопировать отчёт", icon: "doc.on.doc", prominent: true) { state.copyReport() }
                    .keyboardShortcut("c", modifiers: [.command, .shift])
                BigButton(title: "Сохранить на Рабочий стол", icon: "square.and.arrow.down") { state.saveReportToDesktop() }
                ShareLink(item: state.reportText, subject: Text("Отчёт о моём Mac")) {
                    Label("Отправить…", systemImage: "square.and.arrow.up")
                        .font(.body.weight(.medium))
                        .padding(.horizontal, 6).padding(.vertical, 4)
                }
                .controlSize(.large)
                .buttonStyle(.bordered)
                Spacer(minLength: 0)
                Button { state.refresh() } label: {
                    if state.collecting { ProgressView().controlSize(.small) } else { Label("Обновить", systemImage: "arrow.clockwise") }
                }
                .controlSize(.large)
                .help("Проверить Mac ещё раз (⌘R)")
            }
            Toggle("Добавить серийный номер (нужен в сервисе Apple; посторонним не отправляйте)", isOn: $state.includeSerial)
                .toggleStyle(.checkbox)
                .foregroundStyle(.secondary)
        }
    }

    private var preview: some View {
        Card {
            VStack(alignment: .leading, spacing: 8) {
                SectionTitle(text: "Так отчёт увидит помощник", icon: "text.bubble")
                Text(state.reportText)
                    .font(.system(.callout, design: .monospaced))
                    .textSelection(.enabled)
                    .fixedSize(horizontal: false, vertical: true)
                Text("Отчёт никуда не отправляется сам — только когда вы нажмёте «Скопировать» или «Отправить».")
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
    }
}

/// «Светофор»: итог крупно и что с этим делать.
struct VerdictCard: View {
    let report: SystemReport

    var body: some View {
        let level = report.overall
        Card(tint: level.color) {
            VStack(alignment: .leading, spacing: 12) {
                HStack(spacing: 14) {
                    TrafficLight(level: level)
                    VStack(alignment: .leading, spacing: 3) {
                        Text(report.headline).font(.system(size: 26, weight: .bold, design: .rounded))
                        Text(subtitle).foregroundStyle(.secondary)
                    }
                }
                if !report.findings.isEmpty {
                    Divider()
                    ForEach(report.findings) { f in
                        HStack(alignment: .firstTextBaseline, spacing: 10) {
                            Image(systemName: f.level.symbol).foregroundStyle(f.level.color)
                            VStack(alignment: .leading, spacing: 2) {
                                Text(f.title).font(.body.weight(.semibold))
                                Text(f.advice).font(.callout).foregroundStyle(.secondary)
                                    .fixedSize(horizontal: false, vertical: true)
                            }
                        }
                    }
                }
            }
        }
    }

    private var subtitle: LocalizedStringKey {
        switch report.overall {
        case .ok: "Mac в хорошей форме. Если что-то всё равно не так — позовите помощника."
        case .warn: "Ничего страшного, но кое-что стоит сделать:"
        case .bad: "Лучше показать этот отчёт помощнику:"
        }
    }
}

struct TrafficLight: View {
    let level: Level

    var body: some View {
        VStack(spacing: 5) {
            ForEach([Level.bad, .warn, .ok], id: \.self) { l in
                Circle()
                    .fill(l == level ? l.color : Color.gray.opacity(0.25))
                    .frame(width: 16, height: 16)
                    .shadow(color: l == level ? l.color.opacity(0.7) : .clear, radius: 5)
            }
        }
        .padding(7)
        .background(Color.black.opacity(0.75), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
    }
}

/// Плитки «что у меня за Mac».
struct InfoGrid: View {
    let report: SystemReport

    var body: some View {
        let r = report
        LazyVGrid(columns: [GridItem(.adaptive(minimum: 220), spacing: 12, alignment: .top)], spacing: 12) {
            Tile(icon: "laptopcomputer", title: "Mac", value: r.modelName,
                 detail: [r.chip, r.memory.map { String(localized: "память \(Fmt.bytes($0, binary: true))") }].compactMap { $0 }.joined(separator: " · "))
            Tile(icon: "apple.logo", title: "Система", value: r.osName, detail: r.osBuild.map { String(localized: "сборка \($0)") } ?? "")
            if let up = r.uptime {
                Tile(icon: "clock.arrow.circlepath", title: "Без перезагрузки", value: Fmt.uptime(up),
                     detail: up > 7 * 86_400 ? String(localized: "пора перезагрузить") : String(localized: "всё хорошо"),
                     level: up > 30 * 86_400 ? .bad : (up > 7 * 86_400 ? .warn : .ok))
            }
            if let free = r.diskFree, let total = r.diskTotal, let frac = r.diskFreeFraction {
                Tile(icon: "internaldrive", title: "Диск", value: String(localized: "Свободно \(Fmt.bytes(free))"),
                     detail: String(localized: "из \(Fmt.bytes(total))"), level: level("disk"), progress: 1 - frac)
            }
            Tile(icon: "memorychip", title: "Память", value: r.memoryPressure.title.capitalizedFirst,
                 detail: r.swapUsed.flatMap { $0 > 0 ? String(localized: "своп \(Fmt.bytes($0))") : nil } ?? "",
                 level: r.memoryPressure == .critical ? .bad : (r.memoryPressure == .warning ? .warn : .ok))
            if let b = r.battery {
                Tile(icon: b.charging ? "battery.100.bolt" : "battery.75", title: "Батарея",
                     value: "\(Fmt.percent(Double(b.percent))), \(b.powerState)",
                     detail: [b.health.map { String(localized: "здоровье \(Fmt.percent($0))") }, b.cycles.map { Fmt.cycles($0) }]
                        .compactMap { $0 }.joined(separator: " · "),
                     level: level("battery"))
            }
            if let n = r.network {
                Tile(icon: n.interface == "Wi-Fi" ? "wifi" : "network", title: "Интернет",
                     value: !n.connected ? String(localized: "Нет подключения")
                        : (n.internet == false ? String(localized: "Не отвечает") : String(localized: "Есть")),
                     detail: [n.interface, n.localIP].compactMap { $0 }.joined(separator: " · "),
                     level: level("network"))
            }
        }
    }

    private func level(_ id: String) -> Level {
        report.findings.first { $0.id == id }?.level ?? .ok
    }
}

struct Tile: View {
    let icon: String
    let title: LocalizedStringKey
    let value: String
    var detail: String = ""
    var level: Level? = nil
    var progress: Double? = nil

    var body: some View {
        Card {
            VStack(alignment: .leading, spacing: 6) {
                HStack {
                    Label(title, systemImage: icon).font(.callout).foregroundStyle(.secondary)
                    Spacer()
                    if let level { Circle().fill(level.color).frame(width: 9, height: 9) }
                }
                Text(value).font(.title3.weight(.semibold)).lineLimit(2).fixedSize(horizontal: false, vertical: true)
                if let progress {
                    ProgressView(value: min(max(progress, 0), 1)).tint(level?.color ?? Brand.blue)
                }
                if !detail.isEmpty { Text(detail).font(.callout).foregroundStyle(.secondary).lineLimit(2) }
            }
        }
    }
}

struct ProcessesCard: View {
    let report: SystemReport

    var body: some View {
        Card {
            VStack(alignment: .leading, spacing: 8) {
                SectionTitle(text: "Больше всего грузят Mac", icon: "speedometer")
                if report.topProcesses.isEmpty {
                    Text("Нет данных").foregroundStyle(.secondary)
                }
                ForEach(Array(report.topProcesses.enumerated()), id: \.offset) { _, p in
                    HStack {
                        Text(p.name).lineLimit(1)
                        Spacer()
                        Text("\(Fmt.percent(p.cpu)) ЦП").monospacedDigit().foregroundStyle(p.cpu > 80 ? .orange : .secondary)
                        Text(Fmt.bytes(p.memory)).monospacedDigit().foregroundStyle(.secondary).frame(width: 80, alignment: .trailing)
                    }
                    .font(.callout)
                }
                HStack {
                    ToolButton(tool: .perf)
                    Button("Мониторинг системы") { SystemLinks.openApp(SystemLinks.activityMonitor) }
                }
                .controlSize(.small)
                .padding(.top, 2)
            }
        }
    }
}

struct CrashesCard: View {
    let report: SystemReport

    var body: some View {
        Card {
            VStack(alignment: .leading, spacing: 8) {
                SectionTitle(text: "Сбои за неделю", icon: "exclamationmark.bubble")
                let groups = report.crashGroups
                if groups.isEmpty {
                    Label("Ни одно приложение не вылетало", systemImage: "checkmark.circle")
                        .foregroundStyle(.green)
                }
                ForEach(Array(groups.prefix(6).enumerated()), id: \.offset) { _, g in
                    HStack {
                        Text(g.title).lineLimit(1)
                        Spacer()
                        Text(Fmt.times(g.count)).monospacedDigit()
                            .foregroundStyle(g.count >= 3 && (g.kind == .crash || g.kind == .hang) ? .orange : .secondary)
                        Text(Fmt.dayMonth(g.last)).foregroundStyle(.secondary).frame(width: 90, alignment: .trailing)
                    }
                    .font(.callout)
                }
                Text("По именам файлов-отчётов macOS; их содержимое не читается.")
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
    }

}

extension String {
    var capitalizedFirst: String { prefix(1).uppercased() + dropFirst() }
}
