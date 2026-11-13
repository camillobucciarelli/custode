# 017 — Password history

**Status**: Draft (analysed) · **Kind**: Feature / Vault
**Depends on**: 011 (master-password session scope — reveal gating)
**Coordinates with**: 016 (autofill save capture writes the history a user then wants to read), 008 (safe writer, backups)

**Input**: User description: "crerei una spec per la history delle password"

## Summary

Custode already writes password history. Every edit through
`VaultKdbxService` pushes the previous values into the KDBX entry's `<History>`
record, because that is what the KDBX writer does; a test proves the previous
password survives an update. The application reads that history for exactly one
purpose — deciding when a password last changed — and never shows it.

So the data a user needs after a bad edit is on disk, correct, and unreachable
without a second KeePass client. This was found while verifying spec 016: the
autofill save flow told the user "the previous one stays in the entry history",
and the user went looking for a history and found none. The copy was corrected;
the gap it revealed is this spec.

A password manager that silently keeps old secrets and offers no way to see,
use, or delete them is worse than one that keeps none: the user carries the
retention risk without the recovery benefit.

## User Scenarios & Testing *(mandatory)*

### User Story 1 - See what an entry used to hold (Priority: P1)

A user changed a password, and the change turned out to be wrong: the site
rejected it, the change never went through, or a sync overwrote something. They
open the entry and want to see the previous versions and when each stopped being
current.

**Why this priority**: This is the whole point. Without reading the history the
other two stories have nothing to act on, and today the data is invisible.

**Independent Test**: Edit an entry twice, open its detail screen, and confirm
both previous versions are listed with the date each was replaced — without
opening another KeePass client.

**Acceptance Scenarios**:

1. **Given** an entry edited three times, **When** the user opens its history,
   **Then** the previous revisions are listed newest first, each with the date it
   was replaced and which fields differ from the revision after it.
2. **Given** an entry never edited since creation, **When** the user opens its
   history, **Then** an empty state explains that no previous versions exist yet.
3. **Given** a revision in the list, **When** the user has not asked to reveal it,
   **Then** its password is masked, exactly as the current password is on the
   entry screen.
4. **Given** a vault opened read-only or a locked session, **When** history would
   be shown, **Then** it is unavailable for the same reason and by the same rule
   as the entry's current secret.

---

### User Story 2 - Recover a previous password (Priority: P2)

The user has found the old password and needs to use it: copy it to sign in one
last time, or put it back as the entry's current password.

**Why this priority**: Reading without recovering solves the diagnosis and not
the problem, but it is still the smaller half — a user who can see the value can
retype it. Restoring is the convenience that makes it a feature.

**Independent Test**: Change a password, restore the previous revision, and
confirm the entry holds the old password again and the wrongly-set one is itself
now in the history.

**Acceptance Scenarios**:

1. **Given** a revealed revision, **When** the user copies its password, **Then**
   it reaches the clipboard under the same clearing and feedback rules as copying
   the current password.
2. **Given** a revision, **When** the user restores it, **Then** the entry's
   current values become that revision's values, the state before the restore
   becomes the newest history revision, and the change is saved through the same
   protected write path as any other edit.
3. **Given** a restore, **When** the user is asked to confirm it, **Then** the
   confirmation names what will be replaced, because a restore overwrites the
   current password.

---

### User Story 3 - Stop keeping what should not be kept (Priority: P3)

The user does not want an old password retained — it was pasted in the wrong
field, or it is reused somewhere else and its presence in the file is a risk.
They want to remove one revision, or all of an entry's history, and to know what
the vault's retention setting is.

**Why this priority**: It is the counterweight to Story 1. Making history visible
without making it removable converts an invisible retention risk into a visible
one the user cannot act on.

**Independent Test**: Delete one revision and then all of an entry's history, and
confirm both are gone from the saved file, not only from the screen.

**Acceptance Scenarios**:

1. **Given** a revision, **When** the user deletes it, **Then** it is gone from
   the saved `.kdbx` and the remaining revisions keep their order.
2. **Given** an entry with history, **When** the user clears all of it, **Then**
   the user is warned first that the previous passwords are being destroyed and
   cannot be recovered, and a dated backup is written before the file changes.
3. **Given** the vault's retention limits, **When** the user opens the history
   view, **Then** the effective limit on how many revisions are kept is stated,
   so an absent revision is explained rather than mysterious.

---

### Edge Cases

- An entry restored from the recycle bin: its history comes back with it, and the
  time in the bin is not presented as a password change.
- A revision whose password is identical to the current one — a title-only edit —
  is listed as a revision but must not read as a password change.
- Two devices edit the same entry and sync: the merge already reconciles history.
  The view shows the merged result; this spec does not change merge behaviour.
- A revision holding a custom field the current entry no longer has: restoring
  brings it back, because custom fields are part of what a restore moves.
