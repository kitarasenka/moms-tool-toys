import AppKit
import SwiftUI

// MARK: - Фирменные цвета (как у иконок Mom's Tool Toys: синий с бирюзовым свечением)

enum Brand {
    static let blue = Color(red: 0.07, green: 0.42, blue: 0.93)
    static let cyan = Color(red: 0.20, green: 0.78, blue: 1.00)
    static let gradient = LinearGradient(colors: [cyan, blue], startPoint: .topLeading, endPoint: .bottomTrailing)
}

extension Level {
    var color: Color {
        switch self {
        case .ok: .green
        case .warn: .orange
        case .bad: .red
        }
    }

    var symbol: String {
        switch self {
        case .ok: "checkmark.circle.fill"
        case .warn: "exclamationmark.triangle.fill"
        case .bad: "exclamationmark.octagon.fill"
        }
    }
}

struct Card<Content: View>: View {
    var tint: Color? = nil
    @ViewBuilder var content: Content

    var body: some View {
        content
            .padding(16)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(tint.map { AnyShapeStyle($0.opacity(0.10)) } ?? AnyShapeStyle(.background.secondary),
                        in: RoundedRectangle(cornerRadius: 14, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: 14, style: .continuous)
                .strokeBorder(tint.map { AnyShapeStyle($0.opacity(0.35)) } ?? AnyShapeStyle(.separator.opacity(0.6))))
    }
}

/// Крупная кнопка с иконкой — для мамы, а не для мелкого шрифта.
struct BigButton: View {
    let title: String
    let icon: String
    var prominent = false
    var disabled = false
    let action: () -> Void

    var body: some View {
        let b = Button(action: action) {
            Label(title, systemImage: icon)
                .font(.body.weight(.medium))
                .padding(.horizontal, 6)
                .padding(.vertical, 4)
        }
        .controlSize(.large)
        .disabled(disabled)
        if prominent {
            b.buttonStyle(.borderedProminent).tint(Brand.blue)
        } else {
            b.buttonStyle(.bordered)
        }
    }
}

/// Кнопка «Открыть <инструмент>»: если инструмент не установлен — серая, с подсказкой.
struct ToolButton: View {
    let tool: SiblingTool

    var body: some View {
        let installed = tool.isInstalled
        Button { tool.open() } label: {
            Label("Открыть \(tool.name)", systemImage: "arrow.up.forward.app")
        }
        .disabled(!installed)
        .help(installed ? "Запустить \(tool.name)" : "\(tool.name) не установлен — его ставит общий установщик Mom's Tool Toys")
    }
}

struct SectionTitle: View {
    let text: String
    var icon: String? = nil

    var body: some View {
        HStack(spacing: 6) {
            if let icon { Image(systemName: icon).foregroundStyle(Brand.blue) }
            Text(text).font(.headline)
        }
    }
}

/// Нумерованный шаг инструкции.
struct StepRow: View {
    let n: Int
    let text: String

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 10) {
            Text("\(n)")
                .font(.callout.weight(.bold))
                .foregroundStyle(.white)
                .frame(width: 22, height: 22)
                .background(Brand.gradient, in: Circle())
            Text(.init(text))
                .fixedSize(horizontal: false, vertical: true)
        }
    }
}

struct EmptyStateView<Actions: View>: View {
    let icon: String
    let title: String
    let text: String
    @ViewBuilder var actions: Actions

    var body: some View {
        VStack(spacing: 14) {
            Image(systemName: icon)
                .font(.system(size: 50, weight: .light))
                .foregroundStyle(Brand.gradient)
            Text(title).font(.title2.weight(.semibold))
            Text(text).foregroundStyle(.secondary).multilineTextAlignment(.center).frame(maxWidth: 420)
            actions.padding(.top, 6)
        }
        .padding(32)
        .frame(maxWidth: .infinity)
    }
}

struct ToastView: View {
    let text: String

    var body: some View {
        Label(text, systemImage: "checkmark.circle.fill")
            .font(.callout.weight(.medium))
            .padding(.horizontal, 16)
            .padding(.vertical, 10)
            .background(.regularMaterial, in: Capsule())
            .overlay(Capsule().strokeBorder(.separator))
            .shadow(color: .black.opacity(0.15), radius: 8, y: 3)
    }
}

extension View {
    /// Жёстко вписывает экран в доступное место. Без этого стопка со списками внутри колонки
    /// NavigationSplitView получает неограниченную высоту, и окно «разъезжается» (содержимое уходит за края).
    func fillAvailable() -> some View {
        GeometryReader { geo in self.frame(width: geo.size.width, height: geo.size.height) }
    }
}
