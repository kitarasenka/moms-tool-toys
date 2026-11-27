import Charts
import SwiftUI

struct HistoryView: View {
    enum Range: String, CaseIterable, Identifiable {
        case day, week
        var title: LocalizedStringKey { self == .day ? "24 часа" : "7 дней" }
        var id: String { rawValue }
        var seconds: TimeInterval { self == .day ? 86400 : 7 * 86400 }
        /// Усреднение: по минуте за сутки, по 15 минут за неделю.
        var bucket: TimeInterval { self == .day ? 60 : 15 * 60 }
    }

    @Environment(AppState.self) private var state
    @State private var range: Range = .day
    @State private var records: [HistoryRecord]?
    @State private var weekRecords: [HistoryRecord] = []

    var body: some View {
        Group {
            if !state.hasBattery {
                EmptyStateView(icon: "chart.xyaxis.line", title: String(localized: "Истории нет"),
                               text: String(localized: "У этого Mac нет встроенной батареи — записывать нечего.")) { EmptyView() }
            } else if let records {
                content(records)
            } else {
                ProgressView().controlSize(.small)
            }
        }
        .fillAvailable()
        .navigationTitle("История")
        .toolbar {
            ToolbarItem(placement: .principal) {
                Picker("Период", selection: $range) {
                    ForEach(Range.allCases) { Text($0.title).tag($0) }
                }
                .pickerStyle(.segmented)
                .frame(width: 200)
            }
        }
        .task(id: "\(range.rawValue)-\(state.historyTick)") {
            let since = Date().addingTimeInterval(-7 * 86400)
            let all = await state.loadHistory(since: since)
            let from = Date().addingTimeInterval(-range.seconds)
            weekRecords = all
            records = all.filter { $0.t >= from }
        }
    }

    @ViewBuilder
    private func content(_ records: [HistoryRecord]) -> some View {
        let end = Date()
        let start = end.addingTimeInterval(-range.seconds)
        let points = HistoryAnalysis.points(records, bucket: range.bucket)
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                ScreenHeader(title: String(localized: "История"), subtitle: String(localized: "BatteryMom записывает батарею раз в минуту, пока запущен — в том числе с закрытым окном (значок в строке меню). Пропуски на графике — Mac спал или BatteryMom был выключен.")) {
                    EmptyView()
                }
                if records.isEmpty {
                    Card {
                        Label("Записей за этот период пока нет — первая точка появится в течение минуты.", systemImage: "clock")
                            .foregroundStyle(.secondary)
                    }
                } else {
                    Card {
                        VStack(alignment: .leading, spacing: 8) {
                            chartTitle(String(localized: "Заряд"), icon: "battery.75percent", legend: [(String(localized: "Заряд"), Brand.blue), (String(localized: "Заряжался"), .green)])
                            ChargeChart(points: points, start: start, end: end, range: range)
                                .frame(height: 170)
                        }
                    }
                    Card {
                        VStack(alignment: .leading, spacing: 8) {
                            chartTitle(String(localized: "Мощность"), icon: "bolt", legend: [(String(localized: "Потребление Mac"), .orange), (String(localized: "Заряд батареи"), .green)])
                            PowerChart(points: points, start: start, end: end, range: range)
                                .frame(height: 150)
                        }
                    }
                }
                DaysCard(days: HistoryAnalysis.days(weekRecords))
                Text("Файл: \(HistoryStore.shared.fileURL.path.replacingOccurrences(of: NSHomeDirectory(), with: "~")) · хранится \(HistoryStore.retentionDays) дней")
                    .font(.caption).foregroundStyle(.secondary)
                    .textSelection(.enabled)
            }
            .padding(24)
        }
    }

    private func chartTitle(_ title: String, icon: String, legend: [(String, Color)]) -> some View {
        HStack {
            Label(title, systemImage: icon).font(.headline)
            Spacer()
            ForEach(legend, id: \.0) { item in
                HStack(spacing: 4) {
                    Capsule().fill(item.1).frame(width: 12, height: 3)
                    Text(item.0)
                }
                .font(.caption)
                .foregroundStyle(.secondary)
            }
        }
    }
}

// MARK: - Графики

/// Ось времени: каждые 3 часа за сутки, по дням за неделю.
private func timeAxis(_ range: HistoryView.Range) -> some AxisContent {
    AxisMarks(values: .stride(by: range == .day ? .hour : .day, count: range == .day ? 3 : 1)) { v in
        AxisGridLine(stroke: StrokeStyle(lineWidth: 0.5, dash: [2, 3]))
        AxisValueLabel {
            if let d = v.as(Date.self) {
                Text(range == .day ? d.formatted(.dateTime.hour(.twoDigits(amPM: .omitted)).minute(.twoDigits).locale(L10n.locale))
                                   : d.formatted(.dateTime.weekday(.abbreviated).day().locale(L10n.locale)))
                    .font(.caption2)
                    .fixedSize()
            }
        }
    }
}

struct ChargeChart: View {
    let points: [ChartPoint]
    let start: Date
    let end: Date
    let range: HistoryView.Range

