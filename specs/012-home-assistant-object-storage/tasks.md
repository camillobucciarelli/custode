# 012 — Tasks

Ordered tasks. Each names the requirement or acceptance criterion it satisfies,
the files it touches and how it is verified.

Two sequencing rules govern everything below. First, spec 010's immediate
refactor must have landed: this spec consumes its port, models, safe errors,
mapping schema and `(providerId, remoteFileId)` identity, and adds the resolver
that 010's plan deferred. Second, the companion integration is built and proven
before any app wiring exists, because it owns every invariant that cannot be
retrofitted — atomic commit, bounded input, credential lifecycle and restore.

Deferred and non-DoD items at the bottom are plain bullets on purpose. They are
not checkboxes and must never become checkboxes, because the roadmap sync counts
every checkbox line as scheduled work.

## Phase 0 — prerequisites and the restore spike

- [ ] T001 Confirm spec 010's immediate slice has landed: `CloudStorageProvider`,
      the provider-neutral models, the safe-error taxonomy, mapping schema v2 and
      `(providerId, remoteFileId)` identity all exist in `lib/`, and no provider
      registry was added there. Verified as a boolean check against the tree, not
      against a status note.
- [ ] T002 Gate S0: on a real Home Assistant OS instance and a real Home Assistant
      Container instance, prove a backup restore is detectable through a supported
      platform lifecycle signal, early enough to block view activation. Record the
      observed signal per runtime. A negative result is valid and conservative:
      that runtime becomes unsupported and the provider stays disabled there. No
      heuristic may infer restore from timestamps or file mtimes.
- [ ] T003 Record the Gate S0 outcome as sanitized evidence naming the signal and
      the two runtime versions. It contains no URL, token, path, object ID or
      host. This outcome is a binding input to T023.

## Phase 1 — repository prerequisites

- [ ] T004 AC-15: add `home_assistant/pyproject.toml` configuring ruff, mypy and
      pytest over `custom_components/keyvault_storage/` and `tests/`. Existing
      `tool/*.py` stays out of scope. Verified by all three tools running clean on
      an empty package skeleton.
- [ ] T005 AC-15: add a `home_assistant` job to the PR workflow running ruff,
      mypy and pytest. Without it AC-15 is a sentence no command satisfies.
      Verified by a deliberately introduced lint and type error failing the job.
- [ ] T006 Establish the shared wire contract as code, not prose: one protocol
      version constant and one route-path list, declared once per side —
      `home_assistant/custom_components/keyvault_storage/protocol.py` and its Dart
      counterpart — with a contract test that fails when the two disagree. The
      protocol version is distinct from the companion archive version and moves
      only on a wire-contract change.

## Phase 2 — companion object store

- [ ] T007 FR-2: implement `store.py` committed-object writes as create a
      same-directory exclusive temp at mode `0600` where POSIX modes exist, stream
      bytes into it, flush and fsync, atomically install with no-overwrite
      semantics for create or `os.replace` for replacement, fsync the parent
      directory where supported, and return metadata only after reopening or
      restating the committed target.
- [ ] T008 FR-2: on cancellation or failure remove the temp and preserve the old
      target; remove stale temporary files at startup, before any view becomes
      available. Internal temporary files are never listed or addressable through
      the API.
- [ ] T009 FR-2: serialize writes per object. List and read may run concurrently
      with a write only while they continue to observe the old committed file
      until the atomic replace.
- [ ] T010 AC-4: add a store-wide catalog lock serializing create identity
      allocation and quota checks, so two concurrent creates can neither reuse an
      identity nor both pass the 1,000th-object boundary. Equal display names are
      allowed and stay distinct by ID.
- [ ] T011 AC-3: fault-injection tests killing the process at every write phase
      for both create and replace, asserting the store exposes exactly one old or
      new complete object, never a missing or truncated target, and that stale
      temps are removed after restart.

## Phase 3 — input and path hardening

- [ ] T012 AC-4: reject symlinks, hard links, directories, device files and any
      path escaping the storage root, before any committed mutation.
- [ ] T013 AC-4: enforce the bounds — 64 MiB maximum object size, 180-byte maximum
      display-name UTF-8 length before physical encoding, 1,000 committed objects
      per instance. Request bodies are streamed and counted so a missing or
      dishonest `Content-Length` never bypasses the limit.
