import Foundation

/// docs/CHANGELOG.md, copied into the app by build.sh: `## 0.6.1 (10) — 2026-10-30` headings, newest first, with plain
/// bullets under each.
enum Changelog {
    struct Release: Equatable {
        var version: String
        var build: Int?
        /// As written in the heading, normally yyyy-MM-dd.
        var date: String?
        var items: [String] = []

        /// "30 Oct 2026"; a date in another form stays as written.
        var dateText: String? { date.map(Changelog.dateText) }
    }

    static func load(bundle: Bundle = .main) -> [Release] {
        guard let url = bundle.url(forResource: "CHANGELOG", withExtension: "md"),
              let text = try? String(contentsOf: url, encoding: .utf8)
        else { return [] }
        return parse(text)
    }

    /// Tolerant: a heading without a build number or date still lists, and a line under a bullet that is not one
    /// continues that bullet. Text before the first heading is ignored.
    static func parse(_ text: String) -> [Release] {
        var releases: [Release] = []
        for raw in text.components(separatedBy: .newlines) {
            let line = raw.trimmingCharacters(in: .whitespaces)
            if line.hasPrefix("## ") {
                releases.append(heading(line.dropFirst(3)))
            } else if releases.isEmpty || line.isEmpty || line.hasPrefix("#") {
                continue
            } else if line.hasPrefix("- ") || line.hasPrefix("* ") {
                releases[releases.count - 1].items.append(line.dropFirst(2).trimmingCharacters(in: .whitespaces))
            } else if let last = releases[releases.count - 1].items.indices.last {
                releases[releases.count - 1].items[last] += " " + line
            }
        }
        return releases
    }

    /// "0.6.1 (10) — 2026-10-30", "0.6.1 (build 10) - 2026-10-30" or just "0.6.1".
    static func heading(_ text: Substring) -> Release {
        var rest = text
        var date: String?
        if let dash = rest.range(of: #"\s+[—–-]+\s+"#, options: .regularExpression) {
            date = rest[dash.upperBound...].trimmingCharacters(in: .whitespaces)
            rest = rest[..<dash.lowerBound]
        }
        var build: Int?
        if let tail = rest.range(of: #"\s*\((?:build\s+)?\d+\)\s*$"#, options: .regularExpression) {
            build = Int(rest[tail].filter(\.isNumber))
            rest = rest[..<tail.lowerBound]
        }
        return Release(version: rest.trimmingCharacters(in: .whitespaces), build: build, date: date)
    }

    static func dateText(_ written: String) -> String {
        let read = DateFormatter()
        read.locale = Locale(identifier: "en_US_POSIX")
        read.dateFormat = "yyyy-MM-dd"
        guard let date = read.date(from: written) else { return written }
        let show = DateFormatter()
        show.locale = Locale(identifier: "en_US_POSIX")
        show.dateFormat = "d MMM yyyy"
        return show.string(from: date)
    }
}
