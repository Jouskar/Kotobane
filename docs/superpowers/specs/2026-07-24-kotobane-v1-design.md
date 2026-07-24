# Kotobane v1 Design

**Status:** Approved  
**Date:** 2026-07-24  
**Deployment target:** macOS 14 Sonoma or newer on Apple silicon

## Product

Kotobane is an open-source menu-bar application for capturing an explicit,
on-demand voice note, transcribing it locally with Qwen3-ASR, and preparing an
editable deterministic handoff for Codex, Claude, the clipboard, or a Markdown
file. Turkish is the default language hint.

The application does not continuously record, capture system audio, call a
hosted transcription service, rewrite transcripts with an LLM, create user
accounts, synchronize data, or collect telemetry. The provisional name is a
coined Japanese-rooted brand inspired by words becoming seeds; the product does
not present it as a standard Japanese word.

## MVP outcome

The MVP is a runnable, ad-hoc-signed macOS application bundle produced without
requiring a full Xcode installation. It proves the complete local workflow:

1. Start or stop a recording from a configurable global shortcut or UI.
2. Record microphone input into the app's private local storage.
3. Invoke a private newline-delimited JSON helper process.
4. Transcribe locally through Qwen3-ASR after an explicit model installation.
5. Review and edit the transcript.
6. Compose an intent-specific deterministic Markdown brief.
7. Copy or export the brief before activating an optional destination.
8. Retain the capture in local history while applying the configured audio
   retention policy.

Actual model weights are not committed or bundled. The user explicitly installs
the selected model at first run after seeing the download and disk-space
requirements. Recording and review remain usable when no destination
application is installed.

## Build and repository approach

The repository uses Swift Package Manager for the Swift application and tests.
A packaging script assembles the release executable, resources, `Info.plist`,
and entitlements into `Kotobane.app`, then applies ad-hoc code signing. This
allows the installed Apple Command Line Tools and Swift 6.3 toolchain to compile
and test the project today.

The package layout keeps reusable product behavior in a library target and the
SwiftUI/AppKit entry point in an executable target. This makes the deterministic
and persistence behavior testable without launching the UI. A future
conventional Xcode project may consume the same targets without changing their
interfaces.

The repository is initialized on a `main` branch at
`~/Projects/Kotobane`. It contains no model weights, Python virtual environment,
recordings, transcripts, generated application bundles, or developer-specific
settings.

## Architecture

### Application shell

`KotobaneApp` owns the SwiftUI lifecycle, a `MenuBarExtra`, settings and history
windows, and application services. The menu bar presents Record/Stop, Recent
Captures, Settings, and Quit actions. A small floating `NSPanel` hosts the
recording overlay and appears on the active display.

The app uses explicit observable state rather than embedding capture logic in
views. UI actions call the relevant controller or coordinator, and views render
the resulting state.

### Capture

`CaptureController` is a state machine with idle, requesting-permission,
recording, transcribing, reviewing, and failed states. It owns:

- microphone authorization through `AVCaptureDevice`;
- input capture through `AVAudioEngine`;
- metering and elapsed-time updates;
- safe stop and cancel behavior;
- temporary audio-file lifecycle; and
- coordination with the transcription engine and store.

Recordings are written as linear PCM WAV files inside the app's Application
Support capture directory. WAV avoids a separate encoding step and gives the
helper a stable input format. A recording is valid only after the audio engine
starts and writes at least one buffer.

The global shortcut uses the macOS Carbon hot-key API behind a
`GlobalShortcutRegistering` interface. The default shortcut is
Control–Option–Space. Registration failure leaves menu-bar recording available
and presents recovery guidance so a shortcut conflict never disables capture.

### Transcription

`TranscriptionEngine` exposes an asynchronous transcription operation over a
local audio URL, language hint, and model selection. `MLXHelperEngine` launches
the bundled Python helper with `Process`, writes one JSON request per line, and
decodes one response per line.

The request schema is:

```json
{"id":"uuid","action":"transcribe","audioPath":"/absolute/private/path.wav","language":"Turkish","model":"qwen3-asr-0.6b"}
```

A completed response contains `id`, `status`, `text`, `detectedLanguage`, and
`durationSeconds`. A failed response contains `id`, `status`, `code`, and a
human-readable `message`. Unknown status values and malformed responses are
protocol errors.

The helper canonicalizes the supplied audio path and rejects any path outside
Kotobane's Application Support directory. It uses no listening port and makes
no network request during transcription. The process receives an environment
that enables offline model loading. On a crash or timeout, the engine preserves
the recording, restarts the helper once, and then returns actionable
diagnostics.

The Python helper is installed into an app-managed virtual environment by an
explicit setup command. Its dependency versions are pinned. The helper reports
missing runtime, missing model, unsupported architecture, and import failures
as distinct machine-readable errors. Qwen3-ASR-0.6B is the default;
Qwen3-ASR-1.7B is the optional accuracy model.

### Model management

`ModelManager` exposes not-installed, downloading, ready, and failed states.
Before a download, it retrieves model metadata, shows expected storage use, and
checks available disk capacity with a safety margin. Downloads land in a
staging directory and become active only after validation and an atomic move.
Interrupted or invalid staging data is safe to remove and is never treated as a
ready model.

Recording does not require network access. Model installation is the only
network-dependent setup flow and always begins from an explicit user action.
The settings UI can remove either model and its staging data.

### Persistence

`CaptureStore` persists each capture as one UTF-8 JSON metadata file in an
app-managed captures directory. This avoids introducing a database dependency
for v1 while supporting atomic writes, inspection, backup, and deletion.

