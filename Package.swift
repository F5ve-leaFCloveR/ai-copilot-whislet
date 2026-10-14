// swift-tools-version: 6.1
import PackageDescription

let package = Package(
    name: "InterviewCopilot",
    platforms: [.macOS("15.5")],
    products: [
        .library(name: "CopilotCore", targets: ["CopilotCore"]),
        .executable(name: "InterviewCopilot", targets: ["InterviewCopilot"])
    ],
    targets: [
        .target(name: "CopilotCore"),
        .executableTarget(name: "InterviewCopilot", dependencies: ["CopilotCore"]),
        .testTarget(name: "CopilotCoreTests", dependencies: ["CopilotCore"]),
        .testTarget(name: "InterviewCopilotTests", dependencies: ["InterviewCopilot", "CopilotCore"])
    ],
    swiftLanguageModes: [.v6]
)
