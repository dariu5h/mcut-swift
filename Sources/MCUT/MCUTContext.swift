import Cmcut

/// A reusable mcut working state. Wraps `McContext` with RAII: the handle is created
/// on `init` and released on `deinit`, and never escapes in a public signature.
public final class MCUTContext {
    private let context: McContext

    /// Creates an mcut context (`mcCreateContext`).
    public init() throws {
        var ctx: McContext?
        try MCUTContext.check(mcCreateContext(&ctx, McFlags(0)))
        guard let ctx else { throw MCUTError.invalidOperation }
        self.context = ctx
    }

    deinit {
        mcReleaseContext(context)
    }

    /// Severs `source` along its intersection with `cutMesh` and returns the resulting
    /// connected components (`mcDispatch` + readback).
    public func cut(_ source: MCUTMesh, with cutMesh: MCUTMesh,
                    options: CutOptions = CutOptions()) throws -> CutResult {
        let flags = MCUTContext.dispatchFlags(options)

        // Flatten positions to contiguous xyzxyz… ; indices/sizes pass straight through.
        let srcVerts = MCUTContext.flatten(source.positions)
        let cutVerts = MCUTContext.flatten(cutMesh.positions)

        try MCUTContext.check(mcDispatch(
            context, flags,
            srcVerts, source.faceIndices, source.faceSizes,
            UInt32(source.positions.count), UInt32(source.faceSizes.count),
            cutVerts, cutMesh.faceIndices, cutMesh.faceSizes,
            UInt32(cutMesh.positions.count), UInt32(cutMesh.faceSizes.count)))

        var fragments = try readComponents(of: MC_CONNECTED_COMPONENT_TYPE_FRAGMENT) {
            try makeFragment($0, options: options)
        }
        // Asking for SEALING_INSIDE returns each half both unsealed and watertight; keep only
        // the watertight (`.complete`) ones so `seal` yields exactly the sealed fragments.
        if options.seal {
            fragments = fragments.filter { $0.sealType == .complete }
        }
        let patches = try readComponents(of: MC_CONNECTED_COMPONENT_TYPE_PATCH) {
            try makePatch($0, options: options)
        }
        let seams = options.includeSeams
            ? try readComponents(of: MC_CONNECTED_COMPONENT_TYPE_SEAM) { try makeSeam($0) }
            : []

        let intersectionType = try options.includeIntersectionType ? readIntersectionType() : nil

        return CutResult(fragments: fragments, patches: patches, seams: seams,
                         intersectionType: intersectionType)
    }

    /// Read the classification stored by the last dispatch (`MC_CONTEXT_DISPATCH_INTERSECTION_TYPE`).
    /// The value is a fixed-size scalar, so we pass its known size rather than a byte-count pass.
    private func readIntersectionType() throws -> IntersectionType {
        var raw: UInt32 = 0
        try MCUTContext.check(mcGetInfo(
            context, McFlags(MC_CONTEXT_DISPATCH_INTERSECTION_TYPE.rawValue),
            McSize(MemoryLayout<UInt32>.size), &raw, nil))
        return MCUTContext.intersectionType(raw)
    }

    // MARK: - Connected component retrieval

    /// Two-pass `mcGetConnectedComponents` (count, then fetch handles), build a value from
    /// each component, then release them. The handles must outlive `build` — releasing earlier
    /// would leave `build` reading freed components.
    ///
    /// The fetch call must pass `nil` for the count out-param — reusing the count variable there
    /// makes mcut overwrite it to 0.
    private func readComponents<T>(of type: McConnectedComponentType,
                                   _ build: (McConnectedComponent) throws -> T) throws -> [T] {
        var count: UInt32 = 0
        try MCUTContext.check(mcGetConnectedComponents(context, type, 0, nil, &count))
        guard count > 0 else { return [] }

        var handles = [McConnectedComponent?](repeating: nil, count: Int(count))
        try MCUTContext.check(mcGetConnectedComponents(context, type, count, &handles, nil))
        defer { mcReleaseConnectedComponents(context, count, handles) }

        return try handles.compactMap { $0 }.map(build)
    }

    // MARK: - Per-component assembly

