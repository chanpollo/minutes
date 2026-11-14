import AppKit
import QuartzCore

/// The app icon's dial reduced to a one-colour template for the menu bar: twelve ticks, the first quarter drawn longer
/// as recorded levels, and the record dot in the middle.
enum MenuBarIcon {
    static let dial = image(.still, color: nil)
    // The menu bar ignores contentTintColor on template images, so the recording glyph is drawn red itself.
    static let recording = image(.still, color: .recordDot)
    static let recordingDescription = "Minutes, recording"

    /// Under the moving layers, so VoiceOver keeps one label for the whole recording.
    static let blank: NSImage = {
        let image = NSImage(size: NSSize(width: 18, height: 18), flipped: true) { _ in true }
        image.accessibilityDescription = recordingDescription
        return image
    }()

    static let inner: CGFloat = 4.8
    static let rest: CGFloat = 6.6

    /// One drawing of the glyph: each tick's outer radius and alpha from 12 o'clock clockwise, and the dot.
    struct Frame: Equatable {
        var outer: [CGFloat]
        var alpha: [CGFloat]
        var dotRadius: CGFloat
        var dotAlpha: CGFloat

        /// Below these a layer would move less than a device pixel at 2× or four levels of 255; the change waits
        /// until it adds up, so the breathing dot commits a few times a second, not every tick.
        static let reachStep: CGFloat = 0.02
        static let alphaStep: CGFloat = 1 / 64

        func differs(from other: Frame) -> Bool {
            zip(outer, other.outer).contains { abs($0 - $1) >= Self.reachStep }
                || zip(alpha, other.alpha).contains { abs($0 - $1) >= Self.alphaStep }
                || abs(dotRadius - other.dotRadius) >= Self.reachStep
                || abs(dotAlpha - other.dotAlpha) >= Self.alphaStep
        }

        static let still: Frame = {
            let levels: [CGFloat] = [0.55, 1.0, 0.7, 0.9]
            return Frame(
                outer: (0..<12).map { $0 < levels.count ? 6.4 + 2.2 * levels[$0] : rest },
                alpha: (0..<12).map { $0 < levels.count ? 1 : 0.4 },
                dotRadius: 2.2, dotAlpha: 1)
        }()
    }

    /// The red `recording` draws in this appearance, for the layers, which cannot resolve a dynamic colour.
    static func ink(in appearance: NSAppearance) -> CGColor {
        var ink = NSColor.recordDot.cgColor
        appearance.performAsCurrentDrawingAppearance { ink = NSColor.recordDot.cgColor }
        return ink
    }

    /// `color` nil draws the template.
    static func image(_ frame: Frame, color: NSColor?) -> NSImage {
        let ink = color ?? .black
        let image = NSImage(size: NSSize(width: 18, height: 18), flipped: true) { _ in
            let center = NSPoint(x: 9, y: 9)
            // One path per alpha, as the still glyph was always drawn, so it stays the same pixel for pixel.
            let alphas = frame.alpha.reduce(into: [CGFloat]()) { if !$0.contains($1) { $0.append($1) } }
            for alpha in alphas {
                let path = NSBezierPath()
                for i in 0..<12 where frame.alpha[i] == alpha {
                    let angle = CGFloat(i) * .pi / 6 - .pi / 2
                    let outer = frame.outer[i]
                    path.move(to: NSPoint(x: center.x + inner * cos(angle), y: center.y + inner * sin(angle)))
                    path.line(to: NSPoint(x: center.x + outer * cos(angle), y: center.y + outer * sin(angle)))
                }
                path.lineCapStyle = .round
                path.lineWidth = 1.5
                ink.withAlphaComponent(alpha).setStroke()
                path.stroke()
            }
            ink.withAlphaComponent(frame.dotAlpha).setFill()
            let r = frame.dotRadius
            NSBezierPath(ovalIn: NSRect(x: center.x - r, y: center.y - r, width: 2 * r, height: 2 * r)).fill()
            return true
        }
        image.isTemplate = color == nil
        image.accessibilityDescription = color == nil ? "Minutes" : recordingDescription
        return image
    }
}

