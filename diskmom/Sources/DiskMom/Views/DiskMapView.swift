import AppKit
import SwiftUI
import UniformTypeIdentifiers

struct DiskMapView: View {
    @Environment(AppState.self) private var state
    @State private var hovered: SunSegment?
    @State private var hoveringCenter = false
    @State private var confirmTrash: FSNode?

    var body: some View {
        let map = state.map
        Group {
            switch map.phase {
            case .idle: idle
            case .scanning:
                ProgressScreen(title: "Сканирую «\(map.targetTitle)»…",
                               detail: "\(Fmt.files(map.progress.files)), папок: \(map.progress.folders.formatted()) · \(Fmt.seconds(map.elapsed))",
                               current: Paths.pretty(map.progress.current)) { map.cancel() }
            case .ready:
                if map.root != nil { ready.fillAvailable() } else { idle }
            }
        }
        .navigationTitle("Карта диска")
        .toolbar {
            ToolbarItemGroup {
                Button { map.up() } label: { Label("Наверх", systemImage: "chevron.left") }
                    .help("На уровень выше (⌘↑)")
                    .keyboardShortcut(.upArrow, modifiers: .command)
                    .disabled(map.phase != .ready || map.focus?.parent == nil)
                targetMenu
                Button { scan() } label: { Label("Сканировать заново", systemImage: "arrow.clockwise") }
                    .help("Сканировать заново")
                    .disabled(map.phase == .scanning)
            }
        }
        .confirmationDialog(confirmTrash.map { "Перенести «\($0.name)» в Корзину?" } ?? "",
                            isPresented: Binding(get: { confirmTrash != nil }, set: { if !$0 { confirmTrash = nil } }),
                            presenting: confirmTrash) { node in
            Button("В Корзину", role: .destructive) { map.trash(node); state.refreshSystem() }
            Button("Отменить", role: .cancel) {}
        } message: { node in
            Text("\(Fmt.bytes(node.size))\(node.fileCount > 1 ? ", " + Fmt.files(node.fileCount) : ""). \(Paths.pretty(node.path))\n\nМожно вернуть из Корзины, пока она не очищена.")
        }
    }

    private func scan() { Task { await state.map.scan(fullDiskAccess: state.fullDiskAccess) } }

    private var targetMenu: some View {
        Menu {
            Button("Домашняя папка") { state.map.target = Paths.home; scan() }
            Button(DiskScanner.volumeName("/") ?? "Macintosh HD") { state.map.target = URL(fileURLWithPath: "/"); scan() }
            Divider()
            Button("Другая папка…") { if pickFolder() { scan() } }
        } label: {
            Label(state.map.targetTitle, systemImage: "folder")
        }
        .help("Что сканировать")
        .disabled(state.map.phase == .scanning)
    }

    private func pickFolder() -> Bool {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.prompt = "Сканировать"
        panel.directoryURL = state.map.target
        guard panel.runModal() == .OK, let url = panel.url else { return false }
        state.map.target = url
        return true
    }

    // MARK: Начальный экран

    private var idle: some View {
        let map = state.map
        return CenteredScroll { VStack(spacing: 16) {
            Image(nsImage: NSApp.applicationIconImage).resizable().interpolation(.high).frame(width: 100, height: 100)
            Text("Карта диска").font(.system(size: 30, weight: .bold, design: .rounded))
            Text("Посчитаю, что сколько места занимает, и покажу это кругами: чем шире сектор, тем больше папка. Щёлкните сектор, чтобы заглянуть внутрь.")
                .font(.title3).foregroundStyle(.secondary).multilineTextAlignment(.center).frame(maxWidth: 560)
            HStack(spacing: 10) {
                choice("Домашняя папка", icon: "house", url: Paths.home)
                choice(DiskScanner.volumeName("/") ?? "Macintosh HD", icon: "internaldrive", url: URL(fileURLWithPath: "/"))
                Button { _ = pickFolder() } label: {
                    choiceLabel(isOther ? map.target.lastPathComponent : "Другая папка…", icon: "folder", on: isOther)
                }
                .buttonStyle(.plain)
            }
            Text(map.target.path).font(.callout).foregroundStyle(.secondary).lineLimit(1).truncationMode(.middle)
            Button("Сканировать") { scan() }
                .buttonStyle(GlowButtonStyle())
                .keyboardShortcut(.defaultAction)
                .padding(.top, 6)
            FullDiskAccessBanner(reason: "Без него контейнеры приложений, Почта и Сообщения не попадут в подсчёт.")
                .frame(maxWidth: 620).padding(.top, 6)
        }
        .padding(30) }
    }

    private var isOther: Bool { state.map.target.path != Paths.home.path && state.map.target.path != "/" }