    private func makeFragment(_ comp: McConnectedComponent, options: CutOptions) throws -> Fragment {
        Fragment(
            mesh: try readMesh(comp),
            triangulatedFaceIndices: try options.triangulate ? readTriangulation(comp) : nil,
            location: MCUTContext.fragmentLocation(try readScalar(comp, MC_CONNECTED_COMPONENT_DATA_FRAGMENT_LOCATION)),
            sealType: MCUTContext.fragmentSealType(try readScalar(comp, MC_CONNECTED_COMPONENT_DATA_FRAGMENT_SEAL_TYPE)),
            vertexMap: try options.includeVertexMap ? readChannel(comp, MC_CONNECTED_COMPONENT_DATA_VERTEX_MAP) : nil,
            faceMap: try options.includeFaceMap ? readChannel(comp, MC_CONNECTED_COMPONENT_DATA_FACE_MAP) : nil)
    }

    private func makePatch(_ comp: McConnectedComponent, options: CutOptions) throws -> Patch {
        Patch(
            mesh: try readMesh(comp),
            triangulatedFaceIndices: try options.triangulate ? readTriangulation(comp) : nil,
            location: MCUTContext.patchLocation(try readScalar(comp, MC_CONNECTED_COMPONENT_DATA_PATCH_LOCATION)),
            vertexMap: try options.includeVertexMap ? readChannel(comp, MC_CONNECTED_COMPONENT_DATA_VERTEX_MAP) : nil,
            faceMap: try options.includeFaceMap ? readChannel(comp, MC_CONNECTED_COMPONENT_DATA_FACE_MAP) : nil)
    }

    private func makeSeam(_ comp: McConnectedComponent) throws -> Seam {
        Seam(
            mesh: try readMesh(comp),
            origin: MCUTContext.seamOrigin(try readScalar(comp, MC_CONNECTED_COMPONENT_DATA_ORIGIN)))
    }

    /// Rebuild geometry from the VERTEX_FLOAT / FACE / FACE_SIZE channels.
    private func readMesh(_ comp: McConnectedComponent) throws -> MCUTMesh {
        let flat: [Float] = try readChannel(comp, MC_CONNECTED_COMPONENT_DATA_VERTEX_FLOAT)
        var positions = [SIMD3<Float>]()
        positions.reserveCapacity(flat.count / 3)
        for i in stride(from: 0, to: flat.count, by: 3) {
            positions.append(SIMD3<Float>(flat[i], flat[i + 1], flat[i + 2]))
        }
        return MCUTMesh(
            positions: positions,
            faceIndices: try readChannel(comp, MC_CONNECTED_COMPONENT_DATA_FACE),
            faceSizes: try readChannel(comp, MC_CONNECTED_COMPONENT_DATA_FACE_SIZE))
    }

    private func readTriangulation(_ comp: McConnectedComponent) throws -> [UInt32] {
        try readChannel(comp, MC_CONNECTED_COMPONENT_DATA_FACE_TRIANGULATION)
    }

    // MARK: - Two-pass data channel reader

    /// Generic two-pass read of a connected-component data channel: query the byte count,
    /// then fetch into a typed buffer. Works for any trivially-copyable element (Float, UInt32).
    private func readChannel<T>(_ comp: McConnectedComponent,
                                _ query: McConnectedComponentData) throws -> [T] {
        var numBytes: McSize = 0
        try MCUTContext.check(mcGetConnectedComponentData(
            context, comp, McFlags(query.rawValue), 0, nil, &numBytes))

        let count = Int(numBytes) / MemoryLayout<T>.stride
        guard count > 0 else { return [] }

        return try [T](unsafeUninitializedCapacity: count) { buffer, initialized in
            try MCUTContext.check(mcGetConnectedComponentData(
                context, comp, McFlags(query.rawValue), numBytes, buffer.baseAddress, nil))
            initialized = count
        }
    }

    /// Read a single-`UInt32` metadata channel (TYPE / LOCATION / SEAL_TYPE / ORIGIN).
    private func readScalar(_ comp: McConnectedComponent,
                            _ query: McConnectedComponentData) throws -> UInt32 {
        let values: [UInt32] = try readChannel(comp, query)
        return values.first ?? 0
    }

    // MARK: - Flag building

