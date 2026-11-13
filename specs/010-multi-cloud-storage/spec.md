# 010 — Cloud storage provider abstraction

**Status**: Planned · **Immediate delivery**: Google-only refactor  
**Kind**: Architecture refactor · **Depends on**: 005 · **Coordinates with**: 008, 013

## Normative boundary with spec 013

Spec 013 is the normative source for the **Google OAuth scope** and for **how a
remote file is chosen**. It narrows the scope to `drive.file` and replaces the
in-app remote file list with the Google Picker.

010 remains the owner of the provider-neutral architecture: the port, the mapping
schema, the safe error taxonomy and the dependency rules. 010 does **not** define
which scope is requested and does **not** preserve the current file-picker
behavior. Where this document previously assumed "scope unchanged" or "picker
unchanged", 013 governs instead. Neither spec duplicates the other's tasks.

## Summary

Refactor existing Google Drive sync behind one provider-neutral storage port and
one Google Drive implementation. Preserve current sync, UI behavior, static copy,
checksums, conflicts, auto-sync, account and mapping behavior. Remote file
selection is excluded from that preservation guarantee: spec 013 replaces it.
Sole intentional copy change owned by this spec: unsafe dynamic provider error
details become fixed provider-neutral safe messages from this spec; this
authorizes no other copy change.

This delivery does **not** add multi-cloud product behavior. It creates only the
boundary needed to add a second provider later without leaking its SDK, OAuth or
wire model through the application.

## Clarifications

### Session 2026-09-04

- Q: When a single mapping in `sync_mappings.json` has missing or invalid remote
  identity, does the decode failure scope the whole file or only that entry, and
  how does an undecodable entry survive the version-2 write-forward? → A:
  **Per-entry with quarantine.** Valid mappings still decode and are returned;
  the invalid entry is retained as opaque raw JSON and re-emitted unchanged by
  the version-2 serializer; the decode error is exposed only as non-blocking
  diagnostic state. Rationale: one corrupt record must not disable sync for every
  other database, and “must not silently drop a mapping” is only enforceable if
  the undecodable entry is carried through the rewrite.
- Q: Does the `mapping.providerId` guard also block purely local metadata
  operations — remove, move, restore, auto-sync toggle — or only operations that
  touch the remote? → A: **Only remote I/O and vault writes.** Local metadata
  operations stay available. Rationale: blocking them would make a mapping with
  an unknown provider ID unremovable from the app, leaving no UI exit short of
  hand-editing the metadata file; it also resolves the contradiction between
  dependency rule 7 (“before remote I/O”) and the previous “mapping mutation”
  wording.
- Q: After the refactor, who owns the per-call timeout, and must the orchestrator
  convert its own `TimeoutException` into a `CloudStorageException`? → A:
  **Timeout stays in the orchestrator, wrapped as `CloudStorageException(timeout)`
  before it propagates.** Rationale: the plan requires the timeout's duration and
  placement to be unchanged, and wrapping is the only way to keep a non
  provider-neutral exception from crossing the data boundary and to give the
  dynamic error slot a `safeMessage` for the timeout case.
- Q: For an HTTP `403`, is body inspection for rate-limit reasons mandatory or
  optional, and what takes precedence between a status-code row and the
  `malformedResponse` row? → A: **Mandatory inspection on `403`; HTTP status
  classifies first; `malformedResponse` applies only to `2xx` payloads that fail
  to parse; an unreadable `403` body falls back to `forbidden`.** Rationale: the
  mapping is declared exhaustive and precedence-ordered, so a `may` left the
  `rateLimited`-from-`403` row non-deterministic and untestable.
- Q: Must the v2-tolerant reader ship in a release before the v2 writer, or is a
  reactive compatibility patch on rollback acceptable? → A: **Single release plus
  a preventive dated backup of the version-1 `sync_mappings.json` taken before
  the first version-2 rewrite.** Rationale: constitution principle VII requires a
  dated backup before an irreversible operation, and the first v2 rewrite is
  irreversible for older binaries; the backup turns rollback into a metadata
  restore instead of an emergency patch, without the two-release sequencing the
  plan's “reader and writer in the same release” rule forbids.

## Problem and current state

Cloud sync is hard-coded to Google Drive across layers:

- `DatabaseSyncOrchestrator` directly depends on `GoogleDriveApiService`;
- `DatabaseSyncRepositoryImpl` directly coordinates `DriveAuthService`;
- domain/presentation expose `DriveRemoteFile`, `DriveAccountSummary` and
  `DrivePickerData`;
- `DatabaseSyncMapping` persists `driveFileId` and `driveFileName`;
- the application-facing repository exposes `linkDatabaseToDrive`;
- presentation state/events/widgets use Drive-shaped names even where values are
  generic remote object data.

Current code anchors:

| Concern | Current path |
| --- | --- |
| Application sync boundary | `lib/features/password_manager/domain/repositories/database_sync_repository.dart` |
| Sync algorithm and mapping workflow | `lib/features/password_manager/data/services/database_sync_orchestrator.dart` |
| Google object API | `lib/features/password_manager/data/services/google_drive_api_service.dart` |
| Google OAuth/token handling | `lib/features/password_manager/data/services/drive_auth_service.dart` and Google data sources/services |
| Persisted mappings | `lib/features/password_manager/domain/models/database_sync_mapping.dart`, `lib/features/password_manager/data/datasources/sync_metadata_data_source.dart` |
| DI | `lib/features/password_manager/di/password_manager_{data,domain,presentation}_di.dart` |
| Vault and import/link flows | `VaultBloc`, `VaultSessionCoordinator`, `DatabaseSessionCoordinator` |

