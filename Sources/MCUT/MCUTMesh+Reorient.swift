import simd

extension MCUTMesh {
    /// Rewind every face so the surface is **consistently oriented** — adjacent faces agree on which
    /// side is "out" — and, when the mesh is closed, so all normals point **outward**.
    ///
    /// Authoring/scan pipelines often emit meshes whose faces are each individually fine but
    /// collectively scrambled: two faces sharing an edge traverse it in the *same* direction, so
    /// their normals point opposite ways. mcut needs a coherently oriented input to classify
    /// inside/outside and above/below; a scrambled mesh makes `mcDispatch` fail (`MC_INVALID_VALUE`)
    /// or makes sealing and the boolean ops produce wrong/empty results.
    ///
    /// The correction is topological, not geometric, so it is independent of convexity — non-convex
    /// closed meshes are handled exactly like convex ones. The mesh must be manifold and orientable
    /// (every closed real-world solid is). Faces of any size are supported; flipping a face reverses
    /// its vertex order.
    ///
    /// Two steps:
    /// 1. **Consistency** — flood the face-adjacency graph, flipping faces so each shared edge is
    ///    traversed in opposite directions by its two faces.
    /// 2. **Outward** — for a closed mesh (no boundary edges), compute the signed volume and flip the
    ///    whole mesh when it is negative (normals were facing inward). Skipped for open meshes, where
    ///    "outward" is undefined; consistency still holds.
    ///
    /// Like `welded()`, this drops `triangleIndices`, whose winding would no longer match the faces.
    public func reoriented() -> MCUTMesh {
        // Decode the flat layout into per-face index lists.
        var faces = [[UInt32]]()
        faces.reserveCapacity(faceSizes.count)
        var cursor = 0
        for size in faceSizes {
            let n = Int(size)
            faces.append(Array(faceIndices[cursor..<cursor + n]))
            cursor += n
        }

        // Map each undirected edge to the faces using it, recording the direction each face winds it.
        struct EdgeKey: Hashable { let lo: UInt32; let hi: UInt32 }
        func key(_ a: UInt32, _ b: UInt32) -> EdgeKey {
            a < b ? EdgeKey(lo: a, hi: b) : EdgeKey(lo: b, hi: a)
        }
        var incident = [EdgeKey: [(face: Int, dir: (UInt32, UInt32))]]()
        for (fi, face) in faces.enumerated() where face.count >= 3 {
            for k in 0..<face.count {
                let a = face[k], b = face[(k + 1) % face.count]
                incident[key(a, b), default: []].append((fi, (a, b)))
            }
        }
        let hasBoundary = incident.values.contains { $0.count == 1 }

        // Flood across shared edges, flipping faces so each shared edge is traversed in opposing
        // directions by its two faces. `flip[fi]` is the final orientation of face `fi`.
        var visited = [Bool](repeating: false, count: faces.count)
        var flip = [Bool](repeating: false, count: faces.count)

        func orientedEdges(_ fi: Int) -> [(UInt32, UInt32)] {
            let f = flip[fi] ? Array(faces[fi].reversed()) : faces[fi]
            return (0..<f.count).map { (f[$0], f[($0 + 1) % f.count]) }
        }

        for seed in faces.indices where !visited[seed] {
            visited[seed] = true
            var stack = [seed]
            while let fi = stack.popLast() {
                for (a, b) in orientedEdges(fi) {
                    for entry in incident[key(a, b)] ?? [] where !visited[entry.face] {
                        // entry.dir is the neighbour's *original* winding of this edge. If it matches
                        // this face's already-oriented direction, the neighbour must be flipped.
                        flip[entry.face] = (entry.dir == (a, b))
                        visited[entry.face] = true
                        stack.append(entry.face)
                    }
                }
            }
        }

        var oriented = faces
        for fi in oriented.indices where flip[fi] { oriented[fi].reverse() }

        // Outward step — only meaningful for a closed mesh. Signed volume via a triangle fan per face
        // (exact for any planar face, convex or not); negative means normals face inward, so flip all.
        if !hasBoundary {
            func d(_ p: SIMD3<Float>) -> SIMD3<Double> { SIMD3<Double>(Double(p.x), Double(p.y), Double(p.z)) }
            var vol6: Double = 0
            for face in oriented where face.count >= 3 {
                let p0 = d(positions[Int(face[0])])
                for k in 1..<(face.count - 1) {
                    let p1 = d(positions[Int(face[k])])
                    let p2 = d(positions[Int(face[k + 1])])
                    vol6 += simd_dot(p0, simd_cross(p1, p2))
                }
            }
            if vol6 < 0 { for fi in oriented.indices { oriented[fi].reverse() } }
        }

        var newFaceIndices = [UInt32]()
        newFaceIndices.reserveCapacity(faceIndices.count)
        for face in oriented { newFaceIndices.append(contentsOf: face) }

        return MCUTMesh(positions: positions, faceIndices: newFaceIndices, faceSizes: faceSizes)
    }

    /// One-call cleanup that makes a raw authoring mesh safe for mcut: `welded()` to restore shared
    /// edges, then `reoriented()` to make the winding consistent (and outward, when closed). Use this
    /// on meshes from glTF/Model I/O/scans before `cut`/`slice`/`union`/`intersect`/`subtract`.
    public func cleaned(tolerance: Float = 1e-5) -> MCUTMesh {
        welded(tolerance: tolerance).reoriented()
    }
}
