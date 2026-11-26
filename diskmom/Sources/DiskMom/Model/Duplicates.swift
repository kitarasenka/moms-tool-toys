import CryptoKit
import Foundation
import os

// MARK: - Дубликаты

struct DupFile: Identifiable, Hashable, Sendable {
    let url: URL
    let size: Int64
    let modified: Date?
    let created: Date?

    var id: String { url.path }
    var name: String { url.lastPathComponent }
    var folder: URL { url.deletingLastPathComponent() }
}

struct DupGroup: Identifiable, Sendable {
    let id: String  // хеш содержимого
    let size: Int64
    var files: [DupFile]

    var reclaimable: Int64 { size * Int64(max(files.count - 1, 0)) }
    var name: String { files.first?.name ?? "" }
}

final class DupProgress: @unchecked Sendable {
    struct Snapshot: Sendable {
        var phase = "Собираю список файлов"
        var done = 0
        var total = 0
    }

    private let state = OSAllocatedUnfairLock(initialState: Snapshot())
    private let stop = OSAllocatedUnfairLock(initialState: false)

    var snapshot: Snapshot { state.withLock { $0 } }
    var isCancelled: Bool { stop.withLock { $0 } }
    func cancel() { stop.withLock { $0 = true } }
    func set(_ phase: String, total: Int) { state.withLock { $0 = Snapshot(phase: phase, done: 0, total: total) } }
    func step(_ n: Int = 1) { state.withLock { $0.done += n } }
}

/// Поиск одинаковых файлов: группы по размеру → хеш первых и последних 64 КБ → полный SHA-256.
/// Пакеты (.photoslibrary, .app…) и скрытые файлы пропускаются, жёсткие ссылки на один файл
/// дубликатами не считаются, ~/Library не просматривается (данные приложений).
enum DupFinder {
    static let window = 64 * 1024

    static func find(roots: [URL], minSize: Int64, progress: DupProgress = DupProgress()) -> [DupGroup] {
        // 1. Список файлов
        let keys: [URLResourceKey] = [.isRegularFileKey, .fileSizeKey, .contentModificationDateKey,
                                      .creationDateKey, .fileResourceIdentifierKey]
        let library = Paths.library.path
        var bySize: [Int64: [DupFile]] = [:]
        var seenPaths = Set<String>()
        var seenIDs = Set<NSObject>()
        progress.set("Собираю список файлов", total: 0)
        for root in roots {
            let e = FileManager.default.enumerator(at: root, includingPropertiesForKeys: keys,
                                                   options: [.skipsPackageDescendants, .skipsHiddenFiles],
                                                   errorHandler: { _, _ in true })
            while let url = e?.nextObject() as? URL {
                if progress.isCancelled { return [] }
                if url.path == library { e?.skipDescendants(); continue }
                guard let v = try? url.resourceValues(forKeys: Set(keys)), v.isRegularFile == true,
                      let size = v.fileSize, Int64(size) >= minSize else { continue }
                let path = url.standardizedFileURL.path
                guard seenPaths.insert(path).inserted else { continue }  // папки пересекаются
                if let rid = v.fileResourceIdentifier as? NSObject, !seenIDs.insert(rid).inserted { continue }  // жёсткая ссылка
                bySize[Int64(size), default: []].append(
                    DupFile(url: URL(fileURLWithPath: path), size: Int64(size),
                            modified: v.contentModificationDate, created: v.creationDate))
                progress.step()
            }
        }

        // 2. Начало и конец файла
        let sameSize = bySize.values.filter { $0.count > 1 }
        var candidates = sameSize.flatMap { $0 }
        progress.set("Сравниваю начало и конец файлов", total: candidates.count)
        let partial = hashAll(candidates, progress: progress) { partialHash($0.url, size: $0.size) }
        if progress.isCancelled { return [] }
        var byPartial: [String: [DupFile]] = [:]
        for (i, f) in candidates.enumerated() {
            guard let h = partial[i] else { continue }
            byPartial["\(f.size)-\(h)", default: []].append(f)
        }

        // 3. Полный хеш — только там, где начало и конец не покрывают весь файл
        var groups: [DupGroup] = []
        var needFull: [DupFile] = []
        for (key, list) in byPartial where list.count > 1 {
            if list[0].size <= Int64(2 * window) {
                groups.append(DupGroup(id: key, size: list[0].size, files: list))
            } else {
                needFull.append(contentsOf: list)
            }
        }
        candidates = needFull
        progress.set("Сверяю содержимое целиком", total: candidates.count)
        let full = hashAll(candidates, progress: progress) { fullHash($0.url) }
        if progress.isCancelled { return [] }
        var byFull: [String: [DupFile]] = [:]
        for (i, f) in candidates.enumerated() {
            guard let h = full[i] else { continue }
            byFull["\(f.size)-\(h)", default: []].append(f)
        }
        for (key, list) in byFull where list.count > 1 {
            groups.append(DupGroup(id: key, size: list[0].size, files: list))
        }

        for i in groups.indices {
            groups[i].files.sort { ($0.modified ?? .distantPast) > ($1.modified ?? .distantPast) }
        }
        return groups.sorted { $0.reclaimable != $1.reclaimable ? $0.reclaimable > $1.reclaimable : $0.name < $1.name }
    }

