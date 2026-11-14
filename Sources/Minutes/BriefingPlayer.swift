import AVFoundation
import AppKit
import Combine

/// One sound at a time: the briefing, the meeting player and the voice Preview pause each other.
enum OneSound {
    enum Source { case meeting, briefing, preview }

    private static var stoppers: [(source: Source, stop: () -> Void)] = []

    static func register(_ source: Source, stop: @escaping () -> Void) {
        stoppers.append((source, stop))
    }

    static func began(_ source: Source) {
        for stopper in stoppers where stopper.source != source { stopper.stop() }
    }

    static func stopAll() {
        for stopper in stoppers { stopper.stop() }
    }
}

/// Making, playing and the state of every meeting's briefing. Main thread only.
final class BriefingCenter: NSObject, ObservableObject, AVAudioPlayerDelegate {
    static let shared = BriefingCenter()

    enum Phase: Equatable {
        case script
        case audio(Double)
    }

    enum State: Equatable {
        case hidden
        case none
        case making(Phase)
        case ready(BriefingInfo, stale: Bool)
    }

    static let speeds: [Float] = [1, 1.25, 1.5]

    @Published private(set) var jobs: [String: Phase] = [:]
    /// Jobs whose audio is being moved into the meeting folder; too late to cancel.
    @Published private(set) var saving = Set<String>()
    /// The meeting whose briefing is loaded in the player.
    @Published private(set) var loadedID: String?
    @Published private(set) var loadedTitle = ""
    @Published private(set) var isPlaying = false
    @Published private(set) var time: TimeInterval = 0
    @Published private(set) var duration: TimeInterval = 0
    @Published private(set) var speed = Settings.briefingSpeed
    @Published private(set) var mode = Settings.briefingMode
    /// A recording is running: nothing may play, or the system tap could pick it up.
    @Published private(set) var recording = false

    /// State changes the menu bar menu shows (not every tick).
    var onChange: (() -> Void)?
    var onMade: ((String) -> Void)?
    var onError: ((Error) -> Void)?
    /// Tests swap the model and turn the sound down; the app uses the model in Settings.
    var model: () -> SummaryModel = { SummaryModel.current }
    var volume: Float = 1

    private var cancels: [String: () -> Void] = [:]
    private var autoplay = Set<String>()
    private var player: AVAudioPlayer?
    private var ticker: Timer?
    private var positions: [String: TimeInterval] = [:]
    private var scripts: [String: (madeAt: Date, paragraphs: [[String]])] = [:]
    /// Each job's own staging folder while it makes the audio.
    private(set) var stagings: [String: URL] = [:]
    /// When each briefing was last played or moved in the player; with madeAt it decides Play Last Briefing.
    private var touchedAt: [String: Date] = [:]
    private var latestFound: (id: String, title: String, duration: TimeInterval)??
    private var meetingsChanged: Any?
    // Each script job only touches its own meeting folder, so one slow Claude call never holds up another meeting.
    private let scriptQueue = DispatchQueue(label: "minutes.briefing-script", qos: .userInitiated, attributes: .concurrent)
    private let saveQueue = DispatchQueue(label: "minutes.briefing-save", qos: .userInitiated)

    override init() {
        super.init()
        OneSound.register(.briefing) { [weak self] in self?.pause() }
        meetingsChanged = NotificationCenter.default.addObserver(forName: .meetingsChanged, object: nil, queue: .main) { [weak self] _ in
            self?.latestFound = nil
        }
    }

    // MARK: State

    func state(of item: MeetingItem, hasSummary: Bool) -> State {
        guard mode != .off, hasSummary else { return .hidden }
        if let phase = jobs[item.id] { return .making(phase) }
        if item.hasBriefing, let info = item.meta.briefing { return .ready(info, stale: Briefing.isStale(item.meta)) }
        return .none
    }

    func setMode(_ new: Settings.BriefingMode) {
        Settings.briefingMode = new
        mode = new
        if new == .off {
            pause()
            for id in Array(jobs.keys) { cancel(id) }
        }
        onChange?()
    }

