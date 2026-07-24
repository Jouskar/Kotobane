# Kotobane v1 MVP Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Build a runnable Apple-silicon macOS 14 menu-bar app that records explicit microphone captures, transcribes them with a private local Qwen3-ASR helper, preserves editable local history, and hands deterministic Markdown to Codex, Claude, the clipboard, or a file.

**Architecture:** A SwiftPM workspace separates a testable `KotobaneCore` library from a thin SwiftUI/AppKit executable. Core protocols isolate recording, persistence, helper-process transcription, shortcuts, paste automation, and destination activation. A pinned Python helper performs offline MLX/Qwen inference over newline-delimited JSON, while shell scripts assemble and ad-hoc-sign a conventional `.app` bundle.

**Tech Stack:** Swift 6.3, Swift Testing, SwiftUI, AppKit, AVFoundation, Carbon, Python 3.11/3.12, `unittest`, MLX, Qwen3-ASR, POSIX shell, Swift Package Manager.

## Global Constraints

- Deployment target is macOS 14 Sonoma or newer on Apple silicon.
- The repository must build and test with Apple Command Line Tools; full Xcode is not required.
- Recording is explicit and on-demand; continuous recording and system-audio capture are excluded.
- Turkish is the default language hint.
- Audio and transcripts never leave the Mac during capture or transcription.
- No cloud fallback, account, sync, telemetry, subscription, or in-app LLM is permitted.
- Qwen3-ASR-0.6B is the default model; Qwen3-ASR-1.7B is optional.
- Model weights, virtual environments, captures, and generated app bundles never enter Git.
- Raw audio is deleted by default only after transcript persistence succeeds.
- Every Codex or Claude handoff copies the brief before destination activation.
- Automated paste is opt-in and must degrade to copy-and-open when Accessibility is unavailable.
- The Brainstorm template must match the approved design byte-for-byte around the edited transcript.

---

## Planned file map

```text
.
├── Package.swift
├── README.md
├── LICENSE
├── THIRD_PARTY_NOTICES.md
├── Resources
│   ├── Info.plist
│   └── Kotobane.entitlements
├── Sources
│   ├── KotobaneApp
│   │   ├── AppContainer.swift
│   │   ├── KotobaneApp.swift
│   │   ├── MenuBarContent.swift
│   │   ├── RecorderOverlay.swift
│   │   ├── ReviewWindow.swift
│   │   ├── HistoryWindow.swift
│   │   ├── SettingsWindow.swift
│   │   └── ModelSetupView.swift
│   └── KotobaneCore
│       ├── Domain
│       │   ├── Capture.swift
│       │   ├── CaptureIntent.swift
│       │   ├── Destination.swift
│       │   ├── ModelChoice.swift
│       │   └── Settings.swift
│       ├── Briefs
│       │   └── BriefComposer.swift
│       ├── Capture
│       │   ├── AudioRecording.swift
│       │   ├── AVAudioEngineRecorder.swift
│       │   ├── CaptureController.swift
│       │   └── GlobalShortcut.swift
│       ├── Handoff
│       │   ├── HandoffCoordinator.swift
│       │   └── SystemHandoffAdapters.swift
│       ├── Persistence
│       │   ├── AppDirectories.swift
│       │   ├── CaptureStore.swift
│       │   └── SettingsStore.swift
│       ├── Transcription
│       │   ├── HelperProtocol.swift
│       │   ├── MLXHelperEngine.swift
│       │   ├── ModelManager.swift
│       │   └── TranscriptionEngine.swift
│       └── Support
│           └── AtomicFileWriter.swift
├── Tests
│   └── KotobaneCoreTests
│       ├── BriefComposerTests.swift
│       ├── CaptureControllerTests.swift
│       ├── CaptureStoreTests.swift
│       ├── GlobalShortcutTests.swift
│       ├── HandoffCoordinatorTests.swift
│       ├── HelperProtocolTests.swift
│       ├── MLXHelperEngineTests.swift
│       ├── ModelManagerTests.swift
│       └── SettingsStoreTests.swift
├── helper
│   ├── kotobane_helper.py
│   ├── model_install.py
│   ├── runtime-manifest.json
│   ├── requirements.lock
│   └── tests
│       ├── test_helper.py
│       └── test_model_install.py
└── scripts
    ├── bootstrap-helper.sh
    ├── package-app.sh
    ├── swift-test.sh
    └── verify.sh
```

## Task 1: Package foundation and domain contracts

**Files:**

- Create: `.gitignore`
- Create: `Package.swift`
- Create: `Sources/KotobaneCore/Domain/CaptureIntent.swift`
- Create: `Sources/KotobaneCore/Domain/Capture.swift`
- Create: `Sources/KotobaneCore/Domain/Destination.swift`
- Create: `Sources/KotobaneCore/Domain/ModelChoice.swift`
- Create: `Sources/KotobaneCore/Domain/Settings.swift`
- Create: `Tests/KotobaneCoreTests/SettingsStoreTests.swift`

