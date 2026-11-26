import Foundation

// Крупные файлы в домашней папке. ~/Library, скрытые файлы и содержимое пакетов (.app, медиатека
// «Фото» и т. п.) не просматриваются — их чистят другие разделы или трогать их нельзя по частям.

struct LargeFile: Identifiable, Hashable, Sendable {
    let url: URL
    let size: Int64
    let modified: Date?
    var id: String { url.path }
    var name: String { url.lastPathComponent }
    var folder: String { Paths.pretty(url.deletingLastPathComponent()) }
}

enum LargeFileScanner {
    /// Порог сбора: меньше этого не храним, дальше фильтрует экран.
    static let floor: Int64 = 20_000_000

    static func scan(progress: @Sendable (Int) -> Void) -> [LargeFile] {
        let keys: [URLResourceKey] = [.isRegularFileKey, .isDirectoryKey, .totalFileAllocatedSizeKey,
                                      .fileAllocatedSizeKey, .contentModificationDateKey]
        let skip: Set<String> = [Paths.library.path, Paths.home.appendingPathComponent("Applications").path]
        guard let e = FileManager.default.enumerator(
            at: Paths.home, includingPropertiesForKeys: keys,
            options: [.skipsHiddenFiles, .skipsPackageDescendants], errorHandler: { _, _ in true })
        else { return [] }

        var out: [LargeFile] = []
        var seen = 0
        while let url = e.nextObject() as? URL {
            seen += 1
            if seen % 2000 == 0 { progress(seen) }
            guard let v = try? url.resourceValues(forKeys: Set(keys)) else { continue }
            if v.isDirectory == true {
                // node_modules — тысячи мелких файлов зависимостей, вручную там чистить нечего.
                if skip.contains(url.standardizedFileURL.path) || url.lastPathComponent == "node_modules" {
                    e.skipDescendants()
                }
                continue
            }
            guard v.isRegularFile == true else { continue }
            let size = Int64(v.totalFileAllocatedSize ?? v.fileAllocatedSize ?? 0)
            if size >= floor { out.append(LargeFile(url: url, size: size, modified: v.contentModificationDate)) }
        }
        progress(seen)
        return out.sorted { $0.size > $1.size }
    }

    struct TrashReport: Sendable {
        var freed: Int64 = 0
        var removed: [String] = []
        var failures: [String] = []
    }

    static func trash(_ files: [LargeFile]) -> TrashReport {
        var r = TrashReport()
        for f in files where Paths.isStrictlyInside(f.url, Paths.home) {
            do {
                try FileManager.default.trashItem(at: f.url, resultingItemURL: nil)
                r.freed += f.size
                r.removed.append(f.id)
            } catch {
                r.failures.append("\(f.name): \(Cleaner.reason(error))")
            }
        }
        return r
    }
}
