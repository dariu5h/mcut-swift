import XCTest
@testable import MCUT

final class MCUTTests: XCTestCase {
    // Spike 2 gate: the dynamic Cmcut framework links, loads, and a real mcut
    // context can be created and released. No mesh, no dispatch yet.
    func testContextSmoke() {
        XCTAssertEqual(MCUT.contextSmokeTest(), 0, "mcCreateContext should return MC_NO_ERROR (0)")
    }

    // Spike 4 gate: a real mcDispatch runs (cube ∩ plane through-cut) and the
    // resulting fragments read back via the two-pass byte-count idiom.
    func testCubePlaneCut() throws {
        let result = try MCUT.spikeCutCubeWithPlane()
        XCTAssertEqual(result.fragmentCount, 2,
                       "a plane through-cut of a cube should yield 2 fragments (above + below)")
        for (i, frag) in result.fragments.enumerated() {
            XCTAssertGreaterThan(frag.vertexCount, 0, "fragment \(i) should have vertices")
            XCTAssertGreaterThan(frag.faceCount, 0, "fragment \(i) should have faces")
        }
    }
}