    private static func dispatchFlags(_ options: CutOptions) -> McFlags {
        var bits = UInt32(MC_DISPATCH_VERTEX_ARRAY_FLOAT.rawValue)

        if options.enforceGeneralPosition {
            bits |= UInt32(MC_DISPATCH_ENFORCE_GENERAL_POSITION.rawValue)
        }
        if options.includeVertexMap {
            bits |= UInt32(MC_DISPATCH_INCLUDE_VERTEX_MAP.rawValue)
        }
        if options.includeFaceMap {
            bits |= UInt32(MC_DISPATCH_INCLUDE_FACE_MAP.rawValue)
        }
        if options.includeIntersectionType {
            bits |= UInt32(MC_DISPATCH_INCLUDE_INTERSECTION_TYPE.rawValue)
        }

        // Fragment locations: above and below always. Undefined (partial) fragments and the
        // through-cut requirement are mutually exclusive per the header, so they are exclusive here.
        bits |= UInt32(MC_DISPATCH_FILTER_FRAGMENT_LOCATION_ABOVE.rawValue)
        bits |= UInt32(MC_DISPATCH_FILTER_FRAGMENT_LOCATION_BELOW.rawValue)
        if options.requireThroughCuts {
            bits |= UInt32(MC_DISPATCH_REQUIRE_THROUGH_CUTS.rawValue)
        } else {
            bits |= UInt32(MC_DISPATCH_FILTER_FRAGMENT_LOCATION_UNDEFINED.rawValue)
        }

        // Sealing: watertight (hole-filled) fragments when requested, else open shells.
        if options.seal {
            bits |= UInt32(MC_DISPATCH_FILTER_FRAGMENT_SEALING_INSIDE.rawValue)
        } else {
            bits |= UInt32(MC_DISPATCH_FILTER_FRAGMENT_SEALING_NONE.rawValue)
        }

        bits |= UInt32(MC_DISPATCH_FILTER_PATCH_INSIDE.rawValue)
        bits |= UInt32(MC_DISPATCH_FILTER_PATCH_OUTSIDE.rawValue)

        if options.includeSeams {
            bits |= UInt32(MC_DISPATCH_FILTER_SEAM_SRCMESH.rawValue)
            bits |= UInt32(MC_DISPATCH_FILTER_SEAM_CUTMESH.rawValue)
        }

        return McFlags(bits)
    }

    // MARK: - Enum mapping

    private static func fragmentLocation(_ raw: UInt32) -> FragmentLocation {
        switch McFragmentLocation(rawValue: raw) {
        case MC_FRAGMENT_LOCATION_ABOVE: return .above
        case MC_FRAGMENT_LOCATION_BELOW: return .below
        default:                         return .undefined
        }
    }

    private static func fragmentSealType(_ raw: UInt32) -> FragmentSealType {
        McFragmentSealType(rawValue: raw) == MC_FRAGMENT_SEAL_TYPE_COMPLETE ? .complete : .none
    }

    private static func patchLocation(_ raw: UInt32) -> PatchLocation {
        switch McPatchLocation(rawValue: raw) {
        case MC_PATCH_LOCATION_INSIDE:  return .inside
        case MC_PATCH_LOCATION_OUTSIDE: return .outside
        default:                        return .undefined
        }
    }

    private static func seamOrigin(_ raw: UInt32) -> SeamOrigin {
        McSeamOrigin(rawValue: raw) == MC_SEAM_ORIGIN_CUTMESH ? .cutMesh : .sourceMesh
    }

    private static func intersectionType(_ raw: UInt32) -> IntersectionType {
        switch McDispatchIntersectionType(rawValue: raw) {
        case MC_DISPATCH_INTERSECTION_TYPE_INSIDE_CUTMESH:   return .sourceInsideCut
        case MC_DISPATCH_INTERSECTION_TYPE_INSIDE_SOURCEMESH: return .cutInsideSource
        case MC_DISPATCH_INTERSECTION_TYPE_NONE:             return .none
        default:                                             return .standard   // 0 == STANDARD
        }
    }

    // MARK: - Helpers

    private static func flatten(_ positions: [SIMD3<Float>]) -> [Float] {
        var flat = [Float]()
        flat.reserveCapacity(positions.count * 3)
        for p in positions { flat.append(p.x); flat.append(p.y); flat.append(p.z) }
        return flat
    }

    /// Map a non-success `McResult` to a thrown `MCUTError`.
    private static func check(_ rc: McResult) throws {
        switch rc {
        case MC_NO_ERROR:          return
        case MC_INVALID_VALUE:     throw MCUTError.invalidValue
        case MC_OUT_OF_MEMORY:     throw MCUTError.outOfMemory
        default:                   throw MCUTError.invalidOperation   // incl. MC_INVALID_OPERATION
        }
    }
}

/// Convenience: spin up a transient context, cut, and tear it down.
public func cut(_ source: MCUTMesh, with cutMesh: MCUTMesh,
                options: CutOptions = CutOptions()) throws -> CutResult {
    try MCUTContext().cut(source, with: cutMesh, options: options)
}
