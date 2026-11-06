// Notes and tasks from a transcript, on the iPhone, with Apple's on-device language model
// (Foundation Models, iOS 26, Apple Intelligence). Nothing leaves the phone.
//
// Channel "earmark/notes":
//   availability → {state: available | notEligible | notEnabled | notReady | unsupported}
//   notes {lines: [String], header: String} → {title, kind, summary, keyPoints, decisions, tasks, people, topics}
//   embed {texts: [String]} → [[Double]]   sentence vectors (Apple's built-in English sentence embedding, 512-d)
//   answer {question, excerpts: [String], today} → {answer, sources: [Int]}   (Ask; excerpts numbered from 1)
//         lines are "[mm:ss] text", optionally starting with ★ (earmarked) or ◆ (asked to save a task)
//
// The on-device model has a small context (about 4,000 tokens), so a long conversation is read in
// parts and the parts' notes are merged.
import Flutter
import Foundation
import NaturalLanguage

#if canImport(FoundationModels)
    import FoundationModels
#endif

final class NotesChannel: NSObject {
    static func register(with registrar: FlutterPluginRegistrar) {
        let channel = FlutterMethodChannel(name: "earmark/notes", binaryMessenger: registrar.messenger())
        let me = NotesChannel()
        channel.setMethodCallHandler { call, result in me.handle(call, result: result) }
        retained = me
    }

    private static var retained: NotesChannel?

    func handle(_ call: FlutterMethodCall, result: @escaping FlutterResult) {
        let reply: (Any?) -> Void = { value in DispatchQueue.main.async { result(value) } }
        switch call.method {
        case "availability":
            reply(["state": NotesEngine.availability()])
        case "notes":
            let args = call.arguments as? [String: Any] ?? [:]
            let lines = args["lines"] as? [String] ?? []
            let header = args["header"] as? String ?? ""
            Task {
                do {
                    reply(try await NotesEngine.notes(lines: lines, header: header))
                } catch let e as NotesError {
                    reply(FlutterError(code: e.code, message: e.message, details: nil))
                } catch {
                    reply(FlutterError(code: "failed", message: error.localizedDescription, details: String(describing: error)))
                }
            }
        case "embed":
            let args = call.arguments as? [String: Any] ?? [:]
            let texts = args["texts"] as? [String] ?? []
            DispatchQueue.global(qos: .userInitiated).async {
                let out = Embedder.embed(texts)
                DispatchQueue.main.async { result(out) }
            }
        case "answer":
            let args = call.arguments as? [String: Any] ?? [:]
            let question = args["question"] as? String ?? ""
            let excerpts = args["excerpts"] as? [String] ?? []
            let today = args["today"] as? String ?? ""
            Task {
                do {
                    reply(try await NotesEngine.answer(question: question, excerpts: excerpts, today: today))
                } catch let e as NotesError {
                    reply(FlutterError(code: e.code, message: e.message, details: nil))
                } catch {
                    reply(FlutterError(code: "failed", message: error.localizedDescription, details: String(describing: error)))
                }
            }
        default:
            result(FlutterMethodNotImplemented)
        }
    }
}

/// Sentence vectors with Apple's built-in embedding (on the phone, no download).
enum Embedder {
    static let model = NLEmbedding.sentenceEmbedding(for: .english)

    static func embed(_ texts: [String]) -> [[Double]] {
        guard let m = model else { return texts.map { _ in [] } }
        return texts.map { t in
            let s = String(t.prefix(2000))
            return m.vector(for: s) ?? []
        }
    }
}

struct NotesError: Error {
    let code: String   // unsupported | context | guardrail | busy | language | failed
    let message: String
}

enum NotesEngine {
    static func availability() -> String {
        #if canImport(FoundationModels)
            if #available(iOS 26.0, *) {
                switch SystemLanguageModel.default.availability {
                case .available: return "available"
                case .unavailable(.deviceNotEligible): return "notEligible"
                case .unavailable(.appleIntelligenceNotEnabled): return "notEnabled"
                case .unavailable(.modelNotReady): return "notReady"
                default: return "unsupported"
                }
            }
        #endif
        return "unsupported"
    }

    static func answer(question: String, excerpts: [String], today: String) async throws -> [String: Any] {
        #if canImport(FoundationModels)
            if #available(iOS 26.0, *) {
                return try await OnDeviceNotes.answer(question: question, excerpts: excerpts, today: today)
            }
        #endif
        throw NotesError(code: "unsupported", message: "Answers on the iPhone need iOS 26 with Apple Intelligence")
    }

    static func notes(lines: [String], header: String) async throws -> [String: Any] {
        #if canImport(FoundationModels)
            if #available(iOS 26.0, *) {
                return try await OnDeviceNotes.run(lines: lines, header: header)
            }
        #endif
        throw NotesError(code: "unsupported", message: "Notes on the iPhone need iOS 26 with Apple Intelligence")
    }
}

