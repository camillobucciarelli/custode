# 012 — Implementation plan

## Delivery strategy

Two artifacts ship together and neither is useful alone: a Python custom
integration that runs on the user's Home Assistant host, and a Dart adapter that
speaks to it. The plan builds them in that order — server first, with its own
protocol and filesystem tests, before any app wiring exists — because the server
owns every invariant that cannot be retrofitted: atomic commit, bounded input,
credential lifecycle and restore semantics. An adapter written against a server
that is not yet fail-closed will encode the server's bugs as client workarounds.

This is the first spec in the repository that ships production code in a second
language and a second deployable. That is the dominant risk, and the plan treats
the companion as its own project with its own gate rather than as a folder inside
the Flutter app.

The order below is the spec's §Rollout list, kept as-is. What this plan adds is
where each piece lands, which gates are load-bearing, and the three places where
existing repository conventions do not yet cover what this spec needs.

**Owner agents**: `senior-flutter-dev` (Dart adapter, resolver, DI, provider
choice). The companion integration is Python/`aiohttp` on the Home Assistant
host — no existing agent covers it; it is authored by `senior-flutter-dev` with
`senior-tester` owning its fault-injection and attack matrices, or by a
Python-capable operator. `senior-tester` owns the live probes, the five-platform
client matrix and the two-runtime server matrix. Platform specialists are needed
only if secure-token persistence requires native work, which it should not:
`flutter_secure_storage` already covers all five targets.

## Constitution Check

Checked against `.specify/memory/constitution.md` v1.1.2. No gate is violated. One
governance gap is recorded below rather than waived.

| Principle | Verdict | Evidence |
| --- | --- | --- |
| I — Secrets never leak into the shell | PASS | The companion stores opaque encrypted bytes and never receives the master password or key file (spec §Summary). The storage token lives only in `flutter_secure_storage`, is returned once, and is forbidden from mapping JSON, `props`, `toString`, clipboard, crash reports and logs (§Authentication rule 7). FR-8 extends the boundary to the companion's own logs and to validated default Home Assistant access logs; the opaque remote ID and display name are admitted to provider models and mappings only, never to diagnostics. AC-6 asserts token-sentinel absence. |
| II — Clean architecture layering holds | PASS | `HomeAssistantStorageProvider` is a data adapter behind spec 010's `CloudStorageProvider`; pairing and HTTP are data sources it composes. `DatabaseSyncRepository` stays the application boundary; presentation receives no adapter, HTTP response, token or SDK type (§Application rules 2–3). Connect/choose/link/disconnect sequencing stays in the existing coordinators; BLoCs stay event/state translation (rule 6). No new BLoC. |
| III — Design tokens | PASS | The one new surface — the provider choice plus the pairing form — reads from `AppColors`/`AppTheme`/`AppSpacing`/`AppRadii`/`AppMotion`. No hex, family, radius or duration is hard-coded. |
| IV — Pixel fidelity is testable | PASS | The provider choice and the pairing screen are new surfaces and therefore owe a named golden inventory at 390×844 and 1024×768, light and dark, plus widget assertions for the error and disabled-mapping states. That inventory does not exist in `spec.md` and is a gap this plan closes — see *Gaps this plan closes*, item 2. |
| V — Accessibility floor | PASS | FR-6 requires the provider choice to be accessible; the inventory above carries the contrast, 44×44, focus-ring and colour-is-not-the-only-signal assertions, and the pairing-code field must remain usable with a screen reader without ever announcing the code into a log. |
| VI — Copy preserved unless a spec marks a change | PASS | Purely additive. Google Drive remains available and unchanged (§Product behavior 1), and AC-9 requires the existing Google characterization to stay behaviourally unchanged. No existing literal moves. New copy: the provider choice, the pairing flow, the pre-pairing explanation (§Product behavior 7), the backup-propagation disclosure and the fixed safe errors. |
| VII — Destructive operations ask first and back up | PASS | Unlinking removes only the local mapping and never the remote object (§Product behavior 6). Removing provider configuration deletes no mapping and no object. Removing the config entry does not delete objects without a separate explicit confirmation inside Home Assistant, which is outside Custode's API. Backout never rewrites or deletes `.kdbx` data. Spec 008's mutex, backup, write-verify-converge and ambiguous-recovery invariants are preserved (Goal 3, FR-7). |
| VIII — Ship the smallest thing | PASS | The resolver is the one piece of new infrastructure, and spec 010's plan explicitly deferred it until "a real provider is selected and spiked" — this spec is that revision. It is a constructor-injected two-entry lookup on an exact `providerId`: no discovery, reflection, dynamic loading, service-locator access or fallback (§Application rule 4). The optional-capability set ships empty. The companion's minimum package is seven files. Web is out of scope for the first delivery. |
| IX — Verification is local | PARTIAL — see gap 1 | `flutter analyze` and full `flutter test` run before commit as always. But AC-15 also requires companion Python lint, type checks and tests, and the constitution's Principle IX names only the Flutter gate. The repository has Python (`tool/build_app_icon_family.py` and its test) but no `pyproject.toml`, no ruff/mypy configuration and no CI or documented local invocation for it. This plan adds that toolchain rather than assuming it; see *Gaps this plan closes*, item 1. |