- [ ] T014 AC-4: validate display names as one non-empty basename ending in
      `.kdbx`, with no path separators, control characters, `.`/`..` or
      normalization ambiguity; validate object IDs by strict canonical decoding
      and installation-ID check before any filesystem lookup.
- [ ] T015 AC-2/AC-4: attack-matrix tests for traversal, symlink, hard link,
      special file, malformed and foreign IDs, oversized body, dishonest length,
      invalid name and the 1,001st-object attempt — each failing before committed
      mutation.

## Phase 4 — pairing and configuration

- [ ] T016 FR-4: implement `config_flow.py` with exactly one config entry per
      Home Assistant instance and an options flow that generates a
      cryptographically random 256-bit pairing code, displayed exactly once.
- [ ] T017 FR-4/AC-6: persist only a SHA-256 hash, creation time, expiry and a
      random slot ID. A code expires after five minutes, is single-use, and is
      invalidated when a new code is generated for the same slot. At most 20
      active client slots and one pending code per slot.
- [ ] T018 FR-4/AC-6: `POST /pair` atomically consumes the code before issuing a
      separate random 256-bit storage token bound to that slot and installation,
      and persists only the token hash. The server returns the plaintext once.
- [ ] T019 AC-6: bound pairing attempts with a store-wide rate limiter and a fixed
      failure delay, with no distinction between unknown, expired, consumed and
      wrong codes. The pending-code record persists attempt count and next-allowed
      UTC instant atomically with its hash, so a restart cannot reset the limit.
- [ ] T020 FR-4: options list slots by random short label and creation time only,
      never token, hash, device or account metadata. An administrator may revoke
      any slot, and revocation takes effect before the options flow reports
      success.

## Phase 5 — HTTP views and the authentication guard

- [ ] T021 FR-1/AC-2: implement the eight routes under
      `/api/keyvault_storage/v1` — `GET /info`, `POST /pair`, `POST /unpair`,
      `POST /objects/{list,metadata,create,read,replace}`. No `DELETE`, rename,
      path, history, Home Assistant user-auth or generic filesystem endpoint
      exists. `POST /create` always allocates a new identity and never targets an
      existing object.
- [ ] T022 FR-1/AC-2: every protected view sets `requires_auth = false` and runs
      the same custom guard before parsing identity, name or body and before
      touching disk. The storage token is accepted only in `Authorization:
      Bearer`; query-string tokens, cookies, signed paths and Home Assistant user
      tokens are rejected. Token hashes are compared in constant time.
- [ ] T023 AC-2: fixed machine codes and fixed safe messages in every failure
      response. No exception, traceback, absolute path, Home Assistant user ID,
      token, request body, object bytes, remote ID, display name or host appears
      in a response. The integration never logs request headers or bodies.
- [ ] T024 FR-1: metadata responses carry only `id`, `name`, `size`,
      `modifiedTime` and `contentChecksum`. Create, replace and single-object
      metadata compute the checksum from committed bytes; list may return
      `contentChecksum: null`.
- [ ] T025 AC-2: protocol-version negotiation on `GET /info`, and a fixed failure
      for a version the server cannot serve.

## Phase 6 — lifecycle and the restore boundary

- [ ] T026 FR-1: register HTTP views exactly once at integration-level setup.
      Config-entry setup creates the private storage directory, verifies it is
      writable, and only then publishes an active runtime store to those views.
- [ ] T027 AC-1: a missing, failed, unloaded or reloading entry makes every view
      return a fixed `503` without touching disk. Setup is refused when storage is
      unwritable.
- [ ] T028 FR-1: unload removes runtime state and closes open resources; routes
      stay registered but fail closed until a successful reload. Repeated
      setup/unload/reload duplicates no route and retains no old store. Stored
      objects survive.
- [ ] T029 AC-17: implement the restore credential reset using the signal T002
      recorded. Before publishing the runtime store, atomically delete every
      pending pairing code and storage-token slot and persist completion. Until
      the reset completes every route including `/pair` returns a fixed `503`. No
      token from before or from inside the restored backup authenticates, even
      transiently. Objects and installation identity survive.
- [ ] T030 AC-17: restore tests creating active and revoked slots, capturing a
      backup, mutating slot state, restoring, and proving every pre-backup and
      post-backup token receives `503` during reset and `401` after activation,
      and that fresh pairing restores mapped sync.
