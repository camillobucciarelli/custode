# Contributing

## Project structure

Start with [repository guidelines](AGENTS.md) for commands, testing rules and
branch workflow. Product and architecture work is specified in
[specs/README.md](specs/README.md); its rules come from the
[project constitution](.specify/memory/constitution.md).

Application code has two main roots:

- `lib/core/` contains cross-feature infrastructure, utilities and core DI;
- `lib/features/password_manager/` is the single Password Manager feature. Keep
  its `data/`, `domain/`, `presentation/` and `di/` layers together rather than
  creating provider- or workflow-specific top-level features.

Dependency flow is:

```text
widgets/screens -> BLoCs -> coordinators -> use cases/domain services
    -> repository/port contracts <- data implementations
```

- Three BLoCs live under `presentation/bloc/`: `database_selection`,
  `database_unlock` and `vault`. They translate events into calls and state; keep
  business workflows out of them.
- Use cases hold atomic business actions with policy, validation or transaction
  value. Coordinators under `presentation/coordinators/` sequence multi-step
  workflows and multiple use cases. Do not add pass-through use cases only for
  symmetry.
- Domain repositories/ports define behavior required by the application. Data
  implements them. Data sources access one direct persistence, API, plugin or
  platform boundary; data services compose technical integrations and
  transactions such as OAuth, imports, safe file writes and KDBX operations.
- Dependency injection uses `get_it`: core registrations are in
  `lib/core/di/core_di.dart`, Password Manager registrations are in
  `lib/features/password_manager/di/`, and `lib/injection_container.dart`
  assembles them.

KeePass `.kdbx` files are the vault boundary. `VaultKdbxService` owns KDBX parsing
and semantic edits. Approved raw-byte replacement also occurs in import/writer
services and `DatabaseSyncOrchestrator`; those paths must use the shared
`DatabasePathMutex` and approved backup/safe-writer invariants. Do not force raw
replacement through `VaultKdbxService`, but never add a database-path mutation
that bypasses shared protections. Never log vault secrets or replace the single
externally openable `.kdbx` with an application-specific format.

Cloud sync currently ships only Google Drive. [Spec 010](specs/010-multi-cloud-storage/spec.md)
plans one provider-neutral storage port, with `DatabaseSyncRepository` remaining
the application-facing boundary and a Google data adapter as the sole initial
implementation. Under that planned abstraction, remote identity is always
`(providerId, remoteFileId)`. The abstraction is not yet current code. Do not add
a second provider, provider registry/picker or simultaneous remotes outside that
spec.

Autofill spans Flutter and native/runtime integration:

- Apple coordination is in `apple_autofill_v2_coordinator.dart`, with credential
  provider extensions under `ios/CredentialProviderExtension/` and
  `macos/CredentialProviderExtension/`;
- desktop browser coordination is in `desktop_browser_autofill_*.dart`; extension
  assets live under `desktop/browser_extension/`, native host code under
  `desktop/native_host/`, and Dart protocol/entry points under
  `tool/native_host_protocol.dart` and `tool/native_host.dart`.

Flutter platform projects live under `android/`, `ios/`, `macos/`, `linux/`
and `windows/`. Avoid native changes unless the task requires them and can
be reviewed by the relevant platform specialist.

Tests under `test/` mirror `lib/`; protocol tests also live under `test/tool/`.
Device/runtime checks and manual QA harnesses live under `integration_test/` and
are not collected by ordinary `flutter test`. See [AGENTS.md](AGENTS.md) for
build/test commands and platform-specific QA instructions. Specs follow
`specs/NNN-slug/{spec,plan,tasks}.md`; update the governing spec before changing
approved behavior, security boundaries or architecture.

## Licensing of contributions

This project is distributed under the GNU Affero General Public License v3.0
with the additional permissions stated in `LICENSE-EXCEPTIONS.txt`.

By submitting a contribution (pull request, patch, or any other form) you
certify the [Developer Certificate of Origin](https://developercertificate.org/)
and you agree that your contribution is licensed under:

1. the GNU Affero General Public License version 3 or later, **and**
2. the additional permissions in `LICENSE-EXCEPTIONS.txt`, in particular the
   application store distribution permission.

Point 2 is required: without it the project could no longer be published on the
Apple App Store, Google Play, or the Microsoft Store, whose terms of service are
incompatible with the unmodified AGPL.

## How the CLA is enforced

Every pull request from an account other than the maintainer is checked by the
CLA Assistant workflow (`.github/workflows/cla.yml`). If you have not signed
yet, the bot comments on your pull request; reply with exactly:

```
I have read the CLA Document and I hereby sign the CLA
```

Your signature is stored in the `cla-signatures` branch and applies to all your
future pull requests. The `CLA Assistant` status check must be green before a
pull request can be merged. Full text: [CLA.md](CLA.md).

Sign your commits with `git commit -s` to also record the DCO certification.
