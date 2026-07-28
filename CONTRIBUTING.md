# Contributing to Kotobane

Thank you for helping make local-first voice capture better.

## Before you start

- Read the [README](README.md) and [Git Flow guide](docs/GIT_FLOW.md).
- Discuss significant changes in an issue before investing in implementation.
- Keep v1 local-first: do not add telemetry, cloud transcription, or network
  fallbacks without an explicit project decision.

## Development flow

1. Branch from `develop`: `feature/<short-description>`.
2. Keep each change focused and add or update tests.
3. Run the relevant tests; use `scripts/verify.sh` before a release-sized
   change when your environment supports it.
4. Open a pull request against `develop` with a concise description, test
   evidence, and screenshots for UI changes.

Use `release/<version>` for release preparation and `hotfix/<name>` from
`main` only for production fixes.

## Code expectations

- Prefer clear, idiomatic Swift and small focused commits.
- Preserve the user’s raw transcript verbatim except for edits they make.
- Keep audio, transcripts, and models local by default.
- Do not commit downloaded models, recordings, local runtime files, or secrets.

By contributing, you agree that your contributions are licensed under the
[MIT License](LICENSE).
