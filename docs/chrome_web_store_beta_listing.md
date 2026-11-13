# Chrome Web Store beta listing

## Store listing

**Name**

Custode Browser Autofill BETA

**Summary**

Beta autofill for Custode desktop through a local Native Messaging host, with
explicit fills only.

**Detailed description**

THIS EXTENSION IS FOR BETA TESTING.

Custode Browser Autofill connects Chrome to the locally installed Custode
desktop app. Open the popup to find credential metadata matching the current
site or search local metadata. For an exact site match, click **Fill on this
page** to request and fill the credential once. Possible or manually selected
matches create a pending site association that must be confirmed in Custode.
Current-tab origin/title and user-entered global-search text are processed only
between the extension, local Native Messaging host, and Custode desktop app.

The extension never reads a KDBX database or requests the master password. The
local Native Messaging host also cannot access the master password or KDBX
contents. Passwords are returned by the running, unlocked desktop app only after
an explicit Fill click. The extension and Native Messaging host use no silent
fill, analytics, browser storage, remote code, developer server, or cloud
transfer.

Custode desktop and the registered Native Messaging host are required. Chrome
and Chromium-based Microsoft Edge are supported. Firefox is not supported by
this build.

**Single purpose**

Find and explicitly fill credentials from the locally running Custode desktop
app into the current browser tab.

## Permission justifications

**`activeTab`**

Grants temporary access to the user-selected active tab after the extension is
opened. Custode reads only that tab's HTTP(S) origin and title for local
credential matching. No persistent host permissions are requested.

**`nativeMessaging`**

Communicates with the locally installed
`dev.camillobucciarelli.keyvault_native_host` process. The host searches local
Custode metadata and requests a one-shot credential from the running, unlocked
desktop app only after the user clicks Fill.

**`scripting`**

Injects one bundled fill function into the active tab only after the user clicks
**Fill on this page** for an exact site match. No persistent content script or
remote script is used.

## Remote code

**Does the extension use remote code?** No.

All JavaScript is bundled in the extension package. No external scripts,
WebAssembly, dynamic code downloads, `eval`, or remote module imports are used.

## Data-use declarations guidance

Answer dashboard wording exactly as presented and keep declarations consistent
with the privacy policy. Conservatively disclose local handling of:

- **Authentication information:** extension and Native Messaging host copies of
  usernames and passwords handled transiently during an explicit Fill. The
  unlocked desktop app necessarily holds decrypted vault data in process memory
  while the vault is unlocked.
- **Personally identifiable information:** a username may be an email address or
  other identifier.
- **Web history:** only the current active tab origin and title, not browsing
  history.
- **Website content:** current page title and form-field structure processed
  locally for matching and fill.
- **User-entered search text:** sent locally through Native Messaging, processed
  against local credential metadata, and not retained by the extension or host.

For each category, state that data is used only for the extension's single
autofill purpose, is not sold or shared, is not used for advertising, credit, or
unrelated personalization, and is not transferred to remote developer or cloud
servers. Processing occurs locally between the browser extension, local Native
Messaging host, and unlocked Custode desktop app. The extension uses no browser
storage or analytics.

Do not claim secure memory erasure or immediate zeroization. Custode desktop is
a Dart application, and its strings are garbage-collected.

**Privacy policy URL**

https://camillobucciarelli.github.io/keyvault-privacy/

## Reviewer test instructions

This extension is not standalone. Testing requires the public Custode source,
Flutter/Dart, the Custode desktop app, and a Native Messaging host registered
for the published extension ID. Do not use production credentials or vaults.

1. Install this beta item from Chrome Web Store. Open `chrome://extensions` and
   copy its 32-character extension ID.
2. Clone the public repository and fetch dependencies:

   ```bash
   git clone https://github.com/camillobucciarelli/key-vault-password-manager.git
   cd key-vault-password-manager
   flutter pub get
   ```

3. Build and register the local host using the published extension ID.

   macOS with Chrome:

   ```bash
   ./tool/build_native_host.sh
   ./desktop/native_host/install_host_macos.sh chrome <PUBLISHED_EXTENSION_ID>
   ```

   Linux with Google Chrome:

   ```bash
   ./tool/build_native_host.sh
   ./desktop/native_host/install_host_linux.sh <PUBLISHED_EXTENSION_ID>
   ```

   Windows PowerShell:

   ```powershell
   dart compile exe tool/native_host.dart -o desktop/native_host/keyvault_native_host.exe
   .\desktop\native_host\install_host_windows.ps1 -Browser Chrome -ExtensionId <PUBLISHED_EXTENSION_ID>
   ```

4. Restart Chrome.
5. Start the desktop app for the reviewer's platform:

   ```bash
   flutter run -d macos
   # or: flutter run -d linux
   # or, from Windows PowerShell: flutter run -d windows
   ```

6. Create or open a non-production test KDBX vault in Custode. Unlock it with
   reviewer-created test credentials. Add a login entry whose URL exactly matches
   a non-sensitive HTTP(S) test page. Keep the app running and unlocked.
7. Open the extension popup. Native host should show **Available** and the app
   bridge should show **Connected**.
8. Open the matching test page, reopen the popup, and click **Find current
   site**. Confirm an exact strong match appears.
9. Click **Fill on this page**. Confirm the test username/password appear in the
   visible login fields only after that click. The extension does not submit the
   form.
10. Lock Custode. Reopen the popup and confirm credential matching/fill is no
    longer available.

No reviewer password is included in this listing. Reviewer creates all test
vault credentials locally.

## Distribution recommendation

Publish as **Private** to a small trusted-tester group first. Register the native
host separately for the stable Web Store extension ID on each tester computer.
After install and review flow is reliable, switch or republish as **Unlisted**
for broader link-only beta access. Do not use Public distribution for this beta.

## Manual dashboard inputs and assets

- Choose category and primary language.
- Add support contact details and the public privacy policy URL above.
- Add trusted tester accounts or organization group before Private publication.
- Upload at least one sanitized 1280x800 or 640x400 screenshot. Do not show real
  vault names, usernames, domains, passwords, file paths, tokens, or extension
  IDs.
- Create required Chrome Web Store promotional image sizes shown by the current
  dashboard, including a 440x280 small promo tile when requested. These are
  listing assets and are not packaged in the extension ZIP.
- Complete pricing/distribution, privacy-practice, and policy certification
  attestations manually in the developer dashboard.
