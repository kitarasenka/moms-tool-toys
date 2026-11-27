import AppKit
import SwiftUI

// MARK: - Фирменные цвета (как у иконок Mom's Tool Toys: синий с бирюзовым свечением)

enum Brand {
    static let blue = Color(red: 0.07, green: 0.42, blue: 0.93)
    static let cyan = Color(red: 0.20, green: 0.78, blue: 1.00)
    static let gradient = LinearGradient(colors: [cyan, blue], startPoint: .topLeading, endPoint: .bottomTrailing)

    /// Цвет уровня заряда: красный — мало, оранжевый — пора заряжать, иначе фирменный.
    static func level(_ percent: Int) -> Color {
        percent <= 10 ? .red : (percent <= 20 ? .orange : blue)
    }

    static func levelStyle(_ percent: Int) -> AnyShapeStyle {
        percent <= 20 ? AnyShapeStyle(level(percent)) : AnyShapeStyle(gradient)
    }
}

struct Card<Content: View>: View {
    @ViewBuilder var content: Content

    var body: some View {
        content
            .padding(14)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(.background.secondary, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous).strokeBorder(.separator.opacity(0.6)))
    }
}

/// Заголовок экрана: крупное название, пояснение и действия справа.
struct ScreenHeader<Actions: View>: View {
    let title: String
    let subtitle: String
    @ViewBuilder var actions: Actions

    var body: some View {
        HStack(alignment: .firstTextBaseline) {
            VStack(alignment: .leading, spacing: 3) {
                Text(title).font(.largeTitle.weight(.bold))
                Text(subtitle).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            }
            Spacer()
            actions
        }
    }
}

/// Плитка с показателем.
struct StatTile: View {
    let icon: String
    let title: String
    let value: String
    var note: String?
    var tint: Color = Brand.blue

    var body: some View {
        Card {
            VStack(alignment: .leading, spacing: 6) {
                Label(title, systemImage: icon)
                    .font(.callout)
                    .foregroundStyle(.secondary)
                Text(value)
                    .font(.system(size: 22, weight: .semibold, design: .rounded))
                    .monospacedDigit()
                    .foregroundStyle(tint == Brand.blue ? AnyShapeStyle(.primary) : AnyShapeStyle(tint))
                    .lineLimit(1)
                    .minimumScaleFactor(0.7)
                if let note {
                    Text(note).font(.caption).foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            .frame(maxWidth: .infinity, minHeight: 74, alignment: .topLeading)
        }
    }
}

/// Большое кольцо заряда с градиентом и свечением.
struct BatteryRing: View {
    let percent: Int
    let charging: Bool
    var diameter: CGFloat = 200

    var body: some View {
        let frac = Double(percent) / 100
        ZStack {
            Circle()
                .stroke(.quaternary, lineWidth: 18)
            Circle()
                .trim(from: 0, to: max(0.005, frac))
                .stroke(Brand.levelStyle(percent), style: StrokeStyle(lineWidth: 18, lineCap: .round))
                .rotationEffect(.degrees(-90))
                .shadow(color: (percent <= 20 ? Brand.level(percent) : Brand.cyan).opacity(0.55), radius: 14)
            VStack(spacing: 2) {
                if charging {
                    Image(systemName: "bolt.fill")
                        .font(.system(size: 22, weight: .semibold))
                        .foregroundStyle(Brand.gradient)
                }
                HStack(alignment: .firstTextBaseline, spacing: 2) {
                    Text("\(percent)")
                        .font(.system(size: 56, weight: .bold, design: .rounded))
                        .monospacedDigit()
                    Text("%").font(.system(size: 24, weight: .semibold, design: .rounded)).foregroundStyle(.secondary)
                }
            }
        }
        .frame(width: diameter, height: diameter)
        .animation(.easeOut(duration: 0.4), value: percent)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Заряд \(percent) %\(charging ? String(localized: ", заряжается") : "")")
    }
}

/// Полоска уровня (заряд устройства, доля энергопотребления).
struct LevelBar: View {
    let fraction: Double
    var style: AnyShapeStyle = AnyShapeStyle(Brand.gradient)
    var height: CGFloat = 8

    var body: some View {
        GeometryReader { geo in
            ZStack(alignment: .leading) {
                Capsule().fill(.quaternary)
                Capsule().fill(style)
                    .frame(width: max(height, geo.size.width * min(1, max(0, fraction))))
            }
        }
        .frame(height: height)
    }
}

/// Иконка приложения из Finder или символ для системного процесса.
struct AppIcon: View {
    let bundlePath: String?
    var size: CGFloat = 26

    var body: some View {
        if let p = bundlePath {
            Image(nsImage: NSWorkspace.shared.icon(forFile: p))
                .resizable()
                .interpolation(.high)
                .frame(width: size, height: size)
        } else {
            Image(systemName: "gearshape.2")
                .font(.system(size: size * 0.6))
                .foregroundStyle(.secondary)
                .frame(width: size, height: size)
        }
    }
}

/// Пустое состояние с крупной иконкой и действием.
struct EmptyStateView<Actions: View>: View {
    let icon: String
    let title: String
    let text: String
    @ViewBuilder var actions: Actions

    var body: some View {
        VStack(spacing: 14) {
            Image(systemName: icon)
                .font(.system(size: 54, weight: .light))
                .foregroundStyle(Brand.gradient)
            Text(title).font(.title2.weight(.semibold)).multilineTextAlignment(.center)
            Text(text).foregroundStyle(.secondary).multilineTextAlignment(.center).frame(maxWidth: 460)
            actions.padding(.top, 6)
        }
        .padding(40)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

/// Мини-индикатор батареи внизу боковой панели.
struct SidebarBattery: View {
    let battery: BatteryInfo?

    var body: some View {
        VStack(alignment: .leading, spacing: 5) {
            if let b = battery {
                HStack {
                    Label(b.state.title, systemImage: BatterySymbol.name(b))
                        .lineLimit(1)
                    Spacer()
                    Text("\(b.percent) %").monospacedDigit()
                }
                .font(.caption)
                .foregroundStyle(.secondary)
                LevelBar(fraction: Double(b.percent) / 100, style: Brand.levelStyle(b.percent), height: 6)
                if let t = b.timeText {
                    Text(t).font(.caption).monospacedDigit().foregroundStyle(.secondary)
                }
            } else {
                Label("Питание от сети", systemImage: "powerplug")
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
        .padding(10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(.background.secondary.opacity(0.6), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
    }
}

extension View {
    /// Жёстко вписывает экран в доступное место. Без этого стопка со списками внутри детали
    /// NavigationSplitView получает неограниченную высоту, и окно «разъезжается» (содержимое уходит за края).
    func fillAvailable() -> some View {
        GeometryReader { geo in self.frame(width: geo.size.width, height: geo.size.height) }
    }
}
