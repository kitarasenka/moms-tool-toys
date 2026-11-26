import SwiftUI

struct NowView: View {
    @Environment(AppState.self) private var state
    @State private var confirmClear = false

    var body: some View {
        let s = state.sensors
        VStack(spacing: 0) {
            HStack(alignment: .top, spacing: 12) {
                SensorCard(kind: .camera, devices: s.cameras)
                SensorCard(kind: .microphone, devices: s.microphones)
            }
            .padding(12)
            Divider()
            HStack {
                Text("Журнал за 7 дней").font(.headline)
                Text("— записывается, пока PrivacyMom открыт").font(.caption).foregroundStyle(.secondary)
                Spacer()
                if let t = s.lastPoll {
                    Text("проверено в \(Fmt.time(t))").font(.caption).foregroundStyle(.secondary).monospacedDigit()
                }
                Button("Очистить журнал…") { confirmClear = true }.disabled(s.events.isEmpty)
            }
            .padding(.horizontal, 12).padding(.vertical, 8)
            log.frame(maxHeight: .infinity)
        }
        .fillAvailable()
        .navigationTitle("Сейчас")
        .confirmationDialog("Очистить журнал включений?", isPresented: $confirmClear) {
            Button("Очистить", role: .destructive) { s.clearLog() }
            Button("Отменить", role: .cancel) {}
        } message: {
            Text("Удалится только журнал PrivacyMom (sensors.jsonl).")
        }
    }

    private var log: some View {
        let events = state.sensors.events.sorted { $0.t > $1.t }
        return Group {
            if events.isEmpty {
                EmptyStateView(icon: "list.bullet.clipboard", title: "Пока тихо",
                               text: "Когда какое-нибудь приложение включит камеру или микрофон, здесь появится запись: что, когда и на сколько.") {}
            } else {
                List {
                    ForEach(groupedByDay(events), id: \.0) { day, list in
                        Section(day) {
                            ForEach(list) { e in LogRow(event: e, duration: duration(of: e)) }
                        }
                    }
                }
            }
        }
    }

    private func groupedByDay(_ events: [SensorEvent]) -> [(String, [SensorEvent])] {
        var out: [(String, [SensorEvent])] = []
        for e in events {
            let d = e.t.formatted(date: .complete, time: .omitted)
            if out.last?.0 == d { out[out.count - 1].1.append(e) } else { out.append((d, [e])) }
        }
        return out
    }

    /// Для «выключено» — сколько было включено (по предыдущему «включено» того же устройства).
    private func duration(of e: SensorEvent) -> TimeInterval? {
        guard !e.on else { return nil }
        let prev = state.sensors.events.last { $0.t <= e.t && $0.kind == e.kind && $0.device == e.device && $0.on }
        return prev.map { e.t.timeIntervalSince($0.t) }
    }
}

private struct SensorCard: View {
    @Environment(AppState.self) private var state
    let kind: SensorKind
    let devices: [SensorDevice]

    var body: some View {
        let on = devices.contains(where: \.running)
        Card {
            VStack(alignment: .leading, spacing: 12) {
                HStack(spacing: 14) {
                    Image(systemName: kind.icon)
                        .font(.system(size: 26, weight: .semibold))
                        .foregroundStyle(.white)
                        .frame(width: 58, height: 58)
                        .background(Circle().fill(on ? AnyShapeStyle(Color.red.gradient) : AnyShapeStyle(Brand.gradient)))
                        .shadow(color: (on ? Color.red : Brand.cyan).opacity(0.6), radius: on ? 16 : 10)
                    VStack(alignment: .leading, spacing: 3) {
                        Text(kind.title).font(.title3.weight(.semibold))
                        Text(kind == .camera ? (on ? "Сейчас включена" : "Выключена") : (on ? "Сейчас включён" : "Выключен"))
                            .font(.headline)
                            .foregroundStyle(on ? .red : .secondary)
                    }
                    Spacer()
                }
                if devices.isEmpty {
                    Text(kind == .camera ? "Камер не найдено." : "Микрофонов не найдено.")
                        .font(.callout).foregroundStyle(.secondary)
                } else {
                    VStack(alignment: .leading, spacing: 6) {
                        ForEach(devices) { d in
                            HStack(spacing: 8) {
                                Circle().fill(d.running ? Color.red : Color.secondary.opacity(0.35)).frame(width: 8, height: 8)
                                Text(d.name).lineLimit(1)
                                Spacer()
                                if d.running, let since = state.sensors.onSince[d.id] {
                                    Text(Fmt.duration(Date().timeIntervalSince(since))).font(.caption).monospacedDigit().foregroundStyle(.red)
                                }
                            }
                            .font(.callout)
                        }
                    }
                }
            }
        }
    }
}

private struct LogRow: View {
    let event: SensorEvent
    let duration: TimeInterval?

    var body: some View {
        HStack(spacing: 10) {
            Text(Fmt.time(event.t)).monospacedDigit().foregroundStyle(.secondary).frame(width: 72, alignment: .leading)
            Image(systemName: event.kind.icon).foregroundStyle(event.on ? AnyShapeStyle(Color.red) : AnyShapeStyle(.secondary)).frame(width: 20)
            Text(event.device).lineLimit(1)
            Pill(text: event.on ? "включение" : "выключение", color: event.on ? .red : .secondary)
            Spacer()
            if let d = duration { Text("работало \(Fmt.duration(d))").font(.caption).foregroundStyle(.secondary) }
        }
    }
}
