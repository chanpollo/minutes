import Foundation

/// Decides from each mic poll when to offer recording a call and when a recorded call has ended. It opens nothing
/// itself, so made-up polls can drive it.
struct MeetingDetector {
    enum Action: Equatable {
        case closePrompt
        case ask(app: String, bundleID: String?)
        case recordWithoutAsking(app: String, bundleID: String)
        case closeStopPrompt
        case askToStop(remaining: TimeInterval)
        /// The recorded app took the mic back after the stop card was up: the next call, or the same one after a mute?
        case askSameCall(app: String)
        case stop
    }

    struct Recorded {
        var app: String?
        var autoStop: Bool
    }

    // The mic must stay open this many 2-second polls before asking, so a quick voice memo does not trigger it.
    var pollsBeforePrompt = 2
    // Some apps release the mic while muted; wait this long before treating the call as over.
    var autoStopAfter: TimeInterval = 30
    var askStopAfter: TimeInterval = 3
    /// A call that keeps the mic this long after Not now, with no calendar meeting to mark a new call, is asked about again.
    var declineFor: TimeInterval = 15 * 60
    /// The calendar is read at most this often while something is declined.
    var calendarEvery: TimeInterval = 30
    var keepRecording = false

    /// Not now, an unanswered card or a discarded recording, by app name: not offered again until the app releases
    /// the mic, a calendar meeting for it starts, or `declineFor` passes.
    private(set) var declined: [String: Date] = [:]
    /// Declined or stopped by hand while still holding the mic: offered with the card, never recorded without asking,
    /// until the mic is released or a calendar meeting for it starts.
    private(set) var askOnly: [String: Date] = [:]
    private(set) var bundles: [String: String] = [:]
    private var micPolls: [String: Int] = [:]
    private var micFreeSince: Date?
    /// For Keep Recording: whether the recorded app was seen playing sound, and since when it has not.
    private var outputSeen = false
    private var outputFreeSince: Date?
    private var calendarReadAt: Date?

    /// `prompted` is the app whose Record card is up. `meetingStarted(bundleID, since)` says whether a calendar meeting
    /// for that app began after `since`.
    mutating func poll(
        _ candidates: [MicUser], now: Date, recording: Recorded?, prompted: String?, stopPromptShown: Bool,
        isAllowed: (String) -> Bool, alwaysRecord: (String) -> Bool, meetingStarted: (String?, Date) -> Bool,
        outputApps: Set<String> = []
    ) -> [Action] {
        let apps = Set(candidates.map(\.appName))
        bundles = Dictionary(candidates.map { ($0.appName, $0.ownerBundleID) }, uniquingKeysWith: { first, _ in first })
        forget(apps: apps, now: now, meetingStarted: meetingStarted)
        micPolls = Dictionary(uniqueKeysWithValues: apps.map { ($0, (micPolls[$0] ?? 0) + 1) })

        if let recording {
            guard recording.autoStop else { return [] }
            let playing = recording.app.map(outputApps.contains) ?? false
            if playing { outputSeen = true; outputFreeSince = nil }
            // Only the recorded app counts: another app holding the mic must not keep a finished call recording.
            let callHasMic = recording.app.map(apps.contains) ?? !apps.isEmpty
            if callHasMic {
                // Back while the stop card is up: the next call joined straight after, or a long mute.
                let back = stopPromptShown && !keepRecording
                micFreeSince = nil
                outputFreeSince = nil
                keepRecording = false
                guard stopPromptShown else { return [] }
                return [.closeStopPrompt] + (back ? recording.app.map { [.askSameCall(app: $0)] } ?? [] : [])
            }
            if keepRecording {
                // A call muted with Keep Recording that then ends still stops, once its sound has stopped too. Only
                // for an app seen playing sound, so one whose sound is not reported keeps recording as asked.
                guard outputSeen, !playing else { return [] }
                guard let since = outputFreeSince else {
                    outputFreeSince = now
                    return []
                }
                return now.timeIntervalSince(since) >= autoStopAfter ? [.stop] : []
            }
            guard let since = micFreeSince else {
                micFreeSince = now
                return []
            }
            let free = now.timeIntervalSince(since)
            if free >= autoStopAfter { return [.stop] }
            if !stopPromptShown && free >= askStopAfter { return [.askToStop(remaining: autoStopAfter - free)] }
            return []
        }

        var actions: [Action] = []
        var prompted = prompted
        if let app = prompted, !apps.contains(app) {
            actions.append(.closePrompt)
            prompted = nil
        }
        let askable = Set(candidates.filter { isAllowed($0.ownerBundleID) }.map(\.appName))
        guard prompted == nil,
              let app = askable.sorted().first(where: { micPolls[$0, default: 0] >= pollsBeforePrompt && declined[$0] == nil })
        else { return actions }
        if let bundleID = bundles[app], askOnly[app] == nil, alwaysRecord(bundleID) {
            actions.append(.recordWithoutAsking(app: app, bundleID: bundleID))
        } else {
            actions.append(.ask(app: app, bundleID: bundles[app]))
        }
        return actions
    }

    /// The same call can hold the mic straight into the next one, so a release is not the only way a decline ends.
    private mutating func forget(apps: Set<String>, now: Date, meetingStarted: (String?, Date) -> Bool) {
        declined = declined.filter { apps.contains($0.key) && now.timeIntervalSince($0.value) < declineFor }
        askOnly = askOnly.filter { apps.contains($0.key) }
        guard !declined.isEmpty || !askOnly.isEmpty,
              calendarReadAt.map({ now.timeIntervalSince($0) >= calendarEvery }) ?? true
        else { return }
        calendarReadAt = now
        for app in Set(declined.keys).union(askOnly.keys) {
            if let since = declined[app], meetingStarted(bundles[app], since) { declined[app] = nil }
            if let since = askOnly[app], meetingStarted(bundles[app], since) { askOnly[app] = nil }
        }
    }

    /// Not now, a card left unanswered, or a discarded recording.
    mutating func decline(_ app: String, at now: Date) {
        declined[app] = now
        askOnly[app] = now
    }

    /// Stopping is not declining: the card is offered again while the app holds the mic, since the next meeting can
    /// follow on the same call, but it never starts recording by itself.
    mutating func stoppedByHand(_ app: String?, at now: Date) {
        guard let app else { return }
        declined[app] = nil
        askOnly[app] = now
    }

    mutating func recordingStarted() {
        micFreeSince = nil
        keepRecording = false
        outputSeen = false
        outputFreeSince = nil
    }
}
