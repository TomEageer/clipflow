// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "Clipflow",
    platforms: [.macOS(.v14)],
    products: [
        // 核心引擎：零 UI 依赖，可被 App / CLI / 测试 / 未来任何 Shell 复用
        .library(name: "ClipflowCore", targets: ["ClipflowCore"]),
        // 捕获层：唯一允许 import AppKit 的非 UI 目标（NSPasteboard 在 AppKit 里）
        .library(name: "ClipflowCapture", targets: ["ClipflowCapture"]),
        // CLI 不是附赠品——它是「Core 真的零 UI 依赖」的强制验证
        .executable(name: "clipflow", targets: ["ClipflowCLI"]),
    ],
    dependencies: [
        .package(url: "https://github.com/groue/GRDB.swift.git", from: "7.0.0"),
    ],
    targets: [
        .target(
            name: "ClipflowCore",
            dependencies: [.product(name: "GRDB", package: "GRDB.swift")],
            swiftSettings: [.swiftLanguageMode(.v6)]
        ),
        // NSPasteboard 住在 AppKit 里，而 ClipflowCore 有测试硬禁 import AppKit。
        // 所以捕获层单独成 target —— 约束不是绕过，是用架构满足。
        .target(
            name: "ClipflowCapture",
            dependencies: ["ClipflowCore"],
            swiftSettings: [.swiftLanguageMode(.v6)]
        ),
        .executableTarget(
            name: "ClipflowCLI",
            dependencies: ["ClipflowCore", "ClipflowCapture"],
            swiftSettings: [.swiftLanguageMode(.v6)]
        ),
        .testTarget(
            name: "ClipflowCoreTests",
            dependencies: ["ClipflowCore"],
            swiftSettings: [.swiftLanguageMode(.v6)]
        ),
    ]
)
