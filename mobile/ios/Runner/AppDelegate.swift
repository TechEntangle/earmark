import AppIntents
import CoreSpotlight
import Flutter
import UIKit

@main
@objc class AppDelegate: FlutterAppDelegate, FlutterImplicitEngineDelegate {
  override func application(
    _ application: UIApplication,
    didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]?
  ) -> Bool {
    return super.application(application, didFinishLaunchingWithOptions: launchOptions)
  }

  func didInitializeImplicitFlutterEngine(_ engineBridge: FlutterImplicitEngineBridge) {
    GeneratedPluginRegistrant.register(with: engineBridge.pluginRegistry)
    if let reg = engineBridge.pluginRegistry.registrar(forPlugin: "EarmarkIntents") {
      IntentBridge.shared.attach(reg.messenger())
    }
  }

  // a conversation tapped in Spotlight
  override func application(
    _ application: UIApplication, continue userActivity: NSUserActivity,
    restorationHandler: @escaping ([UIUserActivityRestoring]?) -> Void
  ) -> Bool {
    if userActivity.activityType == CSSearchableItemActionType,
      let id = userActivity.userInfo?[CSSearchableItemActivityIdentifier] as? String
    {
      IntentBridge.shared.send("conversation", ["id": id])
      return true
    }
    return super.application(application, continue: userActivity, restorationHandler: restorationHandler)
  }
}

// MARK: - Siri, Shortcuts, the Action button and Spotlight
//
// Channel "earmark/intents":
//   Swift -> Dart  intent {action: earmark | pause | resume | ask | open | conversation, at?, q?, tab?, id?}
//   Dart -> Swift  drain → [intents that arrived before the app was ready]
//                  index {items: [{id, title, summary, date}]}   conversations for Spotlight
//                  unindex {ids}
final class IntentBridge {
  static let shared = IntentBridge()
  private var channel: FlutterMethodChannel?
  private let key = "earmark.pendingIntents"

  func attach(_ messenger: FlutterBinaryMessenger) {
    let ch = FlutterMethodChannel(name: "earmark/intents", binaryMessenger: messenger)
    ch.setMethodCallHandler { [weak self] call, result in
      guard let self = self else { return result(nil) }
      let args = call.arguments as? [String: Any] ?? [:]
      switch call.method {
      case "drain":
        let p = UserDefaults.standard.array(forKey: self.key) ?? []
        UserDefaults.standard.removeObject(forKey: self.key)
        result(p)
      case "index":
        let items = (args["items"] as? [[String: Any]] ?? []).compactMap { m -> CSSearchableItem? in
          guard let id = m["id"] as? String else { return nil }
          let a = CSSearchableItemAttributeSet(contentType: .text)
          a.title = m["title"] as? String
          a.contentDescription = m["summary"] as? String
          if let d = (m["date"] as? NSNumber)?.doubleValue { a.contentCreationDate = Date(timeIntervalSince1970: d) }
          a.keywords = m["keywords"] as? [String]
          return CSSearchableItem(uniqueIdentifier: id, domainIdentifier: "conversations", attributeSet: a)
        }
        CSSearchableIndex.default().indexSearchableItems(items) { _ in }
        result(nil)
      case "unindex":
        CSSearchableIndex.default().deleteSearchableItems(withIdentifiers: args["ids"] as? [String] ?? []) { _ in }
        result(nil)
      default:
        result(FlutterMethodNotImplemented)
      }
    }
    channel = ch
  }

  /// Hand an action to the app; kept until the app is ready if it isn't yet.
  func send(_ action: String, _ args: [String: Any] = [:]) {
    var m = args
    m["action"] = action
    m["at"] = Date().timeIntervalSince1970
    DispatchQueue.main.async {
      if let ch = self.channel {
        ch.invokeMethod("intent", arguments: m)
      } else {
        var p = UserDefaults.standard.array(forKey: self.key) ?? []
        p.append(m)
        UserDefaults.standard.set(p, forKey: self.key)
      }
    }
  }
}

struct EarmarkMomentIntent: AppIntent {
  static var title: LocalizedStringResource = "Earmark this moment"
  static var description = IntentDescription("Marks what's being said now as important. Say \"remind me to…\" after it to make a task.")
  func perform() async throws -> some IntentResult & ProvidesDialog {
    IntentBridge.shared.send("earmark")
    return .result(dialog: "Earmarked.")
  }
}

struct PauseRecordingIntent: AppIntent {
  static var title: LocalizedStringResource = "Pause recording"
  static var description = IntentDescription("Stops the pendant recording until you resume.")
  func perform() async throws -> some IntentResult & ProvidesDialog {
    IntentBridge.shared.send("pause")
    return .result(dialog: "Paused. Nothing is being recorded.")
  }
}

struct ResumeRecordingIntent: AppIntent {
  static var title: LocalizedStringResource = "Resume recording"
  func perform() async throws -> some IntentResult & ProvidesDialog {
    IntentBridge.shared.send("resume")
    return .result(dialog: "Recording again.")
  }
}

struct AskEarmarkIntent: AppIntent {
  static var title: LocalizedStringResource = "Ask Earmark"
  static var description = IntentDescription("Ask about your conversations.")
  static var openAppWhenRun = true
  @Parameter(title: "Question", requestValueDialog: "What would you like to know?")
  var question: String
  func perform() async throws -> some IntentResult {
    IntentBridge.shared.send("ask", ["q": question])
    return .result()
  }
}

struct OpenTasksIntent: AppIntent {
  static var title: LocalizedStringResource = "Show my tasks"
  static var openAppWhenRun = true
  func perform() async throws -> some IntentResult {
    IntentBridge.shared.send("open", ["tab": "tasks"])
    return .result()
  }
}

struct EarmarkShortcuts: AppShortcutsProvider {
  static var appShortcuts: [AppShortcut] {
    AppShortcut(intent: EarmarkMomentIntent(), phrases: [
      "Earmark this with \(.applicationName)", "\(.applicationName) this moment", "Earmark this moment in \(.applicationName)",
    ], shortTitle: "Earmark this moment", systemImageName: "bookmark")
    AppShortcut(intent: PauseRecordingIntent(), phrases: [
      "Pause \(.applicationName)", "Stop recording in \(.applicationName)",
    ], shortTitle: "Pause recording", systemImageName: "pause.circle")
    AppShortcut(intent: ResumeRecordingIntent(), phrases: [
      "Resume \(.applicationName)", "Start recording in \(.applicationName)",
    ], shortTitle: "Resume recording", systemImageName: "record.circle")
    AppShortcut(intent: AskEarmarkIntent(), phrases: [
      "Ask \(.applicationName)", "Ask \(.applicationName) a question",
    ], shortTitle: "Ask Earmark", systemImageName: "sparkles")
    AppShortcut(intent: OpenTasksIntent(), phrases: [
      "Show my \(.applicationName) tasks", "What's on my \(.applicationName) list",
    ], shortTitle: "My tasks", systemImageName: "checklist")
  }
}