`DatabaseSyncRepository` remains the application-facing domain boundary.
`DatabaseSyncOrchestrator` remains the data-layer sync workflow and must depend on
the new provider port, never on Google services.

## Goals

1. Define one provider-neutral cloud storage port used by data sync code.
2. Implement that port once for Google Drive by adapting existing auth and API
   services.
3. Replace Drive-shaped domain models, repository methods and persisted mapping
   fields with provider-neutral vocabulary.
4. Persist stable provider identity `google_drive` per database mapping.
5. Decode existing mapping JSON safely and write it forward to the generic
   schema without touching `.kdbx` bytes.
6. Keep Google OAuth, tokens, HTTP/SDK details and raw errors inside data-layer
   Google code.
7. Preserve current user-visible and sync behavior exactly, except unsafe dynamic
   provider error details intentionally become fixed provider-neutral safe
   messages. Preserve every static string and all unrelated copy.
8. Leave a narrow seam for a future provider without adding infrastructure for
   one that does not exist.

## Immediate non-goals

- No second provider or provider spike.
- No provider picker, provider-list UI or new safety-category UI.
- No simultaneous remotes. One database mapping names one provider and one
  remote object.
- No provider migration/switch flow.
- No registry, resolver, factory, keyed DI map or dynamic plugin system.
- No speculative split into auth, account, metadata and object-operation ports.
- No sync algorithm, conflict policy, checksum algorithm or UI behavior change.
  The per-call timeout keeps its duration and its placement in the orchestrator;
  the only change is that the exception it raises is normalized to
  `CloudStorageException(timeout)` so the data boundary stays provider-neutral.
  No static/unrelated copy change; only unsafe dynamic provider error detail is
  replaced by the fixed safe messages below.
- No native platform code change.
- No feature split or refolder: everything stays under
  `features/password_manager/{data,domain,presentation}`.
- No capability implementation in the immediate slice. Capability taxonomy is
  retained below only as future design vocabulary.

## Architecture and dependency rules

```text
widgets/BLoCs
    -> existing coordinators
        -> meaningful atomic use cases + DatabaseSyncRepository
            -> DatabaseSyncRepositoryImpl
                -> DatabaseSyncOrchestrator
                -> CloudStorageProvider (domain port)
                         ^
                         |
                GoogleDriveStorageProvider (data adapter)
                    -> DriveAuthService
                    -> GoogleDriveApiService
                    -> Google token/OAuth data sources and technical services
```

Rules:

1. Keep one `features/password_manager` feature. Do not create a cloud feature.
2. `DatabaseSyncRepository` remains application-facing. Presentation and use
   cases never receive `CloudStorageProvider` directly.
3. `DatabaseSyncOrchestrator` depends on `CloudStorageProvider`, injected through
   its constructor. It must not import `google_*`, `drive_*`, Google SDK or HTTP
   transport types.
4. One provider port includes connection/auth status, account summary and byte/
   object operations. Split only after a real second implementation proves
   different lifecycles or consumers require it.
5. `GoogleDriveStorageProvider` is the data adapter and sole implementation now.
   Existing `DriveAuthService` and `GoogleDriveApiService` remain data-private
   technical services behind it; they are not additional domain ports.
6. DI registers one `CloudStorageProvider` directly to the Google adapter. No
   collection or provider lookup is introduced.
7. A mapping carries `providerId`. With one injected implementation, an operation
   must verify `mapping.providerId == provider.providerId` before remote I/O.
   Unsupported IDs return a safe typed error and perform no local/remote write.
   The guard covers exactly remote I/O and vault writes. Purely local metadata
   operations — `removeMapping`, `moveMappingPath`, `restoreMappingPathMove` and
   the auto-sync toggle — are never blocked by it, so a mapping with an unknown
   provider ID always remains removable and movable from the UI. Enabling
   auto-sync on such a mapping is therefore permitted; the sync run it would
   trigger still fails closed at the guard.
8. Atomic business actions with policy or transaction value use use cases. In
   this slice, link and sync-now qualify. Do not create pass-through use cases for
   every repository getter/toggle solely for symmetry.
9. Multi-step connect/list/account/import/link flows stay in existing
   coordinators. BLoCs translate events to coordinator calls and state only.
10. Domain and presentation import no Google SDK/type. Provider raw errors and
    credentials never cross the data boundary.

## Domain vocabulary

Names describe application semantics, not current provider:

| Current | Provider-neutral replacement | Semantics |
| --- | --- | --- |
| `DriveRemoteFile` | `RemoteFile` | Provider ID, opaque remote ID, display name, optional modified time and content checksum |
| `DriveAccountSummary` | `StorageAccountSummary` | Safe display label and optional email; no token/account SDK object |
| `DrivePickerData` | `RemoteFileSelectionData` | Files plus account summary for one picker load |
| `LoadDriveRemoteFiles` | `LoadRemoteFiles` | Request provider-neutral picker/list data |
| `linkedDriveFileName` | `linkedRemoteFileName` | Current mapping display name |
| `remoteDriveFiles` | `remoteFiles` | Current provider's listed remote files |
| `getDrivePickerData` | `getRemoteFileSelectionData` | Coordinator picker-data workflow |
| `driveFileId` | `remoteFileId` | Opaque provider object identity |
| `driveFileName` | `remoteFileName` | Display name only; never identity |
| `linkDatabaseToDrive` | `linkDatabaseToRemote` | Create or link one remote object through mapped provider |

