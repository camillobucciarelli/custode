---
name: flutter-toolchain-upgrade
description: The procedure for upgrading the pinned Flutter version and for keeping the self-hosted release runners on it. Use when bumping .fvmrc, when a build fails the Flutter version check, or when changing release.yml toolchain setup.
---

# Flutter toolchain upgrade

The pin is an exact version, not the `stable` channel, because a channel moves
under the repo: when stable advanced from 3.44.8 to 3.47.1 a clean checkout of
`main` went from 1318 passing tests to 42 golden failures (sub-1% antialiasing
diffs) plus a `pub get --enforce-lockfile` failure, with no change to the code.
A moving toolchain means the test gate is not reproducible from the repository —
a fresh clone and CI can disagree with each other and with yesterday's green run.

**To upgrade the toolchain** (a dedicated change, never a side effect of
something else):

1. Bump the version in `.fvmrc`. That is the only place it is written.
2. `fvm install && fvm use <version>`, then `fvm flutter pub get`.
3. Regenerate the golden files and review the diffs — confirm they are rendering
   changes from the new engine, not real UI regressions.
4. Run `fvm flutter analyze` and the full `fvm flutter test`, and record the
   before/after counts in the PR.
5. Update the version and revision quoted in AGENTS.md.
6. Install the new version on the self-hosted runners (below) *before* the next
   release, or their jobs will fail the version check by design.

#### Self-hosted release runners

The `ios` and `macos` jobs in `release.yml` run on `runs-on: self-hosted` and have
no `flutter-action` step, so nothing in the workflow installs a toolchain — they
build with whatever Flutter the machine provides. These jobs produce the
*published* artifacts, so a wrong version there ships a binary rather than merely
reddening a test.

The repo cannot install software on those machines, so instead it refuses to build
with the wrong one: `tool/build_prod_packages.sh` (the single entry point for all
five build jobs) resolves and verifies the version as described in the Flutter
toolchain pin section of AGENTS.md. A
mismatched runner now fails loudly with an actionable message instead of silently
shipping.

Whoever administers those runners must therefore keep the pinned version present,
by either:

- installing fvm and running `fvm install 3.47.1` once, so the SDK is at
  `~/fvm/versions/3.47.1/` where the script looks; or
- putting Flutter 3.47.1 itself on the runner's `PATH`.

The `ios-app-store-publish` and `macos-app-store-publish` jobs are also
self-hosted but do not need Flutter: they download an artifact built by an earlier
job and upload it.
