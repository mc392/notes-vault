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
| Import: readers for Word, Excel, CSV, text, RTF, HTML, Evernote; grouping, mapping, name scan, metadata fields, writer | **93 tests passing**, including real `.docx` and `.xlsx` fixtures |
| Session schedules: predicting what needs writing up, the roster file, planning a sync | **39 tests passing**, fourteen of them cross-checked against GroundWork's own implementation |
| Import screens, PDF text, picking files and folders | **Compiles** for macOS and iOS. **Never rendered**, like the rest of the UI |
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

## Knowing which sessions need writing up

The app suggests the sessions a client should have had and has no note for — on the client's
screen, and as one-tap dates on the note editor. It works out those dates itself, from the notes
already in the vault plus a cadence ("weekly, Tuesdays at 09:30") stored in the client's metadata
log, so a Mac that has never been in contact with GroundWork gets the right answer as long as
iCloud has brought the vault across.

The cadence comes from GroundWork, through a small file — client codes and appointment times, no
names and nothing clinical. Settings › GroundWork › Sync schedules: pick the file once, and every
later sync re-reads whatever GroundWork last wrote there. Nothing goes back the other way; whether
a note has been written stays a tick in GroundWork, done by hand.

The rule both apps implement is written down in **[docs/schedule-sync.md](docs/schedule-sync.md)**,
because they are two implementations in two languages and a disagreement between them shows up as
the wrong dates in front of a counsellor. `SessionScheduleTests` asserts fourteen cases against it;
GroundWork's `scripts/check-schedule-parity.mjs` asserts the same fourteen, with the same expected
output, against its own code.

A cancelled session leaves no trace in the vault, so its date will still be suggested. That is why
these are offered as dates to pick from rather than as a list of work outstanding.

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
  exist in a simulator. A simulated non-match can be sent (`notifyutil -p
  com.apple.BiometricKit_Sim.pearl.nomatch`), which exercises the decline path, but a real
  *failed* check — wrong face, then wrong passcode — only happens on hardware.
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
| 13 | Import a folder of notes with Wi-Fi off; check the raw folder afterwards | The import claim, demonstrated the way the screen says it can be |
| 14 | Export a client's Apple Notes as Markdown into a folder, then import that folder | The route most people will actually take, end to end |
| 15 | Import notes with a `Session number:` header, store it as a field, read it back | Metadata becomes metadata rather than prose |
| 16 | Background the app, reopen it: Face ID is asked for, and the app switcher card is the splash | The lock policy, and the privacy shield |
| 17 | Fail Face ID three times against a note, then fail the passcode | "That check didn't pass", and the passphrase is the only way back |

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
  Import/             reading other people's files: dates, CSV, RTF, HTML, zip,
                      .docx, .xlsx, Evernote, splitting, grouping, the name scan,
                      the plan the counsellor confirms, and the writer

NotesVaultCrypto      the platform edge
  CryptomatorEngine   VaultCryptoEngine backed by the audited library
  VaultBootstrap      masterkey files, the signed vault config, recovery
  FileSystemVaultStore  security scope, file coordination, iCloud placeholders
  KeychainStore       index key + optional biometric passphrase
  IndexStore          the encrypted local cache
  VaultBookmark       remembering which folder, across launches

NotesVaultApp         SwiftUI, one AppModel, everything serialised through it
  SplashView          the launch screen, and the shield over a backgrounded app
  AppModel            the lock policy lives here: `confirmIdentity`, `becameActive`
```

`LockPolicy` (Core) and `DeviceCheck` (Crypto) are the two new pieces of that picture:
where the app asks who you are, and how it asks. See "When the app asks who you are".

### What the folder actually looks like

Decrypted, on the counsellor's screen:

```
SM2/
  2026-06-14T0930-iphone-k3m.note
  2026-06-21T0930-iphone-k3m.note
  2026-06-28T0940-mac-7f2.note
  2026-06-28T1015-mac-7f2-K3M9.client
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

## When the app asks who you are

Rationalised on 31 August 2026. There is one rule, and it is short: **the check is at the
door.** Coming back to the app is the door; once inside, the only two things worth asking
about again are the clinical content itself and the settings that decide who can get in.

| Moment | What happens |
|---|---|
| Cold launch | Splash → the unlock screen, which starts Face ID / Touch ID itself if it is set up. Nothing of the vault is on screen until it opens |
| Coming back to the app | A check — Face ID, Touch ID or the device passcode — unless the counsellor has chosen a grace period and is inside it. **Straight away is the default** |
| Away longer than 10 minutes (or longer than a longer grace) | The vault key is dropped: a real unlock, not a check |
| Opening a note | A check, unless one passed in the last minute |
| Changing the passphrase, issuing a recovery key, exporting everything, forgetting the folder, destroying a client, changing the "Ask again" setting | A check |
| Everything else — the client list, retention, note fields, writing a note | No check. It is behind the door already |

Three properties this is meant to have, all of which were missing before:

