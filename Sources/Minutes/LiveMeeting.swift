import Foundation

/// A meeting being recorded, transcribed or waiting for the transcriber, as the notes window and the menu bar show it.
struct LiveMeeting {
    enum Phase {
        /// `levels` is polled by the view; values are 0…1.
        case recording(levels: () -> (me: Float, others: Float))
        /// nil while the progress is not known yet.
        case transcribing(progress: Double?)
        /// Behind another meeting in the transcriber.
        case queued
    }

    let id: String
    let title: String
    let app: String?
    let startedAt: Date
    let phase: Phase
    var mode: RecordMode = .screen

    func with(_ phase: Phase) -> LiveMeeting {
        LiveMeeting(id: id, title: title, app: app, startedAt: startedAt, phase: phase, mode: mode)
    }

    var isRecording: Bool {
        if case .recording = phase { return true }
        return false
    }
}

/// The transcriber's jobs as shown: the one under way and those waiting behind it, in order. The same meeting can be
/// in it twice (Try Again while it waits); each finish removes one entry.
struct TranscriptionQueue {
    private(set) var current: LiveMeeting?
    private(set) var waiting: [LiveMeeting] = []

    var all: [LiveMeeting] { [current].compactMap { $0 } + waiting }

    /// `next`: nothing is ahead of it, so it shows as transcribing straight away, while its video is combined.
    mutating func add(_ meeting: LiveMeeting, next: Bool) {
        if next && current == nil {
            current = meeting.with(.transcribing(progress: nil))
        } else {
            waiting.append(meeting.with(.queued))
        }
    }

    mutating func started(_ meeting: LiveMeeting) {
        if current?.id != meeting.id, let index = waiting.firstIndex(where: { $0.id == meeting.id }) {
            waiting.remove(at: index)
        }
        // A job that reached the transcriber first puts the one shown as next back at the head of the line.
        if let shown = current, shown.id != meeting.id { waiting.insert(shown.with(.queued), at: 0) }
        current = meeting.with(.transcribing(progress: nil))
    }

    /// Returns false when nothing shown changed: another meeting, or the same whole percent.
    mutating func progress(_ value: Double, id: String) -> Bool {
        guard let now = current, now.id == id else { return false }
        if case .transcribing(let old?) = now.phase, Int(old * 100) == Int(value * 100) { return false }
        current = now.with(.transcribing(progress: value))
        return true
    }

    mutating func finished(_ id: String?) {
        if let id, current?.id == id {
            current = nil
        } else if let id, let index = waiting.firstIndex(where: { $0.id == id }) {
            waiting.remove(at: index)
        }
    }

    mutating func clear() {
        current = nil
        waiting = []
    }
}

/// Mute Microphone on the recording page and in the menu bar menu: the mic track records silence while it is on.
/// Main thread.
final class MicMute: ObservableObject {
    static let shared = MicMute()

    @Published private(set) var on = false
    var onToggle: (() -> Void)?

    func show(_ value: Bool) {
        if on != value { on = value }
    }

    func toggle() {
        onToggle?()
    }
}