**Interfaces:**

- Produces: `CaptureIntent`, `Capture`, `CaptureStatus`, `Destination`,
  `ModelChoice`, `AppSettings`, `AudioRetentionPolicy`.
- All domain values conform to `Codable`, `Equatable`, and `Sendable` where
  their stored properties permit it.

- [ ] **Step 1: Add the package manifest, ignore rules, and failing defaults test**

```swift
// Tests/KotobaneCoreTests/SettingsStoreTests.swift
import Testing
@testable import KotobaneCore

@Test func defaultsFavorPrivateTurkishWorkflow() {
    let settings = AppSettings.defaults
    #expect(settings.version == AppSettings.currentVersion)
    #expect(settings.languageHint == "Turkish")
    #expect(settings.model == .small)
    #expect(settings.audioRetention == .deleteAfterTranscription)
    #expect(settings.shortcut == .init(keyCode: 49, modifiers: [.control, .option]))
    #expect(!settings.pasteAfterOpening)
}
```

- [ ] **Step 2: Run the test and verify RED**

Run: `scripts/swift-test.sh --filter SettingsStoreTests`

Expected: compilation fails because `AppSettings` and its related domain types
do not exist.

- [ ] **Step 3: Implement the smallest domain model**

```swift
// Sources/KotobaneCore/Domain/Settings.swift
public struct AppSettings: Codable, Equatable, Sendable {
    public var version: Int
    public var languageHint: String
    public var model: ModelChoice
    public var audioRetention: AudioRetentionPolicy
    public var shortcut: Shortcut
    public var pasteAfterOpening: Bool

    public static let currentVersion = 2

    public static let defaults = AppSettings(
        version: currentVersion,
        languageHint: "Turkish",
        model: .small,
        audioRetention: .deleteAfterTranscription,
        shortcut: Shortcut(keyCode: 49, modifiers: [.control, .option]),
        pasteAfterOpening: false
    )
}

public enum AudioRetentionPolicy: String, Codable, Equatable, Sendable {
    case deleteAfterTranscription
    case retain
}
```

Implement `ModelChoice.small` as `qwen3-asr-0.6b`, `ModelChoice.accuracy` as
`qwen3-asr-1.7b`, capture fields from the design, built-in destinations, and a
bit-mask `Shortcut.Modifier` option set.

- [ ] **Step 4: Verify GREEN and package compilation**

Run: `scripts/swift-test.sh --filter SettingsStoreTests && swift build`

Expected: one passing test and successful debug build.

- [ ] **Step 5: Commit**

```bash
git add .gitignore Package.swift Sources/KotobaneCore Tests/KotobaneCoreTests/SettingsStoreTests.swift
git commit -m "feat: add package foundation and domain models"
```

## Task 2: Exact deterministic brief composition

**Files:**

- Create: `Sources/KotobaneCore/Briefs/BriefComposer.swift`
- Create: `Tests/KotobaneCoreTests/BriefComposerTests.swift`

**Interfaces:**

- Consumes: `CaptureIntent`.
- Produces: `BriefComposer.compose(intent:transcript:) -> String`.

- [ ] **Step 1: Write failing exact-output tests**

```swift
import Testing
@testable import KotobaneCore

@Test func brainstormTemplateIsExactAndTranscriptIsVerbatim() {
        let transcript = "  Bunu değiştirme.\nİkinci satır.  "
        let expected = """
        # Brainstorm captured in Kotobane

        Please help me turn the following spoken brainstorm into a clear next step.

        ## Desired outcome

        Clarify the idea, identify assumptions and missing decisions, then propose an actionable plan.

        ## Raw transcript

          Bunu değiştirme.
        İkinci satır.  

        ## Requested response

        1. Concise summary
        2. Decisions and constraints
        3. Open questions
        4. Recommended next actions
        """

    #expect(BriefComposer.compose(intent: .brainstorm, transcript: transcript) == expected)
}

@Test func everyIntentHasAStableTemplate() {
    for intent in CaptureIntent.allCases {
        let output = BriefComposer.compose(intent: intent, transcript: "ham metin")
        #expect(output.contains("ham metin"))
        #expect(output.components(separatedBy: "ham metin").count == 2)
    }
}
```

- [ ] **Step 2: Verify RED**

Run: `scripts/swift-test.sh --filter BriefComposerTests`

Expected: compilation fails because `BriefComposer` does not exist.

- [ ] **Step 3: Implement fixed templates**

```swift
public enum BriefComposer {
    public static func compose(intent: CaptureIntent, transcript: String) -> String {
        let template = IntentTemplate.template(for: intent)
        return """
        # \(template.heading)

        \(template.instruction)

        ## Desired outcome

        \(template.outcome)

        ## Raw transcript

        \(transcript)

        ## Requested response

        \(template.checklist.enumerated().map { "\($0.offset + 1). \($0.element)" }.joined(separator: "\n"))
        """
    }
}
```

