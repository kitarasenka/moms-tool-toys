import SwiftUI

struct SmartCleanView: View {
    @Environment(AppState.self) private var state
    @State private var confirm = false

    var body: some View {
        let junk = state.junk
        Group {
            switch junk.phase {
            case .idle: idle
            case .scanning: progress(title: "Ищу мусор…", detail: "Кэши, журналы, временные файлы, Корзина, загрузки", value: nil)
            case .ready: ready
            case .cleaning:
                progress(title: "Очищаю…", detail: "\(junk.cleanedCount) из \(junk.cleaningTotal)",
                         value: Double(junk.cleanedCount) / Double(max(junk.cleaningTotal, 1)))
            case .done: done
            }
        }
        .navigationTitle("Умная очистка")
        .confirmationDialog("Очистить \(Fmt.bytes(junk.totalSelected))?", isPresented: $confirm) {
            Button("Очистить", role: .destructive) { Task { await junk.clean(); state.refreshSystem() } }
            Button("Отменить", role: .cancel) {}
        } message: {
            Text(CleanText.confirmation(junk))
        }
    }

    private var hero: some View {
        Image(nsImage: NSApp.applicationIconImage)
            .resizable().interpolation(.high)
            .frame(width: 132, height: 132)
    }

    private var idle: some View {
        VStack(spacing: 18) {
            hero
            Text("Умная очистка").font(.system(size: 30, weight: .bold, design: .rounded))
            Text("Найду кэши, журналы, временные файлы и другой мусор, который можно удалить без вреда. Перед очисткой покажу, что нашлось.")
                .font(.title3).foregroundStyle(.secondary).multilineTextAlignment(.center).frame(maxWidth: 520)
            Button("Сканировать") { Task { await state.junk.scan() } }
                .buttonStyle(GlowButtonStyle())
                .keyboardShortcut(.defaultAction)
                .padding(.top, 10)
            FullDiskAccessBanner().frame(maxWidth: 620).padding(.top, 8)
        }
        .padding(30)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private func progress(title: String, detail: String, value: Double?) -> some View {
        VStack(spacing: 16) {
            ZStack {
                Circle().stroke(Brand.blue.opacity(0.15), lineWidth: 10)
                if let value {
                    Circle().trim(from: 0, to: value)
                        .stroke(Brand.gradient, style: StrokeStyle(lineWidth: 10, lineCap: .round))
                        .rotationEffect(.degrees(-90))
                        .animation(.easeOut, value: value)
                } else {
                    ProgressView().controlSize(.large)
                }
                hero.frame(width: 96, height: 96).opacity(value == nil ? 0 : 1)
            }
            .frame(width: 150, height: 150)
            Text(title).font(.title2.weight(.semibold))
            Text(detail).foregroundStyle(.secondary).monospacedDigit()
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var ready: some View {
        let junk = state.junk
        return ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                HStack(alignment: .center, spacing: 28) {
                    VStack(alignment: .leading, spacing: 6) {
                        Text("Найдено").font(.title3).foregroundStyle(.secondary)
                        Text(Fmt.bytes(junk.totalFound))
                            .font(.system(size: 46, weight: .bold, design: .rounded)).monospacedDigit()
                        Text("Отмечено к очистке: \(Fmt.bytes(junk.totalSelected))")
                            .foregroundStyle(.secondary).monospacedDigit()
                        HStack {
                            Button("Подробнее…") { state.section = .junk }
                            Button("Сканировать заново") { Task { await junk.scan() } }
                        }
                        .padding(.top, 6)
                    }
                    Spacer()
                    Button {
                        confirm = true
                    } label: {
                        VStack(spacing: 2) {
                            Text("Очистить")
                            Text(Fmt.bytes(junk.totalSelected)).font(.callout).opacity(0.85).monospacedDigit()
                        }
                    }
                    .buttonStyle(GlowButtonStyle(diameter: 140))
                    .disabled(junk.selectedCount == 0)
                    .opacity(junk.selectedCount == 0 ? 0.5 : 1)
                    .keyboardShortcut(.defaultAction)
                }
                .padding(.horizontal, 4)

                if !junk.denied.isEmpty { FullDiskAccessBanner() }

                if junk.found.isEmpty {
                    Card {
                        Label("Мусора не нашлось — на Mac чисто.", systemImage: "checkmark.seal.fill")
                            .font(.title3).foregroundStyle(.green)
                    }
                }

                ForEach(JunkGroup.allCases) { group in
                    let cats = junk.found.filter { $0.group == group }
                    if !cats.isEmpty {
                        Text(group.rawValue).font(.headline).foregroundStyle(.secondary)
                        LazyVGrid(columns: [GridItem(.adaptive(minimum: 320), spacing: 12)], spacing: 12) {
                            ForEach(cats) { CategoryCard(category: $0) }
                        }
                    }
                }
                if junk.trashDenied { FinderTrashCard() }
            }
            .padding(24)
        }
    }

    private var done: some View {
        let junk = state.junk
        let r = junk.report ?? CleanReport()
        return VStack(spacing: 16) {
            Image(systemName: "checkmark.seal.fill")
                .font(.system(size: 84))
                .foregroundStyle(.white, .green)
                .shadow(color: .green.opacity(0.4), radius: 18)
            Text("Освобождено \(Fmt.bytes(r.freed))")
                .font(.system(size: 32, weight: .bold, design: .rounded)).monospacedDigit()
            if r.trashed > 0 {
                Text("\(Fmt.count(r.trashed, "объект перенесён", "объекта перенесены", "объектов перенесены")) в Корзину — место освободится после её очистки.")
                    .foregroundStyle(.secondary)
            }
            if !r.failures.isEmpty {
                DisclosureGroup("Не удалось удалить: \(r.failures.count)") {
                    ScrollView {
                        VStack(alignment: .leading, spacing: 4) {
                            ForEach(r.failures) { f in
                                Text("\(Paths.pretty(URL(fileURLWithPath: f.path))) — \(f.reason)")
                                    .font(.caption).textSelection(.enabled)
                            }
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)
                    }
                    .frame(maxHeight: 160)
                }
                .frame(maxWidth: 560)
            }
            HStack {
                Button("Сканировать снова") { Task { await junk.scan() } }
                    .buttonStyle(.borderedProminent).controlSize(.large)
                Button("Что осталось") { state.section = .junk }.controlSize(.large)
            }
            .padding(.top, 8)
        }
        .padding(30)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

/// Карточка категории на экране умной очистки.
struct CategoryCard: View {
    @Environment(AppState.self) private var state
    let category: JunkCategory

    var body: some View {
        let junk = state.junk
        let skipped = junk.items(category).filter { !$0.preselected && !junk.selected.contains($0.id) }.count
        Card {
            HStack(alignment: .top, spacing: 12) {
                TriCheckbox(state: junk.state(category)) { junk.toggle(category) }
                    .padding(.top, 2)
                Image(systemName: category.icon)
                    .font(.system(size: 22))
                    .foregroundStyle(Brand.gradient)
                    .frame(width: 30)
                VStack(alignment: .leading, spacing: 3) {
                    HStack {
                        Text(category.title).font(.headline)
                        Spacer()
                        Text(Fmt.bytes(junk.total(category))).font(.headline).monospacedDigit()
                    }
                    Text(category.detail).font(.caption).foregroundStyle(.secondary)
                        .lineLimit(3).fixedSize(horizontal: false, vertical: true)
                    if skipped > 0 {
                        Text("Пропущено \(skipped): приложение запущено").font(.caption).foregroundStyle(.orange)
                    }
                    if category.mode == .trash {
                        Text("Перенесётся в Корзину").font(.caption).foregroundStyle(.tertiary)
                    }
                }
            }
        }
        .contentShape(Rectangle())
        .onTapGesture(count: 2) {
            junk.focusedCategory = category.id
            state.section = .junk
        }
        .help("Двойной щелчок — подробности")
    }
}

enum CleanText {
    @MainActor static func confirmation(_ junk: JunkStore) -> String {
        let s = junk.selectionSummary
        var parts: [String] = []
        if s.delete > 0 {
            parts.append("\(Fmt.count(s.delete, "объект", "объекта", "объектов")) (кэши, журналы, временные файлы, Корзина) удалятся сразу — приложения создадут нужное заново.")
        }
        if s.trash > 0 {
            parts.append("\(Fmt.count(s.trash, "объект", "объекта", "объектов")) из Загрузок и резервных копий перенесутся в Корзину.")
        }
        return parts.joined(separator: "\n")
    }
}
