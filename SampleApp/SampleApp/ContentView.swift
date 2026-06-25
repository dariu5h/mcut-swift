import SwiftUI
import MCUT

struct ContentView: View {
    // Spike 3 (device half): run the context smoke test once at launch.
    // 0 == MC_NO_ERROR -> the dynamic Cmcut.framework loaded and the C API
    // is callable on a real iOS device, not just the simulator/host.
    private let result = MCUT.contextSmokeTest()

    private var ok: Bool { result == 0 }

    var body: some View {
        VStack(spacing: 16) {
            Image(systemName: ok ? "checkmark.seal.fill" : "xmark.seal.fill")
                .font(.system(size: 64))
                .foregroundStyle(ok ? .green : .red)

            Text(ok ? "mcut loaded ✓" : "mcut FAILED")
                .font(.title2.bold())

            Text("mcCreateContext returned \(result)")
                .font(.callout)
                .foregroundStyle(.secondary)

            Text(ok ? "MC_NO_ERROR — framework links + loads on device"
                    : "non-zero McResult — see code above")
                .font(.footnote)
                .multilineTextAlignment(.center)
                .foregroundStyle(.secondary)
                .padding(.horizontal)
        }
        .padding()
    }
}

#Preview {
    ContentView()
}
