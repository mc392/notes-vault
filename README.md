# GroundWork Notes

A zero-knowledge clinical notes app for BACP counsellors. Built to the requirements in the
[Notes Vault Handover](https://claude.ai/code/artifact/f47578e9-9e6a-4d97-ae93-9fd4381aa3c9)
(29 August 2026), which remains the authority on anything this README contradicts.

Client records are encrypted on this device and written into a folder the counsellor picks
— typically inside their own iCloud Drive. The app makes no network connection of its own,
holds no account, and has no server. There is nothing for us to hand over, because we never
receive anything.

---

## Status — read this first

**Stage 1 is complete as of 30 August 2026.** The code compiles for macOS and iOS with zero
errors and zero warnings on Xcode 15.4, and all 73 tests pass — including the 14 that run
real Cryptomator cryptography against a real folder on disk (25.6s of genuine scrypt, not a
stub). [Run 33304653201.](https://github.com/mc392/notes-vault/actions/runs/33304653201)

It took two CI runs. Neither failure was in the app: the first was `Package.swift` using a
Swift 6 API on a Swift 5 toolchain, the second was XcodeGen emitting an Xcode 16 project
format that Xcode 15 refuses to open. Once those cleared, the app itself compiled clean
first time.

Locally, the whole core is:

```bash
swift test
```

| Area | State |
|---|---|
| Note format, client records, retention rules, vault layout, index | **59 tests passing** against a stubbed engine |
| Cryptomator integration, masterkey files, recovery | **14 tests passing** using real cryptography on a real folder |
| SwiftUI screens | **Compiles** for macOS and iOS — but has never been rendered |
| Xcode project | **Builds** for both platforms, signing off |
| Keychain, biometrics, iCloud placeholder handling | Compiles. **Behaviour untested — needs a device** |

**What a green build does not prove.** No screen in this app has ever been drawn. Nobody has
opened the document picker, seen a recovery key, or synced a note between two devices. A
compiler checks that the code is well-formed, and the tests check that the storage and
cryptography behave; neither has any opinion on whether the app is usable. [RUNNING.md](RUNNING.md)
is how that gets found out.

---

## Building

```bash
brew install xcodegen
xcodegen generate
open NotesVault.xcodeproj
```

`project.yml` is the source of truth for the app target; the `.xcodeproj` is generated and
gitignored, because a `.pbxproj` is a file nobody can review by eye and everybody conflicts
in.

The app icon is generated too. `tools/icon.py` draws it from GroundWork's own palette — the
brand green, the pale ruling, the paper white — and the leaf outline is the exact Bezier from
GroundWork's `A-leaf-refined.svg` rather than a redrawing of it. The PNGs are
committed so the app builds without Python, but they are output rather than source: change
the palette at the top of that file and re-run it, rather than editing the images.

```bash
pip install Pillow && python3 tools/icon.py
```

Requirements: Xcode 15+, iOS 17 / macOS 14 deployment targets. The one external dependency
is [`cryptolib-swift`](https://github.com/cryptomator/cryptolib-swift), resolved by SwiftPM.

---

## Finishing the build

Two stages. Each is cheap, and each rules out a class of failure that would otherwise
muddy the next one. Do them in order — chasing an iCloud sync bug in something that has a
type error in it is a bad afternoon.

### ✅ Stage 1 — compiles and passes its tests. Done 30 August 2026.

`.github/workflows/ci.yml` runs on GitHub's macOS runners on every push and does everything
a compiler can do: `swift test`, then `xcodegen generate` and `xcodebuild` for macOS and iOS
Simulator with signing off. It is green.

**The loop, for when a change breaks it.** Push, then:

```bash
gh run list --limit 1
```

Take the run ID from that and get only what failed — the ID is required, because `gh` cannot
prompt for it while its output is going to a file, and silently writes nothing instead:

```bash
gh run view RUN_ID --log-failed > ci-errors.txt
```

Only lines containing `error:` matter; ignore `warning:`. A build that fails in under thirty
seconds is a setup or toolchain problem, not your code — nothing has been compiled yet at
that point.

### Stage 2 — a Mac and an iPhone

**Step-by-step walkthrough: [RUNNING.md](RUNNING.md).** Written for a borrowed Mac, and
arranged so that by the end of the session TestFlight delivers new builds to the phone
without needing one again.

What only hardware can answer, and what a simulator would lie about:

- **The document picker into a live iCloud Drive folder.** The handover's own first next
  step, and the single most likely thing to need rework. Security-scoped bookmarks behave
  differently on device, and a folder inside iCloud Drive is not the same as a folder that
  merely looks like one.
- **The Cryptomator interop check.** Open an app-created vault in Cryptomator's own app. It
  is the only evidence that the format is right which does not depend on our own tests
  agreeing with themselves. If it fails, the bug is in `VaultBootstrap` or `VaultLayout` and
  no amount of device testing will find it. The reverse direction matters too: a vault made
  by Cryptomator should open here, with any `.c9s` shortened names *reported and skipped*
  rather than crashing a listing.
- **Placeholder downloads.** Put the phone in airplane mode, add a note on the Mac, then open
  the vault on the phone with data back on. `FileSystemVaultStore.ensureDownloaded` is
  written for exactly this and has never faced it.
- **Face ID / Touch ID.** `NSFaceIDUsageDescription` is set; biometrics do not meaningfully
  exist in a simulator.
- **Two devices, both offline, both writing.** Write a note for the same client on each with
  sync off, then let them both sync. Both notes must survive — this is the append-only claim,
  and the property the whole file format was chosen for.
- **Background sync with file protection.** Confirm notes written while the phone is locked
  still upload.

### Acceptance run before anyone else touches it

The MVP definition of done is "a counsellor could run their entire clinical record-keeping
through this". That means these all pass on real hardware, not just in the simulator:

| # | Check | What it proves |
|---|---|---|
| 1 | Create vault → recovery key shown → typed back → accepted | The highest-consequence screen works |
| 2 | Raw folder in Finder shows only `d/…` and the masterkey files | Nothing identifying is synced |
| 3 | Note written, app force-quit, reopened, note reads back | Nothing lives only in memory |
| 4 | Correction written; original still visible under "Show corrected" | Append-only, audit trail |
| 5 | Same vault opened on the second device; both notes present | The sync story |
| 6 | Both devices offline, one note each, then sync | No overwrite — the core format claim |
| 7 | Forget passphrase → recovery key → new passphrase → notes intact | The recovery route end to end |
| 8 | Change passphrase, then check the old recovery key still works | The deviation below, actually working |
| 9 | Client marked ended with an old last session appears in Retention | The flagging rule |
| 10 | Destroy: export first, tick, type the code, three-second arm | Deliberate destruction |
| 11 | Exported `.note` opens in TextEdit and is readable | No lock-in |
| 12 | Vault opens in Cryptomator's own app | No lock-in, independently verified |

### Repository and visibility — decided

Its own repository, deliberately separate from GroundWork's, and **public** (decided 30
August 2026).

Two things follow from that. GitHub's macOS runners are free on public repositories, which
is what makes Stage 1 possible without owning a Mac. And the trust claim becomes checkable:
for a product whose entire promise is that it cannot read your notes, "read the code and see
what it does" is stronger than any badge on a marketing page — which is the same reasoning
that makes Cryptomator open source.

The repository holds no client data, no keys and no credentials, and `.gitignore` is written
to keep it that way — `*.note`, `*.cryptomator` and exported folders can never be committed
by accident. Anything added later that touches real notes needs the same care.

---

## How it is put together

Five layers, matching the handover's architecture section. The important structural choice
is that **`NotesVaultCore` has no crypto dependency at all** — it talks to a
`VaultCryptoEngine` protocol and a `VaultFileStore` protocol. That is what lets the entire
vault layout, note format and retention engine be tested in-memory in under a second, and
it means nothing in the core module can quietly grow its own cryptography.

```
NotesVaultCore        pure logic, no dependencies
  ClientCode          "never store a name", enforced by the type system
  NoteRecord          the on-disk note format: plain text, headers, immutable
  ClientRecord        append-only client metadata; latest write wins
  Retention           7 years / age 25, flags only, never deletes
  VaultLayout         Cryptomator format-8 paths over the engine protocol
  VaultStore          clients, notes, corrections, index rebuild, export
  VaultIndex          the cache's shape and how it is derived
  RecoveryKey         160-bit key, Crockford Base32, CRC-16 checked

NotesVaultCrypto      the platform edge
  CryptomatorEngine   VaultCryptoEngine backed by the audited library
  VaultBootstrap      masterkey files, the signed vault config, recovery
  FileSystemVaultStore  security scope, file coordination, iCloud placeholders
  KeychainStore       index key + optional biometric passphrase
  IndexStore          the encrypted local cache
  VaultBookmark       remembering which folder, across launches

NotesVaultApp         SwiftUI, one AppModel, everything serialised through it
```

### What the folder actually looks like

Decrypted, on the counsellor's screen:

```
SM2/
  2026-06-14T0930-iphone.note
  2026-06-21T0930-iphone.note
  2026-06-28T0940-mac.note
  2026-06-28T1015-mac-K3M9.client
```

In iCloud Drive:

```
d/D7/F3KQ8W2M.../
  9a1c4e2b....c9r
  2f08b7ad....c9r
```

Folder names, filenames, dates, client codes and content are all inside the encryption
boundary. The raw folder shows how many files exist and roughly how big they are, and
nothing else.

---

## Decisions from the handover, and where they live

| Decision | Where |
|---|---|
| Product for other counsellors, not internal | Onboarding, error copy and `PrivacyExplainerView` are written for a stranger |
| Mac + iPhone only | One multiplatform target, `supportedDestinations: [iOS, macOS]` |
| Typed notes only | `NoteEditorView`. No camera, photo, or microphone usage strings — the app cannot ask for them |
| Cryptomator's vault format | `CryptomatorEngine` + `VaultBootstrap`. All cryptography is delegated; there is no bespoke primitive to review |
| Freemium | Not built. No paywall, no entitlement check, no analytics — nothing to unpick when the free/paid line is decided |
| Separate brand, shared trust story | **Revised 30 August 2026.** Named *GroundWork Notes* and given GroundWork's icon language, so the trust story is shared openly rather than implied. Still a standalone package with its own bundle ID and no shared code — the tie is brand, not architecture |
| Configurable templates, freeform default | `NoteTemplate`. A template prefills and then gets out of the way; nothing enforces headings |
| Recovery phrase, shown once | `RecoveryKey` + `RecoveryKeyView` — **see the deviation below** |
| Identity register external | `ClientCode` rejects anything with a space or punctuation. There is nowhere to put a name |
| MVP = sole clinical record system | Export, retention, corrections and recovery are all finished paths, not stubs |

### Two deliberate deviations

**1. The recovery key is characters, not words.** The handover says "recovery phrase". I
built a 160-bit key rendered as nine groups of four Crockford Base32 characters
(`K3M9-A7QP-2FTV-…`) rather than BIP-39 words.

A word list is only unambiguous if everyone agrees *which* list — and a counsellor writing
this on paper in 2026 and typing it back in 2033 is relying on the app still knowing.
Crockford's alphabet needs no external list, excludes the four characters people actually
mistranscribe (`I`, `L`, `O`, `U`), folds them on input, and carries a CRC-16 so a typo is
caught while they are typing rather than after an eight-second key derivation returns
"wrong passphrase". There is a test asserting that every possible single-character typo is
rejected.

If you would rather have words, `RecoveryKey` is the only type that changes.

**2. Recovery does not encode the vault key.** The key is a high-entropy passphrase for a
*second* masterkey file (`masterkey.recovery.cryptomator`) wrapping the same vault key. So
the recovery route uses the same audited lock/unlock path as the ordinary passphrase, with
no custom cryptography anywhere in it — and changing the passphrase does not invalidate the
piece of paper in the counsellor's safe.

---

## Not built, on purpose

Everything in the handover's "Deferred" column: photo capture and on-device OCR, dictation,
Windows and Android, OneDrive and Google Drive, enforced templates, risk-flag fields, a
built-in identity register, scheduled deletion, and any live link to GroundWork.

Also not built: any paywall, any analytics, any crash reporter. An app whose pitch is "we
receive nothing" should not ship with an SDK that phones home, and adding one later is a
decision someone should have to make on purpose.

---

## Open engineering items

These are real, and none of them is hidden in a comment nobody reads.

**Plaintext briefly touches disk when encrypting.** Cryptomator's library exposes content
encryption only as `encryptContent(from: URL, to: URL)`; the stream overloads that would
keep a note in memory are `internal`. So each note is written to a scratch file for the
length of one call. `PlaintextScratch` handles it deliberately — unique directory, complete
file protection on iOS so the key is evicted when the device locks, contents overwritten
before unlinking — but the honest fix is upstream: a small PR making those overloads public
deletes that file entirely. Worth doing before launch.

**Name shortening is guarded, not implemented.** Cryptomator shortens ciphertext names over
220 characters into `.c9s` directories. This app's own names (a client code plus a
timestamp) are never close, so `VaultLayout` throws a clear error instead of implementing a
path it could never test. A vault created *by Cryptomator* containing long names will have
those entries skipped and reported, not silently dropped.

**Multi-device writes are safe; multi-device metadata is last-write-wins.** Notes cannot
conflict — each is a separate file, never overwritten, which is the whole point of the
append-only format. Client *metadata* folds to the latest write, so changing a client's
status on two devices while both are offline keeps the later one. That is a deliberate,
documented trade-off rather than the silent whole-state clobber GroundWork has as a known
limitation.

**The index is a cache and nothing else.** Losing, corrupting or finding it stale costs a
rebuild, never a note. Nothing is ever read from it that was not written to a vault file
first.

**Retention rule for minors takes the later of the two dates.** Age 25 *or* seven years from
last contact, whichever falls later — a client seen as a minor years ago is now past 25 and
the seven-year rule is what still applies. Both directions have a test. Confirm the reading
with the counsellor's insurer before launch; the constant is one field on `RetentionPolicy`.

## Open product questions, unchanged from the handover

The product name is settled: **GroundWork Notes**, decided 30 August 2026, with an icon drawn
in GroundWork's colours and carrying their leaf: a page, a green band across the top, four ruled
lines, and the leaf stamped on the lower right. The leaf inverts GroundWork's treatment, a green body with a pale midrib, because here it
sits on paper rather than on their sage gradient.

Two things about that direction are deliberate rather than oversights. It does not carry
GroundWork's dark sage background, so the two apps read as the same brand's rather than as an
obvious pair; that was traded for being legible as a notes app at a glance. And the layout is a
widespread convention rather than anyone's property, but Apple's review guideline 4.1 does
police icons confusingly similar to their own — the green band and the leaf are what keep this
clear of it, so they should stay doing real work if the design is ever revised.

iOS truncates home-screen labels at roughly twelve characters, so the icon is labelled
**GW Notes** via `CFBundleDisplayName`; `CFBundleName` keeps the full name for the macOS menu
bar and for App Store Connect.

Still open, still not quietly assumed anywhere in this code: the free/paid
line, the ToS and liability posture, App Store review risk for a clinical-records app, the
iCloud-only launch excluding Windows and Android users, and the support policy for the
inevitable lost-recovery-key tickets.

The last one is the one to write down first. The app tells the counsellor plainly that
nobody can recover their notes. Support needs to be able to say the same thing, in the same
words, without sounding like it is hiding something.