- [ ] T031 FR-1: removing the config entry deletes no vault object without a
      separate explicit destructive confirmation inside Home Assistant.
      Reinstalling against retained objects creates a new installation identity
      and requires fresh pairing; old mappings cannot silently bind to it.

## Phase 7 — live evidence

- [ ] T032 AC-11: produce
      `specs/010-multi-cloud-storage/evidence/home_assistant/<yyyy-mm-dd>-base_operations.json`
      in spec 010's fixed schema — `present`, `sanitized: true`, with at least one
      counter-probe.
- [ ] T033 AC-11: produce the matching `single_file` artifact from a probe that
      kills Home Assistant during create and during replace at each injectable
      phase, restarts, downloads the mapped object and opens it with a
      KeePass-compatible implementation. Every phase exposes either the old or the
      new complete object, never partial bytes and never a duplicate logical
      object.
- [ ] T034 AC-11: both artifacts pass spec 010's structural validator and its
      forbidden-key scan. The optional capability set stays empty: confidence in
      `os.replace` is not evidence for `atomicCreateIfAbsent`.

## Phase 8 — Dart adapter and pairing client

- [ ] T035 FR-3: add `home_assistant_storage_api_data_source.dart` and
      `home_assistant_pairing_service.dart` under
      `lib/features/password_manager/data/`, and
      `home_assistant_storage_provider.dart` implementing spec 010's port with
      stable id `home_assistant`, installation-bound opaque IDs, a fixed
      `Home Assistant` account label with no user identity, and no KDBX parsing.
- [ ] T036 FR-3/AC-5: map every row of the spec's HTTP-condition table to its
      `CloudStorageErrorCode`, and implement the `contentChecksum: null` fallback
      to spec 010's download-and-hash.
- [ ] T037 FR-4/FR-8: add `home_assistant_provider_config.dart` for base URL,
      storage-token reference and installation identity — global, single-instance,
      and never a mapping field. The token itself lives in the existing secure
      storage; it never enters the config model, mapping JSON, `props`,
      `toString`, clipboard, crash reports or logs.
- [ ] T038 AC-6: HTTPS-only in production with normal certificate and hostname
      validation — no trust-all callback, no pin bypass, no persisted exception.
      Redirects may not change origin. Plain HTTP is permitted only for automated
      loopback tests.
- [ ] T039 FR-4: `POST /unpair` on disconnect, erasing the local token only after
      the server confirms the slot can no longer authenticate; on transport
      failure erase the local token and instruct the user to revoke the slot in
      Home Assistant. Storage tokens never refresh: an authorization failure
      requires fresh pairing and is never replayed.
- [ ] T040 AC-5: create and replace retry only when the client can determine no
      request body bytes were dispatched. A failure after dispatch is ambiguous
      and enters spec 008 recovery; it is never blindly replayed.
- [ ] T041 AC-6: token-sentinel tests proving the plaintext storage token is
      absent from every log, state, error message, serialized mapping and test
      artifact.
- [ ] T042 AC-7/AC-10: an object UUID from one installation cannot execute against
      another — a mismatch returns `notFound` with zero writes. Changing the base
      URL disconnects first, rewrites no mapping, and leaves existing mappings
      visible but disabled until fresh pairing proves the same installation
      identity.

## Phase 9 — resolver, DI and provider choice

- [ ] T043 FR-5: add the resolver — a constructor-injected map of exactly two
      entries looked up by exact persisted `providerId`. No discovery, no
      reflection, no dynamic loading, no service-locator access inside it and no
      fallback provider.
- [ ] T044 FR-5/AC-8: an unknown provider id returns spec 010's
      `unsupportedProvider` and performs no auth, remote I/O, local write, backup
      or mapping mutation. Architecture tests prove exactly two implementations
      and that no provider SDK type reaches presentation.
- [ ] T045 FR-5: register both providers and the resolver in DI; the orchestrator
      and repository resolve per mapping instead of holding one provider.
- [ ] T046 FR-6: add one accessible provider choice to the existing connect/link
      sequence in the current coordinators. Once a database is linked its provider
      is read-only; switching requires unlinking and explicitly linking another
      remote, deleting and migrating no bytes.
- [ ] T047 Principle IV: add the golden inventory for the new surfaces —
      `sync_provider_choice_{390x844,1024x768}_{light,dark}.png` and
      `ha_pairing_form_{390x844,1024x768}_{light,dark}.png` — and record it in
      `spec.md`. Widget assertions, not goldens, cover each safe error code
      rendering its fixed message, the disabled foreign-instance mapping row and
      the read-only provider indicator on a linked database.
