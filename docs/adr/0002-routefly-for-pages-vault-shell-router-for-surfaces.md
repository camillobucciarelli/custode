---
status: accepted
date: 2026-11-19
---

# Routefly for pages, VaultShellRouter for surfaces

Custode is being aligned to the stack and architecture of the owner's other Flutter app, Postino (repo `email-client`), so conventions and agent skills are shared between the two. Implementation starts only after store approval of 1.0.0 and completion of spec 023.

Pages become file-based `routefly` routes under `lib/app`, and the 8 untyped page replacements done through the imperative Navigator become route navigation. `VaultShellRouter` stays for the 15 in-shell surfaces, because it returns typed results, picks route, sheet, pane or dialog by available width, and guards the discard of unsaved edits. Dialogs and pickers stay on `Navigator`. This is the same split Postino uses.

## Considered Options

- Keep the imperative Navigator for pages: rejected, it keeps page navigation untyped and unaligned with Postino.
- Move every surface to a routefly push with result: rejected, it would lose typed results, width-adaptive presentation and the discard guard.

## Consequences

- `routefly` keeps its router configuration in statics, so a test that needs a different route configuration must live in a separate test file.
- The last `routefly` release is about 21 months old; the dependency is accepted with that maintenance risk known.
