# Phase 5 — Swift API implementation plan

Builds the public `MCUT` API. Design (types, signatures, rationale): `docs/agent/swift-api-design.md`.
Ground truth for every signature: `external/mcut/include/mcut/mcut.h`.

**Locked decisions:** vertex type `Float` (`SIMD3<Float>`); synchronous-only v1 (blocking C calls).
**No binary rebuild for any of this** — the Swift layer is compiled by consumers; the released
`Cmcut.xcframework` (0.0.4) stays valid. Shipping a version is just a new git tag, no CI run.

---

## Phase 5a — faithful cut (Tier A)

Replace the spike in `Sources/MCUT/MCUT.swift` with the real engine wrapper. Fully testable now.

1. **Core value types** → verify: `swift build` compiles.
   `MCUTMesh` (+ both inits), `MCUTError`, `CutOptions`, the four metadata enums, `Fragment`/`Patch`/`Seam`,
   `CutResult`. Pure Swift, no C yet.
2. **Internal handle plumbing** → verify: compiles; no handle types in public signatures.
   A private result-code → `MCUTError` mapper; a private generic two-pass channel reader
   (`(query) -> [T]`); flatten `[SIMD3<Float>]` → `[Float]`.
3. **`MCUTContext` + `cut`** → verify: the ported cube∕plane case returns 2 fragments with non-zero
   geometry (the spike's known answer, now asserting real positions/faces, not just counts).
   RAII `init`/`deinit`; build dispatch flags from `CutOptions`; dispatch; collect FRAGMENT/PATCH
   (+SEAM if opted) components; fill `MCUTMesh` + metadata; release.
4. **Transient `cut(_:with:options:)` free function** → verify: same cube∕plane result without a
   caller-held context.
5. **Triangulation + options coverage** → verify: with `triangulate: true`, `triangulatedFaceIndices`
   is non-nil and a multiple of 3; a partial (non-through) cut yields an `.undefined`-location fragment.
6. **Delete spike code** → verify: `Spike*` symbols gone; `swift test` green; no public handle leaks.

Exit criteria for 5a: `swift test` passes; public API matches the header; spike removed.

## Phase 5b — boolean / CSG (Tier B) — only after 5a is green

Each operation lands with its own known-answer fixture; do not merge a guessed flag combo.

1. **Fixtures first** → verify: helper builds unit cubes / tetrahedra at chosen offsets; assertions are
   on stable quantities (component counts, vertex/face counts, watertightness, optionally signed volume).
2. **Winding control** → verify: confirm whether `mcBindState` +
   `MC_CONTEXT_CONNECTED_COMPONENT_FACE_WINDING_ORDER` is needed for consistent output orientation;
   capture the finding in the design doc.
3. **`union` / `intersect` / `subtract`** → verify: each against its fixture, cross-checked with mcut's
   `CSGBoolean` tutorial flag combinations. Pin the exact `MC_DISPATCH_FILTER_*` bits in code + doc.
4. **`slice(byPlane:offset:)`** → verify: synthesize a bbox-sized plane quad, cut a cube, assert two
   sealed halves with expected geometry.

Exit criteria for 5b: every boolean has a passing fixture test; final flag combinations documented in
`swift-api-design.md` (replacing the "needs fixtures" caveat).

## Open questions to resolve during 5b (not now)

- Exact `MC_DISPATCH_FILTER_*` combination per boolean (resolve empirically against fixtures + mcut tutorial).
- Whether winding must be flipped for `subtract`'s patch pieces.
- Whether to expose `slice` results as `(above, below)` or a single multi-fragment result.

## Not in Phase 5 (tracked, deferred)

Async/event API, native planar-section, debug-message log, GP-constant tuning, adjacency channels.
See "Deliberately deferred" in `docs/agent/swift-api-design.md`.
