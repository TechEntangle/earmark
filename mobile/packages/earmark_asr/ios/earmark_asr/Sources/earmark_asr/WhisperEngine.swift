// A small Whisper (base, multilingual, ~140 MB, via WhisperKit) on the iPhone, used only to tell
// which language a chunk of speech is in. English is transcribed on the phone by Parakeet;
// anything else is left to the Mac, whose full Whisper large-v3 transcribes and translates it.
//
// Kept in its own file: WhisperKit and FluidAudio both name types like WordTiming.
import Foundation
import WhisperKit

actor WhisperEngine {
    /// Multilingual base: enough to tell English from other languages.
    static let variant = "openai_whisper-base"
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
        if !p.hasSuffix(variant) {
            // an earlier, bigger model (large-v3): remove it to free the space
            try? FileManager.default.removeItem(atPath: p)
            UserDefaults.standard.removeObject(forKey: savedFolderKey)
            return nil
        }
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
}
