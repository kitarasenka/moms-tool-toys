import SwiftUI

struct MaintenanceView: View {
    @Environment(AppState.self) private var state

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 12) {
                Text("Небольшие системные процедуры, которые помогают, когда что-то ведёт себя странно. Запускайте по необходимости — регулярно делать их не нужно.")
                    .foregroundStyle(.secondary)
                    .padding(.bottom, 4)
                ForEach(MaintenanceTask.all) { task in
                    TaskRow(task: task)
                }
            }
            .padding(24)
            .frame(maxWidth: 820, alignment: .leading)
            .frame(maxWidth: .infinity)
        }
        .navigationTitle("Обслуживание")
    }
}

private struct TaskRow: View {
    @Environment(AppState.self) private var state
    let task: MaintenanceTask

    var body: some View {
        let status = state.maintenance.status[task.id] ?? .idle
        Card {
            HStack(alignment: .center, spacing: 14) {
                Image(systemName: task.icon)
                    .font(.system(size: 22))
                    .foregroundStyle(Brand.gradient)
                    .frame(width: 34)
                VStack(alignment: .leading, spacing: 3) {
                    HStack(spacing: 6) {
                        Text(task.title).font(.headline)
                        if task.needsAdmin {
                            Image(systemName: "lock.fill").font(.caption).foregroundStyle(.secondary)
                                .help("Понадобится пароль администратора")
                        }
                    }
                    Text(task.detail).font(.callout).foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                    switch status {
                    case .done(let d):
                        Label("Готово в \(d.formatted(Date.FormatStyle(date: .omitted, time: .shortened).locale(L10n.locale)))", systemImage: "checkmark.circle.fill")
                            .font(.caption).foregroundStyle(.green)
                    case .failed(let msg):
                        Label(msg, systemImage: "exclamationmark.triangle.fill")
                            .font(.caption).foregroundStyle(.orange).lineLimit(2)
                    default: EmptyView()
                    }
                }
                Spacer()
                if status == .running {
                    ProgressView().controlSize(.small).frame(width: 90)
                } else {
                    Button("Выполнить") { Task { await state.maintenance.run(task) } }
                        .frame(width: 90)
                }
            }
        }
    }
}
