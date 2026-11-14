import AppKit
import SwiftUI

/// What a swipe on a meeting row can do: Pin on the left, Delete and Archive on the right.
enum SwipeAction: Equatable {
    case pin, unpin, archive, unarchive, delete

    var label: String {
        switch self {
        case .pin: "Pin"
        case .unpin: "Unpin"
        case .archive: "Archive"
        case .unarchive: "Unarchive"
        case .delete: "Delete"
        }
    }

    var symbol: String {
        switch self {
        case .pin: "pin"
        case .unpin: "pin.slash"
        case .archive: "archivebox"
        case .unarchive: "arrow.up.bin"
        case .delete: "trash"
        }
    }

    var color: Color {
        switch self {
        case .pin, .unpin: .swipePin
        case .archive, .unarchive: .swipeArchive
        case .delete: Color(nsColor: .systemRed)
        }
    }

    /// Icon over label, for placing it at the edge on a full swipe.
    var contentWidth: CGFloat {
        max(16, ceil((label as NSString).size(withAttributes: [.font: NSFont.systemFont(ofSize: 11, weight: .semibold)]).width))
    }
}

extension Color {
    static let swipePin = Color(nsColor: .systemOrange)
    static let swipeArchive = Color(nsColor: NSColor(name: nil) { appearance in
        appearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua
            ? NSColor(srgbRed: 0x8f / 255, green: 0x89 / 255, blue: 0xc4 / 255, alpha: 1)
            : NSColor(srgbRed: 0x8a / 255, green: 0x84 / 255, blue: 0xb6 / 255, alpha: 1)
    })
    /// Archive and Delete on a meeting being recorded or transcribed.
    static let swipeOff = Color(nsColor: NSColor(name: nil) { appearance in
        appearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua
            ? NSColor(srgbRed: 0x3a / 255, green: 0x3a / 255, blue: 0x3c / 255, alpha: 1)
            : NSColor(srgbRed: 0xd8 / 255, green: 0xd8 / 255, blue: 0xde / 255, alpha: 1)
    })
    static let swipeOffText = Color(nsColor: NSColor(name: nil) { appearance in
        appearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua
            ? NSColor(srgbRed: 0x98 / 255, green: 0x98 / 255, blue: 0x9d / 255, alpha: 1)
            : NSColor(srgbRed: 0x6e / 255, green: 0x6e / 255, blue: 0x73 / 255, alpha: 1)
    })
}

extension MeetingItem {
    var isArchived: Bool { meta.archivedAt != nil }
    var isPinned: Bool { meta.pinnedAt != nil && meta.archivedAt == nil }
}

extension Motion {
    /// A swiped row opening, closing or springing back, and a pinned row moving up.
    static var swipeSpring: Animation { .spring(response: 0.4 * timeScale, dampingFraction: 0.86) }
    /// A row sliding off after a full swipe, and the gap it leaves closing.
    static var slideOff: Animation { .easeOut(duration: 0.2 * timeScale) }
}

/// One scroll event as the swipe reads it. `dx` follows the fingers whatever the scroll direction setting says.
struct SwipeInput {
    var phase: NSEvent.Phase
    var momentum: NSEvent.Phase = []
    var dx: CGFloat
    var dy: CGFloat = 0
    /// Seconds.
    var time: TimeInterval

    init(phase: NSEvent.Phase, momentum: NSEvent.Phase = [], dx: CGFloat, dy: CGFloat = 0, time: TimeInterval) {
        self.phase = phase
        self.momentum = momentum
        self.dx = dx
        self.dy = dy
        self.time = time
    }

    init?(_ event: NSEvent) {
        guard event.type == .scrollWheel else { return nil }
        let fingers: CGFloat = event.isDirectionInvertedFromDevice ? 1 : -1
        self.init(phase: event.phase, momentum: event.momentumPhase, dx: event.scrollingDeltaX * fingers,
                  dy: event.scrollingDeltaY * fingers, time: event.timestamp)
    }
}

