// WifiMom.app: окно с веб-интерфейсом. Запускает `node wifimom.mjs --no-open`, ждёт адрес из его
// вывода и показывает страницу в WKWebView. При выходе шлёт монитору SIGINT (он гасит ping и пишет итог).
// Если монитор уже запущен из терминала на 7357 — просто показывает его, второй не запускает.
import AppKit
import WebKit

let info = Bundle.main.infoDictionary ?? [:]
let nodePath = info["WifimomNode"] as? String ?? "/usr/local/bin/node"
let scriptPath = info["WifimomScript"] as? String ?? ""
let defaultURL = URL(string: "http://127.0.0.1:7357/")!

// Запоминает последний mouseDown: по нему окно тащится, когда страница скажет «здесь тулбар».
final class WebView: WKWebView {
  var lastMouseDown: NSEvent?
  override func mouseDown(with event: NSEvent) {
    lastMouseDown = event
    super.mouseDown(with: event)
  }
}

final class App: NSObject, NSApplicationDelegate, WKUIDelegate, WKNavigationDelegate, WKScriptMessageHandler {
  var window: NSWindow!
  var web: WebView!
  var child: Process?
  var output = ""
  var loaded = false

  func applicationDidFinishLaunching(_ note: Notification) {
    buildMenu()
    let cfg = WKWebViewConfiguration()
    cfg.websiteDataStore = .default() // localStorage (вкладка, диапазон, слой) переживает перезапуск
    // Класс .app на <html>: страница делает боковую панель прозрачной и отступает под кнопки окна.
    cfg.userContentController.addUserScript(WKUserScript(
      source: "document.documentElement.classList.add('app')", injectionTime: .atDocumentStart, forMainFrameOnly: true))
    cfg.userContentController.add(self, name: "win")
    web = WebView(frame: .zero, configuration: cfg)
    web.uiDelegate = self
    web.navigationDelegate = self
    web.setValue(false, forKey: "drawsBackground") // прозрачный фон — сквозь панель видна «вибрация»
    web.underPageBackgroundColor = .clear
    web.autoresizingMask = [.width, .height]

    window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 1280, height: 860),
                      styleMask: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView],
                      backing: .buffered, defer: false)
    window.title = "WifiMom"
    window.titleVisibility = .hidden
    window.titlebarAppearsTransparent = true
    window.titlebarSeparatorStyle = .none
    window.toolbar = NSToolbar(identifier: "main") // пустой тулбар: высота 52 и кнопки окна по центру, как в Finder
    window.toolbarStyle = .unified
    window.minSize = NSSize(width: 900, height: 600)
    let blur = NSVisualEffectView()
    blur.material = .sidebar
    blur.blendingMode = .behindWindow
    blur.state = .followsWindowActiveState
    web.frame = blur.bounds
    blur.addSubview(web)
    window.contentView = blur
    window.center()
    window.setFrameAutosaveName("main")
    window.makeKeyAndOrderFront(nil)
    NSApp.activate(ignoringOtherApps: true)
    web.loadHTMLString("<body style='font:13px -apple-system;color:#888;display:grid;place-items:center;height:90vh;-webkit-user-select:none'>Запускаю монитор…</body>", baseURL: nil)

    alreadyRunning { running in
      if running { self.show(defaultURL) } else { self.startMonitor() }
    }
  }

  // Свой ли это сервер на 7357: /api/state отдаёт JSON с полем gateway.
  func alreadyRunning(_ done: @escaping (Bool) -> Void) {
    var req = URLRequest(url: defaultURL.appendingPathComponent("api/state"))
    req.timeoutInterval = 1
    URLSession.shared.dataTask(with: req) { data, _, _ in
      let ok = data.flatMap { try? JSONSerialization.jsonObject(with: $0) as? [String: Any] }?["gateway"] != nil
      DispatchQueue.main.async { done(ok) }
    }.resume()
  }

  func startMonitor() {
    let p = Process()
    p.executableURL = URL(fileURLWithPath: nodePath)
    p.arguments = [scriptPath, "--no-open"]
    var env = ProcessInfo.processInfo.environment
    let nodeDir = (nodePath as NSString).deletingLastPathComponent
    env["PATH"] = "\(nodeDir):/usr/bin:/bin:/usr/sbin:/sbin:/usr/local/bin:/opt/homebrew/bin"
    p.environment = env
    let pipe = Pipe()
    p.standardOutput = pipe
    p.standardError = pipe
    // Читаем вывод всё время, иначе буфер трубы растёт (монитор пишет строку статуса раз в секунду).
    pipe.fileHandleForReading.readabilityHandler = { h in
      let chunk = String(decoding: h.availableData, as: UTF8.self)
      DispatchQueue.main.async { self.consume(chunk) }
    }
    p.terminationHandler = { proc in
      DispatchQueue.main.async { self.monitorExited(proc.terminationStatus) }
    }
    do {
      try p.run()
      child = p
    } catch {
      fail("Не удалось запустить node (\(nodePath)): \(error.localizedDescription)\n\nПереустановите приложение: app/install.sh")
    }
  }

  func consume(_ chunk: String) {
    if loaded { return }
    output += chunk
    if let r = output.range(of: #"Окно: (http://\S+)"#, options: .regularExpression) {
      let s = output[r].dropFirst("Окно: ".count)
      if let url = URL(string: String(s)) { show(url) }
    }
  }

  func show(_ url: URL) {
    loaded = true
    output = ""
    web.load(URLRequest(url: url))
  }

  func monitorExited(_ status: Int32) {
    guard !terminating else { return }
    let text = output.replacingOccurrences(of: #"\r?\u{1b}\[K"#, with: "\n", options: .regularExpression)
      .trimmingCharacters(in: .whitespacesAndNewlines)
    fail(text.isEmpty ? "Монитор остановился (код \(status))." : text)
  }

  func fail(_ text: String) {
    let a = NSAlert()
    a.messageText = "WifiMom не запустился"
    a.informativeText = String(text.suffix(1500))
    a.runModal()
    NSApp.terminate(nil)
  }

  var terminating = false
  func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
    terminating = true
    guard let p = child, p.isRunning else { return .terminateNow }
    p.interrupt() // SIGINT: монитор гасит ping/rf и пишет итог в лог
    DispatchQueue.global().async {
      let deadline = Date().addingTimeInterval(3)
      while p.isRunning && Date() < deadline { usleep(50_000) }
      if p.isRunning { p.terminate() }
      DispatchQueue.main.async { NSApp.reply(toApplicationShouldTerminate: true) }
    }
    return .terminateLater
  }

  func applicationShouldTerminateAfterLastWindowClosed(_ app: NSApplication) -> Bool { true }

  // Ссылки «в новом окне» (адрес роутера) и на чужие хосты — в обычный браузер.
  func webView(_ webView: WKWebView, createWebViewWith configuration: WKWebViewConfiguration,
               for action: WKNavigationAction, windowFeatures: WKWindowFeatures) -> WKWebView? {
    if let url = action.request.url { NSWorkspace.shared.open(url) }
    return nil
  }

  func webView(_ webView: WKWebView, decidePolicyFor action: WKNavigationAction,
               decisionHandler: @escaping (WKNavigationActionPolicy) -> Void) {
    if let url = action.request.url, let host = url.host, host != "127.0.0.1", url.scheme?.hasPrefix("http") == true {
      NSWorkspace.shared.open(url)
      return decisionHandler(.cancel)
    }
    decisionHandler(.allow)
  }

  // Если вкладка WebKit упала — перезагрузить, а не оставить белое окно.
  func webViewWebContentProcessDidTerminate(_ webView: WKWebView) { webView.reload() }

  // <input type=file> — план квартиры на вкладке «Карта покрытия».
  func webView(_ webView: WKWebView, runOpenPanelWith parameters: WKOpenPanelParameters,
               initiatedByFrame frame: WKFrameInfo, completionHandler: @escaping ([URL]?) -> Void) {
    let panel = NSOpenPanel()
    panel.allowsMultipleSelection = parameters.allowsMultipleSelection
    panel.canChooseDirectories = false
    panel.allowedContentTypes = [.image]
    panel.beginSheetModal(for: window) { completionHandler($0 == .OK ? panel.urls : nil) }
  }

  func webView(_ webView: WKWebView, runJavaScriptAlertPanelWithMessage message: String,
               initiatedByFrame frame: WKFrameInfo, completionHandler: @escaping () -> Void) {
    let a = NSAlert()
    a.messageText = message
    a.beginSheetModal(for: window) { _ in completionHandler() }
  }

  func webView(_ webView: WKWebView, runJavaScriptConfirmPanelWithMessage message: String,
               initiatedByFrame frame: WKFrameInfo, completionHandler: @escaping (Bool) -> Void) {
    let a = NSAlert()
    a.messageText = message
    a.addButton(withTitle: "OK")
    a.addButton(withTitle: "Отменить")
    a.beginSheetModal(for: window) { completionHandler($0 == .alertFirstButtonReturn) }
  }

  func webView(_ webView: WKWebView, runJavaScriptTextInputPanelWithPrompt prompt: String, defaultText: String?,
               initiatedByFrame frame: WKFrameInfo, completionHandler: @escaping (String?) -> Void) {
    let a = NSAlert()
    a.messageText = prompt
    a.addButton(withTitle: "OK")
    a.addButton(withTitle: "Отменить")
    let field = NSTextField(frame: NSRect(x: 0, y: 0, width: 320, height: 24))
    field.stringValue = defaultText ?? ""
    a.accessoryView = field
    a.window.initialFirstResponder = field
    a.beginSheetModal(for: window) { completionHandler($0 == .alertFirstButtonReturn ? field.stringValue : nil) }
  }

  // Сообщения страницы: "drag" — тащить окно (зажата кнопка мыши в тулбаре/панели), "zoom" — двойной клик.
  func userContentController(_ c: WKUserContentController, didReceive message: WKScriptMessage) {
    switch message.body as? String {
    case "drag":
      if NSEvent.pressedMouseButtons & 1 == 1, let e = web.lastMouseDown { window.performDrag(with: e) }
    case "zoom":
      switch UserDefaults.standard.string(forKey: "AppleActionOnDoubleClick") {
      case "Minimize": window.performMiniaturize(nil)
      case "None": break
      default: window.performZoom(nil)
      }
    default: break
    }
  }

  @objc func reloadPage() { web.reload() }
  @objc func openInBrowser() { if let u = web.url, u.scheme != "about" { NSWorkspace.shared.open(u) } }

  func buildMenu() {
    let main = NSMenu()
    func sub(_ title: String, _ items: [NSMenuItem]) {
      let m = NSMenu(title: title)
      items.forEach(m.addItem)
      let it = NSMenuItem(title: title, action: nil, keyEquivalent: "")
      it.submenu = m
      main.addItem(it)
    }
    func item(_ t: String, _ a: Selector?, _ k: String, _ mods: NSEvent.ModifierFlags = .command) -> NSMenuItem {
      let i = NSMenuItem(title: t, action: a, keyEquivalent: k)
      i.keyEquivalentModifierMask = mods
      return i
    }
    sub("WifiMom", [
      item("Скрыть WifiMom", #selector(NSApplication.hide(_:)), "h"),
      .separator(),
      item("Завершить WifiMom", #selector(NSApplication.terminate(_:)), "q"),
    ])
    sub("Правка", [
      item("Отменить", Selector(("undo:")), "z"),
      item("Повторить", Selector(("redo:")), "Z"),
      .separator(),
      item("Вырезать", #selector(NSText.cut(_:)), "x"),
      item("Скопировать", #selector(NSText.copy(_:)), "c"),
      item("Вставить", #selector(NSText.paste(_:)), "v"),
      item("Выбрать все", #selector(NSText.selectAll(_:)), "a"),
    ])
    let reload = item("Обновить", #selector(reloadPage), "r")
    reload.target = self
    let browser = item("Открыть в браузере", #selector(openInBrowser), "o")
    browser.target = self
    sub("Вид", [reload, browser, item("Во весь экран", #selector(NSWindow.toggleFullScreen(_:)), "f", [.command, .control])])
    sub("Окно", [
      item("Свернуть", #selector(NSWindow.performMiniaturize(_:)), "m"),
      item("Закрыть", #selector(NSWindow.performClose(_:)), "w"),
    ])
    NSApp.mainMenu = main
  }
}

let app = NSApplication.shared
let delegate = App()
app.delegate = delegate
app.setActivationPolicy(.regular)
app.run()