A capture contains:

- stable UUID;
- editable title;
- creation and modification dates;
- transcript;
- intent;
- transcription status and optional diagnostic;
- original duration; and
- optional relative audio filename.

Files are written to a temporary sibling and atomically replaced. The store
never persists an absolute audio path. Deleting a capture removes its metadata
and retained audio. “Delete all local data” removes capture records, recordings,
temporary files, and downloaded models after explicit confirmation.

After successful transcription, the default retention policy deletes raw audio
only after the transcript has been persisted successfully. When retention is
enabled, audio moves from temporary storage to the capture directory. Failed or
interrupted transcription preserves the temporary recording for retry.

### Brief composition and review

The review window contains editable title and transcript fields, intent and
target selectors, a privacy note, and primary and secondary actions. Transcript
text is never silently normalized or rewritten.

`BriefComposer` is a pure value type. Each intent owns a fixed heading,
introductory instruction, desired outcome, and requested-response checklist.
The Brainstorm template is exactly:

```markdown
# Brainstorm captured in Kotobane

Please help me turn the following spoken brainstorm into a clear next step.

## Desired outcome

Clarify the idea, identify assumptions and missing decisions, then propose an actionable plan.

## Raw transcript

<edited transcript>

## Requested response

1. Concise summary
2. Decisions and constraints
3. Open questions
4. Recommended next actions
```

The composer adds no whitespace to the edited transcript beyond the fixed
template delimiters.

### Handoff

`HandoffCoordinator` accepts a composed brief and a configuration-driven
destination. Clipboard and Markdown export require no Accessibility access.
Codex and Claude actions always write the complete brief to the clipboard before
attempting activation or URL opening.

A destination defines its display name, optional bundle identifier, optional
URL, and paste capability. Activation tries the configured installed
application and then the configured URL. Failure leaves the clipboard intact
and shows a manual-paste instruction.

Automated paste is disabled by default. Enabling it explains and requests
Accessibility permission. Paste is attempted only after an explicit handoff
click and successful activation. Accessibility denial degrades to copy and
activate without blocking the handoff.

## Privacy and permissions

The app requests microphone permission immediately before the first recording.
Denial presents a link to the relevant System Settings pane. Accessibility is
requested only when the user enables paste automation.

Audio and transcript data live beneath the app's Application Support and cache
directories. The review UI states: “Audio and transcript remain on this Mac
until you send exported text.” Destination UI explains that text submitted to
Codex or Claude is governed by that product's separate policies.

The packaged app contains the microphone usage description and the minimum
entitlements needed for audio input and user-selected file export. It does not
enable incoming network connections, analytics, account services, or cloud
containers.

## Failure behavior

- Microphone denial never starts the audio engine and provides a System Settings
  recovery action.
- Missing input or recording failure stops safely and removes invalid audio.
- Missing runtime or model opens setup rather than falling back to a cloud
  service.
- Insufficient disk capacity prevents model activation and reports required and
  available space.
- Helper crash or timeout preserves audio, retries once with a fresh helper, and
  then exposes diagnostics.
- Transcription failure preserves the capture and offers retry, retained-audio
  export, or deletion.
- Accessibility denial still completes clipboard and destination activation.
- Destination failure leaves the brief on the clipboard.
- Persistence failure never triggers default audio deletion.

## Testing and verification

Unit tests cover:

- exact intent templates and verbatim transcript preservation;
- helper request/response encoding and protocol failures;
- path-validation rules shared with helper fixtures;
- capture-store atomic persistence and deletion;
- default and retained-audio cleanup policies;
- shortcut representation and registration failure state;
- destination copy-first ordering and fallback behavior; and
- settings decoding and migration defaults.

Integration tests launch a deterministic fake helper to verify request routing,
timeouts, one restart, malformed responses, model-missing errors, and process
cleanup. Filesystem integration tests cover successful transcription cleanup,
retry preservation, transcript persistence, and full capture deletion.

The verification commands are `swift test`, `swift build -c release`, the helper
Python test suite, and the app packaging script. Manual QA covers microphone and
Accessibility permission paths, shortcut conflict, Turkish dictation,
cancellation, missing destinations, interrupted model installation, and full
local-data deletion.

Ten Turkish acceptance clips include numbers, dates, English technical terms,
proper names, hesitations, and long-form product ideas. Model-dependent
acceptance is recorded separately from deterministic unit and integration test
results because weights are intentionally downloaded outside the repository.

## MVP acceptance

The build is accepted when:

1. An Apple-silicon user can explicitly install Qwen3-ASR-0.6B and transcribe a
   Turkish microphone recording locally.
2. A configurable global shortcut starts and stops capture.
3. Every handoff follows editable transcript review.
4. Brainstorm output matches the fixed template exactly.
5. Clipboard and Markdown export work without Accessibility permission.
6. Codex and Claude handoffs copy before destination activation.
7. Default retention deletes audio only after transcript persistence.
8. Capture deletion removes transcript metadata and retained audio.
9. Permission, model, helper, persistence, and destination failures preserve
   user data and provide a recovery action.
10. The repository builds and tests with Apple Command Line Tools, and its
    packaging script produces a launchable ad-hoc-signed application bundle.

## Deferred work

The MVP excludes a pure Swift/MLX engine, streaming partial transcripts,
speaker diarization, system-audio capture, additional language UX, vocabulary
hints, local LLM rewriting, BYOK services, template editing, custom destination
editing, rich audio browsing, sync, telemetry, accounts, subscriptions,
App Store distribution, Intel Mac, iOS, Windows, and Linux.
