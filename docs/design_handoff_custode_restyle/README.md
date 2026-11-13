# Handoff: Custode UX/UI restyle (Flutter app + Chrome extension + app icon)

## Overview

A full restyle of **Custode** — the cross-platform Flutter password manager in
`camillobucciarelli/key-vault-password-manager` — aimed at a simpler UX and a
cleaner UI. The package covers all twelve functional journeys of the app, in
mobile (390×844) and tablet/desktop (1024×768) layouts, in light and dark, plus
the Chrome extension popup and a new app-icon family.

Two additions are **new features**, not restyles, and are marked as such below:
per-field sync-conflict resolution, and an in-page autofill overlay.

## About the design files

The `.dc.html` files in this bundle are **design references written in HTML** —
prototypes that show intended layout, colour, type and behaviour. They are not
production code to copy. The task is to **recreate these designs in the existing
Flutter codebase**, using its own widgets, theme and architecture (`AppTheme`,
`AppColors`, `AppIcons`, the three BLoCs and the coordinators). Nothing in these
files should be shipped as HTML; the Chrome-extension screens are the exception,
since that surface really is HTML/CSS (`desktop/browser_extension/popup.html`,
`popup.css`).

Open a file by double-clicking it (each is self-contained apart from
`support.js`, `_ds/…/styles.css` and the `icons/` and `assets/` folders shipped
alongside).

## Fidelity

**High fidelity.** Colours, type, spacing, radii and copy are final. Recreate
pixel-for-pixel with Flutter widgets. Every caption inside the design files marks
what already exists in the code versus what is a **Proposta** (proposal) — respect
that distinction when scoping the work.

## Design tokens

Taken from the Organic design system (`_ds/organic-…/styles.css`). Replace the
current indigo/slate theme in `lib/core/theme/app_colors.dart`.

### Light theme

| Role | Token | Hex |
| --- | --- | --- |
| Page ground | `--color-neutral-100` | `#f9f4ed` |
| Surface (cards, rows, fields) | `--color-neutral-200` | `#eee7db` |
| Work surface / canvas behind frames | `--color-neutral-300` | `#dcd3c4` |
| Text primary | `--color-text` | `#201e1d` |
| Text secondary | `--color-neutral-600` | `#82796a` |
| Text tertiary / hint | `--color-neutral-500` | `#a19786` |
| Primary action fill | `--color-accent-300` | `#ffc6a5` |
| Primary action text | `--color-accent-900` | `#402310` |
| Action hover / emphasis | `--color-accent-400` | `#f6a06b` |
| Warning / attention tint | `--color-accent-100` | `#fff2eb` |
| Warning text | `--color-accent-900` | `#402310` |
| Link / inline action text | `--color-accent-800` | `#643312` |
| Positive fill | `--color-accent-2-400` | `#aebf92` |
| Positive tint | `--color-accent-2-100` | `#f0fae1` |
| Positive text | `--color-accent-2-900` | `#272e1b` |
| Divider | `--color-divider` | `#201e1d` @ 16% |

### Dark theme

| Role | Hex |
| --- | --- |
| Ground | `#2e2b25` (`neutral-900`) |
| Surface | `#474238` (`neutral-800`) |
| Text primary | `#f9f4ed` (`neutral-100`) |
| Text secondary | `#f9f4ed` @ 55–62% |
| Text tertiary | `#f9f4ed` @ 50% |
| Divider / outline | `#f9f4ed` @ 20–26% |
| Primary action fill / text | `#ffc6a5` on `#402310` |
| Warning tint / text | `#643312` / `#ffe1d0` |
| Positive tint / text | `#3d472b` / `#e1eecc` |
| Selection border (diff, radio) | `#ffc6a5`, 2px |

Rule of thumb for dark: surfaces move **up** one ramp step, tinted backgrounds
move to the **800** step of their ramp with text at **100–200**, and the pastel
accents stay identical to light.

### Typography

- Display / headings: **Caprasimo** 400 (`--font-heading`). Sizes used: 38, 34,
  32, 30, 28, 27, 26, 24, 23, 22, 20, 19, 18, 17 px. Line-height 1.12–1.15,
  letter-spacing −0.015em.
