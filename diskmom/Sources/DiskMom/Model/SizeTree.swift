import Darwin
import Foundation
import os
import UniformTypeIdentifiers

// MARK: - Дерево размеров

/// Узел карты диска. Дерево строится в фоне, после этого меняется только на главном потоке
/// (перенос в Корзину), поэтому класс помечен @unchecked Sendable.
final class FSNode: Identifiable, @unchecked Sendable {
    enum Kind: UInt8 {
        case folder, file, package
        case smallFiles  // мелкие файлы папки одной строкой (отдельные узлы на миллион файлов — слишком много памяти)
        case locked      // закрыто системой (контейнеры других приложений без полного доступа к диску)
        case cloud       // облачные диски (~/Library/CloudStorage): файлы в основном в сети, не сканируем
    }

    let name: String
    let kind: Kind
    var size: Int64 = 0
    var fileCount = 0
    /// Сколько папок внутри не удалось прочитать.
    var denied = 0
    var children: [FSNode] = []
    weak var parent: FSNode?
    /// Полный путь хранится только у корня, у остальных собирается по родителям.
    var rootPath: String?

    init(name: String, kind: Kind) {
        self.name = name
        self.kind = kind
    }

    var id: ObjectIdentifier { ObjectIdentifier(self) }

    var path: String {
        if let rootPath { return rootPath }
        var names: [String] = []
        var n: FSNode? = self
        while let x = n, x.rootPath == nil { names.append(x.name); n = x.parent }
        // Мелкие файлы — это не отдельный объект, их путь — путь папки.
        if kind == .smallFiles { names.removeFirst() }
        let base = n?.rootPath ?? "/"
        let tail = names.reversed().joined(separator: "/")
        if tail.isEmpty { return base }
        return base.hasSuffix("/") ? base + tail : base + "/" + tail
    }

    var url: URL { URL(fileURLWithPath: path, isDirectory: kind != .file) }

    /// Можно провалиться внутрь (на карте и в списке).
    var canDrill: Bool { kind == .folder && !children.isEmpty }

    /// Реальный объект на диске, не корень сканирования.
    var canTrash: Bool { parent != nil && (kind == .folder || kind == .file || kind == .package) }

    /// Цепочка от корня до узла.
    var chain: [FSNode] {
        var out: [FSNode] = []
        var n: FSNode? = self
        while let x = n { out.append(x); n = x.parent }
        return out.reversed()
    }

    var root: FSNode { chain.first ?? self }

    var displayName: String {
        switch kind {
        case .smallFiles: return "Мелкие файлы (\(fileCount.formatted()))"
        default: return name
        }
    }

    func sortChildren() { children.sort { $0.size > $1.size } }
}

enum SizeTree {
    enum TrashError: LocalizedError {
        case notAllowed, outsideRoot, missing

        var errorDescription: String? {
            switch self {
            case .notAllowed: return "Этот объект нельзя перенести в Корзину"
            case .outsideRoot: return "Объект вне сканированной папки"
            case .missing: return "Объекта уже нет на диске"
            }
        }
    }

    /// Переносит объект в Корзину и вычитает его размер у всех родителей.
    /// Только для узлов строго внутри корня сканирования; сам корень не трогается.
    static func trash(_ node: FSNode, trasher: Trasher = .system) throws {
        guard node.canTrash, let parent = node.parent else { throw TrashError.notAllowed }
        let root = node.root
        guard let rootPath = root.rootPath, Paths.isStrictlyInside(node.path, rootPath) else { throw TrashError.outsideRoot }
        var isDir: ObjCBool = false
        guard FileManager.default.fileExists(atPath: node.path, isDirectory: &isDir) else { throw TrashError.missing }
        try trasher.move(node.url)
        parent.children.removeAll { $0 === node }
        var p: FSNode? = parent
        while let x = p {
            x.size -= node.size
            x.fileCount -= node.fileCount
            x.denied -= node.denied
            p = x.parent
        }
        node.parent = nil
    }
}

// MARK: - Прогресс сканирования

final class ScanProgress: @unchecked Sendable {
    struct Snapshot: Sendable {
        var files = 0
        var folders = 0
        var current = ""
    }

    private let state = OSAllocatedUnfairLock(initialState: Snapshot())
    private let stop = OSAllocatedUnfairLock(initialState: false)

    var snapshot: Snapshot { state.withLock { $0 } }
    var isCancelled: Bool { stop.withLock { $0 } }
    func cancel() { stop.withLock { $0 = true } }

    func add(files: Int, folder: String) {
        state.withLock {
            $0.files += files
            $0.folders += 1
            $0.current = folder
        }
    }
}

// MARK: - Сканер

