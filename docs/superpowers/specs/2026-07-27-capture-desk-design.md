# Capture Desk design

## Goal

Give Kotobane a clear primary interface while keeping its menu-bar-first capture
workflow. Make the active recording state legible with a lightweight live
waveform, complete the Claude handoff experience, and make transcription work
when launched with `swift run` as well as from a packaged app.

## Experience

Kotobane remains a menu-bar app. Selecting the menu-bar item opens a compact
native menu with Start Capture, current status, recent captures, Settings, and
Quit. A new `Capture Desk` window is the app's primary visual home:

- Header: app name, local-only status, model readiness, and Settings.
- Main action: a prominent Record button when idle; a clear Transcribing state
  while a local transcription runs.
- Local history: recent captures with title, intent, timestamp, and transcript
  preview; selecting one opens the existing editable review window.
- Empty state: explains that audio and transcript remain local until exported.

The Capture Desk opens from the menu and is activated after a new capture has
been saved. It never starts recording without an explicit user action.

## Recording overlay and waveform

During explicit capture, Kotobane displays a non-activating floating recorder
near the active display. It contains the recording title, elapsed time, Cancel,
and Stop. The existing scalar microphone level is rendered as a deterministic,
animated SwiftUI waveform: a fixed number of vertical bars whose heights derive
from the current RMS level plus a stable phase offset. It updates only while
recording, introduces no additional audio capture, and respects reduced-motion
by rendering static bars.

## Claude handoff

Claude uses the same deterministic Markdown brief as every other target. The
handoff sequence is fixed:

1. Copy the full brief to the clipboard.
2. Activate the installed Claude desktop app (`com.anthropic.claude`) if
   available.
3. Otherwise open `https://claude.ai/new` using the user's normal browser.
4. When the user enabled Accessibility-based paste automation, paste only after
   the destination is active. Otherwise show that the brief is ready to paste.

Failure to open a destination never clears the clipboard. The review UI names
the target and preserves the existing external-policy note.

## Development helper launch

Packaged apps launch the helper through
`Contents/Helpers/kotobane-launch-shim`. Swift Package Manager builds place
`kotobane-launch-shim` beside the Kotobane executable instead. The launch
configuration will choose the packaged helper path when it exists and otherwise
use the sibling executable path. If neither is executable, it reports actionable
helper-install guidance and keeps the failed capture's audio for retry/export.

## Boundaries

No new network service, user account, analytics, cloud transcription, or LLM
rewriting is introduced. Runtime and model downloads remain user-triggered via
Install Model. The waveform processes only the already-captured local RMS level.

## Verification

- Unit test helper-launch path selection for packaged and SwiftPM layouts.
- Unit test Claude handoff: clipboard write happens before desktop activation
  and browser fallback; inaccessible paste retains the clipboard handoff.
- Unit test waveform bar values are bounded and stable for a given RMS input.
- Manual QA: Capture Desk opens from the menu; start/stop and waveform update;
  `swift run` transcribes with a ready model; Claude desktop and browser fallback
  both retain the brief on the clipboard.
