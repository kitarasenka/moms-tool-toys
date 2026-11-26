import SwiftUI

struct OverviewView: View {
    @Environment(AppState.self) private var state

    var body: some View {
        let m = state.monitor
        let s = m.system
        let columns = [GridItem(.adaptive(minimum: 340), spacing: 16, alignment: .top)]

        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                header(m)

                LazyVGrid(columns: columns, alignment: .leading, spacing: 16) {
                    cpuCard(m, s)
                    memoryCard(m, s)
                    networkCard(m, s)
                    diskCard(m, s)
                }

                LazyVGrid(columns: columns, alignment: .leading, spacing: 16) {
                    TopList(title: "Больше всего ЦП", systemImage: "flame",
                            records: Array(m.processes.sorted { $0.cpu > $1.cpu }.prefix(7))) {
                        "\(Fmt.percent($0.cpu)) %"
                    }
                    TopList(title: "Больше всего памяти", systemImage: "memorychip",
                            records: Array(m.processes.sorted { $0.memory > $1.memory }.prefix(7))) {
                        Fmt.bytes($0.memory)
                    }
                    TopList(title: "Больше всего сети", systemImage: "arrow.up.arrow.down",
                            records: Array(m.processes.filter { $0.netTotalRate > 0 }
                                .sorted { $0.netTotalRate > $1.netTotalRate }.prefix(7))) {
                        "↓ \(Fmt.rate($0.netIn))  ↑ \(Fmt.rate($0.netOut))"
                    }
                }
            }
            .padding(20)
        }
        .navigationTitle("Обзор")
    }

    private func header(_ m: Monitor) -> some View {
        let info = m.machine
        let cores: String = {
            if let p = info.performanceCores, let e = info.efficiencyCores {
                return "\(info.physicalCores) ядер (\(p) производительных + \(e) эффективности)"
            }
            return "\(info.physicalCores) ядер, \(info.logicalCores) потоков"
        }()
        return HStack(alignment: .center, spacing: 14) {
            Image(systemName: "desktopcomputer")
                .font(.system(size: 34, weight: .light))
                .foregroundStyle(.secondary)
            VStack(alignment: .leading, spacing: 2) {
                Text(info.cpuBrand).font(.title2.weight(.semibold))
                Text("\(info.model) · \(cores) · \(Fmt.bytes(info.memory)) ОЗУ")
                    .foregroundStyle(.secondary)
                Text(info.osVersion)
                    .font(.caption).foregroundStyle(.tertiary)
            }
            Spacer()
            VStack(alignment: .trailing, spacing: 4) {
                if let boot = m.system.bootTime {
                    Label("Без перезагрузки \(Fmt.duration(Date().timeIntervalSince(boot)))", systemImage: "clock")
                }
                Label("Нагрузка \(m.system.loadAverage.map { $0.formatted(.number.precision(.fractionLength(2))) }.joined(separator: "  "))",
                      systemImage: "chart.bar")
                    .help("Средняя нагрузка за 1, 5 и 15 минут")
                Label("\(m.processes.count) процессов · \(Fmt.number(m.totalThreads)) потоков", systemImage: "square.stack.3d.up")
            }
            .font(.callout)
            .foregroundStyle(.secondary)
            .monospacedDigit()
        }
    }

    private func cpuCard(_ m: Monitor, _ s: SystemSnapshot) -> some View {
        Card("Процессор", systemImage: "cpu") {
            HStack(alignment: .top) {
                BigValue(value: Fmt.percent(s.cpuTotal), unit: "%", caption: "общая загрузка")
                Spacer()
                VStack(alignment: .leading, spacing: 4) {
                    LegendDot(color: .red, title: "Система", value: "\(Fmt.percent(s.cpuSystem)) %")
                    LegendDot(color: .blue, title: "Пользователь", value: "\(Fmt.percent(s.cpuUser)) %")
                    LegendDot(color: .secondary.opacity(0.4), title: "Простой", value: "\(Fmt.percent(max(0, 100 - s.cpuTotal))) %")
                }
                .frame(width: 190)
            }
            HistoryChart(series: [
                ChartSeries(name: "Пользователь", color: .blue, values: m.cpuUserHistory),
                ChartSeries(name: "Система", color: .red, values: m.cpuSystemHistory),
            ], maxValue: 100, stacked: true)
            .frame(height: 90)
            CoreBars(values: s.perCore).frame(height: 44)
        }
    }

    private func memoryCard(_ m: Monitor, _ s: SystemSnapshot) -> some View {
        let pressure: (String, Color) = switch s.memPressure {
        case 4: ("Критическая", .red)
        case 2: ("Повышенная", .yellow)
        default: ("Нормальная", .green)
        }
        return Card("Память", systemImage: "memorychip") {
            Label(pressure.0, systemImage: "circle.fill")
                .font(.caption)
                .foregroundStyle(pressure.1)
                .help("Нагрузка на память")
        } content: {
            HStack(alignment: .top) {
                BigValue(value: Fmt.bytes(s.memUsed), caption: "из \(Fmt.bytes(s.memTotal))")
                Spacer()
                VStack(alignment: .leading, spacing: 4) {
                    LegendDot(color: .blue, title: "Приложения", value: Fmt.bytes(s.memApp))
                    LegendDot(color: .orange, title: "Зарезервировано", value: Fmt.bytes(s.memWired))
                    LegendDot(color: .purple, title: "Сжато", value: Fmt.bytes(s.memCompressed))
                    LegendDot(color: .gray, title: "Кэш файлов", value: Fmt.bytes(s.memCached))
                }
                .frame(width: 210)
            }
            SegmentBar(segments: [
                .init(color: .blue, value: Double(s.memApp), id: 0),
                .init(color: .orange, value: Double(s.memWired), id: 1),
                .init(color: .purple, value: Double(s.memCompressed), id: 2),
                .init(color: .gray, value: Double(s.memCached), id: 3),
            ], total: Double(s.memTotal))
            HistoryChart(series: [ChartSeries(name: "Используется", color: .green, values: m.memoryHistory)],
                         maxValue: Double(max(s.memTotal, 1)))
                .frame(height: 60)
            HStack {
                Text("Своп: \(Fmt.bytes(s.swapUsed)) из \(Fmt.bytes(s.swapTotal))")
                Spacer()
                Text("Свободно: \(Fmt.bytes(s.memFree))")
            }
            .font(.caption)
            .foregroundStyle(.secondary)
        }
    }

    private func networkCard(_ m: Monitor, _ s: SystemSnapshot) -> some View {
        Card("Сеть", systemImage: "network") {
            HStack(spacing: 24) {
                BigValue(value: Fmt.rate(s.netIn), caption: "↓ получено")
                BigValue(value: Fmt.rate(s.netOut), caption: "↑ отправлено")
                Spacer()
            }
            HistoryChart(series: [
                ChartSeries(name: "Получено", color: .blue, values: m.netInHistory),
                ChartSeries(name: "Отправлено", color: .orange, values: m.netOutHistory),
            ])
            .frame(height: 80)
            HStack {
                LegendDot(color: .blue, title: "Получено", value: Fmt.bytes(s.netInTotal))
                Spacer(minLength: 24)
                LegendDot(color: .orange, title: "Отправлено", value: Fmt.bytes(s.netOutTotal))
            }
        }
    }

    private func diskCard(_ m: Monitor, _ s: SystemSnapshot) -> some View {
        Card("Диск", systemImage: "internaldrive") {
            HStack(spacing: 24) {
                BigValue(value: Fmt.rate(s.diskRead), caption: "чтение")
                BigValue(value: Fmt.rate(s.diskWrite), caption: "запись")
                Spacer()
            }
            HistoryChart(series: [
                ChartSeries(name: "Чтение", color: .teal, values: m.diskReadHistory),
                ChartSeries(name: "Запись", color: .pink, values: m.diskWriteHistory),
            ])
            .frame(height: 80)
            HStack {
                LegendDot(color: .teal, title: "Прочитано", value: Fmt.bytes(s.diskReadTotal))
                Spacer(minLength: 24)
                LegendDot(color: .pink, title: "Записано", value: Fmt.bytes(s.diskWriteTotal))
            }
        }
    }
}

