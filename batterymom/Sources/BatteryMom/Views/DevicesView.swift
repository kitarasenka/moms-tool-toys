import SwiftUI

struct DevicesView: View {
    @Environment(AppState.self) private var state

    var body: some View {
        let connected = state.devices.filter(\.connected)
        let offline = state.devices.filter { !$0.connected }

        VStack(alignment: .leading, spacing: 16) {
            ScreenHeader(title: String(localized: "Устройства"),
                         subtitle: String(localized: "Заряд беспроводных мышей, клавиатур, трекпадов и наушников, подключённых по Bluetooth.")) {
                HStack {
                    Button("Настройки Bluetooth") { SystemSettings.openBluetooth() }
                    Button {
                        Task { await state.refreshDevices() }
                    } label: {
                        if state.devicesLoading {
                            ProgressView().controlSize(.small).frame(width: 16)
                        } else {
                            Label("Обновить", systemImage: "arrow.clockwise")
                        }
                    }
                    .disabled(state.devicesLoading)
                    .help("Обновить (⌘R)")
                }
            }
            if state.devices.isEmpty {
                if state.devicesLoading && state.devicesUpdated == nil {
                    ProgressView("Ищу устройства…").frame(maxWidth: .infinity, maxHeight: .infinity)
                } else {
                    EmptyStateView(icon: "headphones",
                                   title: String(localized: "Устройств с батареей не найдено"),
                                   text: String(localized: "Подключите мышь, клавиатуру или наушники по Bluetooth и нажмите «Обновить». Проводные устройства и iPhone здесь не показываются.")) {
                        EmptyView()
                    }
                }
            } else {
                ScrollView {
                    VStack(alignment: .leading, spacing: 18) {
                        if !connected.isEmpty {
                            group(String(localized: "Подключены"), connected)
                        } else {
                            Card {
                                Label("Сейчас ни одно устройство с батареей не подключено.", systemImage: "antenna.radiowaves.left.and.right.slash")
                                    .foregroundStyle(.secondary)
                            }
                        }
                        if !offline.isEmpty {
                            group(String(localized: "Не подключены — последний известный заряд"), offline)
                        }
                    }
                }
                Text("Обновлено \(Fmt.ago(state.devicesUpdated)) · сами по себе устройства опрашиваются раз в 5 минут.")
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
        .padding(24)
        .fillAvailable()
        .navigationTitle("Устройства")
    }

    private func group(_ title: String, _ list: [DeviceBattery]) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(title).font(.headline).foregroundStyle(.secondary)
            LazyVGrid(columns: [GridItem(.adaptive(minimum: 300), spacing: 12)], spacing: 12) {
                ForEach(list) { DeviceCard(device: $0) }
            }
        }
    }
}

struct DeviceCard: View {
    let device: DeviceBattery

    var body: some View {
        Card {
            HStack(alignment: .top, spacing: 14) {
                Image(systemName: device.kind.symbol)
                    .font(.system(size: 26))
                    .foregroundStyle(device.connected ? AnyShapeStyle(Brand.gradient) : AnyShapeStyle(.tertiary))
                    .frame(width: 40, height: 40)
                VStack(alignment: .leading, spacing: 8) {
                    VStack(alignment: .leading, spacing: 1) {
                        Text(device.name).font(.headline).lineLimit(1)
                        HStack(spacing: 4) {
                            Circle().fill(device.connected ? Color.green : Color.secondary.opacity(0.5)).frame(width: 7, height: 7)
                            Text(device.kind.title + (device.connected ? String(localized: " · подключено") : String(localized: " · не подключено"))
                                 + (device.charging ? String(localized: " · заряжается") : ""))
                        }
                        .font(.caption).foregroundStyle(.secondary)
                    }
                    ForEach(device.levels, id: \.self) { l in
                        HStack(spacing: 8) {
                            if device.levels.count > 1 || l.label != nil {
                                Text(l.label ?? String(localized: "Заряд")).font(.caption).foregroundStyle(.secondary).frame(width: 54, alignment: .leading)
                            }
                            LevelBar(fraction: Double(l.percent) / 100,
                                     style: device.connected ? Brand.levelStyle(l.percent) : AnyShapeStyle(Color.secondary.opacity(0.5)),
                                     height: 7)
                            Text("\(l.percent) %")
                                .font(.callout.monospacedDigit().weight(.semibold))
                                .foregroundStyle(device.connected && l.percent <= 20 ? Brand.level(l.percent) : .primary)
                                .frame(width: 48, alignment: .trailing)
                        }
                    }
                }
            }
        }
        .opacity(device.connected ? 1 : 0.8)
    }
}
