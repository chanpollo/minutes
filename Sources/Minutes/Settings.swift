import Foundation

/// Every user setting in one place; the Settings window and the code that acts on a setting both read these.
enum Settings {
    private static let defaults = UserDefaults.standard

    private static func bool(_ key: String, _ fallback: Bool) -> Bool { defaults.object(forKey: key) as? Bool ?? fallback }
    private static func int(_ key: String, _ fallback: Int) -> Int { defaults.object(forKey: key) as? Int ?? fallback }
    private static func string(_ key: String, _ fallback: String) -> String { defaults.string(forKey: key) ?? fallback }

    // MARK: Recording

    // recordMode and appModes are in RecordModes.swift.

    enum VideoQuality: String, CaseIterable { case smaller, balanced, best }
    /// Every preset keeps the captured window's full pixel size; only the encoder's quality target changes.
    static var videoQuality: VideoQuality {
        get { VideoQuality(rawValue: string("videoQuality", "balanced")) ?? .balanced }
        set { defaults.set(newValue.rawValue, forKey: "videoQuality") }
    }

    static var autoStopSeconds: Int {
        get { max(5, int("autoStopSeconds", 30)) }
        set { defaults.set(newValue, forKey: "autoStopSeconds") }
    }

    /// Owner bundle IDs that start recording without the prompt ("Always record <App>").
    static var alwaysRecord: [String] {
        get { defaults.stringArray(forKey: "alwaysRecord") ?? [] }
        set { defaults.set(newValue, forKey: "alwaysRecord") }
    }

    static var titleFromCalendar: Bool {
        get { bool("titleFromCalendar", true) }
        set { defaults.set(newValue, forKey: "titleFromCalendar") }
    }

    static var separateSpeakers: Bool {
        get { bool("separateSpeakers", true) }
        set { defaults.set(newValue, forKey: "separateSpeakers") }
    }

    /// What whisper is told the meeting is spoken in. Detection picks English on quiet Thai audio and then loops.
    enum SpeechLanguage: String, CaseIterable {
        case thai, english, detect

        var code: String {
            switch self {
            case .thai: "th"
            case .english: "en"
            case .detect: "auto"
            }
        }
    }

    static var speechLanguage: SpeechLanguage {
        get { SpeechLanguage(rawValue: string("speechLanguage", "")) ?? defaultSpeechLanguage(for: Locale.preferredLanguages) }
        set { defaults.set(newValue.rawValue, forKey: "speechLanguage") }
    }

    /// Thai when the Mac's languages hold a Thai one (en-TH is English in Thailand, th-TH is Thai), else detection.
    static func defaultSpeechLanguage(for preferred: [String]) -> SpeechLanguage {
        preferred.contains { Locale(identifier: $0).language.languageCode?.identifier == "th" } ? .thai : .detect
    }

    // MARK: Summary

    enum SummaryProvider: String, CaseIterable {
        case claude, codex, agy, ollama, off

        init(_ engine: SummaryModel.Provider) {
            switch engine {
            case .claude: self = .claude
            case .codex: self = .codex
            case .agy: self = .agy
            case .ollama: self = .ollama
            }
        }

        var engine: SummaryModel.Provider? {
            switch self {
            case .claude: .claude
            case .codex: .codex
            case .agy: .agy
            case .ollama: .ollama
            case .off: nil
            }
        }
    }
    static var summaryProvider: SummaryProvider {
        get { SummaryProvider(rawValue: string("summaryProvider", "claude")) ?? .claude }
        set { defaults.set(newValue.rawValue, forKey: "summaryProvider") }
    }

    enum SummaryLanguage: String, CaseIterable { case thai, english, meeting }
    static var summaryLanguage: SummaryLanguage {
        get { SummaryLanguage(rawValue: string("summaryLanguage", "thai")) ?? .thai }
        set { defaults.set(newValue.rawValue, forKey: "summaryLanguage") }
    }

    /// Off by default: the owner wants summaries on request.
    static var autoSummarise: Bool {
        get { bool("autoSummarise", false) }
        set { defaults.set(newValue, forKey: "autoSummarise") }
    }

