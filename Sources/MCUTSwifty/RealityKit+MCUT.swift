#if canImport(RealityKit)
import MCUT
import RealityKit
import simd

// MARK: - MeshResource ⇄ MCUTMesh

@available(iOS 18.0, macOS 15.0, *)
extension MCUTMesh {
    /// Build an `MCUTMesh` from a `MeshResource` by reading every model/part's positions and
    /// triangle indices (parts are concatenated, indices rebased).
    ///
    /// - Parameter weldTolerance: coincident vertices are merged at this tolerance before returning
    ///   (see ``MCUTMesh/welded(tolerance:)``). RealityKit splits vertices per face, so welding is on
    ///   by default; pass `nil` to keep the mesh exactly as supplied.
    @MainActor
    public init(_ resource: MeshResource, weldTolerance: Float? = 1e-5) {
        var positions = [SIMD3<Float>]()
        var indices = [UInt32]()

        for model in resource.contents.models {
            for part in model.parts {
                let base = UInt32(positions.count)
                positions.append(contentsOf: part.positions.elements)
                if let tris = part.triangleIndices?.elements {
                    indices.append(contentsOf: tris.map { $0 + base })
                }
            }
        }

        let raw = MCUTMesh(vertices: positions, indices: indices)
        self = weldTolerance.map { raw.welded(tolerance: $0) } ?? raw
    }

    /// Produce a `MeshResource` (single triangulated descriptor, positions only — normals/UVs are
    /// not generated; call `MeshResource`'s normal-generation or shade flat as needed).
    @MainActor
    public func makeMeshResource() throws -> MeshResource {
        var descriptor = MeshDescriptor()
        descriptor.positions = MeshBuffers.Positions(positions)
        // Prefer mcut's constrained-Delaunay triangulation (correct for non-convex faces); fall back
        // to a fan only for meshes that carry none (e.g. caller-built non-triangle meshes).
        descriptor.primitives = .triangles(triangleIndices ?? fanTriangleIndices())
        return try MeshResource.generate(from: [descriptor])
    }
}

// MARK: - Same-type convenience ops

/// Boolean / cut / slice that take and return `MeshResource`, so callers stay in RealityKit types.
/// Each is sugar over `MCUTMesh(self)` → core op → `makeMeshResource()`. Inputs are welded on
/// conversion. `@MainActor` because `MeshResource` creation/inspection is main-actor isolated.
@available(iOS 18.0, macOS 15.0, *)
extension MeshResource {
    @MainActor
    public func union(_ other: MeshResource) throws -> MeshResource {
        try MCUTContext().union(MCUTMesh(self), MCUTMesh(other)).makeMeshResource()
    }

    @MainActor
    public func intersect(_ other: MeshResource) throws -> MeshResource {
        try MCUTContext().intersect(MCUTMesh(self), MCUTMesh(other)).makeMeshResource()
    }

    /// `self − other`.
    @MainActor
    public func subtract(_ other: MeshResource) throws -> MeshResource {
        try MCUTContext().subtract(MCUTMesh(other), from: MCUTMesh(self)).makeMeshResource()
    }

    /// Sever `self` along its intersection with `cutMesh`; returns one `MeshResource` per fragment.
    @MainActor
    public func cut(with cutMesh: MeshResource, options: CutOptions = CutOptions()) throws -> [MeshResource] {
        var options = options
        options.triangulate = true     // need mcut's CDT to emit triangles for RealityKit
        let result = try MCUTContext().cut(MCUTMesh(self), with: MCUTMesh(cutMesh), options: options)
        return try result.fragments.map { try $0.mesh.makeMeshResource() }
    }

    /// Cross-section by the plane `normal · x = offset`; returns the two welded halves.
    @MainActor
    public func slice(byPlane normal: SIMD3<Float>, offset: Float)
        throws -> (above: MeshResource, below: MeshResource) {
        let halves = try MCUTContext().slice(MCUTMesh(self), byPlane: normal, offset: offset)
        return (try halves.above.makeMeshResource(), try halves.below.makeMeshResource())
    }
}
#endif