/// Обходит папку через getattrlistbulk (одним системным вызовом — имя, тип и размер на диске
/// для пачки записей; в разы быстрее FileManager). Ссылки не разыменовываются, пакеты
/// (.app, .photoslibrary…) считаются целиком, но внутрь карты не попадают. Чужие тома
/// внутри папки пропускаются. Первые уровни дерева обходятся параллельно.
final class DiskScanner: @unchecked Sendable {
    struct Options: Sendable {
        /// В папке с большим числом файлов отдельно показываем только файлы от этого размера.
        var fileNodeMin: Int64 = 256_000
        /// Если файлов в папке не больше этого — показываем все.
        var keepAllFilesUpTo = 40
        /// Глубина, до которой подпапки обходятся параллельно.
        var parallelDepth = 3
        var fullDiskAccess = false
    }

    let rootPath: String
    let progress: ScanProgress
    private let options: Options
    private var excluded: Set<String> = []
    private var lockedPaths: Set<String> = []
    private var cloudPaths: Set<String> = []

    init(root: URL, progress: ScanProgress = ScanProgress(), options: Options = Options()) {
        let p = root.standardizedFileURL.path
        rootPath = p.count > 1 && p.hasSuffix("/") ? String(p.dropLast()) : p
        self.progress = progress
        self.options = options
        // Другие тома (точки монтирования) отсекает readDir. У `/` данные пользователя приходят
        // через firmlink-и с тома Data — они не точки монтирования и считаются один раз.
        excluded = ["/System/Volumes", "/Volumes", "/dev", "/private/var/vm", "/net", "/home"]
        excluded.remove(rootPath)
        let lib = Paths.library.path
        if !options.fullDiskAccess {
            // Без полного доступа чтение чужих контейнеров вызывает запросы macOS «доступ к данным других приложений».
            lockedPaths = [lib + "/Containers", lib + "/Group Containers"]
        }
        cloudPaths = [lib + "/CloudStorage"]
    }

    func run() -> FSNode {
        let name = rootPath == "/" ? (Self.volumeName("/") ?? "Macintosh HD") : (rootPath as NSString).lastPathComponent
        let node = scanDir(rootPath, name: name, kind: .folder, depth: 0, keep: true)
        node.rootPath = rootPath
        return node
    }

    // MARK: Обход

    private func scanDir(_ path: String, name: String, kind: FSNode.Kind, depth: Int, keep: Bool) -> FSNode {
        let node = FSNode(name: name, kind: kind)
        if progress.isCancelled { return node }
        let listing: [Entry]
        switch Self.readDir(path, root: rootPath) {
        case .ok(let l): listing = l
        case .denied: node.denied = 1; return node
        case .otherVolume, .gone: return node
        }

        var subdirs: [(name: String, path: String, kind: FSNode.Kind)] = []
        var files: [Entry] = []
        var specials: [FSNode] = []
        for e in listing {
            if e.type == Self.VDIR {
                let child = path == "/" ? "/" + e.name : path + "/" + e.name
                if excluded.contains(child) { continue }
                if lockedPaths.contains(child) { specials.append(FSNode(name: e.name, kind: .locked)); continue }
                if cloudPaths.contains(child) { specials.append(FSNode(name: e.name, kind: .cloud)); continue }
                subdirs.append((e.name, child, Self.isPackage(e.name) ? .package : .folder))
            } else {
                files.append(e)
            }
        }
        progress.add(files: files.count, folder: path)

        // Подпапки
        var subnodes = [FSNode?](repeating: nil, count: subdirs.count)
        if depth < options.parallelDepth && subdirs.count > 1 {
            subnodes.withUnsafeMutableBufferPointer { buf in
                let base = buf.baseAddress!
                DispatchQueue.concurrentPerform(iterations: subdirs.count) { i in
                    let s = subdirs[i]
                    base[i] = scanDir(s.path, name: s.name, kind: s.kind, depth: depth + 1, keep: keep && s.kind == .folder)
                }
            }
        } else {
            for (i, s) in subdirs.enumerated() {
                subnodes[i] = scanDir(s.path, name: s.name, kind: s.kind, depth: depth + 1, keep: keep && s.kind == .folder)
            }
        }

        // Итоги
        var size: Int64 = 0, count = 0, denied = 0
        for case let c? in subnodes { size += c.size; count += c.fileCount; denied += c.denied }
        for c in specials { denied += c.kind == .locked ? 1 : 0 }
        let filesSize = files.reduce(Int64(0)) { $0 + $1.alloc }
        node.size = size + filesSize
        node.fileCount = count + files.count
        node.denied = denied

        guard keep else { return node }
        var kids: [FSNode] = []
        kids.reserveCapacity(subdirs.count + specials.count + 8)
        for case let c? in subnodes { c.parent = node; kids.append(c) }
        for c in specials { c.parent = node; kids.append(c) }
        let keepAll = files.count <= options.keepAllFilesUpTo
        var restSize: Int64 = 0, restCount = 0
        for f in files {
            if keepAll || f.alloc >= options.fileNodeMin {
                let c = FSNode(name: f.name, kind: .file)
                c.size = f.alloc
                c.fileCount = 1
                c.parent = node
                kids.append(c)
            } else {
                restSize += f.alloc
                restCount += 1
            }
        }
        if restCount > 0 {
            let c = FSNode(name: "", kind: .smallFiles)
            c.size = restSize
            c.fileCount = restCount
            c.parent = node
            kids.append(c)
        }
        node.children = kids
        node.sortChildren()
        return node
    }

