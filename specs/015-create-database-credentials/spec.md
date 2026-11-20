# 015 — Create database credentials flow

**Status**: Planned · **Kind**: UX / Security  
**Depends on**: 014 (prerequisite — it must land first)  
**Coordinates with**: 003 (creation journey), 011 (session secret and keystore)

## Summary

Rebuild the create-database wizard around one credentials step where the master
password is optional and the key file is a first-class, mutually exclusive
three-way choice. Make creation transactional: any failure leaves no artefact and
no mutated persisted state, and leaves the wizard open with its draft intact.
Define the unlock fallback matrix that follows from allowing key-file-only
vaults, including the device-authentication gate on the app's internal key-file
picker. Web becomes an explicit download-only path instead of a flow that fails
at runtime.

015 depends on 014 because the on-disk naming of the generated key file is
014 FR-3, and the transactional guarantee below must not be written twice.

## Problem and current state

Verified against `lib/features/password_manager/presentation/screens/create_database_screen.dart`
and `lib/features/password_manager/domain/usecases/create_database_usecase.dart`.

- **The key-file-only vault is not reachable linearly.** The wizard has three
  steps (`CreateDatabaseStep.nameAndStorage`, `masterPassword`, `optionalLocks`).
  Advancing out of step 2 requires a non-empty field
  (`_advance`, `create_database_screen.dart:117-129`), but every key-file control
  lives in step 3 (`_LocksStep`, `create_database_screen.dart:507`), so at step 2
  `_keyFilePath` is always null and the check collapses to "password non-empty".
- **The generate switch needs a pointless extra click.** Turning on "Generate key
  file automatically" then requires pressing "Prepare generated key file"
  (`create_database_screen.dart:563-573`). On managed storage that button opens
  no picker at all: `_pickGeneratedKeyFilePath` simply sets the literal relative
  path `'database.key'` (`create_database_screen.dart:70-74`). That relative
  value is passed on verbatim as `generatedKeyFilePath`, and a relative path
  persisted from one working directory does not resolve from another — a lockout
  on the next launch.
- **No at-least-one-factor check.** `_submit`
  (`create_database_screen.dart:143-164`) validates only that a *generated* key
  path is present when the generate switch is on. Nothing asserts that at least
  one credential exists, and step 3 can be reached with an empty password by
  selecting a key file, going back, and clearing it. The use case does not check
  either: `CreateDatabaseUseCase.call` composes
  `Credentials.composite(ProtectedValue.fromString(request.password), keyFileBytes)`
  with both empty (`create_database_usecase.dart:74-77`).
- **An invalid name only warns.** `_NameStepState._validate`
  (`create_database_screen.dart:347-356`) shows "Invalid characters in file
  name." but `_advance` gates on `fieldsNonEmpty` only, so the step still
  advances; the name is later sanitised to `_` by
  `MobileFileStorage._normalizeFileName` (`mobile_file_storage.dart:294-299`).