    private func choice(_ title: String, icon: String, url: URL) -> some View {
        Button { state.map.target = url } label: {
            choiceLabel(title, icon: icon, on: state.map.target.path == url.path)
        }
        .buttonStyle(.plain)
    }

    private func choiceLabel(_ title: String, icon: String, on: Bool) -> some View {
        VStack(spacing: 6) {
            Image(systemName: icon).font(.system(size: 22)).foregroundStyle(on ? AnyShapeStyle(.white) : AnyShapeStyle(Brand.gradient))
            Text(title).font(.callout.weight(.medium)).lineLimit(1).foregroundStyle(on ? .white : .primary)
        }
        .frame(width: 150, height: 64)
        .background(RoundedRectangle(cornerRadius: 12, style: .continuous)
            .fill(on ? AnyShapeStyle(Brand.gradient) : AnyShapeStyle(.background.secondary)))
        .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous).strokeBorder(on ? .clear : Color(nsColor: .separatorColor)))
        .contentShape(Rectangle())
    }

    // MARK: Карта

    private var ready: some View {
        let map = state.map
        _ = map.revision  // перерисовка после переноса в Корзину
        let focus = map.focus ?? map.root!
        let segments = map.segments()
        var colors: [ObjectIdentifier: Int] = [:]
        for s in segments where s.ring == 1 { if let n = s.node { colors[n.id] = s.colorIndex } }
        return VStack(spacing: 0) {
            header(focus)
            Divider()
            HStack(spacing: 0) {
                SunburstView(segments: segments, focus: focus, selected: map.selected,
                             hovered: $hovered, hoveringCenter: $hoveringCenter) { seg in
                    hovered = nil
                    if let seg {
                        if let n = seg.node {
                            if n.canDrill { map.drill(n) } else {
                                if seg.parent !== focus { map.drill(seg.parent) }
                                map.selected = n
                            }
                        } else if seg.parent !== focus {
                            map.drill(seg.parent)
                        }
                    } else {
                        map.up()
                    }
                }
                .padding(16)
                .frame(minWidth: 360, maxWidth: .infinity, maxHeight: .infinity)
                Divider()
                // equatable: наведение на диаграмму не перестраивает длинный список
                ChildList(focus: focus, revision: map.revision, colors: colors, confirmTrash: $confirmTrash)
                    .equatable()
                    .frame(width: 400)
            }
            Divider()
            bottomBar(focus)
        }
    }

    private func header(_ focus: FSNode) -> some View {
        let map = state.map
        let chain = focus.chain
        return VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 4) {
                let shown = chain.count > 6 ? [chain[0]] + chain.suffix(4) : chain
                ForEach(Array(shown.enumerated()), id: \.element.id) { i, n in
                    if i > 0 {
                        Image(systemName: "chevron.right").font(.caption2).foregroundStyle(.tertiary)
                        if chain.count > 6 && i == 1 { Text("…").foregroundStyle(.tertiary); Image(systemName: "chevron.right").font(.caption2).foregroundStyle(.tertiary) }
                    }
                    Button(n.name) { map.jump(n) }
                        .buttonStyle(.plain)
                        .foregroundStyle(n === focus ? AnyShapeStyle(.primary) : AnyShapeStyle(Brand.blue))
                        .fontWeight(n === focus ? .semibold : .regular)
                        .lineLimit(1)
                }
                Spacer()
            }
            HStack(spacing: 14) {
                Text(Fmt.bytes(focus.size)).font(.system(size: 22, weight: .bold, design: .rounded)).monospacedDigit()
                Text(Fmt.files(focus.fileCount)).foregroundStyle(.secondary)
                if let root = map.root {
                    Text("Сканирование: \(Fmt.seconds(map.elapsed)) · \(Fmt.files(root.fileCount)) всего")
                        .foregroundStyle(.tertiary)
                }
                Spacer()
                if let root = map.root, root.denied > 0 {
                    Label("Не прочитано папок: \(root.denied.formatted())", systemImage: "lock")
                        .foregroundStyle(.orange)
                        .help("Системные или закрытые папки — их размер не учтён. С полным доступом к диску их станет меньше.")
                }
            }
            .font(.callout)
            if let root = map.root, root.denied > 0, !state.fullDiskAccess, touchesPrivateData(root.path) {
                FullDiskAccessBanner(reason: "Часть папок не посчитана.")
            }
        }
        .padding(.horizontal, 16).padding(.vertical, 10)
    }

    /// Плашку про полный доступ показываем, только если в сканирование попала ~/Library — там он и нужен.
    private func touchesPrivateData(_ root: String) -> Bool {
        root == Paths.home.path || root == "/" || Paths.isStrictlyInside(Paths.home.path, root)
            || root == Paths.library.path || Paths.isStrictlyInside(root, Paths.library.path)
    }

    private func bottomBar(_ focus: FSNode) -> some View {
        let map = state.map
        let target = map.selected ?? hovered?.node
        return HStack(spacing: 12) {
            if let msg = map.message {
                Label(msg, systemImage: msg.hasPrefix("Не удалось") ? "exclamationmark.triangle" : "checkmark.circle")
                    .foregroundStyle(msg.hasPrefix("Не удалось") ? .orange : .secondary)
                    .lineLimit(1)
            } else if let t = target {
                Text(t.displayName).fontWeight(.medium).lineLimit(1).truncationMode(.middle)
                Text(Fmt.bytes(t.size)).monospacedDigit().foregroundStyle(.secondary)
            } else {
                Text("Щёлкните сектор или строку, чтобы выбрать").foregroundStyle(.secondary)
            }
            Spacer()
            if let s = map.selected {
                Button("Показать в Finder") { Paths.reveal(s.url) }
                Button("В Корзину…") { confirmTrash = s }
                    .buttonStyle(.borderedProminent)
                    .disabled(!s.canTrash)
            }
        }
        .padding(12)
        .background(.bar)
    }
}

