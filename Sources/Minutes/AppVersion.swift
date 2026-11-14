import AppKit

/// What build.sh stamped into the app's Info.plist. A binary run outside a built app reads as 0.0.0 (0).
struct AppVersion {
    var version: String
    var build: Int
    var builtAt: Date?
    /// Short SHA, with "+" when the tree had uncommitted changes.
    var commit: String?
    /// When the app bundle was last written, which is when it was installed.
    var installedAt: Date?

    static let current = AppVersion(bundle: .main)

    init(version: String, build: Int, builtAt: Date? = nil, commit: String? = nil, installedAt: Date? = nil) {
        self.version = version
        self.build = build
        self.builtAt = builtAt
        self.commit = commit
        self.installedAt = installedAt
    }

    init(bundle: Bundle) {
        let installed = try? bundle.bundleURL.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate
        self.init(info: bundle.infoDictionary ?? [:], installedAt: installed)
    }

    init(info: [String: Any], installedAt: Date?) {
        version = info["CFBundleShortVersionString"] as? String ?? "0.0.0"
        build = (info["CFBundleVersion"] as? String).flatMap { Int($0) } ?? 0
        builtAt = (info["MinutesBuildDate"] as? String).flatMap(Self.date)
        commit = info["MinutesCommit"] as? String
        self.installedAt = installedAt
    }

    var uncommitted: Bool { commit?.hasSuffix("+") == true }
    var commitLabel: String? { commit.map { $0.hasSuffix("+") ? String($0.dropLast()) : $0 } }

    /// "Minutes 0.6.1 (10)"
    var line: String { "Minutes \(version) (\(build))" }

    /// "Minutes 0.6.1 (10) · built 30 Oct 2026 02:10 · 154cce9+ · macOS 26.1", for a bug report.
    var report: String {
        var parts = [line]
        if let builtAt { parts.append("built " + Self.dateTime(builtAt)) }
        if let commit { parts.append(commit) }
        parts.append("macOS " + Self.macOS)
        return parts.joined(separator: " · ")
    }

    static var macOS: String {
        let v = ProcessInfo.processInfo.operatingSystemVersion
        return v.patchVersion == 0 ? "\(v.majorVersion).\(v.minorVersion)" : "\(v.majorVersion).\(v.minorVersion).\(v.patchVersion)"
    }

    /// "30 Oct 2026 02:10"
    static func dateTime(_ date: Date) -> String {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = "d MMM yyyy HH:mm"
        return f.string(from: date)
    }

    /// ISO 8601 as `date` writes it, with or without the colon in the offset.
    static func date(_ text: String) -> Date? {
        let f = ISO8601DateFormatter()
        if let date = f.date(from: text) { return date }
        f.formatOptions = [.withInternetDateTime]
        f.formatOptions.remove(.withColonSeparatorInTimeZone)
        return f.date(from: text)
    }
}