    func setRecording(_ on: Bool) {
        guard recording != on else { return }
        recording = on
        BriefingPreview.shared.blocked = on
        if on { OneSound.stopAll() }
        onChange?()
    }

    /// Listen: plays the briefing, making it first when there is none or it is out of date.
    func listen(_ id: String) {
        guard !recording, mode != .off, jobs[id] == nil, let folder = Workspace.folder(id: id) else { return }
        let meta = Workspace.readMeta(folder)
        let audio = FileManager.default.fileExists(atPath: folder.appendingPathComponent(Briefing.audioName).path)
        if audio, let meta, meta.briefing != nil, !Briefing.isStale(meta) {
            play(id)
        } else {
            make(id, autoplay: true)
        }
    }

    // MARK: Making

    /// `again` keeps the script when summary.md has not changed and only speaks it again.
    func make(_ id: String, autoplay play: Bool, again: Bool = false) {
        guard mode != .off, jobs[id] == nil, let folder = Workspace.folder(id: id) else { return }
        guard FileManager.default.fileExists(atPath: folder.appendingPathComponent("summary.md").path) else { return }
        if loadedID == id { unload() }
        jobs[id] = .script
        if play { autoplay.insert(id) } else { autoplay.remove(id) }
        onChange?()

        let claude = Summarizer.ClaudeCancel()
        var cancelled = false
        var speaker: BriefingSpeaker?
        cancels[id] = {
            cancelled = true
            claude.cancel()
            speaker?.cancel()
        }
        let model = model()
        scriptQueue.async { [weak self] in
            let result = Result { try Briefing.script(folder: folder, model: model, reuse: again, cancel: claude) }
            DispatchQueue.main.async {
                guard let self, !cancelled else { return }
                switch result {
                case .failure(let error):
                    self.finish(id, error: error)
                case .success(let script):
                    guard let (voice, label) = BriefingVoices.voice(for: script.language) else {
                        return self.finish(id, error: BriefingError(message: "No \(script.language.name) voice is installed"))
                    }
                    let staging: URL
                    do { staging = try Briefing.stagingFolder() } catch { return self.finish(id, error: error) }
                    self.stagings[id] = staging
                    self.jobs[id] = .audio(0)
                    let temp = staging.appendingPathComponent(Briefing.audioName)
                    let made = BriefingSpeaker(paragraphs: script.paragraphs, to: temp)
                    speaker = made
                    made.start(voice: voice, rate: BriefingVoices.rate(Settings.briefingRate), progress: { [weak self] value in
                        guard let self, self.jobs[id] != nil, !cancelled else { return }
                        let rounded = (value * 100).rounded() / 100
                        if self.jobs[id] != .audio(rounded) { self.jobs[id] = .audio(rounded) }
                    }, completion: { [weak self] output in
                        guard let self, !cancelled else { return }
                        switch output {
                        case .failure(let error):
                            self.finish(id, error: error)
                        case .success(let output):
                            self.saving.insert(id)
                            self.saveQueue.async {
                                let committed = Result {
                                    try Briefing.commit(meetingID: id, script: script, audio: temp, duration: output.duration,
                                                        marks: output.marks, voice: label)
                                }
                                DispatchQueue.main.async {
                                    guard !cancelled else { return }
                                    if case .failure(let error) = committed { return self.finish(id, error: error) }
                                    self.finish(id, error: nil)
                                }
                            }
                        }
                    })
                }
            }
        }
    }

    /// Stops making; whatever was there before stays. Once the new files are being saved it is too late.
    func cancel(_ id: String) {
        guard jobs[id] != nil, !saving.contains(id) else { return }
        cancels[id]?()
        cancels[id] = nil
        removeStaging(id)
        autoplay.remove(id)
        jobs[id] = nil
        onChange?()
    }

    private func removeStaging(_ id: String) {
        guard let folder = stagings.removeValue(forKey: id) else { return }
        try? FileManager.default.removeItem(at: folder)
    }

    private func finish(_ id: String, error: Error?) {
        let play = autoplay.remove(id) != nil
        cancels[id] = nil
        jobs[id] = nil
        saving.remove(id)
        removeStaging(id)
        if let error {
            if !(error is CancellationError) { onError?(error) }
        } else {
            scripts[id] = nil
            positions[id] = 0
            latestFound = nil
            onMade?(id)
            if play && !recording { self.play(id) }
        }
        onChange?()
    }

