import SwiftUI

struct ChecksView: View {
    @Environment(AppState.self) private var state

    var body: some View {
        Group {
            if state.checks.isEmpty {
                LoadingView(text: String(localized: "Проверяю настройки безопасности…"))
            } else {
                ScrollView {
                    VStack(spacing: 12) {
                        VerdictHeader()
                        ForEach(SystemChecks.sorted(state.checks)) { c in CheckCard(check: c) }
                        Text("SafetyMom ничего не меняет сам: только показывает и открывает нужное место в Системных настройках.")
                            .font(.caption).foregroundStyle(.secondary)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .padding(.top, 2)
                    }
                    .padding(16)
                }
                .fillAvailable()
            }
        }
        .navigationTitle("Проверка")
        .toolbar {
            ToolbarItem {
                Button { Task { await state.runChecks() } } label: { Label("Проверить снова", systemImage: "arrow.clockwise") }
                    .help("Проверить снова (⌘R)")
                    .disabled(state.checksLoading)
            }
        }
    }
}

private struct VerdictHeader: View {
    @Environment(AppState.self) private var state

    var body: some View {
        let v = state.verdict
        Card(tint: v.level.color) {
            HStack(spacing: 18) {
                ZStack {
                    Circle().fill(v.level.color.opacity(0.15)).frame(width: 84, height: 84)
                    Image(systemName: v.level.shield)
                        .font(.system(size: 44, weight: .semibold))
                        .foregroundStyle(v.level.color)
                        .shadow(color: v.level.color.opacity(0.4), radius: 8)
                }
                VStack(alignment: .leading, spacing: 6) {
                    Text(v.title).font(.system(size: 22, weight: .bold, design: .rounded))
                        .fixedSize(horizontal: false, vertical: true)
                    Text(v.subtitle).foregroundStyle(.secondary)
                    TrafficLight(checks: state.checks)
                }
                Spacer(minLength: 8)
                Button {
                    Task { await state.runChecks() }
                } label: {
                    if state.checksLoading {
                        ProgressView().controlSize(.small).tint(.white).frame(width: 110)
                    } else {
                        Text("Проверить снова").frame(minWidth: 110)
                    }
                }
                .buttonStyle(GlowCapsuleStyle())
                .disabled(state.checksLoading)
            }
        }
    }
}

/// Полоска из точек: по одной на проверку, цвет — результат.
private struct TrafficLight: View {
    let checks: [CheckResult]

    var body: some View {
        HStack(spacing: 5) {
            ForEach(SystemChecks.sorted(checks)) { c in
                Circle().fill(c.level.color).frame(width: 10, height: 10).help("\(c.title): \(c.status)")
            }
        }
    }
}

private struct CheckCard: View {
    let check: CheckResult

    var body: some View {
        Card {
            HStack(alignment: .top, spacing: 12) {
                LevelIcon(icon: check.icon, level: check.level)
                VStack(alignment: .leading, spacing: 6) {
                    HStack(alignment: .firstTextBaseline) {
                        Text(check.title).font(.headline)
                        Spacer(minLength: 8)
                        LevelBadge(text: check.status, level: check.level)
                    }
                    Text(check.explain)
                        .font(.callout).foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                    if let advice = check.advice {
                        (Text("Что сделать: ").bold() + Text(advice))
                            .font(.callout)
                            .fixedSize(horizontal: false, vertical: true)
                            .padding(10)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .background(check.level.color.opacity(0.08), in: RoundedRectangle(cornerRadius: 8, style: .continuous))
                    }
                    if let link = check.link, check.level != .ok {
                        Button(link.title) { Settings.open(link) }
                            .controlSize(.small)
                    }
                }
            }
        }
    }
}
