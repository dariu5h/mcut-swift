# Build & release

How the `Cmcut.xcframework` binary is produced and shipped. Day-to-day Swift work doesn't touch this —
read it when you change `scripts/build-xcframework.sh`, bump the mcut submodule, or cut a release.

## How the package is structured

Two artifacts make up "the package":
- **the repo** (`Package.swift` + `Sources/MCUT` + scripts) — referenced by URL by consumers;
- **a GitHub Release** carrying `Cmcut.xcframework.zip` — the binary the manifest points at.

Consumers only add the repo URL; SwiftPM reads the manifest and downloads the release binary.
The submodule, scripts, and workflow are build-time machinery — consumers never run them.

```
Package.swift          binaryTarget(Cmcut, dynamic) + target(MCUT) depends on Cmcut
Sources/MCUT/          Swifty API (errors as throws, OptionSet flags, MCUTMesh, ops)
Sources/MCUTSwifty/    opt-in ModelIO/RealityKit interop product (depends on MCUT)
external/mcut/         submodule, pinned tag — DO NOT EDIT
scripts/
  build-xcframework.sh build all slices (native CMake iOS support), wrap dylib→framework, create-xcframework
.github/workflows/
  update-binary.yml    manual-trigger: rebuild binary from submodule → upload asset → bump manifest → tag
```

## Commands

Init the submodule first in a fresh checkout:
```bash
git submodule update --init --recursive
```

**Fast dev loop — build the macOS slice only** (quickest to iterate on the native build):
```bash
cmake -B build-macos -S external/mcut \
  -DCMAKE_OSX_SYSROOT=macosx -DCMAKE_OSX_ARCHITECTURES=arm64 -DCMAKE_OSX_DEPLOYMENT_TARGET=15.0 \
  -DMCUT_BUILD_AS_SHARED_LIB=ON -DMCUT_BUILD_TESTS=OFF -DMCUT_BUILD_TUTORIALS=OFF \
  -DCMAKE_BUILD_TYPE=Release
cmake --build build-macos --config Release
```

**Full xcframework build** (local verification only — releases go through the workflow):
```bash
./scripts/build-xcframework.sh        # produces out/Cmcut.xcframework + prints the checksum
```

**Run tests** (resolves whatever `Package.swift` points at — currently the released remote binary):
```bash
swift test
```

Slices the build produces (native CMake, no third-party toolchain): iOS device (`arm64`, sysroot
`iphoneos`), iOS simulator (`arm64;x86_64` lipo'd into one fat binary, sysroot `iphonesimulator`),
and macOS (`arm64`, sysroot `macosx`).

## Package.swift: dev vs release

- **During development**, point the binary target at a local path for fast iteration:
  `.binaryTarget(name: "Cmcut", path: "out/Cmcut.xcframework")`.
- **For release**, the workflow rewrites it to the remote form:
  `.binaryTarget(name: "Cmcut", url: "<release-asset>", checksum: "<computed>")`.
- **No `.linkedLibrary("c++")`** on the `MCUT` target — a dynamic framework links libc++ itself.
  (That linker setting was only needed for a static build; do not add it here.)

## Updating the binary

Rebuild the xcframework **only when the mcut C++ changes** — i.e. you bump the `external/mcut`
submodule. Swift-only changes never need it: the published release asset stays valid, so just tag a
new version (no CI run). The `update-binary` workflow is the *only* sanctioned way to ship a binary;
don't build + upload one by hand.

To ship a new binary:

1. **Bump the submodule** to the new upstream tag, commit the new pointer, and push:
   ```bash
   git -C external/mcut fetch --tags && git -C external/mcut checkout <new-tag>
   git add external/mcut && git commit -m "Bump mcut to <new-tag>" && git push
   ```
2. **Run the workflow:** GitHub → Actions → **Update Binary** → *Run workflow*, and type a new
   version (e.g. `0.1.0`). It builds all slices, publishes the Release asset, rewrites `Package.swift`
   (url + checksum), commits that, and tags the version — all in one run, so the three can't drift.
3. **`git pull`** afterward — the workflow pushed a manifest commit to your branch.

Footguns:
- **The workflow creates the tag** from the version you type. Never pre-tag a version you're about to
  build — a pre-existing tag is rejected up front (the "Reject a version that already exists" step).
- **Triggering needs WRITE access**, so only you (and explicit collaborators) can run it; public
  visibility does not grant it.

## Packaging internals (what build-xcframework.sh enforces)

The script already embodies these — mind them only if you edit it.

- **Simulator slice must be a fat binary** (arm64 + x86_64 lipo'd) — an xcframework allows only one
  library per platform variant.
- **iOS framework layout is flat; macOS is versioned** (`Versions/A/…`). Handled per-platform in the
  wrap step.
- **Install name must be** `@rpath/Cmcut.framework/Cmcut` (`install_name_tool -id`) or the framework
  won't load from the app bundle.
- **Framework contents:** the dylib renamed to `Cmcut`, an umbrella `Headers/Cmcut.h`
  (`#include <stdbool.h>` then `#include "mcut.h"` — mcut.h uses `bool` but never includes stdbool,
  as it's only ever compiled as C++ upstream) alongside `mcut.h`/`platform.h`, `Modules/module.modulemap`
  (`framework module Cmcut { header "Cmcut.h" export * }`), and an `Info.plist` with
  `CFBundleExecutable=Cmcut`, `CFBundlePackageType=FMWK`, `MinimumOSVersion`, `CFBundleSupportedPlatforms`.
- **Release checksum is chicken-and-egg:** the artifact must exist before its checksum can be computed,
  so the workflow builds + computes + rewrites the manifest in one run. Don't pin a checksum by hand
  ahead of a build.
