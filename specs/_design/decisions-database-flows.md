# Decisions: database flows before the vault (welcome, open, create, unlock, list)

decided: 2026-11-19 · implemented by `specs/025-database-flows-redesign`
drawn in: `15 Database flows.dc.html` (turn **8**, groups 01 to 04) · supersedes the database and unlock screens of `01-02 Database & Unlock.dc.html`

## The principle: one hierarchy

Every screen orders its content the same way: **source/account**, then
**database file**, then **credentials**. The list groups by source and account,
the unlock screen opens with the source chip, the create wizard asks for the
place before the password.

## Flow rules

1. **Two entry actions.** `Create new database` and `Open a database`, on the
   welcome and in the Add sheet. The former three (create, open `.kdbx`, import
   from Drive) are gone, and there is no third add surface.
2. **The source step belongs to Open only.** `Open a database` shows the sheet
   "Where is your database?" (this device or Google Drive). This corrects the
   approved mockups, where the sheet read as common to both paths.
3. **Create chooses the source in step 1.** `Create new database` pushes the
   wizard directly; "Where it lives" is the first block of step 1 "Name and
   place". Choosing Google Drive creates the file on Drive for real.
4. **One conflict sheet.** A match by source, by content hash or by name opens
   the same sheet (open the existing one, keep both, replace existing, cancel).
   It replaces the name-overwrite dialog and the duplicate sheet. `Recommended`
   only for a source or hash match. Dismissal by any means is cancel.
5. **One biometric offer.** Asked once per database, after the first successful
   manual unlock, for every source. Either answer and dismissal count as
   answered. It replaces the pre-unlock prompt after a Drive import, and covers
   the local import that was never offered anything. The switch in create
   step 2 stays, and creating a database marks the offer as answered.
6. **Create enters the vault directly.** No unlock screen and no retyping of
   the password after step 2.
7. **Same flows on every platform.** Same screens and same widget tree
   everywhere. A missing capability (remote source, biometrics, persistence) is
   a disabled option with a one-line reason, and the capability is decided in
   one place (`presentation/utils/platform_utils.dart`), never per screen.

## Paths

| Path | Steps |
| --- | --- |
| Open | welcome → source → (Drive: file list) → conflict, if any → unlock → vault |
| Create | welcome → step 1 → step 2 → vault |
| Reopen / pick from the list | unlock → vault |

The Add sheet on the databases list starts the same Open and Create paths.

## Where the implementation differs from the approved mockups

The record draws the implemented version in each case.

- Drive file rows show an absolute modified date (`Modified 12 Mar 2026`), not a
  relative one: the row is shared with the vault Sync picker and a relative
  date would tie its golden to the clock.
- The list status is day-granular (`Synced today`, `Synced 3 days ago`), not
  `Synced 2 min ago`; a linked database that never synced shows no status.
- The inline unlock error is the field's error text, with no icon.
- The biometric offer body is `You can change this anytime in Settings.`; the
  mockup body was a designer annotation. The sheet sits over the unlock screen,
  not over the vault.
- Icon buttons on these screens are 44, as drawn, while `PIXEL_SPEC` section 2
  still lists 36 for the generic icon button.
- The create switch is the design-system `KvSwitch` (44 × 26), not the 52 × 30
  one drawn.
- `This device` uses the `monitor` glyph, not the smartphone drawn.

## Open

- Tablet/desktop and dark variants are not in the approved mockups; spec 025's
  golden inventory covers them, the record does not draw them.
- The disabled source card and the Drive list loading and empty states are not
  drawn in the approved mockups.
- The mockups' secondary text colour `#665F53` is not a token (nearest:
  `neutral-700`).
- Wording of the strings added by spec 025 beyond the mockups (its open
  decision D4).
