import Foundation

// MARK: - Проверки из консоли (до запуска интерфейса, на главном потоке, без MainActor-работы)

enum SelfTest {
    private static func pad(_ s: String, _ n: Int) -> String { s.padding(toLength: max(n, s.count), withPad: " ", startingAt: 0) }

    static func scan(_ path: String, compare: Bool) {
        let url = URL(fileURLWithPath: (path as NSString).expandingTildeInPath)
        var options = DiskScanner.Options()
        options.fullDiskAccess = FullDiskAccess.granted
        let t0 = Date()
        let root = DiskScanner(root: url, options: options).run()
        let dt = Date().timeIntervalSince(t0)
        print("\(Paths.pretty(root.path)): \(Fmt.bytes(root.size)), \(Fmt.files(root.fileCount)), не прочитано папок: \(root.denied) — \(Fmt.seconds(dt))")
        for c in root.children.prefix(10) {
            print("  \(pad(Fmt.bytes(c.size), 10)) \(c.displayName)\(c.kind == .package ? "  [пакет]" : "")\(c.kind == .locked ? "  [закрыто]" : "")")
        }
        guard compare else { return }
        // Сверка с FileManager: та же сумма размеров на диске, без ссылок и чужих томов.
        let t1 = Date()
        var total: Int64 = 0, n = 0
        let keys: [URLResourceKey] = [.isRegularFileKey, .totalFileAllocatedSizeKey, .isDirectoryKey]
        let e = FileManager.default.enumerator(at: url, includingPropertiesForKeys: keys, options: [], errorHandler: { _, _ in true })
        while let f = e?.nextObject() as? URL {
            guard let v = try? f.resourceValues(forKeys: Set(keys)) else { continue }
            if v.isDirectory == true { continue }
            n += 1
            total += Int64(v.totalFileAllocatedSize ?? 0)
        }
        print("FileManager: \(Fmt.bytes(total)), \(Fmt.files(n)) — \(Fmt.seconds(Date().timeIntervalSince(t1)))")
    }

    static func dupes(_ path: String, min: Int64) {
        let url = URL(fileURLWithPath: (path as NSString).expandingTildeInPath)
        let t0 = Date()
        let groups = DupFinder.find(roots: [url], minSize: min)
        print("Групп: \(groups.count), можно освободить \(Fmt.bytes(groups.reduce(0) { $0 + $1.reclaimable })) — \(Fmt.seconds(Date().timeIntervalSince(t0)))")
        for g in groups.prefix(20) {
            print("  \(Fmt.bytes(g.size)) × \(g.files.count): \(g.name)")
            for f in g.files { print("      \(Paths.pretty(f.url))  (\(Fmt.date(f.modified)))") }
        }
    }

    static func volumes() {
        for v in Volumes.list() {
            print("\(pad(v.name, 18)) \(pad(v.kind.rawValue, 12)) \(pad(v.format, 22)) свободно \(Fmt.bytes(v.available)) из \(Fmt.bytes(v.total))  SMART: \(v.health)  извлечь: \(v.canEject ? "да" : "нет")  \(v.device ?? "-") \(v.bus ?? "")")
        }
    }

    // MARK: --selftest