/// Two-finger swipes on meeting rows. Trackpad and Magic Mouse scrolls carry a phase; a gesture that starts on a row
/// and moves sideways first becomes a swipe, anything else scrolls the list. A plain wheel never swipes, and dragging
/// a row with the mouse stays a drag onto a group.
final class SidebarSwipeModel: ObservableObject {
    struct Sides: Equatable {
        var lead: [SwipeAction] = []
        var trail: [SwipeAction] = []
        /// A live meeting: Archive and Delete show grey and the row springs back.
        var trailDisabled = false
        static let none = Sides()
    }

    enum Release: Equatable {
        case close
        case open(CGFloat)
        case fire(SwipeAction)
    }

    static let button: CGFloat = 60
    static let labelFrom: CGFloat = 52
    static let lock: CGFloat = 6
    static let flick: CGFloat = 0.4
    static let fullFraction: CGFloat = 0.65
    static let defaultWidth: CGFloat = 240
    /// The list's coordinate space, shared by the row frames and the event view.
    static let space = "meeting-list"

    /// The row drawn swiped: being swiped, open, springing shut or sliding off.
    @Published private(set) var rowID: String?
    @Published private(set) var leaving = false
    /// Watched by the swiped row alone; every other row watches only `rowID`.
    let track = SwipeTrack()
    private(set) var offset: CGFloat {
        get { track.offset }
        set { track.offset = newValue }
    }
    /// Past the full-swipe point: letting go does the edge action.
    private(set) var armed: Bool {
        get { track.armed }
        set { track.armed = newValue }
    }
    private(set) var tracking = false

    var rowFrames: [String: CGRect] = [:]
    var sides: (String) -> Sides = { _ in .none }
    var fire: (String, SwipeAction) -> Void = { _, _ in }

    private enum Gesture {
        case idle
        case pending(String, dx: CGFloat, dy: CGFloat)
        case swiping(String, base: CGFloat, dx: CGFloat)
        case scrolling
        /// Let go after a swipe; its momentum is dropped.
        case done
    }

    private var gesture = Gesture.idle
    /// Points per millisecond, towards the right.
    private(set) var velocity: CGFloat = 0
    private var lastMove: TimeInterval = 0

    /// Open or under the fingers; a click elsewhere, Esc or another swipe closes it.
    var isOpen: Bool { rowID != nil && !leaving && (tracking || offset != 0) }

    func row(at point: CGPoint) -> String? {
        rowFrames.first { $0.value.contains(point) }?.key
    }

    private func width(_ id: String) -> CGFloat {
        rowFrames[id].map(\.width).flatMap { $0 > 0 ? $0 : nil } ?? Self.defaultWidth
    }

