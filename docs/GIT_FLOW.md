# Git Flow

Kotobane uses a lightweight Git Flow model.

## Permanent branches

- `main` contains released code only. Every public release is tagged here.
- `develop` is the integration branch for the next release.

## Working branches

- `feature/<name>` branches from `develop` and merges back into `develop`.
- `release/<version>` branches from `develop` when beta/release stabilization
  starts. It merges into both `main` and `develop`, then receives a `v<version>`
  tag on `main`.
- `hotfix/<version-or-name>` branches from `main` for production fixes. It
  merges into both `main` and `develop`, then receives a patch tag on `main`.

## First release

The current baseline is **0.1.0-beta.4** and is tagged as `v0.1.0-beta.4` on
`main`. Its hotfix branch is short-lived and deleted after merging; ongoing
work continues from `develop` through feature branches.

## Example commands

```sh
git switch develop
git switch -c feature/recording-polish

git switch develop
git switch -c release/0.1.0-beta.2

git switch main
git switch -c hotfix/0.1.1-crash
```