    static func run() {
        let fm = FileManager.default
        let sandbox = Paths.tmp.appendingPathComponent("diskmom-selftest-\(UUID().uuidString)", isDirectory: true)
            .resolvingSymlinksInPath()
        func finish(_ ok: Bool) -> Never {
            try? fm.removeItem(at: sandbox)
            print(ok ? "Всё в порядке" : "ЕСТЬ ОШИБКИ")
            exit(ok ? 0 : 1)
        }
        let a = sandbox.appendingPathComponent("Data/A", isDirectory: true)
        let b = sandbox.appendingPathComponent("Data/B", isDirectory: true)
        let c = sandbox.appendingPathComponent("Data/C", isDirectory: true)
        let lib = a.appendingPathComponent("Фото.photoslibrary/originals", isDirectory: true)
        for d in [a, b, c, lib] { try! fm.createDirectory(at: d, withIntermediateDirectories: true) }
        let trashDir = sandbox.appendingPathComponent("Trash", isDirectory: true)

        var ok = true
        func expect(_ cond: Bool, _ msg: String) { print((cond ? "✓ " : "✗ ") + msg); ok = ok && cond }
        func write(_ data: Data, _ url: URL, age days: Double) {
            try! data.write(to: url)
            try! fm.setAttributes([.modificationDate: Date(timeIntervalSinceNow: -days * 86_400)], ofItemAtPath: url.path)
        }
        func random(_ n: Int) -> Data { Data((0..<n).map { _ in UInt8.random(in: 0...255) }) }

        // Фото: три копии (больше 128 КБ — нужен полный хеш), самая новая — в C, самая старая — в A.
        let photo = random(300_000)
        write(photo, a.appendingPathComponent("photo.jpg"), age: 30)
        write(photo, b.appendingPathComponent("photo copy.jpg"), age: 10)
        write(photo, c.appendingPathComponent("IMG_0001.jpg"), age: 1)
        // Тот же снимок внутри пакета и скрытый — пропускаются.
        write(photo, lib.appendingPathComponent("photo.jpg"), age: 5)
        write(photo, a.appendingPathComponent(".hidden.jpg"), age: 5)
        // Ссылка на фото — не файл.
        try! fm.createSymbolicLink(at: c.appendingPathComponent("link.jpg"), withDestinationURL: a.appendingPathComponent("photo.jpg"))
        // Одинаковые начало и конец, разная середина — не дубликаты.
        var mid1 = random(400_000), mid2 = mid1
        mid1[200_000] = 1; mid2[200_000] = 2
        write(mid1, a.appendingPathComponent("almost1.bin"), age: 3)
        write(mid2, b.appendingPathComponent("almost2.bin"), age: 3)
        // Документ: две копии (≤128 КБ — хватает быстрого хеша) + жёсткая ссылка на одну из них.
        let doc = random(120_000)
        write(doc, a.appendingPathComponent("doc.pdf"), age: 20)
        write(doc, b.appendingPathComponent("doc.pdf"), age: 2)
        try! fm.linkItem(at: a.appendingPathComponent("doc.pdf"), to: c.appendingPathComponent("doc-hardlink.pdf"))
        // Мелкие одинаковые — меньше порога.
        let tiny = random(5_000)
        write(tiny, a.appendingPathComponent("tiny.txt"), age: 1)
        write(tiny, b.appendingPathComponent("tiny.txt"), age: 1)

        print("— Поиск дубликатов")
        let roots = [sandbox.appendingPathComponent("Data"), a]  // папки пересекаются нарочно
        let groups = DupFinder.find(roots: roots, minSize: 100_000)
        let photoG = groups.first { $0.size == 300_000 }
        let docG = groups.first { $0.size == 120_000 }
        expect(groups.count == 2, "найдено 2 группы (\(groups.count))")
        expect(photoG?.files.count == 3, "фото: 3 копии, без пакета, скрытого файла и ссылки (\(photoG?.files.count ?? 0))")
        expect(docG?.files.count == 2, "документ: 2 копии, жёсткая ссылка не считается (\(docG?.files.count ?? 0))")
        expect(!groups.contains { $0.size == 400_000 }, "файлы с разной серединой не дубликаты")
        expect(!groups.contains { $0.size == 5_000 }, "файлы меньше порога не учитываются")
        guard let photoG, let docG else { finish(false) }

        print("— Автовыбор")
        var sel = DupSelection.apply(.keepNewest, to: groups)
        expect(!sel.contains(c.appendingPathComponent("IMG_0001.jpg").path) && sel.count == 3,
               "«самый новый»: остаётся IMG_0001.jpg из C, отмечено 3")
        let oldest = DupSelection.apply(.keepOldest, to: groups)
        expect(!oldest.contains(a.appendingPathComponent("photo.jpg").path) && !oldest.contains(a.appendingPathComponent("doc.pdf").path),
               "«самый старый»: остаются копии из A")
        let inB = DupSelection.apply(.keepIn(b), to: groups)
        expect(!inB.contains(b.appendingPathComponent("photo copy.jpg").path) && !inB.contains(b.appendingPathComponent("doc.pdf").path) && inB.count == 3,
               "«в папке B»: остаются копии из B")
        for g in groups {
            expect(g.files.filter { !sel.contains($0.id) }.count >= 1, "в группе «\(g.name)» осталась копия")
        }

        print("— Защита «не все копии»")
        let lastDoc = docG.files.first { !sel.contains($0.id) }!
        expect(!DupSelection.canSelect(lastDoc, in: docG, selected: sel), "последнюю копию документа отметить нельзя")
        let allSelected = Set(groups.flatMap { $0.files.map(\.id) })
        let safe = DupSelection.safeToTrash(groups, selected: allSelected)
        expect(safe.count == 3, "даже если отмечено всё, в Корзину уходит по n−1 из группы (\(safe.count))")

        print("— Перенос в Корзину (песочница)")
        sel.remove(photoG.files.first { sel.contains($0.id) }!.id)  // одну лишнюю копию фото пользователь оставил
        let expected = Set(DupSelection.safeToTrash(groups, selected: sel).map(\.id))
        let r = DupSelection.trash(groups, selected: sel, trasher: .folder(trashDir))
        expect(r.failures.isEmpty && Set(r.trashed.map(\.id)) == expected, "в Корзину ушло ровно отмеченное (\(r.trashed.count))")
        for f in groups.flatMap(\.files) {
            let exists = fm.fileExists(atPath: f.url.path)
            expect(exists != expected.contains(f.id), "\(f.name) из \(f.folder.lastPathComponent): \(exists ? "на месте" : "в Корзине")")
        }
        expect(fm.fileExists(atPath: a.appendingPathComponent("almost1.bin").path) && fm.fileExists(atPath: a.appendingPathComponent("tiny.txt").path),
               "неотмеченные файлы не тронуты")
        let left = DupSelection.removing(r.trashed, from: groups)
        expect(left.count == 1 && left[0].files.count == 2, "осталась одна группа (фото, 2 копии)")

        print("— Карта диска")
        let data = sandbox.appendingPathComponent("Data")
        let tree = DiskScanner(root: data).run()
        var fmTotal: Int64 = 0, fmCount = 0
        let e = FileManager.default.enumerator(at: data, includingPropertiesForKeys: [.isRegularFileKey, .totalFileAllocatedSizeKey, .isSymbolicLinkKey])
        while let f = e?.nextObject() as? URL {
            let v = try! f.resourceValues(forKeys: [.isRegularFileKey, .totalFileAllocatedSizeKey, .isSymbolicLinkKey])
            if v.isRegularFile == true || v.isSymbolicLink == true { fmTotal += Int64(v.totalFileAllocatedSize ?? 0); fmCount += 1 }
        }
        expect(tree.size == fmTotal && tree.fileCount == fmCount,
               "размер дерева совпадает с FileManager (\(tree.size) / \(fmTotal), \(tree.fileCount) / \(fmCount))")
        let nodeA = tree.children.first { $0.name == "A" }!
        let pkg = nodeA.children.first { $0.name.hasSuffix(".photoslibrary") }
        expect(pkg?.kind == .package && pkg?.children.isEmpty == true && (pkg?.size ?? 0) >= 300_000,
               "медиатека — один объект-пакет с полным размером")
        do {
            try SizeTree.trash(tree, trasher: .folder(trashDir))
            expect(false, "корень сканирования в Корзину не уходит")
        } catch { expect(fm.fileExists(atPath: data.path), "корень сканирования в Корзину не уходит") }
        let before = tree.size, beforeA = nodeA.size, pkgSize = pkg!.size
        do {
            try SizeTree.trash(pkg!, trasher: .folder(trashDir))
            expect(!fm.fileExists(atPath: a.appendingPathComponent("Фото.photoslibrary").path), "пакет перенесён")
            expect(nodeA.size == beforeA - pkgSize && tree.size == before - pkgSize, "размеры родителей уменьшились на \(pkgSize)")
            expect(!nodeA.children.contains { $0 === pkg }, "узел убран из дерева")
        } catch { expect(false, "перенос пакета: \(error.localizedDescription)") }

        finish(ok)
    }
}
