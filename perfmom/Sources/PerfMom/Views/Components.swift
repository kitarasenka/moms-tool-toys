import AppKit
import Charts
import SwiftUI
import UniformTypeIdentifiers

extension View {
    /// NSTableView зеркалит столбцы, но начинает прокрутку у левого края.
    @ViewBuilder
    func leadingTableScrollPosition() -> some View {
        if L10n.layoutDirection == .rightToLeft {
            background(TableScrollPosition())
        } else {
            self
        }
    }
}

private struct TableScrollPosition: NSViewRepresentable {
    func makeNSView(context: Context) -> Anchor { Anchor() }
    func updateNSView(_ nsView: Anchor, context: Context) {}

    final class Anchor: NSView {
        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            guard window != nil else { return }
            DispatchQueue.main.async { [weak self] in self?.scrollToLeadingEdge() }
        }

        private func scrollToLeadingEdge() {
            var container = superview
            while let view = container {
                if let scrollView = tableScrollView(in: view), let table = scrollView.documentView as? NSTableView {
                    let clip = scrollView.contentView
                    let start = max(table.bounds.minX, table.bounds.maxX - clip.bounds.width)
                    clip.scroll(to: NSPoint(x: start, y: clip.bounds.minY))
                    scrollView.reflectScrolledClipView(clip)
                    if let header = table.headerView?.superview as? NSClipView {
                        header.scroll(to: NSPoint(x: clip.bounds.minX, y: header.bounds.minY))
                    }
                    return
                }
                container = view.superview
            }
        }

        private func tableScrollView(in view: NSView) -> NSScrollView? {
            if let scrollView = view as? NSScrollView, scrollView.documentView is NSTableView {
                return scrollView
            }
            for child in view.subviews {
                if let found = tableScrollView(in: child) { return found }
            }
            return nil
        }
    }
}

// MARK: - Иконки процессов

@MainActor
final class IconCache {
    static let shared = IconCache()
    private let cache = NSCache<NSString, NSImage>()
    private lazy var generic: NSImage = NSWorkspace.shared.icon(for: .unixExecutable)

    func icon(for path: String) -> NSImage {
        guard !path.isEmpty else { return generic }
        let key = (PathTools.outermostApp(path) ?? path) as NSString
        if let img = cache.object(forKey: key) { return img }
        let img = NSWorkspace.shared.icon(forFile: key as String)
        cache.setObject(img, forKey: key)
        return img
    }
}

struct ProcessIcon: View {
    let path: String
    var size: CGFloat = 16

    var body: some View {
        Image(nsImage: IconCache.shared.icon(for: path))
            .resizable()
            .interpolation(.high)
            .aspectRatio(contentMode: .fit)
            .frame(width: size, height: size)
    }
}

// MARK: - Карточка в стиле «Системных настроек»

struct Card<Content: View, Accessory: View>: View {
    let title: String
    let systemImage: String
    @ViewBuilder var accessory: Accessory
    @ViewBuilder var content: Content

    init(_ title: String, systemImage: String,
         @ViewBuilder accessory: () -> Accessory = { EmptyView() },
         @ViewBuilder content: () -> Content) {
        self.title = title
        self.systemImage = systemImage
        self.accessory = accessory()
        self.content = content()
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Label(title, systemImage: systemImage)
                    .font(.headline)
                    .foregroundStyle(.secondary)
                Spacer()
                accessory
            }
            content
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .topLeading)
        .background(.background.secondary, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous).strokeBorder(.separator.opacity(0.6)))
    }
}

// MARK: - Графики истории

struct ChartSeries: Identifiable {
    let name: String
    let color: Color
    let values: [Double]
    var id: String { name }
}

struct HistoryChart: View {
    let series: [ChartSeries]
    var capacity: Int = Monitor.historyCapacity
    var maxValue: Double?
    var stacked = false
    var showGrid = true

    private var yMax: Double {
        if let maxValue { return maxValue }
        let peak: Double
        if stacked {
            let n = series.map(\.values.count).max() ?? 0
            peak = (0..<n).map { i in series.reduce(0) { $0 + ($1.values.indices.contains(i) ? $1.values[i] : 0) } }.max() ?? 0
        } else {
            peak = series.flatMap(\.values).max() ?? 0
        }
        return max(peak * 1.15, 1)
    }

    var body: some View {
        Chart {
            ForEach(series) { s in
                let offset = capacity - s.values.count
                ForEach(Array(s.values.enumerated()), id: \.offset) { item in
                    AreaMark(
                        x: .value(String(localized: "Время"), offset + item.offset),
                        y: .value(String(localized: "Значение"), item.element),
                        stacking: stacked ? .standard : .unstacked
                    )
                    .foregroundStyle(by: .value(String(localized: "Серия"), s.name))
                    .opacity(stacked ? 0.75 : 0.18)
                    .interpolationMethod(.monotone)
                }
            }
            if !stacked {
                ForEach(series) { s in
                    let offset = capacity - s.values.count
                    ForEach(Array(s.values.enumerated()), id: \.offset) { item in
                        LineMark(
                            x: .value(String(localized: "Время"), offset + item.offset),
                            y: .value(String(localized: "Значение"), item.element),
                            series: .value(String(localized: "Серия"), s.name)
                        )
                        .foregroundStyle(by: .value(String(localized: "Серия"), s.name))
                        .lineStyle(StrokeStyle(lineWidth: 1.5))
                        .interpolationMethod(.monotone)
                    }
                }
            }
        }
        .chartForegroundStyleScale(domain: series.map(\.name), range: series.map(\.color))
        .chartLegend(.hidden)
        .chartXScale(domain: 0...max(1, capacity - 1))
        .chartYScale(domain: 0...yMax)
        .chartXAxis(.hidden)
        .chartYAxis {
            if showGrid {
                AxisMarks(values: .automatic(desiredCount: 3)) { _ in
                    AxisGridLine(stroke: StrokeStyle(lineWidth: 0.5, dash: [2, 3]))
                }
            }
        }
        .animation(.easeOut(duration: 0.25), value: series.first?.values.count)
    }
}

