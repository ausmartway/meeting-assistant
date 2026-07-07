// swift-tools-version: 5.10
import PackageDescription

let package = Package(
    name: "MeetingAssistant",
    platforms: [
        // macOS 26 (Tahoe) is the floor — the owner targets current-OS Macs only,
        // which lets the code use the latest SDK APIs unconditionally. (String
        // form because swift-tools-version 5.10 predates the .v26 enum case.)
        .macOS("26.0")
    ],
    products: [
        .executable(name: "MeetingAssistant", targets: ["MeetingAssistant"]),
        .library(name: "MeetingKit", targets: ["MeetingKit"]),
        // Dev-only CLI to benchmark transcription engines head-to-head on a wav.
        .executable(name: "TranscribeBench", targets: ["TranscribeBench"]),
    ],
    dependencies: [
        // On-device speech-to-text (runs the encoder on the GPU/Neural Engine).
        .package(url: "https://github.com/argmaxinc/WhisperKit", from: "1.0.0"),
        // On-device speaker diarization + enrollment (CoreML).
        .package(url: "https://github.com/FluidInference/FluidAudio", from: "0.5.0"),
    ],
    targets: [
        // Core library: domain models, pure logic, and Apple-framework integrations.
        // Lives in a library target so the test target can import it.
        .target(
            name: "MeetingKit",
            dependencies: [
                .product(name: "WhisperKit", package: "WhisperKit"),
                .product(name: "FluidAudio", package: "FluidAudio"),
            ],
            path: "Sources/MeetingKit"
        ),
        // The menu-bar app executable.
        .executableTarget(
            name: "MeetingAssistant",
            dependencies: ["MeetingKit"],
            path: "Sources/MeetingAssistant"
        ),
        // Dev-only benchmark CLI: compares WhisperKit vs Parakeet on one audio file.
        .executableTarget(
            name: "TranscribeBench",
            dependencies: ["MeetingKit"],
            path: "Sources/TranscribeBench"
        ),
        // Unit tests for the pure-logic modules.
        .testTarget(
            name: "MeetingKitTests",
            dependencies: ["MeetingKit"],
            path: "Tests/MeetingKitTests"
        ),
    ]
)
