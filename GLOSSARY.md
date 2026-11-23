# Custode

Custode is a cross-platform password manager that keeps the user's credentials in KeePass (KDBX) files, optionally linked to cloud storage, and fills them into apps and browsers.

## Language

### Domain

**Database**:
A KDBX file the user has registered with the app, either local only or linked to a remote copy. It is the locked, on-disk thing the user selects, creates, imports and unlocks.
_Avoid_: Vault (for the file), KDBX (as a noun for the registered item), keystore

**Vault**:
The decrypted content of an unlocked **Database**: its Records, Folders and history. A Vault exists only while its Database is unlocked.
_Avoid_: Database (for the decrypted content), store

**Vault session**:
The period during which one **Database** is unlocked. It is the single shared source of the open **Vault** that every **Feature** observes and sends commands to.
_Avoid_: Unlock session, open database, login

**Folder**:
A container of **Records** and other **Folders** inside a **Vault**. KeePass calls it a group.
_Avoid_: Group (in user-facing language)

**Record**:
One stored credential item inside a **Vault**. KeePass calls it an entry.
_Avoid_: Entry (in user-facing language)

### Structure

**Feature**:
One of four areas of the app: database (selecting, creating, importing and unlocking a **Database**), vault (entries, groups, history, generator, CSV import, passkeys), sync (cloud storage link, merge, conflicts) and autofill (Apple, Android, desktop browser).
_Avoid_: Module, package, area

**Store**:
The object that holds a **Feature**'s presentation state and exposes the actions the UI can trigger.
_Avoid_: Bloc, Controller, ViewModel

**Coordinator**:
The owner of a multi-step sequence that spans several operations and must roll back when a step fails.
_Avoid_: Orchestrator, manager, workflow

**Use case**:
One atomic business action that carries policy, validation or transaction value.
_Avoid_: Interactor, service (for a business action), command

### Navigation

**Page**:
A full-screen destination reached by navigation: selection, creation, unlock, vault shell, settings, browser setup.
_Avoid_: Screen, view

**Surface**:
A piece of UI opened inside the vault shell that returns a typed result and adapts its presentation (route, sheet, pane or dialog) to the available width.
_Avoid_: Modal, popup, sub-page

**Destination**:
One of the four top-level sections of the vault shell **Page**: Vault, Health, Sync, Settings. A Destination is a section inside the vault shell Page, not a Page itself.
_Avoid_: Tab, Page

**Back step**:
The single change one press of system back (Android back, iOS swipe-back) undoes, always returning to what the user saw just before. Inside a **Vault session** the precedence is: open **Surface**, search, **Folder**, **Destination**, then leaving the app; leaving the app from the Vault root does not end the Vault session.
_Avoid_: Back navigation, pop

## Relationships

- A **Database** yields at most one **Vault**, and only while it is unlocked
- A **Vault session** covers exactly one **Database**
- A **Vault** contains **Folders**; a **Folder** contains **Records** and other **Folders**
- Each **Feature** has one or more **Stores**; a Store observes the **Vault session** and never another Feature
- A **Store** triggers **Use cases** and **Coordinators**; a **Coordinator** sequences several operations, a **Use case** performs one
- The vault shell is a **Page**; a **Surface** is opened from within it and returns its result to it
- The vault shell **Page** shows exactly one **Destination** at a time
