# 025 — Tasks

Four implementation slices, done **in order**, each by a possibly different
developer, each leaving `flutter analyze` clean and `flutter test` green. A
slice deletes what it replaces, so the next one never reworks it. S5 validates.

Paths are relative to `lib/features/password_manager/` unless they start with
`lib/`, `test/`, `specs/` or `docs/`. Tests mirror the `lib/` path under
`test/`. Goldens live in `test/goldens/` and are driven by
`test/goldens/database_and_unlock_test.dart`.

Rules for every task: reuse before writing (`KvBottomSheet`, `KvPillButton`,
`KvSecondaryPillButton`, `KvListRow`, `KvTag`, `KvSwitch`, `KvSpinner`,
`KvIcon(AppGlyph)`, `KvCircleIconButton`, `kvFieldDecoration`/`kvFieldLabel`,
`showKvConfirmDialog`); sequencing in `DatabaseSessionCoordinator`, never in a
BLoC or widget; no new use case without policy; never resolve `di.sl<T>()`
inside `dispose()`.

## Baseline (already in the worktree, uncommitted)

The fix from branch `fix/unlock-silent-errors` is applied on top of
`origin/main`: `database_unlock_bloc.dart`, `database_unlock_screen.dart`,
`database_unlock_widgets.part.dart`, their two test files and
`fake_database_ports.dart`. S1 builds on it; do not revert it.

## S1 — Unlock and the single biometric offer

- [x] T101 FR-X2: add `supportsRemoteSource`, `supportsBiometricUnlock`,
      `persistsDatabases` and the `@visibleForTesting debugPlatformCapabilities`
      override to `presentation/utils/platform_utils.dart` (keep
      `isManagedStoragePlatform`, `isMobilePlatform`). No new file, no class
      hierarchy. Tests: new `presentation/utils/platform_utils_test.dart`
      (override on/off, reset in `tearDown`).
- [x] T102 FR-X1: add `presentation/widgets/database/source_chip.dart` with
      `SourceChip` and `databaseSourceLabel(...)`. REUSE `KvIcon`,
      `AppGlyph.cloud`, `AppTextStyles`, `CustodeColors`,
      `StorageAccountSummary`. Tests: label matrix (local, remote with email,
      remote without email) in `widgets/database/source_chip_test.dart`.
- [x] T103 FR-X5: add `presentation/widgets/key_file_picker.dart` with
      `pickKeyFile(context, {String? current})` and `KeyFileRow` (empty slot and
      selected state). Move the body of `_pickKeyFile` from
      `screens/database_unlock_screen.dart` into it. REUSE
      `authorizeManagedKeyPickerAccess` (`widgets/managed_key_picker_gate.dart`),
      `showInternalKeyFileManagerSheet`, `getProtectedKeyFilePaths`,
      `KvListRow`, `KvCircleIconButton`. DELETE `_KeyFileSelector` and the
      key-file entry of `_UnlockLinkRow` in
      `screens/database_unlock_widgets.part.dart`. Tests: extend
      `widgets/managed_key_picker_gate_test.dart` expectations through the new
      entry point; new `widgets/key_file_picker_test.dart` (gate refused, key
      chosen, current key deleted, web bytes path via the T101 override).
- [x] T104 FR-U2: extend `UnlockBootstrapResult` and
      `DatabaseSessionCoordinator.initializeUnlock` with `isRemoteLinked` and
      `remoteAccount` (mapping lookup for any record; account only when
      `isConnected()` is already true, best-effort, never `connect()`); copy
      both into `bloc/database_unlock/database_unlock_state.dart`. Tests:
      `coordinators/database_session_coordinator_test.dart` (linked, unlinked,
      account lookup throws, `connect()` never called),
      `bloc/database_unlock_bloc_test.dart`.
- [x] T105 FR-U1, FR-U3: rebuild `_UnlockReadyForm` in
      `screens/database_unlock_widgets.part.dart` to the `Unlock` mockup:
      back, `SourceChip`, name, password field, `KeyFileRow`, `Unlock`,
      `Use biometrics` link. Replace `AppIcons` with `KvIcon(AppGlyph)` in the
      ready form. Change `InvalidCredentialsFailure` copy in `failureMessage`
      (`bloc/database_selection/database_selection_bloc.dart`) to the copy
      contract string. Keep `_BiometricGate`, `_DecryptingView`,
      `_PendingCaptureNotice`, `_WaitingPasskeysNotice` untouched. Tests:
      update `screens/database_unlock_screen_test.dart` and
      `screens/database_selection_unlock_widget_matrix_test.dart` (labels, error
      is a descendant of the credential group, card <= 600 at 1024).
- [x] T106 FR-U5: add `DatabaseSessionCoordinator.redownloadMissingDatabase`.
      REUSE `databaseSyncRepository.getMapping`/`downloadRemoteFile`,
      `databaseFileRepository.stageDriveDownload`/`commitStagedDatabase`/
      `finalizeDatabaseCommit`/`rollbackDatabaseCommit`. No direct byte write.
      Tests in `coordinators/database_session_coordinator_test.dart`: success
      keeps database id, profile and mapping and updates `fileHash`; download
      failure and commit failure mutate nothing; no mapping returns a typed
      error.