### Phase 0 / Phase 1 artifacts

`research.md` is not generated. `spec.md` carries no `[NEEDS CLARIFICATION]`
marker, and the one genuinely open technical question — whether Home Assistant
exposes a restore-lifecycle signal reliable enough to implement §Authentication
rule 13 — is empirical, not a literature question. It is answered by the Gate S0
spike below and recorded as evidence, exactly as spec 013 handles its two
empirical unknowns. If no reliable signal exists, the spec's own answer applies:
that runtime is unsupported and the provider stays disabled there.

`data-model.md` is not generated: the constitution requires it only for specs 008
and 009, and this spec adds no domain entity. It consumes spec 010's
provider-neutral models unchanged and adds provider *configuration* (base URL,
token, installation identity), which is explicitly not a mapping field
(§Mapping and configuration).

`contracts/` is not generated **as a document**, for the usual reason — the route
table, the metadata JSON shape and the error mapping are already normative in
`spec.md` §Binary API v1, and a third copy would drift from the two that bind.
But this spec is the first where two independently-built implementations must
agree, so the contract gets a *code* single-source instead: one protocol-version
constant and one route-path list, declared once per side, with a contract test
that fails when the two sides disagree. That is stricter than a Markdown copy and
cannot go stale silently.

`quickstart.md` **is** generated here, and is the one artifact exception across
these plans. The companion is installed by a human on a machine this repository
does not control: a versioned archive, a manual custom-component install, a
config entry, an options-flow pairing code. AC-1 and the server matrix are
unrunnable without written setup steps, and those steps have no other home —
they are not app validation commands and do not belong in `tasks.md`. It also
carries the two disclosures the spec requires operators to see: that Home
Assistant backups will contain the encrypted KDBX objects, and that a custom
reverse proxy configured to log authorization headers breaks FR-8.

## Gaps this plan closes

Three things this spec needs that the repository does not currently provide.

**1. A Python gate (AC-15).** Add `home_assistant/pyproject.toml` configuring
ruff and mypy over `custom_components/keyvault_storage/`, and pytest for its
tests. Add a `home_assistant` job to the PR workflow running all three. Existing
`tool/*.py` stays out of scope — widening the gate to it is a separate change.
Without this, AC-15 is a sentence no command satisfies.

**2. A golden inventory for the new surfaces (Principle IV).** `spec.md` names no
goldens. The constitution requires every screen spec to list its measurements and
an exact, named golden inventory. This plan declares it below; if the surfaces
change shape during implementation, the inventory is updated in `spec.md`, not
quietly dropped.

