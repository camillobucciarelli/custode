---
name: speckit-guided
description: Guided end-to-end Spec-Kit cycle — specify → clarify → plan → tasks → analyze → implement, with a stop-and-confirm gate between every phase. Use when the user wants to start a new spec, run spec-kit "in guided mode", or asks for the full SDD flow instead of invoking each speckit-* skill by hand.
---

# Guided Spec-Kit cycle

Drive the existing `speckit-*` skills in order. **One phase per turn.** After each
phase, stop, show what was produced, and wait for the user to approve before the
next one. Never chain two phases in a single response.

## Before starting

If `.specify/memory/constitution.md` is missing or empty, run `speckit-constitution`
first. Otherwise skip it.

## Phases

| # | Skill | Gate question after it |
|---|-------|------------------------|
| 1 | `speckit-specify` | "Spec at `specs/NNN-slug/spec.md`. Approve, edit, or re-run?" |
| 2 | `speckit-clarify` | Skip if the spec has no `[NEEDS CLARIFICATION]` markers and the user asks to skip. |
| 3 | `speckit-plan` | "Plan + design artifacts written. Approve?" |
| 4 | `speckit-tasks` | "N tasks generated. Approve?" |
| 5 | `speckit-analyze` | Report inconsistencies. If any are blocking, go back to the phase that owns them. |
| 6 | `speckit-implement` | Run only on explicit go-ahead. |

The user may enter at any phase ("guided from plan") or stop at any phase
("guided, stop after tasks"). Honour that; do not run later phases uninvited.

## Repo rules that apply to every phase

- The spec-kit files under `specs/NNN-slug/` are working documents. The spec of
  record is a GitHub issue labelled `spec` (see `docs/agents/issue-tracker.md`,
  **Roadmap specs**): after the tasks phase, publish or update that issue in the
  `to-spec` shape with a `## Tasks` checklist.
- Title of the issue is `<id> — <Title>`. The id never changes after creation.
- Task lines start at column 0 as `- [ ]`; continuation lines indented.
- Tick `- [x]` in the issue when the work is merged (phase 6), and update the
  Project #2 card by hand. There is no sync script.
- Before finishing phase 6: `flutter test` and `flutter analyze`, report results.
