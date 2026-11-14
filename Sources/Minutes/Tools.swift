import Foundation

/// Where the helper programs are. A team build carries them inside the app; a developer build uses setup.sh's copies.
enum Tools {
    static let support = FileManager.default.homeDirectoryForCurrentUser
        .appendingPathComponent("Library/Application Support/Minutes")

    static func whisper() -> String? {
        first([
            bundled("bin/whisper-cli"),
            "/opt/homebrew/bin/whisper-cli",
            "/usr/local/bin/whisper-cli",
        ])
    }

    static func diarizer() -> String? {
        first([
            bundled("sherpa-onnx/bin/sherpa-onnx-offline-speaker-diarization"),
            support.appendingPathComponent("tools/sherpa-onnx/bin/sherpa-onnx-offline-speaker-diarization").path,
        ])
    }

    private static func bundled(_ path: String) -> String? {
        Bundle.main.resourceURL?.appendingPathComponent(path).path
    }

    private static func first(_ paths: [String?]) -> String? {
        paths.compactMap { $0 }.first(where: FileManager.default.isExecutableFile(atPath:))
    }
}
