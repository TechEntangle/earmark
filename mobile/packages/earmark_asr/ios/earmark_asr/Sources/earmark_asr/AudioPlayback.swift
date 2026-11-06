// Playing back recordings on the iPhone.
//
// Channel "earmark/audio":
//   prepare {paths: [String], offsets: [Double], out: String} → {seconds}
//           decodes the pendant's Opus chunks into one WAV (16 kHz mono), each chunk placed at its
//           offset (seconds from the start), with silence in any gaps, so times match the transcript
//   play {path, at?}   plays the file (from [at] seconds)
//   pause / stop
//   seek {at}
//   speed {speed}   1, 1.25, 1.5, 2 (pitch kept)
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
    private var speed: Float = 1

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
                    player?.enableRate = true
                    player?.delegate = self
                    player?.prepareToPlay()
                    path = p
                }
                player?.enableRate = true
                player?.rate = Float((args["speed"] as? NSNumber)?.doubleValue ?? Double(speed))
                speed = player?.rate ?? 1
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
        case "speed":
            speed = Float((args["speed"] as? NSNumber)?.doubleValue ?? 1)
            if let pl = player {
                pl.enableRate = true
                pl.rate = speed
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
            "speed": Double(speed),
            "fileRate": player?.format.sampleRate ?? 0,
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

    /// 16-bit PCM WAV, 16 kHz mono, written by AVAudioFile (so the header is exactly what iOS expects).
    static func writeWav(paths: [String], offsets: [Double], out: String) throws -> Double {
        let rate = Double(OpusChunk.sampleRate)
        let samples = Self.samples(paths: paths, offsets: offsets)
        let url = URL(fileURLWithPath: out)
        try? FileManager.default.removeItem(at: url)
        let settings: [String: Any] = [
            AVFormatIDKey: kAudioFormatLinearPCM, AVSampleRateKey: rate, AVNumberOfChannelsKey: 1,
            AVLinearPCMBitDepthKey: 16, AVLinearPCMIsFloatKey: false, AVLinearPCMIsBigEndianKey: false,
        ]
        guard let fmt = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: rate, channels: 1, interleaved: false)
        else { throw NSError(domain: "earmark", code: 2, userInfo: [NSLocalizedDescriptionKey: "no audio format"]) }
        let file = try AVAudioFile(forWriting: url, settings: settings, commonFormat: .pcmFormatFloat32, interleaved: false)
        let block = 16000 * 30
        var i = 0
        while i < samples.count {
            let n = min(block, samples.count - i)
            guard let buf = AVAudioPCMBuffer(pcmFormat: fmt, frameCapacity: AVAudioFrameCount(n)) else { break }
            buf.frameLength = AVAudioFrameCount(n)
            samples.withUnsafeBufferPointer { src in
                buf.floatChannelData![0].update(from: src.baseAddress! + i, count: n)
            }
            try file.write(from: buf)
            i += n
        }
        return Double(samples.count) / rate
    }
}
