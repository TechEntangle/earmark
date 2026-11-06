// Earmark for Mac: the window (Flutter) plus what a Mac app should do natively:
//   - a menu bar item with the recording state, Pause / Resume, Earmark this moment
//   - starts Earmark's engine (the service on this Mac) if it isn't running
//   - keeps running in the menu bar when the window is closed
//   - open at login, notifications, audio playback of conversations
//
// Channel "earmark/mac" (Dart <-> Swift):
//   ensureEngine → {running, started, error?}     starts ~/Applications/earmark/run.sh if needed
//   loginItem → {on}  / setLoginItem {on} → {on, error?}
//   notify {title, body}
//   play {url, at?, speed?} / pause / seek {at} / speed {speed} / stop / audioState
//   reveal {path}                                  shows a file in Finder
//   status {line, paused, recording}               (from Dart; the menu bar also polls by itself)
// Swift -> Dart: "menu" {action: open | pause | earmark | settings}
import AVFoundation
import Cocoa
import FlutterMacOS
import ServiceManagement
import UserNotifications

let enginePort = 8765

@main
class AppDelegate: FlutterAppDelegate {
  private var statusItem: NSStatusItem?
  private var statusLine = NSMenuItem(title: "Starting…", action: nil, keyEquivalent: "")
  private var pauseItem = NSMenuItem(title: "Pause recording", action: #selector(menuPause), keyEquivalent: "p")
  private var earmarkItem = NSMenuItem(title: "Earmark this moment", action: #selector(menuEarmark), keyEquivalent: "e")
  private var poll: Timer?
  private var paused = false
  var channel: FlutterMethodChannel?
  private var player: AVPlayer?
  private var playerURL: String?
  private var speed: Float = 1

  override func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { false }

  override func applicationSupportsSecureRestorableState(_ app: NSApplication) -> Bool { true }

  override func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
    if !flag { showWindow() }
    return true
  }

  override func applicationDidFinishLaunching(_ notification: Notification) {
    setUpMenuBar()
    ensureEngine { _ in }
    poll = Timer.scheduledTimer(withTimeInterval: 5, repeats: true) { [weak self] _ in self?.refresh() }
    refresh()
    UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound]) { _, _ in }
  }

  func attach(_ controller: FlutterViewController) {
    let ch = FlutterMethodChannel(name: "earmark/mac", binaryMessenger: controller.engine.binaryMessenger)
    ch.setMethodCallHandler { [weak self] call, result in self?.handle(call, result: result) }
    channel = ch
  }

  // MARK: menu bar

  private func setUpMenuBar() {
    let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
    item.button?.image = symbol("record.circle")
    item.button?.imagePosition = .imageLeading
    let menu = NSMenu()
    statusLine.isEnabled = false
    menu.addItem(statusLine)
    menu.addItem(.separator())
    pauseItem.target = self
    earmarkItem.target = self
    menu.addItem(pauseItem)
    menu.addItem(earmarkItem)
    menu.addItem(.separator())
    let open = NSMenuItem(title: "Open Earmark", action: #selector(menuOpen), keyEquivalent: "o")
    open.target = self
    menu.addItem(open)
    let settings = NSMenuItem(title: "Settings…", action: #selector(menuSettings), keyEquivalent: ",")
    settings.target = self
    menu.addItem(settings)
    menu.addItem(.separator())
    menu.addItem(NSMenuItem(title: "Quit Earmark", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q"))
    item.menu = menu
    statusItem = item
  }

  private func symbol(_ name: String) -> NSImage? {
    let img = NSImage(systemSymbolName: name, accessibilityDescription: "Earmark")
    img?.isTemplate = true
    return img
  }

  /// The engine's state, for the menu bar (works with the window closed).
  private func refresh() {
    get("/api/status") { [weak self] json in
      DispatchQueue.main.async { self?.show(json) }
    }
  }

  private func show(_ s: [String: Any]?) {
    guard let s = s else {
      statusLine.title = "Earmark's engine is not running"
      statusItem?.button?.image = symbol("exclamationmark.circle")
      statusItem?.button?.title = ""
      pauseItem.isEnabled = false
      earmarkItem.isEnabled = false
      return
    }
    paused = s["paused"] as? Bool ?? false
    let pendant = s["pendant"] as? [String: Any] ?? [:]
    let connected = pendant["connected"] as? Bool ?? false
    let via = pendant["via"] as? String
    let battery = (pendant["battery"] as? NSNumber)?.intValue
    let phase = s["phase"] as? String ?? ""
    var line: String
    if paused {
      line = "Paused"
    } else if let via = via, !via.isEmpty {
      line = "Recording on \(via)"
    } else if connected {
      line = phase == "recording" ? "Recording" : "Connected"
    } else {
      line = "Pendant not nearby"
    }
    if let b = battery { line += " · battery \(b)%" }
    statusLine.title = line
    pauseItem.title = paused ? "Resume recording" : "Pause recording"
    pauseItem.isEnabled = true
    earmarkItem.isEnabled = !paused && (connected || via != nil)
    statusItem?.button?.image = symbol(paused ? "pause.circle" : (connected || via != nil) ? "record.circle.fill" : "record.circle")
  }

  @objc private func menuOpen() { showWindow() }

  @objc private func menuSettings() {
    showWindow()
    channel?.invokeMethod("menu", arguments: ["action": "settings"])
  }

  @objc private func menuPause() {
    post("/api/pause", ["paused": !paused]) { [weak self] _ in self?.refresh() }
    channel?.invokeMethod("menu", arguments: ["action": "pause"])
  }

  @objc private func menuEarmark() {
    post("/api/earmark", [:]) { [weak self] _ in self?.refresh() }
  }

  private func showWindow() {
    NSApp.activate(ignoringOtherApps: true)
    for w in NSApp.windows where w is MainFlutterWindow {
      w.makeKeyAndOrderFront(nil)
    }
  }

  // MARK: engine

  private func get(_ path: String, done: @escaping ([String: Any]?) -> Void) {
    var req = URLRequest(url: URL(string: "http://127.0.0.1:\(enginePort)\(path)")!)
    req.timeoutInterval = 4
    URLSession.shared.dataTask(with: req) { data, resp, _ in
      guard let data = data, (resp as? HTTPURLResponse)?.statusCode == 200 else { return done(nil) }
      done((try? JSONSerialization.jsonObject(with: data)) as? [String: Any])
    }.resume()
  }

  private func post(_ path: String, _ body: [String: Any], done: @escaping ([String: Any]?) -> Void) {
    var req = URLRequest(url: URL(string: "http://127.0.0.1:\(enginePort)\(path)")!)
    req.httpMethod = "POST"
    req.setValue("application/json", forHTTPHeaderField: "Content-Type")
    req.httpBody = try? JSONSerialization.data(withJSONObject: body)
    req.timeoutInterval = 8
    URLSession.shared.dataTask(with: req) { data, _, _ in
      done(data.flatMap { (try? JSONSerialization.jsonObject(with: $0)) as? [String: Any] })
    }.resume()
  }

  /// Start the engine (~/Applications/earmark/run.sh) unless it already answers.
  func ensureEngine(done: @escaping ([String: Any]) -> Void) {
    get("/api/status") { json in
      if json != nil { return done(["running": true, "started": false]) }
      let home = FileManager.default.homeDirectoryForCurrentUser
      let candidates = [
        home.appendingPathComponent("Applications/earmark/run.sh"),
        URL(fileURLWithPath: "/Applications/earmark/run.sh"),
      ]
      guard let script = candidates.first(where: { FileManager.default.fileExists(atPath: $0.path) }) else {
        return done(["running": false, "started": false, "error": "Earmark's engine isn't installed (run.sh not found)."])
      }
      let p = Process()
      p.executableURL = URL(fileURLWithPath: "/bin/bash")
      p.arguments = [script.path]
      p.currentDirectoryURL = script.deletingLastPathComponent()
      p.terminationHandler = { proc in
        done(["running": proc.terminationStatus == 0, "started": true,
              "error": proc.terminationStatus == 0 ? NSNull() : "The engine did not start; see service.log in the earmark folder."])
      }
      do { try p.run() } catch { done(["running": false, "started": false, "error": error.localizedDescription]) }
    }
  }

  // MARK: channel

  private func handle(_ call: FlutterMethodCall, result: @escaping FlutterResult) {
    let args = call.arguments as? [String: Any] ?? [:]
    let reply: (Any?) -> Void = { v in DispatchQueue.main.async { result(v) } }
    switch call.method {
    case "ensureEngine":
      ensureEngine { reply($0) }
    case "loginItem":
      result(["on": SMAppService.mainApp.status == .enabled])
    case "setLoginItem":
      let on = args["on"] as? Bool ?? false
      do {
        if on { try SMAppService.mainApp.register() } else { try SMAppService.mainApp.unregister() }
        result(["on": SMAppService.mainApp.status == .enabled])
      } catch {
        result(["on": SMAppService.mainApp.status == .enabled, "error": error.localizedDescription])
      }
    case "notify":
      let c = UNMutableNotificationContent()
      c.title = args["title"] as? String ?? "Earmark"
      c.body = args["body"] as? String ?? ""
      UNUserNotificationCenter.current().add(UNNotificationRequest(identifier: UUID().uuidString, content: c, trigger: nil))
      result(nil)
    case "status":
      refresh()
      result(nil)
    case "reveal":
      if let p = args["path"] as? String { NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: p)]) }
      result(nil)
    case "play":
      guard let u = args["url"] as? String, let url = URL(string: u) else { return result(audioState()) }
      if player == nil || playerURL != u {
        player = AVPlayer(url: url)
        playerURL = u
      }
      if let s = (args["speed"] as? NSNumber)?.floatValue { speed = s }
      if let at = (args["at"] as? NSNumber)?.doubleValue {
        player?.seek(to: CMTime(seconds: at, preferredTimescale: 600), toleranceBefore: .zero, toleranceAfter: .zero)
      }
      player?.playImmediately(atRate: speed)
      result(audioState())
    case "pause":
      player?.pause()
      result(audioState())
    case "seek":
      if let at = (args["at"] as? NSNumber)?.doubleValue {
        player?.seek(to: CMTime(seconds: at, preferredTimescale: 600), toleranceBefore: .zero, toleranceAfter: .zero)
      }
      result(audioState())
    case "speed":
      speed = (args["speed"] as? NSNumber)?.floatValue ?? 1
      if let p = player, p.rate > 0 { p.rate = speed }
      result(audioState())
    case "stop":
      player?.pause()
      player = nil
      playerURL = nil
      result(audioState())
    case "audioState":
      result(audioState())
    default:
      result(FlutterMethodNotImplemented)
    }
  }

  private func audioState() -> [String: Any] {
    let d = player?.currentItem?.duration.seconds ?? 0
    return [
      "playing": (player?.rate ?? 0) > 0,
      "position": player?.currentTime().seconds ?? 0,
      "duration": d.isFinite ? d : 0,
      "url": playerURL ?? "",
      "speed": Double(speed),
    ]
  }
}
