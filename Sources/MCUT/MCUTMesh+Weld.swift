import simd

extension MCUTMesh {
    /// Merge vertices that coincide within `tolerance` into a single vertex, remap every face to
    /// the merged indices, and drop faces that collapse to fewer than three distinct vertices.
    ///
    /// Meshes from GPU/authoring pipelines (Model I/O, RealityKit, glTF, …) routinely *split* a
    /// shared vertex into one copy per incident face so each copy can carry its own normal/UV.
    /// Geometrically the surface looks closed, but topologically the faces don't share edges — it's
    /// a "polygon soup" with redundant, unshared edges. mcut needs a connected (welded) mesh: an
    /// unwelded input makes hole-filling/sealing and the boolean ops produce wrong or empty results.
    /// Welding restores edge sharing so the mesh is a proper 2-manifold mcut can reason about.
    ///
    /// The first vertex seen at a given quantized location is kept as the representative; coincident
    /// copies are bit-identical in the common (attribute-split) case, so the choice is immaterial.
    ///
    /// - Parameter tolerance: positions are quantized to a grid of this size before comparison.
    ///   The default suits attribute-split duplicates (which are exactly equal). Increase it to also
    ///   merge near-coincident vertices.
    public func welded(tolerance: Float = 1e-6) -> MCUTMesh {
        precondition(tolerance > 0, "tolerance must be positive")

        // Quantize to an integer lattice so coincident positions hash to the same key. 64-bit keys
        // avoid overflow for any realistic coordinate/tolerance ratio.
        struct GridKey: Hashable { let x: Int; let y: Int; let z: Int }
        let inv = 1 / tolerance
        func key(_ p: SIMD3<Float>) -> GridKey {
            GridKey(x: Int((p.x * inv).rounded()),
                    y: Int((p.y * inv).rounded()),
                    z: Int((p.z * inv).rounded()))
        }

        var representative = [GridKey: UInt32]()
        var newPositions = [SIMD3<Float>]()
        newPositions.reserveCapacity(positions.count)
        var oldToNew = [UInt32](repeating: 0, count: positions.count)

        for (i, p) in positions.enumerated() {
            let k = key(p)
            if let idx = representative[k] {
                oldToNew[i] = idx
            } else {
                let idx = UInt32(newPositions.count)
                representative[k] = idx
                newPositions.append(p)
                oldToNew[i] = idx
            }
        }

        var newFaceIndices = [UInt32]()
        var newFaceSizes = [UInt32]()
        var cursor = 0
        for size in faceSizes {
            let n = Int(size)
            // Remap, then drop vertices equal to their predecessor (cyclically) so an edge that
            // collapsed to zero length disappears instead of leaving a degenerate face.
            var face = [UInt32]()
            face.reserveCapacity(n)
            for k in 0..<n {
                let v = oldToNew[Int(faceIndices[cursor + k])]
                if face.last != v { face.append(v) }
            }
            if face.count > 1 && face.first == face.last { face.removeLast() }

            if face.count >= 3 {
                newFaceIndices.append(contentsOf: face)
                newFaceSizes.append(UInt32(face.count))
            }
            cursor += n
        }

        return MCUTMesh(positions: newPositions, faceIndices: newFaceIndices, faceSizes: newFaceSizes)
    }
}
