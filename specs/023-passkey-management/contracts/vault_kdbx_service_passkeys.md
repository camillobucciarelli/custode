# Contract — `VaultKdbxService` passkey surface

All methods take the existing `(path, credentials)` pair and run under
`DatabasePathMutex` like every other write.

## Read (no new method)

`loadEntries` / entry mapping now produces, per entry:

- `customFields`: every non-standard string **except** keys starting
  `KPEX_PASSKEY_`, each with `isProtected` as read.
- `passkeys`: `PasskeyParser.parse(rawPasskeyFields)` — one `VaultPasskey`
  per suffix group (`""`, `_1`, `_2`, …); never throws; malformed → `usable:
  false`.
- `passkeyDigest`: fingerprint of the raw strings, or `null`.

Invariant: no `KPEX_PASSKEY_*` key ever appears in `customFields`.

## Write (`createEntry`, `updateEntry`, `restoreEntryRevision`, merge)

`_setCustomFields(entry, customFields)`:

1. Remove every non-standard key **outside** the `KPEX_PASSKEY_*` namespace.
2. Re-add `customFields` with `PlainValue` or `ProtectedValue` per
   `isProtected`, skipping any `KPEX_PASSKEY_*` key a caller passes in.

The namespace is therefore left in the `KdbxEntry` exactly as opened.

Invariant (SC-007): for an entry opened and saved without a passkey change,
every `KPEX_PASSKEY_*` string has identical value and identical
`Protected` attribute before and after — including keys the parser does not
understand (`KPEX_PASSKEY_PRF`).

`restoreEntryRevision` restores the revision's editable fields only; the
passkey strings of the current entry stay in place.

## `deletePasskey`

```
Future<void> deletePasskey({
  required String path, required VaultCredentials credentials,
  required String entryId, required String relyingPartyId,
  required Uint8List credentialId,
})
```

- Removes exactly the suffix group whose `(rpId, credentialId)` matches.
- Leaves every other string, binary, tag and history record untouched.
- Appends one history revision (ordinary edit semantics).
- Throws `PasskeyNotFound` when no group matches; throws on a locked or
  read-only session like the other writers.

Caller (`PasskeyCoordinator`) is responsible for confirmation and the dated
backup; the service does neither.

## Adoption writes (passkeys on all platforms, T011)

A passkey whose key was generated elsewhere needs no method of its own:
`createPasskey` takes a complete `VaultPasskey` (rpId, credential id, user
handle, username, PEM, algorithm, BE/BS) and writes it as given.

```
Future<String> createEntryWithPasskey({
  required String databasePath, required String password, String? keyFilePath,
  required String groupId, required String title, required String username,
  required String url, required VaultPasskey passkey,
})

Future<({String? credentialEntryId, List<String> accountEntryIds})>
findPasskeyHolders({
  required String databasePath, required String password, String? keyFilePath,
  required String relyingPartyId, required Uint8List credentialId,
  Uint8List? userHandle,
})
```

- `createEntryWithPasskey` writes a new entry (empty password and notes) and
  its passkey in **one** save and returns the entry id. The `KPEX_PASSKEY_*`
  fields and their `Protected` attributes are the ones `createPasskey` writes
  (both go through `passkeyFieldsFor`). Same path as every other write:
  `DatabasePathMutex`, safe writer; a failed save leaves the file unchanged.
- `findPasskeyHolders` is read-only, one open under the mutex.
  `credentialEntryId` is the entry holding `(rpId, credentialId)` or null;
  `accountEntryIds` lists every entry holding a passkey for
  `(rpId, userHandle)`, with the null-handle rule `createPasskey` uses for a
  clash (no handle matches only no handle). The recycle bin is not searched.
- The caller (adoption coordinator) owns the dated backup, as for
  `createPasskey` and `deletePasskey`; the service takes none.
- The PEM appears in no exception message, log line, `toString` or `props`.

## `PasskeyParser` (pure, `data/services/passkey_parser.dart`)

```
List<VaultPasskey> parse(List<VaultCustomField> rawPasskeyFields)
VaultPasskeyAlgorithm algorithmOf(String pem)   // OID → enum, unknown otherwise
Uint8List decodeBase64Url(String s)             // padded or unpadded
```

Test vectors live beside the test: one ES256, one EdDSA, one RS256 PEM (all
generated for the tests), one truncated PEM, one missing-credential-id set.