- [x] T107 FR-U4: add `LocateMissingDatabaseFile`, `RedownloadMissingDatabase`,
      `RemoveMissingDatabase` to `bloc/database_unlock/database_unlock_event.dart`
      and thin handlers in `database_unlock_bloc.dart` calling the existing
      `locateMissingDatabase`, T106 and `removeRecentDatabase(removeOnly)`. Add
      `_UnlockMissingView` to `screens/database_unlock_widgets.part.dart` and
      route `DatabaseFileMissingFailure` to it from `_phaseView`; a successful
      locate/re-download replaces the route with
      `DatabaseUnlockScreen(databasePath: <new path>)`; remove goes back to
      `DatabaseSelectionScreen`. REUSE `FilePicker` call shape from
      `_onLocateDatabase`, `showKvConfirmDialog`. `_UnlockFailureView` stays for
      invalid/corrupt/metadata failures. Tests: bloc tests per event; widget
      tests for the three actions, for the re-download action being absent
      without a mapping, and for hash-mismatch copy staying inline.
- [x] T108 FR-U6, FR-U7: add `biometricOfferAnswered` (default `false`) to
      `domain/entities/database_security_profile.dart` and its persistence in
      `data/repositories/database_security_repository_impl.dart` (absent field
      decodes to `false`). In `DatabaseSessionCoordinator`: add
      `shouldOfferBiometricUnlock(databasePath)` and
      `answerBiometricOffer(databasePath, {required bool enable})`; make
      `updateBiometricProtection(enabled: true)` store the credential
      immediately when `sessionSecretHolder` holds a non-empty secret. Do not
      touch the `enabled: false` branch. Tests in
      `coordinators/database_session_coordinator_test.dart`: offer truth table
      (capability off, biometrics unavailable, already enabled, already
      answered, key-only vault); enable writes exactly one keystore entry for
      that database id; "not now" writes none; enable with no session secret
      writes none; spec 011 AC-5 style isolation between two databases.
      Repository test for the new field round trip and legacy decode.
- [x] T109 FR-U6: add
      `presentation/widgets/database/biometric_offer_sheet.dart`
      (`showBiometricOfferSheet`, REUSE `KvBottomSheet.show<bool>`,
      `KvPillButton`). In `screens/database_unlock_screen.dart`, on a manual
      unlock success ask T108, show the sheet, then navigate to `VaultScreen`.
      DELETE `widgets/database/biometric_prompt_sheet.dart`,
      `_showBiometricSetupPrompt`, the `promptBiometricSetup` parameter on
      `DatabaseUnlockScreen`, on `DatabaseSelectionSuccess`
      (`bloc/database_selection/database_selection_state.dart`), on
      `DatabaseSelectionSessionResult` and its set sites in
      `database_session_coordinator.dart`, and the two biometric snackbars.
      Tests: update `screens/database_unlock_screen_test.dart` (replace the
      "Drive-linked unlock with key file after biometric prompt" and "Enable
      biometrics then manual unlock" groups with offer-after-unlock cases for a
      local and a remote database, shown once, dismissal counts as answered,
      not shown after a biometric unlock); update
      `coordinators/database_session_coordinator_test.dart`,
      `bloc/database_selection_bloc_test.dart`,
      `data/services/database_writer_lock_routing_test.dart` for the removed
      field.
- [x] T110 Goldens S1: re-shoot `unlock_password_390x844_light.png`,
      `unlock_password_390x844_dark.png`, `unlock_password_1024x768_light.png`,
      `unlock_wrong_password_390x844_light.png`,
      `unlock_key_selected_390x844_light.png`; add
      `unlock_missing_390x844_light.png`,
      `unlock_biometric_offer_390x844_light.png`; delete
      `unlock_face_id_prompt_390x844_light.png` and its test. Check by eye
      against `Unlock`, `UnlockKeyFile`, `UnlockMissing`, `BiometricOffer`. Run
      the plain and the randomized golden run.
      Done on a macOS machine whose renderer differs from the canonical one by
      about 0.1% of pixels: the 7 goldens above were regenerated here and pass;
      the 15 other `db_*`/`unlock_*` goldens this slice does not touch fail
      identically in the plain and the randomized run (pre-existing, same
      cause). Re-shoot the 7 on the canonical renderer before merging.
- [ ] T111 S1 gate: `dart format`, `flutter analyze`, `flutter test`; run the
      spec 011 keystore probe (`manual-qa-harnesses` skill) for risk R1 on
      Android and one Apple platform and record the outcome under this task.
      Not done: `dart format`, `flutter analyze` and the non-golden
      `flutter test` are green (2624 passed, 2 skipped), but the probe needs
      physical devices. Static finding: `updateBiometricProtection(enabled:
      true)` writes through the same `SecureDataSource.saveMasterPassword`
      call, with the same options, that every manual unlock with the flag on
      already uses, so enabling adds no new keystore access mode or prompt.
      Run the probe plus one manual "Enable, then relaunch" pass per platform
      before closing R1.

