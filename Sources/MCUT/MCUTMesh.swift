// Public value types for the MCUT API. Pure Swift — no C handles escape here.
// Every type is `Sendable`; results are plain values the caller owns.

/// A polygon mesh in the flat layout mcut consumes and returns.
///
/// `faceIndices` is the concatenation of every face's vertex indices; `faceSizes`
/// gives the vertex count of each face in order, so `faceSizes.reduce(0, +) == faceIndices.count`.
public struct MCUTMesh: Sendable {
    public var positions:   [SIMD3<Float>]   // one entry per vertex
    public var faceIndices: [UInt32]         // flat, concatenated per face
    public var faceSizes:   [UInt32]         // vertex count of each face; sum == faceIndices.count

    /// Optional precomputed triangle decomposition of the faces (flat `3·N` indices into
    /// `positions`), as mcut's constrained-Delaunay triangulation. Non-nil on the meshes returned by
    /// `cut`/`union`/`intersect`/`subtract`/`slice`; `nil` on meshes the caller built directly (other
    /// than the `vertices:` convenience, where the input *is* the triangulation). Correct for
    /// non-convex faces, unlike a naive fan — converters to triangle-only formats use it when present.
    /// Indices are invalidated by anything that renumbers vertices (e.g. `welded()` clears it).
    public var triangleIndices: [UInt32]?

    public init(positions: [SIMD3<Float>], faceIndices: [UInt32], faceSizes: [UInt32],
                triangleIndices: [UInt32]? = nil) {
        self.positions = positions
        self.faceIndices = faceIndices
        self.faceSizes = faceSizes
        self.triangleIndices = triangleIndices
    }

    /// Triangle-soup convenience: `faceSizes` becomes `[3, 3, …]`.
    /// `indices.count` must be a multiple of 3. The indices are also the triangulation.
    public init(vertices positions: [SIMD3<Float>], indices: [UInt32]) {
        precondition(indices.count % 3 == 0, "triangle index count must be a multiple of 3")
        self.positions = positions
        self.faceIndices = indices
        self.faceSizes = [UInt32](repeating: 3, count: indices.count / 3)
        self.triangleIndices = indices
    }

    /// `Int`-index convenience for the flat layout; indices are converted to `UInt32`.
    public init(positions: [SIMD3<Float>], faceIndices: [Int], faceSizes: [Int],
                triangleIndices: [Int]? = nil) {
        self.init(positions: positions,
                  faceIndices: faceIndices.map(UInt32.init),
                  faceSizes: faceSizes.map(UInt32.init),
                  triangleIndices: triangleIndices?.map(UInt32.init))
    }

    /// `Int`-index triangle-soup convenience; indices are converted to `UInt32`.
    public init(vertices positions: [SIMD3<Float>], indices: [Int]) {
        self.init(vertices: positions, indices: indices.map(UInt32.init))
    }
}

/// The three real `McResult` failure codes. `MC_NO_ERROR` is success and is never thrown.
public enum MCUTError: Error, Sendable {
    case invalidOperation   // MC_INVALID_OPERATION
    case invalidValue       // MC_INVALID_VALUE
    case outOfMemory        // MC_OUT_OF_MEMORY
}

/// Which connected-component data channels to read back. Default: geometry only
/// (positions + faces + faceSizes).
public struct CutOptions: Sendable {
    /// Auto-perturb the cut mesh when inputs are not in general position
    /// (`MC_DISPATCH_ENFORCE_GENERAL_POSITION`). Default true — axis-aligned inputs violate
    /// general position and would otherwise fail the dispatch.
    public var enforceGeneralPosition: Bool
    /// Return watertight (hole-filled) fragments instead of the default open shells.
    /// When true, fragments are sealed and report `sealType == .complete`.
    public var seal: Bool
    /// Treat partial (non-through) cuts as a no-op (`MC_DISPATCH_REQUIRE_THROUGH_CUTS`): only
    /// cuts that fully sever the source produce fragments. Mutually exclusive with reading
    /// `.undefined`-location fragments, so partial cuts then yield no fragments.
    public var requireThroughCuts: Bool
    /// Also read `MC_CONNECTED_COMPONENT_DATA_FACE_TRIANGULATION` per component.
    public var triangulate: Bool
    /// Also collect SEAM connected components.
    public var includeSeams: Bool
    /// Classify how the inputs intersect, surfaced as `CutResult.intersectionType`
    /// (`MC_DISPATCH_INCLUDE_INTERSECTION_TYPE`).
    public var includeIntersectionType: Bool
    /// `MC_DISPATCH_INCLUDE_VERTEX_MAP` + read the vertex-map channel.
    public var includeVertexMap: Bool
    /// `MC_DISPATCH_INCLUDE_FACE_MAP` + read the face-map channel.
    public var includeFaceMap: Bool

    public init() {
        self.enforceGeneralPosition = true
        self.seal = false
        self.requireThroughCuts = false
        self.triangulate = false
        self.includeSeams = false
        self.includeIntersectionType = false
        self.includeVertexMap = false
        self.includeFaceMap = false
    }
}

/// How the two input meshes were found to intersect (`McDispatchIntersectionType`).
public enum IntersectionType: Sendable {
    case standard          // edges cross faces — a normal cut configuration
    case sourceInsideCut   // the source mesh lies inside the (watertight) cut mesh
    case cutInsideSource   // the cut mesh lies inside the (watertight) source mesh
    case none              // the meshes do not intersect or enclose one another
}

// MARK: - Result

/// The connected components produced by a cut, split by type.
public struct CutResult: Sendable {
    public let fragments: [Fragment]
    public let patches:   [Patch]
    public let seams:     [Seam]              // empty unless options.includeSeams
    public let intersectionType: IntersectionType?   // non-nil iff options.includeIntersectionType
}

/// A connected component originating from the source mesh.
public struct Fragment: Sendable {
    public let mesh: MCUTMesh
    public let triangulatedFaceIndices: [UInt32]?   // non-nil iff options.triangulate
    public let location: FragmentLocation           // McFragmentLocation
    public let sealType: FragmentSealType           // McFragmentSealType
    public let vertexMap: [UInt32]?                  // non-nil iff options.includeVertexMap
    public let faceMap:   [UInt32]?                  // non-nil iff options.includeFaceMap
}

/// A connected component originating from the cut mesh.
public struct Patch: Sendable {
    public let mesh: MCUTMesh
    public let triangulatedFaceIndices: [UInt32]?
    public let location: PatchLocation              // McPatchLocation
    public let vertexMap: [UInt32]?
    public let faceMap:   [UInt32]?
}

/// An input mesh reproduced with the new intersection edges along the cut path.
public struct Seam: Sendable {
    public let mesh: MCUTMesh
    public let origin: SeamOrigin                   // McSeamOrigin
}

/// Location of a fragment relative to the cut mesh (`McFragmentLocation`).
public enum FragmentLocation: Sendable { case above, below, undefined }
/// Hole-filling state of a fragment (`McFragmentSealType`).
public enum FragmentSealType:  Sendable { case complete, none }
/// Location of a patch relative to the source mesh (`McPatchLocation`).
public enum PatchLocation:     Sendable { case inside, outside, undefined }
/// Input mesh a seam is derived from (`McSeamOrigin`).
public enum SeamOrigin:        Sendable { case sourceMesh, cutMesh }
