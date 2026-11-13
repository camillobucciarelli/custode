# 016 — Device evidence

Hardware observations for the tasks that cannot be proven any other way. Fill a
row in, state `pass` or `fail` explicitly, and record the versions: a verdict
without the IME or browser version is not evidence.

Nothing here is filled in by an agent. Every line is something someone watched
happen on a device.

## Devices used

| Label | Model | Android | API | Screen lock | Biometric enrolled |
|-------|-------|---------|-----|-------------|--------------------|
| D1    | Pixel 11 Pro | 17 | 37 | yes | yes |
| D2    | *(API 29 device still needed)* | | | | |

## T001 — inline suggestions on real IMEs (gates Phase 4 and T102)

Emulator IMEs do not advertise what real ones do. This needs a physical API 30+
device.

Observed on D1 (2026-08-28) against the real implementation rather than a
throwaway probe: the service was built with `supportsInlineSuggestions="true"`
and inline datasets, then the advertisement was read back from the live request.

| IME | Version | Renders inline? | maxSuggestionCount | Style spec | Verdict |
|-----|---------|-----------------|--------------------|------------|---------|
| Gboard | 18.0.5.954559732-release-arm64-v8a | yes | 9 | `androidx.autofill.inline.ui.version:v1`, min 89x126, max 630x126 | `pass` |
| SwiftKey | 9.13.14.5 | yes | 9 | `androidx.autofill.inline.ui.version:v1`, min 90x112, max 600x112 | `pass` |

The two IMEs advertise different slot sizes (126 vs 112 tall), so this is two
genuinely different renderers, not the same one twice.

Traced line, verbatim:

```
# Gboard
D CustodeAutofill: fill: entries=468 targets=[AndroidAutofillServiceIdentifier(type=AndroidPackage, value=it.lene.lene)]
strongMatches=0 usernameFields=1 passwordFields=1 inlineRequested=true maxSuggestionCount=9 specs=9
styleV1=[androidx.autofill.inline.ui.version:v1] minSize=89x126 maxSize=630x126

# SwiftKey
D CustodeAutofill: fill: entries=468 targets=[AndroidAutofillServiceIdentifier(type=AndroidPackage, value=it.lene.lene)]
strongMatches=0 usernameFields=1 passwordFields=1 inlineRequested=true maxSuggestionCount=9 specs=9
styleV1=[androidx.autofill.inline.ui.version:v1] minSize=90x112 maxSize=600x112
```

Framework side of the same request:

```
mSupportInlinePresentations=true
datasets=[ hasInlinePresentation x3, hasPresentation (picker) ]
autoFill(): requestId=878; datasetIdx=2
```

Observed by hand: suggestions appear on the strip showing title and username
only, never a password; tapping one raises the biometric prompt and fills
without opening the picker.

**Gboard nuance worth keeping**: on its *password* keyboard layout Gboard reports
`supportsInlineSuggestion=false`, so the strip appears on the username field and
not on the password field. That is Gboard's behaviour, not ours.

**Verdict**: `pass`. Both a first-party and a third-party IME render our inline
suggestions on a physical device.

> `fail` means Phase 4 is not built and `androidx.autofill` is not added. Say so
> here rather than leaving the phase silently open.

## T002 — compatibility mode exposes a web domain (gates Phase 6 verification)

`<compatibility-package>` is already declared for both browsers.

| Browser | Version | Login page | Observed webDomain | Verdict |
|---------|---------|-----------|--------------------|---------|
| Chrome  | *(record)* | *(record)* | *(record)* | partial — see below |
| Firefox | | | | not run |

The declaration is live on the device:

```
Compat packages: {com.android.chrome=1000000000000, org.mozilla.firefox=1000000000000}
```

**Prerequisite discovered on D1**: Chrome does not delegate to an Android autofill
service until the user turns it on in Chrome (Settings → Autofill services →
use another service). Until then the framework opens no session at all
(`notifyValueChanged: ignoring on state UNKNOWN`, no `startSession`), which reads
as "our service is broken" and is not. This belongs in the quickstart, and
possibly in user-facing setup guidance.

After enabling it, Chrome produced a fill request and our service answered with a
dataset (`mTotalDatasetsProvided=1`).

**Verdict**: not yet — needs the three-domain run on both browsers, with the
webDomain recorded and the "never matches the browser package" check.

If a version has to be excluded, record it and narrow `maxLongVersionCode` in
`android/app/src/main/res/xml/keyvault_autofill_service.xml`.

## T003 — biometric prompt across the API split (gates Phase 3)

