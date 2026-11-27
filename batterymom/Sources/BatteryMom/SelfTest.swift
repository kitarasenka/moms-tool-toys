import Foundation

// MARK: - Самопроверка

enum SelfTest {
    static func run() -> Bool {
        var ok = true
        func expect(_ cond: Bool, _ msg: String) { print((cond ? "✓ " : "✗ ") + msg); ok = ok && cond }

        // Батарея Apple silicon: MaxCapacity в процентах, мА·ч — в NominalChargeCapacity.
        let asReg: [String: Any] = [
            "BatteryInstalled": true, "CurrentCapacity": 64, "MaxCapacity": 100, "DesignCapacity": 8694,
            "NominalChargeCapacity": 7596, "AppleRawMaxCapacity": 7352, "AppleRawCurrentCapacity": 4705,
            "CycleCount": 604, "Temperature": 3076, "Voltage": 12100,
            "Amperage": NSNumber(value: UInt64(bitPattern: -1650)),  // так ioreg отдаёт отрицательный ток
            "ExternalConnected": false, "IsCharging": false, "FullyCharged": false,
            "PowerTelemetryData": ["SystemLoad": 20015], "ManufactureDate": 52992232402995 as Int64,
        ]
        let asPS: [String: Any] = ["Type": "InternalBattery", "Is Present": true, "Current Capacity": 64, "Max Capacity": 100,
                                   "Is Charging": false, "Time to Empty": 185, "Time to Full Charge": 0,
                                   "BatteryHealth": "Good", "BatteryHealthCondition": "", "DesignCycleCount": 1000,
                                   "Power Source State": "Battery Power"]
        if let b = BatteryInfo.parse(registry: asReg, source: asPS, adapterDetails: nil) {
            expect(b.percent == 64 && b.state == .onBattery, "Apple silicon: 64 %, от батареи")
            expect(b.maxCapacity == 7596 && b.designCapacity == 8694, "Apple silicon: ёмкость 7596 из 8694 мА·ч")
            expect(abs((b.health ?? 0) - 87.37) < 0.05, "Apple silicon: здоровье \(Fmt.number(b.health ?? 0)) %")
            expect(b.amperage == -1.65 && abs((b.batteryPower ?? 0) + 19.965) < 0.01, "отрицательный ток −1,65 А → разряд ≈ 20 Вт")
            expect(b.consumption == 20.015, "потребление Mac из PowerTelemetryData")
            expect(b.temperature == 30.76, "температура 30,76 °C")
            expect(b.minutesToEmpty == 185 && b.timeText == "Осталось: 3 ч 05 мин", "время: «\(b.timeText ?? "")»")
            expect(b.conditionTitle == "Нормальное" && b.manufactureDate == nil, "состояние нормальное, дата не выдумана")
        } else { expect(false, "Apple silicon: батарея не разобрана") }

        // Intel: всё в мА·ч, дата в формате Smart Battery, обслуживание.
        let packed = (2019 - 1980) << 9 | 7 << 5 | 15
        let inReg: [String: Any] = [
            "BatteryInstalled": true, "CurrentCapacity": 3000, "MaxCapacity": 4000, "DesignCapacity": 5000,
            "CycleCount": 950, "Temperature": 3150, "Voltage": 12500, "Amperage": 2000,
            "ExternalConnected": true, "IsCharging": true, "AvgTimeToFull": 65535, "ManufactureDate": packed,
            "AdapterDetails": ["Watts": 61, "Description": "pd charger"],
        ]
        let inPS: [String: Any] = ["Type": "InternalBattery", "Current Capacity": 75, "Max Capacity": 100, "Is Charging": true,
                                   "Time to Full Charge": -1, "BatteryHealth": "Check Battery", "BatteryHealthCondition": "Check Battery"]
        if let b = BatteryInfo.parse(registry: inReg, source: inPS, adapterDetails: nil) {
            expect(b.percent == 75 && b.state == .charging, "Intel: 75 %, заряжается")
            expect(b.maxCapacity == 4000 && b.health == 80, "Intel: ёмкость 4000 из 5000 мА·ч → 80 %")
            expect(b.serviceRecommended && b.conditionTitle == "Рекомендуется обслуживание", "Intel: рекомендуется обслуживание")
            expect(b.minutesToFull == nil && b.timeText == "До полного: подсчёт…", "Intel: время до полного ещё считается")
            expect(b.adapter?.watts == 61 && b.batteryPower == 25, "Intel: адаптер 61 Вт, заряд 25 Вт")
            let comps = b.manufactureDate.map { Calendar(identifier: .gregorian).dateComponents([.year, .month, .day], from: $0) }
            expect(comps?.year == 2019 && comps?.month == 7 && comps?.day == 15, "Intel: дата изготовления 15.07.2019")
        } else { expect(false, "Intel: батарея не разобрана") }

        expect(BatteryInfo.parse(registry: nil, source: nil, adapterDetails: nil) == nil, "Mac без батареи → nil")
        expect(BatteryInfo.parse(registry: ["BatteryInstalled": false], source: nil, adapterDetails: nil) == nil,
               "BatteryInstalled = No → nil")

        // top: берём второй замер, команда с пробелами, битая кириллица.
        let procs = EnergySampler.parseTop(Fixtures.top)
        expect(procs.count == 6, "top: 6 процессов во втором замере (\(procs.count))")
        expect(procs.first == TopProcess(pid: 462, command: "WindowServer", power: 45.6), "top: первая строка WindowServer 45,6")
        expect(procs.contains { $0.pid == 12609 && $0.command == "Google Chrome He" && $0.power == 0.6 }, "top: имя с пробелами")
        let paths: [Int32: String] = [
            10441: "/Applications/Google Chrome.app/Contents/MacOS/Google Chrome",
            12609: "/Applications/Google Chrome.app/Contents/Frameworks/Google Chrome Framework.framework/Versions/1/Helpers/Google Chrome Helper (Renderer).app/Contents/MacOS/Google Chrome Helper (Renderer)",
            462: "/System/Library/PrivateFrameworks/SkyLight.framework/Versions/A/Resources/WindowServer",
        ]
        let grouped = EnergySampler.group(procs) { paths[$0] }
        let chrome = grouped.first { $0.bundlePath == "/Applications/Google Chrome.app" }
        expect(chrome?.processCount == 2 && abs((chrome?.power ?? 0) - 9.5) < 0.001, "helper Chrome сложен в приложение (9,5)")
        expect(grouped.first?.name == "WindowServer", "без .app — имя из пути")
        expect(grouped.contains { $0.name == "Яндекс М" }, "битая кириллица из top очищена")
        expect(!grouped.contains { $0.power == 0 }, "нулевые не показываются")

        // ioreg: дубликаты одного устройства схлопываются, флаги зарядки.
        let hid = DeviceScanner.parseIoreg(Data(Fixtures.ioreg.utf8))
        expect(hid.count == 2, "ioreg: 2 устройства (\(hid.count))")
        expect(hid.contains { $0.name == "Magic Keyboard" && $0.kind == .keyboard && $0.lowest == 81 && $0.charging },
               "ioreg: Magic Keyboard 81 %, заряжается")
        expect(hid.contains { $0.name == "Magic Mouse" && $0.kind == .mouse && $0.lowest == 9 && !$0.charging }, "ioreg: Magic Mouse 9 %")

        // system_profiler: AirPods с тремя батареями, отключённые с последним значением, без батареи — пропуск.
        let bt = DeviceScanner.parseProfiler(Data(Fixtures.profiler.utf8))
        let pods = bt.first { $0.kind == .airpods }
        expect(pods?.levels.count == 3 && pods?.connected == true && pods?.levelsText == "Л 7 % · П 10 % · футляр 68 %",
               "AirPods: «\(pods?.levelsText ?? "")»")
        expect(bt.contains { $0.name == "Max AP" && $0.kind == .airpodsMax && !$0.connected }, "AirPods Max — не подключены")
        expect(!bt.contains { $0.name == "JBL Flip 5" }, "устройство без батареи пропущено")
        let merged = DeviceScanner.merge(hid: hid, bluetooth: bt)
        expect(merged.filter { $0.name == "Magic Keyboard" }.count == 1, "Magic Keyboard из двух источников — одна строка")
        expect(merged.last?.connected == false, "отключённые — в конце списка")
        expect(DeviceScanner.parseIoreg(Data()).isEmpty && DeviceScanner.parseProfiler(Data("{}".utf8)).isEmpty,
               "пустой вывод — пустой список")

        // История: запись, чтение, обрезка 30 дней, «дыры» и итоги дня во временной папке.
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("batterymom-selftest-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: dir) }
        let store = HistoryStore(directory: dir)
        let now = Date()
        let old = HistoryRecord(t: now.addingTimeInterval(-40 * 86400), p: 50, c: false, a: false)
        store.append(old)
        let base = Calendar.current.startOfDay(for: now).addingTimeInterval(60)
        var recs: [HistoryRecord] = []
        for i in 0..<30 {  // 30 минут от батареи, −1 % в минуту
            recs.append(HistoryRecord(t: base.addingTimeInterval(Double(i) * 60), p: 90 - i, c: false, a: false,
                                      w: 12.34, bw: -12.34, tc: 31.25, cyc: 100))
        }
        for i in 0..<10 {  // через 2 часа — 10 минут на зарядке, +1 цикл
            recs.append(HistoryRecord(t: base.addingTimeInterval(7200 + Double(i) * 60), p: 61 + i, c: true, a: true,
                                      w: 10, bw: 30, tc: 33, cyc: 101))
        }
        for r in recs where r.t <= now { store.append(r) }
        let loaded = store.load()
        let expected = recs.filter { $0.t <= now }
        // Запись старше 30 дней удаляется при первой же записи (обрезка раз в 6 часов) или явным trim.
        store.trim(now: now)
        let trimmed = store.load()
        expect(loaded.count >= expected.count, "история: записано и прочитано \(loaded.count)")
        expect(trimmed.count == expected.count && !trimmed.contains { $0.t < now.addingTimeInterval(-30 * 86400) },
               "история: старше 30 дней удалено, осталось \(trimmed.count)")
        expect(trimmed.first?.w == 12.3 && trimmed.first?.tc == 31.3, "история: значения округлены до десятых")
        let lines = (try? String(contentsOf: store.fileURL, encoding: .utf8))?.split(separator: "\n").count ?? 0
        expect(lines == expected.count, "history.jsonl: по строке на запись (\(lines))")
        if expected.count == recs.count {  // тест запущен не в первые минуты суток
            let pts = HistoryAnalysis.points(trimmed, bucket: 60)
            expect(Set(pts.map(\.segment)).count == 2, "график: «дыра» в 2 часа делит линию на 2 отрезка")
            let day = HistoryAnalysis.days(trimmed, now: now).first
            expect(day?.onBattery == 29 * 60 && day?.drained == 29, "итоги дня: 29 мин от батареи, −29 %")
            expect(day?.cyclesDelta == 1 && day?.minPercent == 61 && day?.maxPercent == 90, "итоги дня: +1 цикл, 61–90 %")
        }
        try? Data("мусор\n".utf8).write(to: store.fileURL, options: .atomic)
        expect(store.load().isEmpty, "битые строки пропускаются")

        print(ok ? "Всё в порядке" : "ЕСТЬ ОШИБКИ")
        return ok
    }
}
