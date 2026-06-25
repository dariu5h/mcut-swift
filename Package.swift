// swift-tools-version:6.0
import PackageDescription

// SPIKE 2: local binaryTarget(path:) for fast iteration. CI rewrites this to
// .binaryTarget(url:checksum:) at release time (see docs/plans/mcut-swift-plan.md §5).
let package = Package(
    name: "MCUT",
    platforms: [.iOS(.v18), .macOS(.v15)],
    products: [
        .library(name: "MCUT", targets: ["MCUT"])
    ],
    targets: [
        .binaryTarget(name: "Cmcut", path: "out/Cmcut.xcframework"),
        .target(name: "MCUT", dependencies: ["Cmcut"]),
        .testTarget(name: "MCUTTests", dependencies: ["MCUT"])
    ]
)