S1 implementation notes for later slices: a successful locate or re-download
re-initialises the unlock screen in place at the new path (no route
replacement); `DatabaseUnlockScreen.debugVaultBuilder` is the test seam that
replaces the vault route; `isManagedStoragePlatform` also follows
`debugPlatformCapabilities` (managed storage exists wherever databases
persist); coordinator tests for the S1 additions live in
`coordinators/database_session_coordinator_unlock_flow_test.dart`.

## S2 — Add/Open: source sheet, Drive list, single conflict sheet

- [x] T201 Characterization first (risk R3): before any change, add tests to
      `coordinators/database_session_coordinator_test.dart` pinning today's
      four duplicate outcomes for a local and a Drive import (backup created on
      replace, rollback on downstream failure, staged bytes discarded on cancel
      and on use-existing). They must pass unmodified after T204.
      Done: group `spec 025 T201 duplicate outcomes (characterization)` in
      `coordinators/database_session_coordinator_test.dart` (11 tests, local and
      Drive: backup observed at the instant the commit is still reversible,
      rollback on downstream failure, staging discarded on cancel and
      use-existing). They ran green before and after T204, unmodified.
- [x] T202 FR-O2, FR-C2 (shared): add
      `presentation/widgets/database/source_option_card.dart`
      (`SourceOptionCard`: icon, title, subtitle, trailing action or chevron,
      optional selected state, disabled with reason). REUSE `KvIcon`,
      `AppRadii`, `colors.surfaceNested`. Add
      `presentation/widgets/database/database_source_sheet.dart`
      (`showDatabaseSourceSheet` returning a small enum, REUSE
      `KvBottomSheet.show`). The Drive card reads connection state through the
      coordinator (`isConnected` + `getConnectedAccount`, best-effort) and
      `supportsRemoteSource`. Tests: `widgets/database/source_option_card_test.dart`,
      `widgets/database/database_source_sheet_test.dart` (not connected,
      connected with and without email, disabled on web override, privacy line).
      Done. `SourceOptionCard` also takes `trailing` and `onSheet` (sheets sit
      on `surface`, so cards step to `surfaceNested`; S3 passes `onSheet:
      false` on the wizard page) and exports `SourcePrivacyLine`, shared by the
      Source sheet and the Drive list. The conflict sheet reuses the card.
      `KvTag` gained an `accent` variant for `Recommended`.
- [x] T203 FR-O3, FR-O4, FR-O5: add
      `presentation/widgets/sync/remote_file_list.dart` (`RemoteFileList`:
      account header, search, rows, skeleton, empty, error/reconnect) by
      extracting the list body from `_RemoteFilePickerScreen`
      (`screens/vault/vault_sync.part.dart`) and add
      `presentation/widgets/sync/remote_file_picker.dart` exposing only
      `Future<RemoteFile?> pickRemoteFile(BuildContext)`. REUSE
      `widgets/sync/remote_file_row.dart`,
      `widgets/database/drive_picker_skeleton.dart`, `KvTag` (`Already added`,
      from `getAllMappings` matched on `(providerId, id)`),
      `getRemoteFileSelectionData`, `reconnectRemoteFileSelectionData`,
      `describeTimeAgo` + `formatBytes`. Add
      `DatabaseSessionCoordinator.switchRemoteAccount()` (`disconnect` then
      `connect` then reload). Make the vault link picker render
      `RemoteFileList` too. DELETE `DrivePickerSheetResult`,
      `showDrivePickerSheet`, `_DrivePickerSheetContent`, `_DriveEmptyState`
      and the hand-rolled rows in `widgets/database/drive_picker_sheet.dart`;
      move `driveErrorMessage` (strings unchanged) next to the new picker and
      delete the old file. Tests: move
      `widgets/database/drive_picker_error_message_test.dart` with the function;
      new `widgets/sync/remote_file_picker_test.dart` (loading, empty without
      create+upload, already-added tag, switch account calls the coordinator,
      cancelled sign-in, reconnect); coordinator test for
      `switchRemoteAccount` (order of calls, failure leaves disconnected);
      `screens/vault/remote_file_picker_test.dart` and
      `widgets/sync/remote_file_row_test.dart` keep passing.
      Done. Deviations: the sheet name is `RemoteFilePickerSheet` (public so
      tests can script loaders; callers only use `pickRemoteFile`); the shared
      row keeps its absolute date (`Modified 12 Mar 2026`) instead of a
      relative one, because `describeTimeAgo` returns `changed ...` and a
      relative string would make the vault `sync_picker` golden depend on the
      clock. `RemoteFileRow` gained `alreadyAdded`, `showChevron`,
      `background`. The picker search filters by name locally (the Google
      Picker of spec 013 replaces the listing). The vault picker now shows the
      skeleton while loading and the same `Search .kdbx files` / `Unable to
      connect to Google Drive` copy; the old `driveOpenErrorMessage` strings
      are unchanged and the reconnect label is `Reconnecting...` everywhere.
