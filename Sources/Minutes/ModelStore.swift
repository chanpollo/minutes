import CryptoKit
import Foundation

struct ModelError: LocalizedError {
    let message: String
    var errorDescription: String? { message }
}

/// Downloads the speech and speaker models into Transcriber.modelsDir. The app ships without them (~610 MB).
final class ModelStore: NSObject, URLSessionDownloadDelegate, @unchecked Sendable {
    struct Model {
        let file: URL
        let source: URL
        let size: Int64
        let sha256: String
        /// Bytes on the wire, for progress: the archive's size when `archive` is set.
        let downloadSize: Int64
        /// A tar.bz2 source: the archive's hash and `file`'s path inside it.
        var archive: (sha256: String, member: String)?
        let transcription: Bool

        // Not URL.resourceValues: a URL caches them, so a file deleted later would still look present.
        var isPresent: Bool {
            let attributes = try? FileManager.default.attributesOfItem(atPath: file.path)
            return (attributes?[.size] as? NSNumber)?.int64Value == size
        }
    }

    enum State: Equatable {
        case idle
        case downloading(percent: Int)
        case failed(String)
    }

    // Transcription models first: a meeting waiting to be transcribed only needs those.
    static let all: [Model] = [
        Model(
            file: Transcriber.vadModel,
            source: URL(string: "https://huggingface.co/ggml-org/whisper-vad/resolve/main/ggml-silero-v5.1.2.bin")!,
            size: 885_098, sha256: "29940d98d42b91fbd05ce489f3ecf7c72f0a42f027e4875919a28fb4c04ea2cf",
            downloadSize: 885_098, transcription: true),
        Model(
            file: Transcriber.model,
            source: URL(string: "https://huggingface.co/ggerganov/whisper.cpp/resolve/main/ggml-large-v3-turbo-q5_0.bin")!,
            size: 574_041_195, sha256: "394221709cd5ad1f40c46e6031ca61bce88931e6e088c188294c6d5a55ffa7e2",
            downloadSize: 574_041_195, transcription: true),
        Model(
            file: Diarizer.segmentationModel,
            source: URL(string: "https://github.com/k2-fsa/sherpa-onnx/releases/download/speaker-segmentation-models/sherpa-onnx-pyannote-segmentation-3-0.tar.bz2")!,
            size: 5_992_913, sha256: "220ad67ca923bef2fa91f2390c786097bf305bceb5e261d4af67b38e938e1079",
            downloadSize: 6_958_444,
            archive: ("24615ee884c897d9d2ba09bb4d30da6bb1b15e685065962db5b02e76e4996488",
                      "sherpa-onnx-pyannote-segmentation-3-0/model.onnx"),
            transcription: false),
        Model(
            file: Diarizer.embeddingModel,
            source: URL(string: "https://github.com/k2-fsa/sherpa-onnx/releases/download/speaker-recongition-models/3dspeaker_speech_campplus_sv_zh_en_16k-common_advanced.onnx")!,
            size: 28_281_164, sha256: "aa3cfc16963a10586a9393f5035d6d6b57e98d358b347f80c2a30bf4f00ceba2",
            downloadSize: 28_281_164, transcription: false),
    ]

    /// Speaker models only matter while speakers are separated.
    static var wanted: [Model] {
        Diarizer.isEnabled ? all : all.filter(\.transcription)
    }

    static var missing: [Model] { wanted.filter { !$0.isPresent } }

    /// The model rows of Settings › Storage.
    struct Row {
        let title: String
        let detail: String
        let models: [Model]
        var isInstalled: Bool { models.allSatisfy(\.isPresent) }
    }

    static let rows: [Row] = {
        let megabytes = { (models: ArraySlice<Model>) in "\(Int((Double(models.reduce(0) { $0 + $1.downloadSize }) / 1e6).rounded())) MB" }
        return [
            Row(title: "Speech model", detail: "large-v3-turbo q5_0 · \(megabytes(all[1...1]))", models: [all[1]]),
            Row(title: "Silence filter", detail: "Silero VAD v5.1.2", models: [all[0]]),
            Row(title: "Speaker models", detail: "pyannote 3.0 + CAM++ · \(megabytes(all[2...3]))", models: Array(all[2...3])),
        ]
    }()

    static let shared = ModelStore()

    /// Main thread only.
    private(set) var state = State.idle
    var onChange: (() -> Void)?
    var onProgress: (() -> Void)?

    var isDownloading: Bool {
        if case .downloading = state { return true }
        return false
    }

    var statusText: String? {
        switch state {
        case .idle: nil
        case .downloading(let percent): "Downloading speech models… \(percent)%"
        case .failed(let message): "Model download failed: \(message)"
        }
    }

    private let queue: OperationQueue = {
        let queue = OperationQueue()
        queue.maxConcurrentOperationCount = 1
        return queue
    }()
    private lazy var session: URLSession = {
        let configuration = URLSessionConfiguration.default
        configuration.waitsForConnectivity = false
        return URLSession(configuration: configuration, delegate: self, delegateQueue: queue)
    }()

    // Touched on `queue` only.
    private var pending: [Model] = []
    private var current: Model?
    private var installError: Error?
    private var bytesDone: Int64 = 0
    private var bytesTotal: Int64 = 0
    private var lastPercent = -1
    private var resumeData: [URL: Data] = [:]

    private let transcriptionLock = NSCondition()
    private var fetchingTranscription = false

