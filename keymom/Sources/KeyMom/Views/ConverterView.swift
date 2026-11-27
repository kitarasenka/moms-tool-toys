import SwiftUI

/// «Исправить текст»: вставить длинный текст, получить исправленный, скопировать. Без разрешений.
struct ConverterView: View {
    @Environment(AppState.self) private var state

    var body: some View {
        @Bindable var state = state
        let result = state.converted(state.convertInput)
        let dir = Binding<Direction?>(get: { state.convertDirection }, set: { state.convertDirection = $0 })

        VStack(alignment: .leading, spacing: 14) {
            HStack {
                Text("Вставьте текст, набранный не в той раскладке (⌘V), — ниже сразу появится исправленный.")
                    .foregroundStyle(.secondary)
                Spacer()
                Picker("Направление", selection: dir) {
                    Text("Автоматически").tag(Direction?.none)
                    ForEach(Direction.allCases) { d in Text(d.title).tag(Direction?.some(d)) }
                }
                .labelsHidden()
                .fixedSize()
            }

            Text("Было").font(.headline)
            TextEditor(text: $state.convertInput)
                .font(.system(size: 15))
                .scrollContentBackground(.hidden)
                .padding(8)
                .background(.background, in: RoundedRectangle(cornerRadius: 10))
                .overlay(RoundedRectangle(cornerRadius: 10).strokeBorder(.separator))
                .frame(minHeight: 100)
                .overlay(alignment: .topLeading) {
                    if state.convertInput.isEmpty {
                        Text("Например: Pfdnhf d 10:30 r dhfxe")
                            .foregroundStyle(.tertiary).font(.system(size: 15)).padding(13).allowsHitTesting(false)
                    }
                }

            HStack {
                Text("Стало").font(.headline)
                if let d = result?.1 {
                    Text(d.title).font(.caption.weight(.bold)).padding(.horizontal, 6).padding(.vertical, 2)
                        .background(Brand.cyan.opacity(0.25), in: Capsule())
                }
                Spacer()
                Text("Русская раскладка: \(state.variant.title)").font(.caption).foregroundStyle(.secondary)
            }
            ScrollView {
                Text(result?.0 ?? (state.convertInput.isEmpty ? " " : "Исправлять нечего — здесь нет букв."))
                    .font(.system(size: 15))
                    .foregroundStyle(result == nil ? .secondary : .primary)
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(12)
            }
            .frame(minHeight: 100)
            .background(Brand.cyan.opacity(0.07), in: RoundedRectangle(cornerRadius: 10))
            .overlay(RoundedRectangle(cornerRadius: 10).strokeBorder(Brand.blue.opacity(0.25)))

            HStack {
                Button {
                    if let r = result { state.copy(r.0) }
                } label: { Label("Скопировать", systemImage: "doc.on.doc") }
                    .buttonStyle(.borderedProminent).tint(Brand.blue)
                    .keyboardShortcut(.return, modifiers: .command)
                    .disabled(result == nil)
                Button {
                    if let r = result { state.convertInput = r.0; state.convertDirection = nil }
                } label: { Label("Поставить вместо исходного", systemImage: "arrow.up.arrow.down") }
                    .disabled(result == nil)
                Spacer()
                Button("Очистить") { state.convertInput = "" }.disabled(state.convertInput.isEmpty)
            }
        }
        .padding(24)
    }
}
