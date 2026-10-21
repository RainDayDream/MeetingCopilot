// swift-tools-version:5.9
import PackageDescription

let package = Package(
    name: "MeetingCopilot",
    platforms: [.macOS(.v14)],
    dependencies: [
        .package(url: "https://github.com/argmaxinc/WhisperKit.git", from: "0.9.0")
    ],
    targets: [
        // 与 UI、设置、系统权限无关的核心逻辑：转写、轮次切分、自动触发判断、上下文组装。可在命令行测试与评测。
        .target(name: "MeetingCopilotCore",
                dependencies: [.product(name: "WhisperKit", package: "WhisperKit")],
                path: "Sources/MeetingCopilotCore"),
        .executableTarget(name: "MeetingCopilot",
                          dependencies: ["MeetingCopilotCore", .product(name: "WhisperKit", package: "WhisperKit")],
                          path: "Sources/MeetingCopilot"),
        .testTarget(name: "MeetingCopilotCoreTests",
                    dependencies: ["MeetingCopilotCore"],
                    path: "Tests/MeetingCopilotCoreTests"),
    ]
)
