// swift-tools-version:5.10
import PackageDescription

// Evaluation harness over the app's own Transcriber (run.sh copies Sources/Minutes in, minus main.swift); not part of
// the app.
let package = Package(
    name: "transcript-eval",
    platforms: [.macOS("14.2")],
    targets: [.executableTarget(name: "transcript-eval", path: "Sources/transcript-eval")]
)
