# Swift API design

The design for the public `MCUT` API (Phase 5 in `docs/plans/mcut-swift-plan.md`).
Implementation is phased — see `docs/plans/swift-api-phase5-plan.md`.

**The header is ground truth.** Everything below is derived from `external/mcut/include/mcut/mcut.h`.
If this doc and the header ever disagree, the header wins — re-derive, don't guess. `Sources/MCUT/MCUT.swift`
currently holds spike code (a context smoke test and a cube-vs-plane probe); Phase 5a replaces it.

## Decisions locked

- **Vertex type is `Float`** (`SIMD3<Float>`). iOS-native — matches SceneKit / RealityKit / ModelIO with no
  conversion at the render boundary. mcut runs exact predicates internally regardless of input precision, so
  cut *robustness* is unaffected by this choice; it only sets the dispatch flag
  (`MC_DISPATCH_VERTEX_ARRAY_FLOAT`) and which vertex channel we read (`..._DATA_VERTEX_FLOAT`).
- **Synchronous v1.** Wrap only the **blocking** C calls (`mcDispatch`, `mcGetConnectedComponents`,
  `mcGetConnectedComponentData`). The async/event API (`mcEnqueue*`, `McEvent`, `mcWaitForEvents`,
  callbacks) is deferred. `async` methods, if added, just run the blocking call off the main actor.

## The one thing to understand first

mcut is **not** a CSG/boolean library. It has a single engine call — `mcDispatch(source, cut, flags)` —
that severs the source mesh along its intersection with the cut mesh and returns **connected components**
(see `McConnectedComponentType`): `FRAGMENT` (from the source), `PATCH` (from the cut), `SEAM` (an input
plus the new intersection edges), `INPUT` (a possibly-repartitioned copy of an input). Filter flags decide
which components come back; data-channel queries read each component's geometry.

Every higher-level operation — union, subtract, intersect, slice — is *derived* from that one call by
picking filter flags and reassembling components. This is why the API has two tiers.

## Design principles

1. **Handles never escape.** No `McContext` or `McConnectedComponent` in any public signature. The two-pass
   byte-count idiom and all `mcRelease*` calls are internal. Public results are plain `Sendable` value types.
2. **Materialize only requested channels.** Reading every channel for every component is wasteful. A
   `CutOptions` set names what to read; default is geometry only (positions + faces + faceSizes).
3. **Faithful core, derived conveniences.** Tier A maps the engine 1:1 and is fully testable. Tier B
   (booleans) sits on top and needs known-answer fixtures before it can be trusted.
4. **Safe defaults from the header.** Default general-position enforcement on (axis-aligned inputs violate
   GP and would otherwise error — the spike already hit this).

## Public types

```swift
public struct MCUTMesh: Sendable {
    public var positions:   [SIMD3<Float>]   // one entry per vertex
    public var faceIndices: [UInt32]         // flat, concatenated per face
    public var faceSizes:   [UInt32]         // vertex count of each face; sum == faceIndices.count

    public init(positions: [SIMD3<Float>], faceIndices: [UInt32], faceSizes: [UInt32])
    /// Triangle-soup convenience: faceSizes becomes [3, 3, …]. indices.count must be a multiple of 3.
    public init(triangles positions: [SIMD3<Float>], indices: [UInt32])
}

/// The three real McResult failure codes (MC_NO_ERROR is success, never thrown).
public enum MCUTError: Error, Sendable {
    case invalidOperation   // MC_INVALID_OPERATION
    case invalidValue       // MC_INVALID_VALUE
    case outOfMemory        // MC_OUT_OF_MEMORY
}

/// Per-cut configuration. Default: geometry only, open (unsealed) fragments.
public struct CutOptions: Sendable {
    public var enforceGeneralPosition: Bool          // default true → MC_DISPATCH_ENFORCE_GENERAL_POSITION
    public var seal: Bool                             // watertight fragments (see note) — default false
    public var requireThroughCuts: Bool              // MC_DISPATCH_REQUIRE_THROUGH_CUTS; partial cut → no fragments
    public var triangulate: Bool                     // also read MC_..._DATA_FACE_TRIANGULATION
    public var includeSeams: Bool                    // also collect SEAM components
    public var includeIntersectionType: Bool         // MC_DISPATCH_INCLUDE_INTERSECTION_TYPE → CutResult.intersectionType
    public var includeVertexMap: Bool                // MC_DISPATCH_INCLUDE_VERTEX_MAP + read channel
    public var includeFaceMap: Bool                  // MC_DISPATCH_INCLUDE_FACE_MAP + read channel
    public init()                                    // all-defaults
}
```

