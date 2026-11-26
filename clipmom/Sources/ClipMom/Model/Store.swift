import AppKit
import Foundation

/// Файлы истории: `<dir>/history.json` и `<dir>/images/`. Папки — 0700, файлы — 0600.
/// В сеть ничего не уходит: ClipMom вообще не открывает сетевых соединений.
struct HistoryStore {
    let dir: URL
    var imagesDir: URL { dir.appendingPathComponent("images", isDirectory: true) }
    var historyURL: URL { dir.appendingPathComponent("history.json") }

    static var defaultDir: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("ClipMom", isDirectory: true)
    }

    private struct FileFormat: Codable {
        var version = 1
        var items: [ClipItem]
    }

    func prepare() throws {
        let fm = FileManager.default
        for d in [dir, imagesDir] {
            try fm.createDirectory(at: d, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
            try fm.setAttributes([.posixPermissions: 0o700], ofItemAtPath: d.path)
        }
    }

    func load() -> [ClipItem] {
        guard let data = try? Data(contentsOf: historyURL),
              let f = try? JSONDecoder().decode(FileFormat.self, from: data) else { return [] }
        return f.items.sorted { $0.date > $1.date }
    }

    func save(_ items: [ClipItem]) throws {
        try prepare()
        let data = try JSONEncoder().encode(FileFormat(items: items))
        try write(data, to: historyURL)
    }

    func imageURL(_ name: String) -> URL { imagesDir.appendingPathComponent(name) }

    func writeImage(_ data: Data, name: String) throws {
        try prepare()
        try write(data, to: imageURL(name))
    }

    private func write(_ data: Data, to url: URL) throws {
        try data.write(to: url, options: .atomic)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
    }

    func deleteFiles(of item: ClipItem) {
        for name in [item.image, item.thumb].compactMap({ $0 }) {
            try? FileManager.default.removeItem(at: imageURL(name))
        }
    }

    /// Удаляет картинки, на которые не ссылается ни одна запись (например, после сбоя).
    func removeOrphans(keeping items: [ClipItem]) {
        let used = Set(items.flatMap { [$0.image, $0.thumb].compactMap { $0 } })
        let files = (try? FileManager.default.contentsOfDirectory(atPath: imagesDir.path)) ?? []
        for f in files where !used.contains(f) {
            try? FileManager.default.removeItem(at: imageURL(f))
        }
    }
}

/// Логика истории без UI: добавление с дедупликацией, закрепление, удаление, сроки хранения.
/// Используется и приложением (через AppState), и консольной проверкой `--selftest`.
final class History {
    let store: HistoryStore
    private(set) var items: [ClipItem] = []
    var limits = Limits()

    init(store: HistoryStore) {
        self.store = store
    }

    func load() {
        items = store.load()
        store.removeOrphans(keeping: items)
    }

    func save() throws { try store.save(items) }

    /// Добавляет захваченное. То же содержимое не дублируется — запись поднимается наверх.
    @discardableResult
    func ingest(_ c: Captured, source: SourceApp?, now: Date = .now) throws -> ClipItem {
        if let i = items.firstIndex(where: { $0.digest == c.digest }) {
            var it = items.remove(at: i)
            it.date = now
            it.copies += 1
            if let source { it.sourceID = source.bundleID; it.sourceName = source.name }
            items.insert(it, at: 0)
            return it
        }
        var item = ClipItem(kind: c.kind, text: c.text, rtf: c.rtf, files: c.files,
                            pixelWidth: c.pixelWidth, pixelHeight: c.pixelHeight,
                            bytes: c.bytes, digest: c.digest, created: now, date: now,
                            sourceID: source?.bundleID, sourceName: source?.name)
        if let png = c.png {
            let name = "\(item.id.uuidString).png"
            try store.writeImage(png, name: name)
            item.image = name
            if let t = Thumbnail.make(from: png) {
                let tn = "\(item.id.uuidString)-thumb.png"
                try store.writeImage(t, name: tn)
                item.thumb = tn
            }
        }
        items.insert(item, at: 0)
        trim(now: now)
        return item
    }

    /// Только для демо-режима и проверок: вставить готовую запись.
    func insertRaw(_ item: ClipItem) {
        items.append(item)
        items.sort { $0.date > $1.date }
    }

    /// Скопировали из истории — запись поднимается наверх.
    func touch(_ id: UUID, now: Date = .now) {
        guard let i = items.firstIndex(where: { $0.id == id }) else { return }
        var it = items.remove(at: i)
        it.date = now
        items.insert(it, at: 0)
    }

    func setPinned(_ id: UUID, _ pinned: Bool) {
        guard let i = items.firstIndex(where: { $0.id == id }) else { return }
        items[i].pinned = pinned
    }

    func remove(_ id: UUID) {
        guard let i = items.firstIndex(where: { $0.id == id }) else { return }
        store.deleteFiles(of: items.remove(at: i))
    }

    func clear(keepPinned: Bool) {
        let (keep, drop) = items.reduce(into: ([ClipItem](), [ClipItem]())) { acc, it in
            if keepPinned && it.pinned { acc.0.append(it) } else { acc.1.append(it) }
        }
        drop.forEach(store.deleteFiles)
        items = keep
    }

    /// Срок и количество: закреплённые не истекают и не считаются в лимит.
    @discardableResult
    func trim(now: Date = .now) -> [ClipItem] {
        let cutoff = now.addingTimeInterval(-Double(limits.maxDays) * 86_400)
        var keep: [ClipItem] = [], removed: [ClipItem] = []
        var unpinned = 0
        for it in items {
            if it.pinned { keep.append(it); continue }
            if it.date < cutoff || unpinned >= limits.maxCount {
                removed.append(it)
            } else {
                keep.append(it)
                unpinned += 1
            }
        }
        items = keep
        removed.forEach(store.deleteFiles)
        return removed
    }
}

enum Thumbnail {
    /// Миниатюра до 160 пикселей по большей стороне.
    static func make(from png: Data, maxSide: CGFloat = 160) -> Data? {
        guard let src = NSBitmapImageRep(data: png), src.pixelsWide > 0, src.pixelsHigh > 0 else { return nil }
        let w = CGFloat(src.pixelsWide), h = CGFloat(src.pixelsHigh)
        let scale = min(1, maxSide / max(w, h))
        let tw = max(1, Int(w * scale)), th = max(1, Int(h * scale))
        guard let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: tw, pixelsHigh: th, bitsPerSample: 8,
                                         samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
                                         colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0),
              let ctx = NSGraphicsContext(bitmapImageRep: rep) else { return nil }
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = ctx
        ctx.imageInterpolation = .high
        src.draw(in: NSRect(x: 0, y: 0, width: tw, height: th))
        NSGraphicsContext.restoreGraphicsState()
        return rep.representation(using: .png, properties: [:])
    }
}