`providerId` is a stable persisted machine value. Immediate constant:

```text
google_drive
```

It is not a localized label, enum ordinal, Dart runtime type or OAuth client ID.
Changing Google branding must not change it.

## Provider contract semantics

Exact Dart syntax may follow repository style, but semantics are fixed.

`CloudStorageProvider` exposes:

- stable `providerId`;
- `isConnected`, `connect`, `disconnect`;
- connected `StorageAccountSummary`;
- obtain one eligible `.kdbx` remote file chosen by the user. Today that is the
  existing list-with-optional-query operation; spec 013 replaces it with a
  select-exactly-one operation and removes list-all. The port shape follows 013
  whenever 013 has landed;
- read object metadata;
- create object from name and bytes;
- replace object bytes by opaque ID;
- download object bytes by opaque ID.

Contract rules:

1. Remote identity is always the tuple `(providerId, remoteFileId)`. Opaque remote
   IDs may collide across providers; callers never parse them, construct them or
   compare them without provider identity.
2. Names are display/fallback-create values, not object identity.
3. Returned collections are immutable snapshots.
4. Optional `contentChecksum`, when present, is comparable to the current local
   MD5 baseline. A provider unable to supply that value returns null; existing
   orchestrator fallback downloads bytes and computes the same checksum. This
   refactor does not change checksum semantics.
5. `modifiedTime` remains optional and normalized to local `DateTime`, matching
   current behavior.
6. Create/update success returns fresh metadata. HTTP `2xx` interpretation and
   metadata refresh remain Google implementation details.
7. Every call either returns provider-neutral data or throws a safe storage
   error. Google SDK classes, HTTP responses, access tokens, signed URLs and raw
   response bodies never escape.
8. Delete is not added: current application behavior does not delete remote
   files. Add it only when a real business flow requires it.
9. Port knows remote bytes/objects, not KDBX parsing, local filesystem writes,
   sync conflict policy or mapping persistence.

`RemoteFile` therefore carries `providerId`; every returned value must match the
provider instance that produced it. Picker “already linked” checks compare
`mapping.providerId == file.providerId && mapping.remoteFileId == file.id`.
Comparing `remoteFileId` alone is forbidden, including while Google is the sole
visible provider.

## Application repository and workflow semantics

`DatabaseSyncRepository` keeps current responsibilities and behavior, with
provider-neutral signatures. It remains responsible for application actions:
connection, account summary, remote listing/download, mapping CRUD/move,
auto-sync, link and sync-now.

`DatabaseSyncRepositoryImpl` delegates provider operations through the injected
provider and sync behavior through `DatabaseSyncOrchestrator`. The orchestrator:

- reads mapping provider identity before remote I/O;
- uses `remoteFileId`/`remoteFileName` only;
- retains current per-call timeout — same duration, same placement — renamed
  provider-neutrally. The orchestrator keeps ownership of that timeout and wraps
  the `TimeoutException` it raises in `CloudStorageException(timeout)` before
  propagating, so no non provider-neutral exception crosses the data boundary.
  This is a normalization of the exception type only: the timeout is not moved
  into the adapter, no second timeout budget is added, and the failing branch,
  lock release and retry behavior are unchanged;
- retains current MD5 baseline/fallback-download behavior;
- retains current conflict branches, backups, mapping updates and auto-sync;
- retains the shared singleton `DatabasePathMutex` and all lock boundaries.

No method gains a provider parameter in current UI/use cases. New links always
store the sole injected provider's ID. Future provider selection will supply a
provider choice through a separately specified application flow.

## Persisted mapping schema and migration

### Version 1 — current legacy shape

```json
{
  "databasePath": "...",
  "driveFileId": "opaque-id",
  "driveFileName": "vault.kdbx"
}
```

Other checksum, timestamp, auto-sync and error keys already present remain
unchanged.

### Version 2 — canonical shape

```json
{
  "schemaVersion": 2,
  "databasePath": "...",
  "providerId": "google_drive",
  "remoteFileId": "opaque-id",
  "remoteFileName": "vault.kdbx"
}
```

Existing checksum/timestamp/auto-sync/error keys remain byte-semantically
equivalent; only remote identity vocabulary and schema metadata change.

### Backward-compatible decode

For each mapping:

1. Missing `schemaVersion` means version 1. Version 1 defaults missing
   `providerId` to `google_drive`.
2. A non-empty `remoteFileId` wins when present; otherwise decoder reads
   non-empty legacy `driveFileId`.
3. A non-empty `remoteFileName` wins when present; otherwise decoder reads
   non-empty legacy `driveFileName`.
4. Version 2 requires non-empty `providerId`, `remoteFileId` and
   `remoteFileName`. Unknown provider IDs are retained but are not executable by
   current Google-only DI.
5. Conflicting generic and legacy values use valid generic values and ignore
   legacy aliases. Tests pin this deterministic rule.
