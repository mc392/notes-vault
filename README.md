# Notes Vault

A zero-knowledge clinical notes app for BACP counsellors. Built to the requirements in the
[Notes Vault Handover](https://claude.ai/code/artifact/f47578e9-9e6a-4d97-ae93-9fd4381aa3c9)
(29 August 2026), which remains the authority on anything this README contradicts.

Client records are encrypted on this device and written into a folder the counsellor picks
— typically inside their own iCloud Drive. The app makes no network connection of its own,
holds no account, and has no server. There is nothing for us to hand over, because we never
receive anything.

---

## Status — read this first

**The code is complete for the v1 scope. It has not been compiled or run.** This machine is
Windows: no Swift toolchain, no Xcode, no simulator, no device. Every line here was written
against the real published API of `cryptolib-swift` (checked against its source, not from
memory), but "it should compile" is not "it compiles", and I am not going to pretend
otherwise.

The fastest route to knowing where you stand is to push and let CI tell you — see
**Finishing the build** below. Locally it is:

```bash
swift test
```

73 tests over the storage format, vault layout, retention rules and the real Cryptomator
integration, with no Xcode, no signing and no device.

| Area | State |
|---|---|
| Note format, client records, retention rules, vault layout, index | Written, 59 tests against a stubbed engine, **not yet run** |
| Cryptomator integration, masterkey files, recovery | Written, 14 integration tests using real cryptography on a real folder, **not yet run** |
| Keychain, biometrics, iCloud placeholder handling | Written against the real APIs, **needs a device** |
| SwiftUI screens | Written, **never rendered** |
| Xcode project | Generated from `project.yml`, **never opened** |

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

Requirements: Xcode 15+, iOS 17 / macOS 14 deployment targets. The one external dependency
is [`cryptolib-swift`](https://github.com/cryptomator/cryptolib-swift), resolved by SwiftPM.

---

## Finishing the build

Three stages. Each is cheap, and each rules out a class of failure that would otherwise
muddy the next one. Do them in order — chasing an iCloud sync bug in something that has a
type error in it is a bad afternoon.

### Stage 1 — no Mac required, do it today

Push. `.github/workflows/ci.yml` runs on GitHub's macOS runners and does everything a
compiler can do:

- `swift test` — 73 tests across the core (stubbed crypto, fast) and the crypto integration
  target (real scrypt, real vault, real folder on disk);
- `xcodegen generate` then `xcodebuild` for **macOS** and **iOS Simulator**, signing off.

That answers: does it compile, does it link, does `project.yml` produce a valid project, and
is what lands on disk a genuine Cryptomator vault.

**Expect the first run to be red.** Nearly six thousand lines of Swift have never been near
a compiler. Work top-down — in Swift the first error routinely explains the next five, and
re-running after each fix is faster than reading the whole log.

macOS runner minutes are free for public repositories and bill at 10× the Linux rate for
private ones, which is worth knowing before this runs on every push.

### Stage 2 — on a Mac, a couple of hours

1. `xcodegen generate && open NotesVault.xcodeproj`, run the macOS target.
2. Click the whole flow through: create a vault in an empty folder, write down the recovery
   key, type it back, add a client, write a note, lock, unlock, correct the note, export.
3. **The interop test, which is the highest-value hour in this whole list.** Install
   [Cryptomator](https://cryptomator.org) and point it at the vault this app created, using
   the same passphrase. If it opens and shows `SM2/2026-06-14T0930-mac.note` with readable
   content, the vault format is correct — verified against the reference implementation
   rather than against my own assumptions. If it does not open, the bug is in
   `VaultBootstrap` or `VaultLayout`, and no amount of device testing will find it.
4. Then the reverse: create a vault in Cryptomator, open it in this app. It should be empty
   and usable, and any long or `.c9s`-shortened names should be *reported and skipped*
   rather than crashing a listing.

### Stage 3 — real devices, and an Apple Developer Program membership (£79/$99 a year)

Only hardware answers these, and the simulator will cheerfully lie about all of them:

- **The document picker into a live iCloud Drive folder.** This is the handover's own first
  next step, and the single most likely thing to need rework. Security-scoped bookmarks
  behave differently on device, and a folder inside iCloud Drive is not the same as a folder
  that merely looks like one.
- **Placeholder downloads.** Put the phone in airplane mode, add a note on the Mac, then open
  the vault on the phone with data back on. `FileSystemVaultStore.ensureDownloaded` is
  written for this and has never faced it.
- **Face ID / Touch ID.** `NSFaceIDUsageDescription` is set; biometrics do not exist in the
  simulator in any meaningful way.
- **Two devices, both offline, both writing.** Write a note for the same client on each with
  sync off, then let them both sync. Both notes must survive. This is the append-only claim,
  and it is the property the whole file format was chosen for.
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

### One decision to make before pushing

This is its own repository, deliberately separate from GroundWork's — which is public, and
is not where a product you intend to sell should land by accident. The remaining choice is
whether *this* repository is public or private when it reaches GitHub.

It cuts both ways. For a zero-knowledge product, being publicly auditable is a genuine
asset: Cryptomator itself is open source, and "read exactly what we do with your notes" is a
stronger claim than any badge on a marketing page. Against that, it is a product with a
paid tier to design. Either is defensible; what matters is that it is chosen. Note also that
GitHub's macOS runners — which Stage 1 depends on — are free on public repositories and
bill at 10× the Linux rate on private ones.

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
| Separate brand, shared trust story | Standalone package, own bundle ID, no code shared with GroundWork |
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

Still open, still not quietly assumed anywhere in this code: the product name, the free/paid
line, the ToS and liability posture, App Store review risk for a clinical-records app, the
iCloud-only launch excluding Windows and Android users, and the support policy for the
inevitable lost-recovery-key tickets.

The last one is the one to write down first. The app tells the counsellor plainly that
nobody can recover their notes. Support needs to be able to say the same thing, in the same
words, without sounding like it is hiding something.
