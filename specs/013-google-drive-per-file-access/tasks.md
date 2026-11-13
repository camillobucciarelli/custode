# 013 — Tasks

Ordered tasks. Each names owner, files and verification. Gate 0 runs as two
checkpoints, because one of its criteria cannot be observed until Phase 1 exists.

- **Gate 0-A** is Phase 0, criteria 1–10. Purely technical: it needs no branding,
  no verified domain and no live site. It must pass on every Gate 0 target before
  Phase 1 starts and before any production task starts.
- **Gate 0-B** is criterion 11, the original symptom. It can only be observed once
  Phase 1 has published the site, verified the domain and published the branding,
  so it runs immediately after Phase 1. It is blocking, not optional and not a
  nice-to-have: no Phase 2 or later task starts until it passes.

Deferred and non-DoD items at the bottom are plain bullets on purpose. They are
not checkboxes and must never become checkboxes, because the roadmap sync counts
every checkbox line as scheduled work.

## Phase 0 — Gate 0-A technical feasibility spike (criteria 1–10)

- [ ] **T001 Prepare spike branch and throwaway accounts** — owner:
  `senior-flutter-dev`  
  Files: spike branch only; nothing under `lib/`.  
  Acceptance: a separate branch holds spike code explicitly marked non-production;
  two dedicated Google accounts exist with empty vaults and a publicly known test
  password; no real account or real vault is used.  
  Verify: branch diff touches no production path; account setup confirmed by the
  human operator.

- [ ] **T002 Prove authorization request shape** — owner: `senior-flutter-dev`  
  Files: spike branch.  
  Acceptance: Gate 0 criterion 1 — exactly `drive.file`, PKCE `S256`, validated
  `state`, `prompt=consent`, `trigger_onepick=true`, system browser, no embedded
  WebView.  
  Verify: observed on physical Android, physical iPhone and real macOS.

- [ ] **T003 Prove one-pick and per-file isolation** — owner:
  `senior-flutter-dev`  
  Files: spike branch.  
  Acceptance: Gate 0 criteria 2 and 3 — exactly one file returned; the chosen file
  is accessible; a decoy file that was not chosen is inaccessible and absent from
  every `files.list` result.  
  Verify: all three Gate 0 targets.

- [ ] **T004 Prove object operations and folder-parent assumption** — owner:
  `senior-flutter-dev`  
  Files: spike branch.  
  Acceptance: Gate 0 criteria 4 and 5 — download, update, checksum read-back and
  new-file creation succeed; creation inside the chosen folder is either verified
  or the root "My Drive" fallback is recorded as the observed outcome.  
  Verify: all three Gate 0 targets; outcome recorded as
  `folder_parent_accepted` or `root_fallback`.

- [ ] **T005 Prove restart persistence and legacy-grant isolation** — owner:
  `senior-flutter-dev`  
  Files: spike branch.  
  Acceptance: Gate 0 criteria 6 and 7 — access survives a process restart with no
  new browser interaction; a legacy full-Drive grant is ignored and an upgrade
  from a legacy build makes no Drive call before new consent.  
  Verify: all three Gate 0 targets, Android explicitly included because refresh
  persistence there is not guaranteed.

- [ ] **T006 Prove revocation and failure modes are fail-closed** — owner:
  `senior-flutter-dev`  
  Files: spike branch.  
  Acceptance: Gate 0 criteria 8 and 9 — external revocation fails safely on every
  device with mappings and vaults preserved and reconnection succeeding; cancel,
  wrong `state`, incomplete callback, no network and a file deleted after pick
  each leave no new mapping, no modified vault byte and no partially persisted
  token.  
  Verify: all three Gate 0 targets.

- [ ] **T007 Run release-build log scan** — owner: `senior-flutter-dev`  
  Files: spike branch.  
  Acceptance: Gate 0 criterion 10 — a release build's logs contain no token,
  authorization code, callback URL, `picked_file_ids` value, file ID or email.  
  Verify: scan performed against a release build, not a debug build, on all three
  Gate 0 targets.

- [ ] **T009 File the sanitized Gate 0-A feasibility report** — owner:
  `senior-flutter-dev`  
  Files: create `specs/013-google-drive-per-file-access/feasibility-report.md`.  
  Acceptance: Gate 0-A criteria 1 to 10 each recorded per platform target as
  `pass` or `fail`, with UTC date and OS/SDK version class; criterion 5 records
  `folder_parent_accepted` or `root_fallback`; no `not-run` row exists among
  them. Criterion 11 is absent at this point because Gate 0-B has not run yet,
  and its row is added by T008; that absence never counts as a pass and never
  unblocks Phase 2. The file contains no token, authorization code, client ID,
  client secret, parameterized callback URL, `picked_file_ids` value, file ID,
  folder ID, email, path or real vault bytes.  
  Verify: manual review against the forbidden-value list in `spec.md`; the file
  must not exist before the spike actually ran.

