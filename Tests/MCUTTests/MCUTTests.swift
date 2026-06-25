import XCTest
import simd
@testable import MCUT

final class MCUTTests: XCTestCase {

    // MARK: - Fixtures

    /// Axis-aligned box with the cube's outward winding, spanning [lo, hi].
    private static func box(min lo: SIMD3<Float>, max hi: SIMD3<Float>) -> MCUTMesh {
        let positions: [SIMD3<Float>] = [
            [lo.x, lo.y, lo.z], [hi.x, lo.y, lo.z], [hi.x, hi.y, lo.z], [lo.x, hi.y, lo.z],
            [lo.x, lo.y, hi.z], [hi.x, lo.y, hi.z], [hi.x, hi.y, hi.z], [lo.x, hi.y, hi.z],
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

    /// Unit cube spanning [-1, 1]^3 — 8 verts, 12 outward-wound triangles.
    private static func cube() -> MCUTMesh {
        box(min: [-1, -1, -1], max: [1, 1, 1])
    }

    /// A second cube overlapping `cube()` in one corner octant, deliberately offset by
    /// non-integer amounts in y/z so no face is coplanar with `cube()`'s (which would be a
    /// hard general-position violation). Spans x[0,2] y[-0.3,1.7] z[-0.7,1.3]; volume 8.
    /// Overlap with the unit cube is the box x[0,1] y[-0.3,1] z[-0.7,1] → volume 1·1.3·1.7 = 2.21.
    private static func cubeB() -> MCUTMesh {
        box(min: [0, -0.3, -0.7], max: [2, 1.7, 1.3])
    }

    /// Signed volume of a (closed) mesh via the divergence theorem, fan-triangulating each
    /// face from its first vertex. Positive for outward-facing winding.
    private static func signedVolume(_ mesh: MCUTMesh) -> Float {
        var vol: Float = 0
        var cursor = 0
        for size in mesh.faceSizes {
            let n = Int(size)
            let p0 = mesh.positions[Int(mesh.faceIndices[cursor])]
            for k in 1..<(n - 1) {
                let p1 = mesh.positions[Int(mesh.faceIndices[cursor + k])]
                let p2 = mesh.positions[Int(mesh.faceIndices[cursor + k + 1])]
                vol += simd_dot(p0, simd_cross(p1, p2))
            }
            cursor += n
        }
        return vol / 6
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

    // MARK: - Tier B: boolean / CSG

    // Known volumes for the two overlapping-cube fixtures.
    private static let volA: Float = 8
    private static let volB: Float = 8
    private static let volOverlap: Float = 1 * 1.3 * 1.7   // 2.21

    /// `union` is watertight and encloses A + B − overlap.
    func testUnionVolumeAndWatertight() throws {
        let result = try MCUTContext().union(Self.cube(), Self.cubeB())

        XCTAssertTrue(Self.isWatertight(result), "union should be watertight")
        let v = Self.signedVolume(result)
        XCTAssertGreaterThan(v, 0, "union faces should be outward-wound")
        XCTAssertEqual(v, Self.volA + Self.volB - Self.volOverlap, accuracy: 0.05)
    }

    /// `intersect` encloses just the overlap box.
    func testIntersectVolumeAndWatertight() throws {
        let result = try MCUTContext().intersect(Self.cube(), Self.cubeB())

        XCTAssertTrue(Self.isWatertight(result), "intersection should be watertight")
        let v = Self.signedVolume(result)
        XCTAssertGreaterThan(v, 0, "intersection faces should be outward-wound")
        XCTAssertEqual(v, Self.volOverlap, accuracy: 0.05)
    }

    /// `subtract` (A − B) encloses A minus the overlap.
    func testSubtractVolumeAndWatertight() throws {
        let result = try MCUTContext().subtract(Self.cubeB(), from: Self.cube())

        XCTAssertTrue(Self.isWatertight(result), "difference should be watertight")
        let v = Self.signedVolume(result)
        XCTAssertGreaterThan(v, 0, "difference faces should be outward-wound")
        XCTAssertEqual(v, Self.volA - Self.volOverlap, accuracy: 0.05)
    }

    /// The transient free functions and a reusable context agree.
    func testBooleanReusableContext() throws {
        let context = try MCUTContext()
        let u = try context.union(Self.cube(), Self.cubeB())
        let i = try context.intersect(Self.cube(), Self.cubeB())
        // A reused context handles successive dispatches without leaking state across them.
        XCTAssertGreaterThan(Self.signedVolume(u), Self.signedVolume(i))
    }

    /// `slice` splits the cube into two sealed halves of equal volume on the `normal`-positive
    /// (`above`) and negative (`below`) sides of the plane.
    func testSliceCubeIntoHalves() throws {
        let (above, below) = try MCUTContext().slice(Self.cube(), byPlane: [0, 1, 0], offset: 0)

        XCTAssertTrue(Self.isWatertight(above), "upper half should be watertight")
        XCTAssertTrue(Self.isWatertight(below), "lower half should be watertight")

        XCTAssertEqual(Self.signedVolume(above), 4, accuracy: 0.05, "upper half is half the cube")
        XCTAssertEqual(Self.signedVolume(below), 4, accuracy: 0.05, "lower half is half the cube")

        // `above` is the +y side; `below` is the −y side.
        for p in above.positions { XCTAssertGreaterThanOrEqual(p.y, -0.001) }
        for p in below.positions { XCTAssertLessThanOrEqual(p.y, 0.001) }
    }

    // MARK: - Vertex welding

    /// Duplicate every face's vertices so no two faces share an index — mimics the attribute-split
    /// "polygon soup" that Model I/O / RealityKit meshes arrive as.
    private static func exploded(_ mesh: MCUTMesh) -> MCUTMesh {
        var positions = [SIMD3<Float>]()
        var faceIndices = [UInt32]()
        var cursor = 0
        for size in mesh.faceSizes {
            let n = Int(size)
            for k in 0..<n {
                faceIndices.append(UInt32(positions.count))
                positions.append(mesh.positions[Int(mesh.faceIndices[cursor + k])])
            }
            cursor += n
        }
        return MCUTMesh(positions: positions, faceIndices: faceIndices, faceSizes: mesh.faceSizes)
    }

    func testWeldReconnectsExplodedMesh() throws {
        let soup = Self.exploded(Self.cube())
        XCTAssertFalse(Self.isWatertight(soup), "an exploded soup shares no edges")
        XCTAssertEqual(soup.positions.count, Int(soup.faceSizes.reduce(0, +)),
                       "every face corner is its own vertex")

        let welded = soup.welded()
        XCTAssertTrue(Self.isWatertight(welded), "welding restores shared edges")
        XCTAssertEqual(welded.positions.count, Self.cube().positions.count,
                       "merges back to the 8 cube corners")
        XCTAssertEqual(Self.signedVolume(welded), Self.signedVolume(Self.cube()), accuracy: 1e-4,
                       "welding preserves geometry")
    }

    /// The payoff: an unwelded soup can't be booleaned, but welding makes the same inputs work.
    func testWeldEnablesBooleanOnExplodedInputs() throws {
        let a = Self.exploded(Self.cube()).welded()
        let b = Self.exploded(Self.cubeB()).welded()
        let union = try MCUTContext().union(a, b)
        XCTAssertTrue(Self.isWatertight(union), "boolean of welded soups is watertight")
        XCTAssertEqual(Self.signedVolume(union), 8 + 8 - (1 * 1.3 * 1.7), accuracy: 0.05)
    }

    // MARK: - mcut triangulation (FACE_TRIANGULATION)

    /// Signed volume computed from `triangleIndices` (mcut's CDT) rather than the faces. If the
    /// triangulation correctly tiles the same solid, this matches the face-based volume.
    private static func signedVolumeFromTriangles(_ mesh: MCUTMesh) -> Float {
        let tris = mesh.triangleIndices!
        var vol: Float = 0
        for i in stride(from: 0, to: tris.count, by: 3) {
            let p0 = mesh.positions[Int(tris[i])]
            let p1 = mesh.positions[Int(tris[i + 1])]
            let p2 = mesh.positions[Int(tris[i + 2])]
            vol += simd_dot(p0, simd_cross(p1, p2))
        }
        return vol / 6
    }

    func testBooleanResultCarriesTriangulation() throws {
        let union = try MCUTContext().union(Self.cube(), Self.cubeB())
        let tris = try XCTUnwrap(union.triangleIndices, "boolean result carries mcut's CDT")
        XCTAssertEqual(tris.count % 3, 0, "triangulation is a flat 3·N index list")
        XCTAssertTrue(tris.allSatisfy { $0 < UInt32(union.positions.count) }, "indices are in range")
        // The triangulation must tile the very same solid as the n-gon faces.
        XCTAssertEqual(Self.signedVolumeFromTriangles(union), Self.signedVolume(union), accuracy: 1e-3,
                       "CDT tiles the same volume as the faces")
    }

    func testSliceHalvesCarryTriangulation() throws {
        let (above, below) = try MCUTContext().slice(Self.cube(), byPlane: [0, 1, 0], offset: 0)
        XCTAssertEqual(Self.signedVolumeFromTriangles(above), 4, accuracy: 0.05)
        XCTAssertEqual(Self.signedVolumeFromTriangles(below), 4, accuracy: 0.05)
    }

    func testWeldClearsTriangulation() {
        // A triangle-soup mesh's triangulation is its own indices; welding renumbers vertices, so it
        // must be dropped rather than left dangling.
        XCTAssertNotNil(Self.cube().triangleIndices, "triangles: init seeds the triangulation")
        XCTAssertNil(Self.cube().welded().triangleIndices, "welding clears the stale triangulation")
    }

    func testWeldDropsDegenerateFaces() throws {
        // A triangle with two coincident corners collapses to an edge and is dropped; the second
        // triangle is non-degenerate and survives.
        let mesh = MCUTMesh(
            triangles: [[0, 0, 0], [1, 0, 0], [0, 0, 0],
                        [0, 0, 0], [1, 0, 0], [0, 1, 0]].map { SIMD3<Float>($0[0], $0[1], $0[2]) },
            indices: [0, 1, 2, 3, 4, 5])
        let welded = mesh.welded()
        XCTAssertEqual(welded.faceSizes.count, 1, "the degenerate triangle is removed")
        XCTAssertEqual(welded.faceSizes.first, 3, "the surviving face is still a triangle")
    }
}