6. Missing/invalid required identity fails **per entry, not per file**. Reading
   the metadata file returns every entry that decodes; the entry that does not
   decode is quarantined — retained verbatim as opaque raw JSON that no caller
   interprets, that is never executable and that is never matched by a database
   path or remote identity lookup. The failure is surfaced as a safe non-blocking
   metadata-decoding diagnostic, not as a thrown failure of the whole read. It
   must not silently drop a mapping, connect a different object, rewrite the
   metadata file or touch vault bytes. Quarantine applies to every entry the
   decoder cannot turn into a mapping, including an entry that is not a JSON
   object at all: the current silent `.whereType<Map>()` drop is a defect this
   rule closes.
7. Existing portable-path decode/encode behavior is unchanged.

### Write-forward

- Reads are side-effect free; opening the app does not rewrite mappings.
- Any later successful mapping save (`upsert`, move, remove, auto-sync update or
  sync result) serializes all retained mappings as version 2.
- Version 2 writes only `providerId`, `remoteFileId` and `remoteFileName`; legacy
  Drive keys are not emitted.
- A quarantined entry is re-emitted unchanged. The serializer copies its retained
  raw JSON through byte-for-byte: it is not upgraded to version 2, not given a
  `providerId`, not reordered into a decoded shape and not dropped. A write that
  cannot preserve it fails instead of losing it.
- Before the first version-2 rewrite of a given metadata file, the writer stores
  a dated copy of the existing version-1 `sync_mappings.json` alongside it. The
  backup is taken once, before the mutation, and the mutation does not proceed if
  the backup cannot be written. It contains metadata only — no vault bytes, no
  credential — and is a plain restore target for a rolled-back binary.
- Migration writes only `sync_mappings.json` and that dated backup. It never
  opens, decrypts, copies, renames or rewrites a `.kdbx`.
- Failed serialization/write leaves current metadata behavior intact: error
  propagates safely and no vault operation is added as compensation.

Backout consequence is explicit: an older binary cannot decode a mapping once it
has been written as version 2. Reader and writer ship in the same release; the
dated version-1 backup above is the preventive mitigation, so backout restores
that file rather than requiring a compatibility patch to be built reactively.
Shipping a compatibility patch that reads version 2 remains an alternative;
never downgrade or rewrite vault bytes. Local vault usability is unaffected if
sync mapping is temporarily unavailable.

## Error and security requirements

Provider failures use exactly one provider-neutral type:

```text
enum CloudStorageErrorCode {
  cancelled,
  authenticationFailed,
  authorizationRequired,
  forbidden,
  unsupportedProvider,
  notFound,
  conflict,
  rateLimited,
  timeout,
  networkUnavailable,
  malformedResponse,
  serverFailure,
  unknown,
}

final class CloudStorageException implements Exception {
  const CloudStorageException(this.code);
  final CloudStorageErrorCode code;
  String get safeCode;
  String get safeMessage;
  String toString() => safeCode;
}
```

No public `cause`, response, provider exception or interpolated detail field is
allowed. `safeCode` and `safeMessage` are exhaustive constants:

| Enum | Safe code | Fixed safe message |
| --- | --- | --- |
| `cancelled` | `cloud_storage.cancelled` | `Cloud storage operation was cancelled.` |
| `authenticationFailed` | `cloud_storage.authentication_failed` | `Unable to authenticate with cloud storage.` |
| `authorizationRequired` | `cloud_storage.authorization_required` | `Cloud storage authorization is required.` |
| `forbidden` | `cloud_storage.forbidden` | `Cloud storage access was denied.` |
| `unsupportedProvider` | `cloud_storage.unsupported_provider` | `Cloud storage provider is not supported by this build.` |
| `notFound` | `cloud_storage.not_found` | `Remote file was not found.` |
| `conflict` | `cloud_storage.conflict` | `Remote file changed before the operation completed.` |
| `rateLimited` | `cloud_storage.rate_limited` | `Cloud storage is temporarily busy. Try again later.` |
| `timeout` | `cloud_storage.timeout` | `Cloud storage request timed out.` |
| `networkUnavailable` | `cloud_storage.network_unavailable` | `Cloud storage is unavailable. Check your connection.` |
| `malformedResponse` | `cloud_storage.malformed_response` | `Cloud storage returned an invalid response.` |
| `serverFailure` | `cloud_storage.server_failure` | `Cloud storage service is temporarily unavailable.` |
| `unknown` | `cloud_storage.unknown` | `Cloud storage operation failed.` |

Google mapping is exhaustive and precedence-ordered:

| Google/transport source | Provider-neutral code |
| --- | --- |
| Explicit user-cancel result or `GoogleSignInExceptionCode.canceled` | `cancelled` |
| Sign-in/configuration failure, missing credentials, token acquisition failure or refresh failure before an HTTP response | `authenticationFailed` |
| HTTP `401` after the existing single token-refresh attempt | `authorizationRequired` |
| HTTP `403` whose body reason is `rateLimitExceeded`, `userRateLimitExceeded`, `dailyLimitExceeded` or `quotaExceeded` | `rateLimited` |
| Every other HTTP `403`, including one whose body is absent, unparsable or carries an unrecognized reason | `forbidden` |
| HTTP `404` | `notFound` |
| HTTP `409` or `412` | `conflict` |
| HTTP `429` | `rateLimited` |
| HTTP `408` or `TimeoutException` | `timeout` |
| `SocketException`, connection-level `http.ClientException`, DNS/offline/no-response failure | `networkUnavailable` |
| `FormatException`, invalid JSON/type, or missing required response field, **in a `2xx` response** | `malformedResponse` |
| HTTP `500..599` | `serverFailure` |
| Every unmapped exception/status | `unknown` |