/// How the recording glyph moves: a 4-tick recorded arc that walks one tick every 5 s of recording, its head showing
/// the level now and the ticks behind it the peaks of the last three 250 ms windows, and a dot that breathes.
struct GlyphMotion {
    static let reach: CGFloat = 1.6
    static let window: TimeInterval = 0.25
    static let step: TimeInterval = 5
    static let fade: TimeInterval = 0.3
    static let breath: TimeInterval = 4

    /// Peaks of the last four windows, newest first.
    private(set) var history: [CGFloat] = [0, 0, 0, 0]
    private var windowPeak: CGFloat = 0
    private var windowEnd: TimeInterval?
    private var hand: Int?
    private var steppedAt = -TimeInterval.infinity
    private var lastWall = -TimeInterval.infinity

    /// −42 dBFS (0.30 on the meter) draws nothing past the rest length, −6 dBFS (0.90) the full reach.
    static func drawn(_ level: Float) -> CGFloat {
        min(max((CGFloat(level) - 0.3) / 0.6, 0), 1)
    }

    /// The head tick, counted from 12 o'clock: 3 o'clock at 0:00, round once a minute.
    static func hand(elapsed: TimeInterval) -> Int {
        (3 + Int(floor(max(0, elapsed) / step))) % 12
    }

    /// `wall` is seconds since the glyph started moving, for the windows, fades and breathing; `elapsed` is the
    /// recording clock, for the hand. Everything runs on these clocks, so the tick rate changes no curve.
    mutating func frame(wall: TimeInterval, elapsed: TimeInterval, level: Float) -> MenuBarIcon.Frame {
        let d = Self.drawn(level)
        var end = windowEnd ?? wall + Self.window
        // After the timer was paused, the windows missed count as silent.
        end = max(end, wall - 4 * Self.window)
        while wall >= end {
            history = [windowPeak] + history.dropLast()
            windowPeak = 0
            end += Self.window
        }
        windowEnd = end
        // Closed first, so a sample counts in the window its time falls in whatever the tick rate.
        windowPeak = max(windowPeak, d)

        let head = Self.hand(elapsed: elapsed)
        if let hand, hand != head {
            // The step fell between the last tick and this one; the recording clock says where.
            let into = max(0, elapsed).truncatingRemainder(dividingBy: Self.step)
            steppedAt = wall - min(into, wall - lastWall)
        }
        hand = head
        lastWall = wall
        let f = min(1, max(0, (wall - steppedAt) / Self.fade))
        let e = 1 - pow(1 - f, 3)

        let rest = MenuBarIcon.rest
        var outer = [CGFloat](repeating: rest, count: 12)
        var alpha = [CGFloat](repeating: 0.4, count: 12)
        outer[head] = rest + Self.reach * d * e
        alpha[head] = 0.4 + 0.6 * e
        for k in 1..<4 {
            outer[(head - k + 12) % 12] = rest + Self.reach * history[k - 1]
            alpha[(head - k + 12) % 12] = 1
        }
        if e < 1 {
            outer[(head + 8) % 12] = rest + Self.reach * history[3] * (1 - e)
            alpha[(head + 8) % 12] = 1 - 0.6 * e
        }
        let c = (1 + cos(2 * .pi * wall.truncatingRemainder(dividingBy: Self.breath) / Self.breath)) / 2
        return MenuBarIcon.Frame(outer: outer, alpha: alpha, dotRadius: 2.0 + 0.2 * c, dotAlpha: 0.55 + 0.45 * c)
    }
}

/// Moves the status item's glyph while recording: 30 fps while the menu bar can be seen, each tick a target the
/// layers glide to by the next one; nothing at all under Reduce Motion, where the still red glyph stays.
final class RecordingGlyph {
    static let fps: Double = 30
    static let tolerance: TimeInterval = 0.005

    private weak var button: NSButton?
    private var levels: (() -> (me: Float, others: Float))?
    private var startedAt = Date()
    private var wallStart: TimeInterval = 0
    private var motion = GlyphMotion()
    private var timer: Timer?
    private var layers: GlyphLayers?
    private var shown: (frame: MenuBarIcon.Frame, ink: CGColor)?
    private var red: (appearance: NSAppearance, color: CGColor)?
    private var observers: [(NotificationCenter, NSObjectProtocol)] = []
    private var appearance: NSKeyValueObservation?