- Body / UI: **Figtree** 400/600/700 (`--font-body`). Sizes: 15 px row title
  (600), 14.5 px field value, 13.5 px body, 12.5 px secondary, 12 px caption,
  11.5–11 px meta, 10–11 px uppercase label (letter-spacing 0.09em, uppercase).
- Monospace for secrets, checksums and codes: `ui-monospace, Menlo, monospace`.
  One-time codes 21 px with 0.16em letter-spacing; revealed passwords 16 px.
- Replaces Poppins (`GoogleFonts.poppinsTextTheme` in `app_theme.dart`).

### Spacing, radii, elevation

- Spacing scale: 4.4 / 8.8 / 13.2 / 17.6 / 26.4 / 35.2 px (`--space-1…8`).
  In practice: 8–10 px between rows, 12–16 px between groups, 18–22 px screen
  side padding (mobile 20 px), 26–30 px bottom safe padding.
- Radii: rows and fields **20–22 px**, cards and sheets **24–28 px**, bottom
  sheets **32 px top corners**, phone frame 46 px, buttons and chips **999 px**
  (pill), icon squares 12–14 px, avatars 999 px.
- Control heights: primary/secondary pill **52 px**, compact pill 46 px, search
  field 46 px, input row min 52 px, icon button 36 px (tap target ≥ 44 px),
  bottom tab bar 82 px.
- Shadows: `--shadow-sm` `0 1px 2px #2e2b25 14%`, `--shadow-md`
  `0 3px 10px #2e2b25 16%`, `--shadow-lg` `0 12px 32px #2e2b25 22%`. Dark:
  `0 12px 32px rgba(0,0,0,.5)`.
- Borders are avoided; separation comes from the ramp step. Focus ring:
  `2px solid var(--color-accent)`, offset 2px.

### Icons

Lucide, **stroke-width 2.75**, sizes 15–23 px inline, 26–34 px in feature
circles. This replaces the Material set in `lib/core/theme/app_icons.dart`; keep
the same semantic names when swapping.

## Structure and navigation

The chosen model (option **1a** in `03 Vault - modelli di navigazione.dc.html`,
picked over search-first and "evolved strip") is:

- **Mobile**: bottom tab bar with four destinations — **Vault**, **Health**,
  **Sync**, **Settings** (82 px tall, icon 23 px + 10.5 px label, active item in
  `accent-800` light / `accent-300` dark).
- **Tablet/desktop**: a 72–76 px icon rail with the same four destinations, then
  (for the vault) a 236–352 px list column and a persistent detail pane. Break at
  the existing `Breakpoints.mobile = 600` / `Breakpoints.tablet = 1024`.
- **Everything that is a dialog today becomes a screen or a bottom sheet**:
  entry detail (`Record info`), recycle bin, duplicates, sync link/conflict,
  database settings, CSV import, password generator. On tablet they become panes,
  never a dialog stacked on a dialog.

## Screens / views

Each file below contains the screens with their state variants side by side and a
caption under every frame explaining what changed and why.

### `01-02 Database & Unlock.dc.html`

Journey 01 — database selection (`DatabaseSelectionBloc`,
`database_selection_screen.dart`, `create_database_dialog.dart`,
`recent_databases_section.dart`):

1. **Welcome / no database** — 88 px app mark, 38 px Caprasimo headline
   ("Your vault, in a file you own."), 3 pill actions: create, open `.kdbx`,
   import from Drive.