Define explicit fixed strings for Brainstorm, Task, Project idea, Meeting note,
and Freeform in a private `IntentTemplate`; do not transform `transcript`.

- [ ] **Step 4: Verify GREEN**

Run: `scripts/swift-test.sh --filter BriefComposerTests`

Expected: two passing tests.

- [ ] **Step 5: Commit**

```bash
git add Sources/KotobaneCore/Briefs Tests/KotobaneCoreTests/BriefComposerTests.swift
git commit -m "feat: compose deterministic handoff briefs"
```

## Task 3: Atomic capture and settings persistence

**Files:**

- Create: `Sources/KotobaneCore/Support/AtomicFileWriter.swift`
- Create: `Sources/KotobaneCore/Persistence/AppDirectories.swift`
- Create: `Sources/KotobaneCore/Persistence/CaptureStore.swift`
- Create: `Sources/KotobaneCore/Persistence/SettingsStore.swift`
- Create: `Tests/KotobaneCoreTests/CaptureStoreTests.swift`
- Modify: `Tests/KotobaneCoreTests/SettingsStoreTests.swift`

**Interfaces:**

- Produces: `CaptureStore.init(root:fileManager:)`,
  `loadAll()`, `save(_:)`, `delete(id:)`, `deleteAll()`.
- Produces: `SettingsStore.load() -> AppSettings`, `save(_:)`.
- `CaptureStore.save` completes before audio-retention cleanup is permitted.

- [ ] **Step 1: Write failing filesystem behavior tests**

```swift
import Testing
@testable import KotobaneCore

@Test func saveRoundTripsAndDeleteRemovesMetadataAndAudio() throws {
    let root = temporaryDirectory()
    let store = CaptureStore(root: root)
    let audio = root.appending(path: "captures/sample.wav")
    try FileManager.default.createDirectory(at: audio.deletingLastPathComponent(),
                                            withIntermediateDirectories: true)
    try Data([1, 2, 3]).write(to: audio)
    let capture = Capture.fixture(audioFilename: "sample.wav")

    try store.save(capture)
    #expect(try store.loadAll() == [capture])

    try store.delete(id: capture.id)
    #expect(!FileManager.default.fileExists(atPath: audio.path))
    #expect(try store.loadAll().isEmpty)
}

@Test func corruptMetadataIsReportedWithoutDeletingAudio() throws {
    let root = temporaryDirectory()
    let store = CaptureStore(root: root)
    try store.prepareDirectories()
    try Data("{".utf8).write(to: store.metadataURL(for: UUID()))

    do {
        _ = try store.loadAll()
        Issue.record("Expected corrupt metadata to be reported")
    } catch {
        // Expected: corrupt metadata remains visible to the caller.
    }
}

@Test func versionOneSettingsMigrateNewPastePreferenceToDisabled() throws {
    let root = temporaryDirectory()
    let settingsURL = root.appending(path: "settings.json")
    try Data(#"{"version":1,"languageHint":"Turkish","model":"small","audioRetention":"deleteAfterTranscription","shortcut":{"keyCode":49,"modifiers":3}}"#.utf8)
        .write(to: settingsURL)

    let migrated = try SettingsStore(url: settingsURL).load()

    #expect(!migrated.pasteAfterOpening)
    #expect(migrated.version == AppSettings.currentVersion)
}
```

- [ ] **Step 2: Verify RED**

Run: `scripts/swift-test.sh --filter CaptureStoreTests`

Expected: compilation fails because `CaptureStore` does not exist.

- [ ] **Step 3: Implement atomic JSON storage**

Use `JSONEncoder` with ISO-8601 dates and sorted keys. Write to a UUID-named
temporary sibling, call `FileManager.replaceItemAt` when a destination exists,
and move when it does not. Resolve stored audio filenames as a single path
component and reject `..`, `/`, or a standardized URL outside the captures
directory.

`SettingsStore.load()` returns `.defaults` only for a missing file. Decode
errors remain visible rather than silently resetting user preferences.

- [ ] **Step 4: Verify GREEN**

Run: `scripts/swift-test.sh --filter 'CaptureStoreTests|SettingsStoreTests'`

Expected: persistence and settings tests pass with no warnings.

- [ ] **Step 5: Commit**

```bash
git add Sources/KotobaneCore/Persistence Sources/KotobaneCore/Support Tests/KotobaneCoreTests
git commit -m "feat: persist captures and settings atomically"
```

## Task 4: Helper protocol and process transcription engine

**Files:**

- Create: `Sources/KotobaneCore/Transcription/TranscriptionEngine.swift`
- Create: `Sources/KotobaneCore/Transcription/HelperProtocol.swift`
- Create: `Sources/KotobaneCore/Transcription/MLXHelperEngine.swift`
- Create: `Tests/KotobaneCoreTests/HelperProtocolTests.swift`
- Create: `Tests/KotobaneCoreTests/MLXHelperEngineTests.swift`
- Create: `Tests/Fixtures/fake-helper.py`

**Interfaces:**