    /// Returns true when the event went to a swipe, so the list does not scroll with it.
    @discardableResult
    func handle(_ input: SwipeInput, row: @autoclosure () -> String?) -> Bool {
        if !input.momentum.isEmpty {
            switch gesture {
            case .swiping, .done: return true
            default: return false
            }
        }
        guard !input.phase.isEmpty, !input.phase.contains(.mayBegin) else { return false }
        if input.phase.contains(.began) {
            gesture = row().map { .pending($0, dx: 0, dy: 0) } ?? .scrolling
            velocity = 0
            lastMove = input.time
        }
        let finished = input.phase.contains(.ended) || input.phase.contains(.cancelled)
        switch gesture {
        case .pending(let id, var dx, var dy):
            dx += input.dx
            dy += input.dy
            if finished {
                gesture = .idle
                return false
            }
            guard hypot(dx, dy) >= Self.lock else {
                gesture = .pending(id, dx: dx, dy: dy)
                return false
            }
            guard abs(dx) >= 1.5 * abs(dy), !(rowID == id && leaving) else {
                gesture = .scrolling
                return false
            }
            var base: CGFloat = 0
            if rowID == id {
                base = offset
            } else if rowID != nil {
                close()
            }
            gesture = .swiping(id, base: base, dx: dx)
            rowID = id
            tracking = true
            lastMove = input.time
            track(id, raw: base + dx)
            return true
        case .swiping(let id, let base, var dx):
            if input.phase.contains(.cancelled) {
                gesture = .done
                tracking = false
                close()
                return true
            }
            if input.dx != 0 {
                let dt = input.time - lastMove
                if dt > 0 { velocity = 0.7 * input.dx / CGFloat(dt * 1000) + 0.3 * velocity }
                lastMove = input.time
            }
            dx += input.dx
            gesture = .swiping(id, base: base, dx: dx)
            if finished {
                gesture = .done
                tracking = false
                // Fingers that rested before lifting give no flick.
                release(id, velocity: input.time - lastMove > 0.08 ? 0 : velocity)
            } else {
                track(id, raw: base + dx)
            }
            return true
        case .scrolling, .idle, .done:
            if finished, case .scrolling = gesture { gesture = .idle }
            return false
        }
    }

    private func track(_ id: String, raw: CGFloat) {
        let shown = Self.display(raw: raw, sides: sides(id), width: width(id))
        offset = shown.offset
        if shown.armed != armed {
            if shown.armed { NSHapticFeedbackManager.defaultPerformer.perform(.alignment, performanceTime: .now) }
            Motion.animate(Motion.reduceMotion ? nil : Motion.slideOff) { armed = shown.armed }
        }
    }

    private func release(_ id: String, velocity: CGFloat) {
        switch Self.release(offset: offset, armed: armed, velocity: velocity, sides: sides(id)) {
        case .close: close()
        case .open(let x): Motion.animate(Motion.reduceMotion ? nil : Motion.swipeSpring) { offset = x }
        case .fire(let action): fire(id, action)
        }
    }

    /// Where the row is drawn for a finger `raw` points from rest: 1:1 up to the full swipe, then 0.45×, stopping
    /// 8 pt short of the edge; a side without actions gives 0.12× up to 24 pt, a disabled one 0.5× then 0.1×.
    static func display(raw: CGFloat, sides: Sides, width: CGFloat) -> (offset: CGFloat, armed: Bool) {
        let lead = raw >= 0
        let actions = lead ? sides.lead : sides.trail
        let sign: CGFloat = lead ? 1 : -1
        let r = abs(raw)
        let open = button * CGFloat(actions.count)
        let full = width * fullFraction
        if actions.isEmpty { return (sign * min(24, r * 0.12), false) }
        if !lead, sides.trailDisabled { return (sign * (r <= open ? r * 0.5 : open * 0.5 + (r - open) * 0.1), false) }
        if r <= full { return (raw, false) }
        return (sign * min(width - 8, full + (r - full) * 0.45), true)
    }

    /// Letting go: past the full swipe does the edge action; past half the buttons, or a flick of 0.4 pt/ms outwards,
    /// opens; a flick back or anything less closes.
    static func release(offset: CGFloat, armed: Bool, velocity: CGFloat, sides: Sides) -> Release {
        let lead = offset > 0
        let actions = lead ? sides.lead : sides.trail
        if offset == 0 || actions.isEmpty || (!lead && sides.trailDisabled) { return .close }
        if armed { return .fire(lead ? actions[0] : actions[actions.count - 1]) }
        let open = button * CGFloat(actions.count)
        let outwards = lead ? velocity : -velocity
        if outwards < -flick { return .close }
        if abs(offset) >= open / 2 || (outwards > flick && abs(offset) > 12) { return .open(lead ? open : -open) }
        return .close
    }