**Default fragment filter.** `cut` requests `FRAGMENT_LOCATION_ABOVE | BELOW`, plus `UNDEFINED`
when `requireThroughCuts` is false (the two are mutually exclusive per the header). Sealing is
`SEALING_NONE` by default (open shells). Patches (`PATCH_INSIDE | OUTSIDE`) are always collected.

**`seal` semantics (empirically pinned).** With `seal == true` the dispatch requests
`SEALING_INSIDE`, which makes mcut return *each* fragment **twice** — once unsealed (`.none`) and
once watertight (`.complete`). The wrapper drops the unsealed duplicates and returns only the
`.complete` fragments. Verified watertight (every edge shared by exactly two faces) by fixture.

**`requireThroughCuts`** sets `MC_DISPATCH_REQUIRE_THROUGH_CUTS` and omits the `UNDEFINED`
location filter; a partial cut then becomes a no-op (no fragments). Confirmed by fixture.

**Vertex/face maps** trace each output vertex/face back to an input. Vertices born on the cut
seam map to `MC_UNDEFINED_VALUE` (`UInt32.max`); every face maps to a real input face. The
source-vs-cut convention: an index `>= numSourceVertices` (resp. `numSourceFaces`) refers to the
cut mesh. Surfaced as `vertexMap` / `faceMap` on `Fragment`/`Patch` (non-nil only when opted in).

## Tier A — faithful cut

Exposes the full engine. A reusable RAII context plus transient-context conveniences.

```swift
public final class MCUTContext {
    public init() throws                              // mcCreateContext; deinit → mcReleaseContext
    public func cut(_ source: MCUTMesh, with cutMesh: MCUTMesh,
                    options: CutOptions = CutOptions()) throws -> CutResult
}

/// Convenience: spin up a transient context, cut, tear it down.
public func cut(_ source: MCUTMesh, with cutMesh: MCUTMesh,
                options: CutOptions = CutOptions()) throws -> CutResult

public struct CutResult: Sendable {
    public let fragments: [Fragment]
    public let patches:   [Patch]
    public let seams:     [Seam]                      // empty unless options.includeSeams
    public let intersectionType: IntersectionType?    // non-nil iff options.includeIntersectionType
}

public struct Fragment: Sendable {
    public let mesh: MCUTMesh
    public let triangulatedFaceIndices: [UInt32]?     // non-nil iff options.triangulate
    public let location: FragmentLocation             // above / below / undefined  (McFragmentLocation)
    public let sealType: FragmentSealType             // complete / none            (McFragmentSealType)
    public let vertexMap: [UInt32]?                    // non-nil iff options.includeVertexMap
    public let faceMap:   [UInt32]?                    // non-nil iff options.includeFaceMap
}
public struct Patch: Sendable {
    public let mesh: MCUTMesh
    public let triangulatedFaceIndices: [UInt32]?
    public let location: PatchLocation                // inside / outside / undefined (McPatchLocation)
    public let vertexMap: [UInt32]?
    public let faceMap:   [UInt32]?
}
public struct Seam: Sendable {
    public let mesh: MCUTMesh
    public let origin: SeamOrigin                     // sourceMesh / cutMesh (McSeamOrigin)
}

public enum FragmentLocation: Sendable { case above, below, undefined }
public enum FragmentSealType:  Sendable { case complete, none }
public enum PatchLocation:     Sendable { case inside, outside, undefined }
public enum SeamOrigin:        Sendable { case sourceMesh, cutMesh }
/// How the inputs intersect (McDispatchIntersectionType).
public enum IntersectionType:  Sendable { case standard, sourceInsideCut, cutInsideSource, none }
```

**Internal flow of `cut`** (all hidden):
1. Build dispatch flags: `VERTEX_ARRAY_FLOAT` | (general-position if requested) | the filter bits implied by
   what's requested (all fragment locations + seal types by default; patches; seams/maps if opted in).
2. Flatten `positions` to a contiguous `[Float]` (xyzxyz…); pass `faceIndices`/`faceSizes` straight through.
3. `mcDispatch` (blocking). Map a non-`MC_NO_ERROR` result to `MCUTError`.
4. `mcGetConnectedComponents` two-pass (count, then fetch) per type.
5. For each component, two-pass read each requested channel; rebuild an `MCUTMesh`
   (positions from `VERTEX_FLOAT`, faces from `FACE` + `FACE_SIZE`), read scalar channels
   (`TYPE`, `FRAGMENT_LOCATION`, `PATCH_LOCATION`, `FRAGMENT_SEAL_TYPE`, `ORIGIN`) for the metadata.
6. `mcReleaseConnectedComponents`, then (for the transient convenience) `mcReleaseContext`. Return values.

