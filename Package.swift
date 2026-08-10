// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "Clipflow",
    platforms: [.macOS(.v14)],
    products: [
        // 核心引擎：零 UI 依赖，可被 App / CLI / 测试 / 未来任何 Shell 复用
        .library(name: "ClipflowCore", targets: ["ClipflowCore"]),
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
        .executableTarget(
            name: "ClipflowCLI",
            dependencies: ["ClipflowCore"],
            swiftSettings: [.swiftLanguageMode(.v6)]
        ),
        .testTarget(
            name: "ClipflowCoreTests",
            dependencies: ["ClipflowCore"],
            swiftSettings: [.swiftLanguageMode(.v6)]
        ),
    ]
)