**3. Companion release mechanics.** §Rollout item 8 requires the companion
archive and the app to ship together, and the backout path requires an old
companion to report unsupported protocol rather than misbehave. Nothing in
`release.yml` builds or versions a Python archive today. The companion's version
and its protocol version are two different numbers and must not be conflated: the
archive version moves on any companion change; the protocol version moves only on
a wire-contract change, and it is the value the compatibility check compares.

## Dependency and safety gates

1. **Spec 010 lands first, completely.** This spec consumes `CloudStorageProvider`,
   the provider-neutral models, the safe-error taxonomy, the mapping schema and
   `(providerId, remoteFileId)` identity. Do not start the adapter against a
   half-migrated port. Spec 010's own plan defers the resolver to "a new plan
   revision after a real provider is selected and spiked" — this document is that
   revision, and the resolver is added here, not there.
2. **Spec 008 invariants are preserved, not re-implemented.** The mutex, backup,
   safe writer, write-verify-converge and ambiguous-write recovery stay exactly as
   they are (Goal 3, FR-7, AC-12). This adapter adds no local write path.
3. **Evidence gates the ship, and unit tests cannot substitute for it.** Live
   `base_operations` and `single_file` artifacts must exist under
   `specs/010-multi-cloud-storage/evidence/home_assistant/` in spec 010's fixed
   schema, `present`, sanitized, with at least one counter-probe, and must pass
   010's structural validator. The optional capability set ships empty:
   confidence in `os.replace` is explicitly not evidence for
   `atomicCreateIfAbsent` (§Provider capabilities).
4. **Ambiguity is never resolved by replay.** Create/replace retry is allowed only
   when the client can prove no body bytes were dispatched. A failure after
   dispatch enters spec 008 recovery. Storage tokens do not refresh; an
   authorization failure requires fresh pairing and is never replayed.
5. **Restore is a hard boundary.** Until the credential reset of
   §Authentication rule 13 completes, every route including `/pair` returns a
   fixed `503`. No token from before or from inside the restored backup may
   authenticate even transiently. A runtime without reliable restore detection is
   unsupported and keeps the provider disabled — that is a shipping decision, not
   a TODO.
6. **HTTPS only in production.** No trust-all callback, no pin bypass, no
   persisted certificate exception, no origin-changing redirect. Plain HTTP exists
   only for automated loopback tests.
7. **Order against 013 and 014.** 013 changes Google authorization and selection;
   014 moves and encrypts local storage and re-keys `sync_mappings.json`. All
   three touch the sync metadata data source or the provider port. 012 is last in
   the queue and rebases onto whatever has landed; it does not respecify any of
   them.

## Gate S0 — restore-signal and platform spike

Before the companion's credential-reset code is designed, prove on a real Home
Assistant OS instance and a real Container instance that a backup restore is
detectable through a supported platform lifecycle signal, early enough to block
view activation. Record the observed signal per runtime.

A negative result is a valid, conservative outcome and is recorded as such: that
runtime becomes unsupported (§Authentication rule 13), and the plan proceeds for
the runtime that passes. Do not design a heuristic that infers restore from
timestamps or file mtimes — that is exactly the "resurrect a revoked credential
hash" risk the spec names.

## M1 — companion integration, no app wiring

New tree, deployable on its own:

```text
home_assistant/
  pyproject.toml                      # gap 1: ruff + mypy + pytest
  README.md                           # install/upgrade, not the app's docs
  custom_components/keyvault_storage/
    manifest.json
    __init__.py                       # setup/unload/reload, restore reset, route registration once
    config_flow.py                    # single config entry, options flow, pairing-code generation
    http.py                           # the eight views, custom auth guard, streaming, bounded parsing
    store.py                          # atomic object store, catalog lock, quota, stale-temp cleanup
    protocol.py                       # protocol version + route paths — the shared contract source
    translations/en.json
  tests/
```

Implementation order inside M1, because each step is the precondition of the
next:

1. `store.py` — temp/flush/fsync/atomic-install/verify, per-object write
   serialization, store-wide catalog lock for identity allocation and the 1,000
   boundary, startup stale-temp cleanup. Fault injection at every write phase
   comes with this file, not after it.
