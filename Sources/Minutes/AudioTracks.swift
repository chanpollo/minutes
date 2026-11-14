import AVFoundation
import Foundation

struct AudioTrackError: LocalizedError {
    let message: String
    var errorDescription: String? { message }
}

/// The recorded tracks of a meeting: 16 kHz mono WAV while recording, FLAC (lossless) once transcribed when
/// Settings.compressAudio is on. Readers look for either.
enum AudioTracks {
    static let names = ["me", "others"]
    /// Every file name a track can have.
    static let fileNames = names.flatMap { ["\($0).flac", "\($0).wav"] }

    /// The file holding track `name` in `folder`; FLAC wins when a compression was cut off before the WAV went.
    static func url(_ name: String, in folder: URL) -> URL? {
        ["flac", "wav"].lazy
            .map { folder.appendingPathComponent("\(name).\($0)") }
            .first { FileManager.default.fileExists(atPath: $0.path) }
    }

    static func existing(in folder: URL) -> [URL] {
        names.compactMap { url($0, in: folder) }
    }

    static func seconds(_ url: URL) -> TimeInterval {
        guard let file = try? AVAudioFile(forReading: url) else { return 0 }
        return Double(file.length) / file.fileFormat.sampleRate
    }

    /// Envelope correlation above this means the mic carries the call: the two leaking recordings measured 0.25 and
    /// 0.28, every other of 37 at most 0.07.
    static let leakThreshold = 0.2

    /// How much the mic follows the call: the best correlation of the two tracks' 100 ms log loudness within ±1 s.
    static func leak(me: URL, others: URL) -> Double {
        guard let a = envelope(me), let b = envelope(others) else { return 0 }
        let count = min(a.count, b.count)
        guard count > 100 else { return 0 }
        var best = 0.0
        for lag in -10...10 {
            let x = a[max(0, lag)..<(count + min(0, lag))], y = b[max(0, -lag)..<(count - max(0, lag))]
            best = max(best, correlation(Array(x), Array(y)))
        }
        return best
    }

    private static func envelope(_ url: URL) -> [Double]? {
        guard let file = try? AVAudioFile(forReading: url, commonFormat: .pcmFormatInt16, interleaved: true) else { return nil }
        let window = AVAudioFrameCount(file.processingFormat.sampleRate / 10)
        guard window > 0, let buffer = AVAudioPCMBuffer(pcmFormat: file.processingFormat, frameCapacity: window) else { return nil }
        var out: [Double] = []
        while file.framePosition < file.length {
            guard (try? file.read(into: buffer, frameCount: window)) != nil, buffer.frameLength == window,
                  let samples = buffer.int16ChannelData?[0] else { break }
            var squares = 0.0
            for i in 0..<Int(window) {
                let v = Double(samples[i]) / 32_768
                squares += v * v
            }
            out.append(log((squares / Double(window)).squareRoot() + 1e-6))
        }
        return out
    }

    private static func correlation(_ x: [Double], _ y: [Double]) -> Double {
        let n = Double(x.count)
        let mx = x.reduce(0, +) / n, my = y.reduce(0, +) / n
        var sxy = 0.0, sxx = 0.0, syy = 0.0
        for i in x.indices {
            let dx = x[i] - mx, dy = y[i] - my
            sxy += dx * dy; sxx += dx * dx; syy += dy * dy
        }
        return sxx > 0 && syy > 0 ? sxy / (sxx * syy).squareRoot() : 0
    }

    /// Re-encodes every WAV track in `folder` to FLAC; returns the bytes saved. Failures leave the WAV in place.
    @discardableResult
    static func compress(in folder: URL) -> Int64 {
        var saved: Int64 = 0
        for name in names {
            let wav = folder.appendingPathComponent("\(name).wav")
            guard FileManager.default.fileExists(atPath: wav.path) else { continue }
            do {
                saved += try compress(wav)
            } catch {
                NSLog("Minutes: %@ not compressed: %@", wav.path, error.localizedDescription)
            }
        }
        return saved
    }

    /// WAV to FLAC next to it. The FLAC is read back and compared sample by sample before the WAV is removed.
    static func compress(_ wav: URL) throws -> Int64 {
        let fm = FileManager.default
        let flac = wav.deletingPathExtension().appendingPathExtension("flac")
        let partial = wav.deletingLastPathComponent().appendingPathComponent(".\(wav.deletingPathExtension().lastPathComponent).partial.flac")
        try? fm.removeItem(at: partial)
        do {
            try encode(wav, to: partial)
            guard try sameSamples(wav, partial) else {
                throw AudioTrackError(message: "FLAC copy of \(wav.lastPathComponent) does not match")
            }
            if fm.fileExists(atPath: flac.path) {
                _ = try fm.replaceItemAt(flac, withItemAt: partial)
            } else {
                try fm.moveItem(at: partial, to: flac)
            }
        } catch {
            try? fm.removeItem(at: partial)
            throw error
        }
        let before = size(wav)
        try fm.removeItem(at: wav)
        return before - size(flac)
    }

