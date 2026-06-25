# CLAUDE.md

Operating rules for Claude Code in this repo. Read first, every session.

- *Why*, and the phased plan with open decisions → `docs/plans/mcut-swift-plan.md`
- *How* the binary is built and shipped (commands, releasing, packaging internals) → `docs/agent/build-and-release.md`
- *What* the Swift API should become → `docs/agent/swift-api-design.md`

---

## What this is

`mcut-swift` — a public Swift Package that wraps [cutdigital/mcut](https://github.com/cutdigital/mcut)
(a C++ mesh cutting / boolean library with a flat C API) and exposes an idiomatic Swift API for
iOS and macOS. mcut ships as a **prebuilt dynamic `xcframework`**; the Swift layer is compiled by
consumers.

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
   and flag values.
5. **Do not relicense mcut.** The distributed combination is LGPL-3.0 regardless of the wrapper's
   own license. Do not add MIT/Apache headers implying the binary is permissively licensed.
6. **Naming is fixed:** `Cmcut` = the binary framework / C module (raw C symbols);
   `MCUT` = the Swift target / public API. The Swift layer does `import Cmcut` internally.

---

## When to stop and ask

- Any open decision in `docs/plans/mcut-swift-plan.md` §9 (deployment targets, Float vs Double,
  platforms, upstream tag, manifest-bump strategy) — confirm with the maintainer rather than assuming.
- Anything that would require editing `external/mcut`, switching to static linking, or changing the
  license posture.

---

## Definition of done for a change

- `swift test` passes.
- No build artifacts staged for commit.
- New/changed public API matches the real `mcut.h`.
- `external/mcut` submodule pointer unchanged unless intentionally bumping the upstream version.
