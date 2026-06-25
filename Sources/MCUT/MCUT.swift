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
}
