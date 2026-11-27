import Charts
import SwiftUI

struct HistoryView: View {
    @Environment(AppState.self) private var state
    @State private var date = Calendar.current.startOfDay(for: Date())
    @State private var day: HistoryDay?
    @State private var availableDays: [Date] = []
    @State private var hover: Date?

    private var isToday: Bool { Calendar.current.isDateInToday(date) }

    var body: some View {
        let buckets = day.map { HistoryBucket.make(from: $0.points, minutes: 5) } ?? []
        let selected = hover.flatMap { h in buckets.min { abs($0.t.timeIntervalSince(h)) < abs($1.t.timeIntervalSince(h)) } }
            .flatMap { abs($0.t.timeIntervalSince(hover ?? $0.t)) < 15 * 60 ? $0 : nil }

        Group {
            if let day, !day.points.isEmpty {
                ScrollView {
                    VStack(alignment: .leading, spacing: 16) {
                        DaySummary(day: day)
                        HStack(alignment: .top, spacing: 16) {
                            VStack(spacing: 16) {
                                chartCard(String(localized: "Процессор"), "cpu", buckets: buckets, series: [
                                    .init(name: String(localized: "Средняя"), color: .blue, value: \.cpu),
                                    .init(name: String(localized: "Пик"), color: .red.opacity(0.7), value: \.cpuMax, dashed: true),
                                ], yMax: 100, format: { "\(Int($0)) %" })
                                chartCard(String(localized: "Память"), "memorychip", buckets: buckets, series: [
                                    .init(name: String(localized: "Используется"), color: .green, value: \.mem),
                                ], yMax: buckets.map(\.memTotal).max(), format: { Fmt.bytes($0) })
                                chartCard(String(localized: "Сеть"), "network", buckets: buckets, series: [
                                    .init(name: String(localized: "Получено"), color: .blue, value: \.netIn),
                                    .init(name: String(localized: "Отправлено"), color: .orange, value: \.netOut),
                                ], yMax: nil, format: { Fmt.rate($0) })
                                chartCard(String(localized: "Диск"), "internaldrive", buckets: buckets, series: [
                                    .init(name: String(localized: "Чтение"), color: .teal, value: \.diskRead),
                                    .init(name: String(localized: "Запись"), color: .pink, value: \.diskWrite),
                                ], yMax: nil, format: { Fmt.rate($0) })
                            }
                            MomentPanel(bucket: selected, day: day)
                                .frame(width: 300)
                        }
                        DayProcesses(day: day)
                    }
                    .padding(20)
                }
            } else if day != nil {
                ContentUnavailableView {
                    Label(isToday ? String(localized: "Запись только началась") : String(localized: "Нет записей за этот день"), systemImage: "chart.xyaxis.line")
                } description: {
                    Text(isToday
                         ? String(localized: "PerfMom сохраняет нагрузку раз в минуту — первая точка появится в течение минуты. Запись идёт, пока PerfMom запущен; окно можно закрыть — он продолжит работать в строке меню.")
                         : String(localized: "В этот день PerfMom не был запущен."))
                }
            } else {
                ProgressView().controlSize(.small)
            }
        }
        .toolbar {
            ToolbarItemGroup(placement: .principal) {
                Button { shift(-1) } label: { Image(systemName: "chevron.left") }
                    .help("Предыдущий день")
                    .disabled(!availableDays.contains { $0 < date })
                DatePicker(String(localized: "День"), selection: $date, in: ...Date(), displayedComponents: .date)
                    .labelsHidden()
                    .datePickerStyle(.field)
                Button { shift(1) } label: { Image(systemName: "chevron.right") }
                    .help("Следующий день")
                    .disabled(isToday)
                Button("Сегодня") { date = Calendar.current.startOfDay(for: Date()) }
                    .disabled(isToday)
            }
        }
        .navigationTitle("История")
        .task(id: date) {
            hover = nil
            if state.demo {
                day = HistoryDay(date: date, points: [], processes: [])
                return
            }
            // Сегодняшний день перечитываем раз в минуту — по мере записи новых точек.
            while !Task.isCancelled {
                let d = date
                let (loaded, days) = await Task.detached(priority: .userInitiated) {
                    (HistoryLoader.load(d), HistoryFiles.availableDays())
                }.value
                day = loaded
                availableDays = days
                guard isToday else { break }
                try? await Task.sleep(for: .seconds(60))
            }
        }
    }

