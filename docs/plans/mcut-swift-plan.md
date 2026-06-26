# MCUT-Swift — Project Plan & Build Spec

A public Swift Package that wraps [cutdigital/mcut](https://github.com/cutdigital/mcut) — a C++ mesh cutting / boolean library — and exposes a clean Swift API for iOS and macOS, distributed as a **dynamic** binary `xcframework`.

This document is the working plan. It is meant to be handed to Claude Code and executed phase by phase. Each phase has a goal, the work, and an acceptance check.

---

## 1. Goal & non-goals

**Goal.** Ship a public, Swift-Package-Index-listed package that lets an iOS/macOS developer add one URL and write `import MCUT` to perform robust mesh booleans, slicing, and intersection queries — without ever touching CMake, C++, or mcut's raw C API.

**In scope**
- A Swifty wrapper API over mcut's C API (`include/mcut/mcut.h`).
- A prebuilt **dynamic** `xcframework` (iOS device, iOS simulator, macOS at minimum).
- CI that builds and publishes the binary on each version tag.
- LGPL-compliant packaging and clear licensing docs.
- Listing on the Swift Package Index.

**Out of scope (for v1)**
- Source-based SwiftPM build of mcut (we ship a prebuilt binary deliberately).
- visionOS / tvOS / Mac Catalyst slices (add later if needed).
- Any modification to mcut's own source (consume upstream unchanged).
- Mesh file parsing (OBJ/PLY/STL). The wrapper takes in-memory arrays; file decoding is the consumer's job.

---

## 2. Background — what we are wrapping

mcut is **C++ behind a flat C API**, modeled after OpenCL/Vulkan. There is **no mesh object and no file I/O** in the library. Key facts that shape the wrapper:

**The model.** You create a context, "dispatch" a cut between two meshes, then enumerate and read back result pieces ("connected components"). Every operation returns an `McResult` error code.

**Input** — two meshes (a *source* and a *cut* mesh), each as three plain C arrays:
- vertices: a flat coordinate buffer (`x,y,z,…`) as `float` or `double` (declared via a dispatch flag),
- face indices: a flat `uint32` array of all faces' vertex indices, concatenated,
- face sizes: a `uint32` array giving each face's vertex count (this is what enables arbitrary n-gons, not just triangles),
- plus the vertex/face counts.

Both meshes must be **manifold** (every edge used by 1–2 faces) with consistent winding. There is also a convenience variant, `mcDispatchPlanarSection`, that cuts against a plane (normal + offset) instead of a second mesh.

**Output** — connected components in four types: `FRAGMENT` (pieces of the source mesh — the main result), `PATCH` (pieces of the cut mesh, i.e. stencils), `SEAM` (an input with the intersection contour stitched in → intersection curves), `INPUT` (copies with provenance maps). For each piece you can read back data channels: vertices (`FLOAT`/`DOUBLE`), `FACE`, `FACE_SIZE`, `EDGE`, `TYPE`, `FRAGMENT_LOCATION`, `PATCH_LOCATION`, `SEAM_VERTEX`, `VERTEX_MAP`, `FACE_MAP`, `FACE_ADJACENT_FACE`, and `FACE_TRIANGULATION`(`_MAP`). Both "get" calls use a **two-pass idiom**: call once with a null buffer to get the byte count, allocate, call again to fill.

**Operations** (all from the one dispatch primitive, selected by `McDispatchFlags`):
1. Boolean union — fragments outside the other mesh, sealed from outside.
2. Boolean difference — source fragment outside the cut, sealed by the cut's inside patch.
3. Boolean intersection — fragments inside, sealed from inside.
4. Slicing / sectioning — cut by plane or mesh, optionally discard one side.
5. Splitting — partition one mesh by another.
6. Stenciling — extract cut-mesh silhouette patches.
7. Partial cuts — cut mesh does not fully pass through.
8. Intersection-curve extraction — pull just the seam geometry.

The three booleans are not separate calls — they are the same `mcDispatch` with different filter-flag combinations.

**Core functions to wrap:** `mcCreateContext` / `mcCreateContextWithHelpers`, `mcBindState` (config, e.g. general-position epsilon), `mcDispatch` / `mcDispatchPlanarSection`, `mcGetConnectedComponents`, `mcGetConnectedComponentData`, `mcReleaseConnectedComponents`, `mcReleaseContext`, plus `mcDebugMessageCallback` for diagnostics. The async `mcEnqueue*` + event family can be deferred past v1.

---

## 3. Repository structure

```
mcut-swift/                      ← the public repo (referenced by URL)
├── Package.swift                ← manifest: binaryTarget(Cmcut) + Swift target(MCUT)
├── README.md                    ← usage + licensing (dual-path)
├── LICENSE                      ← wrapper license (LGPL-3.0, see §7)
├── THIRD-PARTY/
│   ├── COPYING                  ← mcut GPL-3.0 text
│   ├── COPYING.LESSER           ← mcut LGPL-3.0 text
│   └── NOTICE                   ← attribution + pinned upstream source pointer
├── Sources/
│   └── MCUT/                    ← Swifty wrapper API (compiled by consumers)
├── Tests/
│   └── MCUTTests/               ← unit tests (cube ∩ plane, boolean sanity checks)
├── external/
│   └── mcut/                    ← git submodule, pinned to an upstream tag (e.g. v1.3.0)
├── scripts/
│   └── build-xcframework.sh     ← builds all slices (native CMake iOS), wraps frameworks, create-xcframework
│                                   NOTE: ios.toolchain.cmake dropped — native CMake handles iOS (see §9b findings)
├── Examples/
│   └── SampleApp/               ← tiny app proving import + a real cut, used to validate releases
└── .github/
    └── workflows/
        └── release.yml          ← CI: tag → build → release asset → bump manifest
```

**Two-artifact mental model.** The repo (source + `Package.swift`) and the **GitHub Release** (the `Cmcut.xcframework.zip` binary) together are "the package." Consumers reference only the repo URL; SwiftPM reads the manifest, downloads the release asset, links it. The submodule, scripts, and workflow are build-time machinery only you and CI ever run.

**Fork vs reference:** do **not** fork mcut. Pull it in as a submodule pinned to a release tag. Bumping versions is then a one-line submodule update. (CI-fetching the tag instead of a committed submodule also works.)

---

## 4. The dynamic build

We build dynamic from day one (no static-first stage) so the package is publicly shippable and LGPL-clean with zero rework.

**Good news:** mcut's own CMake already supports shared builds — `MCUT_BUILD_AS_SHARED_LIB` is **ON by default** and produces a position-independent shared library with the C-API symbols exported. No fork or source patch needed.

**The wrinkle:** mcut's shared build emits a bare `libmcut.dylib`. iOS requires dynamic code packaged as a `.framework` bundle, and that bundle is also what `xcodebuild -create-xcframework -framework` expects. So the pipeline is "build dylib → wrap into a `.framework`."

### Per-slice pipeline

> **Implemented (2026-06-25) with native CMake, not ios-cmake.** The commands below are kept for
> reference, but [scripts/build-xcframework.sh](../../scripts/build-xcframework.sh) actually uses
> `-DCMAKE_SYSTEM_NAME=iOS` + `-DCMAKE_OSX_SYSROOT` + `-DCMAKE_OSX_ARCHITECTURES`. The simulator
> slice builds **fat in one invocation** (`arm64;x86_64`) — no separate builds + `lipo`. See §9b.

Slices required for v1:
- iOS device — `arm64` (sysroot `iphoneos`)
- iOS simulator — `arm64;x86_64` fat (sysroot `iphonesimulator`, one build)
- macOS — `arm64` (sysroot `macosx`; x86_64 universal slice deferred — see §9b open items)

For each slice:

1. **Configure + build the dylib**
   ```bash
   cmake -B build-ios -S external/mcut \
     -DCMAKE_TOOLCHAIN_FILE=scripts/ios.toolchain.cmake -DPLATFORM=OS64 \
     -DMCUT_BUILD_AS_SHARED_LIB=ON \
     -DMCUT_BUILD_TESTS=OFF -DMCUT_BUILD_TUTORIALS=OFF \
     -DCMAKE_BUILD_TYPE=Release
   cmake --build build-ios --config Release
   ```

2. **Wrap the dylib into `Cmcut.framework`**
   ```bash
   FW=out/ios/Cmcut.framework
   mkdir -p "$FW/Headers" "$FW/Modules"
   cp build-ios/libmcut.dylib "$FW/Cmcut"
   install_name_tool -id @rpath/Cmcut.framework/Cmcut "$FW/Cmcut"
   cp external/mcut/include/mcut/mcut.h "$FW/Headers/"
   cat > "$FW/Modules/module.modulemap" <<'EOF'
   framework module Cmcut { header "mcut.h" export * }
   EOF
   # write Info.plist: CFBundleIdentifier, CFBundleExecutable=Cmcut,
   #   CFBundlePackageType=FMWK, CFBundleName=Cmcut, MinimumOSVersion,
   #   CFBundleSupportedPlatforms (e.g. [iPhoneOS] / [iPhoneSimulator] / [MacOSX])
   ```
   - iOS uses the **flat** framework layout above. macOS uses the **versioned** `Versions/A/…` layout — handle per-platform in the script.

3. **lipo simulator arches** — fuse the two simulator framework binaries into one fat Mach-O at `Cmcut.framework/Cmcut`.

4. **Create the xcframework**
   ```bash
   xcodebuild -create-xcframework \
     -framework out/ios/Cmcut.framework \
     -framework out/sim-fat/Cmcut.framework \
     -framework out/macos/Cmcut.framework \
     -output out/Cmcut.xcframework
   zip -r out/Cmcut.xcframework.zip out/Cmcut.xcframework
   swift package compute-checksum out/Cmcut.xcframework.zip
   ```

**Alternative considered:** letting CMake emit the framework directly via `FRAMEWORK TRUE` / `MACOSX_FRAMEWORK_IDENTIFIER` / `INSTALL_NAME_DIR "@rpath"`. Rejected for v1 because iOS framework emission from CMake is fiddly (default `Info.plist` is macOS-shaped). Script-side wrapping is more predictable.

**Symbol export note:** verify the C-API functions are exported from the dylib (default visibility). mcut's `MCAPI_ATTR`/`MCAPI_CALL` macros handle export; confirm with `nm -gU Cmcut.framework/Cmcut | grep mcDispatch` during bring-up.

---

## 5. Package.swift

```swift
// swift-tools-version:5.9
import PackageDescription

let package = Package(
    name: "MCUT",
    platforms: [.iOS(.v13), .macOS(.v11)],          // confirm minimums (see §9)
    products: [
        .library(name: "MCUT", targets: ["MCUT"])
    ],
    targets: [
        .binaryTarget(
            name: "Cmcut",
            url: "https://github.com/<you>/mcut-swift/releases/download/<tag>/Cmcut.xcframework.zip",
            checksum: "<filled by CI>"
        ),
        .target(
            name: "MCUT",
            dependencies: ["Cmcut"]
            // NOTE: dynamic framework links libc++ itself — no .linkedLibrary("c++") needed.
        ),
        .testTarget(name: "MCUTTests", dependencies: ["MCUT"])
    ]
)
```

- `Cmcut` = the binary framework / C module; `MCUT` = the Swift wrapper target that does `import Cmcut` and exposes the nice API. Keeps raw C symbols separate from the Swift surface.
- Because it's a **dynamic** framework, Xcode auto-embeds and signs it into the consumer's app bundle (Embed & Sign) — the LGPL-clean, replaceable structure.
- The `url` + `checksum` are written by CI after the build (see §6).

---

## 6. CI / release automation

GitHub Actions on a `macos-latest` runner (free minutes for public repos). Trigger on version-tag push (`v*`).

**Pipeline:** tag push → checkout (with submodule) → run `build-xcframework.sh` (all slices, wrap, lipo, create-xcframework) → zip → `swift package compute-checksum` → create GitHub Release and upload `Cmcut.xcframework.zip` as an asset → write the new `url` + `checksum` into `Package.swift` and commit.

**Checksum chicken-and-egg.** `Package.swift` needs a checksum that only exists after the build. Resolve with a two-phase release: build + upload the artifact first, then commit the manifest pointing at it. (Either commit the bumped manifest back to the tagged commit, or open a release PR — decide in Phase 4.)

**Acceptance:** a fresh checkout of the tagged commit, added as a dependency to a clean app, resolves and links with `import MCUT` working, with no manual steps.

---

## 7. Swift API design

Turn the C primitives into idiomatic Swift. Hide the two-pass byte-count dance and manual memory management entirely.

- **Mesh input:** `struct MCUTMesh { var vertices: [SIMD3<Float>]; var faceIndices: [UInt32]; var faceSizes: [UInt32] }` plus a triangle-only convenience init that fills `faceSizes` with `3`s. Consider a `Double` precision variant or a generic over scalar type.
- **Errors:** map `McResult` (`MC_INVALID_OPERATION`, `MC_INVALID_VALUE`, `MC_OUT_OF_MEMORY`) to a `throws` `MCUTError` enum.
- **Dispatch flags:** expose `McDispatchFlags` as a Swift `OptionSet`.
- **High-level operations:** thin methods that set the right filter-flag combination —
  `union(_:_:)`, `subtract(_:from:)`, `intersect(_:_:)`, `slice(_:by:)` / `section(_:plane:offset:)`, `split(_:by:)`, `stencil(...)`, `intersectionCurves(...)`.
- **Results:** each connected component → a struct exposing data channels (vertices, faces, face sizes, edges, location/seal metadata, provenance maps) as lazily-fetched properties.
- **Triangulation:** because mcut returns arbitrary polygons, expose the `FACE_TRIANGULATION` channel (or a `triangulated` accessor) so results can feed renderers/solvers directly.
- **Lifecycle:** wrap context + connected-component release in `deinit` / RAII so callers never leak.

### Target API shape (sketch — confirm names against the real header)

```swift
public struct MCUTMesh {
    public var vertices: [SIMD3<Float>]
    public var faceIndices: [UInt32]
    public var faceSizes:  [UInt32]
    public init(vertices: [SIMD3<Float>], faceIndices: [UInt32], faceSizes: [UInt32])
    public init(triangleVertices: [SIMD3<Float>], triangleIndices: [UInt32])  // fills faceSizes with 3s
}

// Additive bridges — separate files, never in the core type:
#if canImport(ModelIO)
extension MCUTMesh { public init(_ mesh: MDLMesh) throws;  public func mdlMesh() throws -> MDLMesh }
#endif
#if canImport(RealityKit)
@available(iOS 15, macOS 12, *)
extension MCUTMesh { public init(_ mesh: MeshResource) throws;  public func meshResource() throws -> MeshResource }
#endif

public final class MCUTContext {
    public init(flags: MCUTContextFlags = []) throws        // mcCreateContext; deinit -> mcReleaseContext
    public func bind(epsilon: Double) throws                 // mcBindState

    public func union(_ a: MCUTMesh, _ b: MCUTMesh) throws -> [MCUTComponent]
    public func subtract(_ b: MCUTMesh, from a: MCUTMesh) throws -> [MCUTComponent]
    public func intersect(_ a: MCUTMesh, _ b: MCUTMesh) throws -> [MCUTComponent]
    public func section(_ a: MCUTMesh, plane normal: SIMD3<Float>, offset: Float) throws -> [MCUTComponent]
    public func split(_ a: MCUTMesh, by b: MCUTMesh) throws -> [MCUTComponent]
    public func stencil(_ a: MCUTMesh, _ b: MCUTMesh) throws -> [MCUTComponent]
    public func intersectionCurves(_ a: MCUTMesh, _ b: MCUTMesh) throws -> [MCUTComponent]
}

public extension MCUTMesh {                                  // one-shot convenience, transient context
    func subtracting(_ other: MCUTMesh) throws -> [MCUTComponent]
}

public struct MCUTComponent {
    public let type: ComponentType                            // fragment / patch / seam / input
    public var vertices: [SIMD3<Float>] { get }               // lazily fetched; hides 2-pass byte-count
    public var faceIndices: [UInt32] { get }
    public var faceSizes:  [UInt32] { get }
    public var triangulated: (indices: [UInt32], faceCount: Int) { get }   // FACE_TRIANGULATION channel
    // + provenance maps / location metadata as needed
}
```

**Acceptance:** unit tests for "cube cut by a plane yields two sealed fragments" and a boolean sanity check (e.g. A − B vertex/face counts within expected bounds).

---

## 8. Licensing & compliance

> Not legal advice. LGPL-on-the-App-Store is contested terrain; get real legal review before any commercial reliance.

mcut is **LGPL v3** ("weak copyleft"). Our obligations as a redistributor and the consumer's path:

- **Dynamic linking is the compliance mechanism.** Shipping mcut as a dynamic, replaceable framework satisfies LGPL far more cleanly than static linking, which on iOS requires impractical relink provisions.
- **Bundle the license + attribution.** Include `COPYING` (GPL-3.0) and `COPYING.LESSER` (LGPL-3.0), a `NOTICE` crediting CutDigital, and a pointer to the **exact upstream source** built — the pinned submodule tag satisfies the "make the library source available" requirement.
- **Do not relicense mcut.** The wrapper's own code can be any LGPL-compatible license, but the distributed combination carries LGPL terms. License the wrapper LGPL-3.0 and say so. Do not market the package as "MIT-clean."
- **README dual-path** for consumers:
  - Open-source app → no issue.
  - Closed-source commercial app, LGPL route → use the dynamic framework, keep attribution + replaceability.
  - Closed-source commercial app, wanting static / no obligations → buy mcut's **commercial license from CutDigital**. Link it. We can't grant commercial static-linking rights ourselves — we don't own mcut.
- LGPL obligations trigger only on **distribution**. Iterating in a private repo triggers nothing; have all compliance pieces in place before flipping public.

---

## 9. Key decisions

### Locked (2026-06-25)

- **Upstream pin:** mcut **`v1.3.0`** (latest release). Re-pin later is a one-line submodule update.
- **API shape:** a **context object** (`MCUTContext`, RAII over `mcCreateContext`, releases in
  `deinit`) carrying the operation methods, plus thin static/`MCUTMesh`-extension conveniences that
  spin up a transient context for one-shot calls. (Rationale in §7.)
- **Index/size scalar type:** store mesh indices and face sizes as **`UInt32`**, matching mcut's
  `uint32_t`. Do **not** use Swift `UInt` (64-bit) — it forces a narrowing/widening copy of every
  index across the C boundary. Positions are `SIMD3<Float>` (see precision, still open).
- **Core struct is dependency-free.** `MCUTMesh` depends on nothing but `simd`, and the `MCUT`
  library pulls in no Apple-graphics frameworks. ModelIO and RealityKit interop are **additive
  bridges** guarded by `#if canImport(...)` + `@available`, shipped as a **separate opt-in library
  product `MCUTSwifty`** (target `Sources/MCUTSwifty/`, depends on `MCUT`) — so consumers who don't
  need the `MDLMesh` / `MeshResource` conversions don't pay for them.
- **Error model:** one `MCUTError: Error` (likely `LocalizedError`) spanning **both** mcut
  `McResult` codes **and** wrapper-side validation (empty/inconsistent mesh, bridge failures, no
  output). All C calls funnel through one `check(_ r: McResult) throws` helper. Exact case names
  come from the real `mcut.h`, not this doc.
- **Example surface:** ship interop demos as a **`.swiftpm` App Playground / `Examples/` SwiftUI
  app**, **not** a raw `.playground` file (binary xcframework + classic playground is flaky). The
  RealityKit demo uses SwiftUI `RealityView`, which requires a **recent OS (≈ iOS 18 / macOS 15 —
  confirm)**; that floor applies to the *example only*, above the package's own minimum. Older-OS
  fallback if needed: `ARView` via `UIViewRepresentable` / `NSViewRepresentable`.

- **Minimum deployment targets:** **iOS 18 / macOS 15** (locked 2026-06-25). Driven by the
  maintainer's consuming project (Swift 6, iOS 18+); macOS 15 pairs with the iOS 18 wave and is the
  floor SwiftUI `RealityView` needs. The dylib must be built with matching deployment targets
  (`CMAKE_OSX_DEPLOYMENT_TARGET` / ios-cmake `DEPLOYMENT_TARGET`) or the binary's `LC_BUILD_VERSION`
  won't match `Package.swift` and consumers below the floor can't load it. Lowering later = rebuild
  the binary with a lower target; reversible.
- **Swift tools version / language mode:** **6.0** (locked 2026-06-25). Build the wrapper in Swift 6
  mode from day one so the public API is `Sendable`/strict-concurrency clean — cheaper than
  retrofitting once the consuming project is already Swift 6.

### Still open

- **Scalar precision** of positions — `Float` only, `Double` only, or both? (Bridges currently
  assume `SIMD3<Float>`.)
- **Platforms for v1** — iOS + macOS only, or add Catalyst / visionOS / tvOS now?
- **Manifest bump strategy** — commit checksum to the tag vs. release PR.

### Interop & manifold caveat (design note)

ModelIO (`MDLMesh`) and RealityKit (`MeshResource`) interop is a first-class goal — it's what makes
this worth using over raw mcut. Provide both directions: `init(_:)` ingest and a
`meshResource()` / `mdlMesh()` egress. **Egress must go through the `FACE_TRIANGULATION` channel**
because mcut returns arbitrary n-gons and those APIs want triangles.

**The real landmine:** mcut requires **manifold input with consistent winding**, but meshes from
`MDLMesh` / `MeshResource` are frequently non-manifold (duplicated vertices at UV/normal seams).
A naive bridge will feed mcut meshes it rejects or mis-cuts, and it will look like our bug. Plan for
a **weld-by-position** pass in the ingest bridges; treat it as a fast-follow, not a v1-day-1 blocker,
and document the requirement loudly.

---

## 9b. De-risking spikes (run BEFORE any API work)

The Swift API design (§7) is worthless if the build → link → **load** chain doesn't hold. Validate
the riskiest assumptions with throwaway spikes first; each has a hard pass/fail and is allowed to
fail and kill the approach cheaply. Order = assumptions most likely to break, first.

Top three risks, in order: (1) mcut's shared build exports the C symbols cleanly for **iOS**, not
just macOS; (2) a **hand-wrapped framework loads at runtime on a real signed device** (Embed & Sign,
`@rpath`, code signature) — `swift test` on the Mac will NOT catch this; (3) mcut's **manifold input
requirement** vs. real-world meshes.

- **Spike 0 — does it even build? ✅ DONE (2026-06-25).** Submodule pinned `v1.3.0`; macOS shared
  `libmcut.dylib` built via cmake (`MCUT_BUILD_AS_SHARED_LIB=ON`). `nm -gU` shows 22 exported `mc*`
  symbols incl. `mcDispatch`, `mcCreateContext`, `mcGetConnectedComponents`, `mcReleaseContext`.
  `otool -L` confirms system-only deps (`libc++`, `libSystem`) — no `.linkedLibrary("c++")` needed.
- **Spike 1 — wrap + package. ✅ DONE.** [scripts/build-xcframework.sh](../../scripts/build-xcframework.sh)
  builds all three slices and wraps them → `Cmcut.xcframework` → checksum. Slices verified:
  `macos-arm64`, `ios-arm64_x86_64-simulator` (fat: x86_64+arm64), `ios-arm64` (minos 18.0).
- **Spike 2 — does it link? ✅ DONE.** `Package.swift` (local `binaryTarget(path:)`) + `MCUT` target
  (`import Cmcut`) + `MCUTTests.testContextSmoke` calling `mcCreateContext`/`mcReleaseContext`.
  `swift test` passes on the macOS host — the dynamic framework links, loads, and the C API is
  callable from Swift.
- **Spike 3 — does it load in a REAL app, simulator + device? ✅ DONE (make-or-break gate PASSED).**
  - **Simulator half ✅.** `xcodebuild test -scheme MCUT -destination 'platform=iOS Simulator,…'`
    on an iOS 18.5 sim (iPhone 16 Pro) ran `testContextSmoke` → **TEST SUCCEEDED**. Xcode selected the
    `ios-arm64_x86_64-simulator` slice, the dynamic `Cmcut.framework` loaded at runtime, and
    `mcCreateContext` returned `MC_NO_ERROR`. Proves load + C-callable on the iOS runtime, not just host.
  - **Device half ✅.** Real iPhone 14 Pro (iOS, arm64), `SampleApp/` SwiftUI app depending on the
    local package, signed + installed + launched via `devicectl`. Console: `SPIKE3_DEVICE
    mcCreateContext=0` — framework loaded on hardware, no dyld error, C call succeeded. The embedded
    `Cmcut.framework` is auto re-signed with the dev team. **This is where the rpath landmine surfaced**
    (see findings) — the simulator never caught it because it had a stale build-dir search path.
- **Spike 4 — does it actually cut? ✅ DONE.** `MCUT.spikeCutCubeWithPlane()` + `testCubePlaneCut`:
  a real `mcDispatch` cuts a unit cube with a 4×4 plane at y=0 → **2 unsealed FRAGMENT components**
  (above + below), each fragment's vertex/face counts read back via the two-pass byte-count idiom.
  Runs on the macOS host via `swift test` (no app needed — see note below). Two real API behaviors
  pinned down (see findings).
- **Spike 5 — distribution round-trip.** *(NEXT make-or-break gate — the last unproven leg.)* Every
  spike so far uses `binaryTarget(path:)` (local file). This proves the `binaryTarget(url:checksum:)`
  path: push the repo, cut the **first GitHub Release** carrying `Cmcut.xcframework.zip`, flip the
  manifest to `url:checksum:`, and confirm a build still links + loads. Three stages of realism:
  (A) local-path consumer ✅ *(SampleApp already did this)*; (B) remote binary, manifest flipped —
  **requires the push + release**; (C) a brand-new app adding the package by GitHub URL + tag,
  resolving from nothing. Footguns: checksum chicken-and-egg (upload asset *then* commit checksum),
  release-asset URL format, zip layout, public-vs-private repo access. ≈ Phase 4 (release automation).

Cutting works (Spike 4). The remaining gate is *distribution* (Spike 5). After both, `MCUTMesh`,
`MCUTError`, the operation methods, the ModelIO/RealityKit bridges, and the RealityView example earn
their keep (that work is Phase 5). Spikes 0–3 ≈ Phases 1–2; Spike 4 ≈ early Phase 3; Spike 5 ≈ Phase 4.

> **Note — cutting is testable host-side, no app required.** Because the package targets macOS too,
> the entire dispatch/readback path runs under `swift test` on the host. Device/simulator runs are only
> needed for the *load/packaging* gates (Spike 3), not for exercising new cutting functionality.

### Findings so far (build machinery)

- **Toolchain: native CMake iOS support, NOT leetal/ios-cmake.** `-DCMAKE_SYSTEM_NAME=iOS`
  `-DCMAKE_OSX_SYSROOT=iphoneos|iphonesimulator` `-DCMAKE_OSX_ARCHITECTURES=…` builds correct iOS
  slices. The simulator slice builds **fat (`arm64;x86_64`) in one cmake invocation** — no separate
  builds + `lipo` needed. This supersedes the §3/§4 plan of vendoring `scripts/ios.toolchain.cmake`.
- **Header quirk (handled without touching upstream):** `mcut.h` `#include`s sibling `platform.h`
  (bundle both into the framework `Headers/`), and uses `bool` with **no `<stdbool.h>`** (it's only
  ever compiled as C++ upstream). Fixed by generating our own umbrella header `Cmcut.h`
  (`#include <stdbool.h>` then `#include "mcut.h"`) and pointing the module map at `Cmcut.h`.
- **Swift import detail:** `McResult.rawValue` is `Int` (not `UInt32`); `McContext` imports as an
  optional opaque pointer; `mcCreateContext(&ctx, McFlags(0))`.
- **Deployment-target match matters:** native macOS build with no target baked in the host SDK
  (macOS 26) → linker warning vs `Package.swift`. Fixed by passing explicit
  `CMAKE_OSX_DEPLOYMENT_TARGET` (macOS 15 / iOS 18).
- **rpath landmine (the real Spike-3 catch): a consuming app must have `@executable_path/Frameworks`
  in `LD_RUNPATH_SEARCH_PATHS`.** A dynamic binary `xcframework` is *embedded* into the app under
  `App.app/Frameworks/`, but its install id is `@rpath/Cmcut.framework/Cmcut` — so without that rpath
  entry, **dyld can't find it and the app crashes at launch on device** (`Library not loaded:
  @rpath/Cmcut.framework/Cmcut`). Stock Xcode app templates set this; a hand-rolled project (or any
  consumer with a trimmed runpath) may not. *It does not fail on the macOS host or even the iOS
  simulator* if a build-dir `PackageFrameworks` path is still searchable — only a clean device load
  exposes it. Action items: (a) document this requirement for consumers in the README; (b) consider
  whether the framework's install id / packaging can be made more forgiving. The `SampleApp/` project
  sets `LD_RUNPATH_SEARCH_PATHS = ($(inherited), @executable_path/Frameworks)` and now loads cleanly.

### Findings so far (cutting / dispatch — from Spike 4)

- **General position must be enforced by default.** A perfectly axis-aligned source vs. axis-aligned
  cut mesh violates mcut's general-position assumption → `mcDispatch` returns `MC_INVALID_OPERATION`
  (`-2`) with an "incomplete kernel execution" log. Setting `MC_DISPATCH_ENFORCE_GENERAL_POSITION`
  (1<<15) makes mcut auto-perturb the cut mesh and succeed. **Design input for Phase 5:** axis-aligned
  meshes are the *common* case (boxes, planes, primitives), so the Swift wrapper should enable
  general-position enforcement by default rather than surfacing this as opt-in. (Perturbation amount
  is tunable via `mcBindState(MC_CONTEXT_GENERAL_POSITION_ENFORCEMENT_CONSTANT/_ATTEMPTS)`.)
- **`mcGetConnectedComponents` two-pass footgun:** the fetch (second) call must pass `nil` for the
  `numConnComps` out-param. Reusing the same variable that holds the entry count makes mcut overwrite
  it to 0 (the header's own example passes `NULL`). The RAII `MCUTContext` layer must hide this.
- **Fragment count semantics:** with `MC_DISPATCH_FILTER_ALL` a single through-cut yields **6**
  fragments = 2 locations (above/below) × 3 sealing modes (inside/outside/none), plus patches/seams.
  To get just the two geometric halves, filter `LOCATION_ABOVE | LOCATION_BELOW | SEALING_NONE`. The
  high-level ops (`union`/`subtract`/…) will each pick a specific filter-flag combination accordingly.

## 10. Phased implementation plan

**Phase 0 — Repo bring-up** — ✅ submodule pinned `v1.3.0`, `.gitignore` covers build artifacts,
plan in place. (License files / NOTICE still TODO before going public — Phase 6.)
- *Done when:* `git submodule status` shows the pinned tag and license files are present.

**Phase 1 — Build one slice by hand** — ✅ DONE (see §9b Spike 0). macOS dylib builds,
`mcDispatch` exported.

**Phase 2 — Framework wrapping + xcframework** — ✅ DONE (see §9b Spike 1). All three slices
(iOS device, iOS simulator fat, macOS) wrapped and `Cmcut.xcframework` + checksum produced via
[scripts/build-xcframework.sh](../../scripts/build-xcframework.sh). Used native CMake (no leetal
toolchain) and an umbrella header for the `bool`/`stdbool` quirk.

**Phase 3 — Package + minimal Swift wrapper** — ✅ DONE. `Package.swift` (local
`binaryTarget(path:)`, swift-tools 6.0, iOS 18/macOS 15), `MCUT` target (`import Cmcut`), context
smoke test (§9b Spike 2), and a real cube ∩ plane "hello cut" (§9b Spike 4) all pass via `swift
test`. `SampleApp/` proved on-device load (§9b Spike 3) — and flushed out the rpath landmine.
- *Done when:* ✅ `swift test` passes against the local xcframework (smoke + cube∩plane) and the
  SampleApp loads + runs on a real device.

**Phase 4 — CI release**
- Write `release.yml`: tag → build → upload release asset → bump `Package.swift` to remote `binaryTarget(url:checksum:)`.
- Cut `v0.1.0`.
- *Done when:* a clean external app depends on the tag and `import MCUT` works with zero manual steps.

**Phase 5 — Flesh out the API**
- Implement the operation methods (booleans, slice/section, split, stencil, intersection curves), error mapping, triangulation accessor, RAII lifecycle, broader tests.
- *Done when:* all eight operations are covered by tests and documented.

**Phase 6 — Docs, licensing, publish**
- Finalize README (usage + dual-path licensing), DocC if desired.
- Flip repo public; verify the release asset and repo resolve openly.
- Submit to Swift Package Index (form or PackageList PR), then claim via "Do you maintain this package?" and add badges.
- *Done when:* the package page builds green on SPI with a compatibility matrix.

---

## 11. Footguns reference

- **Simulator slice must be fat** (arm64 + x86_64 lipo'd) — an xcframework allows only one library per platform variant.
- **iOS framework layout is flat; macOS is versioned** — handle separately in the script.
- **Install name must be `@rpath/Cmcut.framework/Cmcut`** or the framework won't load from the app bundle.
- **Publish the release asset before submitting to SPI** — SPI builds your package and will fail on a missing/mismatched binary URL.
- **Private repo + binaryTarget URL** isn't fetchable by outsiders — don't share or list until public.
- **No `.linkedLibrary("c++")` needed for dynamic** (it was required for static) — the framework links libc++ itself.
- **Don't relicense** — the distributed combination is LGPL regardless of the wrapper's license.

---

## 12. References

- mcut: https://github.com/cutdigital/mcut — API header `include/mcut/mcut.h`
- ios-cmake toolchain: https://github.com/leetal/ios-cmake
- Swift Package Index — Add a Package: https://swiftpackageindex.com/add-a-package
- SPI requirements: public repo, valid root `Package.swift`, Swift 5.0+, ≥1 semantic-version tag, valid `swift package dump-package` output.