## Phase 1 — Cloud Console, site and domain prerequisites

Human-executed checklist. Every item is boolean evidence: done or not done.

- [ ] **T101 Publish the static site under `website/`** — owner:
  `senior-flutter-dev`  
  Files: new `website/` static content only.  
  Acceptance: an English homepage at `/` and a privacy policy at `/privacy`
  describing exactly the `drive.file` access model, with support email
  `camillo@bucciarelli.dev`. No analytics collecting personal data. No secrets.  
  Verify: content review; no file outside `website/` changes.

- [ ] **T102 Configure DNS and deploy `keyvault.camillobucciarelli.dev`** —
  owner: human operator.  
  Acceptance: both URLs resolve over HTTPS and serve the Phase 1 content.  
  Verify: boolean — live or not live.

- [ ] **T103 Verify the domain in Google Search Console** — owner: human
  operator.  
  Acceptance: the domain is verified for the account that owns the Cloud project,
  which is the precondition for publishing branding.  
  Verify: boolean.

- [ ] **T104 Publish OAuth branding in Cloud Console** — owner: human operator.  
  Acceptance: app name `Custode Password Manager`, compliant square logo,
  homepage and privacy URLs on the verified domain, support email set, audience
  External and status In production.  
  Verify: boolean; consent screen inspected on a non-owner account.

- [ ] **T105 Create public installed-app OAuth clients** — owner: human operator.  
  Acceptance: new clients exist for every platform, desktop as a public
  installed-app client with no secret in the runtime. No client ID or secret is
  committed to this repository.  
  Verify: boolean; secret scan of the repository stays clean.

## Gate 0-B — external consent verification (criterion 11)

Runs after Phase 1 and before Phase 2. Criterion 11 is deferred to here for one
reason only: it cannot be observed until the site is live, the domain is verified
and the branding is published, which is exactly what Phase 1 delivers. It keeps
full Gate 0 force — blocking for Phase 2 and every later phase, with no `not-run`
waiver.

- [ ] **T008 Verify clean consent screen on an external account** — owner:
  `senior-flutter-dev`  
  Files: append the criterion 11 row to
  `specs/013-google-drive-per-file-access/feasibility-report.md`.  
  Acceptance: Gate 0 criterion 11 — with the site live and branding published, an
  external non-owner account sees no "app isn't verified" warning. A `fail` here
  blocks Phase 2 onwards exactly as a Gate 0-A failure does.  
  Verify: requires T101 to T105 complete; observed on at least one Gate 0 target
  with a non-owner account and recorded as a sanitized boolean row.

## Phase 2 — OAuth least privilege

- [ ] **T201 Reduce the requested scope to `drive.file`** — owner:
  `senior-flutter-dev`  
  Files: Google auth data-layer service and the desktop PKCE service.  
  Acceptance: the built request contains exactly
  `https://www.googleapis.com/auth/drive.file`, no broader Drive scope and no
  identity scope. A test pins the exact scope string set.  
  Verify: targeted auth tests plus `flutter analyze`.

- [ ] **T202 Remove the desktop client secret from the runtime** — owner:
  `senior-flutter-dev`  
  Files: desktop PKCE service and its build-time configuration.  
  Acceptance: no build reads or embeds a client secret; PKCE `S256` and `state`
  validation are mandatory and tested; a missing verifier or mismatched `state`
  fails closed with no token persisted.  
  Verify: targeted tests; source search finds no runtime secret reference.

- [ ] **T203 Enforce system-browser-only consent** — owner:
  `senior-flutter-dev`  
  Files: auth data layer per platform.  
  Acceptance: consent opens in the system browser or an OS-provided browser tab
  on every platform; no embedded WebView path exists.  
  Verify: source review plus a guard test asserting no WebView entry point.

- [ ] **T204 Remove account email from state and UI** — owner:
  `senior-flutter-dev`  
  Files: account summary model, sync status widgets, connection surface.  
  Acceptance: the connected-account label is the generic `Google Drive connected`;
  no email is requested, stored, logged or rendered.  
  Verify: widget and state tests; string assertions updated.

## Phase 3 — Picker integration

- [ ] **T301 Define the select-one remote object contract** — owner:
  `senior-flutter-dev`  
  Files: repository port and its data implementation, aligned with spec 010's
  boundary when that has landed.  
  Acceptance: the port exposes selecting exactly one remote object, plus create,
  read, update and download by opaque ID. There is no list-all operation.
  Presentation receives no token, no `picked_file_ids` value and no provider SDK
  type.  
  Verify: architecture guard test; unit tests with a fake implementation.