1. **A failed check is never survivable.** `DeviceCheck` separates a *decline* — a normal
   choice, which costs the counsellor the action they asked for and nothing else — from a
   *failure*, a wrong face or a wrong passcode. A failure drops the key immediately and the
   unlock screen says so ("That check didn't pass"), with the biometric unlock withheld
   until the passphrase has been typed. A check that can be shrugged off is decoration.
2. **Leaving really is leaving.** `LockPolicy.reopenGrace` defaults to zero, so reopening
   asks. It is a setting because a counsellor flicking between this and a calendar twenty
   times an hour is a real way of working, and an exhausting app is one that gets left
   unlocked. `.inactive` and `.background` are handled separately: an app with a Face ID
   prompt in front of it is inactive but has not gone anywhere, and treating that as leaving
   would relock the app in the middle of the check meant to keep it open.
3. **Nothing is visible until it has been paid for.** `SplashView` covers the app from the
   moment it leaves the foreground until a check has passed — so the card in the app
   switcher is the launch screen. On iOS it goes up in a window of its own
   (`PrivacyShieldWindow`) above `.alert`, because a sheet — the note editor mid-sentence,
   an import — is presented above the root view and would otherwise still be in the snapshot
   iOS takes.

A device with no biometry and no passcode is the one place this bends: it cannot be asked,
so in-app checks pass (the passphrase was typed to get in, and demanding it before every
note ends with it taped to the back of the phone) while *reopening* still falls back to the
passphrase. Settings says so in as many words.

The one path the simulator cannot exercise is a genuine `LAError.authenticationFailed` —
biometry there falls through to the passcode sheet — so the "That check didn't pass" screen
has been reasoned about and unit-tested at the mapping (`DeviceCheckTests`) but not seen on
hardware. It belongs in the acceptance run.

---

## Importing what you already have

Nobody starts here. A counsellor arriving at this app has years of records in Word, in a
spreadsheet, in Apple Notes, or in a folder of text files — and the honest reading of "MVP
= sole clinical record system" is that it cannot become the sole system until what came
before it can get in.

**Settings → Import existing notes**, or the button on the empty client list.

### What it reads

Word (`.docx`), Excel (`.xlsx`), CSV and TSV, plain text, Markdown, rich text — including
a note dragged out of Apple Notes or TextEdit, and `.rtfd` bundles — HTML and web-page
exports, Evernote `.enex`, and PDFs that contain real text. A folder is walked, and the
folder each file sits in is the default grouping, because one folder per client is how
most people who kept files kept them.

Word and Excel are zips, and reading them needs an unzip. That is `ZipArchive`, about a
hundred lines over Apple's own `Compression` framework, rather than a package: this is the
one code path that handles a folder of *unencrypted* clinical history, and it is the last
place in the app where "what else does this dependency do?" should be a rhetorical
question.

Not readable, and each says so with what to do instead: older `.doc`, Pages and Numbers,
password-protected files, and PDFs that are scans or photographs. There is no OCR and no
camera permission with which to acquire one later, so handwriting has to be typed up.

### Apple Notes

**Export as Markdown, one folder per client.** Dragging notes out of Notes into Finder
does not work — it leaves nothing behind that can be read, which was found out by trying
it. So: make a folder for a client, select their notes in Notes, export them as Markdown
into it, repeat, then point the importer at the folder holding all of them.

That route names each file after the note's title, and a counsellor's note titles are
usually the date — so a date in the filename is read as the session date when the note
itself does not contain one. Without that, the fallback would be the file's own timestamp,
which for an export is the afternoon they ran it, and five years of work would arrive
dated the same day.

### The three things that are actually hard

**A spreadsheet cannot be guessed at.** Columns are suggested from their names, and from
the data when the names say nothing — but nothing is imported until the counsellor has
confirmed the mapping. A column matched wrongly files one client's session in another
client's record, which is the worst outcome this feature has available to it.

**Dates.** `06/07/2026` is 6 July here and 7 June in an American export, and no file says
which. The app reads day-first, marks every genuinely ambiguous date as ambiguous, states
the reading on the review screen, and lets it be switched. A date it had to invent — a
file's own modification time, because nothing inside said when — is shown in orange and
written into the note as `imported-session-date: uncertain`, so a guess never quietly
becomes a session date. A note with no date at all blocks the import until one is given:
the filename, the timeline and the retention clock all key off it.

**Names.** Every other part of this app is built so a name cannot get in — `ClientCode`
will not hold one and there is nowhere to type one. Import is the one door where that
stops being true, because the file being imported was written in Word, where "Sarah rang
on Tuesday" is entirely normal. So: the source's own word for the client is never stored,
only the code the counsellor picks; that code is picked per group, by hand, with any
existing client offered first so one person's record does not end up split across two
codes; the app offers to replace the source's words for that person with their code
throughout the notes, showing exactly which words; and it scans for emails, phone numbers,
postcodes, NHS numbers and dates of birth, which it flags and does not touch. Editing
someone's clinical record on a pattern match is not this app's decision to make.

### The block at the top of the note

People who kept notes in Word or Notes nearly always wrote a little header on each one —
`Session number: 4`, `Duration: 50 minutes`, `Room: 2` — because there was nowhere else to
put it. This app has somewhere: note fields, which ride in the note's headers, show as
labelled metadata rather than prose, and read back on a device that has never heard of the
field.