    /// Springs back. The row's own offset animates, so the model is at rest at once.
    func close(animated: Bool = true) {
        guard rowID != nil, !leaving else { return }
        tracking = false
        if case .swiping = gesture { gesture = .done }
        Motion.animate(animated && offset != 0 && !Motion.reduceMotion ? Motion.swipeSpring : nil) {
            offset = 0
            armed = false
            rowID = nil
        }
    }

    /// The row leaves the list: it slides off to the left, `done` removes it, and the list closes the gap.
    func slideOff(_ id: String, then done: @escaping () -> Void) {
        tracking = false
        guard rowID == id, !Motion.reduceMotion else {
            if rowID == id { reset() }
            done()
            return
        }
        leaving = true
        Motion.animate(Motion.slideOff) {
            offset = -(width(id) + 4)
            armed = true
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.2 * Motion.timeScale) { [weak self] in
            done()
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.25 * Motion.timeScale) {
                guard let self, self.rowID == id, self.leaving else { return }
                self.reset()
            }
        }
    }

    /// Back to rest at once: undo brings a row back, or the list changed under it.
    func reset() {
        rowID = nil
        offset = 0
        armed = false
        leaving = false
        tracking = false
    }

    /// A click while a row is open closes it. True when the click should go no further: anywhere on a row except the
    /// open row's buttons.
    func click(at point: CGPoint?) -> Bool {
        guard isOpen, let id = rowID else { return false }
        guard let point else {
            close()
            return false
        }
        if let frame = rowFrames[id], frame.contains(point) {
            let onButtons = offset > 0 ? point.x < frame.minX + offset : point.x > frame.maxX + offset
            if onButtons { return false }
            close()
            return true
        }
        close()
        return row(at: point) != nil
    }

    /// Esc: true when it closed a row.
    func escape() -> Bool {
        guard isOpen else { return false }
        close()
        return true
    }
}

/// Where the swiped row is drawn, on every frame of a swipe.
final class SwipeTrack: ObservableObject {
    @Published fileprivate(set) var offset: CGFloat = 0
    @Published fileprivate(set) var armed = false
    /// For the rows not being swiped; never changes.
    static let idle = SwipeTrack()
}

/// A meeting row over its swipe buttons, laid out from one animatable offset so the buttons share out whatever width
/// the row uncovers on every frame of a spring.
struct SwipeSurface<Content: View>: View, Animatable {
    var offset: CGFloat
    /// 0 to 1: the edge action taking the whole width on a full swipe.
    var grow: CGFloat
    /// Asked only while the row is moved.
    let sides: () -> SidebarSwipeModel.Sides
    /// Under the row while it is moved: the selection on the selected row, otherwise nothing over the sidebar.
    let fill: Color
    let act: (SwipeAction) -> Void
    @ViewBuilder let content: Content

    var animatableData: AnimatablePair<CGFloat, CGFloat> {
        get { AnimatablePair(offset, grow) }
        set {
            offset = newValue.first
            grow = newValue.second
        }
    }

    var body: some View {
        content
            .background {
                if abs(offset) >= 0.5 { Rectangle().fill(fill).background(Color.notesChrome) }
            }
            .offset(x: offset)
            .background(alignment: offset > 0 ? .leading : .trailing) {
                if abs(offset) >= 0.5 { buttons }
            }
    }

    @ViewBuilder private var buttons: some View {
        let lead = offset > 0
        let sides = sides()
        let actions = lead ? sides.lead : sides.trail
        let disabled = !lead && sides.trailDisabled
        let width = abs(offset)
        if let edge = lead ? actions.first : actions.last {
            let total = 1 + CGFloat(actions.count - 1) * (1 - grow)
            HStack(spacing: 0) {
                ForEach(Array(actions.enumerated()), id: \.offset) { index, action in
                    let primary = lead ? index == 0 : index == actions.count - 1
                    let share = width * (primary ? 1 : 1 - grow) / total
                    SwipeButton(action: action, width: share, disabled: disabled,
                                showLabel: grow > 0.5 ? primary : width / CGFloat(actions.count) >= SidebarSwipeModel.labelFrom,
                                shift: primary ? edgeShift(action, width: share, lead: lead) : 0) { act(action) }
                }
            }
            .frame(width: width, alignment: lead ? .leading : .trailing)
            .frame(maxHeight: .infinity)
            .background(disabled ? Color.swipeOff : edge.color)
        }
    }