    private static func hashAll(_ files: [DupFile], progress: DupProgress,
                                _ hash: @Sendable (DupFile) -> String?) -> [String?] {
        var out = [String?](repeating: nil, count: files.count)
        out.withUnsafeMutableBufferPointer { buf in
            let base = buf.baseAddress!
            DispatchQueue.concurrentPerform(iterations: files.count) { i in
                if progress.isCancelled { return }
                base[i] = autoreleasepool { hash(files[i]) }
                progress.step()
            }
        }
        return out
    }

    static func partialHash(_ url: URL, size: Int64) -> String? {
        guard let h = try? FileHandle(forReadingFrom: url) else { return nil }
        defer { try? h.close() }
        var sha = SHA256()
        guard let head = try? h.read(upToCount: window) ?? Data() else { return nil }
        sha.update(data: head)
        if size > Int64(window) {
            let tailStart = UInt64(max(Int64(window), size - Int64(window)))
            guard (try? h.seek(toOffset: tailStart)) != nil, let tail = try? h.read(upToCount: window) ?? Data() else { return nil }
            sha.update(data: tail)
        }
        return hex(sha.finalize())
    }

    static func fullHash(_ url: URL) -> String? {
        guard let h = try? FileHandle(forReadingFrom: url) else { return nil }
        defer { try? h.close() }
        var sha = SHA256()
        while true {
            // nil или пустой кусок — конец файла; ошибка чтения — файл пропускается.
            let r: Result<Data?, Error> = autoreleasepool { Result { try h.read(upToCount: 1 << 20) } }
            guard case .success(let chunk) = r else { return nil }
            guard let chunk, !chunk.isEmpty else { break }
            sha.update(data: chunk)
        }
        return hex(sha.finalize())
    }

    private static func hex(_ d: SHA256.Digest) -> String { d.map { String(format: "%02x", $0) }.joined() }
}

// MARK: - Выбор копий

/// Правила отметки и защита «хотя бы одна копия остаётся». Чистые функции — проверяются в `--selftest`.
enum DupSelection {
    enum Rule: Hashable {
        case keepNewest, keepOldest, keepIn(URL)
    }

    /// Какие файлы отметить к удалению по правилу (в каждой группе хотя бы один остаётся).
    static func apply(_ rule: Rule, to groups: [DupGroup]) -> Set<String> {
        var out = Set<String>()
        for g in groups where g.files.count > 1 {
            let keep: Set<String>
            switch rule {
            case .keepNewest:
                keep = [g.files.max { ($0.modified ?? .distantPast) < ($1.modified ?? .distantPast) }!.id]
            case .keepOldest:
                keep = [g.files.min { ($0.modified ?? .distantFuture) < ($1.modified ?? .distantFuture) }!.id]
            case .keepIn(let folder):
                let inside = g.files.filter { Paths.isStrictlyInside($0.url, folder) }.map(\.id)
                if inside.isEmpty { continue }  // в этой папке копии нет — группу не трогаем
                keep = Set(inside)
            }
            out.formUnion(g.files.map(\.id).filter { !keep.contains($0) })
        }
        return out
    }

    /// Можно ли отметить ещё и этот файл: последнюю неотмеченную копию отмечать нельзя.
    static func canSelect(_ file: DupFile, in group: DupGroup, selected: Set<String>) -> Bool {
        if selected.contains(file.id) { return true }
        let marked = group.files.filter { selected.contains($0.id) }.count
        return marked + 1 < group.files.count
    }

    /// Что на самом деле уйдёт в Корзину. Если в группе каким-то образом отмечены все копии,
    /// самая новая остаётся.
    static func safeToTrash(_ groups: [DupGroup], selected: Set<String>) -> [DupFile] {
        var out: [DupFile] = []
        for g in groups {
            var marked = g.files.filter { selected.contains($0.id) }
            if marked.count >= g.files.count {
                let keep = g.files.max { ($0.modified ?? .distantPast) < ($1.modified ?? .distantPast) }!
                marked.removeAll { $0.id == keep.id }
            }
            out.append(contentsOf: marked)
        }
        return out
    }

    struct TrashResult: Sendable {
        var trashed: [DupFile] = []
        var failures: [String] = []
        var freed: Int64 { trashed.reduce(0) { $0 + $1.size } }
    }

    /// Переносит отмеченные копии в Корзину. Перед переносом проверяет, что файл на месте и не изменился.
    static func trash(_ groups: [DupGroup], selected: Set<String>, trasher: Trasher = .system) -> TrashResult {
        var r = TrashResult()
        for f in safeToTrash(groups, selected: selected) {
            guard let v = try? f.url.resourceValues(forKeys: [.fileSizeKey, .isRegularFileKey]),
                  v.isRegularFile == true, Int64(v.fileSize ?? -1) == f.size else {
                r.failures.append("\(f.name): файл изменился или исчез")
                continue
            }
            do {
                try trasher.move(f.url)
                r.trashed.append(f)
            } catch {
                r.failures.append("\(f.name): \(error.localizedDescription)")
            }
        }
        return r
    }

    /// Убирает перенесённые файлы из групп; группы из одного файла исчезают.
    static func removing(_ trashed: [DupFile], from groups: [DupGroup]) -> [DupGroup] {
        let gone = Set(trashed.map(\.id))
        return groups.compactMap { g in
            var g = g
            g.files.removeAll { gone.contains($0.id) }
            return g.files.count > 1 ? g : nil
        }
    }
}
