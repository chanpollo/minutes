import AppKit

/// Which apps holding the microphone get the "Record this meeting?" prompt.
enum MeetingApps {
    struct App: Equatable {
        let bundleID: String
        let name: String
    }

    // Browsers are here because Meet and Teams on the web run in them.
    static let known: [String: String] = [
        "com.microsoft.teams2": "Microsoft Teams",
        "com.microsoft.teams": "Microsoft Teams (classic)",
        "us.zoom.xos": "Zoom",
        "com.cisco.webexmeetingsapp": "Webex Meetings",
        "Cisco-Systems.Spark": "Webex",
        "com.tinyspeck.slackmacgap": "Slack",
        "com.hnc.Discord": "Discord",
        "jp.naver.line.mac": "LINE",
        "com.apple.FaceTime": "FaceTime",
        "com.google.Chrome": "Google Chrome",
        "com.microsoft.edgemac": "Microsoft Edge",
        "com.apple.Safari": "Safari",
        "company.thebrowser.Browser": "Arc",
        "org.mozilla.firefox": "Firefox",
        "com.brave.Browser": "Brave",
    ]

    static let seenLimit = 30

    /// The app a process holding the mic belongs to: helpers map to their app by prefix
    /// (com.google.Chrome.helper → com.google.Chrome), WebKit processes to Safari, FaceTime's call daemon to FaceTime.
    /// `regularApps` are bundle IDs of running apps that have a Dock icon.
    static func owner(of bundleID: String, regularApps: [String] = []) -> String {
        let id = bundleID.lowercased()
        if id == "com.apple.webkit" || id.hasPrefix("com.apple.webkit.") { return "com.apple.Safari" }
        if id == "com.apple.avconferenced" { return "com.apple.FaceTime" }
        let match = (regularApps + known.keys)
            .filter { id == $0.lowercased() || id.hasPrefix($0.lowercased() + ".") }
            .max { $0.count < $1.count }
        return match ?? bundleID
    }

    static func allowed(_ bundleID: String, askAnyApp: Bool, off: Set<String>, on: Set<String>) -> Bool {
        if askAnyApp || on.contains(bundleID) { return true }
        if off.contains(bundleID) { return false }
        let app = owner(of: bundleID)
        return on.contains(app) || (known[app] != nil && !off.contains(app))
    }

    /// Adds `apps` as the newest entries and keeps at most `limit`, dropping the oldest.
    static func remembering(
        _ apps: [App], seen: [String: String], order: [String], limit: Int = seenLimit
    ) -> (seen: [String: String], order: [String]) {
        let fresh = Set(apps.map(\.bundleID))
        // Entries without a recorded order count as oldest.
        var order = seen.keys.filter { !order.contains($0) }.sorted() + order.filter { seen[$0] != nil }
        order.removeAll { fresh.contains($0) }
        order += apps.map(\.bundleID)
        var seen = seen
        for app in apps { seen[app.bundleID] = app.name }
        while order.count > limit { seen[order.removeFirst()] = nil }
        return (seen, order)
    }

    /// Installed known apps, apps switched on by hand and apps seen holding the mic.
    static func menuApps(installed: [String], on: Set<String>, seen: [String: String]) -> [App] {
        let ids = Set(installed).union(on).union(seen.keys)
        return ids.map { App(bundleID: $0, name: known[$0] ?? seen[$0] ?? $0) }
            .sorted {
                let order = $0.name.localizedStandardCompare($1.name)
                return order == .orderedSame ? $0.bundleID < $1.bundleID : order == .orderedAscending
            }
    }

    // MARK: Settings

    private static let defaults = UserDefaults.standard

    static var askAnyApp: Bool {
        get { defaults.bool(forKey: "askAnyApp") }
        set { defaults.set(newValue, forKey: "askAnyApp") }
    }

    static var off: Set<String> {
        get { Set(defaults.stringArray(forKey: "meetingAppsOff") ?? []) }
        set { defaults.set(newValue.sorted(), forKey: "meetingAppsOff") }
    }

    static var on: Set<String> {
        get { Set(defaults.stringArray(forKey: "meetingAppsOn") ?? []) }
        set { defaults.set(newValue.sorted(), forKey: "meetingAppsOn") }
    }

    static var seen: [String: String] {
        defaults.dictionary(forKey: "micAppsSeen") as? [String: String] ?? [:]
    }

    static func isAllowed(_ bundleID: String) -> Bool {
        allowed(bundleID, askAnyApp: askAnyApp, off: off, on: on)
    }

    static func toggle(_ bundleID: String) {
        let allowedNow = allowed(bundleID, askAnyApp: false, off: off, on: on)
        on.remove(bundleID)
        off.remove(bundleID)
        // Known apps, and variants of them (com.google.Chrome.canary), stay allowed until listed as off.
        if allowed(bundleID, askAnyApp: false, off: off, on: on) == allowedNow {
            if allowedNow { off.insert(bundleID) } else { on.insert(bundleID) }
        }
    }

    /// Records apps that just took the mic. Returns true when the list changed.
    @discardableResult
    static func remember(_ apps: [App]) -> Bool {
        let before = seen
        let order = defaults.stringArray(forKey: "micAppsSeenOrder") ?? []
        let after = remembering(apps, seen: before, order: order)
        defaults.set(after.seen, forKey: "micAppsSeen")
        defaults.set(after.order, forKey: "micAppsSeenOrder")
        return after.seen != before
    }

    /// Apps removed from the Settings list with "−"; they stay off and out of the list until added again.
    static var hidden: Set<String> {
        get { Set(defaults.stringArray(forKey: "meetingAppsHidden") ?? []) }
        set { defaults.set(newValue.sorted(), forKey: "meetingAppsHidden") }
    }

    /// Whether the app gets the prompt by its own setting, ignoring "Any App".
    static func isOn(_ bundleID: String) -> Bool {
        allowed(bundleID, askAnyApp: false, off: off, on: on)
    }

    /// The Settings list: installed known apps, apps switched on and apps seen holding the mic, minus removed ones.
    static func listed() -> [App] {
        let installed = known.keys.filter { NSWorkspace.shared.urlForApplication(withBundleIdentifier: $0) != nil }
        return listing(installed: installed, on: on, seen: seen, hidden: hidden)
    }

    static func listing(installed: [String], on: Set<String>, seen: [String: String], hidden: Set<String>) -> [App] {
        menuApps(installed: installed, on: on, seen: seen).filter { !hidden.contains($0.bundleID) }
    }

    /// What "+" offers: running apps with a Dock icon and apps seen or removed earlier, not already listed.
    static func addable(running: [App], listed: [App]) -> [App] {
        let shown = Set(listed.map(\.bundleID))
        var picked: [String: App] = [:]
        for app in running + seen.map({ App(bundleID: $0.key, name: $0.value) })
            + hidden.map({ App(bundleID: $0, name: known[$0] ?? seen[$0] ?? $0) })
        where !shown.contains(app.bundleID) && picked[app.bundleID] == nil {
            picked[app.bundleID] = app
        }
        return picked.values.sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
    }

    static func add(_ app: App) {
        hidden.remove(app.bundleID)
        if known[app.bundleID] == nil { remember([app]) }
        if !isOn(app.bundleID) { toggle(app.bundleID) }
    }

    static func remove(_ bundleID: String) {
        if isOn(bundleID) { toggle(bundleID) }
        hidden.insert(bundleID)
        Settings.alwaysRecord.removeAll { $0 == bundleID }
    }
}