    // MARK: Playing

    func play(_ id: String) {
        guard !recording, mode != .off else { return }
        if loadedID != id || player == nil {
            guard load(id) else { return }
        }
        guard let player else { return }
        OneSound.began(.briefing)
        touch(id)
        player.enableRate = true
        player.rate = Self.speeds[speed]
        player.play()
        isPlaying = true
        startTicking()
        onChange?()
    }

    func pause() {
        guard let player, isPlaying else { return }
        player.pause()
        isPlaying = false
        time = player.currentTime
        if let loadedID { positions[loadedID] = time }
        stopTicking()
        onChange?()
    }

    func toggle(_ id: String) {
        if loadedID == id && isPlaying { pause() } else { play(id) }
    }

    /// Moving another meeting's briefing while one plays carries the playing over to it.
    func seek(_ id: String, to seconds: TimeInterval, play: Bool = false) {
        let carry = isPlaying && loadedID != id
        if loadedID != id || player == nil {
            guard load(id) else { return }
        }
        guard let player else { return }
        player.currentTime = min(max(0, seconds), player.duration)
        time = player.currentTime
        positions[id] = time
        touch(id)
        if (play || carry) && !isPlaying { self.play(id) }
    }

    private func touch(_ id: String) {
        touchedAt[id] = Date()
        latestFound = nil
    }

    func cycleSpeed() {
        speed = (speed + 1) % Self.speeds.count
        Settings.briefingSpeed = speed
        if isPlaying { player?.rate = Self.speeds[speed] }
    }

    /// Where the player is for this meeting: its own position when it is not the one loaded.
    func position(_ id: String) -> TimeInterval {
        loadedID == id ? time : positions[id] ?? 0
    }

    func isPlaying(_ id: String) -> Bool { isPlaying && loadedID == id }

    @discardableResult
    private func load(_ id: String) -> Bool {
        guard let folder = Workspace.folder(id: id) else { return false }
        do {
            let player = try AVAudioPlayer(contentsOf: folder.appendingPathComponent(Briefing.audioName))
            player.delegate = self
            player.enableRate = true
            player.volume = volume
            player.prepareToPlay()
            if let previous = loadedID, let old = self.player {
                pause()
                positions[previous] = old.currentTime
                old.stop()
            }
            self.player = player
            loadedID = id
            loadedTitle = Workspace.readMeta(folder)?.title ?? ""
            duration = player.duration
            player.currentTime = min(positions[id] ?? 0, player.duration)
            time = player.currentTime
            return true
        } catch {
            onError?(error)
            return false
        }
    }

    private func unload() {
        pause()
        player?.stop()
        player = nil
        if let loadedID { positions[loadedID] = 0 }
        loadedID = nil
        time = 0
        duration = 0
    }

    private func startTicking() {
        stopTicking()
        let timer = Timer(timeInterval: 0.1, repeats: true) { [weak self] _ in
            guard let self, let player = self.player else { return }
            self.time = player.currentTime
        }
        RunLoop.main.add(timer, forMode: .common)
        ticker = timer
    }

    private func stopTicking() {
        ticker?.invalidate()
        ticker = nil
    }

    /// At the end it goes back to the start and waits.
    func audioPlayerDidFinishPlaying(_ player: AVAudioPlayer, successfully flag: Bool) {
        guard player === self.player else { return }
        player.currentTime = 0
        isPlaying = false
        time = 0
        if let loadedID { positions[loadedID] = 0 }
        stopTicking()
        onChange?()
    }

    // MARK: Text

    /// briefing.md in paragraphs of sentences, read once per briefing.
    func paragraphs(_ item: MeetingItem, madeAt: Date) -> [[String]] {
        if let cached = scripts[item.id], cached.madeAt == madeAt { return cached.paragraphs }
        let text = (try? String(contentsOf: item.folder.appendingPathComponent(Briefing.scriptName), encoding: .utf8)) ?? ""
        let paragraphs = Briefing.parse(text)
        scripts[item.id] = (madeAt, paragraphs)
        return paragraphs
    }

