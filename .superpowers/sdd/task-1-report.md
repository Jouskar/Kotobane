# Task 1 report: Package foundation and domain contracts

## Status

Implementation committed as `4447640 feat: add package foundation and domain models`.

## RED

Command required by the task brief:

```sh
swift test --filter SettingsStoreTests
```

Result: non-zero exit. It could not reach the test's intended missing-`AppSettings`
compiler error because the environment failed while compiling the package manifest:

```text
error: unable to open output file '/Users/tolgahan/.cache/clang/ModuleCache/.../SwiftShims-....pcm': 'Operation not permitted'
error: failed to build module 'Swift'; this SDK is not supported by the compiler
```

The installed compiler is Apple Swift `6.3.0.123.5`, while the selected SDK was
built with `6.3.0.123.4`. This is a machine/toolchain mismatch, not an
application test result.

## GREEN verification

The package build was verified with isolated module caches and SwiftPM's package
sandbox disabled, which is necessary in this sandboxed environment:

```sh
CLANG_MODULE_CACHE_PATH="$PWD/.swift-cache/clang" \
SWIFTPM_MODULECACHE_OVERRIDE="$PWD/.swift-cache/swiftpm" \
swift build --disable-sandbox -v
```

Relevant output:

```text
Building for debugging...
Build complete! (0.30s)
```

Focused and full-suite commands attempted:

```sh
CLANG_MODULE_CACHE_PATH="$PWD/.swift-cache/clang" \
SWIFTPM_MODULECACHE_OVERRIDE="$PWD/.swift-cache/swiftpm" \
swift test --disable-sandbox --filter SettingsStoreTests

CLANG_MODULE_CACHE_PATH="$PWD/.swift-cache/clang" \
SWIFTPM_MODULECACHE_OVERRIDE="$PWD/.swift-cache/swiftpm" \
swift test --disable-sandbox
```

Both test invocations are blocked at test-module compilation by the installed
Command Line Tools image:

```text
Tests/KotobaneCoreTests/SettingsStoreTests.swift:1:8: error: no such module 'XCTest'
import XCTest
       `- error: no such module 'XCTest'
```

Therefore, no passing XCTest result is claimed. `swift build` passed.

## Changed files

- `.gitignore`
- `Package.swift`
- `Sources/KotobaneCore/Domain/CaptureIntent.swift`
- `Sources/KotobaneCore/Domain/Capture.swift`
- `Sources/KotobaneCore/Domain/Destination.swift`
- `Sources/KotobaneCore/Domain/ModelChoice.swift`
- `Sources/KotobaneCore/Domain/Settings.swift`
- `Tests/KotobaneCoreTests/SettingsStoreTests.swift`

## Domain contracts

- Models are `Codable`, `Equatable`, and `Sendable`; `Capture` is also
  `Identifiable`.
- Captures contain the approved metadata: UUID, editable title, timestamps,
  transcript, intent, status, optional diagnostic, duration, and optional
  relative audio filename.
- Built-in destinations are Codex, Claude, Clipboard, and Markdown file.
- `ModelChoice.small` and `.accuracy` encode the specified Qwen model IDs.
- Shortcut modifiers are a serializable bit-mask option set; Control and Option
  encode as `1` and `2`, preserving the `3` migration representation used by
  the next planned task.

## Self-review

`git diff --check` and `git show --check --stat --oneline HEAD` reported no
whitespace errors. The implementation is scoped to Task 1; no persistence,
brief composition, handoff, recording, or model-management behavior was added.

## Concerns

The current machine's Command Line Tools installation is internally inconsistent
for SwiftPM testing: the compiler/SDK versions differ and the macOS XCTest Swift
module is absent. Re-run the focused and full XCTest commands under a matching
Xcode or Command Line Tools installation before treating Task 1 as fully test
verified.

## Review fix

- Changed file: `.gitignore` — added explicit `*.app/` rule for generated app bundles.
- Commands and exact results:
  - `git check-ignore dist/Kotobane.app` → `dist/Kotobane.app`
  - `git diff --check` → no output (exit 0)

## Swift Testing plan correction

### Approval context

The user approved replacing XCTest because it is unavailable in the installed
Apple Command Line Tools. The requested MVP correction is to use Apple Swift
Testing so the package can build and test without full Xcode. No later product
task was implemented.

### Changed files

- `.gitignore` — ignores sandbox-local `.swift-cache/` build data; the existing
  cache was preserved.
- `Tests/KotobaneCoreTests/SettingsStoreTests.swift` — migrated the defaults
  behavior test from XCTest to Swift Testing.
- `docs/superpowers/plans/2026-07-24-kotobane-v1-mvp.md` — changed the tech
  stack and every Swift test snippet to `import Testing`, `@Test`, `#expect`,
  `#require`, and explicit `do`/`catch` for expected errors.

### Verification

Focused test command:

```sh
CLANG_MODULE_CACHE_PATH="$PWD/.swift-cache/clang" \
SWIFTPM_MODULECACHE_OVERRIDE="$PWD/.swift-cache/swiftpm" \
swift test --disable-sandbox --filter SettingsStoreTests
```

Result: exit 1; zero tests discovered or run. Test-module compilation stopped
with:

```text
Tests/KotobaneCoreTests/SettingsStoreTests.swift:1:8: error: no such module 'Testing'
import Testing
       `- error: no such module 'Testing'
error: fatalError
```

Full-suite command:

```sh
CLANG_MODULE_CACHE_PATH="$PWD/.swift-cache/clang" \
SWIFTPM_MODULECACHE_OVERRIDE="$PWD/.swift-cache/swiftpm" \
swift test --disable-sandbox
```

Result: exit 1; zero tests discovered or run. It stopped at the same
`no such module 'Testing'` test-module compilation error.

Build command:

```sh
CLANG_MODULE_CACHE_PATH="$PWD/.swift-cache/clang" \
SWIFTPM_MODULECACHE_OVERRIDE="$PWD/.swift-cache/swiftpm" \
swift build --disable-sandbox
```

Result: exit 0:

```text
Building for debugging...
Build complete! (0.28s)
```

`git diff --check` completed with exit 0 and no output. Ignore verification:

```text
.gitignore:2:.swift-cache/ .swift-cache/clang/modules.timestamp
```

### Commit

`test: migrate Kotobane tests to Swift Testing` (the final SHA is recorded in
the task handoff; including it here would change the commit object).

### Self-review

The conversion retains the original assertions and test intent. The plan's
corrupt-metadata assertion now uses explicit `do`/`catch` plus `Issue.record`,
and optional state values use `#require` before their property assertions.

### Concern

BLOCKED: the installed Apple Swift 6.3 Command Line Tools compiler can build
the package but does not provide the `Testing` module. No app code was changed
to work around this SDK/toolchain mismatch. Install or select Command Line
Tools/Xcode containing Apple Swift Testing, then rerun the focused and full
commands above.
