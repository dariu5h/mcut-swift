import XCTest
@testable import MCUT

final class MCUTTests: XCTestCase {

    // MARK: - Fixtures

    /// Unit cube spanning [-1, 1]^3 — 8 verts, 12 outward-wound triangles.
    private static func cube() -> MCUTMesh {
        let positions: [SIMD3<Float>] = [
            [-1, -1, -1], [1, -1, -1], [1, 1, -1], [-1, 1, -1],
            [-1, -1,  1], [1, -1,  1], [1, 1,  1], [-1, 1,  1],
        ]
        let indices: [UInt32] = [
            0, 3, 2,  0, 2, 1,   // -Z
            4, 5, 6,  4, 6, 7,   // +Z
            0, 4, 7,  0, 7, 3,   // -X
            1, 2, 6,  1, 6, 5,   // +X
            0, 1, 5,  0, 5, 4,   // -Y
            3, 7, 6,  3, 6, 2,   // +Y
        ]
        return MCUTMesh(triangles: positions, indices: indices)
    }

    /// Horizontal plane quad at y, spanning [-extent, extent] in X/Z.
    private static func planeQuad(y: Float, extent: Float) -> MCUTMesh {
        let positions: [SIMD3<Float>] = [
            [-extent, y, -extent], [extent, y, -extent],
            [ extent, y,  extent], [-extent, y,  extent],
        ]
        return MCUTMesh(triangles: positions, indices: [0, 1, 2,  0, 2, 3])
    }

    /// True if every (undirected) edge is shared by exactly two faces — i.e. closed/watertight.
    private static func isWatertight(_ mesh: MCUTMesh) -> Bool {
        var counts: [SIMD2<UInt32>: Int] = [:]
        var cursor = 0
        for size in mesh.faceSizes {
            let n = Int(size)
            for k in 0..<n {
                let a = mesh.faceIndices[cursor + k]
                let b = mesh.faceIndices[cursor + (k + 1) % n]
                let edge = SIMD2(min(a, b), max(a, b))
                counts[edge, default: 0] += 1
            }
            cursor += n
        }
        return !counts.isEmpty && counts.values.allSatisfy { $0 == 2 }
    }

    // MARK: - Tier A: faithful cut

    /// A plane through-cut of a cube yields two fragments (above + below), each with
    /// real, non-degenerate geometry.
    func testThroughCutYieldsTwoFragments() throws {
        let result = try cut(Self.cube(), with: Self.planeQuad(y: 0, extent: 2))

        XCTAssertEqual(result.fragments.count, 2,
                       "a plane through-cut should sever the cube into 2 fragments")

        let locations = Set(result.fragments.map(\.location))
        XCTAssertEqual(locations, [.above, .below],
                       "the two fragments should be one above and one below the cut")

        for (i, frag) in result.fragments.enumerated() {
            XCTAssertFalse(frag.mesh.positions.isEmpty, "fragment \(i) should have vertices")
            XCTAssertFalse(frag.mesh.faceSizes.isEmpty, "fragment \(i) should have faces")
            XCTAssertEqual(Int(frag.mesh.faceSizes.reduce(0, +)), frag.mesh.faceIndices.count,
                           "fragment \(i): faceSizes must sum to faceIndices.count")
            // Every fragment stays within the cube's bounds; the cut is at y = 0.
            for p in frag.mesh.positions {
                XCTAssertLessThanOrEqual(abs(p.x), 1.001)
                XCTAssertLessThanOrEqual(abs(p.y), 1.001)
                XCTAssertLessThanOrEqual(abs(p.z), 1.001)
            }
            XCTAssertNil(frag.triangulatedFaceIndices, "triangulation is opt-in")
        }
    }

    /// A reusable context produces the same answer as the transient free function.
    func testReusableContextMatchesTransient() throws {
        let context = try MCUTContext()
        let viaContext = try context.cut(Self.cube(), with: Self.planeQuad(y: 0, extent: 2))
        let viaFree = try cut(Self.cube(), with: Self.planeQuad(y: 0, extent: 2))
        XCTAssertEqual(viaContext.fragments.count, viaFree.fragments.count)
    }

    /// With `triangulate`, each component exposes a triangle-index list that is a multiple of 3.
    func testTriangulationOptIn() throws {
        var options = CutOptions()
        options.triangulate = true
        let result = try cut(Self.cube(), with: Self.planeQuad(y: 0, extent: 2), options: options)

        XCTAssertFalse(result.fragments.isEmpty)
        for frag in result.fragments {
            let tris = try XCTUnwrap(frag.triangulatedFaceIndices,
                                     "triangulatedFaceIndices should be non-nil when triangulate is on")
            XCTAssertFalse(tris.isEmpty)
            XCTAssertEqual(tris.count % 3, 0, "triangulated indices must be a multiple of 3")
        }
    }

