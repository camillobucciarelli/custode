# Custode Browser Autofill privacy policy

Last updated: August 2, 2026

This policy applies to the Custode Browser Autofill extension for Chrome and
Microsoft Edge. The extension requires the Custode desktop application and its
locally installed Native Messaging host.

## Data processed

- When the user asks Custode to find or search credentials for the current
  site, the extension processes the active tab origin and page title locally for
  credential matching. It sends them only to the Custode Native Messaging host
  installed on the same computer. Full URL paths, query strings, and fragments
  are not sent or retained.
- When the user runs a global metadata search, the extension sends the entered
  search query locally through the Native Messaging host. The host processes it
  against local Custode metadata. The extension and host do not retain the query
  or send it to a remote server.
- The local Custode app publishes credential metadata needed for matching,
  including entry identifiers, titles, usernames, display services, normalized
  site identifiers, and update timestamps. The Native Messaging host can search
  this local metadata. Passwords are not included in this metadata.
- A username and password are transferred locally from the unlocked Custode app
  through the Native Messaging host only after the user clicks **Fill on this
  page** for an exact site match. The extension injects those values into the
  selected page once and does not submit the form.
- If the user requests a new site association, local pending-association metadata
  is created for confirmation in the Custode app. It contains no password.

## Storage and retention

The extension uses no browser extension storage and retains no credentials or
search queries. Username and password copies handled by the extension and Native
Messaging host exist only transiently during an explicit fill and are not
retained by either component.

The Custode desktop app necessarily keeps unlocked vault data, including
decrypted credentials and the reveal bridge's credential map, in process memory
while the vault is unlocked. On vault lock, database change, or bridge stop, the
app stops the reveal bridge and clears its in-memory credential map. Dart strings
are garbage-collected; Custode does not claim immediate heap or operating-system
memory zeroization.

Custode credential metadata, bridge state, and pending-association data remain
on the user's computer and are cleared when the vault is locked or the database
is changed. Confirmed or rejected pending associations are also cleared after
processing by the app.

## Data sharing and remote transfer

Custode Browser Autofill has no analytics, advertising, tracking, or remote
code. The extension and Native Messaging host do not send data to a developer
server or cloud service, and do not sell or share user data. During an explicit
fill, credentials are placed into the active website's form fields; the website
may process them if the user submits the form.

Neither the extension nor the Native Messaging host can access the Custode
master password, key files, or KDBX database contents. Vault access and
decryption remain inside the unlocked Custode desktop app.

## Contact and support

Report privacy questions or support issues at:
https://github.com/camillobucciarelli/key-vault-password-manager/issues