`unsupportedProvider` is not produced by Google SDK/HTTP mapping. Exact trigger:
a persisted mapping has a syntactically valid non-empty `providerId`, but current
build has no wired adapter for it. In Google-only build this is exactly
`mapping.providerId != injectedProvider.providerId`. Check occurs before auth,
remote I/O, backup or local vault write. It does **not** gate purely local
metadata operations: remove, path move, move restore and the auto-sync toggle
stay available on a mapping with an unsupported provider ID, per dependency rule
7, so the user always has a way to unlink or relocate it. Exception contains only
the enum; `safeCode`, `safeMessage`, `toString`, logs and UI never interpolate or
otherwise reveal raw persisted provider ID.

Precedence is resolved as follows, and every row is deterministic:

1. An HTTP response is classified by its status code first. `malformedResponse`
   is reachable only from a `2xx` response whose payload cannot be parsed or is
   missing a required field; a non-`2xx` response keeps its status-derived code
   even when its body is invalid JSON — a `500` with an unparsable body is
   `serverFailure`, never `malformedResponse`.
2. Body inspection is **mandatory for `403`** and is the only case where the body
   affects classification. The adapter reads the reason, maps the four
   rate-limit reasons above to `rateLimited`, and maps every other `403` —
   including an absent, unparsable or unrecognized reason — to `forbidden`. There
   is no implementation freedom here: the `rateLimited`-from-`403` row is
   testable as one exact expectation.
3. `TimeoutException` in this table means a transport-level timeout observed
   inside the adapter. The orchestrator's own per-call timeout is owned and
   wrapped by the orchestrator, as specified in §Application repository and
   workflow semantics; both paths surface the same `timeout` code and message.

The existing one-time `401` token refresh remains unchanged; this table does not
add retries. The inspected body is discarded immediately and never copied into
the exception.

Existing static UI copy, action labels (including reconnect guidance) and state
transitions remain byte-identical. Only the dynamic error-detail slot changes: it
displays `CloudStorageException.safeMessage` exactly. BLoC/coordinator code must
never display `exception.toString()` or add a prefix/suffix. Characterization tests
classify current assertions as static copy or dynamic provider detail; only the
latter expectations move to the fixed table above. This is the explicit security
copy exception for immediate slice.

Additional security rules:

1. Raw `GoogleSignInException.toString()`, HTTP status/body, token, URL, signed
   URL, object payload, SDK message and stack text never reach domain/
   presentation, logs, `lastError` or mapping JSON.
2. Every enum value and every table row has an exhaustive boundary test: Google/
   transport rows at adapter, `unsupportedProvider` at orchestrator. Tests inject
   a unique token-like sentinel into raw exception/body/URL/unsupported-ID fields
   and assert it is absent from `safeCode`, `safeMessage`, `toString`, logs, state
   and persistence.
3. An unmapped status/exception deterministically becomes `unknown`; adapter code
   has no rethrow-raw branch.
4. Unsupported-provider tests use a unique provider-ID sentinel and assert zero
   provider calls/writes plus sentinel absence from exception/string/log/state/
   persistence.
5. OAuth access/refresh tokens remain in current data services and secure storage.
   They never enter provider-neutral models, `Equatable.props`, `toString`, logs
   or mapping JSON.
6. Logs must not add account email, remote object ID, raw provider errors or
   credentials. Existing conflict diagnostics are not broadened by this refactor.
7. Remote bytes remain encrypted `.kdbx` bytes. Adapter never decrypts them.
8. Unsupported provider, migration failure and adapter failure are fail-closed:
   no guessed provider, fallback remote, blind upload or mapping deletion.
9. Preserve spec 008 safety work: singleton path mutex, writer routing, verified
   backup/safe-writer boundaries and future write-verify-converge semantics must
   not be bypassed or duplicated.

## Functional requirements — immediate Google slice

### FR-1 — Provider-neutral port

One `CloudStorageProvider` domain port covers current auth/account and object-byte
operations. Exactly one Google implementation is registered.

### FR-2 — Google adapter

Google adapter composes existing Google auth/API technical services, maps their
results to neutral models and maps all errors to safe storage errors. OAuth,
scopes, retries, token refresh, HTTP fields and query syntax stay Google-private.
Their *values* are not this spec's to choose: the requested scope and the file
selection mechanism are defined by spec 013, and this adapter carries whatever
013 specifies.

### FR-3 — Neutral orchestrator

`DatabaseSyncOrchestrator` imports only provider-neutral domain contracts/models
for remote work. It has no Google/Drive type, field, method or constructor
dependency.

### FR-4 — Neutral application boundary

`DatabaseSyncRepository` and touched coordinators/BLoC state use neutral remote
models and mapping names. Literal Google Drive UI copy remains unchanged because
Google remains the only shipped provider.

### FR-5 — Mapping version 2

Legacy mappings decode as Google Drive, retain all baselines/settings, and write
forward exactly as specified. No vault byte changes occur during migration.

### FR-6 — Behavior parity

Connect/disconnect, account display/fallback, list/search, existing-file download
and link, new-file create/link, manual sync, auto-sync, conflict resolution,
mapping move/remove and timeout behavior match pre-refactor characterization.

### FR-7 — Thin presentation flow

Link and sync-now use meaningful atomic use cases. Existing coordinators own
multi-step flows. Touched BLoC handlers contain state/event translation, not
provider selection, OAuth or remote sequencing.

## Verifiable acceptance criteria — immediate delivery