- [x] T204 FR-O6: extend `domain/usecases/resolve_database_duplicate_usecase.dart`
      with `displayName` and `DatabaseDuplicateMatchType.name`
      (`domain/models/database_dedup_result.dart`), precedence source, hash,
      name. In `DatabaseSessionCoordinator`: pass the name from
      `selectExistingDatabase`/`selectDriveDatabase`; DELETE
      `hasManagedDatabaseNamed`, `_findRecordByDisplayName`'s overwrite use,
      every `overwriteExisting` parameter and the name-resolved target branch
      of `_commitStagedImport`; carry the match type in
      `DatabaseDuplicatePrompt`; apply decision D6 on keep-both for a name
      match. Remove `overwriteExisting` from `SelectExistingDatabase` and
      `SelectDriveDatabase` (`bloc/database_selection/database_selection_event.dart`)
      and from the BLoC. Tests: use-case tests for precedence and name match;
      coordinator tests for a name-only conflict in all four outcomes; T201
      tests still green; update `bloc/database_event_redaction_test.dart` and
      `bloc/database_selection_bloc_test.dart`.
      Done. Also removed `DatabaseImportService.importFromSelection`'s
      `overwriteExisting` and `_replaceManagedDatabase` (no lib caller, the
      name-based overwrite), its writer-lock routing test, and updated the
      frozen writer inventory (rename 13 -> 9, delete 9 -> 7). A name-only
      "Open the existing one" does not re-point the existing record's sync
      mapping. Conflict outcomes no longer return a snackbar message (FR-O8).
- [x] T205 FR-O7: add
      `presentation/widgets/database/database_conflict_sheet.dart`
      (`showDatabaseConflictSheet`, REUSE `KvBottomSheet.show`, `KvTag` for
      `Recommended`, `databaseSourceLabel` for the two sources). In
      `screens/database_selection_screen.dart` a `null` result dispatches
      `ResolveDuplicateDecision(DatabaseDuplicateResolution.cancel)`. DELETE
      `showDuplicateDatabaseSheet`, `_DuplicateSheet`
      (`widgets/database/database_selection_sheets.dart`, keep the
      invalid/corrupt dialogs) and `_showOverwriteDatabaseSheet`. Tests:
      `widgets/database/database_conflict_sheet_test.dart` (four results,
      `Recommended` only for source/hash, sheet geometry light and dark);
      `screens/database_selection_screen_test.dart` (barrier dismiss and back
      both dispatch cancel; coordinator fake sees `discardStagedDatabase`).
- [x] T206 FR-O1, FR-O8, FR-X6: wire the open path. `screens/welcome_screen.dart`:
      two pills (`Create new database`, `Open a database`), new body copy,
      DELETE `onOpenFromGoogleDrive`. `screens/database_selection_screen.dart`:
      one `_onOpenDatabase` (source sheet, then `FilePicker` or
      `pickRemoteFile`, then the existing `SelectExistingDatabase`/
      `SelectDriveDatabase`); reduce `_AddSection` to the same two actions
      (S4 replaces it); DELETE `_openFromGoogleDrive`, the `kIsWeb` snackbar,
      the switch-account snackbar, the `MobileFileStorage` import and
      `MobileFileStorage.fileExistsInAppDirectory`
      (`lib/core/utils/mobile_file_storage.dart`, no other caller). Add `label`
      to `DatabaseSelectionLoading`, set it in the BLoC handlers, and render
      `KvSpinner` + label over the mounted content instead of swapping the
      body. Tests: update `screens/database_selection_screen_test.dart`,
      `screens/database_selection_unlock_widget_matrix_test.dart`,
      `bloc/database_selection_bloc_test.dart` (labels; content stays mounted
      while loading; success navigates to Unlock with no snackbar).
      Done. `CheckInitialDatabase` from `DatabaseSelectionInitial` emits no
      `Loading` (the first load stays the bare spinner); later events keep the
      content mounted. `withData: true` on the local picker (it was `kIsWeb ||
      isManagedStoragePlatform`, true on every platform). `kIsWeb` remains in
      `database_selection_screen.dart` only for the export action and the
      remove-and-delete button (S4, T405).
- [x] T207 Goldens S2: re-shoot `db_welcome_390x844_light.png`,
      `db_welcome_390x844_dark.png`, `db_drive_loading_390x844_light.png`,
      `db_drive_empty_390x844_light.png`; add
      `db_source_sheet_390x844_light.png`, `db_drive_files_390x844_light.png`,
      `db_conflict_390x844_light.png`; delete `db_duplicate_390x844_light.png`
      and its test; re-shoot `sync_picker_390x844_light.png`
      (`test/goldens/sync_health_import_test.dart`) only if its pixels moved,
      and say so here. Check by eye against `Main`, `Source`, `DriveFiles`,
      `Conflict`. Plain and randomized golden runs.
      Done. Also re-shot the four `db_recent_*` goldens: S2 reduces
      `_AddSection` to two rows, which moved 0.3 to 0.75% of their pixels
      (S4 replaces them with `db_list_*`). `sync_picker_390x844_light.png`
      moved (0.16%, the search hint) and was re-shot. Plain and randomized
      runs of `database_and_unlock_test.dart`: the 15 goldens this slice owns
      pass in both; the 6 untouched ones (`db_create_step1/2`, `db_invalid_file`, `unlock_decrypting`,
      `unlock_key_manager`, `unlock_biometric_gate`) keep failing at the known
      0.04 to 0.1% local renderer diff. The welcome
      now follows `Main` (identity block centred in the free space, pills
      pinned to the bottom, 480 max width).