- Produces: `TranscriptionEngine.transcribe(_:) async throws -> TranscriptionResult`.
- Produces: `TranscriptionRequest`, `HelperRequest`, `HelperResponse`,
  `TranscriptionFailure`.
- `MLXHelperEngine` accepts helper executable URL, allowed root, timeout, and a
  `ProcessLaunching` adapter.

- [ ] **Step 1: Write failing codec and fake-process tests**

```swift
import Testing
@testable import KotobaneCore

@Test func requestEncodingMatchesNDJSONContract() throws {
    let id = UUID(uuidString: "00000000-0000-0000-0000-000000000001")!
    let request = HelperRequest(
        id: id,
        action: "transcribe",
        audioPath: "/private/tmp/audio.wav",
        language: "Turkish",
        model: "qwen3-asr-0.6b"
    )
    let line = try HelperCodec.encode(request)
    #expect(line == #"{"action":"transcribe","audioPath":"/private/tmp/audio.wav","id":"00000000-0000-0000-0000-000000000001","language":"Turkish","model":"qwen3-asr-0.6b"}"# + "\n")
}

@Test func engineRestartsOnceAfterCrash() async throws {
    let launcher = ScriptedProcessLauncher(outcomes: [.exit(1), .line(completedJSON)])
    let engine = MLXHelperEngine(configuration: fixtureConfiguration, launcher: launcher)
    let result = try await engine.transcribe(fixtureRequest)
    #expect(result.text == "Merhaba")
    #expect(launcher.launchCount == 2)
}
```

Also test mismatched IDs, malformed JSON, unknown statuses, failed responses,
timeouts, and failure after the single restart.

- [ ] **Step 2: Verify RED**

Run: `scripts/swift-test.sh --filter 'HelperProtocolTests|MLXHelperEngineTests'`

Expected: compilation fails because helper protocol types do not exist.

- [ ] **Step 3: Implement codec and process isolation**

Encode with sorted JSON keys and exactly one trailing newline. Decode responses
through a status discriminator and require the response UUID to match the
request. Launch with `Process`, separate stdin/stdout/stderr pipes, and:

```swift
environment["HF_HUB_OFFLINE"] = "1"
environment["TRANSFORMERS_OFFLINE"] = "1"
environment["NO_PROXY"] = "*"
```

Canonicalize the audio URL and verify it is a descendant of `allowedAudioRoot`
before launch. Use a task group to race the response against
`ContinuousClock.sleep(for: timeout)`. Terminate and reap timed-out processes.
Retry only crash, EOF, and timeout errors; do not retry model or input errors.

- [ ] **Step 4: Verify GREEN**

Run: `scripts/swift-test.sh --filter 'HelperProtocolTests|MLXHelperEngineTests'`

Expected: all helper protocol and engine tests pass.

- [ ] **Step 5: Commit**

```bash
git add Sources/KotobaneCore/Transcription Tests/KotobaneCoreTests Tests/Fixtures
git commit -m "feat: add local helper transcription engine"
```

## Task 5: Offline Python helper and explicit model installation

**Files:**

- Create: `helper/kotobane_helper.py`
- Create: `helper/model_install.py`
- Create: `helper/requirements.lock`
- Create: `helper/tests/test_helper.py`
- Create: `helper/tests/test_model_install.py`
- Create: `scripts/bootstrap-helper.sh`

**Interfaces:**

- Helper reads one request per stdin line and writes one response per stdout
  line; diagnostics go to stderr.
- `transcribe(request, app_support_root, backend) -> dict`.
- `install_model(model_id, destination, expected_bytes, free_bytes) -> Path`.
- Bootstrap installs the immutable arm64 CPython runtime described by
  `runtime-manifest.json` and installs exactly the hash-locked dependencies.

- [ ] **Step 1: Verify the upstream MLX integration and freeze its supply chain**

Using the required gstack `/browse` workflow, inspect only Qwen's official
Qwen3-ASR repository/model cards, the selected MLX backend's official
repository, PyPI JSON metadata, and the Python Standalone Builds release
manifest. Record:

- the exact Qwen model repository identifiers for 0.6B and 1.7B;
- the exact public Python call that accepts a local model path, local audio
  path, and Turkish language hint without network access;
- the minimum supported macOS and Python versions;
- an immutable MLX backend release or commit;
- a CPython 3.12 arm64 archive URL and SHA-256; and
- every resolved wheel URL, version, and SHA-256 for the arm64/macOS target.

Write the CPython values to `helper/runtime-manifest.json` and the resolved
packages to pip's `--require-hashes` format in `helper/requirements.lock`.
Verify every referenced URL belongs to the upstream project, PyPI, GitHub
Releases, or Hugging Face model repository selected above.

Hard stop: if the official/maintained backend cannot load both named Qwen3-ASR
models through MLX on Apple silicon, do not substitute PyTorch or a cloud API.
Report the incompatibility and revise the approved architecture with the user.

- [ ] **Step 2: Write failing helper tests**