#if canImport(FoundationModels)

    @available(iOS 26.0, *)
    @Generable
    struct GenTask {
        @Guide(description: "A specific, self-contained action starting with a verb that names what it is about. Write 'me' for the wearer.")
        var task: String
        @Guide(description: "Who will do it: 'me' for the wearer, a person's first name, or 'unknown'")
        var owner: String
        @Guide(description: "The deadline exactly as it was said, such as 'by Thursday', or an empty string")
        var dueText: String
        @Guide(description: "True only if the conversation says this was already finished")
        var done: Bool
    }

    @available(iOS 26.0, *)
    @Generable
    struct GenNotes {
        @Guide(description: "A specific title, at most 8 words, without a date")
        var title: String
        @Guide(description: "What kind of recording it is", .anyOf(["meeting", "call", "conversation", "note_to_self", "ambient"]))
        var kind: String
        @Guide(description: "2 to 4 sentences: what it was about and what came out of it")
        var summary: String
        @Guide(description: "The key points, at most 6")
        var keyPoints: [String]
        @Guide(description: "Decisions actually agreed, at most 5")
        var decisions: [String]
        @Guide(description: "Real commitments and requests only, at most 12")
        var tasks: [GenTask]
        @Guide(description: "First names of people mentioned or present, at most 8")
        var people: [String]
        @Guide(description: "2 to 5 short topic tags")
        var topics: [String]
    }

    @available(iOS 26.0, *)
    @Generable
    struct GenPart {
        @Guide(description: "2 to 3 sentences about this part")
        var summary: String
        @Guide(description: "The key points of this part, at most 5")
        var keyPoints: [String]
        @Guide(description: "Decisions agreed in this part, at most 4")
        var decisions: [String]
        @Guide(description: "Real commitments and requests in this part, at most 10")
        var tasks: [GenTask]
        @Guide(description: "First names mentioned or present, at most 8")
        var people: [String]
    }

    @available(iOS 26.0, *)
    @Generable
    struct GenMerge {
        @Guide(description: "A specific title for the whole recording, at most 8 words, without a date")
        var title: String
        @Guide(description: "What kind of recording it is", .anyOf(["meeting", "call", "conversation", "note_to_self", "ambient"]))
        var kind: String
        @Guide(description: "3 to 6 sentences about the whole recording")
        var summary: String
        @Guide(description: "The most important key points, at most 8")
        var keyPoints: [String]
        @Guide(description: "2 to 5 short topic tags")
        var topics: [String]
    }

    @available(iOS 26.0, *)
    @Generable
    struct GenAnswer {
        @Guide(description: "The answer in 1 to 5 sentences, using only the excerpts. If they don't contain it, say so plainly.")
        var answer: String
        @Guide(description: "The numbers of the excerpts the answer relies on")
        var sources: [Int]
    }

    @available(iOS 26.0, *)
    enum OnDeviceNotes {
        static func answer(question: String, excerpts: [String], today: String) async throws -> [String: Any] {
            guard SystemLanguageModel.default.isAvailable else {
                throw NotesError(code: "unsupported", message: "Apple Intelligence is not available: \(NotesEngine.availability())")
            }
            let rules = """
                You answer questions about the user's own recorded conversations, using only the numbered excerpts.
                The user wore the recorder and is "me"/"Me" in the excerpts. Today is \(today).
                Be direct and specific: names, numbers, dates and who promised what. Cite the excerpts you used.
                If the excerpts don't answer the question, say you couldn't find it. Never invent anything.
                """
            var list = excerpts
            while true {
                let numbered = list.enumerated().map { "[\($0.offset + 1)] \($0.element)" }.joined(separator: "\n\n")
                let session = LanguageModelSession(instructions: rules)
                do {
                    let r = try await session.respond(
                        to: "Question: \(question)\n\nExcerpts:\n\(numbered)", generating: GenAnswer.self, options: options
                    ).content
                    return ["answer": r.answer, "sources": r.sources.filter { $0 >= 1 && $0 <= list.count }]
                } catch let e as LanguageModelSession.GenerationError {
                    if case .exceededContextWindowSize = e, list.count > 2 {
                        list = Array(list.prefix(list.count * 2 / 3))
                        continue
                    }
                    throw map(e)
                }
            }
        }

        static let rules = """
            You turn transcripts from a wearable voice recorder into precise notes. The person wearing the recorder is "me".
            Lines are [mm:ss] timestamps followed by speech; work out who is speaking from the back-and-forth.
            Tasks: only real commitments or requests (someone agrees to do something, is asked to, or says they will), \
            not ideas or wishes. Write each task so it makes sense on its own a week later. Inside task text refer to the \
            wearer as "me". The owner is "me" when the speaker commits and you cannot tell it is someone else. \
            Copy deadline words as said; do not calculate dates. If something was reported as finished, mark it done.
            Lines starting with ◆ are the wearer asking the notes app to save a task or reminder: always make a task owned by "me".
            Lines starting with ★ were earmarked by the wearer as important: always cover them in the key points.
            Never invent tasks, names or dates. Empty lists are fine. Use kind "ambient" for background talk with nothing to act on.
            """

        static var options: GenerationOptions { GenerationOptions(temperature: 0.2) }

        static func run(lines: [String], header: String) async throws -> [String: Any] {
            guard SystemLanguageModel.default.isAvailable else {
                throw NotesError(code: "unsupported", message: "Apple Intelligence is not available: \(NotesEngine.availability())")
            }
            var budget = 1100   // words of transcript per request; halved if the model says it is too long
            while true {
                let parts = split(lines, words: budget)
                do {
                    if parts.count == 1 {
                        return dict(try await single(parts[0], header: header))
                    }
                    return try await long(parts, header: header)
                } catch let e as LanguageModelSession.GenerationError {
                    if case .exceededContextWindowSize = e, budget > 300 {
                        budget /= 2
                        continue
                    }
                    throw map(e)
                }
            }
        }

        static func split(_ lines: [String], words: Int) -> [[String]] {
            var parts: [[String]] = [[]]
            var n = 0
            for l in lines {
                let w = l.split(separator: " ").count
                if n + w > words, !parts[parts.count - 1].isEmpty {
                    parts.append([])
                    n = 0
                }
                parts[parts.count - 1].append(l)
                n += w
            }
            return parts
        }

        static func single(_ lines: [String], header: String) async throws -> GenNotes {
            let session = LanguageModelSession(instructions: rules)
            let prompt = "\(header)\n\nTranscript:\n\(lines.joined(separator: "\n"))"
            return try await session.respond(to: prompt, generating: GenNotes.self, options: options).content
        }

        static func long(_ parts: [[String]], header: String) async throws -> [String: Any] {
            var got: [GenPart] = []
            for (i, p) in parts.enumerated() {
                let session = LanguageModelSession(instructions: rules)
                let prompt = "\(header) This is part \(i + 1) of \(parts.count) of one long recording; note this part only.\n\nTranscript:\n\(p.joined(separator: "\n"))"
                got.append(try await session.respond(to: prompt, generating: GenPart.self, options: options).content)
            }
            let digest = got.enumerated().map { i, g in
                "Part \(i + 1): \(g.summary)\nKey points: \(g.keyPoints.joined(separator: "; "))"
            }.joined(separator: "\n\n")
            let session = LanguageModelSession(
                instructions: "You merge notes from consecutive parts of ONE long recording into notes for the whole recording. Never invent.")
            let m = try await session.respond(to: "\(header)\n\n\(digest)", generating: GenMerge.self, options: options).content
            var seen = Set<String>()
            var tasks: [GenTask] = []
            for t in got.flatMap(\.tasks) {
                let key = t.task.lowercased().filter { $0.isLetter || $0.isNumber }
                if !key.isEmpty, seen.insert(key).inserted { tasks.append(t) }
            }
            var people: [String] = []
            for p in got.flatMap(\.people) where !people.contains(p) { people.append(p) }
            return [
                "title": m.title, "kind": m.kind, "summary": m.summary, "keyPoints": m.keyPoints,
                "decisions": got.flatMap(\.decisions), "tasks": tasks.map(task), "people": people, "topics": m.topics,
                "parts": parts.count,
            ]
        }

        static func task(_ t: GenTask) -> [String: Any] {
            ["task": t.task, "owner": t.owner, "dueText": t.dueText, "done": t.done]
        }

        static func dict(_ n: GenNotes) -> [String: Any] {
            [
                "title": n.title, "kind": n.kind, "summary": n.summary, "keyPoints": n.keyPoints,
                "decisions": n.decisions, "tasks": n.tasks.map(task), "people": n.people, "topics": n.topics, "parts": 1,
            ]
        }

        static func map(_ e: LanguageModelSession.GenerationError) -> NotesError {
            switch e {
            case .exceededContextWindowSize: return NotesError(code: "context", message: "The conversation is too long for the on-device model")
            case .guardrailViolation: return NotesError(code: "guardrail", message: "Apple's model declined to summarise this conversation")
            case .unsupportedLanguageOrLocale: return NotesError(code: "language", message: "The conversation's language is not supported on the iPhone")
            case .rateLimited, .concurrentRequests: return NotesError(code: "busy", message: "The on-device model is busy; trying again later")
            default: return NotesError(code: "failed", message: e.localizedDescription)
            }
        }
    }

#endif