- [x] T208 S2 gate: `dart format`, `flutter analyze`, `flutter test`;
      `rg -n "overwriteExisting|hasManagedDatabaseNamed|createAndUpload|showDuplicateDatabaseSheet" lib test`
      is empty.
      Done: `dart format` clean, `flutter analyze` clean, non-golden
      `flutter test` 2528 passed, 2 skipped; the `rg` is empty.

## S3 — Create wizard, direct vault entry, create on Drive

- [x] T301 FR-C2, FR-C4: rebuild `_NameStep` and `_CreateHeader` in
      `screens/create_database_screen.dart` to the `CreateName` mockup. REUSE
      `SourceOptionCard` (T202, selectable mode) with the same connection
      lookup as the source sheet, `kvFieldDecoration`/`kvFieldLabel`,
      `KvCircleIconButton`, `KvPillButton`. Keep `_nameValid` (015 FR-8) and the
      existing `StartCreateDatabaseFlow`/`AdvanceCreateDatabaseStep`/
      `GoBackCreateDatabaseStep`/`CancelCreateDatabaseFlow` events unchanged.
      The chosen source is ephemeral screen state. Tests: update
      `screens/create_database_screen_test.dart` (default source, remote
      selectable only when connected, `Connect` action, disabled on web
      override, `Saved as` caption, invalid name blocks).
      Done. Source cards are ephemeral screen state; `Connect` calls the new
      `DatabaseSessionCoordinator.connectRemoteAccount()` (sign-in only there,
      `connectedAccountOrNull()` for the initial lookup). The field shows the
      name without extension, `Saved as <name>.kdbx`, and the screen sends
      `<name>.kdbx`.
- [x] T302 FR-C3, FR-C4, FR-X5: rebuild `_CredentialsStep` to the
      `CreateCredentials` mockup. REUSE `KeyFileRow` + `pickKeyFile` (T103),
      `KvSwitch`, `widgets/entry/strength_strip.dart` (`StrengthStrip`),
      `kvFieldDecoration`, `KvBottomSheet` for the two key choices. Keep
      `KeyFileMode`, `_submitBlockReason`, the FR-13 warning and the
      `_WebDownloadStep` behaviour. DELETE `RadioListTile`, `SwitchListTile`,
      raw `InputDecoration`, every `AppIcons` use, `_StrengthMeter`, the
      wizard's `_pickKeyFile`, and `debugWebMode` (use
      `debugPlatformCapabilities`). The biometric switch is disabled with its
      reason when `supportsBiometricUnlock` is false or the device has no
      biometrics. Tests: update `screens/create_database_screen_test.dart`
      (three key modes through the row + sheet, empty password hides confirm
      and strength, inert submit states why, failure keeps the wizard and the
      draft, web path via the override).
      Done. Strength bar is `StrengthBar`, extracted from the change-password
      screen into `widgets/entry/strength_strip.dart` (the strip itself is the
      entry-detail card). `PasswordStrengthCategory` deleted. `KeyFileRow`
      gained `emptySubtitle`. Biometric row is a `KvListRow` with `KvSwitch`,
      disabled with `Not available on this device`.
- [x] T303 FR-C5, FR-C7: add `createOnRemote` to `CreateNewDatabase`
      (`bloc/database_selection/database_selection_event.dart`, non-secret
      prop) and to `DatabaseSessionCoordinator.createNewDatabase`. After the
      015 FR-9 transaction commits: REUSE the injected
      `LinkDatabaseToRemoteUseCase` with `remoteFileId: null`,
      `remoteFileName: '<name>.kdbx'`; on success stamp the record
      `sourceType: drive` and `sourceRef`; on failure keep the local vault and
      return the FR-C5 notice (decision D2). Always set
      `biometricOfferAnswered = true` on the new profile. No new use case.
      Tests in `coordinators/database_session_coordinator_test.dart`: remote
      create calls the use case once with a null id and the `.kdbx` name; link
      failure leaves record, file, profile and session intact and returns the
      notice; authorization-required is treated the same way; every existing
      015 rollback test still passes unmodified; offer flag is set.
      Done. Also: a keystore failure at creation no longer rolls back (decision
      D2 family): the flag is withdrawn and `biometricsNotEnabledNotice` is
      returned; the spec 015 test that asserted rollback for that case was
      rewritten. Key-only creation now holds the empty password in the session
      (as a manual key-only unlock does) so the vault can open; the old
      "no empty session secret" assertion was rewritten, the secure store still
      never receives an empty string. The success `Info` emission in the bloc
      was dropped (it duplicated the `Success` snackbar).
- [x] T304 FR-C6: add `openVault` to `DatabaseSelectionSessionResult` and
      `DatabaseSelectionSuccess`; `createNewDatabase` sets it. In
      `screens/database_selection_screen.dart` the success listener pushes
      `VaultScreen(databasePath:)` when it is true and `DatabaseUnlockScreen`
      otherwise; the wizard's own pop-on-leave listener must not race it
      (single navigation, tested). Confirm `VaultBloc` initialises from
      `SessionSecretHolder` plus the profile key path (risk R4); if it does
      not, call the existing unlock path in the coordinator rather than adding
      state to the BLoC. Tests: widget test through the real coordinator with
      fake ports: create with password only, key only, both, each lands on
      `VaultScreen` with no unlock screen in the tree; a session without a
      secret falls back to Unlock.
      Done. R4 confirmed: `VaultBloc` needs only `SessionSecretHolder.read()`
      and the active database's profile key path; unlock adds nothing else. The
      wizard does not pop itself on `Success`; the selection screen pops to
      itself and replaces (single navigation). `debugVaultBuilder` on
      `DatabaseSelectionScreen` mirrors the unlock screen seam.