    private func shift(_ days: Int) {
        let cal = Calendar.current
        // Перепрыгиваем через дни без записей.
        if days < 0, let prev = availableDays.first(where: { $0 < date }) {
            date = prev
        } else if days > 0, let next = availableDays.last(where: { $0 > date }) {
            date = next
        } else if let d = cal.date(byAdding: .day, value: days, to: date), d <= Date() {
            date = cal.startOfDay(for: d)
        }
    }

    private func chartCard(_ title: String, _ icon: String, buckets: [HistoryBucket], series: [DayChart.Series],
                           yMax: Double?, format: @escaping (Double) -> String) -> some View {
        Card(title, systemImage: icon) {
            HStack(spacing: 12) {
                ForEach(series, id: \.name) { s in
                    HStack(spacing: 4) {
                        Capsule().fill(s.color).frame(width: 12, height: 3)
                        Text(s.name)
                    }
                }
            }
            .font(.caption)
            .foregroundStyle(.secondary)
        } content: {
            DayChart(buckets: buckets, series: series, day: date, yMax: yMax, format: format, hover: $hover)
                .frame(height: 130)
        }
    }
}

// MARK: - График за сутки

struct DayChart: View {
    struct Series {
        let name: String
        let color: Color
        let value: KeyPath<HistoryBucket, Double>
        var dashed = false
    }

    let buckets: [HistoryBucket]
    let series: [Series]
    let day: Date
    let yMax: Double?
    let format: (Double) -> String
    @Binding var hover: Date?

    var body: some View {
        let start = Calendar.current.startOfDay(for: day)
        let end = start.addingTimeInterval(24 * 3600)
        let peak = series.flatMap { s in buckets.map { $0[keyPath: s.value] } }.max() ?? 0
        let top = yMax ?? max(peak * 1.15, 1)
        // Отрезки из одной точки линией не рисуются — для них ставим маркер.
        let segmentSizes = Dictionary(grouping: buckets, by: \.segment).mapValues(\.count)

        Chart {
            ForEach(series, id: \.name) { s in
                ForEach(buckets) { b in
                    if !s.dashed {
                        AreaMark(x: .value(String(localized: "Время"), b.t), y: .value(s.name, b[keyPath: s.value]),
                                 series: .value(String(localized: "Отрезок"), "\(s.name)-\(b.segment)"), stacking: .unstacked)
                            .foregroundStyle(s.color.opacity(0.15))
                            .interpolationMethod(.monotone)
                    }
                    LineMark(x: .value(String(localized: "Время"), b.t), y: .value(s.name, b[keyPath: s.value]),
                             series: .value(String(localized: "Отрезок"), "\(s.name)-\(b.segment)"))
                        .foregroundStyle(s.color)
                        .lineStyle(StrokeStyle(lineWidth: s.dashed ? 1 : 1.5, dash: s.dashed ? [3, 3] : []))
                        .interpolationMethod(.monotone)
                    if segmentSizes[b.segment] == 1 {
                        PointMark(x: .value(String(localized: "Время"), b.t), y: .value(s.name, b[keyPath: s.value]))
                            .foregroundStyle(s.color)
                            .symbolSize(18)
                    }
                }
            }
            if let hover, hover >= start, hover <= end {
                RuleMark(x: .value(String(localized: "Время"), hover))
                    .foregroundStyle(Color.secondary.opacity(0.6))
                    .lineStyle(StrokeStyle(lineWidth: 1, dash: [2, 2]))
            }
        }
        .chartXScale(domain: start...end)
        .chartYScale(domain: 0...top)
        .chartXAxis {
            AxisMarks(values: .stride(by: .hour, count: 3)) { v in
                AxisGridLine(stroke: StrokeStyle(lineWidth: 0.5, dash: [2, 3]))
                AxisValueLabel(collisionResolution: .disabled) {
                    if let d = v.as(Date.self) {
                        Text(d.formatted(.dateTime.hour(.twoDigits(amPM: .omitted)).minute(.twoDigits).locale(L10n.locale)))
                            .font(.caption2)
                            .fixedSize()
                    }
                }
            }
        }
        .chartYAxis {
            AxisMarks(position: .leading, values: .automatic(desiredCount: 3)) { v in
                AxisGridLine(stroke: StrokeStyle(lineWidth: 0.5, dash: [2, 3]))
                AxisValueLabel {
                    if let d = v.as(Double.self) { Text(format(d)).font(.caption2) }
                }
            }
        }
        .chartOverlay { proxy in
            GeometryReader { geo in
                Rectangle().fill(.clear).contentShape(Rectangle())
                    .onContinuousHover { phase in
                        switch phase {
                        case .active(let location):
                            guard let frame = proxy.plotFrame else { return }
                            let x = location.x - geo[frame].origin.x
                            hover = proxy.value(atX: x, as: Date.self)
                        case .ended:
                            hover = nil
                        }
                    }
            }
        }
    }
}

