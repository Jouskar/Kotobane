# Transcript Only Intent Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Let a user hand off exactly their edited transcript through any existing destination.

**Architecture:** Add a new persisted `CaptureIntent` case. `BriefComposer` handles that case before template lookup and returns the supplied text unchanged; all existing handoff destinations continue consuming composer output. The review picker gets a display label through its existing intent-label switch.

**Tech Stack:** Swift 6, Swift Testing, SwiftUI, macOS 14.

## Global Constraints

- Preserve the user-edited transcript character-for-character, including leading spaces and paragraph breaks.
- Add no title, Markdown, prompt, checklist, or extra whitespace for `Transcript only`.
- Keep existing intent templates and handoff destinations unchanged.
- Work on `feature/transcript-only-intent`, then merge to `develop`.

---

### Task 1: Add the raw transcript intent and composer behavior

**Files:**
- Modify: `Sources/KotobaneCore/Domain/CaptureIntent.swift:1-7`
- Modify: `Sources/KotobaneCore/Briefs/BriefComposer.swift:1-27`
- Modify: `Tests/KotobaneCoreTests/BriefComposerTests.swift:1-36`

**Interfaces:**
- Produces: `CaptureIntent.transcriptOnly`
- Produces: `BriefComposer.compose(intent: .transcriptOnly, transcript: String) -> String` returning the exact input string.

- [ ] **Step 1: Write the failing test**

```swift
@Test func transcriptOnlyReturnsTheEditedTranscriptExactly() {
    let transcript = "  İlk fikir.\n\nİkinci fikir.  "

    #expect(
        BriefComposer.compose(intent: .transcriptOnly, transcript: transcript) == transcript
    )
}
```

- [ ] **Step 2: Run test to verify it fails**

Run: `scripts/swift-test.sh --filter transcriptOnlyReturnsTheEditedTranscriptExactly`

Expected: compilation failure because `CaptureIntent.transcriptOnly` does not exist.

- [ ] **Step 3: Write minimal implementation**

Add this case to `CaptureIntent`:

```swift
case transcriptOnly
```

At the top of `BriefComposer.compose`, before `IntentTemplate.template(for:)`, add:

```swift
if intent == .transcriptOnly {
    return transcript
}
```

- [ ] **Step 4: Run test to verify it passes**

Run: `scripts/swift-test.sh --filter transcriptOnlyReturnsTheEditedTranscriptExactly`

Expected: PASS.

- [ ] **Step 5: Run the complete composer suite**

Run: `scripts/swift-test.sh --filter BriefComposerTests`

Expected: PASS; existing template behavior remains unchanged.

### Task 2: Expose the intent in the review picker

**Files:**
- Modify: `Sources/KotobaneApp/ReviewWindow.swift:190-201`

**Interfaces:**
- Consumes: `CaptureIntent.transcriptOnly`
- Produces: `CaptureIntent.displayName == "Transcript only"` for the existing picker.

- [ ] **Step 1: Update the existing display-name switch**

Add this switch arm:

```swift
case .transcriptOnly: "Transcript only"
```

The picker already iterates `CaptureIntent.allCases`, so no picker structure changes are needed.

- [ ] **Step 2: Build and run the regression test**

Run: `scripts/swift-test.sh --filter transcriptOnlyReturnsTheEditedTranscriptExactly`

Expected: PASS and the app target compiles with the new exhaustive switch case.

- [ ] **Step 3: Commit the implementation**

```sh
git add Sources/KotobaneCore/Domain/CaptureIntent.swift \
  Sources/KotobaneCore/Briefs/BriefComposer.swift \
  Sources/KotobaneApp/ReviewWindow.swift \
  Tests/KotobaneCoreTests/BriefComposerTests.swift
git commit -m "feat: add transcript-only handoff intent"
```
