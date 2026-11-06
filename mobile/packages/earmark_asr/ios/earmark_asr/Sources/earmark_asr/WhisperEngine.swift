// Whisper large-v3 on the iPhone (WhisperKit, Core ML), for everything that isn't English:
// it tells which language a chunk is in, and translates Hindi, Marathi, Urdu and the rest straight
// into English, as the Mac does. English stays with Parakeet, which is faster and better at it.
//
// Kept in its own file: WhisperKit and FluidAudio both name types like WordTiming.
import Foundation
import WhisperKit

actor WhisperEngine {
    /// The full large-v3 (not "turbo", which translates poorly), compressed for iPhone.
    static let variant = "openai_whisper-large-v3_947MB"
    private static let savedFolderKey = "earmark.whisper.folder"

    private var pipe: WhisperKit?
    private var loading: Task<WhisperKit, Error>?
    private var state = "idle"
    private var progress = 0.0
    private var lastError: String?

    static var downloadBase: URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
        return base.appendingPathComponent("WhisperKit", isDirectory: true)
    }

    /// Where the model was saved after its download (nil until then).
    static var savedFolder: URL? {
        guard let p = UserDefaults.standard.string(forKey: savedFolderKey) else { return nil }
        let url = URL(fileURLWithPath: p, isDirectory: true)
        return FileManager.default.fileExists(atPath: url.appendingPathComponent("AudioEncoder.mlmodelc").path) ? url : nil
    }

    var ready: Bool { pipe != nil }

    func status() -> [String: Any] {
        var s: [String: Any] = [
            "state": pipe != nil ? "ready" : state,
            "progress": progress,
            "onDisk": Self.savedFolder != nil,
        ]
        if let e = lastError { s["error"] = e }
        return s
    }

    func prepare() async throws {
        _ = try await load()
    }

    private func load() async throws -> WhisperKit {
        if let p = pipe { return p }
        if let t = loading { return try await t.value }
        let t = Task { () throws -> WhisperKit in
            var folder = Self.savedFolder
            if folder == nil {
                try FileManager.default.createDirectory(at: Self.downloadBase, withIntermediateDirectories: true)
                let got = try await WhisperKit.download(
                    variant: Self.variant, downloadBase: Self.downloadBase,
                    progressCallback: { [weak self] p in
                        let f = p.fractionCompleted
                        Task { await self?.setProgress(f) }
                    })
                UserDefaults.standard.set(got.path, forKey: Self.savedFolderKey)
                folder = got
                var base = Self.downloadBase
                var values = URLResourceValues()
                values.isExcludedFromBackup = true
                try? base.setResourceValues(values)
            }
            await self.setState("loading")
            let config = WhisperKitConfig(
                model: Self.variant,
                downloadBase: Self.downloadBase,
                modelFolder: folder!.path,
                verbose: false,
                logLevel: .error,
                prewarm: true,
                load: true,
                download: false)
            return try await WhisperKit(config)
        }
        loading = t
        state = Self.savedFolder == nil ? "downloading" : "loading"
        lastError = nil
        do {
            let p = try await t.value
            pipe = p
            loading = nil
            state = "ready"
            progress = 1
            return p
        } catch {
            loading = nil
            state = "error"
            lastError = error.localizedDescription
            throw error
        }
    }

    private func setProgress(_ f: Double) {
        progress = f
    }

    private func setState(_ s: String) {
        state = s
    }

    /// The language of up to 30 s of speech, and how sure Whisper is (0…1).
    func detect(_ samples: [Float]) async throws -> (String, Double) {
        let p = try await load()
        let r = try await p.detectLangauge(audioArray: Array(samples.prefix(16000 * 30)))
        var prob = 1.0
        if let lp = r.langProbs[r.language] {
            prob = lp <= 0 ? exp(Double(lp)) : Double(lp)   // log-probability or probability
        }
        return (r.language, prob)
    }

    /// Translate speech in [language] into English. Words carry times from the start of [samples].
    func translate(_ samples: [Float], language: String) async throws -> (String, [[Any]]) {
        let p = try await load()
        let options = DecodingOptions(
            verbose: false,
            task: .translate,
            language: language,
            temperature: 0,
            temperatureFallbackCount: 3,
            usePrefillPrompt: true,
            detectLanguage: false,
            skipSpecialTokens: true,
            withoutTimestamps: false,
            wordTimestamps: true,
            chunkingStrategy: .vad)
        let results = try await p.transcribe(audioArray: samples, decodeOptions: options)
        var words: [[Any]] = []
        var texts: [String] = []
        for r in results {
            for seg in r.segments {
                let t = seg.text.trimmingCharacters(in: .whitespacesAndNewlines)
                if t.isEmpty || seg.noSpeechProb > 0.8 { continue }
                texts.append(t)
                if let ws = seg.words, !ws.isEmpty {
                    for w in ws {
                        let word = w.word.trimmingCharacters(in: .whitespaces)
                        if !word.isEmpty { words.append([Double(w.start), Double(w.end), word]) }
                    }
                } else {
                    // no word times: spread the segment's words over it
                    let toks = t.split(separator: " ").map(String.init)
                    let step = Double(max(0.05, (seg.end - seg.start) / Float(max(1, toks.count))))
                    for (i, w) in toks.enumerated() {
                        words.append([Double(seg.start) + Double(i) * step, Double(seg.start) + Double(i + 1) * step, w])
                    }
                }
            }
        }
        return (texts.joined(separator: " "), words)
    }
}
