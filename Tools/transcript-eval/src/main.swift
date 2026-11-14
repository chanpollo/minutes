import AppKit
import Foundation

// transcript-eval <tq2 root> <out dir> <name>…
// Runs Transcriber.transcribe the way the app does on a work copy of tq2/src/<name> (FLAC decoded back to the 16 kHz
// WAV a fresh recording has, meta.json as written), Thai forced and the diarizer on through a volatile defaults
// domain, and prints the spec's metrics. Never starts AppDelegate; never reads or writes the user's meetings.

let args = CommandLine.arguments
guard args.count >= 4 else {
    FileHandle.standardError.write(Data("usage: transcript-eval <tq2 root> <out dir> <name>…\n".utf8))
    exit(2)
}
let tq2 = URL(fileURLWithPath: args[1], isDirectory: true)
let out = URL(fileURLWithPath: args[2], isDirectory: true)
guard out.path.contains("/scratchpad/") else {
    FileHandle.standardError.write(Data("refusing to write outside the scratchpad\n".utf8))
    exit(2)
}

// The argument domain sits first in the search list and is never written to disk.
UserDefaults.standard.setVolatileDomain(
    ["speechLanguage": "thai", "separateSpeakers": true, "compressAudio": false], forName: UserDefaults.argumentDomain)
guard Settings.speechLanguage == .thai, Diarizer.isEnabled, !Settings.compressAudio else {
    FileHandle.standardError.write(Data("settings did not take\n".utf8))
    exit(2)
}
guard Diarizer.isAvailable, Tools.whisper() != nil, FileManager.default.fileExists(atPath: Transcriber.model.path) else {
    FileHandle.standardError.write(Data("whisper, the diarizer or a model is missing\n".utf8))
    exit(2)
}

typealias Line = TranscriptCleaner.Line
let fm = FileManager.default

func near(_ a: Line, _ b: Line, tolerance: TimeInterval = 3) -> Bool {
    a.start <= b.end + tolerance && b.start <= a.end + tolerance
}

/// Longest run of characters the two normalised texts share.
func sharedRun(_ a: String, _ b: String) -> Int {
    let x = Array(a.unicodeScalars), y = Array(b.unicodeScalars)
    guard !x.isEmpty, !y.isEmpty else { return 0 }
    var previous = [Int](repeating: 0, count: y.count + 1)
    var best = 0
    for i in 1...x.count {
        var row = [Int](repeating: 0, count: y.count + 1)
        for j in 1...y.count where x[i - 1] == y[j - 1] {
            row[j] = previous[j - 1] + 1
            best = max(best, row[j])
        }
        previous = row
    }
    return best
}

/// Me lines that share a run of six or more characters with an Others line heard within three seconds (the spec's
/// gate definition).
func duplicates(_ me: [Line], _ others: [Line]) -> [Line] {
    let far = others.map { ($0, TranscriptCleaner.normalise($0.text)) }
    return me.filter { line in
        let said = TranscriptCleaner.normalise(line.text)
        return far.contains { other, text in near(line, other) && sharedRun(said, text) >= 6 }
    }
}

func thaiLatin(_ texts: [String]) -> (thai: Double, latin: Double) {
    var thai = 0, latin = 0
    for scalar in texts.flatMap({ $0.unicodeScalars }) {
        if (0x0E00...0x0E7F).contains(scalar.value) { thai += 1 } else if (65...90).contains(scalar.value) || (97...122).contains(scalar.value) { latin += 1 }
    }
    let total = max(1, thai + latin)
    return (Double(thai) / Double(total) * 100, Double(latin) / Double(total) * 100)
}

func pct(_ value: Double) -> String { String(format: "%.1f", value) }

func dictionary(_ line: Line) -> [String: Any] {
    var d: [String: Any] = ["start": line.start, "end": line.end, "text": line.text]
    if let voice = line.voice { d["voice"] = voice }
    if let p = line.p { d["p"] = p }
    return d
}