1. `DatabaseSyncOrchestrator` constructor accepts `CloudStorageProvider`; source
   imports/references no `GoogleDriveApiService`, `DriveAuthService` or Drive
   domain model.
2. Exactly one provider port and exactly one production implementation exist.
   No registry/factory/provider map exists.
3. Domain and presentation import no Google SDK classes. This is the single
   canonical list of banned identifiers; `plan.md` and `tasks.md` reference it
   rather than restating it. Code has no
   `DriveRemoteFile`, `DriveAccountSummary`, `DrivePickerData`,
   `LoadDriveRemoteFiles`, `linkedDriveFileName`, `remoteDriveFiles`,
   `getDrivePickerData` or `linkDatabaseToDrive` contract/state identifier.
   `driveFileId`/`driveFileName` remain only quoted v1 serialized keys in decoder
   and migration fixtures. Their neutral replacements are `RemoteFile`,
   `StorageAccountSummary` and `RemoteFileSelectionData`; where spec 013 has
   already removed the selection surface, `RemoteFileSelectionData` is deleted
   rather than introduced.
4. `DatabaseSyncRepository` remains the application-facing sync boundary.
5. DI binds `CloudStorageProvider -> GoogleDriveStorageProvider` directly and
   injects that same instance into repository/orchestrator paths.
6. Every newly created mapping persists `schemaVersion: 2`,
   `providerId: google_drive`, `remoteFileId` and `remoteFileName`, with no legacy
   Drive keys.
7. Legacy fixtures without `providerId` decode to `google_drive`, preserve every
   checksum/timestamp/auto-sync/error value, and write forward on the next
   successful metadata mutation. A fixture mixing valid mappings with one
   undecodable entry returns every valid mapping, quarantines the bad entry, and
   re-emits that entry unchanged after a write-forward. The first version-2
   rewrite leaves a dated copy of the version-1 file, and the restored copy
   decodes back to the original mappings.
8. Remote identity and duplicate-link checks use `(providerId, remoteFileId)`.
   Tests prove equal opaque IDs under different providers are not duplicates.
9. A valid mapping whose provider ID has no wired adapter throws exactly
   `unsupportedProvider` from remote-I/O and vault-write paths, exposes only its
   fixed code/message, never includes raw ID, and performs no auth, remote call,
   backup, metadata mutation or `.kdbx` write. On that same mapping, remove, path
   move, move restore and the auto-sync toggle succeed normally and throw
   nothing. Malformed mappings also perform no remote/local write.
10. Google auth/API failures map exhaustively to the exact enum/code/message table
    above, including deterministic `unknown`, both `403` rows and the `2xx`-only
    scope of `malformedResponse`; the orchestrator's per-call timeout surfaces as
    `CloudStorageException(timeout)` and no bare `TimeoutException` escapes the
    data layer; raw errors and token-bearing values
    cannot appear in domain/presentation models, logs, mapping JSON or
    user-visible error state.
11. Pre-refactor characterization tests and post-refactor parity tests cover all
    FR-6 branches and remain green.
12. Shared `DatabasePathMutex` and existing backup/local-write boundaries remain
    unchanged. The remote timeout keeps its duration, its placement and its lock
    behavior; only its exception type is normalized per criterion 10. No sync
    algorithm or checksum branch changes.
13. Existing UI strings and widget behavior remain byte-identical except explicit
    normalization of unsafe dynamic error detail to fixed safe messages; no provider
    picker or new settings appear. Remote file selection copy and behavior are
    exempt when spec 013 has landed, because 013 replaces that surface; 010 still
    changes nothing there on its own.
14. `flutter analyze`, targeted suites and full `flutter test` pass.
15. No native platform or file outside documentation/tests/Dart implementation
    scope changes during eventual implementation. Verified mechanically by the
    branch-diff guard in T604, not by review alone.

## Test matrix

### Automated

| Area | Required evidence |
| --- | --- |
| Architecture | source/dependency test rejects Google/Drive imports and identifiers in orchestrator/domain contracts; confirms one port/implementation and no registry |
| Mapping migration | v1 missing provider, mixed legacy/generic, v2, unknown provider, malformed identity, non-object entry, per-entry quarantine and verbatim re-emission, dated v1 backup on first v2 rewrite and its restore, portable path, write-forward/no-legacy-output, `(providerId, remoteFileId)` preservation |
| Provider contract | fake provider proves tuple identity, checksum-null fallback, immutable list, fresh metadata, exact typed errors and `unsupportedProvider` fail-closed behavior |
| Google adapter | auth/account fallback, list/query, metadata/create/update/download mapping, 401 refresh path, every exhaustive error row and unknown fallback |
| Orchestrator | unchanged first-sync, local-only, remote-only, conflict/cancel/keep-local/use-remote, checksum-download fallback and timeout branches; per-call timeout surfaces as `CloudStorageException(timeout)` with unchanged duration, placement and lock release; unsupported provider blocks remote I/O but not remove/move/restore/auto-sync toggle |
| Concurrency/safety | existing edit-vs-sync, writer lock routing, shared mutex identity and backup tests remain green |
| Repository/use cases | neutral delegation, provider-ID guard, link and sync-now atomic behavior |
| Presentation | existing picker, duplicate-link tuple identity (including same opaque ID/different provider), coordinators, background auto-sync, conflict and status tests pass with renamed models only |
| Regression | full `flutter test` |