    /// A partial (non-through) cut produces a fragment whose location is neither above nor
    /// below: `.undefined`. The plane spans the cube fully in X but stops at z = 0, so its
    /// trailing edge lies inside the cube and the cut cannot sever it.
    func testPartialCutYieldsUndefinedFragment() throws {
        let partialPlane = MCUTMesh(
            triangles: [[-2, 0, -2], [2, 0, -2], [2, 0, 0], [-2, 0, 0]],
            indices: [0, 1, 2,  0, 2, 3])
        let result = try cut(Self.cube(), with: partialPlane)
        let hasUndefined = result.fragments.contains { $0.location == .undefined }
        XCTAssertTrue(hasUndefined,
                      "a partial cut should yield at least one .undefined-location fragment")
    }

    /// With `seal`, the through-cut halves come back watertight and report `.complete`.
    func testSealedFragmentsAreWatertight() throws {
        var options = CutOptions()
        options.seal = true
        let result = try cut(Self.cube(), with: Self.planeQuad(y: 0, extent: 2), options: options)

        XCTAssertEqual(result.fragments.count, 2, "a sealed through-cut should still yield 2 fragments")
        for (i, frag) in result.fragments.enumerated() {
            XCTAssertEqual(frag.sealType, .complete, "sealed fragment \(i) should report .complete")
            XCTAssertTrue(Self.isWatertight(frag.mesh), "sealed fragment \(i) should be watertight")
        }
    }

    /// `requireThroughCuts` turns a partial cut into a no-op: no fragments come back.
    func testRequireThroughCutsRejectsPartialCut() throws {
        let partialPlane = MCUTMesh(
            triangles: [[-2, 0, -2], [2, 0, -2], [2, 0, 0], [-2, 0, 0]],
            indices: [0, 1, 2,  0, 2, 3])

        var options = CutOptions()
        options.requireThroughCuts = true
        let result = try cut(Self.cube(), with: partialPlane, options: options)
        XCTAssertTrue(result.fragments.isEmpty,
                      "requireThroughCuts should make a partial cut produce no fragments")

        // The same flag still admits a real through-cut.
        let through = try cut(Self.cube(), with: Self.planeQuad(y: 0, extent: 2), options: options)
        XCTAssertEqual(through.fragments.count, 2)
    }

    /// `includeIntersectionType` classifies a normal cut as `.standard`.
    func testIntersectionTypeReadback() throws {
        var options = CutOptions()
        options.includeIntersectionType = true
        let result = try cut(Self.cube(), with: Self.planeQuad(y: 0, extent: 2), options: options)
        XCTAssertEqual(result.intersectionType, .standard,
                       "a plane crossing the cube faces is a standard intersection")
    }

    /// Without the option, `intersectionType` is nil and the maps stay off.
    func testIntersectionTypeOptInOnly() throws {
        let result = try cut(Self.cube(), with: Self.planeQuad(y: 0, extent: 2))
        XCTAssertNil(result.intersectionType)
    }

    /// `includeVertexMap` traces output vertices back to inputs; cut-born vertices map to max.
    func testVertexMapTracesProvenance() throws {
        var options = CutOptions()
        options.includeVertexMap = true
        options.includeFaceMap = true
        let result = try cut(Self.cube(), with: Self.planeQuad(y: 0, extent: 2), options: options)

        let frag = try XCTUnwrap(result.fragments.first)
        let vmap = try XCTUnwrap(frag.vertexMap)
        let fmap = try XCTUnwrap(frag.faceMap)

        XCTAssertEqual(vmap.count, frag.mesh.positions.count, "one vertex-map entry per vertex")
        XCTAssertEqual(fmap.count, frag.mesh.faceSizes.count, "one face-map entry per face")
        // Original cube corners survive (some entry < 8); cut-seam vertices map to UInt32.max.
        XCTAssertTrue(vmap.contains { $0 != .max }, "some vertices trace back to an input vertex")
        XCTAssertTrue(vmap.contains(.max), "cut-seam vertices map to MC_UNDEFINED_VALUE")
        // Every face maps to a real input face (never undefined).
        XCTAssertFalse(fmap.contains(.max), "every output face maps to an input face")
    }
}