- A revision holding an attachment the current entry no longer has: restoring
  does **not** bring it back, and the confirmation says so (FR-006a).
- An entry with a very long history — hundreds of revisions — must not make the
  detail screen slow to open, since history is only needed on demand.
- Changing the master password re-encrypts the file; history survives and is not
  presented as a password change on every entry.
- A revision's OTP secret is a secret like any other and is masked and gated the
  same way.

## Requirements *(mandatory)*

### Functional Requirements

- **FR-001**: The application MUST show, for a chosen entry, the previous
  revisions the vault file already holds, newest first.
- **FR-002**: Each revision MUST state when it stopped being current and which of
  the entry's fields differ from the revision that replaced it.
- **FR-003**: A revision's secret values MUST be masked by default and revealed
  only on an explicit request, under the same session and authentication rules
  that gate the entry's current secret.
- **FR-004**: A revision's secret MUST never appear in logs, diagnostic output,
  state descriptions or error messages (Constitution I).
- **FR-005**: Users MUST be able to copy a revision's password, with the same
  clipboard clearing and confirmation behaviour as copying the current password.
- **FR-006**: Users MUST be able to restore a revision, making its title,
  username, password, URL, notes and custom fields the entry's current values.
  A revision's OTP secret travels with its custom fields, so it is restored too.
- **FR-006a**: A restore MUST NOT change the entry's attachments, and the
  confirmation MUST say so whenever the revision's attachments differ from the
  entry's. Attachment bytes are not part of what a restore moves, and a user who
  assumes otherwise loses a file silently.
- **FR-007**: A restore MUST preserve the pre-restore state as a new history
  revision, so a restore is itself reversible.
- **FR-008**: A restore MUST be confirmed first, naming what it replaces.
- **FR-009**: Users MUST be able to delete a single revision, after a
  confirmation. No dated backup is written for a single deletion: a copy of the
  whole vault per revision removed is a worse trade than the confirmation, and
  the entry's other revisions are untouched. Clearing the whole history is the
  case Constitution VII covers, and it does back up (FR-010).
- **FR-010**: Users MUST be able to clear an entry's entire history, after a
  warning that names what is destroyed, with a dated backup written before the
  file is modified (Constitution VII).
- **FR-011**: Every write in this feature MUST go through the existing protected
  write path — path mutex, safe writer, backup — and never bypass it.
- **FR-012**: The history view MUST state the vault's effective retention limit,
  so a missing revision is explained.
- **FR-013**: An entry with no history MUST show an empty state that says no
  previous versions exist, not an error and not a blank screen.
- **FR-014**: The feature MUST NOT change what the application writes to history:
  the KDBX writer's existing behaviour is the source, and no new retention
  policy is introduced. This MUST be asserted, not assumed — after any operation
  in this feature, an ordinary edit still records exactly one new revision.
- **FR-015**: History MUST be loaded only when the user asks for it, so an entry
  with a long history does not slow the entry screen.

### Key Entities

- **Entry revision**: one previous version of an entry — its title, username,
  password, URL, notes, custom fields, attachments and OTP secret as they were,
  plus the moment it stopped being current. Ordered relative to the other
  revisions of the same entry.
- **Revision difference**: which fields changed between one revision and the next,
  used to label a revision without revealing its secrets.
- **Retention limit**: the vault-level ceiling on how many revisions, and how
  much data, are kept per entry. Read, reported, and not set by this feature.

## Success Criteria *(mandatory)*

### Measurable Outcomes

- **SC-001**: A user who has just made a wrong password change can see the
  previous password and restore it without leaving Custode and without a second
  KeePass client.
- **SC-002**: Opening an entry whose history holds 200 revisions is no slower
  than opening one with none, because history loads only when requested.
- **SC-003**: No revision secret appears in any log, crash report or serialized
  state, verified by the same redaction sweep used for the current password.
- **SC-004**: Every history write is preceded by a dated backup and leaves the
  `.kdbx` readable by another KeePass client, verified by reopening the file
  elsewhere after each operation.
- **SC-005**: A user asked to clear history is told what is destroyed before it
  happens, in every path that destroys it.

## Assumptions

- History is already written correctly by the existing write path; this feature
  reads, restores and deletes, and does not change what gets recorded.
- The entry detail screen is where history belongs, reached from the entry the
  user is already looking at, rather than a separate top-level destination.
- Revealing a historical secret is governed by the same session rules as the
  current one (spec 011); this feature adds no second authentication concept.
- KDBX retention limits are honoured as the file declares them. Letting the user
  change those limits is out of scope.
- Merge and sync behaviour for history is already handled by the merge adapter
  and is not modified here.
- Attachments are out of scope for restore. A revision lists the attachment
  names it held, so the user can see what differs, but moving attachment bytes
  between revisions is its own feature and is not this one.
