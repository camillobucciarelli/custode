---
name: maintenance-release
description: The step-by-step sequence for shipping a fix on an already-published version line via a release/X.Y.x branch and hotfix/X.Y.Z, including the mandatory port back to main. Use when a hotfix or maintenance release is requested.
---

# Maintenance release

When that situation arrives:

1. Branch `release/X.Y.x` from the released tag it continues (`vX.Y.Z+N`), never
   from `main` — `main` carries a higher `version:`, and basing a maintenance
   line on it would ship a version that moves backwards.
2. Do the work on `hotfix/X.Y.Z` cut from that branch, and open the PR **into
   `release/X.Y.x`**. A PR from this base into `main` reads as a revert of
   everything merged since the tag.
3. Bump the patch digit on that line in the same PR — `0.5.0` → `0.5.1`, never
   the build counter after the `+` — and reset `+N` per the Versioning and
   releases rule in AGENTS.md, safe
   here precisely because the new patch version has published nothing yet
   (`version: 0.5.0+4` becomes `version: 0.5.1+1`). Mirror
   `_kApplicationVersion` in the settings screen, as any version bump does.
4. Dispatch `release.yml` **from `release/X.Y.x`** to ship it: the workflow bumps
   and tags whichever branch it is dispatched on, so nothing else is needed.
5. **Port the fix to `main`** in its own PR, by cherry-pick. This step is not
   optional: a fix that lives only on a maintenance line is a bug the next
   version reintroduces. Never merge `release/X.Y.x` into `main` — that drags the
   older line's `pubspec.yaml` back with it. Expect the cherry-pick to conflict
   where the two lines have diverged, and resolve in favour of the target
   branch's own API.

The branch stays after the release, so the next fix on that line has a base.
