# 017 — Tasks

Ordered work for [spec.md](spec.md), against [plan.md](plan.md).

Owners name the agent best suited to the task; a human may take any of them.
Each task states the files it touches, what "done" means, and how that is
checked. Tick a box only when its own acceptance holds and its tests pass.

---

## Phase 1 — Foundational (blocks every story)

- [x] **T101** Model the revision — owner: `senior-flutter-dev`
  Files: `lib/features/password_manager/domain/models/vault_entry_revision.dart` (new).
  Acceptance: `VaultEntryRevision`, `VaultEntryRevisionSummary` and
  `VaultHistoryRetention` per `data-model.md`. `password`, `notes` and `otpUri`
  are redacted in `props` and `toString` exactly as `VaultEntry` redacts them
  (Constitution I).
  Verify: unit test asserts a revision holding `'hunter2'` never renders it in
  `props` or `toString`, and that `otpUri` reports presence only.

- [x] **T102** [P] Compute what changed between revisions — owner: `senior-flutter-dev`
  Files: `lib/features/password_manager/domain/models/vault_entry_revision.dart`.
  Acceptance: a pure function producing `changedFields` for a revision against
  the one that replaced it (the next newer revision, or the current entry for the
  newest). It compares secret values but emits only field names.
  Verify: unit tests — a title-only edit reports `title` and not `password`; an
  identical password across two revisions is not reported as changed; the newest
  revision is compared against the current entry.

- [x] **T103** Read history from the file — owner: `senior-flutter-dev`
  Files: `lib/features/password_manager/data/services/vault_kdbx_service.dart`,
  `test/features/password_manager/data/services/vault_kdbx_service_test.dart`.
  Acceptance: one `loadEntryHistory` returning revisions **and** retention limits
  from a single open under one lock, newest first (FR-001), per
  `contracts/vault_kdbx_service_history.md`. Newest first; an entry with no
  history returns an empty list, not an error.
  Verify: service tests against a real temporary `.kdbx` — three edits produce
  three revisions in the right order; an untouched entry returns empty; the
  retention values match `meta.historyMaxItems` / `historyMaxSize`.

---

## Phase 2 — US1: see what an entry used to hold (P1) 🎯 MVP

**Independent test**: quickstart.md section A.

- [x] **T201** [US1] Carry history in the vault state — owner: `senior-flutter-dev`
  Files: `lib/features/password_manager/presentation/bloc/vault/{vault_event,vault_state,vault_bloc}.dart`.
  Acceptance: a `LoadEntryHistory` event and the resulting state, loaded on
  demand and cleared when the entry screen closes (FR-015, D6). No new BLoC
  (Constitution II). The state's `toString` reports a revision count, never a
  revision.
  Verify: bloc test — loading populates, closing clears, and `toString` holds no
  secret.

- [x] **T202** [US1] The history view — owner: `senior-flutter-dev`
  Files: `lib/features/password_manager/presentation/screens/vault/vault_entry_history.part.dart` (new),
  `lib/features/password_manager/presentation/screens/vault_screen.dart`,
  `lib/features/password_manager/presentation/screens/vault/vault_entry_detail.part.dart`.
  Acceptance: revisions newest first (FR-001), each dated and labelled with what
  changed (FR-002);
  an empty state that says no previous versions exist (FR-013); the effective
  retention limit stated (FR-012); reached from the entry the user is already
  looking at. Every colour, type size, radius and duration from a token
  (Constitution III). Rows ≥ 44 dp, 2 px focus ring, "password changed" carried
  by a label and never by colour alone (Constitution V).
  Verify: widget tests for the three states; quickstart A steps 1, 3 and 4 —
  together these are the first half of SC-001, seeing the previous password
  without leaving Custode.

- [x] **T203** [US1] Reveal a revision through the existing gate — owner: `senior-flutter-dev`
  Files: `lib/features/password_manager/presentation/screens/vault/vault_entry_history.part.dart`.
  Acceptance: masked by default; revealing uses the same `RevealController` and
  `_showBiometricRevealGate` path as the current password, including the
  auto-hide timer (FR-003, D3). No second authentication concept is introduced.
  Verify: widget test — a masked revision renders none of the secret's
  characters; with biometric protection enabled the gate is shown before the
  reveal; quickstart A step 2.

