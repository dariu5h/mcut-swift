import MCUT

extension MCUTMesh {
    /// Fan-triangulate every face into a flat triangle index list (`[i0,i1,i2, …]`).
    ///
    /// Model I/O submeshes and RealityKit `MeshDescriptor.triangles` both want triangles, but mcut
    /// returns arbitrary n-gons. A triangle fan is exact for convex faces; cut/boolean outputs of
    /// convex solids are convex, so this is correct for the common case. Strongly non-convex faces
    /// would need a proper polygon triangulator — out of scope for v1.
    func fanTriangleIndices() -> [UInt32] {
        var triangles = [UInt32]()
        triangles.reserveCapacity(faceIndices.count)   // ~ n-2 triangles per n-gon
        var cursor = 0
        for size in faceSizes {
            let n = Int(size)
            if n >= 3 {
                let pivot = faceIndices[cursor]
                for k in 1..<(n - 1) {
                    triangles.append(pivot)
                    triangles.append(faceIndices[cursor + k])
                    triangles.append(faceIndices[cursor + k + 1])
                }
            }
            cursor += n
        }
        return triangles
    }
}