2. Path and input hardening — traversal, symlink, hard link, directory, device
   file, malformed and foreign IDs, name rules, 180-byte name bound, 64 MiB
   streamed body bound that a dishonest or missing `Content-Length` cannot
   bypass.
3. `config_flow.py` — one entry per instance, 256-bit pairing code shown once,
   hash-only persistence, five-minute expiry, single use, 20 slots, one pending
   code per slot, slot listing by random short label and creation time only.
4. `http.py` — `requires_auth = false` on every protected view plus the custom
   guard, which runs *before* identity, name or body parsing and touches no disk.
   Bearer only: query-string tokens, cookies, signed paths and Home Assistant
   user tokens are rejected. Constant-time hash comparison. Rate limiting whose
   attempt count and next-allowed UTC instant persist atomically with the pending
   code's hash, so a restart does not reset it.
5. `__init__.py` — integration-level route registration exactly once;
   config-entry setup creates and verifies the storage directory and only then
   publishes the runtime store; missing/failed/unloaded/reloading entry returns
   fixed `503` without touching disk; repeated setup/unload/reload duplicates no
   route and retains no old store.
6. Restore reset per Gate S0's finding, blocking every route until it completes.

Gate: AC-1 to AC-4 and AC-17. Fixed machine codes and fixed safe messages in
every failure response — no exception, traceback, absolute path, Home Assistant
user ID, token, body, object bytes, remote ID, display name or host. The
integration never logs request headers or bodies.

## M2 — live evidence

Produce the two required spec 010 artifacts before the adapter exists, so the
adapter is written against observed behaviour rather than intent:

```text
specs/010-multi-cloud-storage/evidence/home_assistant/<yyyy-mm-dd>-base_operations.json
specs/010-multi-cloud-storage/evidence/home_assistant/<yyyy-mm-dd>-single_file.json
```

The `single_file` probe kills Home Assistant during create and during replace at
each injectable phase, restarts, downloads the mapped object and opens it with a
KeePass-compatible implementation. Every phase must expose either the old or the
new complete object — never partial bytes and never a duplicate logical object.

Gate: AC-11, plus spec 010's structural validator, plus the forbidden-key scan.

## M3 — Dart adapter and pairing

### Add

```text
lib/features/password_manager/data/datasources/home_assistant_storage_api_data_source.dart
lib/features/password_manager/data/services/home_assistant_pairing_service.dart
lib/features/password_manager/data/services/home_assistant_storage_provider.dart
lib/features/password_manager/domain/models/home_assistant_provider_config.dart
```

Provider configuration — base URL, storage token reference, installation identity
— is global, single-instance, and is **not** a mapping field. The token itself
lives in `flutter_secure_storage` via the existing `SecureDataSource` pattern,
never in the config model.

`HomeAssistantStorageProvider` implements spec 010's port with stable id
`home_assistant`, the exact error mapping of §Binary API v1, installation-bound
opaque IDs, the `contentChecksum: null` fallback to 010's download-and-hash, a
fixed `Home Assistant` account label with no user identity, and no KDBX parsing.

Changing the base URL disconnects first and rewrites no mapping. Existing
mappings stay visible but disabled until the new origin is freshly paired and
proves the same installation identity; a different instance returns `notFound`
and never inherits them (AC-7, AC-10).

Gate: AC-5, AC-6.

## M4 — resolver, DI and provider choice

### Add

```text
lib/features/password_manager/domain/repositories/cloud_storage_provider_resolver.dart
lib/features/password_manager/data/services/cloud_storage_provider_resolver_impl.dart
```

Constructor-injected map of exactly two entries, looked up by exact persisted
`providerId`. No discovery, no reflection, no dynamic loading, no service-locator
access inside it, no fallback provider. An unknown id returns spec 010's
`unsupportedProvider` and performs no auth, remote I/O, local write, backup or
mapping mutation.

### Change