| Device | API | Fingerprint enrolled | Prompt shown | Device-credential fallback | Verdict |
|--------|-----|----------------------|--------------|----------------------------|---------|
| | 29 | yes | | | |
| | 29 | no | | | |
| | 31+ | yes | | | |
| | 31+ | no | | | |

**Verdict**: `pass` / `fail` —

## T004 — device with no secure lock (gates Phase 3)

Remove the screen lock, attempt a fill, restore the lock afterwards.

- `BiometricManager.canAuthenticate` returned (verbatim constant):
- Refusal reachable and message shown:

**Verdict**: `pass` / `fail` —

## Quickstart runs

| Section | D1 | D2 | Notes |
|---------|----|----|-------|
| A — authentication gate | | | |
| B — inline suggestions | B1–B3 pass | | B4 not reproducible: Gboard offers 9 slots and no test form matched more than 9 entries. B5 needs the API 29 device. |
| C — save capture | C1–C6 pass | | Run against practicetestautomation.com. C3 needed a copy fix: the app writes KDBX history correctly but has no screen showing it, so the confirmation no longer promises one. |
| D — browsers | | | |
| E — accessibility | | | |
| F — redaction | | | |

## T802 — redaction sweep

Command run and its output (a hit is a failed gate, not a note):

```
adb logcat -d | grep -i -E "password|secret" | grep -v "redacted"
```

```
<paste output, including "no matches">
```

Also checked: nothing under `files/autofill_v2` holds a plaintext password.

## T803 — sign-off

- Sections A–F pass on API 29:
- Sections A–F pass on API 33+:
- Deviations, with device / OS / IME / browser:

---

## What remains, and where it can be done

Written 2026-08-28 at the end of a device session, so the next one does not start
by rediscovering this.

### Doable on the Pixel (D1, API 37) — six tasks

| Task | What to do | Quickstart |
|---|---|---|
| **T301–T304** | The authentication gate: pick an entry and expect a prompt; cancel it and expect nothing filled; authenticate and expect a fill; fill again inside the 30 s reuse window and expect no second prompt, then outside it and expect one. | A 1–4 |
| **T004** | Remove the screen lock, attempt a fill, **restore the lock**. The `canAuthenticate` constant is now traced verbatim by `AutofillAuthGate` — read it from logcat rather than paraphrasing. | A 5 |
| **T003** (half) | API 31+ with and without a fingerprint enrolled. | — |
| **T002** | Three distinct domains on Chrome **and** Firefox, versions recorded, plus the check that no entry ever matches the browser's own package. Remember Chrome needs its own opt-in first. | D |
| **T704** | TalkBack over the picker, a hardware keyboard through it, then both again in dark theme. | E |
| **T802** | The redaction sweep, after a session exercising every flow. | F |

### Needs an API 29 device — two tasks

| Task | Why |
|---|---|
| **T003** (half) | The prompt on the old side of the API split, where `setDeviceCredentialAllowed` is the only equivalent of `setAllowedAuthenticators`. |
| **T803** | Sections A–F on API 29 as well as API 33+. |
| B5 | That an inline-less API still gets the unchanged dropdown-and-picker path (FR-004). The code makes this a no-op by construction, but the point of the task is to see it. |

**The emulator is blocked on host memory, not on anything in this repo.** The
API 29 arm64 image reported `Available Memory: 5109 MB, Required: 5120 MB` and
fell back to software GL rendering, at which point a Flutter debug build on top of
it is effectively frozen and shows as `offline` over adb. It needs roughly half a
gigabyte more headroom than the machine had, and more than that to be usable.
Raising the AVD's own memory makes it worse, not better — that raises the
pressure the check is measuring.

### Not observable on any device we have — one task

**T404**, the "Search Custode" overflow slot. Both Gboard and SwiftKey advertise
`maxSuggestionCount=9`, so it needs a site with more than nine matching entries in
the vault. Either construct one, or accept that only an instrumented test can
cover it and say so in the task.

### Needs a `Context` the module cannot fake — two tasks

**T201** and **T504**. The Android module has no Robolectric, which is why the
testable rules in this spec were extracted into pure objects
(`AutofillAuthSessionWindow`, `SubmittedCredentialExtractor`,
`AndroidAutofillCaptureHolder`). These two are the remainder that genuinely needs
a `Context`. Adding Robolectric is a real decision, not a chore — it belongs in
its own change, not smuggled into this spec.

### Ready to tick on evidence already gathered

**T801**: `dart format` clean, `flutter analyze` clean, `flutter test` 1534
passing, `./gradlew :app:test` green with 96 tests. Its acceptance also asks for
that output in the PR body, and PR #171 carries it.
