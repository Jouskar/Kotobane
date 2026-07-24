# Kotobane

Kotobane is a local-first macOS menu-bar app for capturing an explicit voice
note, transcribing it with Qwen3-ASR, reviewing the transcript, and preparing a
deterministic Markdown handoff for Codex, Claude, the clipboard, or a file.
Turkish is the default language hint.

Kotobane does not continuously listen, capture system audio, send audio to a
hosted transcription service, rewrite transcripts with an LLM, create an
account, synchronize data, collect telemetry, or include a cloud fallback.

## Requirements

- An Apple-silicon Mac (`arm64`)
- macOS 14 Sonoma or newer
- Apple Command Line Tools with Swift 6.3
- Internet access during the explicit runtime and model installation steps

Install the Command Line Tools if needed:

```sh
xcode-select --install
```

The repository and packaged app intentionally contain no Python runtime, model
weights, recordings, transcripts, or captures.

## Build and package

From the repository root:

```sh
swift build --product Kotobane
scripts/package-app.sh
open dist/Kotobane.app
```

`scripts/package-app.sh` builds both release executables, creates
`dist/Kotobane.app`, copies the helper assets, and applies an ad-hoc signature.
It refuses to package on a non-arm64 host.

To run the complete deterministic local gate:

```sh
scripts/verify.sh
```

The gate runs the Swift and Python tests, release builds, packaging, property
list validation, signature verification, helper-isolation checks, and a signed
entitlement check that rejects network client or server access.

## First-run setup

Install the pinned local Python runtime from a repository checkout:

```sh
scripts/bootstrap-helper.sh
```

This downloads a checksum-locked CPython 3.12 runtime and installs the
hash-locked helper dependencies below
`~/Library/Application Support/Kotobane/runtime`.

Open Kotobane's settings, choose a model, and select **Install Model**. The
recommended Qwen3-ASR 0.6B download is about 1.88 GB; the optional 1.7B model is
about 4.70 GB. Before downloading, Kotobane shows the expected size and minimum
free-space requirement. The capacity check includes a safety margin of the
larger of 1 GiB or ten percent of the model size. An interrupted download stays
in staging and is never activated as a ready model.

Model installation is the only model-related network operation. Transcription
runs through a child process placed in an explicit deny-network sandbox.

## Permissions

Kotobane asks for microphone access immediately before the first recording.
If access is denied, enable Kotobane in **System Settings → Privacy & Security
→ Microphone**.

Accessibility access is optional and is requested only when automatic paste is
enabled. Without it, Kotobane still copies the complete brief and opens the
selected destination for manual paste. Clipboard and Markdown export do not
require Accessibility access.

## Local data and privacy

Kotobane stores private data beneath:

```text
~/Library/Application Support/Kotobane/
├── captures/       transcript metadata and retained WAV recordings
├── models/         explicitly downloaded Qwen3-ASR models
├── runtime/        pinned Python runtime and virtual environment
└── settings.json   local preferences
```

Temporary capture files also remain inside Kotobane's private Application
Support area. macOS may maintain ordinary transient app data in the user's
Library caches.

By default, raw audio is deleted only after the transcript is persisted
successfully. If audio retention is enabled, the recording remains with the
capture until that capture is deleted. Failed or interrupted transcription
preserves the temporary recording for recovery.

Settings offers **Delete All Local Data**, which removes captures, retained and
temporary audio, and downloaded models after confirmation. The runtime can be
removed separately:

```sh
rm -rf "$HOME/Library/Application Support/Kotobane/runtime"
```

Only run that command when Kotobane is closed and you intend to remove its local
runtime. Removing the entire
`~/Library/Application Support/Kotobane` directory deletes all Kotobane data.

Audio and transcripts remain on this Mac until you explicitly export or send
text. Text handed to Codex, Claude, or another destination is then governed by
that product's separate privacy, retention, and account policies.

## Gatekeeper and distribution

The packaging script creates an ad-hoc-signed build for local development. It
is not Developer ID signed, notarized, or intended for the Mac App Store.
Gatekeeper can therefore warn about or block a copy received from another Mac.
Prefer building from a trusted checkout. After verifying the source, use
Finder's **Open** context-menu action or the **Open Anyway** control in
**System Settings → Privacy & Security** if macOS offers it. Do not disable
Gatekeeper system-wide.

## License

Kotobane is available under the [MIT License](LICENSE). Qwen3-ASR, MLX, and the
pinned Python helper dependencies retain their own licenses; see
[THIRD_PARTY_NOTICES.md](THIRD_PARTY_NOTICES.md).
