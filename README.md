# MCUT

[![Swift 6](https://img.shields.io/badge/Swift-6.0-orange.svg)](https://swift.org)
[![Platforms](https://img.shields.io/badge/Platforms-iOS%2018%20%7C%20macOS%2015-blue.svg)](https://developer.apple.com)
[![License: LGPL v3](https://img.shields.io/badge/License-LGPL%20v3-green.svg)](LICENSE)

Robust mesh **cutting**, **boolean / CSG** (union, intersection, difference) and **slicing** for
iOS and macOS — an idiomatic Swift wrapper around [cutdigital/mcut](https://github.com/cutdigital/mcut),
shipped as a prebuilt dynamic `xcframework`.

Add one URL, write `import MCUT`, and cut meshes. No CMake, no C++, no raw C API.

```swift
let result = try cut(model, with: blade)        // sever a mesh along another
let combined = try ctx.union(a, b)              // a ∪ b
let carved   = try ctx.subtract(hole, from: a)  // a − b
let (top, bottom) = try ctx.slice(model, byPlane: [0, 1, 0], offset: 0)
```

---

## Installation

Swift Package Manager. In **Xcode**: *File ▸ Add Package Dependencies…* and enter:

```
https://github.com/dariu5h/mcut-swift
```

Or in a `Package.swift`:

```swift
dependencies: [
    .package(url: "https://github.com/dariu5h/mcut-swift", from: "0.0.6")
],
targets: [
    .target(name: "MyApp", dependencies: [
        .product(name: "MCUT", package: "mcut-swift"),
        // Optional — only if you want MDLMesh / RealityKit interop:
        .product(name: "MCUTSwifty", package: "mcut-swift"),
    ])
]
```

SwiftPM downloads the binary `xcframework` from the matching GitHub Release; the Swift layer
compiles in your build. Because the framework is **dynamic**, Xcode embeds and signs it into your
app automatically (Embed & Sign).

**Requirements:** iOS 18+ / macOS 15+, Swift 6.

---

## Quick start

A mesh is positions plus faces. The flat layout matches what mcut consumes: `faceIndices` is every
face's vertex indices concatenated, and `faceSizes` gives each face's vertex count.

```swift
import MCUT
import simd

// A triangle-soup convenience init fills faceSizes with 3s for you:
let cube = MCUTMesh(vertices: positions, indices: triangleIndices)

// One-shot free function — spins up a context, cuts, tears it down:
let result = try cut(cube, with: blade)
for fragment in result.fragments {
    print(fragment.location, fragment.mesh.positions.count)   // .above / .below / .undefined
}
```

For repeated operations, reuse a context (it owns the underlying mcut handle and releases it on
`deinit`):

```swift
let ctx = try MCUTContext()
let a = try ctx.union(boxA, boxB)
let b = try ctx.intersect(a, sphere)
```

### Boolean / CSG operations

On **watertight, consistently oriented solids**:

```swift
let ctx = try MCUTContext()
let union     = try ctx.union(a, b)            // a ∪ b
let intersect = try ctx.intersect(a, b)        // a ∩ b
let diff      = try ctx.subtract(b, from: a)   // a − b
```

### Slicing by a plane

```swift
// Cross-section by the plane  normal · x = offset.
// `above` is the normal-positive side; either half is empty if the plane misses the mesh.
let (above, below) = try ctx.slice(model, byPlane: [0, 1, 0], offset: 2.5)
```

### Cutting and reading components

`cut` returns connected components split by type. `CutOptions` controls what mcut computes and what
you read back:

```swift
var options = CutOptions()
options.seal = true               // watertight (hole-filled) fragments instead of open shells
options.triangulate = true        // also read mcut's constrained-Delaunay triangulation
options.includeIntersectionType = true

let result = try ctx.cut(source, with: cutMesh, options: options)

result.fragments   // pieces of the source mesh — the main result
result.patches     // pieces of the cut mesh (stencils)
result.seams       // input meshes with the intersection contour stitched in (opt-in)
result.intersectionType   // .standard / .sourceInsideCut / .cutInsideSource / .none
```

---

## Preparing input meshes

mcut needs a **welded, coherently oriented** input. Two helpers cover the common failure modes:

- **`welded(tolerance:)`** — GPU/authoring pipelines (Model I/O, RealityKit, glTF) split a shared
  vertex into one copy per face so each can carry its own normal/UV. The surface *looks* closed but
  the faces don't share edges — a "polygon soup". Welding restores edge sharing so mcut sees a real
  2-manifold. Without it, sealing and booleans produce wrong or empty results.

- **`reoriented()`** — flips faces so adjacent faces agree on which side is "out", and (for a closed
  mesh) so normals point outward. Scan/authoring output is often individually fine but collectively
  scrambled, which makes `mcDispatch` fail or yields wrong booleans.

```swift
let clean = mesh.welded().reoriented()
```

> The `MCUTSwifty` conversions below **weld automatically** (pass `weldTolerance: nil` to opt out).

---

## Apple-graphics interop — `MCUTSwifty`

The optional `MCUTSwifty` product bridges **Model I/O** (`MDLMesh`) and **RealityKit**
(`MeshResource`), so you can stay in Apple types. It's a separate product to keep the core
dependency-light — import it only when you need it.

```swift
import MCUTSwifty
import RealityKit

// Convert, or use the same-type sugar that converts on both ends:
let carved = try mesh.subtract(drill)                 // MeshResource → MeshResource
let pieces = try mesh.cut(with: blade)                // [MeshResource], one per fragment
let (above, below) = try mesh.slice(byPlane: [0,1,0], offset: 0)
```

```swift
import ModelIO

let allocator = MDLMeshBufferDataAllocator()
let result = try meshA.union(meshB, allocator: allocator)   // MDLMesh → MDLMesh
```

> Conversions carry positions and triangle indices only — normals/UVs are not regenerated. Use
> RealityKit's / Model I/O's normal generation on the result as needed.

---

## License

**This package distributes mcut, which is licensed under the [GNU LGPL v3](LICENSE).** The combined
distribution carries LGPL-3.0 terms — see [`LICENSE`](LICENSE) (LGPL v3), [`COPYING`](COPYING)
(GPL v3, which the LGPL incorporates) and [`NOTICE`](NOTICE) for attribution and the exact upstream
source.

What this means in practice:

- **Open-source app** → no issue.
- **Closed-source / commercial app, LGPL route** → fine *because* mcut ships as a **dynamic,
  replaceable** framework. Keep it dynamic (don't relink it statically), keep the attribution, and
  let users replace the framework. That's the compliance mechanism — do not switch to static linking.
- **Closed-source / commercial app wanting no LGPL obligations** → buy a **commercial license for
  mcut from [CutDigital](mailto:contact@cut-digital.com)**. This wrapper cannot grant that — it
  doesn't own mcut.

> Not legal advice. LGPL-on-the-App-Store is contested terrain; get real legal review before
> commercial reliance.

## Credits

- [**mcut**](https://github.com/cutdigital/mcut) by CutDigital Enterprise — the C++ cutting/boolean
  engine this package wraps (pinned to `v1.3.0`).
