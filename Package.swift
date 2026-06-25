// swift-tools-version:6.0
import PackageDescription

// SPIKE 5: release form — binaryTarget(url:checksum:) pointing at the GitHub
// Release asset. For local iteration, swap back to the path: form (see
// docs/plans/mcut-swift-plan.md §5). The checksum is the SHA-256 produced by
// `swift package compute-checksum out/Cmcut.xcframework.zip`.
let package = Package(
    name: "MCUT",
    platforms: [.iOS(.v18), .macOS(.v15)],
    products: [
        .library(name: "MCUT", targets: ["MCUT"])
    ],
    targets: [
        .binaryTarget(
            name: "Cmcut",
            url: "https://github.com/dariu5h/mcut-swift/releases/download/0.0.1/Cmcut.xcframework.zip",
            checksum: "ab1f01fd63ab82d6c3eadc5829173fd47d9afe5fecbc68845b753f97ff44cf10"
        ),
        .target(name: "MCUT", dependencies: ["Cmcut"]),
        .testTarget(name: "MCUTTests", dependencies: ["MCUT"])
    ]
)