```python
class HelperTests(unittest.TestCase):
    def test_rejects_audio_outside_app_support(self):
        request = {
            "id": "00000000-0000-0000-0000-000000000001",
            "action": "transcribe",
            "audioPath": "/tmp/escape.wav",
            "language": "Turkish",
            "model": "qwen3-asr-0.6b",
        }
        response = transcribe(request, Path("/safe/root"), FakeBackend())
        self.assertEqual(response["status"], "failed")
        self.assertEqual(response["code"], "invalid_audio_path")

    def test_completed_response_preserves_backend_text(self):
        audio = self.root / "captures" / "note.wav"
        audio.parent.mkdir(parents=True)
        audio.write_bytes(b"RIFF")
        response = transcribe(
            request_for(audio),
            self.root,
            FakeBackend(text=" şey, API'yi düzeltelim "),
        )
        self.assertEqual(response["text"], " şey, API'yi düzeltelim ")
```

Model tests assert insufficient capacity fails before backend download, staging
is not marked ready, successful validation is atomically activated, and an
interrupted download leaves only removable staging data.

- [ ] **Step 3: Verify RED**

Run: `python3 -m unittest discover -s helper/tests -v`

Expected: import failure because helper modules do not exist.

- [ ] **Step 4: Implement helper and installer**

Use `Path.resolve(strict=True)` plus `is_relative_to(app_support_root.resolve())`
for input validation. Load the selected model only from the configured local
model directory. Import MLX/Qwen dependencies lazily so missing dependencies
return `runtime_unavailable`. Emit `model_unavailable`, `invalid_audio_path`,
`unsupported_model`, and `transcription_failed` codes explicitly.

`model_install.py` accepts only the two configured upstream model identifiers,
requires `expected_bytes + max(1 GiB, expected_bytes / 10)` free space, downloads
to `.staging/<uuid>`, verifies required model files, writes `ready.json`, and
uses `os.replace` to activate.

`bootstrap-helper.sh` checks `uname -m` is `arm64`, downloads the exact CPython
archive in `runtime-manifest.json` into a staging directory, verifies SHA-256
before extraction, creates `Application Support/Kotobane/runtime/venv`, and
invokes `pip install --only-binary=:all: --require-hashes -r
requirements.lock`. Runtime and dependency downloads begin only after the user
clicks the setup action. A checksum failure removes staging and never activates
the runtime.

- [ ] **Step 5: Verify GREEN**

Run: `python3 -m unittest discover -s helper/tests -v`

Expected: all helper tests pass without importing MLX in fake-backend tests.

- [ ] **Step 6: Commit**

```bash
git add helper scripts/bootstrap-helper.sh
git commit -m "feat: add offline Qwen transcription helper"
```

## Task 6: Copy-first handoff and Accessibility fallback

**Files:**

- Create: `Sources/KotobaneCore/Handoff/HandoffCoordinator.swift`
- Create: `Sources/KotobaneCore/Handoff/SystemHandoffAdapters.swift`
- Create: `Tests/KotobaneCoreTests/HandoffCoordinatorTests.swift`

**Interfaces:**

- Produces: `ClipboardWriting`, `DestinationOpening`, `PasteAutomating`,
  `MarkdownExporting`.
- Produces: `HandoffCoordinator.perform(brief:destination:pasteAfterOpening:)`.
- Produces: `HandoffResult` describing copied, exported, activated, pasted, or
  manual-paste fallback outcomes.

- [ ] **Step 1: Write failing ordering and fallback tests**

```swift
import Testing
@testable import KotobaneCore

@Test func codexCopiesBeforeOpening() async throws {
    let events = EventRecorder()
    let coordinator = HandoffCoordinator(
        clipboard: SpyClipboard(events),
        opener: SpyOpener(events, succeeds: true),
        paste: SpyPaste(events, trusted: false),
        exporter: SpyExporter(events)
    )

    let result = try await coordinator.perform(
        brief: "brief",
        destination: .codex,
        pasteAfterOpening: false
    )

    #expect(events.values == ["copy:brief", "open:codex"])
    #expect(result == .activated(pasteAttempted: false))
}

@Test func accessibilityDenialKeepsSuccessfulCopyAndOpen() async throws {
    let events = EventRecorder()
    let coordinator = HandoffCoordinator(
        clipboard: SpyClipboard(events),
        opener: SpyOpener(events, succeeds: true),
        paste: SpyPaste(events, trusted: false),
        exporter: SpyExporter(events)
    )

    let result = try await coordinator.perform(
        brief: "brief",
        destination: .claude,
        pasteAfterOpening: true
    )

    #expect(events.values == ["copy:brief", "open:claude", "paste-trust-check"])
    #expect(result == .manualPasteRequired(reason: .accessibilityDenied))
}
```

- [ ] **Step 2: Verify RED**

Run: `scripts/swift-test.sh --filter HandoffCoordinatorTests`

Expected: compilation fails because `HandoffCoordinator` does not exist.