struct TopList: View {
    let title: String
    let systemImage: String
    let records: [ProcessRecord]
    let value: (ProcessRecord) -> String
    @Environment(AppState.self) private var state

    var body: some View {
        Card(title, systemImage: systemImage) {
            VStack(spacing: 2) {
                if records.isEmpty {
                    Text("Сейчас активности нет")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(6)
                }
                ForEach(records) { r in
                    Button {
                        state.select(r.pid)
                        state.section = .processes
                    } label: {
                        HStack(spacing: 8) {
                            ProcessIcon(path: r.path, size: 18)
                            Text(r.name).lineLimit(1)
                            Text(verbatim: "\(r.pid)").font(.caption).foregroundStyle(.tertiary).monospacedDigit()
                            Spacer()
                            Text(value(r)).monospacedDigit().foregroundStyle(.secondary)
                        }
                        .padding(.vertical, 4)
                        .padding(.horizontal, 6)
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(RowButtonStyle())
                }
            }
        }
    }
}

struct RowButtonStyle: ButtonStyle {
    @State private var hovering = false

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .background(
                RoundedRectangle(cornerRadius: 6, style: .continuous)
                    .fill(configuration.isPressed ? Color.accentColor.opacity(0.2)
                          : (hovering ? Color.secondary.opacity(0.1) : Color.clear))
            )
            .onHover { hovering = $0 }
    }
}
