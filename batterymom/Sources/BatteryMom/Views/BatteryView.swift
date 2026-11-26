import SwiftUI

struct BatteryView: View {
    @Environment(AppState.self) private var state

    var body: some View {
        Group {
            if let b = state.battery {
                ScrollView {
                    VStack(alignment: .leading, spacing: 18) {
                        hero(b)
                        tiles(b)
                        TipsCard(battery: b)
                    }
                    .padding(24)
                }
            } else {
                NoBatteryView()
            }
        }
        .fillAvailable()
        .navigationTitle("Батарея")
        .toolbar {
            ToolbarItem {
                Button { state.refreshBattery() } label: { Label("Обновить", systemImage: "arrow.clockwise") }
                    .help("Обновить (⌘R)")
            }
        }
    }

    // MARK: Главный блок

    private func hero(_ b: BatteryInfo) -> some View {
        HStack(alignment: .center, spacing: 32) {
            BatteryRing(percent: b.percent, charging: b.isCharging)
                .padding(10)
            VStack(alignment: .leading, spacing: 10) {
                Text(b.state.title)
                    .font(.system(size: 28, weight: .bold, design: .rounded))
                if let t = b.timeText {
                    Label(t, systemImage: "clock").font(.title3).monospacedDigit()
                } else if b.state == .pluggedNotCharging {
                    Text("macOS придерживает заряд, чтобы батарея меньше изнашивалась (оптимизированная зарядка или предел заряда).")
                        .foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                }
                if let w = b.consumption {
                    Label("Mac потребляет \(Fmt.watts(w))", systemImage: "bolt")
                        .foregroundStyle(.secondary)
                }
                if let p = b.batteryPower, p > 0.5 {
                    Label("Батарея заряжается мощностью \(Fmt.watts(p))", systemImage: "battery.100percent.bolt")
                        .foregroundStyle(.secondary)
                }
                if let a = b.adapter {
                    Label(a.name + (a.watts.map { " · \($0) Вт" } ?? ""), systemImage: "powerplug")
                        .foregroundStyle(.secondary)
                }
                if b.lowPowerMode {
                    Label("Включён режим энергосбережения", systemImage: "leaf")
                        .foregroundStyle(.green)
                }
                if let h = b.health {
                    HStack(spacing: 8) {
                        Image(systemName: b.serviceRecommended ? "exclamationmark.triangle.fill" : "heart.fill")
                            .foregroundStyle(b.serviceRecommended ? AnyShapeStyle(.orange) : AnyShapeStyle(Brand.gradient))
                        Text("Здоровье \(Int(h.rounded())) % — \(BatteryInfo.healthVerdict(h).lowercasedFirst)")
                    }
                    .padding(.top, 4)
                }
            }
            Spacer(minLength: 0)
        }
        .padding(20)
        .background(
            RoundedRectangle(cornerRadius: 18, style: .continuous)
                .fill(LinearGradient(colors: [Brand.cyan.opacity(0.12), Brand.blue.opacity(0.06)],
                                     startPoint: .topLeading, endPoint: .bottomTrailing))
        )
        .overlay(RoundedRectangle(cornerRadius: 18, style: .continuous).strokeBorder(Brand.cyan.opacity(0.25)))
    }

    // MARK: Показатели

