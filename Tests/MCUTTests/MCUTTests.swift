import XCTest
@testable import MCUT

final class MCUTTests: XCTestCase {
    // Spike 2 gate: the dynamic Cmcut framework links, loads, and a real mcut
    // context can be created and released. No mesh, no dispatch yet.
    func testContextSmoke() {
        XCTAssertEqual(MCUT.contextSmokeTest(), 0, "mcCreateContext should return MC_NO_ERROR (0)")
    }
}