2. **Recent databases** — 40 px mark + "Databases" + 40 px accent add button;
   `Recent` label; one 24 px-radius row per database with a 40 px rounded icon
   square, name (15/600), source line ("On this device · 128 items · biometrics
   on" / "Google Drive · synced 1 h ago"); active one on `accent-200`. Add
   section with two rows. Today's version shows the full path and a
   Open/Export/Remove popup menu — keep those actions in the row's overflow.
   *Proposal*: the "file not found → Locate" row.
3. **Create database, steps 1–3** — progress = three 4 px bars; step 1 name +
   storage note ("Custode app storage"), step 2 master password with a 4-notch
   strength meter and confirm field, step 3 optional locks: generate key file,
   Face ID, auto-lock (accepted). Field labels match the real dialog.
4. **Drive picker, loading** — skeleton rows shaped like the final rows.
5. **Drive picker, empty** — names the Google account, offers create+upload or
   switch account.
6. **Invalid file** — bottom sheet naming the file; CSV import is *not* offered
   here (it is a `VaultEvent`, only available with a vault open).
7. **Duplicate detected** — the three real resolutions: Keep both, Replace
   existing, Use existing (+ cancel), each with its consequence written under it.
8. **Tablet** — two columns: identity + 3 actions left, database cards right.

Journey 02 — unlock (`database_unlock_screen.dart`, `DatabaseUnlockBloc`):
password (default), biometric gate (dark, full screen), wrong password (error
under the field, naming the missing-key-file case), key file selected (button
becomes "Unlock with key file", password marked optional), internal key file
manager sheet, "Decrypting Personal.kdbx" with progress and the Argon2
explanation, "Use Face ID for Work.kdbx?" prompt after a Drive import, and the
centred desktop card (max 600 px, no step counter, no explanatory paragraphs).

### `04-06 Voce, editor, generatore.dc.html`

Journey 04 — entry detail: 56 px avatar + title + "folder · host"; copyable rows
(Username, Password, Website, Notes) at 22 px radius; "More" chips for
attachments and custom fields; strength strip at the bottom
(`_evaluatePasswordStrength`: Weak <40 bits, Fair <60, Good <80, Strong) with
`lastPasswordChangedAt`; primary "Copy password" pill. Variants: hidden,
revealed + TOTP (12 s reveal timer is a proposal; the TOTP countdown is real,
`Timer.periodic` + `TotpUtils`), biometric gate sheet ("Unlock with biometrics" /
"Use password"), copy confirmation ("Copied password." exists today; the 30 s
clipboard clear is a proposal), weak/reused warning that links to the generator.

Journey 05 — editor: Cancel / New item / Save header, the six real fields
(Title, Username, Password, URL, Notes) with the generator spark inside the
password field, and a vertical **Optional** list — Custom field, Attachment,
One-time code — identical on mobile and tablet. Variants: generator sheet, the
two literal constraint errors, full-screen QR scanner, camera-denied screen with
the `OTP URI (otpauth://…)` field, discard-changes sheet, saving overlay
("Writing to the .kdbx…").

Journey 06 — generator: slider **8–64**, default **16**, the four character-set
checkboxes with their exact labels, result shown live above the controls, and
`canGenerate` disabling the primary action.

Tablet: detail pane with copy actions as pills and a metadata grid (Created,
Updated, last password change — the three rows `Record info` shows today);
editor with the generator as a **third column**.

### `07-09 Sync, igiene, import-export.dc.html`

Journey 07 — the six `DatabaseSyncStatus` values: `disconnected` (explains the
security model before asking for access), connected-but-not-linked (create a new
Drive file — "A new file will be created in My Drive root." — or pick an existing
one; auto-sync toggle), remote file picker (`DriveRemoteFile`: name,
`modifiedTime`, size, already-linked warning), `success` (last sync, local
checksum, unlink; recent-activity list is a proposal), `syncing` + offline
(offline is a proposal), `error` with "Reconnect Google Drive" as a persistent
state, and `conflict` as a sheet with the three real resolutions (Keep local /
Use remote / Cancel) plus which side is which, the truncated checksums and
`remoteModifiedTime`.

Journey 08 — vault health (score + five categories, all computed from data the
app already has), duplicates (`sharedUrl` + `sharedUsername` groups, Keep =
`MergePreview.primary`, Merge = `secondary`, "Some data will be copied"), merge
preview listing exactly the four `MergePreview` flags, no-duplicates empty state,
recycle bin (Restore inline, Delete permanently in the overflow, `Empty bin (n)`)
and the empty state + confirm with the literal strings.

Journey 09 — CSV import (Detected format / Rows found / Valid records / Skipped
rows + Avoid duplicates), import outcome with per-row skip reasons (proposal),
and a Backups screen collecting the three existing export actions.

**New feature — per-field conflict resolution** (3 mobile screens + tablet):

1. **Review changes** — every difference classified: present on one side only
   (kept automatically), same record with differing fields (needs a decision),
   deletions, folder renames. Two shortcuts, "Keep all local" / "Take all
   remote", reproduce today's behaviour in one tap. Nothing is written yet.
2. **Field diff** — one card per differing field with both values, their
   timestamps and a radio; the selected one carries a 2 px accent border.
   Identical fields are collapsed into one line. Notes offer a third option,
   "keep both, one under the other".
3. **Ready to merge** — final record count, every decision listed and editable,
   and the safety net: a dated local copy plus the previous Drive revision.

Implementation note: this needs record-level merging inside
`DatabaseSyncOrchestrator` (open the remote `.kdbx` in memory, diff by entry id,
apply per-field choices), not just the current checksum comparison.

### `10-12 Sicurezza, autofill, estensione.dc.html`

Journey 10 — settings as a tab: database group (file name, Biometric protection
switch, Lock on inactivity, Change master password, Key file) and app group
(Appearance, Autofill & browsers, Backups & import), plus "Close database".
Change-master-password screen with the three real fields and the
`Confirm security changes` → `Confirm and apply` sheet listing what changes and
what stays. Lock overlay (dark, says how long it has been locked, offers Face ID,
master password or closing the database); the privacy overlay is the same dark
ground with the mark only, no text.

Journey 11 — autofill: iOS enablement with the three system steps and a statement
of what is shared (titles, usernames, sites — not passwords); the
`Link AutoFill credential?` sheet with Target / Entry / Username and Reject /
Link; the desktop `BrowserSetupScreen` in three steps keeping its Italian labels
("Carica l'estensione beta", "Registra Native Messaging Host", "Ho fatto",
"Estensione caricata ✓", "Incolla") with the copyable install command; and a
host-not-found diagnostic naming `dev.camillobucciarelli.keyvault_native_host`
and the three likely causes.

Journey 12 — extension popup, **400 px wide**: 38 px header with the mark, the two
statuses (Native host / App-vault bridge) as a pair of tinted cards, the current
tab detected automatically, matches with the `strong` label and a Fill button,
global search field, and the privacy line. Three more states: app locked, host
not found ("Show me how" / "Check again"), and possible-only matches where the
action is "Ask app" (creates a pending association). **New feature**: an in-page
overlay anchored to the password field — appears on focus, `esc` closes it,
`↵` fills the highlighted match, with "Generate a new password instead". It needs
a content script, which the current MV3 manifest deliberately does not have; treat
it as a security decision, not just UI.

### `13 Icona app & estensione.dc.html`

Four icon directions; **3d "Combinatore"** was chosen: peach ring
(`#f6a06b`, stroke 10/100 units), dark hub (`#402310`, r 14) with a hand to
(74,26), four sage dots (`#ccdbb2`, r 5) at 12/3/6/9 o'clock, on an
`#ffe1d0` full-bleed square. All ink is scaled to **75 % about the centre** so it
fits Android's adaptive safe zone (66/108). Generated files are in `icons/`:

| File | Use |
| --- | --- |
| `custode-source-1024.png` | `flutter_launcher_icons: image_path` |
| `custode-adaptive-foreground-1024.png` | `adaptive_icon_foreground` (transparent) |
| `custode-monochrome-1024.png` | `adaptive_icon_monochrome` (white on alpha) |
| `app-512.png`, `app-192.png` | `web/icons/` |
| `ext-16/32/48/128.png` | extension `manifest.json` |

In `pubspec.yaml` only one value changes besides the paths:
`adaptive_icon_background: "#FFE1D0"` (was `#FFFFFF`).
The extension icon also gains **state badges** (grey = app locked, peach = host
missing, sage with a count = N matches) — not present in the manifest today.

### `14 Dark mode.dc.html`

Vault list, entry detail with reveal + TOTP, health, the new field diff, settings
with a Light / Dark / System selector (`ThemeCubit` already holds the three
values), and the extension popup — all on the dark token mapping above.

## Interactions & behaviour

- Copy actions keep the existing snackbars ("Copied password.", "Copied
  username.", "Copied URL.", "Copied notes.", "Copied one-time code.", "Copied
  <field>."); the list keeps its 1600 ms copy toast.
- Password reveal is a toggle today (`_passwordVisible`); the 12 s auto-hide plus
  progress bar is a proposal.
- TOTP: 1 s periodic tick, remaining seconds from the URI `period`.
- Auto-lock: existing inactivity timer plus the 30 s background rule; the lock
  overlay is full screen with Face ID / master password / close database.
- Saving: keep `isSaving` as a blocking overlay, but with the "Writing to the
  .kdbx…" card.
- Sync: auto-sync on open, save and resume; `Reconnect` action on expired
  authorization; conflicts open the per-field flow (with the two "all local /
  all remote" shortcuts as the fast path).
- Motion: reuse the existing durations — item transitions 190 ms, buttons 220 ms,
  screen transitions per platform (`ZoomPageTransitionsBuilder` on Android,
  Cupertino on iOS/macOS, fade on desktop). Sheets slide up 240 ms ease-out-cubic.
- Every interactive element needs a hover tint and a pressed state one ramp step
  past its base, plus the 2 px accent focus ring.

## State management

No new BLoCs for the restyle: `DatabaseSelectionBloc`, `DatabaseUnlockBloc` and
`VaultBloc` already expose everything the screens show (`VaultState` carries
search query, sort, expanded groups, recycle-bin entries, duplicate groups, sync
status/error/last sync, remote Drive files, pending Apple autofill associations).

New state needed only for the two new features:

- **Per-field conflict merge**: a `SyncMergeSession` holding the remote snapshot,
  a list of `RecordDiff { entryId, kind: localOnly|remoteOnly|fieldConflict|
  deletedLocal|deletedRemote|groupRenamed, fields: [FieldDiff{name, localValue,
  remoteValue, choice}] }`, plus the resulting decision map. Applied atomically,
  with a dated local backup written before the merge.
- **In-page overlay**: extension-side only — focused field, matches for the
  current origin, keyboard selection index. No plaintext kept after the fill.

## Assets

- `assets/custode-icon.png` — the new mark used as app chrome in the mockups.
- `icons/*` — the generated icon family (see the table above), drawn from the
  chosen direction, not from the previous PNG.
- Fonts: Caprasimo and Figtree (Google Fonts).
- Icons: Lucide (https://lucide.dev), stroke-width 2.75. Not bundled — add the
  Lucide Flutter package or export the SVGs you need.
- The original marks read from the repo (`assets/logo/custode-source.png`,
  `custode-monochrome.png`) are superseded.

## Files

| File | Contents |
| --- | --- |
| `00 Catalogo & Piano.dc.html` | Assumptions, source map, principles, visual direction, the twelve-journey catalogue |
| `03 Vault - modelli di navigazione.dc.html` | The three navigation models; **1a** is the chosen one |
| `01-02 Database & Unlock.dc.html` | Journeys 01–02, all states, mobile + tablet |
| `04-06 Voce, editor, generatore.dc.html` | Journeys 04–06, all states, mobile + tablet |
| `07-09 Sync, igiene, import-export.dc.html` | Journeys 07–09 + the per-field conflict feature |
| `10-12 Sicurezza, autofill, estensione.dc.html` | Journeys 10–12 + the in-page overlay feature |
| `13 Icona app & estensione.dc.html` | Icon directions, chosen mark, generated asset map |
| `14 Dark mode.dc.html` | Dark token mapping and six key screens |
| `_ds/organic-…/styles.css` | The token sheet every file reads from |
| `support.js` | Runtime needed to open the `.dc.html` files |
| `PIXEL_SPEC.md` | Every measurement: frames, paddings, component sizes, type scale, per-screen anchors, motion, a11y floor |
| `ICONS.md` | App-mark geometry, export table, `pubspec.yaml` diff, extension badge states, the full Lucide mapping for `AppIcons` |
| `icons/custode-mark.svg` | Vector master of the app mark (full bleed) |
| `icons/custode-mark-foreground.svg` | Vector master, ink only — adaptive foreground / monochrome |
| `screenshots/*.jpg` | Flat renders of each design file, for quick visual reference |

**Read order for implementation:** this README → `PIXEL_SPEC.md` for numbers →
`ICONS.md` for the mark and the glyph set → the `.dc.html` file of the journey
you are building (its captions say what exists today and what is a proposal).

Captions inside the files are in Italian; all product copy is in English, as in
the app today (except the desktop browser-setup screen, which is Italian in the
current code and stays that way).
