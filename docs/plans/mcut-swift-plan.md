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
│   ├── build-xcframework.sh     ← builds all slices, wraps frameworks, lipo, create-xcframework
│   └── ios.toolchain.cmake      ← leetal/ios-cmake toolchain (vendored or fetched)
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

Slices required for v1:
- iOS device — `arm64` (ios-cmake `PLATFORM=OS64`)
- iOS simulator — `arm64` + `x86_64` (`SIMULATORARM64` + `SIMULATOR64`), then `lipo`'d into one fat Mach-O
- macOS — `arm64` + `x86_64` (`MAC_ARM64` + `MAC`)

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
- **Core struct is dependency-free.** `MCUTMesh` depends on nothing but `simd`. ModelIO and
  RealityKit interop are **additive bridges** in separate files guarded by `#if canImport(...)` +
  `@available`, not baked into the core type. (May graduate to separate library products
  `MCUTModelIO` / `MCUTRealityKit` if we want opt-in; single target with conditional extensions for
  now — simplest.)
- **Error model:** one `MCUTError: Error` (likely `LocalizedError`) spanning **both** mcut
  `McResult` codes **and** wrapper-side validation (empty/inconsistent mesh, bridge failures, no
  output). All C calls funnel through one `check(_ r: McResult) throws` helper. Exact case names
  come from the real `mcut.h`, not this doc.
- **Example surface:** ship interop demos as a **`.swiftpm` App Playground / `Examples/` SwiftUI
  app**, **not** a raw `.playground` file (binary xcframework + classic playground is flaky). The
  RealityKit demo uses SwiftUI `RealityView`, which requires a **recent OS (≈ iOS 18 / macOS 15 —
  confirm)**; that floor applies to the *example only*, above the package's own minimum. Older-OS
  fallback if needed: `ARView` via `UIViewRepresentable` / `NSViewRepresentable`.

### Still open

- **Minimum deployment targets** (e.g. iOS 13 / macOS 11?) — must match the slice builds.
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

- **Spike 0 — does it even build?** *(in progress)* Submodule (`v1.3.0`) + macOS `libmcut.dylib`
  via native cmake, `MCUT_BUILD_AS_SHARED_LIB=ON`. *Pass:* dylib builds and
  `nm -gU … | grep mcDispatch` prints the symbol.
- **Spike 1 — wrap + package.** macOS slice only → `Cmcut.framework` → `Cmcut.xcframework` →
  `swift package compute-checksum`. *Pass:* xcframework produced, checksum computed.
- **Spike 2 — does it link?** Trivial `Package.swift` with local `binaryTarget(path:)`, an `MCUT`
  target that does `import Cmcut`, and a test that only calls `mcCreateContext`/`mcReleaseContext`
  (no mesh). *Pass:* `swift test` links and dynamically loads the framework.
- **Spike 3 — does it load in a REAL app, device + simulator?** Add the package to a separate
  throwaway iOS app, run the same no-op on hardware. **Make-or-break gate** for the whole dynamic
  xcframework premise.
- **Spike 4 — does it actually cut?** First real `mcDispatch`: hardcoded cube ∩ plane, read back
  fragments via the two-pass idiom. *Pass:* expected fragment count/geometry.

Only after Spike 4 is green do `MCUTMesh`, `MCUTError`, the operation methods, the ModelIO/RealityKit
bridges, and the RealityView example earn their keep (that work is Phase 5). Spikes 0–3 ≈ Phases 1–2.

## 10. Phased implementation plan

**Phase 0 — Repo bring-up**
- Init repo, add mcut as submodule pinned to a tag, add `.gitignore`, license files, NOTICE.
- *Done when:* `git submodule status` shows the pinned tag and license files are present.

**Phase 1 — Build one slice by hand**
- Get `MCUT_BUILD_AS_SHARED_LIB=ON` building a `libmcut.dylib` for **macOS** first (fastest to iterate), confirm exported symbols with `nm`.
- *Done when:* a macOS dylib builds and `mcDispatch` is a visible exported symbol.

**Phase 2 — Framework wrapping + xcframework**
- Wrap the dylib into `Cmcut.framework` (Info.plist, `@rpath` install name, headers, module map). Extend to all slices; lipo simulator arches; `create-xcframework`.
- *Done when:* `Cmcut.xcframework` is produced and `swift package compute-checksum` succeeds.

**Phase 3 — Package + minimal Swift wrapper**
- Write `Package.swift` (local `binaryTarget(path:)` first for fast iteration), a minimal `MCUT` target that does `import Cmcut`, and a "hello cut" test (cube ∩ plane).
- *Done when:* `swift test` passes against a local xcframework and the SampleApp runs a real cut.

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