    private func tiles(_ b: BatteryInfo) -> some View {
        let cols = [GridItem(.adaptive(minimum: 200), spacing: 12)]
        return LazyVGrid(columns: cols, alignment: .leading, spacing: 12) {
            StatTile(icon: "heart.text.square", title: "Здоровье",
                     value: b.health.map { "\(Int($0.rounded())) %" } ?? "—",
                     note: b.health.map { BatteryInfo.healthVerdict($0) })
            StatTile(icon: b.serviceRecommended ? "exclamationmark.triangle" : "checkmark.seal", title: "Состояние",
                     value: b.conditionTitle,
                     note: b.serviceRecommended ? "Так считает macOS — стоит показать Mac в сервисе" : "Так считает macOS",
                     tint: b.serviceRecommended ? .orange : Brand.blue)
            StatTile(icon: "arrow.triangle.2.circlepath", title: "Циклы перезарядки",
                     value: b.cycleCount.map { "\($0) из \(b.designCycleCount)" } ?? "—",
                     note: b.cycleCount.map { cyclesNote($0, design: b.designCycleCount) })
            StatTile(icon: "battery.100percent", title: "Ёмкость",
                     value: b.maxCapacity.map { "\($0) мА·ч" } ?? "—",
                     note: b.designCapacity.map { "Новая была \($0) мА·ч" + (b.currentCapacity.map { ", сейчас в ней \($0)" } ?? "") })
            StatTile(icon: "thermometer.medium", title: "Температура",
                     value: b.temperature.map { "\(Fmt.number($0)) °C" } ?? "—",
                     note: b.temperature.map(temperatureNote),
                     tint: (b.temperature ?? 0) >= 40 ? .orange : Brand.blue)
            StatTile(icon: "bolt", title: "Мощность",
                     value: b.batteryPower.map { Fmt.watts(abs($0)) } ?? "—",
                     note: powerNote(b))
            StatTile(icon: "waveform.path.ecg", title: "Напряжение и ток",
                     value: [b.voltage.map { "\(Fmt.number($0, digits: 2)) В" }, b.amperage.map { "\(Fmt.number($0, digits: 2)) А" }]
                        .compactMap { $0 }.joined(separator: " · ").ifEmpty("—"),
                     note: "Ток со знаком «минус» — батарея отдаёт энергию")
            StatTile(icon: "powerplug", title: "Адаптер",
                     value: b.adapter.map { a in a.watts.map { "\($0) Вт" } ?? "Подключён" } ?? "Не подключён",
                     note: b.adapter.map { [$0.name, $0.manufacturer].compactMap { $0 }.joined(separator: " · ") })
            if let d = b.manufactureDate {
                StatTile(icon: "calendar", title: "Изготовлена", value: Fmt.date(d))
            }
        }
    }

    private func cyclesNote(_ c: Int, design: Int) -> String {
        let left = design - c
        return left > 0 ? "До расчётного ресурса ещё ≈ \(left)" : "Расчётный ресурс выработан — батарея ещё работает, но слабее"
    }

    private func temperatureNote(_ t: Double) -> String {
        switch t {
        case ..<35: "Нормально"
        case ..<40: "Тёплая — это обычно под нагрузкой"
        default: "Горячая — жара сильнее всего изнашивает батарею"
        }
    }

    private func powerNote(_ b: BatteryInfo) -> String {
        guard let p = b.batteryPower else { return "Нет данных" }
        if p > 0.05 { return "Батарея заряжается" }
        if p < -0.05 { return "Батарея разряжается" }
        return "Ток через батарею не идёт"
    }
}

// MARK: - Советы

struct TipsCard: View {
    let battery: BatteryInfo

    var body: some View {
        Card {
            VStack(alignment: .leading, spacing: 12) {
                Label("Как продлить жизнь батарее", systemImage: "lightbulb")
                    .font(.headline)
                tip("arrow.triangle.2.circlepath",
                    "Цикл перезарядки — это израсходованные 100 % заряда, не обязательно за один раз: два раза по 50 % — один цикл. Apple рассчитывает батареи современных MacBook на 1000 циклов: после них ёмкость обычно около 80 % от новой, и это нормально.")
                tip("bolt.badge.clock",
                    "Оптимизированная зарядка запоминает ваш распорядок и держит заряд на 80 %, пока Mac не понадобится. На Mac с Apple silicon в macOS 15 и новее можно ещё задать предел зарядки (80–100 %).")
                tip("thermometer.sun",
                    "Батарею портит жара: не оставляйте MacBook на солнце и под одеялом, не заряжайте в чехле.")
                tip("powerplug",
                    "Держать MacBook всё время на зарядке можно — macOS сама придерживает заряд. Если месяцами не пользуетесь, оставьте его заряженным примерно наполовину.")
                HStack {
                    Button("Открыть настройки «Аккумулятор»") { SystemSettings.openBattery() }
                    Text("Там же — режим энергосбережения и предел зарядки.")
                        .font(.caption).foregroundStyle(.secondary)
                }
                .padding(.top, 2)
            }
        }
    }

    private func tip(_ icon: String, _ text: String) -> some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: icon)
                .foregroundStyle(Brand.gradient)
                .frame(width: 22)
            Text(text).fixedSize(horizontal: false, vertical: true)
        }
    }
}

extension String {
    var lowercasedFirst: String { prefix(1).lowercased() + dropFirst() }
    func ifEmpty(_ s: String) -> String { isEmpty ? s : self }
}
