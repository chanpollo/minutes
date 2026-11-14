import Foundation

/// Repairs what whisper gets wrong on quiet or noisy stretches: a phrase looped inside a line, the same line emitted
/// over and over, a stock phrase invented over silence, and the owner's microphone copying the far end. Pure
/// functions over parsed lines; the second whisper pass over a looping stretch comes in through `rerun`.
enum TranscriptCleaner {
    /// A line as parseJSON builds it: token times, the voice heard (when told apart) and the tokens' mean probability.
    struct Line: Equatable {
        var start: TimeInterval
        var end: TimeInterval
        var text: String
        var voice: Int?
        var p: Double?
    }

    struct Result {
        var lines: [Line]
        /// Lines with a phrase looped inside, cut to one occurrence.
        var collapsed = 0
        /// Lines that were nothing but the looped phrase, at a probability below `fillerProbability`.
        var dropped = 0
        /// Runs of identical lines cut to one.
        var runs = 0
        /// Copies of a line said again within `recurrenceWindow`, or a long line said again anywhere, cut away.
        var repeats = 0
        /// Lines that were only a piece of a looped phrase.
        var fragments = 0
        var fillers = 0
        /// Stretches re-run with `-mc 0`, as (from, to) seconds.
        var retried: [(from: TimeInterval, to: TimeInterval)] = []
    }

    /// Measured on four meetings (M1, 30 Oct 2026): looped lines sit at p 0.72–0.999, median 0.90, above real speech,
    /// so no probability separates them; repetition alone decides. The threshold stays for the stock phrases, where
    /// every real "ขอบคุณค่ะ" measured was at p ≥ 0.85.
    static let fillerProbability = 0.5

    /// What whisper writes over silence or noise. With --suppress-nst none appeared in 3,177 measured lines; kept as
    /// the safety net it was meant to be.
    static let fillers = ["Thank you.", "Thanks for watching.", "ขอบคุณครับ", "ขอบคุณค่ะ", "ติดตามชมตอนต่อไป"]
    static let fillerPrefixes = ["บรรยายโดย", "Subtitles by"]

    /// The same line said again this close is whisper carrying its context, not the speaker (teams1432: one invented
    /// sentence 49 times over 75 minutes, in clusters a few minutes long).
    static let recurrenceWindow: TimeInterval = 120
    /// A line this long (in characters, spaces and punctuation removed) said three times anywhere in a track is
    /// whisper's: nobody repeats a sentence word for word.
    static let longPhrase = 10
    /// A line this short is a backchannel, never a fragment of a looped phrase.
    static let fragmentFloor = 4
    /// Repaired lines this close together are one looping stretch for the second pass.
    static let stretchGap: TimeInterval = 10

