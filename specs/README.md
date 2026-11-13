# Custode specs

Spec-kit style specifications for the **Custode restyle** (Organic design
system) plus the **two new features** the design package introduces.

Source of the design: Claude Design project
`5151eacb-bbf2-44aa-921c-6a0e2d231d12`, folder `design_handoff_custode_restyle/`.
Imported 2026-08-05.

## Layout

```
.specify/memory/constitution.md   non-negotiable rules
specs/_design/                    the design handoff, verbatim (numbers of record)
  HANDOFF.md                      journeys, tokens, behaviour, state
  PIXEL_SPEC.md                   every measurement, per surface
  ICONS.md                        app mark geometry + Lucide mapping
  tokens.css                      Organic handoff source; 001 records mandatory accessibility deviations
  custode-mark*.svg              vector masters of the new app mark
specs/NNN-slug/spec.md|plan.md|tasks.md
```

## Specs

| # | Spec | Kind | Depends on |
| --- | --- | --- | --- |
| 001 | [Organic design system](001-organic-design-system/spec.md) | Restyle foundation | — |
| 002 | [Navigation shell (model 1a)](002-navigation-shell/spec.md) | Restyle foundation | 001 |
| 003 | [Database selection & unlock](003-database-and-unlock/spec.md) | Restyle (journeys 01–02) | 001, 002 |
| 004 | [Entry, editor, generator](004-entry-editor-generator/spec.md) | Restyle (journeys 04–06) | 001, 002 |
| 005 | [Sync, health, import/export](005-sync-health-import/spec.md) | Restyle (journeys 07–09) | 001, 002 |
| 006 | [Security, autofill, extension](006-security-autofill-extension/spec.md) | Restyle (journeys 10–12) | 001, 002 |
| 007A | [App icon family — asset generation](007-app-icon-family/spec.md) | Restyle asset work | — |
| 007B | [App icon family — UI/badge integration](007-app-icon-family/spec.md) | Restyle integration | 001, 002, 007A |
| 008 | [Per-field sync conflict resolution](008-per-field-conflict-resolution/spec.md) | **New feature** | 001, 002, 005 |
| 009 | [In-page autofill overlay](009-in-page-autofill-overlay/spec.md) | **New feature** | 006 |
| 010 | [Cloud storage provider abstraction](010-multi-cloud-storage/spec.md) ([plan](010-multi-cloud-storage/plan.md), [tasks](010-multi-cloud-storage/tasks.md)) | **Architecture refactor** (planned, Google-only first slice) | 005; coordinates with 008 |
| 011 | [Master password session scope](011-master-password-session-scope/spec.md) | **Security fix** | 003, 006 |
| 012 | [Home Assistant object storage](012-home-assistant-object-storage/spec.md) | **New storage provider** (draft) | 005, 010 |
| 013 | [Google Drive per-file access and Picker](013-google-drive-per-file-access/spec.md) ([tasks](013-google-drive-per-file-access/tasks.md)) | **Security / release blocker** | 005; coordinates with 010, 006 |
| 014 | [Managed storage hardening](014-managed-storage-hardening/spec.md) ([tasks](014-managed-storage-hardening/tasks.md)) | **Security** | 003; coordinates with 013, 010 |
| 015 | [Create database credentials flow](015-create-database-credentials/spec.md) ([tasks](015-create-database-credentials/tasks.md)) | **UX / Security** | 014; coordinates with 003, 011 |

Journey 03 (navigation models) resolved into spec 002; journey 14 (dark mode) is
not a separate spec — the dark token mapping lands in 001 and every screen spec
carries dark acceptance criteria.

## Suggested order

1. **007A** asset generation may run independently or alongside **001**. It
   produces reviewed assets only; no launcher, in-app or badge integration.
2. **001** then **002** establish tokens and shell. Constitution governance makes
   both prerequisites for every later UI integration, including **007B**.
3. **003 → 004 → 005 → 006** may then proceed; 004 is the highest-traffic surface.
4. **007B** follows 001, 002 and 007A. **008** follows 005; **009** follows 006.
5. **010** follows 005 and now plans an immediate Google-only abstraction slice:
   one provider-neutral port, one Google implementation and generic persisted
   mappings. Its [plan](010-multi-cloud-storage/plan.md) and
   [tasks](010-multi-cloud-storage/tasks.md) coordinate shared orchestrator,
   mapping, mutex and safe-writer work with active **008**. A second provider,
   provider picker, registry and capability UI remain deferred.
6. **012** drafts a second storage provider and therefore sits behind **010**'s
   provider-neutral port; it stays a draft until that port exists.
7. **013** is a release blocker and takes priority over **010** and **012**: the
   public consent screen currently warns every non-owner account, because the app
   requests a restricted Drive scope it has not been verified for. It is the
   normative source for the Google OAuth scope and for how a remote file is
   selected, while **010** stays the owner of the provider-neutral architecture.
8. **011** is a security fix, independent of the restyle sequence, and takes
   priority over new-feature work: it removes an unbounded plaintext lifetime
   that violates constitution principle I and blocks the accurate privacy claim
   required for store submission.
9. **014** hardens the app-managed local storage — desktop root off `~/Documents`,
   opaque file names, encrypted metadata, restrictive permissions — and performs
   no migration by design. It is independent of the cloud-sync sequence and only
   coordinates with **013** over where the local copy of a Drive vault lives.
10. **015** follows **014**, which is a hard prerequisite: the create-database
    wizard's generated key file uses 014's opaque naming, and 015 must not
    restate that rule. 015 also owns the unlock fallback matrix that becomes
    necessary once a key-file-only vault can be created.

## Roadmap board

Development status is mirrored to a GitHub Projects v2 board: one issue per
spec, labelled `spec`, its body a copy of that spec's `tasks.md` checklist.
`tool/sync_spec_project.sh` derives task completion from this directory, detects
open PRs that touch each spec, and runs on every push to `main` that touches `specs/**`
(`.github/workflows/spec-project-sync.yml`). Status is `Done` when every task
box is ticked, `In Progress` when some are or an open PR touches the spec, `Todo`
otherwise; a `Done` spec's issue is closed automatically. Active PR links are
shown without treating their unmerged task boxes as completed work.

Tick the boxes in `tasks.md` — the issue body is regenerated and hand edits to
it are lost. One-time setup: repo variable `SPEC_PROJECT_NUMBER` (the board
number) and secret `PROJECTS_TOKEN` (a classic PAT with `repo`, `project`,
`read:org` and `read:discussion`; the default `GITHUB_TOKEN` and fine-grained
PATs cannot write user-level Projects v2).

Checkboxes record whether each task's full acceptance criteria hold on `main`,
not the historical order in which old implementation landed. A retrospective
audit can therefore leave an earlier partial task open while checking a later,
independently satisfied task. Open PRs affect only `In Progress` and active-work
links; checkout is pinned to `main`, so their unmerged boxes never count.

## Definition of done, every spec

- `flutter analyze` clean, targeted tests green, then `flutter test` green before
  commit.
- Exact named golden inventory in the spec is green. Responsive root layouts use
  390×844 and 1024×768, light and dark; explicitly listed state variants may use
  a representative axis with widget-test coverage for omitted axes.
- No hard-coded hex, font, radius or duration in migrated files. Compatibility
  aliases are allowed only for untouched call sites and are tracked to zero.
- Every text/background pairing declared by the spec passes ≥4.5:1 contrast;
  accessibility-approved handoff deviations are documented. Remaining
  accessibility floor from the constitution is met.
