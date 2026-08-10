// swift-tools-version: 6.0

import PackageDescription

let package = Package(
    name: "LocalGemmaDispatch",
    platforms: [
        .iOS(.v17),
        .macOS(.v14)
    ],
    products: [
        .library(name: "DispatchCore", targets: ["DispatchCore"]),
        .library(name: "DispatchUI", targets: ["DispatchUI"]),
        .executable(name: "local-gemma-agent", targets: ["LocalGemmaAgent"])
    ],
    targets: [
        .target(name: "DispatchCore"),
        .target(
            name: "DispatchUI",
            dependencies: ["DispatchCore"]
        ),
        .executableTarget(
            name: "LocalGemmaAgent",
            dependencies: ["DispatchCore"]
        ),
        .testTarget(
            name: "DispatchCoreTests",
            dependencies: ["DispatchCore"]
        )
    ]
)
