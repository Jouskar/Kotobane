# Task 2 Report: Exact Deterministic Brief Composition

## RED evidence

After adding `BriefComposerTests.swift`, ran:

```text
scripts/swift-test.sh --filter BriefComposerTests
```

The build failed as expected with `cannot find 'BriefComposer' in scope` at both
test call sites. No production `BriefComposer` implementation existed at that
point.

## GREEN evidence

Implemented `BriefComposer` with one fixed template per `CaptureIntent` and no
transcript transformation. Ran:

```text
scripts/swift-test.sh --filter BriefComposerTests
```

Result: 2 tests passed.

Ran the full suite:

```text
scripts/swift-test.sh
```

Result: 3 tests passed.

## Files

- `Sources/KotobaneCore/Briefs/BriefComposer.swift`
- `Tests/KotobaneCoreTests/BriefComposerTests.swift`

## Commit

`176eaa6 feat: compose deterministic handoff briefs`

## Self-review

- The Brainstorm output test matches the approved template exactly around a
  whitespace-sensitive, multiline transcript.
- `compose` inserts the transcript a single time and applies no trimming,
  normalization, or rewriting.
- Every `CaptureIntent` has an explicit fixed template.

## Concerns

Swift Package Manager emitted sandbox cache-permission warnings for user-level
caches. These did not affect compilation or test results.

## Repository-hygiene remediation

Replaced the whitespace-bearing source line in
`Tests/KotobaneCoreTests/BriefComposerTests.swift` with `\(transcript)` inside
the expected multiline template. The runtime transcript remains exactly
`"  Bunu değiştirme.\nİkinci satır.  "`, including two leading spaces on the
first line and two trailing spaces on the second line; the assertion remains an
exact equality check.

Verification run after the change:

```text
scripts/swift-test.sh --filter BriefComposerTests
Result: 2 tests passed.

scripts/swift-test.sh
Result: 3 tests passed.

git diff --check 9998202..HEAD
Result before this remediation commit: failed only on the historical trailing
whitespace at Tests/KotobaneCoreTests/BriefComposerTests.swift:18.
Result after this remediation commit: clean (see commit verification below).
```

Swift Package Manager again emitted sandbox cache-permission warnings for
user-level caches; compilation and both test runs completed successfully.

## Commit verification

Committed the remediation with message `test: remove fixture trailing whitespace`.
The following commands completed with exit status 0; the two `git diff --check`
and `git status --short` commands produced no output:

```text
git diff --check 9998202..HEAD
git status --short
git show --check --stat --oneline HEAD
HEAD test: remove fixture trailing whitespace
```
