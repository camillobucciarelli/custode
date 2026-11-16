# Google Play listing

Draft texts for the Play Console. Everything below describes features that
exist in the app today. The app interface is in English only, so the Italian
listing describes an English-language app; say so in the full description or
decide whether to publish the Italian listing at all.

## Store listing: English (default)

**App name** (max 30)

Custode Password Manager

**Short description** (max 80)

Open-source KeePass (.kdbx) password manager with Android autofill and TOTP.

**Full description** (max 4000)

Custode is a free, open-source password manager that stores your vault in the
standard KeePass .kdbx format. Your passwords live in one encrypted file that
you control and that any KeePass-compatible app can open.

No account. No ads. No analytics. No crash reporting. The developer receives no
data from your device.

Features

- KeePass .kdbx vaults: open existing databases or create new ones, and keep
  full compatibility with other KeePass clients.
- Biometric unlock: optionally unlock a database with your fingerprint or face.
  The master password is then kept in the Android Keystore and removed when you
  turn the option off.
- Android autofill: fill usernames and passwords in apps and browsers through
  the system autofill service.
- TOTP codes: store one-time password secrets next to the entry and scan the
  QR code with the camera. Scanning happens on your device.
- Password generator and entry editor with custom fields, including protected
  fields.
- Password history: see earlier values of an entry.
- Optional Google Drive sync: keep your vault in step across devices. Only the
  encrypted .kdbx file is uploaded, to your own Google Drive, and sync is off
  until you turn it on. Conflicts between devices are resolved field by field.
- Optional update check, off by default; not available in Google Play installs (disabled and hidden when the installer is Google Play).
- Also available for iOS, macOS, Windows, Linux and as a desktop browser
  autofill extension.

Privacy by design

Your master password is never uploaded and the vault cannot be read without it.
Cloud sync and the update check make no network requests until you enable them.

Open source

Custode is licensed under AGPL-3.0. Source code and privacy policy:
https://github.com/camillobucciarelli/custode

## Store listing: Italiano

**Nome dell'app** (max 30)

Custode Password Manager

**Descrizione breve** (max 80)

Password manager open source per KeePass (.kdbx) con autofill Android e TOTP.

**Descrizione completa** (max 4000)

Custode è un password manager gratuito e open source che salva la tua cassaforte
nel formato standard KeePass .kdbx. Le tue password stanno in un unico file
cifrato che controlli tu e che qualsiasi app compatibile con KeePass può aprire.

Nessun account. Nessuna pubblicità. Nessuna analisi d'uso. Nessun report dei
crash. Lo sviluppatore non riceve alcun dato dal tuo dispositivo.

Funzioni

- Cassaforti KeePass .kdbx: apri database esistenti o creane di nuovi, con piena
  compatibilità con gli altri client KeePass.
- Sblocco biometrico: se vuoi, sblocca un database con impronta o volto. La
  password principale viene conservata nel Keystore di Android e rimossa quando
  disattivi l'opzione.
- Autofill Android: compila nomi utente e password nelle app e nei browser
  tramite il servizio di compilazione automatica del sistema.
- Codici TOTP: salva i segreti delle password monouso accanto alla voce e
  inquadra il codice QR con la fotocamera. La scansione avviene sul dispositivo.
- Generatore di password ed editor delle voci con campi personalizzati, anche
  protetti.
- Cronologia delle password: consulta i valori precedenti di una voce.
- Sincronizzazione opzionale con Google Drive: tieni la cassaforte allineata tra
  i dispositivi. Viene caricato solo il file .kdbx cifrato, sul tuo Google Drive,
  e la sincronizzazione resta spenta finché non la attivi. I conflitti tra
  dispositivi si risolvono campo per campo.
- Controllo aggiornamenti opzionale, disattivato per impostazione predefinita.
- Disponibile anche per iOS, macOS, Windows, Linux e come estensione per
  l'autofill nei browser desktop.

Privacy fin dalla progettazione

La password principale non viene mai caricata e la cassaforte non si legge senza
di essa. La sincronizzazione cloud e il controllo aggiornamenti non effettuano
richieste di rete finché non li attivi.

Open source

Custode è distribuito con licenza AGPL-3.0. Codice sorgente e informativa sulla
privacy: https://github.com/camillobucciarelli/custode

Privacy policy URL for the Console:
https://github.com/camillobucciarelli/custode/blob/main/PRIVACY.md

## Data safety draft

Derived from PRIVACY.md and the code. Review every row before submitting.

| Question | Answer | Basis |
|---|---|---|
| Does the app collect or share user data? | Yes, see below (the Drive upload is the only item) | Optional Drive sync |
| Data encrypted in transit | Yes | HTTPS only (Google APIs, update check) |
| Can users request data deletion? | Yes, the user deletes the file and the Drive copy; the developer holds no data | PRIVACY.md, Your rights |
| Analytics, advertising, crash reporting | None | PRIVACY.md |
| Account required | No | PRIVACY.md |

Data types:

- Files and docs: the encrypted .kdbx vault is uploaded to the user's own Google
  Drive, only when the user turns on sync. Purpose: app functionality. Optional.
  The developer never receives it. Whether Play treats a user-initiated upload
  to the user's own Drive as "collected" or "shared" is a Console judgment call;
  review it against the current Data safety help text before answering.
- Device or other IDs, location, contacts, messages, photos, audio, health,
  financial info, web history: not collected.
- Update check (optional, off by default, disabled in Google Play installs): one HTTPS request to a static file;
  the server sees the IP address, and the developer does not use it. If the
  Console asks about IP address processing, answer for this request.
- Camera: used on device to scan TOTP QR codes. Frames are not stored or sent by
  the app. Camera is a permission, not a Data safety data type.
- Open point, not verified: the Android build bundles the ML Kit barcode
  scanner (default of `mobile_scanner`, no unbundled override in
  `android/gradle.properties`). Scanning runs on device, but whether ML Kit
  itself reports usage or performance metrics to Google was not verified from
  the code or from the plugin README. Check the ML Kit data disclosure page
  before declaring "no data collected", and extend PRIVACY.md if it applies.

## Graphic assets

All under `docs/store_assets/google_play/`. Entry names in the screenshots are
neutral demo data: no real brands or logos.

- `icon-512.png`: app icon, 512 x 512, 32-bit PNG. Copy of
  `assets/logo/app_icon_family/app-512.png` converted from RGB to RGBA.
- `feature-graphic.png`: 1024 x 500, 24-bit PNG.
- `phone/`: six screenshots, 1080 x 1920 (`01-vault`, `02-entry-detail`,
  `03-generator`, `04-unlock`, `05-health`, `06-sync`).
- `tablet-7/`: the same six, 1200 x 1920.
- `tablet-10/`: the same six, 1600 x 2560.
- Optional promo video (YouTube URL): not created.

Regenerate the feature graphic and every screenshot (macOS; the file is not a
`*_test.dart`, so no test run or CI job picks it up):

```bash
fvm flutter test test/store_screenshots/google_play_assets.dart
```

`icon-512.png` is not produced by that command; redo the copy by hand if the
source icon changes.
