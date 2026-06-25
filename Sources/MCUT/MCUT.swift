import Cmcut

public enum MCUT {
    /// Spike 2 smoke check: create then release an mcut context. Proves the dynamic
    /// `Cmcut` framework links and loads and the C symbols are callable from Swift.
    /// Returns the raw `McResult` of the create call (`MC_NO_ERROR` == 0 on success).
    public static func contextSmokeTest() -> Int {
        var ctx: McContext?
        let rc = mcCreateContext(&ctx, McFlags(0))
        if rc == MC_NO_ERROR, let ctx {
            mcReleaseContext(ctx)
        }
        return rc.rawValue
    }

    // MARK: - Spike 4: first real cut (NOT the final API — Phase 5 designs that)

    /// Per-fragment readback counts, proving the two-pass byte-count idiom works.
    public struct SpikeFragment: Sendable {
        public let vertexCount: Int
        public let faceCount: Int
    }

    public struct SpikeCutResult: Sendable {
        public let fragmentCount: Int
        public let fragments: [SpikeFragment]
    }

    public enum SpikeError: Error {
        /// A C call returned a non-`MC_NO_ERROR` result. Carries the call name and raw code.
        case mcut(String, Int)
    }

    /// Spike 4 probe: cut a unit cube (source) with a 4×4 plane at y=0 (cut mesh) that fully
    /// severs it, then read back the resulting FRAGMENT connected components. Proves a real
    /// `mcDispatch` runs end-to-end and CC data reads back via the two-pass idiom.
    /// Expected: 2 fragments (above + below the plane), each with non-zero geometry.
    public static func spikeCutCubeWithPlane() throws -> SpikeCutResult {
        // Source: unit cube spanning [-1, 1]^3 — 8 verts, 12 triangles (outward-wound).
        let cubeVerts: [Float] = [
            -1, -1, -1,   1, -1, -1,   1,  1, -1,  -1,  1, -1,
            -1, -1,  1,   1, -1,  1,   1,  1,  1,  -1,  1,  1,
        ]
        let cubeFaces: [UInt32] = [
            0, 3, 2,  0, 2, 1,   // -Z
            4, 5, 6,  4, 6, 7,   // +Z
            0, 4, 7,  0, 7, 3,   // -X
            1, 2, 6,  1, 6, 5,   // +X
            0, 1, 5,  0, 5, 4,   // -Y
            3, 7, 6,  3, 6, 2,   // +Y
        ]
        let cubeFaceSizes = [UInt32](repeating: 3, count: 12)

        // Cut: horizontal plane at y=0, spanning [-2, 2] in X/Z so it fully severs the cube.
        let planeVerts: [Float] = [
            -2, 0, -2,   2, 0, -2,   2, 0, 2,  -2, 0, 2,
        ]
        let planeFaces: [UInt32] = [0, 1, 2,  0, 2, 3]
        let planeFaceSizes: [UInt32] = [3, 3]

        var ctx: McContext?
        try check("mcCreateContext", mcCreateContext(&ctx, McFlags(0)))
        guard let ctx else { throw SpikeError.mcut("mcCreateContext", -1) }
        defer { mcReleaseContext(ctx) }

        let flags = McFlags(
            UInt32(MC_DISPATCH_VERTEX_ARRAY_FLOAT.rawValue) |
            // Axis-aligned cube vs. axis-aligned plane violates general position;
            // let mcut auto-perturb the cut mesh instead of failing the dispatch.
            UInt32(MC_DISPATCH_ENFORCE_GENERAL_POSITION.rawValue) |
            UInt32(MC_DISPATCH_FILTER_FRAGMENT_LOCATION_ABOVE.rawValue) |
            UInt32(MC_DISPATCH_FILTER_FRAGMENT_LOCATION_BELOW.rawValue) |
            UInt32(MC_DISPATCH_FILTER_FRAGMENT_SEALING_NONE.rawValue)
        )

        try check("mcDispatch", mcDispatch(
            ctx, flags,
            cubeVerts, cubeFaces, cubeFaceSizes, 8, 12,
            planeVerts, planeFaces, planeFaceSizes, 4, 2))

        // First pass: how many fragments? Second pass: fetch their handles.
        // NOTE: the fetch call must pass nil for numConnComps (per the header's own
        // example) — reusing the count variable there makes mcut overwrite it to 0.
        var numCC: UInt32 = 0
        try check("mcGetConnectedComponents(count)",
                  mcGetConnectedComponents(ctx, MC_CONNECTED_COMPONENT_TYPE_FRAGMENT, 0, nil, &numCC))

        var comps = [McConnectedComponent?](repeating: nil, count: Int(numCC))
        if numCC > 0 {
            try check("mcGetConnectedComponents(fetch)",
                      mcGetConnectedComponents(ctx, MC_CONNECTED_COMPONENT_TYPE_FRAGMENT, numCC, &comps, nil))
        }
        defer { mcReleaseConnectedComponents(ctx, numCC, comps) }

        var fragments: [SpikeFragment] = []
        for case let comp? in comps {
            let vertBytes = try byteCount(ctx, comp, MC_CONNECTED_COMPONENT_DATA_VERTEX_FLOAT)
            let faceSizeBytes = try byteCount(ctx, comp, MC_CONNECTED_COMPONENT_DATA_FACE_SIZE)
            fragments.append(SpikeFragment(
                vertexCount: Int(vertBytes) / (3 * MemoryLayout<Float>.size),
                faceCount: Int(faceSizeBytes) / MemoryLayout<UInt32>.size))
        }

        return SpikeCutResult(fragmentCount: Int(numCC), fragments: fragments)
    }

    /// First pass of the two-pass idiom: ask only for the byte count of a CC data channel.
    private static func byteCount(
        _ ctx: McContext, _ comp: McConnectedComponent, _ query: McConnectedComponentData
    ) throws -> McSize {
        var n: McSize = 0
        try check("mcGetConnectedComponentData(\(query))",
                  mcGetConnectedComponentData(ctx, comp, McFlags(query.rawValue), 0, nil, &n))
        return n
    }

    private static func check(_ call: String, _ rc: McResult) throws {
        if rc != MC_NO_ERROR { throw SpikeError.mcut(call, rc.rawValue) }
    }
}
