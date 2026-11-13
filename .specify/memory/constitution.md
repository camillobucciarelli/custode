# Custode Constitution

Non-negotiable principles every spec, plan and task in `specs/` must respect.
When a plan conflicts with this file, this file wins.

## I. Secrets never leak into the shell

Passwords, notes, OTP URIs and key-file bytes stay inside their existing secret
boundary: ephemeral input controllers/typed commands, `VaultKdbxService`,
redacted BLoC state and platform secure storage. Controllers and route results
hold plaintext only until the requested operation completes and are disposed;
secret values never enter diagnostic `props`/`toString`. Secrets are never logged
(see `RedactedValue` in `VaultEntry.props`/`toString`), written to a plaintext
cache, sent over the native-messaging bridge unless the user explicitly asked for
that specific value, or persisted by a design surface. A restyle must not widen
the surface or lifetime that holds plaintext.

## II. Clean architecture layering holds

`presentation/` → `coordinators/` → `usecases/` + `domain/services/` →
`repositories/` → `data/`. UI never touches `data/` directly. New multi-step
workflows go in a coordinator, not a BLoC and not a widget.
No new BLoC unless a spec proves the three existing ones cannot carry the state.

## III. The design tokens are the only source of colour, type and metric

Spec 001 introduces the Organic tokens without breaking untouched screens.
Compatibility aliases remain until their call sites migrate; they may not be
used by new or migrated code. After a surface migrates, it hard-codes no hex,
font family, radius or duration. It reads from `AppColors` / `AppTheme` /
`AppSpacing` / `AppRadii` / `AppMotion`. A pixel value from
`specs/_design/PIXEL_SPEC.md` uses its token wherever one exists.

## IV. Pixel fidelity is testable, not aspirational

Every screen spec lists its measurements and an exact, named golden inventory.
Responsive root layouts cover 390×844 and 1024×768 in light and dark. Additional
state variants may use a representative size/theme only when the spec names the
omitted axes and supplies widget assertions for them. Where a golden is
impractical, the spec names the exact widget assertions that replace it.

## V. Accessibility floor is part of the definition of done

Every declared text/background role pairing is ≥ 4.5:1, including secondary and
tertiary text at the smallest allowed size. Accessibility overrides handoff
colour values when they conflict; each deviation is recorded in its spec and
covered by contrast tests. Tap targets are ≥ 44×44, every focusable has a 2 px
focus ring, colour is never the only signal, and every added animation respects
`MediaQuery.disableAnimations`.

## VI. Existing behaviour and copy are preserved unless a spec marks a change

Literal user-facing strings that exist today ("Copied password.",
"Empty bin (n)", the Italian browser-setup labels) stay byte-identical. Design
items labelled *Proposal* in `specs/_design/HANDOFF.md` are opt-in scope: they
are called out explicitly in the spec that adopts them, never smuggled in.

## VII. Destructive and irreversible operations ask first and back up

Merges, imports, "empty bin", "replace existing" and master-password changes
write a dated local copy before touching the `.kdbx`, and state in the UI what
is about to be lost.

## VIII. Ship the smallest thing that satisfies the spec

No speculative abstraction with one implementation, no config for a constant,
no widget library beyond what the screens in scope need. Domain repository/port
abstractions and platform trust-boundary adapters required to enforce Principle
II are explicitly exempt: their purpose is dependency direction and isolation,
not speculative polymorphism, even when only one data implementation exists.
One-implementation UI routers, coordinators and services remain concrete unless
another implementation is required now. Shared widgets are extracted on the
second use, not the first.

## IX. Verification is local, before the push

`flutter analyze` clean and `flutter test` green before any commit. CI runs no
tests. `pubspec.yaml: version:` is never hand-edited — the release workflow owns it.

## Governance

Specs live in `specs/NNN-slug/` with `spec.md` (what + why + acceptance),
`plan.md` (how + files touched) and `tasks.md` (ordered, checkable work).
Specs 001 and 002 are prerequisites for UI integration in 003–006 and 007B.
Spec 007A is limited to deterministic generation and review of icon assets and
may run independently; launcher, in-app and badge integration is 007B and waits
for 001/002. Specs 008 and 009 are new features and additionally carry
`data-model.md`.

**Version**: 1.1.2 · **Ratified**: 2026-08-05 · **Amended**: 2026-08-05
