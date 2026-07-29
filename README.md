# Kotobane

> A local-first voice capture and handoff tool for macOS.

Kotobane captures an explicit spoken thought, transcribes it locally with
Qwen3-ASR, and prepares an editable handoff for Codex, Claude, the clipboard,
or a Markdown file. Turkish is the default language hint.

![Status](https://img.shields.io/badge/status-0.1.0--beta.4-7c3aed)
![Platform](https://img.shields.io/badge/macOS-14%2B-111827)
![Architecture](https://img.shields.io/badge/Apple%20silicon-arm64-f59e0b)
[![License: MIT](https://img.shields.io/badge/license-MIT-22c55e)](LICENSE)

## Download

[Download Kotobane 0.1.0-beta.4](https://github.com/Jouskar/Kotobane/releases/download/v0.1.0-beta.4/Kotobane-0.1.0-beta.4.zip)

1. Unzip the download.
2. Move `Kotobane.app` to Applications.
3. On first launch, Control-click the app in Finder and choose **Open**.
4. Confirm **Open** in the Gatekeeper dialog.

This beta is ad-hoc signed and not notarized. It requires an Apple-silicon Mac
running macOS 14 Sonoma or newer.

## Why Kotobane?

Thinking out loud is often faster than structuring an idea. Kotobane preserves
that first draft locally, then gives you a clean, editable handoff for the tool
where the real reasoning happens.

## Workflow

```text
Capture → Local transcription → Review and edit → Deterministic handoff
```

1. Start capture with the configurable global shortcut.
2. Speak while the compact overlay shows duration and microphone level.
3. Stop capture and wait for local Qwen3-ASR transcription.
4. Edit the transcript and select an intent.
5. Copy or export the result, or open Codex/Claude for handoff.

## Intent options

| Intent | Output |
| --- | --- |
| Transcript only | The edited transcript exactly as written; no wrapper or additions. |
| Brainstorm | Summary, decisions, open questions, and recommended next actions. |
| Task | Task summary, acceptance criteria, constraints, and next actions. |
| Project idea | Problem, outcome, scope, assumptions, risks, and validation steps. |
| Meeting note | Summary, decisions, action items, owners, and follow-up. |
| Freeform | Key points, open questions, and a recommended next action. |

## Local-first by design

Kotobane records only during an explicit capture. Audio is transcribed on the
Mac through Qwen3-ASR and is deleted after successful transcription by default.
You can retain recordings locally, delete individual captures, or delete all
local data from Settings.

Kotobane has no account, cloud sync, telemetry, continuous listening, system
audio capture, hosted transcription, LLM rewriting, or cloud fallback.

The only intentional outbound actions are user-triggered text export or opening
the selected Codex/Claude destination. Text submitted there follows that
product’s own policies.

## First-run setup

Open Settings and install the local runtime and one of the supported models:

- Qwen3-ASR 0.6B (recommended): approximately 1.88 GB.
- Qwen3-ASR 1.7B (accuracy mode): approximately 4.70 GB.

Microphone permission is requested before the first recording. Accessibility is
optional and is requested only for automated paste after opening a destination.

## Build from source

Requirements:

- Apple-silicon Mac (`arm64`)
- macOS 14 Sonoma or newer
- Swift 6.3 and Apple Command Line Tools

```sh
git clone https://github.com/Jouskar/Kotobane.git
cd Kotobane
git switch develop
scripts/run-app.sh
```

`scripts/run-app.sh` packages and launches the app bundle. To package without
launching it:

```sh
scripts/package-app.sh
open dist/Kotobane.app
```

The packaging script creates an ad-hoc-signed app by default and refuses to
package on a non-arm64 host. To use a locally installed Developer ID
Application identity, pass it explicitly:

```sh
KOTOBANE_SIGNING_IDENTITY='Developer ID Application: Your Name (TEAMID)' \
  scripts/package-app.sh
```

Run `scripts/verify.sh` for the complete local verification gate.

## Project status

Kotobane is beta software. Current support is limited to Apple-silicon Macs and
macOS 14+. Model weights are not included in the repository or app download;
they are installed after explicit user confirmation according to their upstream
licenses.

## Contributing and licensing

Contributions are welcome. See [CONTRIBUTING.md](CONTRIBUTING.md),
[CODE_OF_CONDUCT.md](CODE_OF_CONDUCT.md), and the [Git Flow guide](docs/GIT_FLOW.md).

Kotobane is available under the [MIT License](LICENSE). Third-party components
retain their own licenses; see [THIRD_PARTY_NOTICES.md](THIRD_PARTY_NOTICES.md).
