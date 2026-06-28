// swift-tools-version:6.0
import PackageDescription

// Release form — binaryTarget(url:checksum:) pointing at the GitHub Release asset. For local
// iteration, swap back to the path: form (`.binaryTarget(name: "Cmcut", path: "out/Cmcut.xcframework")`).
// The checksum is the SHA-256 produced by `swift package compute-checksum out/Cmcut.xcframework.zip`.
let package = Package(
    name: "MCUT",
    platforms: [.iOS(.v18), .macOS(.v15)],
    products: [
        .library(name: "MCUT", targets: ["MCUT"]),
        // Opt-in Apple-graphics interop (Model I/O + RealityKit). Kept out of MCUT so the core
        // stays dependency-light; import it only when you need MDLMesh/MeshResource conversions.
        .library(name: "MCUTSwifty", targets: ["MCUTSwifty"])
    ],
    targets: [
        .binaryTarget(
            name: "Cmcut",
            url: "https://github.com/dariu5h/mcut-swift/releases/download/0.0.6/Cmcut.xcframework.zip",
            checksum: "0a16593030e58a9bfeb5854dbf911c160fdaea2dfc86798541b8c4a3852d34dc"
        ),
        .target(name: "MCUT", dependencies: ["Cmcut"]),
        .target(name: "MCUTSwifty", dependencies: ["MCUT"]),
        .testTarget(name: "MCUTTests", dependencies: ["MCUT"])
    ]
)