    // MARK: Menu bar

    /// The briefing made or played most recently. Kept until the workspace changes or another one is made or played.
    func latest() -> (id: String, title: String, duration: TimeInterval)? {
        guard mode != .off else { return nil }
        if let found = latestFound { return found }
        let fm = FileManager.default
        var best: (id: String, title: String, duration: TimeInterval, at: Date)?
        for meeting in Workspace.meetings() {
            guard let info = meeting.meta.briefing,
                  fm.fileExists(atPath: meeting.folder.appendingPathComponent(Briefing.audioName).path) else { continue }
            let at = max(info.madeAt, touchedAt[meeting.meta.id] ?? .distantPast)
            if best.map({ at > $0.at }) ?? true { best = (meeting.meta.id, meeting.meta.title, info.duration, at) }
        }
        let found = best.map { (id: $0.id, title: $0.title, duration: $0.duration) }
        latestFound = .some(found)
        return found
    }

    /// Play Last Briefing: resumes where it was stopped; never makes one.
    func playLatest() {
        if isPlaying { return pause() }
        guard let latest = latest() else { return }
        play(latest.id)
    }

    var menuStatus: MenuBarStatus? {
        guard isPlaying, loadedID != nil else { return nil }
        return .briefing(label: "Briefing · \(loadedTitle)", progress: duration > 0 ? time / duration : 0,
                         note: "\(Self.clock(time)) / \(Self.clock(duration))")
    }

    /// "1:34".
    static func clock(_ seconds: TimeInterval) -> String {
        let total = max(0, Int(seconds))
        return String(format: "%d:%02d", total / 60, total % 60)
    }

    /// "41 s of 1 min 34 s" for VoiceOver.
    static func spoken(_ seconds: TimeInterval) -> String {
        let total = max(0, Int(seconds))
        return (total >= 60 ? "\(total / 60) min " : "") + "\(total % 60) s"
    }
}

/// Settings' Preview: a sentence in the chosen voice and rate, through the speakers.
final class BriefingPreview: NSObject, ObservableObject, AVSpeechSynthesizerDelegate {
    static let shared = BriefingPreview()

    @Published private(set) var speaking: BriefingLanguage?
    /// While recording, nothing may play: the microphone would pick it up.
    @Published var blocked = false {
        didSet { if blocked { stop() } }
    }
    var volume: Float = 1
    private let synthesizer = AVSpeechSynthesizer()

    override init() {
        super.init()
        synthesizer.delegate = self
        OneSound.register(.preview) { [weak self] in self?.stop() }
    }

    func toggle(_ language: BriefingLanguage, voice: String?, rate: Int) {
        if speaking == language { return stop() }
        stop()
        guard !blocked, let voice = voice.flatMap(AVSpeechSynthesisVoice.init(identifier:)) ?? BriefingVoices.voice(for: language)?.voice else { return }
        OneSound.began(.preview)
        let utterance = AVSpeechUtterance(string: language == .thai
            ? "สวัสดีค่ะ นี่คือเสียงที่จะอ่านสรุปการประชุมให้คุณฟังค่ะ"
            : "Hello. This is the voice that will read your meeting briefings.")
        utterance.voice = voice
        utterance.rate = BriefingVoices.rate(rate)
        utterance.volume = volume
        speaking = language
        synthesizer.speak(utterance)
    }

    func stop() {
        guard speaking != nil else { return }
        speaking = nil
        synthesizer.stopSpeaking(at: .immediate)
    }

    func speechSynthesizer(_ synthesizer: AVSpeechSynthesizer, didFinish utterance: AVSpeechUtterance) {
        speaking = nil
    }

    func speechSynthesizer(_ synthesizer: AVSpeechSynthesizer, didCancel utterance: AVSpeechUtterance) {
        speaking = nil
    }
}

/// The Listen button and progress line on a "Summary ready" card, kept in step with the briefing.
final class BriefingCard {
    private weak var panel: PromptPanel?
    private let id: String
    private let index: Int
    private let center: BriefingCenter
    private var watch: AnyCancellable?
    private let progress = BriefingCardProgress()
    private var shown: (making: Bool, playing: Bool, recording: Bool)?