    /// On a full swipe the edge action moves from the middle of its button to 14 pt from the row.
    private func edgeShift(_ action: SwipeAction, width: CGFloat, lead: Bool) -> CGFloat {
        let travel = max(0, width / 2 - 14 - action.contentWidth / 2)
        return (lead ? travel : -travel) * grow
    }
}

private struct SwipeButton: View {
    let action: SwipeAction
    let width: CGFloat
    let disabled: Bool
    let showLabel: Bool
    let shift: CGFloat
    let run: () -> Void

    var body: some View {
        Button(action: run) {
            VStack(spacing: 3) {
                // One box for every icon, so the labels share a baseline.
                Image(systemName: action.symbol)
                    .font(.system(size: 14, weight: .medium))
                    .frame(width: 18, height: 16)
                Text(action.label)
                    .font(.system(size: 11, weight: .semibold))
                    .opacity(showLabel ? 1 : 0)
            }
            .fixedSize()
            // The icon alone sits in the middle; the label fades in under it.
            .offset(x: shift, y: showLabel ? 0 : 8)
            .animation(.easeOut(duration: 0.12 * Motion.timeScale), value: showLabel)
            .frame(width: max(width, 0))
            .frame(maxHeight: .infinity)
            .foregroundStyle(disabled ? Color.swipeOffText : .white)
            .background(disabled ? Color.swipeOff : action.color)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(disabled)
        .clipped()
        .accessibilityLabel(action.label)
    }
}

/// Where each meeting row is, in the list's coordinate space.
struct SwipeRowFrames: PreferenceKey {
    static let defaultValue: [String: CGRect] = [:]

    static func reduce(value: inout [String: CGRect], nextValue: () -> [String: CGRect]) {
        value.merge(nextValue()) { $1 }
    }
}

/// Sees the window's scrolls, clicks and keys before the list does, in the list's coordinates. Draws nothing and
/// takes no clicks of its own.
struct SidebarEvents: NSViewRepresentable {
    /// Points at the bottom of the list that something lies over, such as the Undo toast.
    var covered: CGFloat = 0
    /// True: the event goes no further. The point is nil outside the visible part of the list.
    let handle: (NSEvent, CGPoint?) -> Bool

    func makeNSView(context: Context) -> EventView {
        let view = EventView()
        updateNSView(view, context: context)
        return view
    }

    func updateNSView(_ view: EventView, context: Context) {
        view.handle = handle
        view.covered = covered
    }

    final class EventView: NSView {
        var handle: (NSEvent, CGPoint?) -> Bool = { _, _ in false }
        var covered: CGFloat = 0
        private var monitor: Any?

        override var isFlipped: Bool { true }

        override func hitTest(_ point: NSPoint) -> NSView? { nil }

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            if let monitor { NSEvent.removeMonitor(monitor) }
            monitor = nil
            guard window != nil else { return }
            monitor = NSEvent.addLocalMonitorForEvents(matching: [.scrollWheel, .leftMouseDown, .rightMouseDown, .keyDown]) { [weak self] event in
                guard let self, let window = self.window, event.window === window else { return event }
                // Rows scrolled out of sight lie under the search field and the toast; a point there is not on them.
                let point = self.convert(event.locationInWindow, from: nil)
                let visible = self.visibleRect
                let listed = visible.contains(point) && point.y < visible.maxY - self.covered
                return self.handle(event, listed ? point : nil) ? nil : event
            }
        }

        deinit {
            if let monitor { NSEvent.removeMonitor(monitor) }
        }
    }
}