    var isRecording: Bool { levels != nil }
    var isTicking: Bool { timer != nil }
    var isMoving: Bool { layers != nil }

    init(button: NSButton?) {
        self.button = button
    }

    func start(startedAt: Date, levels: @escaping () -> (me: Float, others: Float)) {
        if isRecording, startedAt == self.startedAt { return }
        stop()
        self.startedAt = startedAt
        self.levels = levels
        wallStart = ProcessInfo.processInfo.systemUptime
        motion = GlyphMotion()
        let workspace = NSWorkspace.shared.notificationCenter
        observers.append((workspace, workspace.addObserver(
            forName: NSWorkspace.accessibilityDisplayOptionsDidChangeNotification, object: nil, queue: .main
        ) { [weak self] _ in self?.update() }))
        // Back from behind the notch, another Space or a display change may not post an occlusion change of its own.
        observers.append((workspace, workspace.addObserver(
            forName: NSWorkspace.activeSpaceDidChangeNotification, object: nil, queue: .main
        ) { [weak self] _ in self?.update() }))
        observers.append((.default, NotificationCenter.default.addObserver(
            forName: NSApplication.didChangeScreenParametersNotification, object: nil, queue: .main
        ) { [weak self] _ in self?.update() }))
        observers.append((.default, NotificationCenter.default.addObserver(
            forName: NSWindow.didChangeOcclusionStateNotification, object: nil, queue: .main
        ) { [weak self] note in
            if let self, let window = note.object as? NSWindow, window === button?.window { update() }
        }))
        // This fires several times for every image set, so only a change of colour counts.
        appearance = button?.observe(\.effectiveAppearance) { [weak self] button, _ in
            guard let self, let shown, shown.ink != MenuBarIcon.ink(in: button.effectiveAppearance) else { return }
            DispatchQueue.main.async { self.update() }
        }
        update()
    }

    /// Stop and quit: the timer goes and the plain dial comes back in the same call.
    func stop() {
        timer?.invalidate()
        timer = nil
        levels = nil
        for (center, observer) in observers { center.removeObserver(observer) }
        observers = []
        appearance = nil
        shown = nil
        layers?.host.removeFromSuperlayer()
        layers = nil
        button?.image = MenuBarIcon.dial
    }

    private func update() {
        guard isRecording, let button else { return }
        if Motion.reduceMotion {
            timer?.invalidate()
            timer = nil
            layers?.host.removeFromSuperlayer()
            layers = nil
            shown = nil
            if button.image !== MenuBarIcon.recording { button.image = MenuBarIcon.recording }
            return
        }
        tick()
        let visible = button.window?.occlusionState.contains(.visible) ?? false
        if visible, timer == nil {
            let timer = Timer(timeInterval: 1 / Self.fps, repeats: true) { [weak self] _ in self?.tick() }
            timer.tolerance = Self.tolerance
            // .common keeps it running while the menu is open.
            RunLoop.main.add(timer, forMode: .common)
            self.timer = timer
        } else if !visible {
            timer?.invalidate()
            timer = nil
        }
    }

    private func tick() {
        guard let levels, let button else { return }
        let (me, others) = levels()
        let frame = motion.frame(
            wall: ProcessInfo.processInfo.systemUptime - wallStart, elapsed: Date().timeIntervalSince(startedAt),
            level: max(me, others))
        // Resolving the dynamic red costs more than the frame; the appearance object changes when the colour would.
        let appearance = button.effectiveAppearance
        if red?.appearance !== appearance { red = (appearance, MenuBarIcon.ink(in: appearance)) }
        let ink = red!.color
        if let shown, !frame.differs(from: shown.frame), shown.ink == ink, layers != nil { return }
        shown = (frame, ink)
        if let layers {
            layers.show(frame, ink: ink, in: button, duration: 1 / Self.fps)
        } else {
            let layers = GlyphLayers()
            button.image = MenuBarIcon.blank
            button.wantsLayer = true
            button.layer?.addSublayer(layers.host)
            self.layers = layers
            layers.show(frame, ink: ink, in: button, duration: 0)
        }
    }
}

