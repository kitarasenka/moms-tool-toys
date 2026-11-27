import SwiftUI

struct DownloadsView: View {
    @Environment(AppState.self) private var state
    @State private var confirm = false

    var body: some View {
        @Bindable var state = state
        Group {
            if state.downloadsDenied {
                AccessDeniedView(folder: String(localized: "Загрузки")) { state.scanDownloads() }
            } else if !state.downloadsScanned {
                ProgressView("Смотрю, что лежит в Загрузках…").frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                VStack(spacing: 0) {
                    controls.padding(12)
                    Divider()
                    if state.visibleDownloads.isEmpty {
                        EmptyStateView(icon: "checkmark.seal", title: String(localized: "Здесь пусто"),
                                       text: state.downloads.isEmpty ? String(localized: "В Загрузках ничего нет.")
                                                                     : String(localized: "Под этот фильтр ничего не подходит."))
                    } else {
                        table
                    }
                    Divider()
                    footer.padding(12)
                }
            }
        }
        .navigationTitle("Загрузки")
        .navigationSubtitle(state.downloadsBusy ? String(localized: "обновляется…") : Fmt.files(state.downloads.count))
        .confirmationDialog(String(localized: "Перенести в Корзину \(Fmt.files(state.selectedDownloads.count))?"), isPresented: $confirm) {
            Button("В Корзину", role: .destructive) { state.trashSelected() }
            Button("Отмена", role: .cancel) {}
        } message: {
            Text("\(Fmt.bytes(state.selectedSize)). Пока Корзина не очищена, всё можно вернуть — кнопкой в «Журнале» или из самой Корзины.")
        }
    }

    private var controls: some View {
        @Bindable var state = state
        return VStack(alignment: .leading, spacing: 10) {
            Picker("Показать", selection: $state.dlFilter) {
                ForEach(DLFilter.allCases) { f in
                    Text("\(f.short) \(state.downloads(f).count)").tag(f)
                }
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            HStack(alignment: .top, spacing: 10) {
                Image(systemName: "lightbulb").foregroundStyle(.yellow)
                Text("Установщики (.dmg, .pkg) после установки не нужны — само приложение уже в «Программах». Отметка «уже установлено» — догадка по имени файла: проверьте, прежде чем удалять.")
                    .font(.callout).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            }
            HStack {
                Picker("«Давно» — это", selection: $state.oldDays) {
                    Text("больше месяца").tag(30)
                    Text("больше 3 месяцев").tag(90)
                    Text("больше полугода").tag(180)
                    Text("больше года").tag(365)
                }
                .fixedSize()
                Spacer()
                Button("Отметить предложенное (\(state.suggested.count))") { state.selectSuggested() }
                    .disabled(state.suggested.isEmpty)
                    .help("Установщики уже установленных приложений и установщики, которые давно не открывали")
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var table: some View {
        Table(state.visibleDownloads) {
            TableColumn("") { (e: Entry) in
                Toggle("", isOn: Binding(get: { state.dlSelected.contains(e.id) },
                                         set: { if $0 { state.dlSelected.insert(e.id) } else { state.dlSelected.remove(e.id) } }))
                    .labelsHidden().toggleStyle(.checkbox)
            }
            .width(22)
            TableColumn("Имя") { (e: Entry) in
                HStack(spacing: 8) {
                    FileIcon(entry: e, size: 20)
                    Text(e.name).lineLimit(1).truncationMode(.middle)
                    if let app = e.installedMatch {
                        Tag(text: String(localized: "уже установлено"), tint: .green)
                            .help("Похоже на «\(app)» в «Программах». Это догадка по имени файла.")
                    }
                    if e.isOld(days: state.oldDays) { Tag(text: String(localized: "давно"), tint: .orange) }
                }
                .contextMenu { Button("Показать в Finder") { state.reveal(e.url) } }
            }
            TableColumn("Размер") { (e: Entry) in
                Text(Fmt.bytes(e.size)).monospacedDigit().foregroundStyle(e.isLarge ? .primary : .secondary)
            }
            .width(min: 70, ideal: 85, max: 110)
            TableColumn("Последний раз") { (e: Entry) in
                Text(Fmt.ago(e.lastTouched)).foregroundStyle(.secondary)
                    .help("Скачан \(Fmt.date(e.added)), изменён \(Fmt.date(e.modified)), открыт \(Fmt.date(e.lastUsed))")
            }
            .width(min: 100, ideal: 130, max: 170)
        }
    }

    private var footer: some View {
        HStack {
            let n = state.selectedDownloads.count
            Text(n == 0 ? String(localized: "Ничего не отмечено")
                        : String(localized: "Отмечено: \(Fmt.files(n)), \(Fmt.bytes(state.selectedSize))"))
                .monospacedDigit()
            Spacer()
            if n > 0 { Button("Снять отметки") { state.dlSelected = [] } }
            Button {
                confirm = true
            } label: {
                Label("В Корзину…", systemImage: "trash")
            }
            .buttonStyle(.borderedProminent)
            .disabled(n == 0 || state.downloadsBusy)
        }
    }
}