---

## Phase 3 — US2: recover a previous password (P2)

**Independent test**: quickstart.md section B.

- [x] **T301** [US2] Restore a revision in the file — owner: `senior-flutter-dev`
  Files: `lib/features/password_manager/data/services/vault_kdbx_service.dart`,
  `test/features/password_manager/data/services/vault_kdbx_service_test.dart`.
  Acceptance: `restoreEntryRevision` writes the revision's title, username,
  password, URL, notes and custom fields with the same setters `updateEntry`
  uses, so the pre-restore state is appended to history by the writer (D5). The
  OTP secret rides along in the custom fields, because that is where it lives.
  **Attachments are not touched** (FR-006a) — `updateEntry`'s setters do not
  cover them, and pretending otherwise would lose a file silently. Throws when
  no revision carries that timestamp, rather than restoring a neighbour.
  Verify: service tests — the entry holds the restored values **and** the
  pre-restore password is now in history, since the reversibility in FR-007 is a
  property of the dependency and must be asserted rather than assumed; a
  revision whose custom fields held an `otpauth://` value restores that OTP; an
  entry's attachments are unchanged by a restore; an unknown timestamp throws.
  The write goes through the write-tracking harness already used in this test
  file, which is what checks FR-011.

- [x] **T302** [US2] Sequence the restore — owner: `senior-flutter-dev`
  Files: `lib/features/password_manager/presentation/coordinators/entry_history_coordinator.dart` (new),
  `lib/features/password_manager/di/password_manager_presentation_di.dart`.
  Acceptance: `EntryHistoryCoordinator.restore` per its contract — refuses on a
  locked session and writes nothing, otherwise restores and reports the outcome.
  Registered in DI.
  Verify: coordinator tests with fakes — locked session writes nothing and
  reports `vaultLocked`; a successful restore reports `done`; a failing write
  reports `failed`.

- [x] **T303** [P] [US2] Copy a revision's password — owner: `senior-flutter-dev`
  Files: `lib/features/password_manager/presentation/screens/vault/vault_entry_history.part.dart`.
  Acceptance: copying goes through the existing `ClipboardGuard` with the same
  toast and clearing behaviour as copying the current password (FR-005).
  Verify: widget test asserts the guard is used; quickstart B step 1.

- [x] **T304** [US2] Confirm before replacing — owner: `senior-flutter-dev`
  Files: `lib/features/password_manager/presentation/screens/vault/vault_entry_history.part.dart`,
  `lib/features/password_manager/presentation/bloc/vault/vault_bloc.dart`.
  Acceptance: a restore is confirmed first, and the confirmation names what is
  being replaced (FR-008). When the revision's attachment names differ from the
  entry's, the confirmation also says attachments are not restored (FR-006a). On
  success the vault reloads and the user is told. All strings new; no existing
  string edited (Constitution VI).
  Verify: widget test — dismissing writes nothing; confirming calls the
  coordinator once. Quickstart B steps 2 and 3, which complete SC-001: the user
  both sees and recovers the previous password inside Custode.

---

## Phase 4 — US3: stop keeping what should not be kept (P3)

**Independent test**: quickstart.md section C.

- [x] **T401** [US3] Delete and clear in the file — owner: `senior-flutter-dev`
  Files: `lib/features/password_manager/data/services/vault_kdbx_service.dart`,
  `test/features/password_manager/data/services/vault_kdbx_service_test.dart`.
  Acceptance: `deleteEntryRevision` removes exactly the named revision and leaves
  the others in order (FR-009); `clearEntryHistory` empties the list (FR-010).
  Neither writes a backup — that is the coordinator's, so the backup and the
  warning stay together.
  Verify: service tests — deleting the middle of three leaves the outer two in
  order; clearing leaves an empty list; both survive a reopen of the file; both
  write through the write-tracking harness (FR-011); and after either, an
  ordinary edit still records exactly one new revision (FR-014).

