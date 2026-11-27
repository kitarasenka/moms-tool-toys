// Mom's Tool Toys.app — общий запуск инструментов. Ничего не знает об их коде: ищет приложения
// по bundle id через LaunchServices, открывает их и следит, какие сейчас запущены.
// Иконки и картинка в шапке копируются в Resources при сборке (install.sh).
import AppKit
import SwiftUI

struct Tool: Identifiable {
  let id: String     // bundle id
  let name: String
  let blurb: String
  let icon: String   // PNG в Resources
}

let tools = [
  Tool(id: "local.wifimom", name: "Wifi",
       blurb: "Домашний Wi-Fi: отличает сбои Wi-Fi от сбоев провайдера, карта покрытия, устройства в сети, замер скорости.",
       icon: "wifimom"),
  Tool(id: "local.perfmon.app" /* bundle id с тех пор, как приложение звалось PerfMon */, name: "Perf",
       blurb: "Производительность Mac: процессы и их дерево, автозагрузка, проверка безопасности, история нагрузки.",
       icon: "perfmom"),
  Tool(id: "local.cleanermom", name: "Cleaner",
       blurb: "Уборка Mac: кэши, журналы, временные файлы и Корзина одной кнопкой, крупные файлы, удаление приложений.",
       icon: "cleanermom"),
  Tool(id: "local.diskmom", name: "Disk",
       blurb: "Диски: карта того, что занимает место, поиск дубликатов, состояние и извлечение дисков.",
       icon: "diskmom"),
  Tool(id: "local.privacymom", name: "Privacy",
       blurb: "Приватность: кто имеет доступ к камере, микрофону и файлам, история браузеров, сохранённые сети Wi-Fi.",
       icon: "privacymom"),
  Tool(id: "local.batterymom", name: "Battery",
       blurb: "Батарея: здоровье и циклы, история заряда, кто тратит энергию, заряд мыши и наушников.",
       icon: "batterymom"),
  Tool(id: "local.clipmom", name: "Clip",
       blurb: "История буфера обмена: всё скопированное под рукой, поиск, закрепление, быстрая панель ⇧⌘V.",
       icon: "clipmom"),
  Tool(id: "local.helpmom", name: "Help",
       blurb: "Позвать на помощь: отчёт о Mac одной кнопкой, звонок или сообщение близким, шпаргалки по частым бедам.",
       icon: "helpmom"),
  Tool(id: "local.safetymom", name: "Safety",
       blurb: "Проверка Mac: защита включена ли, резервные копии, расширения и спам-уведомления браузеров, прокси и DNS.",
       icon: "safetymom"),
  Tool(id: "local.keymom", name: "Key",
       blurb: "Раскладка: исправить «ghbdtn» на «привет» одним сочетанием, язык и Caps Lock видно у курсора.",
       icon: "keymom"),
  Tool(id: "local.desktopmom", name: "Desktop",
       blurb: "Порядок на Рабочем столе: снимки экрана — по папкам месяцев, старые установщики из Загрузок — в Корзину.",
       icon: "desktopmom"),
]

/// ⌘1…⌘9, ⌘0 — для первых десяти инструментов.
func shortcutKey(_ index: Int) -> String? { index < 9 ? String(index + 1) : index == 9 ? "0" : nil }

func resourceImage(_ name: String) -> NSImage? {
  Bundle.main.url(forResource: name, withExtension: "png").flatMap(NSImage.init(contentsOf:))
}

@MainActor
final class Store: ObservableObject {
  @Published var installed: [String: URL] = [:]
  @Published var running: Set<String> = []
  private var observers: [NSObjectProtocol] = []

  init() {
    refresh()
    let ws = NSWorkspace.shared.notificationCenter
    for name in [NSWorkspace.didLaunchApplicationNotification, NSWorkspace.didTerminateApplicationNotification] {
      observers.append(ws.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
        Task { @MainActor in self?.refresh() }
      })
    }
    // Вернулись в окно — могли переустановить инструмент.
    observers.append(NotificationCenter.default.addObserver(
      forName: NSApplication.didBecomeActiveNotification, object: nil, queue: .main) { [weak self] _ in
        Task { @MainActor in self?.refresh() }
      })
  }

  func refresh() {
    var found: [String: URL] = [:]
    for t in tools { found[t.id] = NSWorkspace.shared.urlForApplication(withBundleIdentifier: t.id) }
    installed = found
    let ids = Set(tools.map(\.id))
    running = Set(NSWorkspace.shared.runningApplications.compactMap(\.bundleIdentifier)).intersection(ids)
  }

  func open(_ t: Tool) {
    guard let url = installed[t.id] else { return }
    let cfg = NSWorkspace.OpenConfiguration()
    cfg.activates = true
    NSWorkspace.shared.openApplication(at: url, configuration: cfg) { _, error in
      guard let error else { return }
      Task { @MainActor in NSAlert(error: error).runModal() }
    }
  }

  func quit(_ t: Tool) {
    NSRunningApplication.runningApplications(withBundleIdentifier: t.id).forEach { $0.terminate() }
  }

  func reveal(_ t: Tool) {
    if let url = installed[t.id] { NSWorkspace.shared.activateFileViewerSelecting([url]) }
  }
}

struct ContentView: View {
  @EnvironmentObject var store: Store

