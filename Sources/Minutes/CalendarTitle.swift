import EventKit
import Foundation

/// A calendar event reduced to what choosing the meeting needs.
struct CalendarEvent {
    var title: String
    var start: Date
    var end: Date
    var isAllDay = false
    var isCancelled = false
    var declinedByMe = false
    /// URL, location and notes, searched for a call link.
    var text = ""
    var attendees: [String] = []
    /// An invitee's email is on another domain than the user's.
    var hasExternal = false
}

struct CalendarParticipant {
    var name: String?
    var email: String?
    var isMe = false
    var isPerson = true
}

/// Names a meeting after the calendar event that is on now.
enum CalendarTitle {
    static let lookBack: TimeInterval = 4 * 3600
    static let lookAhead: TimeInterval = 15 * 60

    // Teams web and Meet both run in browsers; only Meet is taken as the browser's own link.
    private static let appHosts: [(bundleIDs: [String], hosts: [String])] = [
        (["com.microsoft.teams2", "com.microsoft.teams"], ["teams.microsoft.com", "teams.live.com"]),
        (["us.zoom.xos"], ["zoom.us"]),
        (["com.cisco.webexmeetingsapp", "Cisco-Systems.Spark"], ["webex.com"]),
        ([
            "com.google.Chrome", "com.microsoft.edgemac", "com.apple.Safari", "com.apple.WebKit",
            "company.thebrowser.Browser", "org.mozilla.firefox", "com.brave.Browser",
        ], ["meet.google.com"]),
    ]
    private static let callHosts = ["teams.microsoft.com", "teams.live.com", "zoom.us", "meet.google.com", "webex.com"]

    // Made on first read, which happens only with access: a store made before the grant can keep returning nothing.
    private static let store = EKEventStore()

    static var status: EKAuthorizationStatus { EKEventStore.authorizationStatus(for: .event) }
    static var hasAccess: Bool { status == .fullAccess }

    static func requestAccess(_ done: @escaping (Bool) -> Void = { _ in }) {
        let asker = EKEventStore()
        asker.requestFullAccessToEvents { granted, _ in
            withExtendedLifetime(asker) { done(granted) }
        }
    }

    static func current(appBundleID: String?, voice: Bool = false, now: Date = Date()) -> CalendarEvent? {
        on(appBundleID: appBundleID, voice: voice, at: now).first
    }

    /// Every event on at `date`, the one `current` takes first. Two meetings booked over each other both show here.
    static func on(appBundleID: String?, voice: Bool = false, at date: Date) -> [CalendarEvent] {
        guard hasAccess else { return [] }
        let predicate = store.predicateForEvents(
            withStart: date.addingTimeInterval(-lookBack), end: date.addingTimeInterval(lookAhead), calendars: nil)
        return ranked(store.events(matching: predicate).map(event), now: date, appBundleID: appBundleID, voice: voice)
    }

    static func hasCallLink(_ event: CalendarEvent) -> Bool {
        let text = event.text.lowercased()
        return callHosts.contains { text.contains($0) }
    }

    /// The event the user is most likely in: one with the app's call link, then any call link, then the start closest to now.
    /// `voice` (a Voice recording of no app) puts events without a call link first.
    static func pick(_ events: [CalendarEvent], now: Date, appBundleID: String?, voice: Bool = false) -> CalendarEvent? {
        ranked(events, now: now, appBundleID: appBundleID, voice: voice).first
    }

    /// The events `pick` chooses from, best first; repeats of one event (the same title and times) appear once.
    static func ranked(_ events: [CalendarEvent], now: Date, appBundleID: String?, voice: Bool = false) -> [CalendarEvent] {
        let own = hosts(for: appBundleID)
        let candidates = events.filter {
            !$0.isAllDay && !$0.isCancelled && !$0.declinedByMe
                && !$0.title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                && $0.start <= now.addingTimeInterval(lookAhead) && $0.end > now
        }
        func rank(_ event: CalendarEvent) -> (Int, TimeInterval) {
            let text = event.text.lowercased()
            if voice { return (hasCallLink(event) ? 1 : 0, abs(event.start.timeIntervalSince(now))) }
            let tier = own.contains { text.contains($0) } ? 0 : callHosts.contains { text.contains($0) } ? 1 : 2
            return (tier, abs(event.start.timeIntervalSince(now)))
        }
        var seen = Set<String>()
        return candidates.enumerated()
            .sorted {
                let a = rank($0.element), b = rank($1.element)
                return (a.0, a.1, $0.offset) < (b.0, b.1, $1.offset)
            }
            .map(\.element)
            .filter { seen.insert("\($0.title)\u{1}\($0.start.timeIntervalSince1970)\u{1}\($0.end.timeIntervalSince1970)").inserted }
    }

