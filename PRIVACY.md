# Privacy Policy

**Application:** Custode Password Manager
**Data controller:** Camillo Bucciarelli
**Contact:** bucciarelli.camillo92@gmail.com
**Last updated:** 2026-11-14

## Summary

This application collects nothing. There is no account, no telemetry, no
analytics, no crash reporting, and no advertising. The developer receives no
data from your device. The only server the developer operates is a static file
host used by the optional, off-by-default update check described below; it
receives no identifiers and no vault data.

## Data stored on your device

| Data | Where | Purpose |
|---|---|---|
| Vault contents (entries, passwords, notes, TOTP secrets) | Encrypted `.kdbx` file in a location you choose | The core function of the application |
| Master password, only if you enable biometric unlock for a database | Platform keystore (Apple Keychain, Android Keystore, OS secure store on desktop), in an entry scoped to that database | Serving a biometric unlock of that same database. Removed immediately when you disable biometric unlock. Without biometric unlock the master password is never written to the keystore; it exists only in memory while the vault is unlocked. |
| Google OAuth tokens, only if you enable cloud sync | Platform keystore | Authenticating to your own cloud storage |
| Preferences (theme, selected database path, update-check setting and the last version seen) | Application preferences storage | Restoring your settings |

This data never leaves your device except through the cloud sync you explicitly
enable, described below. It is not accessible to the developer.

## Optional cloud sync

Cloud sync is off by default. If you enable it:

- You authenticate directly with Google. The developer never sees your Google
  credentials.
- Only the **encrypted** `.kdbx` file is uploaded. Your master password is never
  uploaded, and the file cannot be decrypted without it. Google, and anyone who
  obtains the file, sees ciphertext.
- The file is stored in **your own** Google Drive, under your own account and
  your agreement with Google. The developer has no access to it.
- Google's handling of that data is governed by the Google Privacy Policy:
  https://policies.google.com/privacy

Disabling sync stops all uploads. Deleting the file from your Google Drive
removes the cloud copy; the developer cannot do this for you because the
developer has no access.

## Optional update check

The update check is off by default, and the application makes no request for it
until you turn on "Check for updates" in Settings. If you enable it:

- The application sends one HTTPS GET request per day (and one when you turn the
  setting on) to `https://custode.camillobucciarelli.dev/latest.json`, a static
  file hosted on Cloudflare R2 and operated by the developer.
- The request carries no identifiers and no vault data. As with any web
  request, the server sees your IP address and standard HTTP request metadata.
  The developer does not use these to profile you.
- The file contains only the latest version number. The application compares it
  with its own version and, if a newer one exists, shows a link to the download
  page, which opens in your system browser only when you tap it.

Turning the setting off stops all such requests. The web build never performs
this check.

## Autofill

The autofill integrations (Android autofill service, Apple credential provider,
desktop browser extension with native messaging host) run locally on your
device. Credentials are passed from the vault to the requesting application or
browser through operating system channels. Nothing is sent over the network, and
no record of autofill usage is transmitted anywhere.

## Network connections

The application connects only to:

- `accounts.google.com` and `oauth2.googleapis.com` — sign-in, only when you
  enable cloud sync
- `www.googleapis.com` — Google Drive upload and download, only when you enable
  cloud sync
- `custode.camillobucciarelli.dev` — the update check, only when you enable
  "Check for updates"
- `127.0.0.1` on a local port — detecting the desktop native messaging host for
  browser autofill. This connection never leaves your computer.

Opening the browser extension page, the native host download or the download
page uses links handed to your system browser; the application itself makes no
request to those sites.

The only connection to a server operated by the developer is the optional
update check above. It is off unless you turn it on.

## Third parties

There are no analytics providers, advertising networks, or data processors. No
data is sold, shared, or disclosed, because none is collected. The only third
parties involved are Google, only for the cloud sync you choose to enable under
your own account, and Cloudflare, which hosts the static file of the optional
update check.

## Your rights

Because no personal data is collected or processed by the developer, there is
no data to access, correct, export, or erase on the developer's side. All your
data is under your direct control:

- **Export:** your vault is a standard `.kdbx` file, readable by KeePass and
  compatible clients.
- **Erase:** delete the `.kdbx` file and uninstall the application. Uninstalling
  removes the keystore entries. Delete any cloud copy from your own Drive.

Under the GDPR the developer acts as a data controller with no processing
activity. Enquiries may be sent to the contact address above.

## Children

The application is not directed at children under 13 and collects no data from
any user regardless of age.

## Changes

Changes to this policy are published in this file in the public repository, with
the "Last updated" date revised. The Git history is the authoritative record of
every revision.