- [ ] **T302 Android Picker bridge** — owner: `senior-flutter-dev` with the
  Android platform specialist.  
  Files: minimal Kotlin bridge under the existing Android source tree plus its
  Dart data-layer counterpart.  
  Acceptance: `AuthorizationRequest` with `PICKER_OAUTH_TRIGGER`,
  `setOptOutIncludingGrantedScopes(true)`, `Prompt.CONSENT`, and
  `getTokenResponseParams()["picked_file_ids"]` parsing.
  `play-services-auth >= 21.6.0` and below `22.0.0`. `google_sign_in` is not
  forked.  
  Verify: physical Android device run of the full flow.

- [ ] **T303 iOS Picker bridge** — owner: `senior-flutter-dev` with the iOS
  platform specialist.  
  Files: minimal Swift bridge over the AppAuth dependency already present
  transitively, plus its Dart counterpart.  
  Acceptance: no new Flutter plugin is added; the refresh token lives in the
  Keychain and is never exposed to Dart.  
  Verify: physical iPhone run of the full flow.

- [ ] **T304 Desktop Picker integration** — owner: `senior-flutter-dev`  
  Files: existing desktop PKCE loopback service.  
  Acceptance: the existing loopback flow is extended with `trigger_onepick=true`
  and `picked_file_ids` parsing; no new desktop dependency is added.  
  Verify: real macOS run; Windows and Linux GUI runs are covered by the Phase 6
  release gate.

- [ ] **T305 Replace the remote file list UI with the two actions** — owner:
  `senior-flutter-dev`  
  Files: the database selection and vault sync presentation surfaces.  
  Acceptance: exactly two actions are exposed — choose an existing file, and
  upload this vault as a new file. The `files.list` global list is removed from
  both the UI and the data layer. The golden inventory in `spec.md` is realised
  exactly: `db_drive_empty_390x844_light.png`,
  `db_drive_loading_390x844_light.png` and `sync_picker_390x844_light.png` are
  deleted, `db_drive_actions_390x844_light.png` is added, and the omitted axes
  named there are covered by widget assertions.  
  Verify: widget, coordinator and golden tests; no golden listed in the inventory
  is missing and none outside it is added.

- [ ] **T306 New remote file: editable name and folder destination** — owner:
  `senior-flutter-dev`  
  Files: creation coordinator path and its UI.  
  Acceptance: the default remote name is the local file name and is editable
  before upload; the destination folder is chosen through the Picker with folder
  selection enabled. If Gate 0 recorded `root_fallback`, the file is created in
  the root of My Drive and the user is told they may move it.  
  Verify: coordinator tests for both outcomes; the shipped behaviour matches the
  Gate 0 finding.

- [ ] **T307 Handle read-only and Shared Drive results** — owner:
  `senior-flutter-dev`  
  Files: selection coordinator and its error surface.  
  Acceptance: a file that cannot be modified is imported as a local copy with
  sync disabled and the reason shown. A file resolving to a Shared Drive is
  refused safely. Neither case creates a mapping claiming write access.  
  Verify: coordinator and widget tests.

## Phase 4 — Migration and revocation

- [ ] **T401 Implement the per-vault migration sequence** — owner:
  `senior-flutter-dev`  
  Files: a dedicated migration coordinator plus the sync mapping data source.  
  Acceptance: suspend sync, confirm with the user, revoke, re-consent, re-pick,
  validate, resume — in that order, preserving the existing checksum and
  timestamp baselines. The mapping is never recreated with null baselines.
  Migration is per vault, triggered on open or on sync, and multiple mappings
  migrate independently.  
  Verify: coordinator tests covering each step boundary.

- [ ] **T402 Require explicit confirmation before revoking** — owner:
  `senior-flutter-dev`  
  Files: migration coordinator UI.  
  Acceptance: the user is told, before revocation, that sync will be disconnected
  on all devices for this account. Declining leaves everything untouched.  
  Verify: widget and coordinator tests.

- [ ] **T403 Fail closed on failed or unverifiable revocation** — owner:
  `senior-flutter-dev`  
  Files: migration coordinator and auth data layer.  
  Acceptance: sync stays suspended; the user may retry or revoke manually from
  their Google Account; the old token is never reused on any path.  
  Verify: tests asserting zero requests carrying the old grant after a failed
  revocation.

