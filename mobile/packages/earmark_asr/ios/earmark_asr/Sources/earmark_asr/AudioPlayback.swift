// Playing back recordings on the iPhone.
//
// Channel "earmark/audio":
//   prepare {paths: [String], offsets: [Double], out: String} → {seconds}
//           decodes the pendant's Opus chunks into one WAV (16 kHz mono), each chunk placed at its
//           offset (seconds from the start), with silence in any gaps, so times match the transcript
//   play {path, at?}   plays the file (from [at] seconds)
//   pause / stop
//   seek {at}
//   state → {playing, position, duration, path}
import AVFoundation
import Flutter
import Foundation

final class AudioChannel: NSObject, AVAudioPlayerDelegate {
    static func register(with registrar: FlutterPluginRegistrar) {
        let channel = FlutterMethodChannel(name: "earmark/audio", binaryMessenger: registrar.messenger())
        let me = AudioChannel()
        channel.setMethodCallHandler { call, result in me.handle(call, result: result) }
        retained = me
    }

    private static var retained: AudioChannel?
    private var player: AVAudioPlayer?
    private var path: String?

    func handle(_ call: FlutterMethodCall, result: @escaping FlutterResult) {
        let args = call.arguments as? [String: Any] ?? [:]
        switch call.method {
        case "prepare":
            let paths = args["paths"] as? [String] ?? []
            let offsets = (args["offsets"] as? [NSNumber] ?? []).map { $0.doubleValue }
            guard let out = args["out"] as? String else {
                result(FlutterError(code: "args", message: "out is required", details: nil))
                return
            }
            DispatchQueue.global(qos: .userInitiated).async {
                do {
                    let secs = try Self.writeWav(paths: paths, offsets: offsets, out: out)
                    DispatchQueue.main.async { result(["seconds": secs]) }
                } catch {
                    DispatchQueue.main.async {
                        result(FlutterError(code: "audio", message: error.localizedDescription, details: nil))
                    }
                }
            }
        case "play":
            guard let p = args["path"] as? String else {
                result(FlutterError(code: "args", message: "path is required", details: nil))
                return
            }
            do {
                try AVAudioSession.sharedInstance().setCategory(.playback, mode: .spokenAudio)
                try AVAudioSession.sharedInstance().setActive(true)
                if player == nil || path != p {
                    player = try AVAudioPlayer(contentsOf: URL(fileURLWithPath: p))
                    player?.delegate = self
                    player?.prepareToPlay()
                    path = p
                }
                if let at = (args["at"] as? NSNumber)?.doubleValue {
                    player?.currentTime = max(0, min(at, (player?.duration ?? 0) - 0.05))
                }
                player?.play()
                result(state())
            } catch {
                result(FlutterError(code: "audio", message: error.localizedDescription, details: nil))
            }
        case "pause":
            player?.pause()
            result(state())
        case "stop":
            player?.stop()
            player = nil
            path = nil
            try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
            result(state())
        case "seek":
            if let at = (args["at"] as? NSNumber)?.doubleValue, let pl = player {
                pl.currentTime = max(0, min(at, pl.duration - 0.05))
            }
            result(state())
        case "state":
            result(state())
        default:
            result(FlutterMethodNotImplemented)
        }
    }

    private func state() -> [String: Any] {
        [
            "playing": player?.isPlaying ?? false,
            "position": player?.currentTime ?? 0,
            "duration": player?.duration ?? 0,
            "path": path ?? "",
        ]
    }

    func audioPlayerDidFinishPlaying(_ player: AVAudioPlayer, successfully flag: Bool) {
        player.currentTime = 0
    }

    /// The chunks as one stretch of 16 kHz audio, each at its offset, silence in the gaps.
    static func samples(paths: [String], offsets: [Double]) -> [Float] {
        let rate = OpusChunk.sampleRate
        var out: [Float] = []
        for (i, p) in paths.enumerated() {
            let at = i < offsets.count ? offsets[i] : Double(out.count) / Double(rate)
            let want = Int(at * Double(rate))
            if want > out.count {
                out += [Float](repeating: 0, count: min(want - out.count, rate * 600))   // a gap: silence
            }
            out += (try? OpusChunk.decode(path: p)) ?? []
        }
        return out
    }

    /// 16-bit PCM WAV, 16 kHz mono.
    static func writeWav(paths: [String], offsets: [Double], out: String) throws -> Double {
        let rate = OpusChunk.sampleRate
        let samples: [Int16] = Self.samples(paths: paths, offsets: offsets).map { Int16(max(-1, min(1, $0)) * 32767) }
        var data = Data()
        func u32(_ v: UInt32) { var x = v.littleEndian; data.append(Data(bytes: &x, count: 4)) }
        func u16(_ v: UInt16) { var x = v.littleEndian; data.append(Data(bytes: &x, count: 2)) }
        let bytes = UInt32(samples.count * 2)
        data.append("RIFF".data(using: .ascii)!)
        u32(36 + bytes)
        data.append("WAVEfmt ".data(using: .ascii)!)
        u32(16)
        u16(1)
        u16(1)
        u32(UInt32(rate))
        u32(UInt32(rate * 2))
        u16(2)
        u16(16)
        data.append("data".data(using: .ascii)!)
        u32(bytes)
        samples.withUnsafeBufferPointer { b in
            data.append(b.baseAddress!.withMemoryRebound(to: UInt8.self, capacity: samples.count * 2) {
                Data(bytes: $0, count: samples.count * 2)
            })
        }
        try data.write(to: URL(fileURLWithPath: out), options: .atomic)
        return Double(samples.count) / Double(rate)
    }
}
