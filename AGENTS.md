# Repository Guidelines

`CLAUDE.md` is a symlink to this file — one set of instructions for every agent. Edit this file.

A cross-platform Flutter password manager (Android, iOS, macOS, Windows, Linux, web) storing vaults in the KeePass `.kdbx` format, with Android/Apple autofill integration and a desktop browser autofill bridge.

## Project Structure & Module Organization

Cross-feature infrastructure lives in `lib/core/`. Keep one Password Manager feature under `lib/features/password_manager/{data,domain,presentation,di}`; do not split cloud sync, autofill, or vault workflows into new top-level features without an approved spec.

Three BLoCs (`presentation/bloc/{database_selection,database_unlock,vault}`) stay thin: event/state translation only. Put atomic business actions with policy, validation, or transaction value in `domain/usecases/`; put multi-step sequencing and rollback in `presentation/coordinators/` (`database_session_coordinator.dart`, `vault_session_coordinator.dart`, and dedicated integration coordinators). Do not create one-line pass-through use cases only for symmetry. Large screens are split into `*.part.dart` files assembled by the owning screen.

Domain repository/port contracts define application-required behavior; data implements them. Data sources own direct persistence, API, plugin, or platform access. Data services own technical integration and transaction mechanics by composing those sources. Presentation never imports data implementations or provider SDK types.

DI uses `get_it`, split across `lib/core/di/core_di.dart` and `lib/features/password_manager/di/*.dart`, assembled by `lib/injection_container.dart`. `data/services/vault_kdbx_service.dart` owns semantic KDBX parsing/edits. Approved raw-byte replacement, import, and sync writers remain in data services/orchestrator paths under shared `DatabasePathMutex`, backup, and safe-writer invariants; never bypass those protections or imply every vault write routes through `VaultKdbxService`.

Cloud sync is currently hard-coded to Google Drive. [Spec 010](specs/010-multi-cloud-storage/spec.md) plans one provider-neutral storage port, a sole Google data adapter, remote identity as `(providerId, remoteFileId)`, typed safe errors, and direct DI without a registry. Do not describe that refactor as implemented until its tasks land. Its deferred provider evidence/single-file constraints remain normative outside the immediate Google-only DoD. Autofill has two live paths: Apple (`apple_autofill_v2_coordinator.dart` + `ios/CredentialProviderExtension`, `macos/CredentialProviderExtension`) and desktop browsers (`desktop_browser_autofill_*.dart` + `desktop/native_host/` + `desktop/browser_extension/`). The native messaging protocol is Dart in `tool/native_host_protocol.dart`, entry point `tool/native_host.dart`.

## Build, Test, and Development Commands

```bash
flutter run --dart-define-from-file=.env.dart.define.json   # OAuth ids required; see .env.dart.define.example.json
flutter test
flutter test test/features/password_manager/data/services/vault_kdbx_service_test.dart
flutter analyze
tool/build_prod_packages.sh --platforms android,linux        # artifacts -> dist/prod_packages/<timestamp>/
tool/build_native_host.sh                                    # compile desktop native host
desktop/browser_extension/package_extension.sh               # zip the extension
flutter pub run flutter_launcher_icons                       # after changing assets/logo/
```

### Flutter toolchain pin

Flutter is pinned to the exact version **3.47.1** (stable, revision `6655482ec0`).

**`.fvmrc` is the single source of truth.** It holds `{"flutter": "3.47.1"}` and
nothing else restates the version:

- Locally, `fvm flutter …` reads it.
- In CI, every `subosito/flutter-action@v2` step passes
  `flutter-version-file: .fvmrc` (the action parses that file's `flutter` key
  directly). Do **not** add a `flutter-version:` next to it — the action refuses
  both at once, and a second copy of the version is how local and CI drift apart.
- `tool/build_prod_packages.sh` reads it too, prepends a matching fvm SDK to
  `PATH` when it finds one, and then **fails the build** if the resolved
  `flutter --version` is not the pinned one.

Upgrading the toolchain is a dedicated change, never a side effect of something
else. Follow the `flutter-toolchain-upgrade` skill
(`.claude/skills/flutter-toolchain-upgrade/SKILL.md`), which also covers the
self-hosted release runners.

## Coding Style & Naming Conventions

