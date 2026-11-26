import SwiftUI

extension RiskLevel {
    var color: Color {
        switch self {
        case .none: .green
        case .info: .secondary
        case .warning: .orange
        case .danger: .red
        }
    }
}

enum SecurityFilter: String, CaseIterable, Identifiable {
    case danger = "Подозрительные"
    case attention = "Требуют внимания"
    case all = "Все замечания"
    case trusted = "Доверенные"
    var id: Self { self }
}

struct SecurityView: View {
    @Environment(AppState.self) private var state
    @State private var filter: SecurityFilter = .attention
    @State private var sortOrder = [KeyPathComparator(\SecurityRow.score, order: .reverse)]

    var body: some View {
        @Bindable var state = state
        let m = state.monitor
        let all = m.processes.map { SecurityRow(record: $0, trusted: state.isTrusted($0)) }
        let counts = Dictionary(grouping: all.filter { !$0.trusted }, by: \.level).mapValues(\.count)
        let q = state.search.trimmingCharacters(in: .whitespaces)
        let rows = all.filter { row in
            let byFilter: Bool = switch filter {
            case .danger: !row.trusted && row.level == .danger
            case .attention: !row.trusted && row.level >= .warning
            case .all: !row.trusted && row.level >= .info
            case .trusted: row.trusted
            }
            return byFilter && (q.isEmpty || row.record.name.localizedCaseInsensitiveContains(q)
                || row.record.path.localizedCaseInsensitiveContains(q) || row.reasons.localizedCaseInsensitiveContains(q))
        }.sorted(using: sortOrder)

        VStack(spacing: 0) {
            SecuritySummary(danger: counts[.danger] ?? 0, warning: counts[.warning] ?? 0,
                            info: counts[.info] ?? 0, total: all.count, trusted: state.trustedPaths.count)
                .padding(16)
            Divider()

            Table(rows, selection: $state.selectedPID, sortOrder: $sortOrder) {
                TableColumn("Риск", value: \.score) { row in
                    RiskBadge(level: row.level, score: row.score)
                }
                .width(min: 120, ideal: 150)

                TableColumn("Процесс", value: \.record.name) { row in
                    HStack(spacing: 6) {
                        ProcessIcon(path: row.record.path, size: 16)
                        Text(row.record.name).lineLimit(1)
                        Text(verbatim: "\(row.record.pid)").font(.caption).foregroundStyle(.tertiary).monospacedDigit()
                    }
                }
                .width(min: 160, ideal: 220)

                TableColumn("Причины", value: \.reasons) { row in
                    Text(row.reasons)
                        .lineLimit(2)
                        .help(row.record.security.findings.map { "• \($0.title): \($0.detail)" }.joined(separator: "\n"))
                }
                .width(min: 220, ideal: 380)

                TableColumn("Подпись", value: \.record.security.signer) { row in
                    Text(row.record.security.signer).foregroundStyle(.secondary).lineLimit(1)
                }
                .width(min: 110, ideal: 170)

                TableColumn("Путь", value: \.record.path) { row in
                    Text(row.record.path.isEmpty ? "—" : row.record.path)
                        .foregroundStyle(.secondary)
                        .truncationMode(.middle)
                        .help(row.record.path)
                }
                .width(min: 120, ideal: 280)
            }
            .contextMenu(forSelectionType: pid_t.self) { pids in
                if let pid = pids.first, let r = m.byPID[pid] {
                    Button(state.isTrusted(r) ? "Перестать доверять" : "Доверять этому файлу") { state.toggleTrust(r.path) }
                        .disabled(r.path.isEmpty)
                    Divider()
                    ProcessMenuItems(pid: pid, state: state)
                }
            } primaryAction: { pids in
                if let pid = pids.first { state.showChain(pid) }
            }
            .overlay {
                if rows.isEmpty {
                    ContentUnavailableView {
                        Label(filter == .trusted ? "Нет доверенных файлов" : "Ничего не найдено",
                              systemImage: filter == .trusted ? "hand.thumbsup" : "checkmark.shield")
                    } description: {
                        Text(filter == .trusted
                             ? "Отметьте процесс как доверенный через контекстное меню, если уверены, что это ложное срабатывание."
                             : "Среди запущенных процессов нет таких, что подходят под фильтр.")
                    }
                }
            }
        }
        .toolbar {
            ToolbarItem(placement: .principal) {
                Picker("Фильтр", selection: $filter) {
                    ForEach(SecurityFilter.allCases) { Text($0.rawValue).tag($0) }
                }
                .pickerStyle(.segmented)
            }
        }
        .navigationTitle("Безопасность")
    }
}

/// Строка таблицы (позиция в таблице нестабильна, но процессов с замечаниями немного).
struct SecurityRow: Identifiable {
    let record: ProcessRecord
    let trusted: Bool
    var id: pid_t { record.pid }
    var level: RiskLevel { trusted ? .none : record.security.level }
    var score: Int { trusted ? 0 : record.security.score }
    var reasons: String { record.security.findings.map(\.title).joined(separator: " · ") }
}