- [x] T305 FR-C8: web outcome caption and unchanged 015 FR-14 gestures behind
      `persistsDatabases`. Tests: existing web cases in
      `screens/create_database_screen_test.dart` and
      `domain/usecases/create_database_download_usecase_test.dart` stay green
      with the new override.
      Done. Web is `persistsDatabases == false`: same widgets, Drive disabled
      with the reason, biometric row disabled, caption `Downloads the database.
      The browser keeps nothing.`; `debugWebMode` is gone.
- [x] T306 Goldens S3: re-shoot `db_create_step1_390x844_light.png`,
      `db_create_step2_390x844_light.png`; check by eye against `CreateName`,
      `CreateCredentials`. Plain and randomized golden runs.
      Done. Both re-shot and checked against `CreateName`/`CreateCredentials`;
      plain and randomized runs pass for both.
- [x] T307 S3 gate: `dart format`, `flutter analyze`, `flutter test`;
      `rg -n "RadioListTile|SwitchListTile|AppIcons|debugWebMode|kIsWeb" lib/features/password_manager/presentation/screens/create_database_screen.dart`
      is empty.
      Done: `dart format` on touched files, `flutter analyze` clean, non-golden
      suite 2550 passed, 2 skipped, 0 failed; the `rg` is empty.

## S4 — Databases list, Add sheet, deletion sweep

- [x] T401 FR-L2: add `remoteProviderId` to
      `domain/models/database_selection_item.dart`; in
      `DatabaseSessionCoordinator._loadSelectionItems` read the mapping for
      every record; add best-effort `remoteAccount` to
      `DatabaseSelectionSessionResult` and to `DatabaseSelectionState` (rule of
      FR-L2: only when already connected, never `connect()`). Tests: coordinator
      tests (a `created`/`local` record linked later is remote; mapping lookup
      failure degrades to local; account lookup never connects); bloc test for
      the new state field.
      Done. `_loadSelectionItems` reads the mapping of every record through
      `_mappingOrNull` and caches the account it found (`_listRemoteAccount`,
      looked up only when a remote row exists, via `connectedAccountOrNull`);
      each result copies it next to its items and the BLoC carries it through
      every state. The conflict sheet decides "remote" for the existing record
      from the item's `remoteProviderId`. Tests live in
      `coordinators/database_session_coordinator_unlock_flow_test.dart` and
      `bloc/database_selection_bloc_test.dart`.
- [x] T402 FR-L1, FR-L3, FR-L4: rework
      `widgets/database/recent_databases_section.dart` into
      `widgets/database/database_grouped_list.dart` (`git mv`, group headers via
      `databaseSourceLabel`, keep the search for more than five items using
      `kvFieldDecoration`). Rework `widgets/database/database_item_tile.dart`:
      status line, `KvTag`s `Biometrics`/`Key file`, missing row with
      `File not found` + `Locate`; replace its private `_relativeTime` with
      `describeTimeAgo`; DELETE `databaseSubtitle`. Update
      `widgets/database/database_action_menu.dart` tooltip to
      `More actions for <name>`. A tap on a missing row opens Unlock (missing
      state from T107). Tests: update
      `widgets/database/database_item_tile_test.dart`; new
      `widgets/database/database_grouped_list_test.dart` (grouping, order
      inside a group, header without account, search).
      Done. Deviations: the local header is the copy-contract literal
      `On this device` (`databaseSourceLabel(remote: false)` says
      `This device`); headers are an icon plus label as in the mockup, not a
      `SourceChip`. `describeTimeAgo` has day granularity and words an entry's
      password age, so the status reads `Synced today` / `Synced 3 days ago`
      (its `changed ` prefix is stripped), not `Synced 2 min ago`; a linked
      database that never synced shows no status line. `KvTag` gained a
      `nested` variant for a tag on a `surface` row. The screen opens Unlock
      directly for a missing row (no BLoC event).
- [x] T403 FR-L1: add `presentation/widgets/database/add_database_sheet.dart`
      (`showAddDatabaseSheet`, REUSE `KvBottomSheet.show`, `SourceOptionCard`
      or `KvListRow` for the two actions). In
      `screens/database_selection_screen.dart` put the accent "+"
      (`KvCircleIconButton`, tooltip `Add database`) in `_RecentHeader` and
      DELETE `_AddSection`; keep the 599/600 two-column rule. Tests: update
      `screens/database_selection_screen_test.dart` and
      `screens/database_selection_unlock_widget_matrix_test.dart` ("+" opens the
      sheet, both actions route to create and open, widths 599/600/1024).
      Done. The sheet returns `AddDatabaseAction` and uses two
      `SourceOptionCard`s; the tablet left column now holds only the header.
