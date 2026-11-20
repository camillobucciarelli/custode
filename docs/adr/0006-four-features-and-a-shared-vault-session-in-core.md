---
status: accepted
date: 2026-11-19
---

# Four features and a shared vault session in core

Custode is being aligned to the stack and architecture of the owner's other Flutter app, Postino (repo `email-client`), so conventions and agent skills are shared between the two. Implementation starts only after store approval of 1.0.0 and completion of spec 023.

Today everything is one feature, `password_manager`, whose areas form a single strongly connected import component. We split it into four features: database, vault, sync and autofill. A feature imports only itself, core and the design system, never another feature.

File safety (safe writer, backups, path mutex, portable paths), the encrypted metadata store, the vault session and the shared domain models move to core. The open vault is exposed by one session service in core domain that each feature's Store observes. Settings is a page that composes the features.

## Considered Options

- Seven features: rejected, selection and unlock are too intertwined to separate, and so are the three autofill paths.
- Two features: rejected.
- Composing features through callbacks in pages: rejected in favour of the shared session service in core.

## Consequences

- The AGENTS.md rule "Keep one Password Manager feature" must be rewritten.
- Specs 012 and 013 start after the restructuring, with their paths rewritten.
