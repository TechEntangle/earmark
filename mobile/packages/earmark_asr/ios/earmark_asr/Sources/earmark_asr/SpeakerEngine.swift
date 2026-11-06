// Who spoke when, on the iPhone: FluidAudio's offline diarizer (pyannote segmentation + WeSpeaker
// voice signatures + VBx clustering, Core ML). Names are matched against the voices saved in the
// app (Dart side); this only finds the speakers and their voice signatures.
//
// Channel "earmark/speakers":
//   diarize {paths, offsets} → {segments: [[start, end, id]], speakers: {id: {embedding, seconds, energy}}}
//            times in seconds from the start of the conversation
import Flutter
import FluidAudio
import Foundation

final class SpeakersChannel: NSObject {
    static func register(with registrar: FlutterPluginRegistrar) {
        let channel = FlutterMethodChannel(name: "earmark/speakers", binaryMessenger: registrar.messenger())
        let me = SpeakersChannel()
        channel.setMethodCallHandler { call, result in me.handle(call, result: result) }
        retained = me
    }

    private static var retained: SpeakersChannel?
    private let engine = SpeakerEngine()

    func handle(_ call: FlutterMethodCall, result: @escaping FlutterResult) {
        let args = call.arguments as? [String: Any] ?? [:]
        let reply: (Any?) -> Void = { value in DispatchQueue.main.async { result(value) } }
        switch call.method {
        case "diarize":
            let paths = args["paths"] as? [String] ?? []
            let offsets = (args["offsets"] as? [NSNumber] ?? []).map { $0.doubleValue }
            let engine = self.engine
            Task {
                do {
                    reply(try await engine.diarize(paths: paths, offsets: offsets))
                } catch {
                    reply(FlutterError(code: "speakers", message: error.localizedDescription, details: String(describing: error)))
                }
            }
        default:
            result(FlutterMethodNotImplemented)
        }
    }
}

actor SpeakerEngine {
    private var manager: OfflineDiarizerManager?

    func diarize(paths: [String], offsets: [Double]) async throws -> [String: Any] {
        let audio = AudioChannel.samples(paths: paths, offsets: offsets)
        let rate = Double(OpusChunk.sampleRate)
        if audio.count < OpusChunk.sampleRate * 2 {
            return ["segments": [[Any]](), "speakers": [String: Any]()]
        }
        if manager == nil {
            let m = OfflineDiarizerManager()
            try await m.prepareModels()
            manager = m
        }
        let r = try await manager!.process(audio: audio)
        var segs: [[Any]] = []
        var seconds: [String: Double] = [:]
        var energy: [String: (Double, Int)] = [:]
        var sums: [String: [Float]] = [:]
        for g in r.segments {
            let a = Double(g.startTimeSeconds), b = Double(g.endTimeSeconds)
            segs.append([a, b, g.speakerId])
            seconds[g.speakerId, default: 0] += b - a
            let lo = max(0, Int(a * rate)), hi = min(audio.count, Int(b * rate))
            if hi > lo {
                var acc = 0.0
                for i in stride(from: lo, to: hi, by: 4) { acc += Double(audio[i] * audio[i]) }
                let n = (hi - lo + 3) / 4
                let e = energy[g.speakerId] ?? (0, 0)
                energy[g.speakerId] = (e.0 + acc, e.1 + n)
            }
            if !g.embedding.isEmpty {
                let w = Float(b - a)
                let cur = sums[g.speakerId] ?? [Float](repeating: 0, count: g.embedding.count)
                if cur.count == g.embedding.count {
                    sums[g.speakerId] = zip(cur, g.embedding).map { $0 + $1 * w }
                }
            }
        }
        var speakers: [String: Any] = [:]
        for (id, secs) in seconds {
            let emb = r.speakerDatabase?[id] ?? sums[id] ?? []
            let e = energy[id] ?? (0, 1)
            speakers[id] = [
                "embedding": emb.map { Double($0) },
                "seconds": secs,
                "energy": (e.0 / Double(max(1, e.1))).squareRoot(),
            ]
        }
        return ["segments": segs, "speakers": speakers]
    }
}