    /// Main thread. Starts downloading whatever is missing; does nothing while a download runs.
    func start() {
        guard !isDownloading else { return }
        let models = Self.missing
        guard !models.isEmpty else {
            if state != .idle { setState(.idle) }
            return
        }
        setFetchingTranscription(models.contains(where: \.transcription))
        setState(.downloading(percent: 0))
        queue.addOperation { [self] in
            pending = models
            bytesDone = 0
            bytesTotal = models.reduce(0) { $0 + $1.downloadSize }
            lastPercent = 0
            next()
        }
    }

    /// Blocks until the whisper models are on disk or their download has stopped. Never call it on the main thread.
    func waitForTranscriptionModels() {
        transcriptionLock.lock()
        while fetchingTranscription { transcriptionLock.wait() }
        transcriptionLock.unlock()
    }

    private func setFetchingTranscription(_ value: Bool) {
        transcriptionLock.lock()
        fetchingTranscription = value
        transcriptionLock.broadcast()
        transcriptionLock.unlock()
    }

    private func setState(_ state: State) {
        self.state = state
        onChange?()
    }

    private func next() {
        if !pending.contains(where: \.transcription) { setFetchingTranscription(false) }
        guard !pending.isEmpty else {
            current = nil
            DispatchQueue.main.async { self.setState(.idle) }
            return
        }
        let model = pending.removeFirst()
        current = model
        installError = nil
        let task = resumeData.removeValue(forKey: model.source).map(session.downloadTask(withResumeData:))
            ?? session.downloadTask(with: model.source)
        task.resume()
    }

    private func fail(_ error: Error) {
        pending = []
        current = nil
        setFetchingTranscription(false)
        let message = error.localizedDescription
        NSLog("Minutes: model download failed: %@", message)
        DispatchQueue.main.async { self.setState(.failed(message)) }
    }

    // MARK: URLSessionDownloadDelegate

    func urlSession(
        _ session: URLSession, downloadTask: URLSessionDownloadTask, didWriteData bytesWritten: Int64,
        totalBytesWritten: Int64, totalBytesExpectedToWrite: Int64
    ) {
        guard bytesTotal > 0 else { return }
        let percent = Int(min(99, (bytesDone + totalBytesWritten) * 100 / bytesTotal))
        guard percent != lastPercent else { return }
        lastPercent = percent
        DispatchQueue.main.async {
            guard self.isDownloading else { return }
            self.state = .downloading(percent: percent)
            self.onProgress?()
        }
    }

    func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask, didFinishDownloadingTo location: URL) {
        guard let model = current else { return }
        // The system deletes `location` when this returns, so the file is moved first and checked afterwards.
        do {
            // 206 is a resumed download; the checksum below covers the whole file.
            if let http = downloadTask.response as? HTTPURLResponse, ![200, 206].contains(http.statusCode) {
                throw ModelError(message: "\(model.source.lastPathComponent): HTTP \(http.statusCode)")
            }
            let part = Transcriber.modelsDir.appendingPathComponent(model.source.lastPathComponent + ".part")
            try FileManager.default.createDirectory(at: Transcriber.modelsDir, withIntermediateDirectories: true)
            try? FileManager.default.removeItem(at: part)
            try FileManager.default.moveItem(at: location, to: part)
            defer { try? FileManager.default.removeItem(at: part) }
            try Self.install(model, from: part)
        } catch {
            installError = error
        }
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        guard let model = current else { return }
        if let error {
            if let data = (error as NSError).userInfo[NSURLSessionDownloadTaskResumeData] as? Data {
                resumeData[model.source] = data
            }
            fail(error)
        } else if let installError {
            fail(installError)
        } else {
            bytesDone += model.downloadSize
            next()
        }
    }

    // MARK: Install

    static func install(_ model: Model, from download: URL) throws {
        let files = FileManager.default
        var source = download
        var scratch: URL?
        defer { scratch.map { try? files.removeItem(at: $0) } }

        if let archive = model.archive {
            try verify(download, sha256: archive.sha256, name: model.source.lastPathComponent)
            let folder = Transcriber.modelsDir.appendingPathComponent(".extract-\(UUID().uuidString)")
            scratch = folder
            try files.createDirectory(at: folder, withIntermediateDirectories: true)
            let tar = Process()
            tar.executableURL = URL(fileURLWithPath: "/usr/bin/tar")
            tar.arguments = ["-xjf", download.path, "-C", folder.path, archive.member]
            tar.standardOutput = FileHandle.nullDevice
            tar.standardError = FileHandle.nullDevice
            try tar.run()
            tar.waitUntilExit()
            guard tar.terminationStatus == 0 else {
                throw ModelError(message: "\(model.source.lastPathComponent) could not be unpacked")
            }
            source = folder.appendingPathComponent(archive.member)
        }

        try verify(source, sha256: model.sha256, name: model.file.lastPathComponent)
        try files.createDirectory(at: model.file.deletingLastPathComponent(), withIntermediateDirectories: true)
        if files.fileExists(atPath: model.file.path) {
            _ = try files.replaceItemAt(model.file, withItemAt: source)
        } else {
            try files.moveItem(at: source, to: model.file)
        }
    }

    static func verify(_ file: URL, sha256 expected: String, name: String) throws {
        guard try sha256(of: file) == expected else { throw ModelError(message: "\(name) is damaged (checksum mismatch)") }
    }

    static func sha256(of file: URL) throws -> String {
        let handle = try FileHandle(forReadingFrom: file)
        defer { try? handle.close() }
        var hash = SHA256()
        while let chunk = try handle.read(upToCount: 4 << 20), !chunk.isEmpty {
            hash.update(data: chunk)
        }
        return hash.finalize().map { String(format: "%02x", $0) }.joined()
    }
}