// MARK: - Мелкие элементы

struct LegendDot: View {
    let color: Color
    let title: String
    let value: String

    var body: some View {
        HStack(spacing: 6) {
            Circle().fill(color).frame(width: 8, height: 8)
            Text(title).foregroundStyle(.secondary).lineLimit(1)
            Spacer(minLength: 8)
            Text(value).monospacedDigit()
        }
        .font(.callout)
    }
}

struct BigValue: View {
    let value: String
    var unit: String = ""
    var caption: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack(alignment: .firstTextBaseline, spacing: 3) {
                Text(value)
                    .font(.system(size: 30, weight: .semibold, design: .rounded))
                    .monospacedDigit()
                    .lineLimit(1)
                    .minimumScaleFactor(0.6)
                    .contentTransition(.numericText())
                if !unit.isEmpty {
                    Text(unit).font(.title3.weight(.medium)).foregroundStyle(.secondary)
                }
            }
            if let caption {
                Text(caption).font(.caption).foregroundStyle(.secondary).lineLimit(1)
            }
        }
    }
}

/// Сегментированная полоса (как «Память» в Мониторинге системы).
struct SegmentBar: View {
    struct Segment: Identifiable {
        let color: Color
        let value: Double
        var id: Int
    }

    let segments: [Segment]
    let total: Double
    var height: CGFloat = 10

    var body: some View {
        GeometryReader { geo in
            HStack(spacing: 1.5) {
                ForEach(segments) { seg in
                    Rectangle()
                        .fill(seg.color.gradient)
                        .frame(width: max(0, geo.size.width * seg.value / max(total, 1) - 1.5))
                }
                Spacer(minLength: 0)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(Color.secondary.opacity(0.15))
            .clipShape(Capsule())
        }
        .frame(height: height)
    }
}

/// Мини-столбики загрузки по ядрам.
struct CoreBars: View {
    let values: [Double]

    var body: some View {
        HStack(alignment: .bottom, spacing: 3) {
            ForEach(Array(values.enumerated()), id: \.offset) { item in
                VStack(spacing: 3) {
                    GeometryReader { geo in
                        ZStack(alignment: .bottom) {
                            RoundedRectangle(cornerRadius: 2).fill(Color.secondary.opacity(0.15))
                            RoundedRectangle(cornerRadius: 2)
                                .fill(color(for: item.element).gradient)
                                .frame(height: geo.size.height * min(item.element, 100) / 100)
                        }
                    }
                    Text("\(item.offset + 1)").font(.system(size: 8)).foregroundStyle(.tertiary)
                }
                .help("Ядро \(item.offset + 1): \(Fmt.percent(item.element)) %")
            }
        }
        .animation(.easeOut(duration: 0.3), value: values)
    }

    private func color(for v: Double) -> Color {
        v > 85 ? .red : (v > 60 ? .orange : .blue)
    }
}

struct InspectorSection<Content: View>: View {
    let title: String
    @ViewBuilder var content: Content

    init(_ title: String, @ViewBuilder content: () -> Content) {
        self.title = title
        self.content = content()
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(title)
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(.secondary)
            VStack(alignment: .leading, spacing: 6) { content }
                .padding(12)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(.background.secondary, in: RoundedRectangle(cornerRadius: 10, style: .continuous))
                .overlay(RoundedRectangle(cornerRadius: 10, style: .continuous).strokeBorder(.separator.opacity(0.5)))
        }
    }
}

struct KeyValueRow: View {
    let key: String
    let value: String
    var monospaced = false

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 10) {
            Text(key)
                .foregroundStyle(.secondary)
                .frame(width: 118, alignment: .leading)
            Text(value)
                .font(monospaced ? .callout.monospaced() : .callout)
                .textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
        .font(.callout)
    }
}

struct MetricTile: View {
    let title: String
    let value: String

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(title).font(.caption).foregroundStyle(.secondary)
            Text(value)
                .font(.system(.title3, design: .rounded).weight(.semibold))
                .monospacedDigit()
                .lineLimit(1)
                .minimumScaleFactor(0.7)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

/// Строка-ссылка на другой процесс (родитель, ответственный, дочерний).
struct ProcessLink: View {
    let record: ProcessRecord
    @Environment(AppState.self) private var state

    var body: some View {
        Button {
            state.select(record.pid)
        } label: {
            HStack(spacing: 6) {
                ProcessIcon(path: record.path, size: 16)
                Text(record.name).lineLimit(1)
                Text(verbatim: "\(record.pid)").foregroundStyle(.secondary).monospacedDigit()
                Spacer(minLength: 0)
                Image(systemName: "chevron.right").font(.caption2).foregroundStyle(.tertiary)
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help("Перейти к процессу \(record.name)")
    }
}
