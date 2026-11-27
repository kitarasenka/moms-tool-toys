import Foundation

// MARK: - Консольные режимы (без окна; ничего не трогают на главном актёре)

enum CLI {
    static func status() {
        if let b = BatteryReader.read() {
            print(String(localized: "Батарея: \(b.percent) % — \(b.state.title)"))
            if let t = b.timeText { print("  \(t)") }
            if let h = b.health { print(String(localized: "  Здоровье: \(Fmt.number(h)) % — \(BatteryInfo.healthVerdict(h))")) }
            print(String(localized: "  Состояние: \(b.conditionTitle)\(b.healthRaw.map { " (\($0))" } ?? "")"))
            print(String(localized: "  Циклы: \(b.cycleCount.map(String.init) ?? "—") из \(b.designCycleCount)"))
            print(String(localized: "  Ёмкость: \(b.maxCapacity.map(String.init) ?? "—") из \(b.designCapacity.map(String.init) ?? "—") мА·ч")
                  + (b.currentCapacity.map { String(localized: ", сейчас \($0) мА·ч") } ?? ""))
            if let t = b.temperature { print(String(localized: "  Температура: \(Fmt.number(t)) °C")) }
            if let v = b.voltage { print(String(localized: "  Напряжение: \(Fmt.number(v, digits: 2)) В")) }
            if let a = b.amperage { print(String(localized: "  Ток: \(Fmt.number(a, digits: 2)) А")) }
            if let p = b.batteryPower { print(String(localized: "  Через батарею: \(Fmt.watts(p))")) }
            if let w = b.consumption { print(String(localized: "  Потребление Mac: \(Fmt.watts(w))")) }
            if let a = b.adapter { print(String(localized: "  Адаптер: \(a.name)\(a.watts.map { String(localized: ", \($0) Вт") } ?? "")")) }
            if let d = b.manufactureDate { print(String(localized: "  Изготовлена: \(Fmt.date(d))")) }
            if b.lowPowerMode { print(String(localized: "  Режим энергосбережения включён")) }
        } else {
            print(String(localized: "У этого Mac нет встроенной батареи"))
        }
        let devices = DeviceScanner.scan()
        print(String(localized: "Устройства: \(devices.isEmpty ? String(localized: "не найдено") : "\(devices.count)")"))
        for d in devices {
            print(String(localized: "  [\(d.connected ? String(localized: "подключено") : String(localized: "не подключено"))] \(d.name) (\(d.kind.title)): \(d.levelsText)\(d.charging ? String(localized: ", заряжается") : "")"))
        }
        let recs = HistoryStore.shared.load()
        print(String(localized: "История: \(recs.count) записей\(recs.last.map { String(localized: ", последняя \($0.t.formatted())") } ?? "") — \(HistoryStore.shared.fileURL.path)"))
    }

    static func energy() {
        let apps = EnergySampler.sample()
        print(String(localized: "Энергопотребление (оценка macOS, как в Мониторинге системы):"))
        for a in apps {
            let n = a.processCount > 1 ? "  (\(Fmt.processes(a.processCount)))" : ""
            print("  \(Fmt.number(a.power).padding(toLength: 7, withPad: " ", startingAt: 0)) \(a.name)\(n)")
        }
    }
}