`analysis_options.yaml` includes `package:flutter_lints/flutter.yaml` with no overrides. Default `dart format` (2-space indent). Files are snake_case; test files mirror the `lib/` path under `test/` with a `_test.dart` suffix.

## Testing Guidelines

`flutter_test`; tests live in `test/` mirroring `lib/`, plus `test/tool/native_host_test.dart` for the native host protocol. CI runs no tests — run `flutter test` and `flutter analyze` before pushing.

**Test order must not matter.** The `test-random-order` PR job runs the suite under a fresh `--test-randomize-ordering-seed` on every run, so a new order dependence fails immediately instead of lying dormant until something reshuffles the suite. That job excludes `test/goldens/*` for the same macOS-rasterization reason the `test` job does, so **golden ordering is only ever checked locally** — when you touch a golden or its harness, run `flutter test test/goldens --test-randomize-ordering-seed=$RANDOM` as well as the plain run. Two rules keep goldens order-independent: never resolve `di.sl<T>()` inside `dispose()` (capture the dependency in `initState` — teardown must not require the locator to still be registered), and warm any `Image.asset` a golden renders via `warmUpGoldenAssets()` in `setUpAll`, because asset decoding completes on the real event loop and `pumpAndSettle()` never advances it, so whichever test mounts the asset first would otherwise capture a blank image.

**Windows prerequisite:** three QA suites build a `/var`→`/private/var`-style path divergence with `Link.create`, which on Windows requires Developer Mode or an elevated shell. Without it these files fail locally for environment reasons only — they are not skipped, since every CI Flutter job runs on `ubuntu-latest` and macOS is unaffected. Affected files: `test/features/password_manager/data/portable_path_symlink_qa_test.dart`, `test/core/utils/mobile_file_storage_guard_qa_test.dart`, `test/core/utils/mobile_file_storage_guard_bypass_qa_test.dart`.

### Manual, on-demand QA harnesses

Three harnesses run by hand only, never in CI: the spec 008 T111 safe-writer
platform harness, the spec 011 master-password keystore probe, and the iOS
container-relocation harness. Their full procedures and invariants live in the
`manual-qa-harnesses` skill (`.claude/skills/manual-qa-harnesses/SKILL.md`) —
read it before running or changing any of them.

## Commit & Pull Request Guidelines

Conventional Commits (`feat:`, `fix:`, `chore:`, `docs:`, `refactor:`, `ci:`), scope optional (`fix(ci):`).

### Versioning and releases

`version:` in `pubspec.yaml` is `X.Y.Z+N`. Bump `X.Y.Z` by hand in the PR that warrants it; never touch `+N` outside of that bump. The one exception is the `X.Y.Z` bump itself: hand-set `+N` to a low, positive, buildable number (never `0` — `versionCode = flutter.versionCode` in `android/app/build.gradle.kts` requires a positive integer, so `+0` breaks Android builds on `main` until the next dispatch) so the counter restarts near the new version line instead of continuing the old one's count. App Store Connect and the Chrome Web Store each require every uploaded build number to be strictly higher than the last one published for that app, so this reset is only safe directly after bumping `X.Y.Z` — never on an existing version line with builds already published. Nothing ships on merge: `.github/workflows/release.yml` is `workflow_dispatch` only, with a `channel` input:

- `beta` (default) — bumps `+N`, commits `chore: bump build number to vX.Y.Z-beta+N` to the dispatched branch, tags it, and publishes a GitHub **pre-release** with every artifact.
- `release` — same, tagged `vX.Y.Z+N`, a normal GitHub release.

Both channels run the App Store Connect (TestFlight) and Chrome Web Store publish jobs — there is no separate staged/beta track on those stores, so a beta dispatch reaches their users too. Only the GitHub release's pre-release flag and the tag suffix differ.

The `-beta` suffix lives in the tag only; `pubspec.yaml` stays numeric because `CFBundleShortVersionString` rejects pre-release suffixes. Run it with `gh workflow run release.yml -f channel=beta` (or `release`) from `main` — or from `release/X.Y.x` for a maintenance release, since the workflow bumps and tags whichever branch it is dispatched on (see **Branch model** below).

### Branch model

`main` is the trunk and the default base for every branch: features, fixes and
spec work all target it, and its `version:` is the line that ships next. Beta is
a **channel, not a branch** — `release.yml` takes it as a dispatch input, so a
beta needs no base branch of its own; what a beta changes is the tag suffix and
the GitHub pre-release flag, not where the code lives.