// MARK: - Список содержимого

private struct ChildList: View, Equatable {
    @Environment(AppState.self) private var state
    let focus: FSNode
    let revision: Int
    let colors: [ObjectIdentifier: Int]
    @Binding var confirmTrash: FSNode?

    static func == (a: ChildList, b: ChildList) -> Bool {
        a.focus === b.focus && a.revision == b.revision && a.colors == b.colors
    }

    var body: some View {
        let map = state.map
        let sel = Binding<ObjectIdentifier?>(
            get: { map.selected?.id },
            set: { id in map.selected = id.flatMap { i in focus.children.first { $0.id == i } } })
        List(selection: sel) {
            ForEach(focus.children) { n in
                row(n).tag(n.id)
            }
        }
        .contextMenu(forSelectionType: ObjectIdentifier.self) { ids in
            if let id = ids.first, let n = focus.children.first(where: { $0.id == id }) {
                if n.canDrill { Button("Открыть на карте") { map.drill(n) } }
                Button("Показать в Finder") { Paths.reveal(n.url) }
                Divider()
                Button("Переместить в Корзину…") { confirmTrash = n }.disabled(!n.canTrash)
            }
        } primaryAction: { ids in
            if let id = ids.first, let n = focus.children.first(where: { $0.id == id }) {
                if n.canDrill { map.drill(n) } else { Paths.reveal(n.url) }
            }
        }
        .overlay {
            if focus.children.isEmpty { Text("Пусто").foregroundStyle(.secondary) }
        }
    }

    private func row(_ n: FSNode) -> some View {
        let frac = focus.size > 0 ? Double(n.size) / Double(focus.size) : 0
        let ci = colors[n.id] ?? -1
        return HStack(spacing: 8) {
            Circle().fill(Sunburst.color(ci)).frame(width: 8, height: 8)
            icon(n).frame(width: 20, height: 20)
            VStack(alignment: .leading, spacing: 3) {
                HStack {
                    Text(n.displayName).lineLimit(1).truncationMode(.middle)
                    if n.canDrill {
                        Image(systemName: "chevron.right").font(.caption2).foregroundStyle(.tertiary)
                    }
                    Spacer(minLength: 6)
                    Text(sizeText(n)).monospacedDigit().foregroundStyle(.secondary)
                }
                SizeBar(fraction: frac, color: ci >= 0 ? Sunburst.color(ci) : nil, height: 4)
            }
        }
        .padding(.vertical, 2)
        .help(note(n) ?? Paths.pretty(n.path))
    }

    private func sizeText(_ n: FSNode) -> String {
        switch n.kind {
        case .locked: return "закрыто"
        case .cloud: return "в облаке"
        default: return Fmt.bytes(n.size)
        }
    }

    private func note(_ n: FSNode) -> String? {
        switch n.kind {
        case .locked: return "Данные других приложений. Без полного доступа к диску macOS их не показывает."
        case .cloud: return "Облачные диски (iCloud, Google Drive, Dropbox…) не сканируются — файлы там в основном в сети."
        case .smallFiles: return "Файлы меньше 256 КБ в этой папке — одной строкой."
        default: return nil
        }
    }

    @ViewBuilder private func icon(_ n: FSNode) -> some View {
        switch n.kind {
        case .smallFiles: Image(systemName: "doc.on.doc").foregroundStyle(.secondary)
        case .locked: Image(systemName: "lock.fill").foregroundStyle(.orange)
        case .cloud: Image(systemName: "icloud").foregroundStyle(Brand.blue)
        case .folder: Image(nsImage: NSWorkspace.shared.icon(for: .folder)).resizable()
        default: FileIcon(url: n.url, size: 20)
        }
    }
}