- [ ] **Step 3: Implement coordinator and system adapters**

Use `NSPasteboard.general` for clipboard, `NSSavePanel` plus atomic UTF-8 write
for Markdown, `NSWorkspace` for bundle-ID activation and URL fallback, and
`AXIsProcessTrustedWithOptions` plus a Command-V `CGEvent` pair for opt-in paste.
The coordinator calls `clipboard.write` before any opener method and never
clears or restores the clipboard after a failed open or paste.

- [ ] **Step 4: Verify GREEN**

Run: `scripts/swift-test.sh --filter HandoffCoordinatorTests`

Expected: ordering, export, denied-permission, and unavailable-destination tests
pass.

- [ ] **Step 5: Commit**

```bash
git add Sources/KotobaneCore/Handoff Tests/KotobaneCoreTests/HandoffCoordinatorTests.swift
git commit -m "feat: add resilient copy-first handoff"
```

## Task 7: Audio recording, shortcut registration, and capture state machine

**Files:**

- Create: `Sources/KotobaneCore/Capture/AudioRecording.swift`
- Create: `Sources/KotobaneCore/Capture/AVAudioEngineRecorder.swift`
- Create: `Sources/KotobaneCore/Capture/GlobalShortcut.swift`
- Create: `Sources/KotobaneCore/Capture/CaptureController.swift`
- Create: `Tests/KotobaneCoreTests/GlobalShortcutTests.swift`
- Create: `Tests/KotobaneCoreTests/CaptureControllerTests.swift`

**Interfaces:**

- Produces: `AudioRecording`, `MicrophoneAuthorizing`,
  `GlobalShortcutRegistering`, `CaptureController`.
- `CaptureController.State` is idle, requestingPermission, recording,
  transcribing, reviewing, or failed.
- UI observes immutable state snapshots on `@MainActor`.

- [ ] **Step 1: Write failing state and retention tests**

```swift
import Testing
@testable import KotobaneCore

@MainActor
@Test func successfulDefaultCapturePersistsTranscriptBeforeDeletingAudio() async throws {
    let events = EventRecorder()
    let controller = makeController(
        recorder: SpyRecorder(events),
        engine: StubEngine(text: "Merhaba"),
        store: SpyStore(events),
        fileSystem: SpyAudioFiles(events),
        retention: .deleteAfterTranscription
    )

    await controller.start()
    await controller.stop()

    let capture = try #require(controller.state.capture)
    #expect(capture.transcript == "Merhaba")
    #expect(events.values.suffix(2) == ["persist", "delete-audio"])
}

@MainActor
@Test func persistenceFailurePreservesAudioAndOffersRetry() async {
    let events = EventRecorder()
    let controller = makeController(
        recorder: SpyRecorder(events),
        engine: StubEngine(text: "Merhaba"),
        store: FailingStore(error: FixtureError.writeFailed),
        fileSystem: SpyAudioFiles(events),
        retention: .deleteAfterTranscription
    )

    await controller.start()
    await controller.stop()

    let failure = try #require(controller.state.failure)
    #expect(failure.recovery == .retryTranscription)
    #expect(!events.values.contains("delete-audio"))
}
```

Shortcut tests verify Control–Option–Space conversion, conflict reporting, event
handler cleanup, and callback delivery.

- [ ] **Step 2: Verify RED**

Run: `scripts/swift-test.sh --filter 'CaptureControllerTests|GlobalShortcutTests'`

Expected: compilation fails because capture interfaces do not exist.

- [ ] **Step 3: Implement adapters and controller**

`AVAudioEngineRecorder` uses
`AVCaptureDevice.authorizationStatus(for: .audio)` and
`AVAudioEngine.inputNode`. Install a tap, write buffers through `AVAudioFile`,
publish RMS meter values, and reject a recording with zero written frames.

The Carbon adapter registers one `EventHotKeyRef`, installs one application
event handler, maps the configured modifier mask, and disposes both resources
on reconfiguration/deinit.

The controller performs permission, recording, transcription, persistence, then
retention in that order. Cancel removes valid temporary audio only after the
recorder is stopped. Helper failures preserve audio and attach retry guidance.

- [ ] **Step 4: Verify GREEN**

Run: `scripts/swift-test.sh --filter 'CaptureControllerTests|GlobalShortcutTests'`

Expected: controller transition, cleanup, retry, and shortcut tests pass.

- [ ] **Step 5: Commit**

```bash
git add Sources/KotobaneCore/Capture Tests/KotobaneCoreTests/CaptureControllerTests.swift Tests/KotobaneCoreTests/GlobalShortcutTests.swift
git commit -m "feat: capture microphone audio from a global shortcut"
```

## Task 8: Model state and disk-space safety

**Files:**

- Create: `Sources/KotobaneCore/Transcription/ModelManager.swift`
- Create: `Tests/KotobaneCoreTests/ModelManagerTests.swift`

**Interfaces:**

- Produces: `ModelManaging`, `ModelState`, `DiskCapacityReading`,
  `ModelInstallerRunning`.
