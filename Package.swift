// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "Clipflow",
    defaultLocalization: "en",
    platforms: [.macOS(.v14)],
    products: [
        // 核心引擎：零 UI 依赖，可被 App / CLI / 测试 / 未来任何 Shell 复用
        .library(name: "ClipflowCore", targets: ["ClipflowCore"]),
        // 捕获层：唯一允许 import AppKit 的非 UI 目标（NSPasteboard 在 AppKit 里）
        .library(name: "ClipflowCapture", targets: ["ClipflowCapture"]),
        // CLI 不是附赠品——它是「Core 真的零 UI 依赖」的强制验证
        .executable(name: "clipflow", targets: ["ClipflowCLI"]),
        // 真正能用的 App：菜单栏 + 全局热键 + 鼠标旁面板 + 粘回原应用
        .executable(name: "ClipflowApp", targets: ["ClipflowApp"]),
    ],
    dependencies: [
        .package(url: "https://github.com/groue/GRDB.swift.git", from: "7.0.0"),
    ],
    targets: [
        .target(
            name: "ClipflowCore",
            dependencies: [.product(name: "GRDB", package: "GRDB.swift")],
            // Core 也有面向用户的字符串（类型名、保留期档位），要跟界面一起换语言。
            // Foundation 的本地化不违反「Core 禁 import AppKit/SwiftUI」那条硬规则。
            resources: [.process("Resources")],
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
        .executableTarget(
            name: "ClipflowApp",
            dependencies: ["ClipflowCore", "ClipflowCapture"],
            resources: [.process("Resources")],
            swiftSettings: [.swiftLanguageMode(.v6)]
        ),
        .testTarget(
            name: "ClipflowCoreTests",
            dependencies: ["ClipflowCore"],
            swiftSettings: [.swiftLanguageMode(.v6)]
        ),
        // 捕获层的测试单独一个 target：ClipflowCoreTests 里有一条硬禁 import AppKit
        // 的约束测试，而这里必须碰 NSPasteboard。
        .testTarget(
            name: "ClipflowCaptureTests",
            dependencies: ["ClipflowCapture", "ClipflowCore"],
            swiftSettings: [.swiftLanguageMode(.v6)]
        ),
    ]
)