// MARK: - Сводка за день

struct DaySummary: View {
    let day: HistoryDay

    var body: some View {
        let p = day.points
        let w = max(day.recordedSeconds, 1)
        let avgCPU = p.reduce(0) { $0 + $1.cpu * $1.dur } / w
        let peakCPU = p.max { $0.cpuMax < $1.cpuMax }
        let peakMem = p.max { $0.memMax < $1.memMax }
        let netIn = p.reduce(0) { $0 + $1.netIn * $1.dur }
        let netOut = p.reduce(0) { $0 + $1.netOut * $1.dur }
        let dRead = p.reduce(0) { $0 + $1.diskRead * $1.dur }
        let dWrite = p.reduce(0) { $0 + $1.diskWrite * $1.dur }

        LazyVGrid(columns: [GridItem(.adaptive(minimum: 170), spacing: 12)], spacing: 12) {
            tile(String(localized: "Средняя загрузка ЦП"), "\(Fmt.percent(avgCPU)) %", nil)
            tile(String(localized: "Пик ЦП"), peakCPU.map { "\(Fmt.percent($0.cpuMax)) %" } ?? "—", peakCPU.map { String(localized: "в \(time($0.t))") })
            tile(String(localized: "Пик памяти"), peakMem.map { Fmt.bytes($0.memMax) } ?? "—",
                 peakMem.map { String(localized: "в \(time($0.t)) из \(Fmt.bytes($0.memTotal))") })
            tile(String(localized: "Сеть"), "↓ \(Fmt.bytes(netIn))", "↑ \(Fmt.bytes(netOut))")
            tile(String(localized: "Диск"), "R \(Fmt.bytes(dRead))", "W \(Fmt.bytes(dWrite))")
            tile(String(localized: "Записано"), Fmt.duration(day.recordedSeconds),
                 p.first.map { String(localized: "с \(time($0.t)) до \(time($0.t.addingTimeInterval(60)))") }.map { first in
                     first.replacingOccurrences(of: String(localized: "до \(time(p.first!.t.addingTimeInterval(60)))"),
                                                with: String(localized: "до \(time((p.last?.t ?? p.first!.t).addingTimeInterval(60)))"))
                 })
        }
    }

    private func time(_ d: Date) -> String { d.formatted(Date.FormatStyle(date: .omitted, time: .shortened).locale(L10n.locale)) }

    private func tile(_ title: String, _ value: String, _ caption: String?) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(title).font(.caption).foregroundStyle(.secondary)
            Text(value)
                .font(.system(.title3, design: .rounded).weight(.semibold))
                .monospacedDigit()
                .lineLimit(1)
                .minimumScaleFactor(0.7)
            Text(caption ?? " ").font(.caption).foregroundStyle(.secondary).lineLimit(1)
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(.background.secondary, in: RoundedRectangle(cornerRadius: 10, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 10, style: .continuous).strokeBorder(.separator.opacity(0.5)))
    }
}

// MARK: - Что происходило в выбранный момент