- [ ] **T404 Handle a changed file ID on re-selection** — owner:
  `senior-flutter-dev`  
  Files: migration coordinator.  
  Acceptance: a re-picked file whose ID differs from the mapping requires an
  explicit confirmation before a new mapping is created. There is no implicit
  overwrite; content comparison and the safe writer both run.  
  Verify: coordinator tests for accept and decline.

- [ ] **T405 Preserve the local vault on cancel, error or offline** — owner:
  `senior-flutter-dev`  
  Files: migration coordinator.  
  Acceptance: in every abort path the local vault stays usable, sync stays
  suspended, and mapping and vault bytes are untouched.  
  Verify: coordinator tests for each abort path.

- [ ] **T406 Foreground-only reconnection** — owner: `senior-flutter-dev`  
  Files: background sync path and the migration coordinator.  
  Acceptance: reconnection is only ever requested in the foreground. Background
  sync never presents UI; it fails safe and marks the mapping as needing
  reconnection.  
  Verify: background sync tests asserting no UI trigger.

## Phase 5 — Regression and security

- [ ] **T501 Add a scope and secret guard test** — owner: `senior-flutter-dev`  
  Files: a new guard test.  
  Acceptance: the test fails if any broader Drive scope, any identity scope or any
  runtime client secret reference reappears in the source.  
  Verify: the guard fails on a deliberately reintroduced violation.

- [ ] **T502 Add a leak guard for tokens and identifiers** — owner:
  `senior-flutter-dev`  
  Files: auth, Picker and sync data-layer tests.  
  Acceptance: sentinel values injected as token, authorization code, callback URL,
  `picked_file_ids`, file ID and email are absent from every log, state, error
  message and persisted mapping.  
  Verify: sentinel assertions across each surface.

- [ ] **T503 Run the log scan on release builds** — owner: `senior-flutter-dev`  
  Files: none; evidence only.  
  Acceptance: a release build on each of the five platforms produces logs
  containing none of the forbidden values.  
  Verify: recorded as boolean per platform, no values quoted.

- [ ] **T504 Full static and test gate** — owner: `senior-flutter-dev`  
  Files: whole Dart workspace.  
  Acceptance: `dart format` clean, `flutter analyze` clean, full `flutter test`
  green, including updated goldens for the removed list UI.  
  Verify: exact commands recorded in the pull request.

## Phase 6 — Release gate and legacy cut

- [ ] **T601 Five-platform manual gate** — owner: `senior-flutter-dev`  
  Files: release evidence only; no secrets recorded.  
  Acceptance: Android, iOS, macOS, Windows and Linux each independently record
  `pass` for consent, pick, download, update, create, restart, revoke, reconnect
  and migrate. No `not-run` waiver exists. One platform's result never qualifies
  another.  
  Verify: five dated boolean rows with no token, account, path or file ID.

- [ ] **T602 Ship the atomic release** — owner: `senior-flutter-dev`  
  Files: release artifacts.  
  Acceptance: all five platforms ship together with the new clients and the
  narrow scope.  
  Verify: release workflow output.

- [ ] **T603 Cut the legacy OAuth clients** — owner: human operator.  
  Acceptance: the legacy clients are deleted or disabled before the release is
  announced. Old builds lose Drive access; their local vaults stay usable. The
  full Drive scope is never restored and no legacy client is re-enabled as a
  rollback.  
  Verify: boolean; Cloud Console state confirmed.

## Website, extension and repository archival

- [ ] **T701 Migrate the browser extension privacy policy** — owner:
  `senior-flutter-dev`  
  Files: `website/` content and the extension's privacy URL reference.  
  Acceptance: the extension privacy policy is served under
  `keyvault.camillobucciarelli.dev` and the extension references the new URL.  
  Verify: live URL check.

- [ ] **T702 Update the Chrome Web Store listing** — owner: human operator.  
  Acceptance: the listing points at the new privacy URL and the update is
  approved.  
  Verify: boolean; approval confirmed.

- [ ] **T703 Archive the `keyvault-privacy` repository** — owner: human operator.  
  Acceptance: the repository stays online until the new URL is live and the store
  listing is approved, then it is archived. It is never deleted during the
  transition.  
  Verify: boolean; archive state confirmed after T702.

## Deferred and non-DoD

Plain bullets on purpose. Not scheduled work; never convert these to checkboxes.

- Shared Drives support. Out of scope; a Shared Drive result is refused safely.
- A backend or token proxy. Explicitly rejected: the app stays device-to-Google.
- Google verification for a restricted scope. Not pursued; the narrow scope is
  the whole point of this spec.
- Restoring a broader Drive scope as a rollback. Forbidden, in every scenario.
- Provider-neutral picker abstraction for a second provider. Belongs to spec 010's
  deferred provider phase, not here.
