import SwiftUI

struct EnergyView: View {
    @Environment(AppState.self) private var state

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            ScreenHeader(title: String(localized: "Расход приложений"),
                         subtitle: String(localized: "Кто сильнее всего тратит энергию прямо сейчас. Это та же оценка, что в «Мониторинге системы», — относительная, не ватты. Помощники приложений (вкладки браузера и т. п.) сложены в само приложение.")) {
                refreshButton
            }
            if state.energy.isEmpty {
                Card {
                    HStack(spacing: 10) {
                        if state.energyLoading { ProgressView().controlSize(.small) }
                        Text(state.energyLoading ? String(localized: "Замеряю… (около двух секунд)") : String(localized: "Нет данных — нажмите «Обновить»."))
                            .foregroundStyle(.secondary)
                    }
                }
                Spacer()
            } else {
                list
                footer
            }
        }
        .padding(24)
        .fillAvailable()
        .navigationTitle("Расход приложений")
        .task {
            // Пока раздел открыт — обновляем раз в 30 секунд.
            while !Task.isCancelled {
                await state.refreshEnergy()
                try? await Task.sleep(for: .seconds(30))
            }
        }
    }

    private var refreshButton: some View {
        Button {
            Task { await state.refreshEnergy() }
        } label: {
            if state.energyLoading {
                ProgressView().controlSize(.small).frame(width: 16)
            } else {
                Label("Обновить", systemImage: "arrow.clockwise")
            }
        }
        .disabled(state.energyLoading)
        .help("Обновить (⌘R)")
    }

    private var list: some View {
        let top = state.energy.first?.power ?? 1
        return ScrollView {
            VStack(spacing: 0) {
                ForEach(Array(state.energy.enumerated()), id: \.element.id) { i, app in
                    HStack(spacing: 12) {
                        Text("\(i + 1)").font(.callout.monospacedDigit()).foregroundStyle(.tertiary).frame(width: 20)
                        AppIcon(bundlePath: app.bundlePath, size: 28)
                        VStack(alignment: .leading, spacing: 4) {
                            HStack(alignment: .firstTextBaseline) {
                                Text(app.name).font(.body.weight(.medium)).lineLimit(1)
                                if app.processCount > 1 {
                                    Text(Fmt.processes(app.processCount))
                                        .font(.caption).foregroundStyle(.secondary)
                                }
                                if app.bundlePath == nil {
                                    Text("системный процесс").font(.caption).foregroundStyle(.tertiary)
                                }
                                Spacer()
                                Text(Fmt.number(app.power)).font(.body.monospacedDigit().weight(.semibold))
                            }
                            LevelBar(fraction: app.power / max(top, 0.1),
                                     style: i == 0 && app.power > 20 ? AnyShapeStyle(Color.orange) : AnyShapeStyle(Brand.gradient),
                                     height: 6)
                        }
                    }
                    .padding(.vertical, 8)
                    .padding(.horizontal, 14)
                    if i < state.energy.count - 1 { Divider().padding(.leading, 74) }
                }
            }
            .background(.background.secondary, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous).strokeBorder(.separator.opacity(0.6)))
        }
    }

    private var footer: some View {
        HStack {
            Image(systemName: "info.circle").foregroundStyle(.secondary)
            Text("Обновлено \(Fmt.ago(state.energyUpdated)) · автообновление раз в 30 с, пока раздел открыт. WindowServer — это отрисовка экрана, он всегда наверху.")
                .font(.caption).foregroundStyle(.secondary)
            Spacer()
        }
    }
}