- [x] **T402** [US3] Back up before destroying — owner: `senior-flutter-dev`
  Files: `lib/features/password_manager/presentation/coordinators/entry_history_coordinator.dart`.
  Acceptance: `clearHistory` writes a dated backup **before** the file changes,
  reusing the existing dated-backup mechanism (FR-010, Constitution VII). A write
  that fails after the backup exists leaves it in place and says so.
  Verify: coordinator test asserts the backup exists before the service is
  called, and that a failing write still reports the backup's path.

- [x] **T403** [US3] Ask before destroying — owner: `senior-flutter-dev`
  Files: `lib/features/password_manager/presentation/screens/vault/vault_entry_history.part.dart`.
  Acceptance: deleting one revision is confirmed (FR-009); clearing is confirmed
  with a warning that names what is destroyed and says a backup will be written
  (FR-010). Every path that destroys history warns first (SC-005). Colour is not
  the only signal that these are destructive.
  Verify: widget tests for both confirmations; quickstart C steps 1–3.

---

## Phase 5 — Verification gate

- [x] **T501** [P] Goldens — owner: `senior-flutter-dev`
  Files: `test/goldens/vault_entry_history_*_test.dart` (new).
  Acceptance: the inventory in `plan.md` — list at 390×844 and 1024×768 in light
  and dark, the empty state, and a revealed revision using a fixed fake secret
  (Constitution IV). `warmUpGoldenAssets()` in `setUpAll`; no `di.sl<T>()` in
  `dispose()`.
  Verify: `flutter test test/goldens --test-randomize-ordering-seed=$RANDOM`
  passes, since golden order-independence is only ever checked locally.

- [x] **T502** [P] Contrast and target assertions — owner: `senior-tester`
  Files: `test/features/password_manager/presentation/screens/vault_entry_history_a11y_test.dart` (new).
  Acceptance: every text/background pairing in the view is ≥ 4.5:1 in light and
  dark, including the smallest secondary text; rows are ≥ 44 dp; every focusable
  has a 2 px focus ring (Constitution V).
  Verify: the test fails when a token is changed to a failing value.

- [ ] **T503** Redaction sweep — owner: `senior-tester`
  Files: none.
  Acceptance: after a session exercising every flow, no historical or current
  password appears in the run's output, in any `toString`, or in a crash report
  (FR-004, SC-003).
  Verify: quickstart section E, with the output recorded in the PR.

- [ ] **T504** Interoperability and long history — owner: `senior-tester`
  Files: none.
  Acceptance: after a restore, a delete and a clear, the `.kdbx` opens in another
  KeePass client and shows the same revisions (SC-004); the backup from a clear
  still holds them; an entry with 200 revisions opens no slower than one with
  none (SC-002). Two declared edge cases are checked here because only a real
  file can show them: an entry restored from the recycle bin brings its history
  back, and its time in the bin is not presented as a password change; and a
  master-password change leaves history intact without making every entry look
  freshly changed.
  Verify: quickstart sections C and D.

- [x] **T505** Local gate — owner: `senior-flutter-dev`
  Files: none.
  Acceptance: `dart format --set-exit-if-changed lib test tool`,
  `flutter analyze` and the full `flutter test` all clean and green
  (Constitution IX). `pubspec.yaml: version:` untouched.
  Verify: command output in the PR body, with before/after test counts.

---

## Dependencies

- Phase 1 blocks everything.
- Phase 2 (US1) is the MVP and stands alone: read-only history is shippable.
- Phase 3 (US2) needs Phase 1's service reads and Phase 2's view to act from.
- Phase 4 (US3) needs the same, and is independent of Phase 3.
- Phase 5 runs last, on whatever shipped.

Parallel opportunities: T102 alongside T103; T303 alongside T301/T302; T501 and
T502 alongside each other once the view exists.

## Deferred, not scheduled

- Editing the vault's retention limits (D7).
- A history view for groups, or a vault-wide "everything that changed" timeline.
- Restoring a single field from a revision rather than the whole revision.
- Changing what the writer records in history (FR-014 forbids it here).