    /// Any readable track as 16-bit WAV, for tools that only read WAV.
    static func decodeToWAV(_ source: URL, to target: URL) throws {
        try copySamples(from: source, to: target) { format in
            [
                AVFormatIDKey: kAudioFormatLinearPCM,
                AVSampleRateKey: format.sampleRate,
                AVNumberOfChannelsKey: format.channelCount,
                AVLinearPCMBitDepthKey: 16,
                AVLinearPCMIsFloatKey: false,
                AVLinearPCMIsBigEndianKey: false,
            ]
        }
    }

    /// `from`…`to` seconds of a track as 16-bit WAV, for a second whisper pass over one stretch.
    static func slice(_ source: URL, from: TimeInterval, to: TimeInterval, into target: URL) throws {
        let input = try AVAudioFile(forReading: source, commonFormat: .pcmFormatInt16, interleaved: true)
        let rate = input.fileFormat.sampleRate
        let first = max(0, Int64(from * rate)), last = min(input.length, Int64(to * rate))
        guard last > first else { throw AudioTrackError(message: "Nothing to cut from \(source.lastPathComponent)") }
        let output = try AVAudioFile(forWriting: target, settings: [
            AVFormatIDKey: kAudioFormatLinearPCM,
            AVSampleRateKey: rate,
            AVNumberOfChannelsKey: input.fileFormat.channelCount,
            AVLinearPCMBitDepthKey: 16,
            AVLinearPCMIsFloatKey: false,
            AVLinearPCMIsBigEndianKey: false,
        ], commonFormat: .pcmFormatInt16, interleaved: true)
        guard let buffer = AVAudioPCMBuffer(pcmFormat: input.processingFormat, frameCapacity: 65_536) else {
            throw AudioTrackError(message: "Cannot read \(source.lastPathComponent)")
        }
        input.framePosition = first
        var remaining = AVAudioFrameCount(last - first)
        while remaining > 0 {
            try input.read(into: buffer, frameCount: min(remaining, buffer.frameCapacity))
            guard buffer.frameLength > 0 else { break }
            try output.write(from: buffer)
            remaining -= buffer.frameLength
        }
    }

    private static func encode(_ wav: URL, to flac: URL) throws {
        try copySamples(from: wav, to: flac) { format in
            [
                AVFormatIDKey: kAudioFormatFLAC,
                AVSampleRateKey: format.sampleRate,
                AVNumberOfChannelsKey: format.channelCount,
                AVLinearPCMBitDepthKey: 16,
            ]
        }
    }

    // The output file is closed (and its header written) when it goes out of scope here.
    private static func copySamples(from source: URL, to target: URL, settings: (AVAudioFormat) -> [String: Any]) throws {
        let input = try AVAudioFile(forReading: source, commonFormat: .pcmFormatInt16, interleaved: true)
        let output = try AVAudioFile(
            forWriting: target, settings: settings(input.fileFormat), commonFormat: .pcmFormatInt16, interleaved: true)
        guard let buffer = AVAudioPCMBuffer(pcmFormat: input.processingFormat, frameCapacity: 65_536) else {
            throw AudioTrackError(message: "Cannot read \(source.lastPathComponent)")
        }
        while input.framePosition < input.length {
            try input.read(into: buffer)
            guard buffer.frameLength > 0 else { break }
            try output.write(from: buffer)
        }
    }

    static func sameSamples(_ a: URL, _ b: URL) throws -> Bool {
        let first = try AVAudioFile(forReading: a, commonFormat: .pcmFormatInt16, interleaved: true)
        let second = try AVAudioFile(forReading: b, commonFormat: .pcmFormatInt16, interleaved: true)
        guard first.length == second.length, first.processingFormat == second.processingFormat,
              let x = AVAudioPCMBuffer(pcmFormat: first.processingFormat, frameCapacity: 65_536),
              let y = AVAudioPCMBuffer(pcmFormat: second.processingFormat, frameCapacity: 65_536)
        else { return false }
        let channels = Int(first.processingFormat.channelCount)
        while first.framePosition < first.length {
            try first.read(into: x)
            // A short read fails the check, which only keeps the WAV.
            try second.read(into: y, frameCount: x.frameLength)
            guard x.frameLength == y.frameLength, x.frameLength > 0,
                  let p = x.int16ChannelData?[0], let q = y.int16ChannelData?[0],
                  memcmp(p, q, Int(x.frameLength) * channels * 2) == 0
            else { return false }
        }
        return second.framePosition == second.length
    }

    private static func size(_ url: URL) -> Int64 {
        ((try? FileManager.default.attributesOfItem(atPath: url.path))?[.size] as? NSNumber)?.int64Value ?? 0
    }
}