    init(panel: PromptPanel, meetingID: String, listenIndex: Int, center: BriefingCenter = .shared) {
        self.panel = panel
        self.id = meetingID
        self.index = listenIndex
        self.center = center
        panel.staysOpen.insert(listenIndex)
        panel.addAccessory(progress)
        watch = center.objectWillChange.sink { [weak self] _ in
            DispatchQueue.main.async { self?.update() }
        }
        panel.onClose = { [weak self] in self?.watch = nil }
        // Closing the card with its × stops what it started playing; the position is kept for the Notes window.
        panel.onDismiss = { [weak self] in
            guard let self, center.isPlaying(id) else { return }
            center.pause()
        }
        update()
    }

    func pressed() {
        if center.isPlaying(id) {
            center.pause()
        } else if center.position(id) > 0, center.jobs[id] == nil, center.loadedID == id {
            center.play(id)
        } else {
            center.listen(id)
        }
    }

    /// Runs on every tick of the player: the button and the panel's size change only when what they show does.
    private func update() {
        guard let panel, let button = panel.button(index) else { return }
        let making = center.jobs[id] != nil
        let playing = center.isPlaying(id)
        let recording = center.recording
        if shown.map({ $0 != (making, playing, recording) }) ?? true {
            shown = (making, playing, recording)
            button.title = making ? "Making…" : playing ? "Pause" : "Listen"
            button.image = making ? nil : NSImage(systemSymbolName: playing ? "pause.fill" : "speaker.wave.2",
                                                  accessibilityDescription: nil)
            button.imagePosition = .imageLeading
            button.isEnabled = !making && !recording
            panel.setSpinner(making, on: index)
            panel.holdTimeout(making || playing)
        }
        let time = center.position(id)
        let shows = !making && center.loadedID == id && center.duration > 0 && (playing || time > 0)
        let flipped = progress.set(shown: shows, value: center.duration > 0 ? time / center.duration : 0,
                                   text: "\(BriefingCenter.clock(time)) / \(BriefingCenter.clock(center.duration))")
        if flipped { panel.refit() }
    }
}

/// "Briefing ━━━━━── 0:42 / 1:34" under a card's detail line.
final class BriefingCardProgress: NSStackView {
    private let bar = AccentLine()
    private let label = NSTextField(labelWithString: "")

    init() {
        super.init(frame: .zero)
        orientation = .horizontal
        spacing = 8
        let title = NSTextField(labelWithString: "Briefing")
        for field in [title, label] {
            field.font = .monospacedDigitSystemFont(ofSize: 11, weight: .regular)
            field.textColor = .tertiaryLabelColor
        }
        bar.translatesAutoresizingMaskIntoConstraints = false
        bar.heightAnchor.constraint(equalToConstant: 3).isActive = true
        bar.setContentHuggingPriority(.defaultLow, for: .horizontal)
        addView(title, in: .leading)
        addView(bar, in: .leading)
        addView(label, in: .leading)
        isHidden = true
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    /// True when it appeared or went away, so the card has to change its height.
    func set(shown: Bool, value: Double, text: String) -> Bool {
        let flipped = isHidden == shown
        if flipped { isHidden = !shown }
        guard shown else { return flipped }
        bar.value = value
        if label.stringValue != text { label.stringValue = text }
        return flipped
    }
}

/// A 3 pt track with an accent fill.
final class AccentLine: NSView {
    var value: Double = 0 { didSet { if value != oldValue { needsDisplay = true } } }

    override func draw(_ dirtyRect: NSRect) {
        let track = NSBezierPath(roundedRect: bounds, xRadius: bounds.height / 2, yRadius: bounds.height / 2)
        NSColor.tertiaryLabelColor.withAlphaComponent(0.35).setFill()
        track.fill()
        var filled = bounds
        filled.size.width = bounds.width * max(0, min(1, value))
        NSColor.controlAccentColor.setFill()
        NSBezierPath(roundedRect: filled, xRadius: bounds.height / 2, yRadius: bounds.height / 2).fill()
    }
}