/// The moving glyph as shape layers over a blank button image. Setting the button's image ten times a second cost
/// about 5 % CPU on macOS 27; these layers at 10 fps 0.2–0.4 %, and at 30 fps with the tweens 0.9 % of one core,
/// most of it the commit each tick, measured headless over 20 s of simulated talking.
final class GlyphLayers {
    let host = CALayer()
    private let ticks: [CAShapeLayer]
    private let dot = CAShapeLayer()
    private var ink: CGColor?
    private var shown: MenuBarIcon.Frame?
    private static let linear = CAMediaTimingFunction(name: .linear)
    /// Every path runs to the longest tick any frame draws, the still glyph's 1 o'clock, and strokeEnd trims it.
    static let longest = max(MenuBarIcon.rest + GlyphMotion.reach, MenuBarIcon.Frame.still.outer.max()!)

    init() {
        let outer = Self.longest
        ticks = (0..<12).map { i in
            let angle = CGFloat(i) * .pi / 6 - .pi / 2
            let path = CGMutablePath()
            path.move(to: CGPoint(x: 9 + MenuBarIcon.inner * cos(angle), y: 9 + MenuBarIcon.inner * sin(angle)))
            path.addLine(to: CGPoint(x: 9 + outer * cos(angle), y: 9 + outer * sin(angle)))
            let tick = CAShapeLayer()
            tick.path = path
            tick.lineWidth = 1.5
            tick.lineCap = .round
            tick.fillColor = nil
            return tick
        }
        dot.path = CGPath(ellipseIn: CGRect(x: 6.8, y: 6.8, width: 4.4, height: 4.4), transform: nil)
        for layer in ticks + [dot] { host.addSublayer(layer) }
    }

    /// Sets the frame as the layers' target; with a `duration` they glide there linearly from wherever they are now,
    /// so a tick a frame apart reads as motion, not a step. 0 applies at once. A property that moved less than a
    /// step keeps its old target, so a slow drift gathers into one small move.
    func show(_ frame: MenuBarIcon.Frame, ink: CGColor, in button: NSButton, duration: TimeInterval) {
        let bounds = button.bounds
        let place = CGRect(x: (bounds.width - 18) / 2, y: (bounds.height - 18) / 2, width: 18, height: 18)
        let scale = button.window?.backingScaleFactor ?? 2
        if ink != self.ink || host.contentsScale != scale || host.frame != place {
            CATransaction.begin()
            CATransaction.setDisableActions(true)
            host.frame = place
            if ink != self.ink || host.contentsScale != scale {
                self.ink = ink
                for layer in ticks + [dot] {
                    layer.frame = host.bounds
                    layer.contentsScale = scale
                    layer.strokeColor = layer === dot ? nil : ink
                    layer.fillColor = layer === dot ? ink : nil
                }
                host.contentsScale = scale
            }
            CATransaction.commit()
        }

        CATransaction.begin()
        if duration > 0 {
            CATransaction.setAnimationDuration(duration)
            CATransaction.setAnimationTimingFunction(Self.linear)
        } else {
            CATransaction.setDisableActions(true)
        }
        let span = Self.longest - MenuBarIcon.inner
        var next = shown ?? frame
        let reachStep = MenuBarIcon.Frame.reachStep, alphaStep = MenuBarIcon.Frame.alphaStep
        for (i, tick) in ticks.enumerated() {
            if shown == nil || abs(frame.outer[i] - next.outer[i]) >= reachStep {
                next.outer[i] = frame.outer[i]
                tick.strokeEnd = (frame.outer[i] - MenuBarIcon.inner) / span
            }
            if shown == nil || abs(frame.alpha[i] - next.alpha[i]) >= alphaStep {
                next.alpha[i] = frame.alpha[i]
                tick.opacity = Float(frame.alpha[i])
            }
        }
        if shown == nil || abs(frame.dotAlpha - next.dotAlpha) >= alphaStep {
            next.dotAlpha = frame.dotAlpha
            dot.opacity = Float(frame.dotAlpha)
        }
        if shown == nil || abs(frame.dotRadius - next.dotRadius) >= reachStep {
            next.dotRadius = frame.dotRadius
            let k = frame.dotRadius / 2.2
            dot.setAffineTransform(CGAffineTransform(scaleX: k, y: k))
        }
        shown = next
        CATransaction.commit()
    }
}
