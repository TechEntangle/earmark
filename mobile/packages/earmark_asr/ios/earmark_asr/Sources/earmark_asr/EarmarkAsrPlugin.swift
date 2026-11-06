// On-device speech to text for Earmark.
//
//   chunk file ([u16 BE length][Opus frame]…, 16 kHz mono, from the pendant)
//     → libopus → 16 kHz Float32 → Parakeet TDT 0.6B v2 (Core ML, Neural Engine, via FluidAudio)
//     → text + word timings (seconds from the start of the chunk)
//
// Channel "earmark/asr":
//   status        → {state: idle|downloading|loading|ready|error, progress: 0…1, onDisk: Bool, error?}
//   prepare       → downloads the model once (~480 MB, from Hugging Face) and loads it
//   transcribe    {path, prev?} → {text, words: [[start, end, word]], seconds}
//                 prev = the chunk just before, if the audio runs on: its last 2 s are used as
//                 context so a word cut at the boundary is heard whole, then dropped from the result.
//   unload        → frees the model's memory (it stays on disk)
//   deleteModels  → removes the model from the phone
import AVFoundation
import Copus
import Flutter
import FluidAudio
import Foundation

public final class EarmarkAsrPlugin: NSObject, FlutterPlugin {
    private let engine = AsrEngine()

    public static func register(with registrar: FlutterPluginRegistrar) {
        let channel = FlutterMethodChannel(name: "earmark/asr", binaryMessenger: registrar.messenger())
        registrar.addMethodCallDelegate(EarmarkAsrPlugin(), channel: channel)
    }

    public func handle(_ call: FlutterMethodCall, result: @escaping FlutterResult) {
        let args = call.arguments as? [String: Any] ?? [:]
        let engine = self.engine
        let reply: (Any?) -> Void = { value in DispatchQueue.main.async { result(value) } }
        let fail: (Error) -> Void = { error in
            reply(FlutterError(code: "asr", message: error.localizedDescription, details: String(describing: error)))
        }
        switch call.method {
        case "status":
            Task { reply(await engine.status()) }
        case "prepare":
            Task {
                do {
                    try await engine.prepare()
                    reply(nil)
                } catch { fail(error) }
            }
        case "transcribe":
            guard let path = args["path"] as? String else {
                result(FlutterError(code: "args", message: "path is required", details: nil))
                return
            }
            let prev = args["prev"] as? String
            Task {
                do {
                    reply(try await engine.transcribe(path: path, prev: prev))
                } catch { fail(error) }
            }
        case "unload":
            Task {
                await engine.unload()
                reply(nil)
            }
        case "deleteModels":
            Task {
                do {
                    try await engine.deleteModels()
                    reply(nil)
                } catch { fail(error) }
            }
        default:
            result(FlutterMethodNotImplemented)
        }
    }
}

enum EarmarkAsrError: LocalizedError {
    case opus(Int32)
    case notReady

    var errorDescription: String? {
        switch self {
        case .opus(let code): return "Could not decode the audio (Opus error \(code))"
        case .notReady: return "The speech model is not ready"
        }
    }
}