- [ ] T048 FR-8: the pre-pairing UI states that Home Assistant receives only the
      encrypted `.kdbx`, and the UI shows fixed provider-neutral safe errors only.

## Phase 10 — sync safety and Google regression

- [ ] T049 FR-7/AC-12: spec 008 convergence, writer routing, backup, mutex,
      ambiguous recovery and conflict suites pass with Home Assistant fakes. This
      adapter adds no local write path.
- [ ] T050 AC-12: the live two-client contention probe — synchronized
      replace/read-back interleavings, disconnect after body dispatch, Home
      Assistant restart — demonstrating honest ambiguous outcomes, retained local
      state, no partial remote bytes and eventual spec 008 convergence. Fake
      provider and model tests do not substitute for it.
- [ ] T051 AC-9: existing Google provider characterization and goldens stay
      behaviourally unchanged and byte-identical.
- [ ] T052 AC-16: near-limit tests on Android and iOS syncing a generated 64 MiB
      object while recording peak RSS and process survival. If either device class
      cannot complete safely, the release lowers the fixed app and server limit;
      the test is never waived and a larger object is never silently uploaded.

## Phase 11 — manual matrices

- [ ] T053 AC-13: five client platforms — Android, iOS, macOS, Windows, Linux —
      each independently recording setup, pair, create, restart, list, download,
      local-only sync, remote-only sync, conflict, auto-sync, revoke/reconnect and
      KeePass-openability. One platform never qualifies another. Every `not-run`
      carries approver, date and a concrete release reason.
- [ ] T054 AC-14: two server runtimes — Home Assistant OS and Home Assistant
      Container — as independent rows, each against the latest stable release at
      implementation freeze and its immediately previous monthly stable. Core and
      Supervised stay unsupported until separately executed. Artifacts record
      exact versions; oldest and latest cannot be inferred from one another.
- [ ] T055 AC-13/AC-14: all manual evidence contains no URL, user, token, path,
      object ID or name, or vault bytes.

## Phase 12 — packaging, release and closing checks

- [ ] T056 Add `home_assistant/README.md` and
      `specs/012-home-assistant-object-storage/quickstart.md` covering versioned
      archive install, upgrade, config entry and options-flow pairing. Both carry
      the two required disclosures: Home Assistant backups will contain the
      encrypted KDBX objects, and a custom reverse proxy configured to log
      authorization or identity headers violates FR-8.
- [ ] T057 Build and version the companion archive in the release pipeline, and
      ship it together with app support. Either side alone reports unsupported
      protocol and writes nothing. The compatibility check compares the protocol
      version from T006, not the archive version.
- [ ] T058 Verify the backout path: new links disabled, provider settings and a
      minimal disconnect/revoke path retained until every stored token is remotely
      revoked and locally erased. Mappings, local vaults and remote objects remain;
      backout never rewrites or deletes `.kdbx` data and never converts a mapping
      to Google.
- [ ] T059 AC-15 regression gate: `ruff check home_assistant`,
      `mypy home_assistant/custom_components/keyvault_storage`,
      `pytest home_assistant/tests`, `dart format`, `flutter analyze` and the full
      `flutter test` including goldens, all clean. Exact commands recorded in the
      pull request.

## Deferred and non-DoD

Plain bullets on purpose. Not scheduled work; never convert these to checkboxes.

- Flutter web support. Out of scope for the first delivery; the five native
  platforms are required.
- HACS publication or Home Assistant Core inclusion. Initial distribution is a
  versioned archive with manual custom-component install.
- Multiple Home Assistant instances in one Custode installation.
- Automatic Google-to-Home-Assistant migration or provider switching.
- Remote delete, rename, folders, sharing, browser editing and public download
  links.
- Home Assistant entities, sensors, services, automations or change events for
  vault activity. They would create unnecessary metadata exposure.
- Home Assistant add-on, Samba, WebDAV, MQTT or network-share transports, and any
  Nabu Casa dependency.
- Using Home Assistant core REST, state, event, recorder, media or backup APIs as
  an object store.
- The optional capabilities `conditionalWrite`, `versionHistory`,
  `atomicCreateIfAbsent` and `changeNotification`. Each requires separate
  real-service evidence and an immutable `VerifiedCapability`; none is ever
  upgraded by unit tests or source inspection.
