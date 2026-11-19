---
status: accepted
date: 2026-11-19
---

# flutter_web_auth_2 replaces google_sign_in

Custode is being aligned to the stack and architecture of the owner's other Flutter app, Postino (repo `email-client`), so conventions and agent skills are shared between the two. Implementation starts only after store approval of 1.0.0 and completion of spec 023.

Google authorization uses `google_sign_in` on mobile plus a hand-written PKCE loopback flow on desktop. We replace both with one authorization-code + PKCE flow through `flutter_web_auth_2` on all platforms, and we do it now, not inside spec 010.

## Considered Options

- Defer to spec 010: rejected, the decision was to make the change now.
- Keep `google_sign_in`: rejected, it keeps two separate authorization flows.

## Consequences

- New OAuth clients and redirect configuration are required.
- Android needs a callback activity.
- Users already linked to Google Drive on mobile must sign in again.
