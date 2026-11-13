# Implementation Plan: Dark mode verification

**Branch**: `fix/022-dark-mode` (only if a fix is needed) | **Date**: 2026-08-31 | **Spec**: `spec.md`

## Summary

A manual dark-mode walk of every journey on phone and desktop, six screens
against the `14 Dark mode` artboard and the rest against the handoff's dark
rule. Findings become fix tasks appended to `tasks.md`; nothing is built up
front.

## Technical Context

Dark values live in `lib/core/theme/custode_colors.dart` (`CustodeColors.dark`)
and `app_colors.dart`; `ThemeCubit` switches Light / Dark / System. Contrast
and role tables are already pinned by `test/core/theme/app_theme_test.dart`.
Dark goldens exist for 20 screens (`test/goldens/*_dark.png`), none at
1024×768 for entry detail, health, settings, sync.

## Constitution Check

| Principle | Status |
|---|---|
| III tokens | any fix reads tokens only; a wrong dark value is fixed in `CustodeColors.dark`, not at the call site |
| IV pixel fidelity | each fix names the dark golden it re-records; missing 1024 dark goldens are listed, not silently skipped |
| V a11y | any changed dark pair re-runs the contrast test |
| VI copy | none |
| VIII | no work before a finding |

No research/data-model/contracts: verification, not construction.

## Method

Run `flutter run --dart-define-from-file=.env.dart.define.json` on macOS (window
≥ 1024 and resized to phone width) with Settings › Appearance = Dark. For each
task tick when the screen matches; otherwise add a `- [ ] T0xx fix …` line
under **Findings** naming screen, expected token, observed, golden to update.
