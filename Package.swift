// swift-tools-version: 5.8

import PackageDescription

let package = Package(
    name: "SKProcessRunner",
    platforms: [
        .macOS(.v12),
        .iOS(.v14),
    ],
    products: [
        .library(name: "SKProcessRunner", targets: ["SKProcessRunner"]),
    ],
    targets: [
        .target(name: "SKProcessRunner"),
        .testTarget(name: "SKProcessRunnerTests", dependencies: ["SKProcessRunner"]),
    ]
)