  var body: some View {
    VStack(spacing: 0) {
      header
      // Три колонки: инструментов много, в одну-две колонки окно не помещается на экран ноутбука.
      LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 12, alignment: .top), count: 3),
                spacing: 12) {
        ForEach(Array(tools.enumerated()), id: \.element.id) { i, t in ToolRow(tool: t, index: i) }
      }
      .padding(20)
    }
    .frame(width: 1180)
    .fixedSize(horizontal: false, vertical: true)
  }

  var header: some View {
    HStack(spacing: 18) {
      if let hero = resourceImage("hero") {
        Image(nsImage: hero).resizable().interpolation(.high).frame(width: 128, height: 128)
      }
      VStack(alignment: .leading, spacing: 6) {
        Text("Mom's Tool Toys").font(.system(size: 30, weight: .bold, design: .rounded))
          .foregroundStyle(dark ? .white : Color(red: 0.16, green: 0.10, blue: 0.20))
        Text("Маленькие инструменты для домашнего Mac").font(.title3)
          .foregroundStyle(dark ? Color.white.opacity(0.78) : Color(red: 0.36, green: 0.30, blue: 0.42))
        HStack(spacing: 16) {
          Link(destination: URL(string: "https://github.com/kitarasenka/moms-tool-toys")!) {
            Label("GitHub", systemImage: "chevron.left.forwardslash.chevron.right")
          }
          Link(destination: URL(string: "https://t.me/marstut")!) {
            Label("Telegram разработчика @marstut", systemImage: "paperplane.fill")
          }
        }
        .font(.callout.weight(.medium))
        // Розовый в тон бантику на картинке: системный синий на сливовом фоне терялся.
        .foregroundStyle(dark ? Color(red: 1, green: 0.72, blue: 0.84) : Color(red: 0.76, green: 0.15, blue: 0.42))
        .padding(.top, 4)
      }
      Spacer(minLength: 0)
    }
    .padding(.horizontal, 24)
    .padding(.top, 4)
    .padding(.bottom, 12)
    .frame(maxWidth: .infinity)
    .background(LinearGradient(colors: dark
                                 ? [Color(red: 0.33, green: 0.13, blue: 0.27), Color(red: 0.15, green: 0.12, blue: 0.33)]
                                 : [Color(red: 1, green: 0.89, blue: 0.93), Color(red: 0.89, green: 0.87, blue: 1)],
                               startPoint: .topLeading, endPoint: .bottomTrailing)
      .ignoresSafeArea(edges: .top)) // фон уходит под скрытую строку заголовка
  }

  @Environment(\.colorScheme) private var scheme
  private var dark: Bool { scheme == .dark }
}

struct ToolRow: View {
  @EnvironmentObject var store: Store
  let tool: Tool
  let index: Int

  var installed: Bool { store.installed[tool.id] != nil }
  var running: Bool { store.running.contains(tool.id) }

  var body: some View {
    HStack(alignment: .center, spacing: 16) {
      Group {
        if let img = resourceImage(tool.icon) {
          Image(nsImage: img).resizable().interpolation(.high)
        } else {
          Image(systemName: "app.dashed").resizable().scaledToFit().foregroundStyle(.secondary)
        }
      }
      .frame(width: 72, height: 72)
      .opacity(installed ? 1 : 0.45)

      VStack(alignment: .leading, spacing: 4) {
        Text(tool.name).font(.title2.weight(.semibold)).lineLimit(1)
        status
        Text(tool.blurb).font(.callout).foregroundStyle(.secondary)
          .fixedSize(horizontal: false, vertical: true)
      }

      Spacer(minLength: 8)

      Button(running ? "Показать" : "Открыть") { store.open(tool) }
        .buttonStyle(.borderedProminent)
        .controlSize(.large)
        .disabled(!installed)
        .modifier(ToolShortcut(key: shortcutKey(index)))
    }
    .padding(14)
    .frame(maxHeight: .infinity, alignment: .center)
    .background(.background.secondary, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
    .overlay(RoundedRectangle(cornerRadius: 14, style: .continuous).strokeBorder(.separator))
    .contextMenu {
      Button("Открыть") { store.open(tool) }.disabled(!installed)
      Button("Завершить") { store.quit(tool) }.disabled(!running)
      Divider()
      Button("Показать в Finder") { store.reveal(tool) }.disabled(!installed)
    }
  }

  @ViewBuilder var status: some View {
    if !installed {
      Label("не установлено", systemImage: "exclamationmark.triangle.fill")
        .font(.caption).foregroundStyle(.orange)
        .help("Запустите ./install.sh в папке проекта")
    } else if running {
      HStack(spacing: 4) {
        Circle().fill(.green).frame(width: 7, height: 7)
        Text("запущено").font(.caption).foregroundStyle(.secondary)
      }
    }
  }
}

struct ToolShortcut: ViewModifier {
  let key: String?
  func body(content: Content) -> some View {
    if let key, let ch = key.first {
      content.keyboardShortcut(KeyEquivalent(ch), modifiers: .command).help("⌘\(key)")
    } else {
      content
    }
  }
}

final class AppDelegate: NSObject, NSApplicationDelegate {
  func applicationShouldTerminateAfterLastWindowClosed(_ app: NSApplication) -> Bool { true }
}

@main
struct LauncherApp: App {
  @NSApplicationDelegateAdaptor(AppDelegate.self) var delegate
  @StateObject private var store = Store()

  var body: some Scene {
    Window("Mom's Tool Toys", id: "main") {
      ContentView().environmentObject(store)
    }
    .windowStyle(.hiddenTitleBar)
    .windowResizability(.contentSize)
  }
}