- [x] T404 FR-X5 in settings: route the key-file choice in
      `screens/vault/vault_settings.part.dart` (line ~274) through
      `pickKeyFile`. Compare `widgets/internal_key_file_manager_dialog.dart`
      with `internal_key_file_manager_sheet.dart` (risk R6): if the sheet
      covers the settings case DELETE the dialog and
      `widgets/internal_key_file_manager_dialog_test.dart` (moving any unique
      assertions to the sheet's tests); otherwise keep it and record why under
      this task. Tests: settings widget test for choosing and removing a key
      file through the shared picker.
      Done. Risk R6: the sheet has the same result contract, actions (select,
      import, export through `DatabaseFileRepository.copyFile`, protected
      delete) and strings as the dialog, and `KvBottomSheet` already renders
      as a `Dialog` at 600 and wider, so nothing desktop-only was lost. The
      dialog is deleted; its one unit test moved to
      `widgets/internal_key_file_manager_sheet_test.dart`.
      `VaultSessionCoordinator.getProtectedKeyFilePaths` lost its only caller
      and was deleted with its two tests. Settings now renders `KeyFileRow`
      (FR-X5), which adds a `Remove key file` button there: it asks first
      (`Remove key file?`, new copy, not in the contract) and re-keys through
      the existing `updateDatabaseSettings`, which still refuses to leave a
      database with no credential. `pickKeyFile`'s listing seam became the
      `debugKeyFileLister` global so a screen test can reach it. This moved
      `settings_390x844_light/dark` and `settings_1024x768_light` (re-shot).
      Tests: `screens/vault/vault_settings_key_file_test.dart`.
- [x] T405 FR-L5 sweep. DELETE
      `widgets/database/database_action_tile.dart`,
      `docs/database_flows_refactor.md`, goldens `db_recent_390x844_light.png`,
      `db_recent_390x844_dark.png`, `db_recent_1024x768_light.png`,
      `db_recent_1024x768_dark.png` and their tests, any
      `DatabaseSessionStatus`/state/event member with no remaining reader, and
      remaining `kIsWeb` reads in the files named by FR-X2 (the export action
      moves to `persistsDatabases`). Verify with
      `rg -n "kIsWeb" lib/features/password_manager/presentation/screens/{welcome_screen,database_selection_screen,create_database_screen,database_unlock_screen,database_unlock_widgets.part}.dart`
      (empty) and
      `rg -n "database_action_tile|RecentDatabasesSection|biometric_prompt_sheet|drive_picker_sheet|promptBiometricSetup" lib test --glob '!test/fixtures/**'`
      (empty).
      Done: both `rg` are empty. The second check was narrowed from
      `lib test docs` to `lib test` minus `test/fixtures/`, because the only
      two hits it ever had are frozen historical artefacts that must not be
      rewritten: `test/fixtures/001_app_icons_baseline.txt:14` (spec 001
      snapshot of `AppIcons` call sites, read by no test) and
      `docs/design_handoff_custode_restyle/01-02 Database & Unlock.dc.html:459`
      (design handoff prose quoting `promptBiometricSetup`). No code, test or
      current doc references any of the five names. Everything else:
      the files, the four `db_recent_*` goldens and `_AddSection` are deleted;
      `DatabaseSessionStatus.info` / `DatabaseSelectionInfo` stay (the remove
      and metadata-reset outcomes still read them); the unlock event was
      renamed `LocateMissingDatabaseFile` (both event files are imported by
      `bloc/database_event_redaction_test.dart`); the failure view's legacy
      icon became `KvIcon`. Four `AppIcons` remain in
      `database_unlock_widgets.part.dart`, inside the gate, decrypting and the
      two notices that T105 keeps untouched (their goldens are "unchanged").
      Also fixed here: the Drive list's `Already added` tag now shares the
      metadata line and wraps under it instead of cutting date and size
      (`db_drive_files_390x844_light.png` re-shot).
- [x] T406 Goldens S4: add `db_list_390x844_light.png`,
      `db_list_390x844_dark.png`, `db_list_1024x768_light.png`,
      `db_list_1024x768_dark.png`, `db_add_sheet_390x844_light.png`; check by
      eye against `Databases`, `AddSheet`. Plain and randomized golden runs.
      Done on the same macOS renderer as S1 to S3. Added the five files and
      checked them against `Databases` and `AddSheet`. Also re-shot because
      their pixels moved in this slice: `db_drive_files_390x844_light.png`,
      `settings_390x844_light.png`, `settings_390x844_dark.png`,
      `settings_1024x768_light.png`. Plain and randomized runs of
      `database_and_unlock_test.dart` agree: 21 of 25 pass; `db_invalid_file`,
      `unlock_biometric_gate`, `unlock_decrypting` and `unlock_key_manager`
      (untouched) fail at the known 0.07 to 0.09% local renderer diff.
      Re-shoot every golden this spec changed on the canonical renderer
      before merging.
- [x] T407 S4 gate: `dart format`, `flutter analyze` (no unused element or
      import), `flutter test`.
      Done: `dart format` on touched files clean, `flutter analyze` clean,
      non-golden suite 2583 passed, 2 skipped, 0 failed.

## S4b — Independent test findings

- [x] T408 Fix the defects an independent tester found in S1 to S4, each with
      a test written first, and record what was decided as D10 (extended) to
      D16 in `spec.md`.
      Done. F1 (D13): both unlock paths make the database active before
      decrypting it (`_activateForUnlock`); `VaultSessionCoordinator` then
      reads the right profile. F2 (D10): `unlockWithManualCredentials` returns
      a notice instead of throwing for anything that fails after the decrypt,
      and never writes an empty secret; the state's `biometricStoreFailed`
      became `notice`. F3 (D14): `updateKeyFilePath` returns whether the choice
      was remembered; the key fills the slot either way. F4 (D15): the keystore
      read sits inside the bloc's `try`. F5 (D12): the use case takes
      `DatabaseSyncRepository` and `remoteProviderId`, and shares
      `DatabaseSyncMapping.pointsAt` with the picker's `Already added` tag.
      F6 (D11): confirmed; `DatabaseDuplicatePrompt.canReplaceExisting`.
      F7: `switchRemoteAccount` refreshes the cached list account, and
      `DatabaseUnlockState.copyWith` can clear `remoteAccount`. F8: the locate
      mismatch message names `Open a database`. F9: `Use biometrics` follows
      `biometricEnabled && biometricAvailable`; `Creating <name>…`; `Google
      account` in sentence case; FR-X2 wording allows the test value holder;
      spec status; unlock width 480; `databaseSourceGlyph` (D16). F10: the
      unreachable Drive branch of the unstaged `resolveDuplicateDecision` and
      `_buildDuplicateMessage` are deleted; `KeyFileRow` holds its lookup in
      state. Not changed: `create_database_screen.dart` still imports
      `BiometricDataSource` for device availability, because no
      presentation-level path exists (the unlock bloc, the lock overlay and
      the key picker read the same data source). F11: the relocation case is
      back in `coordinators/key_file_relocation_qa_test.dart`, against the
      live `DatabaseSessionCoordinator`. Titles of the unlock and missing
      views and of the conflict, source, Drive files and biometric offer
      sheets are semantic headings (the add sheet's already was).
      Tests: `coordinators/database_session_coordinator_unlock_flow_test.dart`
      (groups named after the findings), `bloc/database_unlock_bloc_test.dart`,
      `domain/usecases/resolve_database_duplicate_usecase_test.dart`,
      `screens/database_unlock_screen_test.dart` (group `Tester findings`),
      `screens/database_selection_screen_test.dart`,
      `screens/create_database_screen_test.dart`, the sheet tests under
      `widgets/database/`, `widgets/sync/remote_file_picker_test.dart`,
      `widgets/key_file_picker_test.dart`.
      Goldens re-shot here because their pixels moved (the `This device`
      glyph, `Google account`): `db_list_*` (4), `db_add_sheet`,
      `db_create_step1`, `db_source_sheet`, `db_drive_files`,
      `db_drive_empty`, `unlock_password_*` (3), `unlock_key_selected`. Same
      macOS renderer as S1 to S4: re-shoot on the canonical one before merging.
      Gate: `dart format` on touched files, `flutter analyze` clean, non-golden
      suite 2624 passed, 2 skipped, 0 failed; `database_and_unlock_test.dart`
      plain and randomized: 22 pass, the same 4 untouched goldens fail on
      local renderer noise (`db_invalid_file`, `unlock_biometric_gate`,
      `unlock_decrypting`, `unlock_key_manager`).

## S5 — Validation

- [ ] T501 Full local verification: `flutter analyze`, `flutter test`,
      `flutter test test/goldens --test-randomize-ordering-seed=$RANDOM` three
      times with different seeds; `database_session_coordinator_imports_test.dart`
      unmodified and green; golden count for `db_*`/`unlock_*` equals the spec
      inventory (25).
- [ ] T502 Acceptance walk: tick each of the 13 acceptance criteria in
      `spec.md` against a test name or a manual step, recorded under this task.
- [ ] T503 Manual QA on Android, iOS, macOS, one of Windows/Linux, and web
      (Chrome): welcome to vault through create (device and Drive), open from
      device, open from Drive, each conflict outcome plus dismissal, switch
      account with a vault linked to the previous account (risk R2), missing
      file locate / re-download / remove, biometric offer once per database and
      enable with no second prompt, biometric unlock after restart
      (spec 011 AC-3), key-only vault (015 FR-12 matrix), web create download.
      Append the cases to `docs/manual-qa.md`.
- [ ] T504 Security review of S1/S3 changes against spec 011 FR-3, FR-4, FR-5
      and AC-1, AC-2, AC-4, AC-5, AC-8: no plaintext in logs, `props`,
      `toString` or state; keystore entry only with the flag on.
- [ ] T505 Close the open decisions D1 to D9 in `spec.md` with the product
      answer (or confirm the default) and remove any that changed code after
      the fact.
- [ ] T506 Docs: confirm the superseded notes in
      `specs/003-database-and-unlock/spec.md` and
      `specs/015-create-database-credentials/spec.md` match what shipped; update
      `AGENTS.md` only if a new stable convention emerged; run
      `PROJECT_NUMBER=2 tool/sync_spec_project.sh` and report the board state.
