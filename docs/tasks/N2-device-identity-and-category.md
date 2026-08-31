# N2 — Unique per-install device identity + App Store category

**Model:** Sonnet · **Depends on:** nothing · **Touches:**
`Sources/NotesVaultCrypto/FileSystemVaultStore.swift` (DeviceIdentity), `project.yml`,
`README.md`, possibly a small new test

## Why (identity)
`DeviceIdentity.current` returns the model class — every iPhone is `"iphone"`. Two
iPhones on one iCloud account (old phone + new phone is common), both offline, writing a
note for the same client in the same minute, produce the same cleartext filename → the
same deterministic ciphertext name → an iCloud sync conflict whose renamed "conflicted
copy" no longer decrypts and gets reported-and-skipped. The README's "two devices never
collide" claim is currently only true when the devices are different *kinds*. The
acceptance run (mac + iphone) cannot catch this.

## Changes (identity)
1. In `DeviceIdentity`, generate once and persist a short random suffix:
   - UserDefaults key `device.suffix`; value: 3 characters from the Crockford alphabet
     already in the codebase (`CrockfordBase32` in Core — reuse its alphabet constant
     rather than redefining one), lowercased.
   - `current` returns `"\(base)-\(suffix)"`, e.g. `iphone-k3m`, `mac-7f2`.
2. **Filename-safety check first**: read `NoteRecord.preferredFilename` /
   `disambiguatedFilename` and their tests (`NoteFormatTests`, `NoteIDTests`) to confirm
   the device segment's allowed characters — the suffix must be lowercase letters/digits
   only (no extra hyphens beyond the existing separator convention if the parser splits
   on them; if the filename parser treats hyphens as structure, use a suffix with no
   hyphen: `iphonek3m`). Follow what the parser can round-trip, and add a test proving a
   suffixed device name round-trips through filename generation and parsing.
3. Existing files named `…-iphone.note` are untouched and remain valid — names are just
   names in an append-only store; say so in a comment.
4. README: update the two example listings that show `-iphone.note` filenames and the
   AppModel comment reference if it claims uniqueness ("two devices never collide") —
   make the claim true.

## Changes (category — decision made: Business, matching GroundWork)
5. `project.yml`: `LSApplicationCategoryType: public.app-category.medical` →
   `public.app-category.business`. Update the README if it mentions the category.
   (Rationale on file: practice administration/record-keeping tooling, consistent with
   the companion app; Medical invites extra review scrutiny for no fit gain.)

## Constraints
- UserDefaults is the right store (it's an identity label, not a secret); it must be
  created lazily and be stable across launches — never regenerate if present.
- `DeviceIdentity` is used by tests via injected `deviceName:` parameters — confirm no
  test asserts the literal `"iphone"`; if any does, update it to match the new shape.
- Zero warnings; `swift test` green.

## Verify
- `swift build && swift test`.
- New/updated test: suffixed name round-trips; suffix stable across two reads;
  regenerated only when absent.

## Out of scope
- Draft autosave (N1). Keychain lifecycle (N3). Migration of existing filenames (none
  needed).