    var body: some View {
        let sizes = Dictionary(grouping: points, by: \.segment).mapValues(\.count)
        Chart {
            ForEach(points) { p in
                AreaMark(x: .value(String(localized: "Время"), p.t), y: .value(String(localized: "Заряд"), p.percent),
                         series: .value(String(localized: "Отрезок"), p.segment), stacking: .unstacked)
                    .foregroundStyle(LinearGradient(colors: [Brand.cyan.opacity(0.35), Brand.blue.opacity(0.05)],
                                                    startPoint: .top, endPoint: .bottom))
                    .interpolationMethod(.monotone)
                LineMark(x: .value(String(localized: "Время"), p.t), y: .value(String(localized: "Заряд"), p.percent), series: .value(String(localized: "Отрезок"), p.segment))
                    .foregroundStyle(Brand.blue)
                    .lineStyle(StrokeStyle(lineWidth: 1.8))
                    .interpolationMethod(.monotone)
                if sizes[p.segment] == 1 {
                    PointMark(x: .value(String(localized: "Время"), p.t), y: .value(String(localized: "Заряд"), p.percent))
                        .foregroundStyle(Brand.blue).symbolSize(18)
                }
                if p.charging {
                    // Полоска внизу — периоды зарядки.
                    RectangleMark(xStart: .value(String(localized: "С"), p.t.addingTimeInterval(-range.bucket / 2)),
                                  xEnd: .value(String(localized: "По"), p.t.addingTimeInterval(range.bucket / 2)),
                                  yStart: .value("", 0), yEnd: .value("", 3))
                        .foregroundStyle(.green.opacity(0.8))
                }
            }
        }
        .chartXScale(domain: start...end)
        .chartYScale(domain: 0...100)
        .chartXAxis { timeAxis(range) }
        .chartYAxis {
            AxisMarks(position: .leading, values: [0, 25, 50, 75, 100]) { v in
                AxisGridLine(stroke: StrokeStyle(lineWidth: 0.5, dash: [2, 3]))
                AxisValueLabel { if let d = v.as(Int.self) { Text("\(d) %").font(.caption2) } }
            }
        }
    }
}

struct PowerChart: View {
    let points: [ChartPoint]
    let start: Date
    let end: Date
    let range: HistoryView.Range

    var body: some View {
        let peak = points.flatMap { [$0.power ?? 0, max(0, $0.batteryPower ?? 0)] }.max() ?? 0
        Chart {
            ForEach(points) { p in
                if let w = p.power {
                    LineMark(x: .value(String(localized: "Время"), p.t), y: .value(String(localized: "Вт"), w), series: .value(String(localized: "Ряд"), "w-\(p.segment)"))
                        .foregroundStyle(.orange)
                        .lineStyle(StrokeStyle(lineWidth: 1.5))
                        .interpolationMethod(.monotone)
                }
                if let c = p.batteryPower, c > 0 {
                    LineMark(x: .value(String(localized: "Время"), p.t), y: .value(String(localized: "Вт"), c), series: .value(String(localized: "Ряд"), "c-\(p.segment)"))
                        .foregroundStyle(.green)
                        .lineStyle(StrokeStyle(lineWidth: 1.2, dash: [3, 2]))
                        .interpolationMethod(.monotone)
                }
            }
        }
        .chartXScale(domain: start...end)
        .chartYScale(domain: 0...max(5, peak * 1.15))
        .chartXAxis { timeAxis(range) }
        .chartYAxis {
            AxisMarks(position: .leading, values: .automatic(desiredCount: 3)) { v in
                AxisGridLine(stroke: StrokeStyle(lineWidth: 0.5, dash: [2, 3]))
                AxisValueLabel { if let d = v.as(Double.self) { Text("\(Int(d)) Вт").font(.caption2) } }
            }
        }
    }
}

// MARK: - Итоги по дням

struct DaysCard: View {
    let days: [DaySummary]

    var body: some View {
        Card {
            VStack(alignment: .leading, spacing: 10) {
                Label("По дням", systemImage: "calendar").font(.headline)
                if days.isEmpty {
                    Text("Пока нет ни одного дня с записями.").foregroundStyle(.secondary)
                } else {
                    Grid(alignment: .leading, horizontalSpacing: 24, verticalSpacing: 8) {
                        GridRow {
                            Text("День"); Text("От батареи"); Text("Израсходовано"); Text("Заряд"); Text("Циклы"); Text("Записано")
                        }
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(.secondary)
                        Divider()
                        ForEach(days) { d in
                            GridRow {
                                Text(dayTitle(d.day))
                                Text(d.onBattery > 0 ? Fmt.duration(d.onBattery) : "—")
                                Text(d.drained > 0 ? "\(d.drained) %" : "—")
                                Text(d.minPercent == d.maxPercent ? "\(d.minPercent) %" : "\(d.minPercent)–\(d.maxPercent) %")
                                Text(d.cyclesDelta.map { $0 > 0 ? "+\($0)" : "0" } ?? "—")
                                Text(Fmt.duration(d.recorded)).foregroundStyle(.secondary)
                            }
                            .monospacedDigit()
                        }
                    }
                }
            }
        }
    }

    private func dayTitle(_ d: Date) -> String {
        let cal = Calendar.current
        if cal.isDateInToday(d) { return String(localized: "Сегодня") }
        if cal.isDateInYesterday(d) { return String(localized: "Вчера") }
        return d.formatted(.dateTime.weekday(.wide).day().month(.wide).locale(L10n.locale))
    }
}
