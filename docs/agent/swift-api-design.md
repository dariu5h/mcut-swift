# Swift API design

Forward-looking conventions for the public `MCUT` API (Phase 5 in `docs/plans/mcut-swift-plan.md`).
**Not yet built** — `Sources/MCUT/MCUT.swift` currently holds spike code (a context smoke test and a
cube-vs-plane cut probe). Design the real API from the actual header
(`external/mcut/include/mcut/mcut.h`); the list below is intent, the header is ground truth.

- `McResult` codes → a `throws` `MCUTError` enum. No raw error ints in the public API.
- `McDispatchFlags` → a Swift `OptionSet`.
- Input mesh → `MCUTMesh { vertices, faceIndices, faceSizes }` with a triangle-only convenience init.
- Hide the C two-pass byte-count idiom and all manual `mcRelease*` calls behind RAII / `deinit`.
  Callers must never see or leak handles.
- Expose the `FACE_TRIANGULATION` channel — mcut returns arbitrary polygons; renderers/solvers need tris.
- High-level ops set filter-flag combinations: `union`, `subtract`, `intersect`, `slice`/`section`,
  `split`, `stencil`, `intersectionCurves`.