    /// A phrase of two or more words said three or more times in a row.
    private static let wordLoop = try! NSRegularExpression(pattern: #"(?<!\S)(\S+(?:\s+\S+)+?)(?:\s+\1){2,}(?!\S)"#)
    /// Six or more characters repeated, run together or spaced: Thai has no spaces between words.
    private static let characterLoop = try! NSRegularExpression(pattern: #"(\S{6,}?)(?:\s*\1){2,}"#)
    /// One word six or more times in a row ("บน" ×31); three to five is often real ("ใช่ ใช่ ใช่").
    private static let tokenLoop = try! NSRegularExpression(pattern: #"(?<!\S)(\S+)(?:\s+\1){5,}(?!\S)"#)
    /// The same line this many times in a row is a loop whatever its length ("ที่..." ×44).
    static let longRun = 6

    // MARK: Loops and fillers

    struct Collapsed {
        var text: String
        var phrase: String?
        /// The line was nothing but the phrase and fragments of it.
        var onlyPhrase: Bool
        var looped: Bool { phrase != nil }
    }

    /// Every phrase looped three times or more cut to one occurrence; the first phrase found and whether anything
    /// else was said in the line.
    static func collapse(_ text: String) -> Collapsed {
        var phrase: String?
        var out = text
        let whole = NSRange(out.startIndex..., in: out)
        if let match = wordLoop.firstMatch(in: out, range: whole), let range = Range(match.range(at: 1), in: out) {
            phrase = String(out[range])
            out = wordLoop.stringByReplacingMatches(in: out, range: whole, withTemplate: "$1")
        }
        let words = NSRange(out.startIndex..., in: out)
        if let match = tokenLoop.firstMatch(in: out, range: words), let range = Range(match.range(at: 1), in: out) {
            phrase = phrase ?? String(out[range])
            out = tokenLoop.stringByReplacingMatches(in: out, range: words, withTemplate: "$1")
        }
        // Back to front so the ranges stay valid while replacing.
        let matches = characterLoop.matches(in: out, range: NSRange(out.startIndex..., in: out))
        for match in matches.reversed() {
            guard let all = Range(match.range, in: out), let unit = Range(match.range(at: 1), in: out) else { continue }
            guard isThai(String(out[unit])) else { continue }
            // Six characters of "การ" are two of them: cut to the word, and the odd one the match left behind with it.
            let repeated = period(String(out[unit]))
            var end = all.upperBound
            while out[end...].hasPrefix(repeated) { end = out.index(end, offsetBy: repeated.count) }
            out.replaceSubrange(all.lowerBound..<end, with: repeated)
            phrase = repeated
        }
        if matches.isEmpty, phrase == nil { return Collapsed(text: text, phrase: nil, onlyPhrase: false) }
        guard let phrase else { return Collapsed(text: out, phrase: nil, onlyPhrase: false) }
        let said = normalise(out), unit = normalise(phrase)
        let only = said.isEmpty || (unit + unit + unit).contains(said)
        return Collapsed(text: out, phrase: phrase, onlyPhrase: only)
    }

    /// The shortest string `text` is a repetition of; `text` itself when there is none.
    private static func period(_ text: String) -> String {
        let chars = Array(text)
        for d in 1..<max(1, chars.count) where chars.count % d == 0 {
            let unit = chars[..<d]
            if stride(from: d, to: chars.count, by: d).allSatisfy({ chars[$0..<($0 + d)].elementsEqual(unit) }) { return String(unit) }
        }
        return text
    }

    static func isFiller(_ text: String) -> Bool {
        let said = normalise(collapse(text).text)
        guard !said.isEmpty else { return false }
        return fillers.contains { normalise($0) == said } || fillerPrefixes.contains { said.hasPrefix(normalise($0)) }
    }

    /// Lower case without spaces and punctuation, for comparing what was said.
    static func normalise(_ text: String) -> String {
        String(text.lowercased().unicodeScalars.filter {
            !CharacterSet.whitespacesAndNewlines.contains($0) && !CharacterSet.punctuationCharacters.contains($0)
        })
    }

    private static func isThai(_ text: String) -> Bool {
        text.unicodeScalars.contains { (0x0E00...0x0E7F).contains($0.value) }
    }

    /// Long enough for a repeat to be a loop rather than "ใช่ ใช่ ใช่": two words or six characters.
    static func aboveFloor(_ text: String) -> Bool {
        text.split(whereSeparator: \.isWhitespace).count >= 2 || normalise(text).count >= 6
    }

    // MARK: Lines

    private struct Marked {
        let original: Line
        var line: Line?
        var bad: Bool
        /// The looped phrase this line was cut to, when it is the occurrence that stays.
        var anchorKey: String?
    }

    /// A looped phrase and the stretch of the track it was heard looping in.
    private struct Anchor {
        let key: String
        let from: TimeInterval
        let to: TimeInterval
        /// A phrase known before this pass: a line saying it again is whisper's, exact copies included.
        var exact = false
        var long: Bool { key.count >= longPhrase }
        func covers(_ line: Line) -> Bool { from <= line.start && line.start <= to }
    }

    /// Loops collapsed, repeats and fillers dropped, and with `rerun` (whisper over `from`…`to` seconds of the same
    /// track with `-mc 0`, lines in track time) each looping stretch decoded again, once.
    static func clean(_ lines: [Line], rerun: ((TimeInterval, TimeInterval) throws -> [Line])? = nil) -> Result {
        clean(lines, rerun: rerun, known: [])
    }

    /// `known` are the looped phrases of the whole track, applied to a stretch decoded again.
    private static func clean(_ lines: [Line], rerun: ((TimeInterval, TimeInterval) throws -> [Line])?, known: [String]) -> Result {
        var result = Result(lines: [])
        var marked: [Marked] = lines.map { Marked(original: $0, line: $0, bad: false) }
        var anchors = known.map { Anchor(key: $0, from: -.infinity, to: .infinity, exact: true) }
        let window = { (first: Line, last: Line) in (first.start - recurrenceWindow, last.end + recurrenceWindow) }

        for i in marked.indices {
            let line = marked[i].original
            let cut = collapse(line.text)
            if cut.looped {
                result.collapsed += 1
                marked[i].bad = true
                if cut.onlyPhrase, (line.p ?? 1) < fillerProbability {
                    result.dropped += 1
                    marked[i].line = nil
                } else {
                    marked[i].line?.text = cut.text
                }
                let span = window(line, line)
                marked[i].anchorKey = normalise(cut.phrase!)
                anchors.append(Anchor(key: normalise(cut.phrase!), from: span.0, to: span.1))
            } else if isFiller(line.text), (line.p ?? 1) < fillerProbability {
                result.fillers += 1
                marked[i].bad = true
                marked[i].line = nil
            }
        }

        // The same line three or more times in a row: whisper breaks a looping sentence into one line per repeat.
        // Lines already found looping need no floor; they are not "ใช่ ใช่ ใช่".
        var i = 0
        while i < marked.count {
            guard let first = marked[i].line else { i += 1; continue }
            let key = normalise(first.text)
            var j = i
            while j + 1 < marked.count, let next = marked[j + 1].line, normalise(next.text) == key,
                  next.start - marked[j].original.end <= recurrenceWindow { j += 1 }
            if j - i >= 2, !key.isEmpty, aboveFloor(first.text) || marked[i...j].allSatisfy(\.bad) || j - i + 1 >= longRun {
                result.runs += 1
                for k in i...j {
                    marked[k].bad = true
                    if k > i { marked[k].line = nil }
                }
                let span = window(first, marked[j].original)
                marked[i].anchorKey = key
                anchors.append(Anchor(key: key, from: span.0, to: span.1))
            }
            i = j + 1
        }

        // The same line again with other lines between: a long one three times anywhere in the track, a shorter one
        // three times within the window. The first stays, as in a run.
        var groups: [String: [Int]] = [:]
        for (k, mark) in marked.enumerated() {
            guard let line = mark.line, aboveFloor(line.text) else { continue }
            let key = normalise(line.text)
            if !key.isEmpty { groups[key, default: []].append(k) }
        }
        for (key, indices) in groups.sorted(by: { $0.value[0] < $1.value[0] }) {
            var chains: [[Int]] = []
            if key.count >= longPhrase, indices.count >= 3 {
                chains = [indices]
            } else {
                var chain = [indices[0]]
                for k in indices.dropFirst() {
                    if marked[k].original.start - marked[chain.last!].original.end <= recurrenceWindow {
                        chain.append(k)
                    } else {
                        chains.append(chain)
                        chain = [k]
                    }
                }
                chains.append(chain)
                chains = chains.filter { $0.count >= 3 }
            }
            for chain in chains {
                for k in chain {
                    marked[k].bad = true
                    if k != chain[0] { marked[k].line = nil; result.repeats += 1 }
                }
                marked[chain[0]].anchorKey = key
                let span = key.count >= longPhrase
                    ? (-TimeInterval.infinity, TimeInterval.infinity)
                    : window(marked[chain[0]].original, marked[chain.last!].original)
                anchors.append(Anchor(key: key, from: span.0, to: span.1))
            }
        }

        // What is left of a looped sentence around its loops: a piece of it, or the sentence with noise around it.
        // The one occurrence a loop or run was cut to stays.
        let long = anchors.filter(\.long)
        if !long.isEmpty {
            for k in marked.indices {
                guard let line = marked[k].line else { continue }
                let said = normalise(line.text), own = marked[k].anchorKey
                guard said.count >= fragmentFloor else { continue }
                let piece = long.contains { anchor in
                    guard anchor.covers(line), anchor.key != own else { return false }
                    if said == anchor.key { return anchor.exact }
                    return anchor.key.contains(said) || (own == nil && said.contains(anchor.key))
                }
                if piece {
                    result.fragments += 1
                    marked[k].bad = true
                    marked[k].line = nil
                }
            }
        }

        // Three or more repaired lines close together are decoded again without context carried over.
        if let rerun {
            var spans: [Range<Int>] = []
            var k = 0
            while k < marked.count {
                guard marked[k].bad else { k += 1; continue }
                var end = k, count = 1
                var next = end + 1
                while next < marked.count {
                    if marked[next].bad {
                        guard marked[next].original.start - marked[end].original.end <= stretchGap else { break }
                        end = next
                        count += 1
                    }
                    next += 1
                }
                if count >= 3 { spans.append(k..<(end + 1)) }
                k = end + 1
            }
            let phrases = long.map(\.key)
            for span in spans.reversed() {
                let from = max(0, marked[span.lowerBound].original.start - 5)
                let to = marked[span.upperBound - 1].original.end + 5
                let again: [Line]
                do {
                    again = try rerun(from, to)
                } catch {
                    NSLog("Minutes: second pass over %.0f–%.0f s skipped: %@", from, to, error.localizedDescription)
                    continue
                }
                result.retried.insert((from, to), at: 0)
                let before = marked[..<span.lowerBound].last { $0.line != nil }?.original.end ?? 0
                let after = marked[span.upperBound...].first { $0.line != nil }?.original.start ?? .infinity
                let fresh = clean(again, rerun: nil, known: phrases).lines.filter { $0.start >= before - 0.5 && $0.start < after - 0.5 }
                marked.replaceSubrange(span, with: fresh.map { Marked(original: $0, line: $0, bad: false) })
            }
        }

        result.lines = marked.compactMap(\.line)
        return result
    }

    // MARK: Me copying Others

    /// With the call measured in the mic (AudioTracks.leak), a stretch of the mic that whisper looped on is the owner
    /// listening: what the second pass hears there while the call side speaks is the call side through the speaker,
    /// whatever the words (teams1432: 210 of the 225 lines the second pass wrote on the mic sat under far-end speech).
    /// A line heard while the call side is quiet stays.
    static func dropLeak(
        me: [Line], others: [Line], retried: [(from: TimeInterval, to: TimeInterval)], tolerance: TimeInterval = 3
    ) -> (kept: [Line], dropped: Int) {
        guard !retried.isEmpty, !others.isEmpty else { return (me, 0) }
        var dropped = 0
        let kept = me.filter { line in
            guard retried.contains(where: { $0.from <= line.start && line.start <= $0.to }) else { return true }
            let leak = others.contains { line.start <= $0.end + tolerance && $0.start <= line.end + tolerance }
            if leak { dropped += 1 }
            return !leak
        }
        return (kept, dropped)
    }

    /// Share of a Me line's character trigrams that, once said on the call within the tolerance, mark it as the
    /// call's words: the far end through the speaker, or a room that is also on the call (hybrid 11-02: 47 of 103 Me
    /// lines). In 15 calls without either, 2 of about 730 owner lines reached it.
    static let copyShare = 0.6

    /// A Me line shorter than this (characters, spaces and punctuation removed) is a backchannel; common words make
    /// it look like any call line ("โอเค ขอบคุณครับ").
    static let copyMinimum = 8

    /// Drops a Me line whose words one Others line within three seconds said. Lines are compared one to one: pooled,
    /// the common words of several call lines covered the owner's own short answers. The owner talking over the call
    /// keeps most of the line's own words, so it stays.
    static func dedupe(me: [Line], others: [Line], tolerance: TimeInterval = 3) -> (kept: [Line], dropped: Int) {
        let far = others.map { (line: $0, grams: trigrams(normalise($0.text))) }.filter { !$0.grams.isEmpty }
        var dropped = 0
        let kept = me.filter { line in
            let said = normalise(line.text)
            guard said.count >= copyMinimum else { return true }
            let grams = trigrams(said)
            let copies = far.contains { other in
                guard line.start <= other.line.end + tolerance, other.line.start <= line.end + tolerance else { return false }
                return Double(grams.intersection(other.grams).count) >= copyShare * Double(grams.count)
            }
            if copies { dropped += 1 }
            return !copies
        }
        return (kept, dropped)
    }

    static func trigrams(_ text: String) -> Set<String> {
        let chars = Array(text)
        guard chars.count >= 3 else { return chars.isEmpty ? [] : [text] }
        return Set((0...(chars.count - 3)).map { String(chars[$0..<($0 + 3)]) })
    }
}