struct MomentPanel: View {
    let bucket: HistoryBucket?
    let day: HistoryDay

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            if let b = bucket {
                let end = b.t.addingTimeInterval(5 * 60)
                Text("\(b.t.formatted(Date.FormatStyle(date: .omitted, time: .shortened).locale(L10n.locale))) – \(end.formatted(Date.FormatStyle(date: .omitted, time: .shortened).locale(L10n.locale)))")
                    .font(.headline)
                VStack(alignment: .leading, spacing: 4) {
                    LegendDot(color: .blue, title: String(localized: "ЦП"), value: String(localized: "\(Fmt.percent(b.cpu)) % (пик \(Fmt.percent(b.cpuMax)))"))
                    LegendDot(color: .green, title: String(localized: "Память"), value: Fmt.bytes(b.mem))
                    LegendDot(color: .blue, title: String(localized: "Сеть ↓"), value: Fmt.rate(b.netIn))
                    LegendDot(color: .orange, title: String(localized: "Сеть ↑"), value: Fmt.rate(b.netOut))
                    LegendDot(color: .teal, title: String(localized: "Диск"), value: Fmt.rate(b.diskRead + b.diskWrite))
                }
                topList(String(localized: "Больше всего ЦП"), b.topCPU) { "\(Fmt.percent($0)) %" }
                topList(String(localized: "Больше всего памяти"), b.topMem) { Fmt.bytes($0) }
                if b.minutes < 5 {
                    Text("Записано минут в интервале: \(b.minutes) из 5")
                        .font(.caption).foregroundStyle(.tertiary)
                }
            } else {
                Label("Наведите на график", systemImage: "cursorarrow.motionlines")
                    .font(.headline)
                Text("Здесь появятся значения и процессы, которые больше всего нагружали систему в выбранные 5 минут.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .topLeading)
        .background(.background.secondary, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous).strokeBorder(.separator.opacity(0.6)))
    }

    private func topList(_ title: String, _ items: [HistoryTop], _ format: @escaping (Double) -> String) -> some View {
        VStack(alignment: .leading, spacing: 5) {
            Text(title).font(.caption.weight(.semibold)).foregroundStyle(.secondary)
            if items.isEmpty {
                Text("—").foregroundStyle(.tertiary)
            }
            ForEach(items, id: \.self) { t in
                HStack(spacing: 6) {
                    ProcessIcon(path: t.path, size: 16)
                    Text(t.name).lineLimit(1)
                    Spacer(minLength: 4)
                    Text(format(t.value)).monospacedDigit().foregroundStyle(.secondary)
                }
                .font(.callout)
                .help(t.path)
            }
        }
    }
}

// MARK: - Кто нагружал систему за день

struct DayProcesses: View {
    let day: HistoryDay
    @Environment(AppState.self) private var state
    @State private var showAll = false

    var body: some View {
        let list = day.processes
        let shown = showAll ? Array(list.prefix(60)) : Array(list.prefix(12))
        let maxCPU = list.first?.cpuSeconds ?? 1
        let recorded = max(day.recordedSeconds, 1)

        Card(String(localized: "Кто нагружал систему за день"), systemImage: "list.number") {
            Text("Helper-процессы суммируются в своё приложение")
                .font(.caption).foregroundStyle(.secondary)
        } content: {
            Grid(alignment: .leading, horizontalSpacing: 16, verticalSpacing: 8) {
                GridRow {
                    Text("Приложение / процесс")
                    Text("Время ЦП")
                    Text("В среднем")
                    Text("Пик памяти")
                    Text("Сеть")
                    Text("Диск")
                }
                .font(.caption.weight(.semibold))
                .foregroundStyle(.secondary)
                Divider().gridCellColumns(6)
                ForEach(shown) { p in
                    GridRow {
                        HStack(spacing: 6) {
                            ProcessIcon(path: p.path, size: 18)
                            Text(p.name).lineLimit(1)
                        }
                        .help(p.path)
                        .frame(minWidth: 200, alignment: .leading)
                        HStack(spacing: 6) {
                            Capsule().fill(Color.blue.gradient)
                                .frame(width: max(2, 70 * p.cpuSeconds / max(maxCPU, 1)), height: 6)
                            Text(Fmt.cpuTime(p.cpuSeconds)).monospacedDigit()
                        }
                        Text("\(Fmt.percent(p.cpuSeconds / recorded * 100)) %").monospacedDigit()
                            .help("Средняя загрузка за записанное время (100 % = одно ядро)")
                        Text(Fmt.bytes(p.maxMemory)).monospacedDigit()
                        Text(p.netBytes > 0 ? Fmt.bytes(p.netBytes) : "—").monospacedDigit()
                        Text(p.diskBytes > 0 ? Fmt.bytes(p.diskBytes) : "—").monospacedDigit()
                    }
                    .font(.callout)
                }
            }
            if list.count > 12 {
                Button(showAll ? String(localized: "Свернуть") : String(localized: "Показать все (\(min(list.count, 60)))")) { showAll.toggle() }
                    .buttonStyle(.link)
                    .padding(.top, 4)
            }
            if list.isEmpty {
                Text("Итоги по процессам появятся после первой минуты записи.")
                    .font(.callout).foregroundStyle(.secondary)
            }
        }
    }
}
