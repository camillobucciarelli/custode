---
status: accepted
date: 2026-11-19
---

# Signals and Stores replace BLoC

Custode is being aligned to the stack and architecture of the owner's other Flutter app, Postino (repo `email-client`), so conventions and agent skills are shared between the two. Implementation starts only after store approval of 1.0.0 and completion of spec 023.

Presentation state lives in three BLoCs on `flutter_bloc`. `VaultBloc` alone is over 3,600 lines and more than 65 events spanning vault content, sync and autofill. We migrate to `signals_flutter`: each BLoC is replaced by Stores, plain classes that expose signals and methods, are registered in DI and are unit-testable.

This diverges from Postino, which keeps signals inside widget `State` and has no state classes. Custode needs Stores because the open vault state outlives a single screen, and because the existing BLoC unit tests must be converted, not dropped.

## Considered Options

- Keep `flutter_bloc`: rejected, it keeps the two apps on different stacks and different agent skills.
- Signals in widget `State` only (the Postino shape): rejected, vault state is shared across screens and would lose its unit tests.

## Consequences

- The constitution rule "No new BLoC" and the AGENTS.md "Three BLoCs" rule must be rewritten in terms of Stores.
- The Cubits in `lib/core` (`ThemeCubit` and `UpdateCheckCubit`) are migrated to signals as well, since `flutter_bloc` is removed from the app entirely.
