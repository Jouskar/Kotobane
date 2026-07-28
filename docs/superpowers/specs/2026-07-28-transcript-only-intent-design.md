# Transcript Only Intent Design

## Goal

Add a `Transcript only` capture intent for handoffs that should contain only
the user-edited transcript.

## Behavior

- The existing intent selector gains `Transcript only`.
- For this intent, `BriefComposer.compose` returns its `transcript` argument
  unchanged.
- The result has no Markdown heading, instruction, checklist, title, or
  whitespace added or removed by Kotobane.
- Clipboard, Markdown, Codex, and Claude use the same existing handoff path;
  only the composed text changes.
- Existing intent templates and stored captures remain compatible.

## Implementation

Add a `transcriptOnly` case to `CaptureIntent`. Make `BriefComposer` return
early for that case, before selecting an `IntentTemplate`; the template type
therefore remains responsible only for templated intents.

## Validation

Add a unit test that supplies a transcript with leading spaces and paragraph
breaks and asserts `Transcript only` returns exactly the same string. Keep the
existing template test green for all other intents.