    /// Slides and shared screens from the video, placed under the summary point they show; their text goes with the
    /// transcript.
    static var summaryPictures: Bool {
        get { bool("summaryPictures", true) }
        set { defaults.set(newValue, forKey: "summaryPictures") }
    }

    /// New meetings with an invitee outside the user's own email domain start as confidential (not sent for summary).
    static var confidentialExternal: Bool {
        get { bool("confidentialExternal", true) }
        set { defaults.set(newValue, forKey: "confidentialExternal") }
    }

    /// The spoken briefing of a summary: made only when asked, after every summary, or never.
    enum BriefingMode: String, CaseIterable { case off, request, after }
    static var briefingMode: BriefingMode {
        get { BriefingMode(rawValue: string("briefingMode", "request")) ?? .request }
        set { defaults.set(newValue.rawValue, forKey: "briefingMode") }
    }

    /// AVSpeechSynthesisVoice identifiers; nil or a voice no longer installed falls back to the best one installed.
    static var briefingVoiceThai: String? {
        get { defaults.string(forKey: "briefingVoiceThai") }
        set { defaults.set(newValue, forKey: "briefingVoiceThai") }
    }

    static var briefingVoiceEnglish: String? {
        get { defaults.string(forKey: "briefingVoiceEnglish") }
        set { defaults.set(newValue, forKey: "briefingVoiceEnglish") }
    }

    /// 0 slowest … 4 fastest, 2 normal; for newly made briefings and Preview.
    static var briefingRate: Int {
        get { min(4, max(0, int("briefingRate", 2))) }
        set { defaults.set(newValue, forKey: "briefingRate") }
    }

    /// Playback speed step: 1×, 1.25×, 1.5×.
    static var briefingSpeed: Int {
        get { min(2, max(0, int("briefingSpeed", 0))) }
        set { defaults.set(newValue, forKey: "briefingSpeed") }
    }

    // MARK: Storage

    /// 0 keeps forever.
    static var keepVideoDays: Int {
        get { max(0, int("keepVideoDays", 90)) }
        set { defaults.set(newValue, forKey: "keepVideoDays") }
    }

    /// 0 keeps forever. Audio tracks are only removed once a transcript exists.
    static var keepAudioDays: Int {
        get { max(0, int("keepAudioDays", 0)) }
        set { defaults.set(newValue, forKey: "keepAudioDays") }
    }

    /// Lossless: the tracks are re-encoded to FLAC after transcription.
    static var compressAudio: Bool {
        get { bool("compressAudio", true) }
        set { defaults.set(newValue, forKey: "compressAudio") }
    }

    // MARK: Sync

    enum SyncMode: String, CaseIterable { case off, folder, googleDrive }
    /// Unset until the first launch with Sync decides it (`Sync.migrate`).
    static var syncMode: SyncMode {
        get { SyncMode(rawValue: string("syncMode", "off")) ?? .off }
        set { defaults.set(newValue.rawValue, forKey: "syncMode") }
    }

    static var syncModeChosen: Bool { defaults.string(forKey: "syncMode") != nil }

    /// The folder a sync app uploads; copies go to its Minutes sub-folder.
    static var syncFolder: String? {
        get { defaults.string(forKey: "syncFolder").flatMap { $0.isEmpty ? nil : $0 } }
        set { defaults.set(newValue, forKey: "syncFolder") }
    }

    static var syncFolderPerGroup: Bool {
        get { bool("syncFolderPerGroup", true) }
        set { defaults.set(newValue, forKey: "syncFolderPerGroup") }
    }

    /// Synced copies go too when the meeting is deleted here or clean-up deletes a file; for either kind of sync.
    static var deleteOnDrive: Bool {
        get { bool("deleteOnDrive", false) }
        set { defaults.set(newValue, forKey: "deleteOnDrive") }
    }

    // Kept under their Drive-era keys; they choose the files for either kind of sync.
    static var driveUploadText: Bool {
        get { bool("driveUploadText", true) }
        set { defaults.set(newValue, forKey: "driveUploadText") }
    }

    static var driveUploadMedia: Bool {
        get { bool("driveUploadMedia", true) }
        set { defaults.set(newValue, forKey: "driveUploadMedia") }
    }
}