Architecture characterization tests land before production changes, so tests
first describe current behavior and then change only vocabulary/dependency
expectations.

### Five-platform manual Google smoke

Run independently on Android, iOS, macOS, Windows and Linux. Android/iOS use the
mobile `google_sign_in` authorization path. macOS/Windows/Linux use desktop browser
OAuth PKCE plus secure persisted desktop credentials. One platform result never
qualifies another.

Each platform record is `pass`, `fail` or `not-run`, written to
`specs/010-multi-cloud-storage/manual-qa.md`. `not-run` requires an
approved waiver naming approver, date and concrete environment/release reason;
blank or “covered on host” is invalid. Store no account, object, path or token.

| Platform | Auth path | Required result |
| --- | --- | --- |
| Android | mobile Google Sign-In + Drive scope | `pass|fail|not-run` + waiver when not-run |
| iOS | mobile Google Sign-In + Drive scope | `pass|fail|not-run` + waiver when not-run |
| macOS | desktop browser OAuth PKCE + secure token store | `pass|fail|not-run` + waiver when not-run |
| Windows | desktop browser OAuth PKCE + secure token store | `pass|fail|not-run` + waiver when not-run |
| Linux | desktop browser OAuth PKCE + secure token store | `pass|fail|not-run` + waiver when not-run |

Every platform run covers the same checklist:

1. connect and show safe account label/fallback;
2. select a remote `.kdbx` through whichever selection mechanism ships at the
   time — the current list/search, or the spec 013 Picker once 013 has landed;
3. link/download existing and create/link new remote file;
4. manual no-change/local-only/remote-only sync;
5. restart, then verify persisted mapping and auto-sync after a local edit;
6. force conflict and exercise Keep local, Use remote and Cancel;
7. disconnect, revoke authorization externally, observe safe failure, reconnect;
8. load a legacy mapping without `providerId`, sync it, verify write-forward and
   verify the dated version-1 backup exists next to the migrated file;
9. inspect redacted metadata for schema v2, `google_drive`, generic identity keys,
   no legacy output keys and no credential/raw provider detail;
10. open resulting remote `.kdbx` in a KeePass-compatible client.

## Rollout and backout

Rollout is behavior-preserving and requires no feature flag:

1. Land characterization and migration tests.
2. Land generic models/schema decode while preserving behavior.
3. Land port and Google adapter.
4. Switch orchestrator/repository and DI.
5. Neutralize touched presentation vocabulary and run full validation.
6. Release with Google as sole provider and monitor safe sync-error categories.

Do not combine this with spec 008 algorithm/merge changes. Rebase and re-run the
008 writer/safety suites after any concurrent 008 work touching orchestrator,
mapping, DI or mutex code.

Backout never rewrites a vault. Code rollback is safe for local `.kdbx` data.
Version-2 metadata is handled by restoring the dated version-1 backup that the
first write-forward left behind; a reader-compatible rollback build remains the
fallback when that backup is absent. If mapping metadata is unavailable, disable
sync and retain local vault rather than guessing Google identity.

## Risks and dependencies

| Risk | Mitigation |
| --- | --- |
| Refactor changes sync semantics accidentally | Characterize every branch first; provider substitution only; diff algorithm separately |
| Mapping migration links wrong remote | Generic-first deterministic decode, strict required fields, stable provider guard, fail closed |
| Raw Google error leaks token/body | Adapter-owned closed error mapping; tests with token-like sentinel strings |
| Port grows into speculative framework | One interface, one adapter, direct DI; defer registry/capabilities/picker |
| Active spec 008 changes same files | Sequence/rebase explicitly; preserve singleton mutex and safe-writer invariants; run 008 gates |
| Old binary cannot read v2 metadata | Dated version-1 backup written before the first v2 rewrite, restored on rollback; reader-compatible rollback build as fallback; never touch vault bytes to downgrade |
| One corrupt mapping record disables sync for every database | Per-entry decode with quarantine; valid mappings keep working and the bad entry is preserved verbatim rather than dropped |
| Presentation rename expands scope | Rename only touched Drive-shaped data identifiers; preserve literal Google UI copy |
| Spec 013 replaces the selection surface this refactor renames | Sequence the two explicitly; 013 owns scope and picking, 010 owns the port shape; rebase and re-run the selection suites after either lands |

Spec 008 is active. Its Gate 0 and deletion model are closed, while writer routing,
collision-safe backup and safe local writer work remain relevant dependencies.
010 must consume the shared infrastructure that exists at implementation time and
must not fork or weaken it. 010 does not implement 008's merge algorithm.

## Deferred future-provider phase — not immediate DoD

Only after a second provider is selected and measured:

- add its adapter and direct selection mechanism appropriate to real UI needs;
- add provider picker and provider-switch/migration UX;
- resolve `providerId` to one of multiple implementations (then, and only then,
  introduce a minimal resolver/registry);
- measure capabilities against the real service;
- define migration verification before dropping an old provider mapping;
- add provider-specific manual/network test evidence.

### Capability vocabulary retained for future work

Base operations should remain byte/object operations. Optional capabilities may
include:

| Capability | Meaning |
| --- | --- |
| `conditionalWrite` | server rejects a stale write precondition |
| `versionHistory` | overwritten object bytes remain retrievable from server |
| `atomicCreateIfAbsent` | create succeeds only if logical target is absent |
| `changeNotification` | efficient remote-change scheduling signal; never a safety guarantee |

