# 016 — Research

Phase 0 output. Each item records a decision with the alternatives that were on
the table and why they lost. Empirical questions that a document cannot answer
are deferred to the Phase 0 device gate and named as such.

## R1 — Authentication API for releasing a secret

**Decision**: `androidx.biometric.BiometricPrompt` with
`setAllowedAuthenticators(BIOMETRIC_STRONG or DEVICE_CREDENTIAL)`, hosted by a
`FragmentActivity`.

**Rationale**: The app's `minSdk` is 29, and the platform split its
device-credential fallback between `setDeviceCredentialAllowed` (deprecated at
30) and `setAllowedAuthenticators` (added at 30). The AndroidX wrapper collapses
that into one call and one behaviour, and `MainActivity` is already a
`FlutterFragmentActivity`, so the pattern is not new to the module.

**Alternatives considered**:

- *Framework `android.hardware.biometrics.BiometricPrompt`*: no new dependency,
  but the 29-vs-30 branch and its deprecation warnings become our code, for a
  saving of one AndroidX artifact.
- *`KeyguardManager.createConfirmDeviceCredentialIntent`*: zero dependencies and
  the smallest diff, but it only ever offers PIN/pattern/password. Users with a
  fingerprint enrolled would be asked for a PIN on every fill, which is exactly
  the friction that makes people disable autofill.
- *Keystore `setUserAuthenticationRequired` on the cache key*: enforces
  authentication cryptographically rather than by control flow. Rejected for this
  cut because it re-keys the existing sealed cache and would migrate every
  installed user's store; the control-flow gate plus the existing Keystore key is
  the smaller change. Recorded as a possible hardening follow-up.

## R2 — Reuse window for a successful authentication

**Decision**: a `lastAuthenticatedAtEpochMs` timestamp in the existing plaintext
metadata file, compared against an `authSessionTtlMs` value published by the
Flutter side from the spec 011 master-password session scope. `0` means
authenticate every time.

**Rationale**: The reuse window is a policy the vault owns, not a constant the
Android module should invent, and spec 011 already defines that policy. A
timestamp is not a secret, so it needs no new sealed storage, and clearing the
cache clears it.

**Alternatives considered**:

- *A hard-coded window in Kotlin*: config-free, but it would silently disagree
  with the session scope the user configured in the app.
- *No reuse at all (prompt every fill)*: strictly safer, and it is still
  reachable by publishing `0`. Not the default, because filling a username field
  and then a password field would prompt twice for one login.

## R3 — Inline suggestions

**Decision**: `androidx.autofill`'s `InlineSuggestionUi` content builder,
gated on `FillRequest.getInlineSuggestionsRequest()` being non-null (API 30+),
with one dataset per ranked match plus a trailing "Search Custode" dataset.

**Rationale**: The platform's inline contract is a `Slice` with a specific,
undocumented-by-hand structure; the AndroidX builder is the supported way to
produce it. The request object also carries the IME's advertised maximum
suggestion count and its style spec, both of which FR-006 needs.

**Alternatives considered**:

- *Hand-built `Slice`*: no dependency, but couples us to an internal layout
  contract with no compile-time check.
- *One inline dataset that opens the picker*: trivial, but it saves no taps —
  which is the entire point of FR-004.

**Deferred to the device gate**: how many slots real IMEs advertise, and whether
third-party IMEs render our style consistently (Phase 0 T001).

## R4 — Save capture transport

**Decision**: keep the captured credential in a process-local holder keyed by an
opaque token; only the token travels in the `Intent`.

**Rationale**: `AutofillService` and the app's activities run in the same process
by default, so a shared in-memory holder is available and costs nothing.
`Intent` extras, by contrast, pass through the system server and can surface in
`ActivityManager` diagnostics — a plaintext password there violates Principle I.

**Alternatives considered**:

- *Password in an `Intent` extra*: simplest, and disqualified by Principle I.
- *Encrypted pending-capture file*: survives process death, and creates a second
  at-rest secret surface for a case the unlock screen already covers
  (Constitution VIII, spec decision SD2). A capture lost to process death is an
  acceptable outcome; a leaked one is not.

## R5 — Browser coverage

**Decision**: declare `<compatibility-package>` entries for `com.android.chrome`
and `org.mozilla.firefox` in the autofill service resource.

**Rationale**: Without compatibility mode the browsers' form fields are not
exposed as fillable structure at all, which is why autofill in mobile browsers
does nothing today. The matching half — `webDomain` extraction and domain
normalization — is already implemented and currently unreachable.

**Alternatives considered**:

- *A broad browser list (Edge, Brave, Opera, Samsung Internet, Vivaldi)*: more
  coverage, but each entry needs its own version verification and the list rots
  between releases. Deferred until the two-browser path is proven (spec SD3).
- *Relying on browsers' own autofill integration*: not under our control, and
  inconsistent across versions.

**Deferred to the device gate**: current Chrome and Firefox versions actually
exposing a readable `webDomain` under compatibility mode (Phase 0 T002).

## R6 — Design tokens on a native Android surface

**Decision**: mirror the token values into Android resources and add a Dart test
that fails when the mirror drifts from `AppColors`.

**Rationale**: The picker is a native Android surface and cannot read Flutter
tokens, but Constitution III forbids a surface that hard-codes its own colours.
A checked mirror is the only way to satisfy both.

**Alternatives considered**:

- *Rendering the picker in Flutter*: full token access, but it means starting a
  Flutter engine inside an autofill fill request — heavy, slow, and it puts the
  vault app's whole surface behind an OS-invoked activity.
- *Hand-copying values with a comment*: what drift looks like before it is
  noticed.
