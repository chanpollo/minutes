// swift-tools-version:5.10
import PackageDescription

let package = Package(
    name: "Minutes",
    platforms: [.macOS("14.2")],
    dependencies: [.package(url: "https://github.com/sparkle-project/Sparkle", exact: "2.10.1")],
    targets: [
        .executableTarget(name: "Minutes", dependencies: [.product(name: "Sparkle", package: "Sparkle")], path: "Sources/Minutes", linkerSettings: [.unsafeFlags(["-Xlinker", "-rpath", "-Xlinker", "@executable_path/../Frameworks"])]),
        .testTarget(name: "MinutesTests", dependencies: ["Minutes"], path: "Tests/MinutesTests"),
    ]
)