func writeJSON(_ object: Any, to url: URL) throws {
    try JSONSerialization.data(withJSONObject: object, options: [.prettyPrinted, .sortedKeys]).write(to: url)
}

struct TrackSeen {
    let speaker: String
    let voices: (raw: Int, absorbed: Int)?
    let parsed: [Line]
    let cleaned: TranscriptCleaner.Result
}

var failures = 0
for name in args[3...] {
    let src = tq2.appendingPathComponent("src/\(name)", isDirectory: true)
    let dir = out.appendingPathComponent(name, isDirectory: true)
    let work = dir.appendingPathComponent("work", isDirectory: true)
    try? fm.removeItem(at: dir)
    try! fm.createDirectory(at: work, withIntermediateDirectories: true)
    try! fm.copyItem(at: src.appendingPathComponent("meta.json"), to: work.appendingPathComponent("meta.json"))
    try! fm.copyItem(at: src.appendingPathComponent("transcript.md"), to: dir.appendingPathComponent("transcript-app.md"))
    for track in AudioTracks.names {
        guard let source = AudioTracks.url(track, in: src) else { continue }
        try! AudioTracks.decodeToWAV(source, to: work.appendingPathComponent("\(track).wav"))
    }
    // The decoded tracks are not needed again, whatever happens; transcript.md and meta.json stay in work/.
    func dropWAVs() { for track in AudioTracks.names { try? fm.removeItem(at: work.appendingPathComponent("\(track).wav")) } }
    guard let meta = Workspace.readMeta(work) else { print("\(name): no meta"); failures += 1; dropWAVs(); continue }

    var tracks: [TrackSeen] = []
    var deduped: (me: [Line], dropped: Int, leak: Int)?
    var named: [(start: TimeInterval, speaker: String, text: String)] = []
    Transcriber.observe = { event in
        switch event {
        case let .track(speaker, voices, parsed, cleaned): tracks.append(TrackSeen(speaker: speaker, voices: voices, parsed: parsed, cleaned: cleaned))
        case let .deduped(me, dropped, leak): deduped = (me, dropped, leak)
        case let .named(lines): named = lines
        }
    }
    print("== \(name): \(meta.recordMode.name), \(meta.app ?? "no app"), mic separated: \(Transcriber.separatesMic(mode: meta.recordMode, app: meta.app, bundleID: meta.bundleID))")
    let started = Date()
    var shown = -1
    do {
        _ = try Transcriber.transcribe(folder: work, title: meta.title, startedAt: meta.startedAt, id: nil) { progress in
            let tenth = Int(progress * 10)
            if tenth > shown { shown = tenth; print("   \(tenth * 10) % at \(Int(Date().timeIntervalSince(started))) s") }
        }
    } catch {
        print("\(name): transcribe failed: \(error.localizedDescription)")
        failures += 1
        dropWAVs()
        continue
    }
    let elapsed = Date().timeIntervalSince(started)
    Transcriber.observe = nil
    try! fm.copyItem(at: work.appendingPathComponent("transcript.md"), to: dir.appendingPathComponent("transcript.md"))

    let me = tracks.first { $0.speaker == "Me" }
    let others = tracks.first { $0.speaker == "Others" }
    let meBefore = me?.cleaned.lines ?? []
    let meFinal = deduped?.me ?? meBefore
    let othersFinal = others?.cleaned.lines ?? []
    let dupBefore = duplicates(meBefore, othersFinal).count
    let dupAfter = duplicates(meFinal, othersFinal).count
    var labelCounts: [String: Int] = [:]
    var paragraphs = 0
    var last: String?
    for line in named {
        labelCounts[line.speaker, default: 0] += 1
        if line.speaker != last { paragraphs += 1; last = line.speaker }
    }
    let share = thaiLatin(named.map(\.text))
    let collapsed = tracks.reduce(0) { $0 + $1.cleaned.collapsed }
    let dropped = tracks.reduce(0) { $0 + $1.cleaned.dropped }
    let runs = tracks.reduce(0) { $0 + $1.cleaned.runs }
    let repeats = tracks.reduce(0) { $0 + $1.cleaned.repeats }
    let fragments = tracks.reduce(0) { $0 + $1.cleaned.fragments }
    let fillers = tracks.reduce(0) { $0 + $1.cleaned.fillers }
    let retried = tracks.reduce(0) { $0 + $1.cleaned.retried.count }

    for track in tracks {
        let voices = track.voices.map { "\($0.raw)→\($0.absorbed)" } ?? "one voice"
        print("   \(track.speaker): voices \(voices), lines \(track.parsed.count)→\(track.cleaned.lines.count), collapsed \(track.cleaned.collapsed), dropped \(track.cleaned.dropped), runs \(track.cleaned.runs), repeats \(track.cleaned.repeats), fragments \(track.cleaned.fragments), fillers \(track.cleaned.fillers), retried \(track.cleaned.retried.map { "\(Int($0.from))–\(Int($0.to))" }.joined(separator: " "))")
    }
    let labels = labelCounts.keys.sorted { a, b in
        let na = Int(a.split(separator: " ").last ?? "") ?? -1, nb = Int(b.split(separator: " ").last ?? "") ?? -1
        return na != nb ? na < nb : a < b
    }
    print("   labels \(labelCounts.count): \(labels.map { "\($0) \(labelCounts[$0]!)" }.joined(separator: ", "))")
    print("   Me lines \(meBefore.count)→\(meFinal.count): second-pass lines under far-end speech dropped \(deduped?.leak ?? 0), copies of Others dropped \(deduped?.dropped ?? 0); Me duplicating Others \(dupBefore)→\(dupAfter)")
    print("   paragraphs \(paragraphs), lines \(named.count), Thai \(pct(share.thai)) %, Latin \(pct(share.latin)) %, run time \(Int(elapsed)) s")

    var metrics: [String: Any] = [
        "name": name, "title": meta.title, "mode": meta.recordMode.name, "app": meta.app ?? "",
        "seconds": elapsed, "paragraphs": paragraphs, "lines": named.count, "labels": labelCounts,
        "me_lines_before_dedupe": meBefore.count, "me_lines": meFinal.count, "dedupe_dropped": deduped?.dropped ?? 0,
        "second_pass_leak_dropped": deduped?.leak ?? 0,
        "me_duplicating_others_before_dedupe": dupBefore, "me_duplicating_others": dupAfter,
        "collapsed": collapsed, "dropped": dropped, "runs": runs, "repeats": repeats, "fragments": fragments, "fillers": fillers, "retried": retried,
        "thai_pct": share.thai, "latin_pct": share.latin,
    ]
    metrics["tracks"] = tracks.map { track -> [String: Any] in
        var d: [String: Any] = ["speaker": track.speaker, "parsed": track.parsed.count, "cleaned": track.cleaned.lines.count,
                                "collapsed": track.cleaned.collapsed, "dropped": track.cleaned.dropped, "runs": track.cleaned.runs,
                                "repeats": track.cleaned.repeats, "fragments": track.cleaned.fragments,
                                "fillers": track.cleaned.fillers, "retried": track.cleaned.retried.map { [$0.from, $0.to] }]
        if let voices = track.voices { d["voices_raw"] = voices.raw; d["voices_absorbed"] = voices.absorbed }
        return d
    }
    try! writeJSON(metrics, to: dir.appendingPathComponent("metrics.json"))
    let lines: [String: Any] = [
        "me_parsed": (me?.parsed ?? []).map(dictionary), "me_cleaned": meBefore.map(dictionary), "me_final": meFinal.map(dictionary),
        "others_parsed": (others?.parsed ?? []).map(dictionary), "others_cleaned": othersFinal.map(dictionary),
        "named": named.map { ["start": $0.start, "speaker": $0.speaker, "text": $0.text] },
    ]
    try! writeJSON(lines, to: dir.appendingPathComponent("lines.json"))
    dropWAVs()
}
exit(failures == 0 ? 0 : 1)
