# Safari Adapter (Experimental)

This folder provides tooling to convert the existing WebExtension into a Safari-compatible Xcode project.

## Generate Safari project

From repository root:

```bash
./desktop/safari/convert_extension_to_safari.sh
```

Optional custom name/bundle id:

```bash
./desktop/safari/convert_extension_to_safari.sh CustodeSafariAutofill dev.camillobucciarelli.kdbxKeyVault.safari
```

Generated project output:

- `desktop/safari/generated/`

## Keep Safari project in sync after extension updates

When you update files in `desktop/browser_extension`, sync them to the Safari extension target folder:

```bash
./desktop/safari/sync_extension_assets.sh "desktop/safari/generated/<AppName>/Shared (Extension)"
```

## Xcode steps

1. Open generated Xcode project.
2. Set signing team for both targets (container app + web extension).
3. Build and run the container app once.
4. Enable extension in Safari settings.

## Important note about transport

Current desktop autofill transport is optimized for Chromium/Firefox through native messaging.

Safari support is marked experimental because end-to-end native host communication in this repository
still needs Safari-specific runtime validation and signing/distribution hardening.