- **The wizard closes before creation runs.** `_submit` calls
  `Navigator.of(context).pop(CreateDatabaseCredentials(...))` and the async
  creation happens after the screen is gone, so a failure loses the draft. This
  contradicts `specs/003-database-and-unlock/spec.md:113-115` ("Submit failure
  leaves step/draft visible").
- **No rollback.** A failed creation can leave an orphan generated key file, and
  the registry, active database id, security profile and secure store are each
  mutated with no compensation. This contradicts
  `specs/003-database-and-unlock/plan.md:100-101` ("Create failure removes
  partial output/key material created by that attempt and leaves prior active
  database/credentials unchanged"). `CreateDatabaseUseCase` only deletes the
  `.kdbx` when hashing fails (`create_database_usecase.dart:93-100`).
- **The key path is skipped under test.** `_prepareKeyFilePath` runs only when
  `!Platform.environment.containsKey('FLUTTER_TEST')`
  (`create_database_usecase.dart:63-65`), so the entire key-preparation branch is
  never exercised by any test.
- **Web creation always fails at runtime.** The same `Platform.environment` read
  needs `dart:io`; the storage root needs `path_provider`;
  `FilePicker.saveFile` cannot write without `bytes` on web; and `kdbx` needs
  `KdbxFormat.dartWebWorkaround` for dart2js `Uint64` behaviour.

## Goals

1. One credentials step containing both password and key file.
2. A valid credential matrix that includes key-file-only, enforced at both the UI
   and the use case.
3. All-or-nothing creation with a real rollback.
4. A wizard that survives failure with its draft intact.
5. An unlock fallback matrix consistent with the matrix that can now be created.
6. A web path that is honest: download-only, persisting nothing.

## Non-goals

- No migration and no special-casing of databases created before this spec.
- No export or backup feature for key files; only the inline warning below.
- No change to the KDBX format, the safe writer, `DatabasePathMutex`, or sync.
- No new credential factor (no hardware token, no passkey).

## Functional requirements

**FR-1 — Two steps on native.** The wizard is (1) name and storage, (2)
credentials. Biometric activation lives at the bottom of the credentials step,
since it is an option *on* the credentials just chosen and needs no step of its
own; the binding constraint is that password and key file are in the same step.

**FR-2 — Optional password.** Valid combinations: password only, key file only,
both. At least one factor is mandatory, validated in the UI (the submit control
is inert without one, with the reason stated) **and** in
`CreateDatabaseUseCase`, which is the trust boundary and rejects the request
regardless of caller.

**FR-3 — Confirmation rules.** With an empty password: no confirmation field
requirement, no mismatch error, strength meter hidden. With a non-empty
password: an identical confirmation is mandatory.

**FR-4 — Three-way key control.** Mutually exclusive: *none* / *select an
existing file* / *generate automatically*. Not a switch plus a separate button.

**FR-5 — Generate at submit only.** Key bytes are generated during submission.
No "Prepare generated key file" button exists on native. The on-disk name is
opaque per 014 FR-3.

**FR-6 — Selected key is copied.** A selected key file is copied into managed
storage; the user's original is never modified and never deleted. The UI shows
its name with *Change* and *Remove* actions.

**FR-7 — Key validation.** A key file that is unreadable, missing or empty
blocks creation with the error shown in the credentials step, and is rejected by
the use case as well. Any readable non-empty file is valid — no format
restriction.

**FR-8 — Name validation blocks.** A name containing `\ / : * ? " < > |` blocks
advancing out of step 1. No silent sanitisation.

**FR-9 — Transactional creation.** On failure the attempt deletes the `.kdbx` and
any key file it created, and restores the registry, the active database, the
security profile, the secure store, the sync metadata and the session secret to
their pre-attempt values. The key file the *user* selected is never deleted. The
rollback follows the shape already used by `_commitStagedImport`
(`database_session_coordinator.dart:454`).

**FR-10 — Failure UX and ownership.** On failure the wizard stays open with the
draft intact. While creation runs, the controls and Back/Cancel are disabled.
Field errors render next to their field; I/O errors render in the wizard.
Sequencing and rollback stay in the coordinator; the BLoC holds neither the
draft nor any secret.

**FR-11 — Biometric activation.** Biometrics can only be enabled by storing the
credentials at the same time. If credentials cannot be stored, activation is
refused with an explicit message. An empty string is never written to the secure
store.

**FR-12 — Unlock fallback matrix.** Shared code, so it applies to existing
databases too:

| Vault credentials | Fallback unlock requires |
| --- | --- |
| Password only | the password |
| Password + key | the password only; the managed key is used automatically |
| Key only | selecting the key file |

App-managed key files appear in the fallback picker **only after device
authentication** via `local_auth`, falling back to the system PIN/passcode. By
default the picker offers only the key associated with that database; listing
every managed key requires the same authentication. Without this gate, biometric
protection on a key-only vault would be cosmetic, because the managed key is
already sitting on the device.

**FR-13 — Generated-key warning.** A permanent inline notice on the generated-key
option: back this file up, losing it makes the database inaccessible. No modal,
no checkbox. Export stays out of scope.

**FR-14 — Web is download-only.** No biometric step (`local_auth` has no web
support). Password-only is allowed; a selected key file is read with
`withData: true`; a generated key's bytes are produced **once** and kept in
memory so a retry reuses them. Two explicit gestures: download the key, then
download the database — creation stays blocked until the key download has been
requested. `KdbxFormat.dartWebWorkaround = true` is set at the web boundary. No
registry entry, no opened vault, no persisted credential: after the download the
app returns to database selection. An inline notice states that the web app
keeps nothing and that reloading the page loses the draft and the key.

**FR-15 — No migration.** No migration and no special rule for existing
databases.

## Acceptance criteria

1. Each of the three credential combinations can be created and then unlocked.
2. Creating a database with no factor is impossible from the UI **and** rejected
   by `CreateDatabaseUseCase`.
3. An induced failure at each stage of creation leaves no `.kdbx`, no generated
   key, and no mutated registry, active id, security profile, secure-store entry
   or sync metadata; the user's selected key file still exists.
4. After a failure the wizard is still on screen with the draft intact.
5. A name containing an invalid character blocks step 1 and is never sanitised.
6. No empty string is ever written to the secure store.
7. Fallback unlock matches the FR-12 table, and the internal key picker is
   reachable only after device authentication.
8. On web, the two downloaded files are mutually consistent: the downloaded
   `.kdbx` opens with the downloaded key.

## Tests

- Unit — `CreateDatabaseUseCase` and `DatabaseSessionCoordinator`: the credential
  matrix, the at-least-one-factor rejection, key-file validation, and rollback
  for each induced failure point.
- Widget — the three key modes, the optional password with and without
  confirmation, an invalid name blocking step 1, and a failure that keeps the
  wizard open.
- Unlock — the FR-12 fallback matrix, including the device-authentication gate on
  the managed key picker.
- Goldens — realise the inventory below for the new two-step shape.
- Web — the download-only path verified without a real browser (bytes generated
  once, both artefacts consistent, nothing persisted).
- Remove the `FLUTTER_TEST` shortcut in `create_database_usecase.dart:63-65` so
  the key-preparation branch is actually covered.
- Manual — Safari and Firefox before any web release; Chrome is the automated
  gate.

### Golden inventory

Constitution principle IV. Collapsing three steps to two retires one golden and
re-shoots the other two:

| Golden | Status |
| --- | --- |
| `db_create_step1_390x844_light.png` | re-shot — name and storage, now blocking on an invalid name |
| `db_create_step2_390x844_light.png` | re-shot — the merged credentials step |
| `db_create_step3_390x844_light.png` | deleted with `CreateDatabaseStep.optionalLocks` |

Following the convention already in `test/goldens`, wizard steps are state
variants captured at one representative size and theme. **Omitted axes:**
1024×768, and dark theme.

The credentials step has more states than a golden per combination would justify,
so these are covered by named widget assertions instead: the three key modes
(*none* / *select* / *generate*), an empty password with the confirmation field
and strength meter hidden, a non-empty password with its confirmation mandatory,
the inert submit control stating why it is inert, the FR-13 backup warning on the
generated-key option, and a failed submission leaving the wizard mounted with the
draft intact.

The web path renders no golden: it persists nothing and its two-gesture download
flow is asserted behaviourally per FR-14.

## Risks

| Risk | Mitigation |
| --- | --- |
| Rollback misses one mutated store and leaves a half-created vault | Enumerate the stores in FR-9 and cover each with an induced-failure test, modelled on `_commitStagedImport` |
| A key-only vault plus an ungated internal picker makes biometrics cosmetic | FR-12 gates the picker with `local_auth` plus system PIN/passcode fallback |
| Users lose a generated key file and lose the vault | Permanent inline warning (FR-13); generation only at submit so no stray key is written by an abandoned draft |
| Depends on 014 landing first for the opaque key name | Sequenced: 015 does not start before 014's naming task lands, and does not restate 014's naming rule |
| Web path silently regressing, since no CI browser gate exists today | Automated Chrome gate plus manual Safari/Firefox before release |
| Removing the `FLUTTER_TEST` shortcut may surface latent failures in existing tests | Expected and desirable: those tests were passing over an unexecuted branch |

## Open questions

None blocking.