- `install(_:)` moves through notInstalled → downloading → ready or failed.
- Model deletion removes active and staging paths for only the selected model.

- [ ] **Step 1: Write failing capacity and activation tests**

```swift
import Testing
@testable import KotobaneCore

@MainActor
@Test func insufficientSpacePreventsInstallerLaunch() async {
    let installer = SpyInstaller()
    let manager = ModelManager(
        catalog: .fixtures(smallBytes: 4_000),
        capacity: StubCapacity(bytes: 4_399),
        installer: installer
    )

    await manager.install(.small)

    #expect(manager.state == .failed(.insufficientSpace(required: 5_000, available: 4_399)))
    #expect(installer.launchCount == 0)
}
```

- [ ] **Step 2: Verify RED**

Run: `scripts/swift-test.sh --filter ModelManagerTests`

Expected: compilation fails because `ModelManager` does not exist.

- [ ] **Step 3: Implement model management**

Define a checked-in catalog with upstream identifier, display download bytes,
required installed bytes, and minimum safety margin for each model. Read volume
capacity through `URLResourceValues.volumeAvailableCapacityForImportantUsage`.
Run the explicit installer process, consume structured progress lines, and
report error codes without treating staging as ready.

- [ ] **Step 4: Verify GREEN**

Run: `scripts/swift-test.sh --filter ModelManagerTests`

Expected: state, capacity, installer-failure, ready-marker, and deletion tests
pass.

- [ ] **Step 5: Commit**

```bash
git add Sources/KotobaneCore/Transcription/ModelManager.swift Tests/KotobaneCoreTests/ModelManagerTests.swift
git commit -m "feat: manage local transcription models safely"
```

## Task 9: SwiftUI menu-bar experience and review workflow

**Files:**

- Create: `Sources/KotobaneApp/AppContainer.swift`
- Create: `Sources/KotobaneApp/KotobaneApp.swift`
- Create: `Sources/KotobaneApp/MenuBarContent.swift`
- Create: `Sources/KotobaneApp/RecorderOverlay.swift`
- Create: `Sources/KotobaneApp/ReviewWindow.swift`
- Create: `Sources/KotobaneApp/HistoryWindow.swift`
- Create: `Sources/KotobaneApp/SettingsWindow.swift`
- Create: `Sources/KotobaneApp/ModelSetupView.swift`
- Modify: `Package.swift`

**Interfaces:**

- Consumes all core services through `AppContainer`.
- Produces the `KotobaneApp` executable and no new business rules.

- [ ] **Step 1: Add a failing executable smoke check**

Add an executable target depending on `KotobaneCore`, temporarily point it at a
missing `KotobaneApp` entry point, then run:

Run: `swift build --product Kotobane`

Expected: compilation fails because the application entry point is missing.

- [ ] **Step 2: Implement the app shell**

```swift
@main
struct KotobaneApp: App {
    @State private var container = AppContainer.live()

    var body: some Scene {
        MenuBarExtra("Kotobane", systemImage: container.capture.isRecording ? "waveform.circle.fill" : "waveform.circle") {
            MenuBarContent(container: container)
        }
        Window("Capture Review", id: "review") {
            ReviewWindow(container: container)
        }
        Window("History", id: "history") {
            HistoryWindow(container: container)
        }
        Settings {
            SettingsWindow(container: container)
        }
    }
}
```

`RecorderOverlay` is hosted in a borderless floating `NSPanel` on the active
screen and shows recording status, elapsed time, level, Stop, and Cancel.
`ReviewWindow` binds title and transcript directly to a draft capture, provides
the five intents and four targets, and displays the exact privacy copy.

History loads local captures newest-first and supports open and confirmed
delete. Settings covers shortcut, default language, model, retention, built-in
destination configuration, opt-in paste, model install/remove, and confirmed
full local-data deletion. All errors include a concrete recovery button where
the design specifies one.

- [ ] **Step 3: Build the executable**

Run: `swift build --product Kotobane`

Expected: successful debug build with no concurrency or deprecation errors that
affect behavior.

- [ ] **Step 4: Run the complete Swift test suite**

Run: `scripts/swift-test.sh`

Expected: all tests pass.

- [ ] **Step 5: Commit**

```bash
git add Package.swift Sources/KotobaneApp
git commit -m "feat: add menu bar capture and review experience"
```

## Task 10: Application packaging, licensing, and operator documentation

**Files:**

- Create: `Resources/Info.plist`
- Create: `Resources/Kotobane.entitlements`
- Create: `scripts/package-app.sh`
- Create: `scripts/verify.sh`
- Create: `README.md`
- Create: `LICENSE`
- Create: `THIRD_PARTY_NOTICES.md`
- Modify: `.gitignore`

**Interfaces:**

- Produces: `dist/Kotobane.app`.
- `scripts/verify.sh` is the single deterministic local verification entry
  point.

- [ ] **Step 1: Write a packaging smoke check that fails before the script exists**

