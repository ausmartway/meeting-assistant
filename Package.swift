// swift-tools-version: 5.10
import PackageDescription

let package = Package(
    name: "MeetingAssistant",
    platforms: [
        // macOS 14 (Sonoma) is the floor: EventKit full-access model,
        // ScreenCaptureKit audio capture, and the Vision OCR APIs we rely on.
        .macOS(.v14)
    ],
    products: [
        .executable(name: "MeetingAssistant", targets: ["MeetingAssistant"]),
        .library(name: "MeetingKit", targets: ["MeetingKit"]),
    ],
    dependencies: [
        // On-device speech-to-text (runs the encoder on the GPU/Neural Engine).
        .package(url: "https://github.com/argmaxinc/WhisperKit", from: "1.0.0"),
    ],
    targets: [
        // Core library: domain models, pure logic, and Apple-framework integrations.
        // Lives in a library target so the test target can import it.
        .target(
            name: "MeetingKit",
            dependencies: [
                .product(name: "WhisperKit", package: "WhisperKit"),
            ],
            path: "Sources/MeetingKit"
        ),
        // The menu-bar app executable.
        .executableTarget(
            name: "MeetingAssistant",
            dependencies: ["MeetingKit"],
            path: "Sources/MeetingAssistant"
        ),
        // Unit tests for the pure-logic modules.
        .testTarget(
            name: "MeetingKitTests",
            dependencies: ["MeetingKit"],
            path: "Tests/MeetingKitTests"
        ),
    ]
)
