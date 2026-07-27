# Capture Desk Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Deliver a visual Capture Desk, a local live waveform, reliable SwiftPM helper launching, and tested Claude handoff.

**Architecture:** Retain the menu-bar capture entry. Add a desk SwiftUI window; retain the floating recorder. Put helper-path selection and waveform calculation in KotobaneCore so they are deterministic and unit-tested.

**Tech Stack:** Swift 6, SwiftUI, AppKit, Swift Testing, Foundation.

## Global Constraints

- macOS 14+, Apple silicon only; capture remains explicit and local.
- Waveform uses existing RMS values only, and respects Reduce Motion.
- Runtime/model downloads happen only after the user presses Install Model.
- Claude copies the deterministic brief before app/browser activation.

---

### Task 1: Resolve the helper launch shim in both layouts

**Files:** Modify `Sources/KotobaneCore/Transcription/FoundationProcessLauncher.swift`; modify `Tests/KotobaneCoreTests/FoundationProcessLauncherTests.swift`.

**Produces:** `SandboxExecNetworkIsolation.defaultLaunchShimURL(bundleURL:executableURL:executablePaths:) -> URL`.

- [ ] **Step 1: Write the failing layout test.**

```swift
@Test func swiftPackageLayoutUsesSiblingLaunchShim() {
    let executable = URL(filePath: "/tmp/.build/debug/Kotobane")
    let expected = executable.deletingLastPathComponent().appending(path: "kotobane-launch-shim")
    #expect(SandboxExecNetworkIsolation.defaultLaunchShimURL(
        bundleURL: URL(filePath: "/tmp/.build/debug"), executableURL: executable,
        executablePaths: { $0 == expected.path }
    ) == expected)
}
```

- [ ] **Step 2: Run `scripts/swift-test.sh --filter FoundationProcessLauncherTests`.** Expected: FAIL because the resolver does not exist.

- [ ] **Step 3: Implement selection:** first return executable packaged path `Contents/Helpers/kotobane-launch-shim`; otherwise return a sibling `kotobane-launch-shim` beside `Bundle.main.executableURL`; retain the packaged path as the actionable missing-file result.

- [ ] **Step 4: Run the same test.** Expected: PASS.

- [ ] **Step 5: Commit:** `git add Sources/KotobaneCore/Transcription/FoundationProcessLauncher.swift Tests/KotobaneCoreTests/FoundationProcessLauncherTests.swift && git commit -m "fix: resolve helper shim in SwiftPM builds"`.

### Task 2: Add deterministic waveform data

**Files:** Create `Sources/KotobaneCore/Capture/WaveformMeter.swift`; create `Tests/KotobaneCoreTests/WaveformMeterTests.swift`.

**Produces:** `WaveformMeter.bars(rmsLevel:count:phase:) -> [Double]`, values limited to `0.08...1.0`.

- [ ] **Step 1: Write the failing test.**

```swift
@Test func waveformBarsAreStableAndBounded() {
    let bars = WaveformMeter.bars(rmsLevel: 0.6, count: 16, phase: 0.25)
    #expect(bars == WaveformMeter.bars(rmsLevel: 0.6, count: 16, phase: 0.25))
    #expect(bars.count == 16)
    #expect(bars.allSatisfy { (0.08...1.0).contains($0) })
}
```

- [ ] **Step 2: Run `scripts/swift-test.sh --filter WaveformMeterTests`.** Expected: FAIL because `WaveformMeter` does not exist.

- [ ] **Step 3: Implement:** clamp RMS to `0...1`, return minimum bars when silent, and derive each bar from `sin((index / count) * .pi * 4 + phase)`; clamp each height.

- [ ] **Step 4: Run the same test.** Expected: PASS.

- [ ] **Step 5: Commit:** `git add Sources/KotobaneCore/Capture/WaveformMeter.swift Tests/KotobaneCoreTests/WaveformMeterTests.swift && git commit -m "feat: add deterministic recording waveform"`.

### Task 3: Build the Capture Desk and recorder waveform

**Files:** Create `Sources/KotobaneApp/CaptureDeskWindow.swift` and `Sources/KotobaneApp/RecordingWaveform.swift`; modify `Sources/KotobaneApp/KotobaneApp.swift`, `Sources/KotobaneApp/MenuBarContent.swift`, `Sources/KotobaneApp/AppContainer.swift`, and `Sources/KotobaneApp/RecorderOverlay.swift`.

**Produces:** `Window("Kotobane", id: "desk")`, `AppContainer.openCaptureDesk()`, and `RecordingWaveform(rmsLevel:)`.

- [ ] **Step 1: Add a failing desk-routing test:** install a window action, call `openCaptureDesk()`, then assert the captured ID equals `"desk"`.

- [ ] **Step 2: Run `scripts/swift-test.sh --filter CaptureDesk`.** Expected: FAIL because desk routing is absent.

- [ ] **Step 3: Implement:** add the desk window and menu action; show model/local-only status, explicit Record, transcribing status, privacy empty state, and recent capture buttons. Replace recorder `ProgressView` with sixteen Capsule bars from `WaveformMeter`. When Reduce Motion is active use phase zero; otherwise use a current-time phase. Do not add any audio tap.

- [ ] **Step 4: Run `swift build --product Kotobane`.** Expected: PASS. Manually open the desk, record a short clip, confirm waveform movement and Stop, then open the saved capture.

- [ ] **Step 5: Commit:** `git add Sources/KotobaneApp && git commit -m "feat: add capture desk and live waveform"`.

### Task 4: Verify Claude copy-first handoff

**Files:** Modify `Tests/KotobaneCoreTests/HandoffCoordinatorTests.swift` and `Tests/KotobaneCoreTests/SystemHandoffAdaptersTests.swift`.

**Consumes:** `HandoffCoordinator.perform(brief:destination:pasteAfterOpening:)`.

- [ ] **Step 1: Write this failing test.**

```swift
@Test func claudeCopiesBeforeOpening() async throws {
    let result = try await fixture.coordinator.perform(
        brief: "# Brief", destination: .claude, pasteAfterOpening: false
    )
    #expect(fixture.events == [.clipboard("# Brief"), .open(.claude)])
    #expect(result == .activated(pasteAttempted: false))
}
```

- [ ] **Step 2: Add a system-opener test with no Claude bundle URL and a `claude.ai/new` handler; assert that it opens the fallback URL.**

- [ ] **Step 3: Run `scripts/swift-test.sh --filter Claude`.** Expected: PASS after retaining the sequence: clipboard write, Claude desktop activation, browser fallback, optional Accessibility paste.

- [ ] **Step 4: Run `scripts/swift-test.sh`.** Expected: PASS.

- [ ] **Step 5: Commit:** `git add Tests/KotobaneCoreTests/HandoffCoordinatorTests.swift Tests/KotobaneCoreTests/SystemHandoffAdaptersTests.swift Sources/KotobaneCore/Handoff && git commit -m "test: verify Claude copy-first handoff"`.
