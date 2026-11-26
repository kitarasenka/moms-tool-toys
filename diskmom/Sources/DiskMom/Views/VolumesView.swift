import AppKit
import SwiftUI

struct VolumesView: View {
    @Environment(AppState.self) private var state

    var body: some View {
        let store = state.volumes
        ScrollView {
            VStack(alignment: .leading, spacing: 12) {
                if let msg = store.message {
                    Label(msg, systemImage: msg.hasPrefix("Не удалось") ? "exclamationmark.triangle" : "checkmark.circle")
                        .foregroundStyle(msg.hasPrefix("Не удалось") ? .orange : .secondary)
                }
                ForEach(store.volumes) { v in VolumeCard(volume: v) }
                if store.volumes.isEmpty && !store.loading {
                    Text("Подключённых дисков не видно").foregroundStyle(.secondary)
                        .frame(maxWidth: .infinity, minHeight: 200)
                }
                Text("Состояние (S.M.A.R.T.) сообщает сам диск: «в порядке» — сбоев не замечено. Для образов, сетевых дисков и многих USB-корпусов оно недоступно.")
                    .font(.caption).foregroundStyle(.tertiary).fixedSize(horizontal: false, vertical: true)
                    .padding(.top, 4)
            }
            .padding(16)
        }
        .fillAvailable()
        .navigationTitle("Диски")
        .toolbar {
            Button { Task { await store.refresh() } } label: { Label("Обновить", systemImage: "arrow.clockwise") }
                .help("Обновить список")
                .disabled(store.loading)
        }
        .task { if store.volumes.isEmpty { await store.refresh() } }
    }
}

private struct VolumeCard: View {
    @Environment(AppState.self) private var state
    let volume: VolumeInfo

    var body: some View {
        let v = volume
        Card {
            HStack(alignment: .top, spacing: 14) {
                Image(systemName: v.kind.symbol)
                    .font(.system(size: 34))
                    .foregroundStyle(Brand.gradient)
                    .frame(width: 48, height: 48)
                VStack(alignment: .leading, spacing: 8) {
                    HStack(spacing: 8) {
                        Text(v.name).font(.title3.weight(.semibold)).lineLimit(1)
                        badge(v.kind.rawValue)
                        if v.isRoot { badge("Загрузочный") }
                        if v.isReadOnly { badge("Только чтение") }
                    }
                    let frac = v.usedFraction
                    SizeBar(fraction: frac, color: frac > 0.9 ? .red : (frac > 0.8 ? .orange : nil), height: 10)
                    HStack {
                        Text("Свободно \(Fmt.bytes(v.available))").fontWeight(.medium)
                        Text("из \(Fmt.bytes(v.total)) · занято \(Fmt.percent(frac))").foregroundStyle(.secondary)
                        Spacer()
                    }
                    .monospacedDigit()
                    HStack(spacing: 14) {
                        detail("Формат", v.format)
                        if let dev = v.device { detail("Устройство", dev) }
                        if let bus = v.bus { detail("Подключение", bus) }
                        if let ssd = v.solidState, v.kind != .diskImage { detail("Тип", ssd ? "SSD" : "HDD") }
                        health(v)
                    }
                    .font(.caption)
                }
                VStack(spacing: 6) {
                    Button { NSWorkspace.shared.open(v.url) } label: { wide(Label("Открыть в Finder", systemImage: "folder")) }
                    Button { state.openMap(v.url) } label: { wide(Label("Карта диска", systemImage: "chart.pie")) }
                    if v.canEject {
                        Button {
                            Task { await state.volumes.eject(v) }
                        } label: {
                            if state.volumes.ejecting.contains(v.id) { wide(ProgressView().controlSize(.small)) } else { wide(Label("Извлечь", systemImage: "eject")) }
                        }
                        .disabled(state.volumes.ejecting.contains(v.id))
                    }
                }
                .frame(width: 170)
            }
        }
    }

    private func wide(_ v: some View) -> some View { v.frame(maxWidth: .infinity) }

    private func badge(_ s: String) -> some View {
        Text(s).font(.caption.weight(.medium))
            .padding(.horizontal, 7).padding(.vertical, 2)
            .background(Brand.blue.opacity(0.12), in: Capsule())
            .foregroundStyle(Brand.blue)
    }

    private func detail(_ k: String, _ v: String) -> some View {
        HStack(spacing: 4) {
            Text(k).foregroundStyle(.tertiary)
            Text(v).foregroundStyle(.secondary)
        }
    }

    @ViewBuilder private func health(_ v: VolumeInfo) -> some View {
        switch v.health {
        case .ok: Label("Состояние: в порядке", systemImage: "checkmark.seal.fill").foregroundStyle(.green)
        case .failing: Label("Диск сбоит — скопируйте данные!", systemImage: "exclamationmark.octagon.fill").foregroundStyle(.red)
        case .unsupported: Label("Состояние недоступно", systemImage: "questionmark.circle").foregroundStyle(.secondary)
        case .unknown: EmptyView()
        }
    }
}