actor AsrEngine {
    private let version: AsrModelVersion = .v2   // English, the most accurate for English
    private var manager: AsrManager?
    private var loading: Task<AsrManager, Error>?
    private var state = "idle"
    private var progress = 0.0
    private var lastError: String?

    func status() -> [String: Any] {
        var s: [String: Any] = [
            "state": manager != nil ? "ready" : state,
            "progress": progress,
            "onDisk": AsrModels.modelsExist(at: AsrModels.defaultCacheDirectory(for: version), version: version),
        ]
        if let e = lastError { s["error"] = e }
        return s
    }

    func prepare() async throws {
        _ = try await ready()
    }

    private func ready() async throws -> AsrManager {
        if let m = manager { return m }
        if let t = loading { return try await t.value }
        let version = self.version
        let t = Task { () throws -> AsrManager in
            let models = try await AsrModels.downloadAndLoad(
                version: version,
                progressHandler: { [weak self] p in
                    Task { await self?.update(p) }
                })
            await self.setState("loading")
            let m = AsrManager(config: .default)
            try await m.loadModels(models)
            return m
        }
        loading = t
        state = "downloading"
        lastError = nil
        do {
            let m = try await t.value
            manager = m
            loading = nil
            state = "ready"
            progress = 1
            Self.excludeModelsFromBackup()
            return m
        } catch {
            loading = nil
            state = "error"
            lastError = error.localizedDescription
            throw error
        }
    }

    private func update(_ p: DownloadProgress) {
        progress = p.fractionCompleted
        if case .compiling = p.phase {
            state = "loading"
        }
    }

    private func setState(_ s: String) {
        state = s
    }

    func unload() async {
        if let m = manager {
            await m.cleanup()
        }
        manager = nil
        if state == "ready" { state = "idle" }
    }

    func deleteModels() async throws {
        await unload()
        state = "idle"
        progress = 0
        let dir = AsrModels.defaultCacheDirectory(for: version)
        if FileManager.default.fileExists(atPath: dir.path) {
            try FileManager.default.removeItem(at: dir)
        }
    }

    func transcribe(path: String, prev: String?) async throws -> [String: Any] {
        let m = try await ready()
        let main = try OpusChunk.decode(path: path)
        var lead: [Float] = []
        if let prev, let p = try? OpusChunk.decode(path: prev) {
            lead = Array(p.suffix(OpusChunk.sampleRate * 2))
        }
        let seconds = Double(main.count) / Double(OpusChunk.sampleRate)
        if main.count < OpusChunk.sampleRate / 4 {
            return ["text": "", "words": [[Any]](), "seconds": seconds]
        }
        var (text, words) = try await run(m, lead: lead, main: main)
        if words.isEmpty && !lead.isEmpty && !text.isEmpty {
            // no timings to tell the context apart from the chunk: transcribe the chunk alone
            (text, words) = try await run(m, lead: [], main: main)
        }
        return ["text": text, "words": words, "seconds": seconds]
    }

    private func run(_ m: AsrManager, lead: [Float], main: [Float]) async throws -> (String, [[Any]]) {
        let overlap = Double(lead.count) / Double(OpusChunk.sampleRate)
        var samples = lead + main
        let minimum = OpusChunk.sampleRate   // the model wants at least a second
        if samples.count < minimum {
            samples += [Float](repeating: 0, count: minimum - samples.count)
        }
        var decoderState = TdtDecoderState.make(decoderLayers: await m.decoderLayerCount)
        let r = try await m.transcribe(samples, decoderState: &decoderState)
        let timed = buildWordTimings(from: r.tokenTimings ?? [])
        if timed.isEmpty {
            return (lead.isEmpty ? r.text.trimmingCharacters(in: .whitespacesAndNewlines) : r.text, [])
        }
        var words: [[Any]] = []
        for w in timed where w.startTime >= overlap - 0.08 {
            words.append([max(0, w.startTime - overlap), max(0, w.endTime - overlap), w.word])
        }
        let text = words.compactMap { $0[2] as? String }.joined(separator: " ")
        return (text, words)
    }

    private static func excludeModelsFromBackup() {
        var url = MLModelConfigurationUtils.defaultModelsDirectory()
        var values = URLResourceValues()
        values.isExcludedFromBackup = true
        try? url.setResourceValues(values)
    }
}

/// The phone's recording format: repeated [u16 big-endian length][Opus frame], 16 kHz mono.
enum OpusChunk {
    static let sampleRate = 16000

    static func decode(path: String) throws -> [Float] {
        let bytes = [UInt8](try Data(contentsOf: URL(fileURLWithPath: path)))
        var err: Int32 = 0
        guard let dec = opus_decoder_create(Int32(sampleRate), 1, &err), err == 0 else {
            throw EarmarkAsrError.opus(err)
        }
        defer { opus_decoder_destroy(dec) }
        let maxFrame = sampleRate * 120 / 1000   // the longest Opus frame, 120 ms
        var pcm = [Float](repeating: 0, count: maxFrame)
        var out: [Float] = []
        out.reserveCapacity(bytes.count * 6)
        var i = 0
        while i + 2 <= bytes.count {
            let n = Int(bytes[i]) << 8 | Int(bytes[i + 1])
            i += 2
            guard n > 0, i + n <= bytes.count else { break }
            let start = i
            let got: Int32 = bytes.withUnsafeBufferPointer { b in
                pcm.withUnsafeMutableBufferPointer { p in
                    opus_decode_float(dec, b.baseAddress! + start, Int32(n), p.baseAddress!, Int32(maxFrame), 0)
                }
            }
            i += n
            if got > 0 {
                out.append(contentsOf: pcm[0..<Int(got)])
            } else {
                out.append(contentsOf: [Float](repeating: 0, count: sampleRate / 50))   // keep timing past a bad frame
            }
        }
        return out
    }
}
