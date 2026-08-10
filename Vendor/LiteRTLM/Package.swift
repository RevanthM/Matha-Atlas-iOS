// swift-tools-version: 5.9
// This local package avoids an upstream Git-LFS checkout failure in the LiteRT-LM 0.15.0 tag.
// The wrapper sources and binary checksum are unchanged from Google's official Package.swift.

import PackageDescription

let package = Package(
    name: "LiteRTLM",
    platforms: [.iOS(.v15)],
    products: [
        .library(name: "LiteRTLM", targets: ["LiteRTLM"])
    ],
    targets: [
        .binaryTarget(
            name: "CLiteRTLM",
            url: "https://github.com/google-ai-edge/LiteRT-LM/releases/download/v0.15.0/CLiteRTLM.xcframework.zip",
            checksum: "d6ccf6b54362d894ff71a7580c7e446d36767dab908aecfbb16ffca0fa0bc59b"
        ),
        .target(
            name: "LiteRTLM",
            dependencies: ["CLiteRTLM"],
            path: "Sources/LiteRTLM"
        )
    ]
)