Run: `test -x scripts/package-app.sh && scripts/package-app.sh`

Expected: failure because the packaging script does not exist.

- [ ] **Step 2: Implement packaging**

`package-app.sh` must:

1. reject non-arm64 hosts;
2. run `swift build -c release --product Kotobane`;
3. create `dist/Kotobane.app/Contents/{MacOS,Resources}`;
4. copy the release executable to `Contents/MacOS/Kotobane`;
5. copy the helper, lock file, bootstrap script, and `Info.plist`;
6. set `CFBundleIdentifier=dev.kotobane.app`,
   `LSMinimumSystemVersion=14.0`, `LSUIElement=true`, and
   `NSMicrophoneUsageDescription`;
7. sign with `codesign --force --deep --sign - --entitlements
   Resources/Kotobane.entitlements`; and
8. verify with `codesign --verify --deep --strict`.

`verify.sh` runs:

```bash
scripts/swift-test.sh
python3 -m unittest discover -s helper/tests -v
swift build -c release --product Kotobane
scripts/package-app.sh
plutil -lint Resources/Info.plist
codesign --verify --deep --strict dist/Kotobane.app
```

Choose the MIT License. Document Apple-silicon and macOS floors, Command Line
Tools build steps, first-run model setup, disk-size display behavior, local data
paths and retention, permissions, Gatekeeper expectations for ad-hoc builds,
verification, deletion, and the separate policies of external destinations.
List Qwen3-ASR, MLX, and every pinned helper dependency in third-party notices
with upstream license references.

- [ ] **Step 3: Verify packaging GREEN**

Run: `scripts/package-app.sh`

Expected: `dist/Kotobane.app` exists and `codesign --verify` exits zero.

- [ ] **Step 4: Run the fresh full verification gate**

Run: `scripts/verify.sh`

Expected: Swift tests, Python tests, release build, plist validation, packaging,
and signature verification all exit zero. Record exact test counts in the
handoff.

- [ ] **Step 5: Inspect repository hygiene**

Run:

```bash
git status --short
git check-ignore dist/Kotobane.app
find . -type d \( -name .venv -o -name models -o -name captures \) -prune -print
git diff --check
```

Expected: only intended source/documentation changes are uncommitted; the app
bundle is ignored; no runtime/model/capture directories are tracked; diff check
is clean.

- [ ] **Step 6: Commit**

```bash
git add .gitignore Resources scripts README.md LICENSE THIRD_PARTY_NOTICES.md
git commit -m "build: package and document the Kotobane MVP"
```

## Task 11: Manual MVP acceptance

**Files:**

- Create: `docs/qa/2026-07-24-mvp-acceptance.md`
- Create: `Tests/Acceptance/README.md`

**Interfaces:**

- Produces a reproducible manual checklist and a manifest format for ten
  untracked/private Turkish audio fixtures.

- [ ] **Step 1: Create the manual checklist**

Record pass/fail/not-run plus evidence for:

1. microphone first-run allow and deny;
2. Control–Option–Space start/stop while another app is active;
3. overlay placement, elapsed time, level, stop, and cancel;
4. model-missing recovery with no cloud fallback;
5. one real Turkish transcription using Qwen3-ASR-0.6B;
6. transcript editing and exact Brainstorm output;
7. clipboard and Markdown without Accessibility;
8. Codex and Claude unavailable fallback;
9. Accessibility denied and allowed paste flows;
10. default deletion and retained-audio behavior;
11. helper crash/retry and audio preservation;
12. single capture and all-local-data deletion.

The acceptance fixture manifest requires ten clips spanning numbers, dates,
English technical terms, proper names, hesitations, and long-form product ideas.
It explicitly excludes audio files from Git.

- [ ] **Step 2: Launch the packaged app for smoke testing**

Run: `open dist/Kotobane.app`

Expected: a Kotobane menu-bar item appears and the process remains running.

- [ ] **Step 3: Execute every non-model manual check**

Update the QA document with observed results and exact recovery messages. Do
not mark model-dependent checks passed without installing the runtime/model and
performing a real transcription.

- [ ] **Step 4: Run final automated verification again**

Run: `scripts/verify.sh`

Expected: all automated checks exit zero after manual-QA documentation changes.

- [ ] **Step 5: Commit acceptance documentation**

```bash
git add docs/qa/2026-07-24-mvp-acceptance.md Tests/Acceptance/README.md
git commit -m "docs: record Kotobane MVP acceptance"
```

## Completion criteria

Before claiming the MVP complete:

- every checked implementation task has a corresponding RED and GREEN command
  result;
- `scripts/verify.sh` has just completed with exit status zero;
- `git status --short` is clean;
- `git log --oneline` shows the design, plan, and task commits;
- manual checks are reported honestly as passed, failed, or not run;
- a real Turkish/Qwen acceptance claim is made only with recorded model-backed
  evidence; and
- the final handoff distinguishes the verified deterministic app build from any
  model download or permission-dependent checks the environment could not run.
