# CLAUDE.md

Operating context for Claude Code working in this repo. Read this first, every session.
Full rationale and the phased plan live in `mcut-swift-plan.md` — consult it for *why*; this file is *how*.

---

## What this is

`mcut-swift` — a public Swift Package that wraps [cutdigital/mcut](https://github.com/cutdigital/mcut)
(a C++ mesh cutting / boolean library with a flat C API) and exposes an idiomatic Swift API for
iOS and macOS. mcut ships as a **prebuilt dynamic `xcframework`**; the Swift layer is compiled by
consumers.

**Status:** private repo, pre-release. Current phase: _<update this — e.g. "Phase 1: building macOS slice">_.
Phases and acceptance criteria are in `mcut-swift-plan.md` §10.

---

## Hard constraints (do not violate)

1. **Dynamic build only — never static.** mcut is LGPL v3. A dynamic, replaceable framework is the
   compliance mechanism. Do not switch to `-library` / static `.a` packaging.
2. **Never modify `external/mcut/`.** It is an upstream submodule pinned to a tag. Consume it
   unchanged. If a patch seems necessary, stop and ask — do not edit upstream source.
3. **Never commit build artifacts.** `out/`, `build-*/`, `*.xcframework`, `*.xcframework.zip`,
   `*.dylib` are generated. They belong in `.gitignore`, not in git.
4. **API design must come from the real header**, not from memory or this file. When writing or
   changing the Swift wrapper, read `external/mcut/include/mcut/mcut.h` for exact signatures, enums,
   and flag values. The plan's API summary is a guide, not ground truth.
5. **Do not relicense mcut.** The distributed combination is LGPL-3.0 regardless of the wrapper's
   own license. Do not add MIT/Apache headers implying the binary is permissively licensed.
6. **Naming is fixed:** `Cmcut` = the binary framework / C module (raw C symbols);
   `MCUT` = the Swift target / public API. The Swift layer does `import Cmcut` internally.

---

## Architecture

Two artifacts make up "the package":
- **the repo** (`Package.swift` + `Sources/MCUT` + scripts) — referenced by URL by consumers;
- **a GitHub Release** carrying `Cmcut.xcframework.zip` — the binary the manifest points at.

Consumers only add the repo URL; SwiftPM reads the manifest and downloads the release binary.
The submodule, scripts, and workflow are build-time machinery — consumers never run them.

```
Package.swift          binaryTarget(Cmcut, dynamic) + target(MCUT) depends on Cmcut
Sources/MCUT/          Swifty API (errors as throws, OptionSet flags, MCUTMesh, ops)
external/mcut/         submodule, pinned tag — DO NOT EDIT
scripts/
  build-xcframework.sh build all slices, wrap dylib→framework, lipo, create-xcframework
  ios.toolchain.cmake  leetal/ios-cmake toolchain
.github/workflows/
  release.yml          tag → build → upload release asset → bump manifest
```

---

## Commands

Always init the submodule first in a fresh checkout:
```bash
git submodule update --init --recursive
```

**Fast dev loop — build the macOS slice only** (quickest to iterate):
```bash
cmake -B build-macos -S external/mcut \
  -DCMAKE_TOOLCHAIN_FILE=scripts/ios.toolchain.cmake -DPLATFORM=MAC_ARM64 \
  -DMCUT_BUILD_AS_SHARED_LIB=ON -DMCUT_BUILD_TESTS=OFF -DMCUT_BUILD_TUTORIALS=OFF \
  -DCMAKE_BUILD_TYPE=Release
cmake --build build-macos --config Release
```

**Verify C symbols are exported** (bring-up sanity check):
```bash
nm -gU build-macos/libmcut.dylib | grep mcDispatch   # must print the symbol
```

**Full xcframework build:**
```bash
./scripts/build-xcframework.sh        # produces out/Cmcut.xcframework
swift package compute-checksum out/Cmcut.xcframework.zip
```

**Run tests** (against a *local* xcframework during dev — see manifest note below):
```bash
swift test
```

ios-cmake `PLATFORM` values used by the build: `OS64` (iOS device), `SIMULATORARM64` + `SIMULATOR64`
(simulator, lipo'd into one fat binary), `MAC_ARM64` + `MAC` (macOS).

---

## Package.swift: dev vs release

- **During development**, point the binary target at a local path for fast iteration:
  `.binaryTarget(name: "Cmcut", path: "out/Cmcut.xcframework")`.
- **For release**, CI rewrites it to the remote form:
  `.binaryTarget(name: "Cmcut", url: "<release-asset>", checksum: "<computed>")`.
- **No `.linkedLibrary("c++")`** on the `MCUT` target — a dynamic framework links libc++ itself.
  (That linker setting was only needed for a static build; do not add it here.)

---

## Build & packaging footguns

- **Simulator slice must be a fat binary** (arm64 + x86_64 lipo'd) — an xcframework allows only one
  library per platform variant.
- **iOS framework layout is flat; macOS is versioned** (`Versions/A/…`). Handle per-platform in the
  wrap step.
- **Install name must be** `@rpath/Cmcut.framework/Cmcut` (`install_name_tool -id`) or the framework
  won't load from the app bundle.
- **Framework contents:** the dylib renamed to `Cmcut`, `Headers/mcut.h`, `Modules/module.modulemap`
  (`framework module Cmcut { header "mcut.h" export * }`), and an `Info.plist` with
  `CFBundleExecutable=Cmcut`, `CFBundlePackageType=FMWK`, `MinimumOSVersion`, `CFBundleSupportedPlatforms`.
- **Release checksum is chicken-and-egg:** build + upload the artifact first, then commit the manifest
  with the computed checksum. CI does this in two phases — don't try to compute it before the build.

---

## Swift API conventions

- `McResult` codes → a `throws` `MCUTError` enum. No raw error ints in the public API.
- `McDispatchFlags` → a Swift `OptionSet`.
- Input mesh → `MCUTMesh { vertices, faceIndices, faceSizes }` with a triangle-only convenience init.
- Hide the C two-pass byte-count idiom and all manual `mcRelease*` calls behind RAII / `deinit`.
  Callers must never see or leak handles.
- Expose the `FACE_TRIANGULATION` channel — mcut returns arbitrary polygons; renderers/solvers need tris.
- High-level ops set filter-flag combinations: `union`, `subtract`, `intersect`, `slice`/`section`,
  `split`, `stencil`, `intersectionCurves`.

---

## When to stop and ask

- Any open decision in `mcut-swift-plan.md` §9 (deployment targets, Float vs Double, platforms,
  upstream tag, manifest-bump strategy) — confirm with the maintainer rather than assuming.
- Anything that would require editing `external/mcut`, switching to static linking, or changing the
  license posture.

## Definition of done for a change

- `swift test` passes (local xcframework).
- No build artifacts staged for commit.
- New/changed public API matches the real `mcut.h`.
- `external/mcut` submodule pointer unchanged unless intentionally bumping the upstream version.
