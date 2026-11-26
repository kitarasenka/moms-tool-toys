import SwiftUI

private struct PendingClean: Identifiable {
    var report: BrowserReport
    var kind: BrowserDataKind
    var id: String { "\(report.id)|\(kind.rawValue)" }
}

struct BrowsersView: View {
    @Environment(AppState.self) private var state
    @State private var pending: PendingClean?

    var body: some View {
        let b = state.browsers
        Group {
            if b.phase != .ready {
                LoadingView(text: "Ищу браузеры и считаю размеры…")
            } else {
                content.fillAvailable()
            }
        }
        .navigationTitle("Браузеры")
        .task { if b.phase == .idle { await b.load(fullDiskAccess: state.fullDiskAccess) } }
        .toolbar {
            ToolbarItem {
                Button { Task { await b.load(fullDiskAccess: state.fullDiskAccess) } } label: { Label("Обновить", systemImage: "arrow.clockwise") }
                    .help("Пересчитать (⌘R)")
            }
        }
        .alert(pending.map { "\($0.kind.actionTitle) в \($0.report.def.name)?" } ?? "",
               isPresented: Binding(get: { pending != nil }, set: { if !$0 { pending = nil } }), presenting: pending) { p in
            Button(p.kind.actionTitle, role: .destructive) {
                Task { await b.clean(p.report, p.kind, fullDiskAccess: state.fullDiskAccess) }
            }
            Button("Отменить", role: .cancel) {}
        } message: { p in
            Text(confirmText(p))
        }
    }

    private func confirmText(_ p: PendingClean) -> String {
        let t = p.report.target(p.kind)
        let files = "\(Fmt.count(t.files.count, "файл", "файла", "файлов")), \(Fmt.bytes(t.size))"
        let what: String
        switch p.kind {
        case .history:
            what = "Список посещённых сайтов и загрузок пропадёт во всех профилях."
                + (p.report.def.isSafari ? " Если включена синхронизация Safari через iCloud, история может вернуться с других устройств — тогда очистите её в самом Safari." : "")
        case .cookies:
            what = "Вы выйдете из всех сайтов (почта, соцсети, банки) — придётся снова вводить логины и пароли. Сохранённые пароли и закладки не трогаются."
        case .cache:
            what = "Сайты при первом открытии загрузятся чуть медленнее. Больше ничего не изменится."
        }
        let where_ = p.kind.toTrash ? "Файлы (\(files)) переместятся в Корзину — пока она не очищена, их можно вернуть." : "Файлы (\(files)) удалятся сразу."
        return "\(what)\n\n\(where_)"
    }

    private var content: some View {
        let b = state.browsers
        return ScrollView {
            VStack(spacing: 12) {
                FullDiskAccessBanner(reason: "История, cookies и кэш Safari закрыты системой.")
                if let m = b.message { MessageBar(text: m) { b.message = nil } }
                Text("Пароли, закладки и автозаполнение не трогаются никогда. Очищать можно только закрытый браузер.")
                    .font(.callout).foregroundStyle(.secondary).frame(maxWidth: .infinity, alignment: .leading)
                if b.reports.isEmpty {
                    EmptyStateView(icon: "safari", title: "Браузеров не найдено", text: "") {}
                }
                ForEach(b.reports) { r in BrowserCard(report: r) { kind in pending = PendingClean(report: r, kind: kind) } }
            }
            .padding(14)
        }
    }
}

private struct BrowserCard: View {
    @Environment(AppState.self) private var state
    let report: BrowserReport
    let onClean: (BrowserDataKind) -> Void
    @State private var showFiles = false

    var body: some View {
        Card {
            VStack(alignment: .leading, spacing: 12) {
                HStack(spacing: 12) {
                    AppIconView(url: report.appURL, size: 40)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(report.def.name).font(.title3.weight(.semibold))
                        Text(subtitle).font(.caption).foregroundStyle(.secondary)
                    }
                    Spacer()
                    if report.running {
                        Label("запущен — закройте, чтобы очистить", systemImage: "exclamationmark.circle")
                            .font(.callout).foregroundStyle(.orange)
                    }
                }
                HStack(alignment: .top, spacing: 10) {
                    ForEach(BrowserDataKind.allCases) { k in column(k) }
                }
                if BrowserDataKind.allCases.contains(where: { !report.target($0).files.isEmpty }) {
                DisclosureGroup("Какие файлы", isExpanded: $showFiles) {
                    VStack(alignment: .leading, spacing: 3) {
                        ForEach(BrowserDataKind.allCases) { k in
                            let t = report.target(k)
                            ForEach(t.files) { f in
                                HStack {
                                    Text(k.title).foregroundStyle(.secondary).frame(width: 60, alignment: .leading)
                                    Text(Paths.pretty(f.url)).lineLimit(1).truncationMode(.middle).textSelection(.enabled)
                                    Spacer()
                                    Text(Fmt.bytes(f.size)).monospacedDigit().foregroundStyle(.secondary)
                                }
                                .font(.caption)
                            }
                        }
                    }
                    .padding(.top, 4)
                }
                .font(.callout)
                }
            }
        }
    }

    private var subtitle: String {
        if report.def.isSafari { return state.fullDiskAccess ? "встроенный браузер macOS" : "встроенный браузер macOS · нужен полный доступ к диску" }
        let p = report.profiles.filter { !$0.isEmpty }
        return p.isEmpty ? "один профиль" : Fmt.count(p.count, "профиль", "профиля", "профилей")
    }

    private func column(_ k: BrowserDataKind) -> some View {
        let t = report.target(k)
        let busy = state.browsers.busy == "\(report.id)|\(k.rawValue)"
        return VStack(alignment: .leading, spacing: 8) {
            Label(k.title, systemImage: k.icon).font(.headline).foregroundStyle(Brand.blue)
            if let u = t.unavailable {
                Text(u == "нужен доступ" ? "нужен доступ" : u)
                    .font(u == "нужен доступ" ? .title3.weight(.semibold) : .caption)
                    .foregroundStyle(u == "нужен доступ" ? AnyShapeStyle(.orange) : AnyShapeStyle(.secondary))
                    .fixedSize(horizontal: false, vertical: true)
                    .frame(maxHeight: .infinity, alignment: .topLeading)
            } else {
                Text(t.files.isEmpty ? "пусто" : Fmt.bytes(t.size))
                    .font(.title3.weight(.semibold)).monospacedDigit()
                    .foregroundStyle(t.files.isEmpty ? .secondary : .primary)
                Spacer(minLength: 0)
                Button {
                    onClean(k)
                } label: {
                    if busy { ProgressView().controlSize(.small) } else {
                        Text(k == .cookies ? "Очистить cookies" : k.actionTitle)
                    }
                }
                .buttonStyle(GlowCapsuleStyle())
                .disabled(report.running || t.files.isEmpty || state.browsers.busy != nil)
                .help(report.running ? "Сначала закройте \(report.def.name)"
                      : (k == .cookies ? "Вы выйдете из сайтов" : (k.toTrash ? "Файлы уйдут в Корзину" : "Удалить кэш")))
            }
        }
        .padding(12)
        .frame(maxWidth: .infinity, minHeight: 120, alignment: .topLeading)
        .background(.background.opacity(0.6), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
    }
}