struct RiskBadge: View {
    let level: RiskLevel
    var score: Int?

    var body: some View {
        HStack(spacing: 5) {
            Image(systemName: level.symbol).foregroundStyle(level.color)
            Text(level.title).foregroundStyle(level >= .warning ? level.color : .secondary)
            if let score, score > 0 {
                Text("\(score)").font(.caption2.monospacedDigit()).foregroundStyle(.tertiary)
            }
        }
        .lineLimit(1)
    }
}

struct SecuritySummary: View {
    let danger: Int
    let warning: Int
    let info: Int
    let total: Int
    let trusted: Int

    var body: some View {
        let level: RiskLevel = danger > 0 ? .danger : (warning > 0 ? .warning : .none)
        HStack(alignment: .center, spacing: 16) {
            Image(systemName: level == .none ? "checkmark.shield.fill" : level.symbol)
                .font(.system(size: 36))
                .foregroundStyle(level.color)
            VStack(alignment: .leading, spacing: 3) {
                Text(headline).font(.title3.weight(.semibold))
                Text("Проверено процессов: \(total). Оцениваются подпись кода (в т. ч. статус из ядра), расположение файла, маскировка под системные процессы, цепочка запуска, внедрение библиотек, сеть и автозагрузка. Это эвристика, а не антивирус.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(3)
                    .frame(maxWidth: 640, alignment: .leading)
            }
            Spacer()
            HStack(spacing: 18) {
                counter(danger, "Подозрительно", .red)
                counter(warning, "Внимание", .orange)
                counter(info, "Замечания", .secondary)
                if trusted > 0 { counter(trusted, "Доверено", .green) }
            }
        }
    }

    private var headline: String {
        if danger > 0 { return "Найдены подозрительные процессы" }
        if warning > 0 { return "Есть процессы, на которые стоит посмотреть" }
        return "Подозрительных процессов не найдено"
    }

    private func counter(_ n: Int, _ title: String, _ color: Color) -> some View {
        VStack(spacing: 1) {
            Text("\(n)").font(.system(.title2, design: .rounded).weight(.semibold)).monospacedDigit()
                .foregroundStyle(n > 0 ? color : .secondary)
            Text(title).font(.caption2).foregroundStyle(.secondary)
        }
    }
}

// MARK: - Блок в инспекторе

struct SecuritySection: View {
    let record: ProcessRecord
    @Environment(AppState.self) private var state
    @State private var verification: SecurityAnalyzer.DeepVerification?
    @State private var verifying = false

    var body: some View {
        let trusted = state.isTrusted(record)
        let a = record.security
        InspectorSection("Безопасность") {
            HStack {
                RiskBadge(level: trusted ? .none : a.level, score: trusted ? nil : a.score)
                    .font(.callout.weight(.medium))
                Spacer()
                if trusted {
                    Label("Доверенный", systemImage: "hand.thumbsup.fill").font(.caption).foregroundStyle(.green)
                }
            }
            KeyValueRow(key: "Подпись", value: a.signer)
            if !a.isPlatform {
                KeyValueRow(key: "Hardened Runtime", value: a.hardenedRuntime ? "Включён" : "Выключен")
            }
            ForEach(a.findings) { f in
                HStack(alignment: .firstTextBaseline, spacing: 8) {
                    Image(systemName: f.level.symbol).foregroundStyle(trusted ? .secondary : f.level.color)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(f.title).font(.callout.weight(.medium))
                        Text(f.detail).font(.caption).foregroundStyle(.secondary)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                }
                .padding(.top, 2)
            }
            if let v = verification {
                Label(v.message, systemImage: v.valid ? (v.notarized ? "checkmark.seal.fill" : "checkmark.seal") : "xmark.seal.fill")
                    .font(.caption)
                    .foregroundStyle(v.valid ? (v.notarized ? Color.green : Color.orange) : Color.red)
                    .padding(.top, 2)
            }
            HStack {
                if !a.isPlatform && !record.path.isEmpty {
                    Button {
                        verifying = true
                        let path = record.path
                        Task {
                            verification = await Task.detached { SecurityAnalyzer.deepVerify(path: path) }.value
                            verifying = false
                        }
                    } label: {
                        if verifying { ProgressView().controlSize(.mini) } else { Text("Проверить подлинность") }
                    }
                    .disabled(verifying)
                    .help("Сверить хеши всех файлов с подписью и проверить нотаризацию Apple (может занять несколько секунд)")
                }
                if !a.findings.isEmpty || trusted {
                    Button(trusted ? "Перестать доверять" : "Доверять") { state.toggleTrust(record.path) }
                        .disabled(record.path.isEmpty)
                        .help("Отметить файл как доверенный, если это ложное срабатывание")
                }
            }
            .controlSize(.small)
            .padding(.top, 4)
        }
        .onChange(of: record.pid) { verification = nil }
    }
}