A `release/X.Y.x` branch exists for exactly one situation: a fix has to ship on a
version line that is already published while `main` has moved past it. Do not
create one preemptively — a line with nothing to fix does not need a branch.

When that situation arrives, follow the `maintenance-release` skill
(`.claude/skills/maintenance-release/SKILL.md`). The rules that always hold:
branch `release/X.Y.x` from the released tag, never from `main`; open the hotfix
PR into `release/X.Y.x`, never into `main`; port the fix to `main` by cherry-pick
in its own PR; never merge `release/X.Y.x` into `main`.

## Agent skills

### Issue tracker

Ordinary requests use GitHub Issues; roadmap specs remain repository-authored and are mirrored to GitHub Project #2. See `docs/agents/issue-tracker.md`.

### Triage labels

Ordinary issues use the canonical `needs-triage`, `needs-info`, `ready-for-agent`, `ready-for-human`, and `wontfix` states. Generated `spec` issues are excluded. See `docs/agents/triage-labels.md`.

### Domain docs

Use the single-context domain documentation layout. See `docs/agents/domain.md`.

## Agent Instructions

Per `.github/copilot-instructions.md`: if `graphify-out/GRAPH_REPORT.md` exists, read it before answering structural questions about the repo.

## Spec Task Tracking

When you finish work that completes a task in a `specs/NNN-*/tasks.md` file, tick that task's box (`- [ ]` → `- [x]`) in the same change that lands the work. This is not bookkeeping: `tasks.md` is the sole source of completed roadmap work (Projects v2 #2), and `.github/workflows/spec-project-sync.yml` derives each spec's issue body and Status from those boxes on every push to `main`. An untouched box means the board reports the work as not done. Open PRs touching a spec are detected separately and make it `In Progress`; their unmerged boxes never count as completed.

Tick a box only when that task's own acceptance criteria are met and its tests pass. Never edit the generated issue body or move a card by hand — the next sync overwrites both. To resync without a push: `PROJECT_NUMBER=2 tool/sync_spec_project.sh`.

The same duty covers every other spec edit, not just ticking boxes: adding or removing a spec, renaming one, adding, deleting, reordering or rewording tasks. The board must end up consistent with `specs/` in the same change, so keep the shapes the sync depends on:

- `specs/NNN-slug/spec.md` — first line is `# <id> — <Title>`; the id (`001`, `007A`) is the issue's identity. Changing the id orphans the existing issue and creates a second one; change the title freely, never the id.
- `tasks.md` — task lines start at column 0 as `- [ ]` / `- [x]`; continuation lines are indented. Anything else is invisible to the sync.
- A spec with no `tasks.md` shows as `Todo` with an explanatory body — expected for drafts.

After a spec change, run the script (`PROJECT_NUMBER=2 tool/sync_spec_project.sh`) or the `Spec project sync` workflow via `workflow_dispatch`, and report the resulting board state. Do not leave `specs/` and the board disagreeing.

## Agent Branch Workflow

- Before changing files for an isolated development task, create a dedicated branch from `origin/main`, unless the user names another base.
- Use branch names `feat/<slug>`, `fix/<slug>`, `refactor/<slug>`, or `chore/<slug>`.
- A fix for an already-published version line uses `hotfix/<X.Y.Z>` cut from `release/X.Y.x`, not from `origin/main`. See the `maintenance-release` skill for the whole sequence, including the mandatory port back to `main`.
- If the shared worktree contains unrelated changes, do not switch branches. Create a separate Git worktree for the task instead.
- Do not reuse or modify another agent's branch or worktree.
- Do not push, merge, rebase, delete branches, open pull requests, or commit unless the user explicitly requests it.
- Before finishing, run relevant tests and report the branch name, worktree path when applicable, and verification performed.

## Agent Memory

- Update this file only when a repeated practice becomes a stable repository convention.
- Do not persist passwords, tokens, personal data, private keys, or other secrets in agent memory.

## Approach

- Read existing files before writing. Don't re-read unless changed.
- Thorough in reasoning, concise in output.
- Skip files over 100KB unless required.
- No sycophantic openers or closing fluff.
- In agent responses, avoid emojis and em-dashes.
- Do not guess APIs, versions, flags, commit SHAs, or package names. Verify by reading code or docs before asserting.