So the importer looks for that block, and for each kind of detail it finds:

- **a field you already have, switched on** — matched without asking, because switching
  that field on is exactly the decision being honoured;
- **a field you have but have never switched on** — offered, not assumed. Turning a field
  on changes every note screen from then on;
- **anything else** — offered as a new field, with the kind guessed from the values, and
  otherwise left in the note exactly as written.

The default everywhere is to change nothing. A line only leaves the body once a field has
been chosen for it, because silently restructuring a clinical record on a pattern match is
not a decision an importer gets to make. `Date:` and `Time:` are never offered (the
session date is read separately and is part of the note's identity), and neither are
`Name:`, `DOB:`, `Address:` and their like — offering those would put a name field in an
app built so that names cannot be stored. They stay in the body, where the
identifying-details scan flags them.

### Showing the encryption rather than claiming it

The point of nervousness at this moment is not misplaced: this is the largest amount of
identifiable clinical data the app will ever handle at once. Four things answer it, and
each is a fact rather than a reassurance.

- **Nothing is uploaded, because there is nothing to upload to.** The app has no network
  client entitlement (`project.yml`, and the checked-in `.entitlements`). Not "does not
  make requests" — *cannot*: macOS refuses the connection at the sandbox. The import
  screen says so, and invites the counsellor to turn Wi-Fi off first and watch it work
  anyway.
- **Encrypted before written, not after.** Every note goes through the same
  `VaultStore.write` path as one typed into the editor — serialise, encrypt, write
  ciphertext. There is no bulk path and no staging folder, so there is no second place for
  the encryption to be got wrong and no window in which a readable copy exists in a synced
  folder. The counsellor's files stay in memory from the moment they are picked until the
  sheet closes.
- **A receipt for each note.** `writeWithReceipt` returns the readable filename, the
  `…c9r` name that actually reaches iCloud, both sizes, and the result of searching the
  bytes just written for the note's own distinctive words. "What was written" lists all of
  it. `CiphertextCheck` would not detect a subtle cipher flaw and does not pretend to —
  what it catches is a write path that skipped the engine, which is the failure that could
  really happen here.
- **Read back, every time.** Each note is decrypted out of the vault immediately after it
  goes in and compared with what went in. It costs one decryption per note and turns "it
  says it saved" into "here is the note again".

And the last screen is about what the app *cannot* do: the originals are still sitting
there unencrypted, nothing has been moved or deleted on the counsellor's behalf, and
Apple Notes will keep anything deleted for another thirty days. That step is theirs, and
saying so plainly is worth more than a green tick.

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

**Unsaved notes are now held, encrypted, until they are saved.** The gap the append-only
format could never close was everything typed *before* Save: it lived in the editor's
`@State` and nowhere else, so an iPhone killing a backgrounded app took the note with it.
`DraftStore` (`Sources/NotesVaultCrypto/DraftStore.swift`) keeps it in Application Support,
as ciphertext under the same per-device index key as the index cache, under a hashed
filename that carries no client code, with complete file protection on iOS. `NoteEditorView`
writes about a second after the last keystroke and again the moment the app leaves the
foreground, restores automatically with a notice saying it has done so, and clears the draft
on save, on either Discard, and when a client is destroyed. `DraftStoreTests` covers the
round trip, the absence of plaintext on disk and the clearing. Two things it deliberately
does not do: drafts never reach the vault — a half-written clinical note must not become a
record — and they do not sync, so a draft started on the phone is on the phone.

**Plaintext briefly touches disk when encrypting.** Cryptomator's library exposes content
encryption only as `encryptContent(from: URL, to: URL)`; the stream overloads that would
keep a note in memory are `internal`. So each note is written to a scratch file for the
length of one call. `PlaintextScratch` handles it deliberately — unique directory, complete
file protection on iOS so the key is evicted when the device locks, contents overwritten
before unlinking — but the honest fix is upstream: a small PR making those overloads public
deletes that file entirely. Worth doing before launch.

**The Apple Notes route now says what actually works, and the rest of it is still
untried.** Dragging notes into Finder was tried and does not work; the screen says so and
gives the Markdown export instead. What has *not* been done is a full run of that route
end to end — export a real client's notes, import the folder, and check the dates and the
splitting came out right. That is acceptance check 14.

**Excel dates are read by range, not by cell format.** A spreadsheet keeps `14/06/2026` as
the number 46187, and knowing it is a date rather than a fee means reading the number
format out of `styles.xml`. Instead, a bare number in the column the counsellor mapped as
the date is treated as a date when it falls between 1990 and 2100. Outside a date column it
is never guessed at, and the review screen shows the date it produced — but a workbook with
a genuine five-figure number in its date column would be read wrongly.

**Import holds plaintext in memory, and briefly on disk.** The picked files are held in
memory for the length of the sheet, which is unavoidable and fine. The disk part is the
existing `PlaintextScratch` limitation multiplied by the size of the import: every note
encrypted means one scratch file. The upstream fix below removes it for imports as well as
for typed notes, which makes it more worth doing than it was.

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