    /// Whether a meeting for the app began after `since`, for a call that holds the mic from one meeting into the next.
    static func meetingStarted(appBundleID: String?, since: Date, now: Date = Date()) -> Bool {
        guard hasAccess, since < now else { return false }
        let predicate = store.predicateForEvents(withStart: since, end: now, calendars: nil)
        return started(store.events(matching: predicate).map(event), since: since, now: now, appBundleID: appBundleID)
    }

    /// An event with the app's call link (any call link for an app without one of its own) whose start is in
    /// (since, now]. Not `pick`: that moves to the next event up to `lookAhead` before it starts.
    static func started(_ events: [CalendarEvent], since: Date, now: Date, appBundleID: String?) -> Bool {
        let own = hosts(for: appBundleID)
        let links = own.isEmpty ? callHosts : own
        return events.contains { event in
            let text = event.text.lowercased()
            return !event.isAllDay && !event.isCancelled && !event.declinedByMe
                && event.start > since && event.start <= now && links.contains { text.contains($0) }
        }
    }

    /// Display names, organiser first, without the user, rooms and repeats.
    static func names(organizer: CalendarParticipant?, attendees: [CalendarParticipant]) -> [String] {
        var seen = Set<String>()
        var names: [String] = []
        for person in [organizer].compactMap({ $0 }) + attendees where !person.isMe && person.isPerson {
            let name = [person.name, person.email]
                .compactMap { $0?.trimmingCharacters(in: .whitespacesAndNewlines) }
                .first { !$0.isEmpty }
            guard let name else { continue }
            let keys = [name, person.email].compactMap { $0?.lowercased() }
            guard seen.isDisjoint(with: keys) else { continue }
            seen.formUnion(keys)
            names.append(name)
        }
        return names
    }

    /// True when a person invited has an email on another domain than the user's own. Names without an email, rooms
    /// and an unknown user email never count.
    static func hasExternal(organizer: CalendarParticipant?, attendees: [CalendarParticipant]) -> Bool {
        let people = [organizer].compactMap { $0 } + attendees
        guard let mine = people.first(where: \.isMe).flatMap({ domain($0.email) }) else { return false }
        return people.contains { person in
            guard !person.isMe, person.isPerson, let theirs = domain(person.email) else { return false }
            // A subdomain (th.example.com) belongs to the same organisation as example.com.
            return !(theirs == mine || theirs.hasSuffix("." + mine) || mine.hasSuffix("." + theirs))
        }
    }

    private static func domain(_ email: String?) -> String? {
        guard let email, let at = email.lastIndex(of: "@") else { return nil }
        let domain = email[email.index(after: at)...].trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        return domain.isEmpty ? nil : domain
    }

    static func hosts(for bundleID: String?) -> [String] {
        guard let bundleID else { return [] }
        return appHosts.first { entry in
            entry.bundleIDs.contains { bundleID == $0 || bundleID.hasPrefix($0 + ".") }
        }?.hosts ?? []
    }

    private static func event(_ event: EKEvent) -> CalendarEvent {
        let people = event.attendees ?? []
        let organizer = event.organizer.map(participant), invited = people.map(participant)
        return CalendarEvent(
            title: event.title ?? "",
            start: event.startDate,
            end: event.endDate,
            isAllDay: event.isAllDay,
            isCancelled: event.status == .canceled,
            declinedByMe: people.contains { $0.isCurrentUser && $0.participantStatus == .declined },
            text: [event.url?.absoluteString, event.location, event.notes].compactMap { $0 }.joined(separator: "\n"),
            attendees: names(organizer: organizer, attendees: invited),
            hasExternal: hasExternal(organizer: organizer, attendees: invited))
    }

    private static func participant(_ p: EKParticipant) -> CalendarParticipant {
        let address = p.url.absoluteString
        let email = address.lowercased().hasPrefix("mailto:")
            ? String(address.dropFirst("mailto:".count)).removingPercentEncoding : nil
        return CalendarParticipant(
            name: p.name, email: email, isMe: p.isCurrentUser,
            isPerson: p.participantType != .room && p.participantType != .resource)
    }
}
