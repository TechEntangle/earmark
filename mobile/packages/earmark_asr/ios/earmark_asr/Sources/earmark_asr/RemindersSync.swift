// Your tasks in Apple Reminders, in a list called "Earmark", both ways: new tasks appear there
// (with due dates and alerts), and ticking one off in Reminders ticks it off in Earmark.
//
// Channel "earmark/reminders":
//   access → {granted}            asks for permission the first time
//   sync {items: [{id, title, notes, due?, timed, done}]} → {done: [id]}
//        due = epoch seconds; timed = whether it has a time of day (then it also gets an alert)
//        returns the ids that are completed in Reminders
import EventKit
import Flutter
import Foundation

final class RemindersChannel: NSObject {
    static func register(with registrar: FlutterPluginRegistrar) {
        let channel = FlutterMethodChannel(name: "earmark/reminders", binaryMessenger: registrar.messenger())
        let me = RemindersChannel()
        channel.setMethodCallHandler { call, result in me.handle(call, result: result) }
        retained = me
    }

    private static var retained: RemindersChannel?
    private let store = EKEventStore()

    func handle(_ call: FlutterMethodCall, result: @escaping FlutterResult) {
        let reply: (Any?) -> Void = { value in DispatchQueue.main.async { result(value) } }
        switch call.method {
        case "access":
            let done: (Bool, Error?) -> Void = { ok, _ in reply(["granted": ok]) }
            if #available(iOS 17.0, *) {
                store.requestFullAccessToReminders(completion: done)
            } else {
                store.requestAccess(to: .reminder, completion: done)
            }
        case "sync":
            let args = call.arguments as? [String: Any] ?? [:]
            let items = args["items"] as? [[String: Any]] ?? []
            sync(items) { r in reply(r) }
        default:
            result(FlutterMethodNotImplemented)
        }
    }

    private var authorized: Bool {
        let s = EKEventStore.authorizationStatus(for: .reminder)
        if #available(iOS 17.0, *) { return s == .fullAccess }
        return s == .authorized
    }

    private func list() throws -> EKCalendar {
        if let id = UserDefaults.standard.string(forKey: "earmark.reminders.list"),
            let cal = store.calendar(withIdentifier: id)
        {
            return cal
        }
        if let cal = store.calendars(for: .reminder).first(where: { $0.title == "Earmark" }) {
            UserDefaults.standard.set(cal.calendarIdentifier, forKey: "earmark.reminders.list")
            return cal
        }
        let cal = EKCalendar(for: .reminder, eventStore: store)
        cal.title = "Earmark"
        guard let source = store.defaultCalendarForNewReminders()?.source ?? store.sources.first(where: { $0.sourceType == .local })
        else {
            throw NSError(domain: "earmark", code: 1, userInfo: [NSLocalizedDescriptionKey: "No place to keep reminders"])
        }
        cal.source = source
        try store.saveCalendar(cal, commit: true)
        UserDefaults.standard.set(cal.calendarIdentifier, forKey: "earmark.reminders.list")
        return cal
    }

    private func sync(_ items: [[String: Any]], done: @escaping ([String: Any]) -> Void) {
        guard authorized else {
            done(["error": "no access", "done": [String]()])
            return
        }
        let cal: EKCalendar
        do { cal = try list() } catch {
            done(["error": error.localizedDescription, "done": [String]()])
            return
        }
        let predicate = store.predicateForReminders(in: [cal])
        store.fetchReminders(matching: predicate) { found in
            let existing = Dictionary(
                (found ?? []).compactMap { r -> (String, EKReminder)? in
                    guard let u = r.url?.absoluteString, u.hasPrefix("earmark://task/") else { return nil }
                    return (String(u.dropFirst("earmark://task/".count)), r)
                }, uniquingKeysWith: { a, _ in a })
            var completed: [String] = []
            for it in items {
                guard let id = it["id"] as? String, let title = it["title"] as? String else { continue }
                let wantDone = it["done"] as? Bool ?? false
                let r: EKReminder
                if let e = existing[id] {
                    r = e
                    if e.isCompleted && !wantDone {
                        completed.append(id)   // ticked off in Reminders
                        continue
                    }
                    if e.isCompleted == wantDone && e.title == title { continue }   // nothing changed
                } else {
                    if wantDone { continue }   // never send what's already done
                    r = EKReminder(eventStore: self.store)
                    r.calendar = cal
                    r.url = URL(string: "earmark://task/\(id)")
                    if let due = (it["due"] as? NSNumber)?.doubleValue {
                        let date = Date(timeIntervalSince1970: due)
                        let timed = it["timed"] as? Bool ?? false
                        var comps = Calendar.current.dateComponents([.year, .month, .day, .hour, .minute], from: date)
                        if !timed {
                            comps.hour = nil
                            comps.minute = nil
                        }
                        r.dueDateComponents = comps
                        if timed { r.addAlarm(EKAlarm(absoluteDate: date)) }
                    }
                }
                r.title = title
                r.notes = it["notes"] as? String
                r.isCompleted = wantDone
                try? self.store.save(r, commit: false)
            }
            try? self.store.commit()
            done(["done": completed])
        }
    }
}