DI registers both providers and the resolver; the orchestrator and repository
resolve per mapping instead of holding one provider. The existing coordinators
gain the provider choice in the connect/link sequence. Once a database is linked
its provider is read-only: switching requires unlinking and explicitly linking
another remote, with no byte deleted or migrated (FR-6).

### Golden inventory (gap 2)

New goldens, at 390×844 and 1024×768, light and dark:

```text
sync_provider_choice_{390x844,1024x768}_{light,dark}.png
ha_pairing_form_{390x844,1024x768}_{light,dark}.png
```

Widget assertions, not goldens, for: pairing error states (each safe error code
renders its fixed message), the disabled foreign-instance mapping row, and the
read-only provider indicator on a linked database.

Gate: AC-8, plus AC-9 — the existing Google characterization and its goldens stay
byte-identical.

## M5 — safety, regression and the two manual matrices

### Targeted commands

```bash
# companion
ruff check home_assistant
mypy home_assistant/custom_components/keyvault_storage
pytest home_assistant/tests

# app
dart format lib test
flutter analyze
flutter test test/features/password_manager/data/services/home_assistant_storage_provider_test.dart
flutter test test/features/password_manager/data/services/cloud_storage_provider_resolver_test.dart
flutter test test/features/password_manager/data/architecture/cloud_storage_provider_architecture_test.dart
flutter test test/features/password_manager/data/services/database_sync_orchestrator_test.dart
flutter test test/features/password_manager/data/services/database_writer_lock_routing_test.dart
flutter test test/features/password_manager/data/services/sync_merge_convergence_model_test.dart
flutter test test/features/password_manager/presentation/coordinators
flutter test test/goldens
flutter test
```

### Live probes — not substitutable by fakes

- the two-client contention probe: synchronized replace/read-back interleavings,
  disconnect after body dispatch, Home Assistant restart. It must show honest
  ambiguous outcomes, retained local state, no partial remote bytes and eventual
  spec 008 convergence (AC-12).
- the 64 MiB near-limit test on Android and iOS, recording peak RSS and process
  survival. If either device class cannot complete safely, the release **lowers
  the fixed app and server limit**. It never waives the test and never silently
  uploads a larger object (AC-16).

### Manual matrices

Five client platforms — Android, iOS, macOS, Windows, Linux — each recording its
own `pass`/`fail`/`not-run` for setup, pair, create, restart, list, download,
local-only sync, remote-only sync, conflict, auto-sync, revoke/reconnect and
KeePass-openability. One platform never qualifies another (AC-13).

Two server runtimes — Home Assistant OS and Home Assistant Container — as
independent rows, each against the latest stable release at implementation freeze
**and** its immediately previous monthly stable. Core and Supervised stay
unsupported until separately executed; shared Python code does not imply
compatibility (AC-14). Every `not-run` carries approver, date and a concrete
release reason. Evidence contains no URL, user, token, path, object ID or name,
or vault bytes.

## Rollout and backout

Companion archive and app support ship together; either side alone reports
unsupported protocol and writes nothing. That check compares the *protocol*
version, not the archive version (gap 3).

Backout disables new Home Assistant links but retains provider settings and a
minimal disconnect/revoke path until every stored token is remotely revoked and
locally erased. `POST /unpair` confirms success only after removing the matching
server hash; on transport failure the build erases the local token and directs
the user to revoke that slot from the Home Assistant options flow. Mappings,
local vaults and remote objects remain. Backout never rewrites or deletes `.kdbx`
data and never converts a mapping to Google.

## Deferred implementation plan

Flutter web, HACS publication or Home Assistant Core inclusion, multiple Home
Assistant instances, remote delete/rename/folders/sharing, Home Assistant
entities or automations for vault activity, and any optional capability
(`conditionalWrite`, `versionHistory`, `atomicCreateIfAbsent`,
`changeNotification`) are out of scope. A capability is added only when separate
real-service evidence proves it and the code exposes an immutable
`VerifiedCapability`; no capability is ever upgraded by unit tests or source
inspection.