## Tier B — boolean / CSG (Phase 5b, fixtures passing)

```swift
extension MCUTContext {
    public func union(_ a: MCUTMesh, _ b: MCUTMesh)     throws -> MCUTMesh
    public func subtract(_ b: MCUTMesh, from a: MCUTMesh) throws -> MCUTMesh
    public func intersect(_ a: MCUTMesh, _ b: MCUTMesh) throws -> MCUTMesh
    /// Cross-section of `mesh` by an infinite plane (synthesized as a bbox-sized quad in v1).
    public func slice(_ mesh: MCUTMesh, byPlane normal: SIMD3<Float>, offset: Float)
        throws -> (above: MCUTMesh, below: MCUTMesh)
}
```

**How it actually works.** Each boolean is *one* `mcDispatch` with a constrained filter that returns the
single sealed fragment which *is* the result — mcut's hole-filling does the reassembly, so the wrapper does
not stitch fragments-plus-patches itself. It only keeps the `.complete` (sealed) fragments (requesting one
sealing mode still returns unsealed duplicates) and merges them into one mesh.

**Pinned flags** (verbatim from mcut's `CSGBoolean` tutorial; all also carry
`MC_DISPATCH_VERTEX_ARRAY_FLOAT | MC_DISPATCH_ENFORCE_GENERAL_POSITION`). Source = first input, cut = second:

| Op | `MC_DISPATCH_FILTER_*` bits |
|----|-----------------------------|
| `union(a, b)`        — `a ∪ b` | `FRAGMENT_SEALING_OUTSIDE \| FRAGMENT_LOCATION_ABOVE` |
| `intersect(a, b)`    — `a ∩ b` | `FRAGMENT_SEALING_INSIDE  \| FRAGMENT_LOCATION_BELOW` |
| `subtract(b, from: a)` — `a − b` | `FRAGMENT_SEALING_INSIDE  \| FRAGMENT_LOCATION_ABOVE` |

**Winding.** No reorientation is needed. The tutorial reverses faces only in the
`FRAGMENT_LOCATION_BELOW && PATCH_LOCATION_OUTSIDE` case, which is `B − A` — an op this API does not expose.
All three exposed ops avoid that combination, and known-answer tests confirm outward winding (positive
signed volume) directly, so `mcBindState` / `MC_CONTEXT_CONNECTED_COMPONENT_FACE_WINDING_ORDER` is not used.

**`slice`** is not a dispatch-flag boolean: it synthesizes a bbox-sized quad on the plane (wound so its
normal points along `normal`), runs a sealed through-cut via the Tier-A `cut`, and partitions the resulting
fragments by `FragmentLocation` into `above` (the `normal`-positive side) and `below`.

**Verified by fixture.** Two overlapping unit cubes (offset by non-integer amounts to avoid coplanar
faces) give known signed volumes — union 13.79, intersect 2.21, A−B 5.79 — and a y=0 plane slice yields two
watertight halves of volume 4. See `Tests/MCUTTests/MCUTTests.swift`.

## Deliberately deferred

- The async/event API (`mcEnqueue*`, `McEvent`, callbacks, profiling, out-of-order execution).
- Native `mcEnqueueDispatchPlanarSection` — has no blocking variant, so v1 `slice` synthesizes a plane quad.
- Debug message log / `mcDebugMessageCallback` plumbing (useful later for diagnostics).
- `mcBindState` tuning (GP enforcement constant, attempts) beyond the on/off `enforceGeneralPosition` toggle.
- Adjacency channels (`FACE_ADJACENT_FACE*`), perturbation vector, seam-vertex contours.

## C API → Swift map (quick reference)

| C | Swift |
|---|-------|
| `McContext` + `mcCreateContext` / `mcReleaseContext` | `MCUTContext` (RAII, hidden) |
| `mcDispatch` | `MCUTContext.cut` |
| `McResult` codes | `throws MCUTError` |
| `McDispatchFlags` | computed internally from `CutOptions` |
| `mcGetConnectedComponents` (two-pass) | hidden inside `cut` |
| `mcGetConnectedComponentData` (two-pass) | hidden; fills `MCUTMesh` + metadata |
| `McConnectedComponentType` | the `fragments` / `patches` / `seams` split of `CutResult` |
| `McFragmentLocation` / `McFragmentSealType` / `McPatchLocation` / `McSeamOrigin` | the four metadata enums |
| `MC_..._DATA_FACE_TRIANGULATION` | `triangulatedFaceIndices` (opt-in) |
| `mcEnqueue*`, `McEvent`, `mcWaitForEvents` | deferred |
