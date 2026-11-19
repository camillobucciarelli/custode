---
status: accepted
date: 2026-11-19
---

# Coordinators and use cases are kept

Custode is being aligned to the stack and architecture of the owner's other Flutter app, Postino (repo `email-client`), so conventions and agent skills are shared between the two. Implementation starts only after store approval of 1.0.0 and completion of spec 023.

Custode keeps coordinators (multi-step sequencing and rollback) and use cases for atomic actions with policy value. This is a deliberate difference from Postino, which has no coordinators and allows a use case only when it orchestrates two or more repositories. The reason: this code protects vault files, and only presentation is being aligned.

## Considered Options

- Adopt Postino's rule now: rejected, it would restructure the code that protects vault files for no gain in presentation alignment.