Declarations require dated live-service evidence and conservative defaults.
Google Drive's `conditionalWrite` was measured absent by spec 008; unmeasured
capabilities remain absent. Future user-facing safety categories from the prior
draft remain deferred from Google-only refactor, but their derivation constraints
remain normative for future provider-choice work:

| Category | Exact derivation | Required condition-first copy |
| --- | --- | --- |
| **Protetto** | `conditionalWrite` present | `If another device saves at the same moment, this service refuses the second save. Nothing you save here is replaced by another device without you being asked.` |
| **Recuperabile** | no `conditionalWrite`; `versionHistory` present | `If two devices save at the same moment, one save can replace the other. As long as the device that made the replaced save connects again, Custode gets it back from the service and nothing is lost. Until then, that save exists only on that device.` |
| **Ricostruibile** | neither present | `If two devices save at the same moment, one save can replace the other. As long as the device that made the replaced save connects again, Custode restores it from the copy kept on that device and nothing is lost. If that device never connects again, that save is lost.` |

Category is one pure function of evidence-backed capability set, never an adapter
constant/override. `changeNotification` changes freshness only and never raises a
safety category. Category/copy is shown before future provider choice; every
string states failure condition before reassurance. None of this creates current
Google UI or immediate acceptance work.

### Deferred adapter eligibility and evidence — normative

These constraints are outside immediate Google-only refactor DoD, but mandatory
before any future provider adapter ships or any optional capability is declared:

1. **Single-file invariant:** at every instant, including interrupted and
   mid-write states, the remote is exactly one `.kdbx` directly openable by a
   KeePass-compatible application. No partial object at the mapped identity, no
   per-device fragments, duplicate logical vaults, sidecar lock/marker/journal,
   proprietary wrapper or chunking. An adapter unable to prove this is ineligible
   regardless of capabilities.
2. Every base-operation and capability spike runs against the real service with a
   throwaway account/object. A reported success is paired with a counter-proof:
   re-read bytes/metadata; stale-write probes verify whether bytes landed;
   interruption probes verify single-file/openability; negative results include
   transport counter-probes that rule out dropped headers or a broken request.
3. Artifacts contain no credential, account identifier/email, object ID, local or
   remote path, token, signed URL or real vault bytes. Probes use generated
   non-secret bytes only.
4. Negative evidence is valid and conservative: `absent` means capability absent;
   missing, malformed or inconclusive evidence also means absent. Negative
   evidence can never support a present declaration.
5. No future adapter ships without passing base-operation/single-file evidence.
   No capability is declared present without passing capability evidence.

Artifact path and schema are fixed:

```text
specs/010-multi-cloud-storage/evidence/<providerId>/<yyyy-mm-dd>-<subject>.json

{
  "schemaVersion": 1,
  "providerId": "stable_machine_id",
  "subject": "base_operations|single_file|conditionalWrite|versionHistory|atomicCreateIfAbsent|changeNotification",
  "observedAtUtc": "ISO-8601 UTC",
  "result": "present|absent",
  "probeSummary": "sanitized non-secret summary",
  "counterProbes": ["at least one sanitized counter-probe"],
  "sanitized": true
}
```

When future adapter/capability work starts, a structural test must:

- enumerate every shippable adapter from the then-necessary provider resolver;
- require `base_operations` and `single_file` artifacts with `present` result;
- require each present capability declaration to use an immutable
  `VerifiedCapability(capability, artifactPath, observedAtUtc)` value; no bare
  boolean and no separate optional comment;
- validate path, schema, UTC date, provider/subject match, non-empty counter-probe
  list and `sanitized: true`;
- reject present declarations backed by `absent`, missing, malformed or
  mismatched artifacts;
- scan forbidden keys/patterns and fail if an artifact contains credentials,
  account/object identifiers, paths, tokens, URLs or vault bytes.

Do not build this resolver or structural test in the immediate one-provider
slice: there is no provider choice to enumerate and Google declares no optional
capability. The obligation activates before future adapter/capability code can
ship; it is not waived by being outside immediate DoD.

The immediate `GoogleDriveStorageProvider` is a boundary refactor around the
already-shipped Google backend, not approval of a new backend or capability. Its
gate is complete behavior characterization plus the five-platform matrix above,
and it declares no optional capability. Changing Google's remote write primitive,
claiming a capability, or adding another provider activates the artifact and
single-file eligibility gate before release.

## Definition of done — immediate slice

- All immediate acceptance criteria pass.
- Mapping migration and safe-error tests pass, including per-entry quarantine and
  the dated version-1 backup taken before the first write-forward.
- Targeted sync, mutex/writer, coordinator, BLoC and widget suites pass.
- `flutter analyze` and full `flutter test` pass.
- Android, iOS, macOS, Windows and Linux manual rows are recorded; no row is
  `fail`, and every `not-run` has approved dated waiver/reason.
- No source behavior, static UI copy, native code or sync algorithm changed beyond
  provider abstraction, explicit metadata migration and fixed safe replacement
  of dynamic provider error detail.
- Deferred second-provider/capability/picker tasks remain unimplemented.

## Open questions

No blocking architecture question remains for immediate slice. The file grouping
question is closed: safe error models live in
`domain/models/cloud_storage_error.dart` and the port in
`domain/repositories/cloud_storage_provider.dart`, exactly as T201 specifies.
There is one provider port and one Google adapter.

Future questions, intentionally deferred: which second provider, which measured
capabilities it has, and what provider-selection/migration UX it requires.