    // MARK: getattrlistbulk

    struct Entry {
        var name: String
        var type: UInt32
        var alloc: Int64
    }

    enum Listing {
        case ok([Entry])
        case denied, otherVolume, gone
    }

    static let VDIR: UInt32 = 2

    // Значения из <sys/attr.h>
    private static let cmnName: UInt32 = 0x0000_0001
    private static let cmnObjType: UInt32 = 0x0000_0008
    private static let cmnError: UInt32 = 0x2000_0000
    private static let cmnReturnedAttrs: UInt32 = 0x8000_0000
    private static let fileAllocSize: UInt32 = 0x0000_0004
    private static let bufferSize = 128 * 1024

    /// Содержимое папки. Точка монтирования другого тома (кроме самого корня сканирования) — `.otherVolume`.
    static func readDir(_ path: String, root: String) -> Listing {
        let fd = open(path, O_RDONLY | O_DIRECTORY | O_CLOEXEC)
        if fd < 0 { return (errno == EACCES || errno == EPERM) ? .denied : .gone }
        defer { close(fd) }
        if path != root {
            var sfs = statfs()
            if fstatfs(fd, &sfs) == 0 {
                let mnt = withUnsafeBytes(of: &sfs.f_mntonname) { String(decoding: $0.prefix { $0 != 0 }, as: UTF8.self) }
                if mnt == path { return .otherVolume }
            }
        }

        var al = attrlist()
        al.bitmapcount = u_short(ATTR_BIT_MAP_COUNT)
        al.commonattr = cmnReturnedAttrs | cmnName | cmnError | cmnObjType
        al.fileattr = fileAllocSize

        let buf = UnsafeMutableRawPointer.allocate(byteCount: bufferSize, alignment: 16)
        defer { buf.deallocate() }
        var out: [Entry] = []
        while true {
            let n = getattrlistbulk(fd, &al, buf, bufferSize, 0)
            if n < 0 {
                if out.isEmpty && (errno == EACCES || errno == EPERM) { return .denied }
                break
            }
            if n == 0 { break }
            var p = UnsafeRawPointer(buf)
            for _ in 0..<n {
                let length = Int(p.loadUnaligned(as: UInt32.self))
                var c = p + 4
                let retCommon = c.loadUnaligned(as: UInt32.self)
                let retFile = (c + 12).loadUnaligned(as: UInt32.self)
                c += 20  // attribute_set_t
                var err: UInt32 = 0
                if retCommon & cmnError != 0 { err = c.loadUnaligned(as: UInt32.self); c += 4 }
                var name = ""
                if retCommon & cmnName != 0 {
                    let off = Int(c.loadUnaligned(as: Int32.self))
                    name = String(cString: (c + off).assumingMemoryBound(to: CChar.self))
                    c += 8  // attrreference_t
                }
                var type: UInt32 = 0
                if retCommon & cmnObjType != 0 { type = c.loadUnaligned(as: UInt32.self); c += 4 }
                var alloc: Int64 = 0
                if retFile & fileAllocSize != 0 { alloc = c.loadUnaligned(as: Int64.self) }
                p += length
                if err == 0 && !name.isEmpty { out.append(Entry(name: name, type: type, alloc: alloc)) }
            }
        }
        return .ok(out)
    }

    static func volumeName(_ path: String) -> String? {
        try? URL(fileURLWithPath: path).resourceValues(forKeys: [.volumeLocalizedNameKey]).volumeLocalizedName
    }

    // MARK: Пакеты

    private static let knownPackages: Set<String> = [
        "app", "photoslibrary", "musiclibrary", "tvlibrary", "imovielibrary", "fcpbundle", "aplibrary",
        "migratedphotolibrary", "photolibrary", "bundle", "plugin", "kext", "appex", "framework",
        "xcarchive", "xcodeproj", "xcworkspace", "playground", "pages", "numbers", "key", "rtfd",
        "logicx", "band", "sparsebundle", "pkg", "mpkg", "prefpane", "saver", "qlgenerator",
        "mdimporter", "wdgt", "xpc", "systemextension", "docarchive", "playgroundbook", "scptd",
    ]
    private static let packageCache = OSAllocatedUnfairLock(initialState: [String: Bool]())

    /// Папка-пакет (Finder показывает её одним файлом).
    static func isPackage(_ name: String) -> Bool {
        guard let dot = name.lastIndex(of: "."), dot != name.startIndex else { return false }
        let ext = name[name.index(after: dot)...].lowercased()
        guard !ext.isEmpty, ext.count <= 24 else { return false }
        if knownPackages.contains(ext) { return true }
        if let cached = packageCache.withLock({ $0[ext] }) { return cached }
        let isPkg = UTType.types(tag: ext, tagClass: .filenameExtension, conformingTo: nil)
            .contains { $0.isDeclared && $0.conforms(to: .package) }
        packageCache.withLock { $0[ext] = isPkg }
        return isPkg
    }
}
