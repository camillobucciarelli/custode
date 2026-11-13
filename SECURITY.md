# Security Policy

## Reporting a vulnerability

**Do not open a public issue for security vulnerabilities.**

Report privately through GitHub Security Advisories:
https://github.com/camillobucciarelli/custode/security/advisories/new

Include: affected version and platform, reproduction steps, and the impact you
believe the issue has. A proof of concept helps but is not required.

## Response

This project is maintained by a single developer in their spare time. Best
effort targets, not guarantees:

| Stage | Target |
|---|---|
| Acknowledgement of your report | 7 days |
| Initial assessment | 14 days |
| Fix or documented mitigation for confirmed high-severity issues | 90 days |

If you receive no acknowledgement within 14 days, assume the report was not
received and escalate through another channel.

## Disclosure

Coordinated disclosure is requested: please allow a fix to ship before public
disclosure, up to 90 days from acknowledgement. Reporters are credited in the
release notes unless they ask otherwise.

There is no bug bounty program. No monetary reward is offered or implied.

## Supported versions

Only the latest released version receives security fixes. Older versions,
including builds installed from artifacts of previous releases, are not
supported.

## Security model

What this application protects:

- Vault contents are stored in the KeePass `.kdbx` format and encrypted with a
  key derived from the master password. The master password is never
  transmitted off the device.
- When cloud sync is enabled, only the encrypted `.kdbx` file is uploaded. The
  sync provider never receives the master password or the decrypted contents.
- Credentials cached for biometric unlock and OAuth tokens are held in the
  platform keystore (Keychain on Apple platforms, Keystore on Android, the
  equivalent secure store on desktop).

What this application does **not** protect against:

- A compromised operating system, a device with malware, or an attacker with
  root or administrator privileges. On such a device the decrypted vault is
  readable while unlocked.
- A weak master password. Key derivation slows brute force, it does not prevent
  it.
- Physical access to an unlocked device with the vault open.
- Screen capture, clipboard scraping, or accessibility-service abuse by other
  installed applications.

## Audit status

**This project has never received an independent security audit.** The
cryptography is delegated to the `kdbx` Dart package and the platform keystores;
the integration around them has been reviewed only by its author. Evaluate this
accordingly before trusting it with high-value secrets.
