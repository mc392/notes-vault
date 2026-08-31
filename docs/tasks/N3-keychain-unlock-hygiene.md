# N3 — Keychain lifecycle + biometric-unlock failure surfacing

**Model:** Sonnet · **Depends on:** nothing · **Touches:**
`Sources/NotesVaultApp/AppModel.swift`, `Sources/NotesVaultCrypto/KeychainStore.swift`,
`Sources/NotesVaultCrypto/FileSystemVaultStore.swift` (only if reacquire is needed)

## Why
Two hygiene gaps and one dead-feeling button:
1. `KeychainStore.forget(vaultID:)`'s doc comment says it is "called when the vault is
   removed from the app" — nothing calls it. "Use a different folder" leaves the
   biometric-wrapped passphrase and index key on the device indefinitely.
2. `FileSystemVaultStore.relinquish()` exists for releasing security-scoped access early
   and is never called; scope release rides on `deinit`.
3. `unlockWithBiometrics()` is a chain of silent `guard … return`s: if the config can't
   be read or the keychain item has gone, the Face ID button does nothing at all.

## Changes

1. **`forgetFolder()`** (AppModel): before dropping `files`, read the vault's `jti` (the
   same non-secret read `unlockWithBiometrics` does: read `vault.cryptomator` via
   `files`, `VaultBootstrap.decodeConfiguration`) and call `KeychainStore.forget(vaultID:)`.
   If the folder has no vault or the read fails, skip silently — there is nothing to
   forget. Also call `files.relinquish()` before releasing the reference. Update the
   SettingsView footer for "Use a different folder" to add: "Face ID unlock for this
   vault is switched off on this device too." Keep the reassurance that nothing in the
   folder is touched.
2. **`lock()`** (AppModel): do NOT relinquish here — unlock reuses the same
   `FileSystemVaultStore` and there is no re-acquire path; note this in a comment so the
   asymmetry is deliberate rather than mysterious. (If you instead choose to add a
   `reacquire()` to FileSystemVaultStore and relinquish on lock, that is acceptable —
   but only with a test or clear reasoning that unlock-after-lock still works on both
   platforms. The simple, safe option is the comment.)
3. **Biometric failure surfacing**:
   - `KeychainStore.passphrase(vaultID:reason:)` currently returns `nil` for user-cancel
     and genuine failure alike. Change its return to distinguish them — e.g.
     `enum PassphraseResult { case value(String), cancelled, unavailable }` — mapping
     `errSecUserCanceled` (and `errSecAuthFailed` after cancel-like interaction) to
     `.cancelled`, `errSecItemNotFound` to `.unavailable`, other statuses to
     `.unavailable`.
   - `unlockWithBiometrics()`: `.cancelled` → do nothing (declining is a normal choice —
     preserve the existing philosophy); `.unavailable` → set `errorMessage = "Face ID
     unlock isn't set up any more on this device — use your passphrase, then turn it
     back on from the unlock screen."` and remove the stale item
     (`KeychainStore.remove(.passphrase, vaultID:)`) so `biometricsEnrolled` stops
     offering a dead button. Config-read failures → the same error path with a message
     that says the folder couldn't be read.

## Constraints
- `KeychainStore` is public API within the package; update all call sites (only
  AppModel) and any tests.
- Never log or expose the passphrase. Messages name the outcome and the next step, no
  apology, matching the app's voice.
- Zero warnings; `swift test` green. Keychain behaviour can't run in plain `swift test`
  — keep the enum mapping logic testable (pure function from OSStatus → case) and test
  that mapping.

## Verify
- `swift build && swift test`.
- Code-review level walkthrough in your summary: the exact sequence for (a) forget
  folder with a vault present, (b) forget folder pointing at a non-vault, (c) biometric
  unlock with item missing.

## Out of scope
- Draft autosave (N1). Any change to how passphrases are stored or the `.userPresence`
  access-control choice (deliberate — see the file's comments).
