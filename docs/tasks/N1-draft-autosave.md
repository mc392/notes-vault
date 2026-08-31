# N1 — Encrypted draft autosave in the note editor

**Model:** Opus · **Depends on:** nothing · **Touches:**
`Sources/NotesVaultApp/Views/NoteEditorView.swift`, `Sources/NotesVaultApp/AppModel.swift`,
new file `Sources/NotesVaultCrypto/DraftStore.swift`, tests in
`Tests/NotesVaultCoreTests/` or a new crypto test file, `README.md` (open items section)

## Why
`NoteEditorView` holds the note body in `@State` with nothing behind it. iOS routinely
kills backgrounded apps; a counsellor who writes 400 words, flicks to Messages, and
comes back to a relaunched app has lost the note with no trace. The vault's append-only
guarantees protect everything *after* Save — this closes the gap before it. It is the
single most likely real-world data loss for this app's audience.

## Design

**`DraftStore`** (new, in NotesVaultCrypto — it needs the keychain, so it cannot live in
Core). Model it directly on `IndexStore` (read that file first and mirror its choices:
where it puts files, how it encrypts with the keychain index key, how it fails soft):
- One draft per (vaultID, client code, corrected-note ID or "new"). Key the filename on
  a hash of those, never on the cleartext client code — the draft lives OUTSIDE the
  vault folder (Application Support, like the index cache), so nothing identifying may
  appear in its filename.
- Contents: a small Codable struct — client code, body, sessionDate, template raw value,
  fieldValues, savedAt — JSON-encoded then encrypted with the vault's index key
  (`KeychainStore.indexKey(vaultID:)`), same AEAD construction as IndexStore.
- API: `save(_ draft: NoteDraft, vaultID: String)`, `load(vaultID:client:correcting:)`,
  `clear(vaultID:client:correcting:)`, `clearAll(vaultID:)`. Every failure is soft:
  a draft is a convenience, and a keychain hiccup must never block writing a note.
- iOS file protection: `.completeFileProtection` on write (unlike vault writes, this is
  plaintext-derived material at rest only under our encryption; the stricter class is
  right here because no sync daemon needs to read it).

**Editor behaviour** (`NoteEditorView`):
- Debounced save (~1s after last change) whenever the body or fields differ from their
  initial values, and immediately on `scenePhase` leaving `.active` (use
  `@Environment(\.scenePhase)` + `.onChange`).
- On appear for a (client, correcting) pair with a stored draft: restore it into the
  fields automatically and show a dismissible one-line notice at the top of the form:
  "Restored an unsaved draft from <time>." with a "Discard draft" button that reverts to
  the blank/correcting initial state and clears the draft. Automatic restore, not a
  prompt — the failure mode of a prompt is tapping past it and losing the draft anyway.
- Cleared on: successful save (after `model.addNote` returns and only if no
  `errorMessage` was raised — check how `run` reports; safest is to clear when the
  refreshed index write succeeded, or simply clear after `addNote` when
  `model.errorMessage == nil`), and on explicit Discard (both the notice's button and
  the existing discard confirmation dialog).
- The Cancel path keeps its confirmation dialog; choosing "Discard" there also clears
  the stored draft. Choosing Cancel→dismiss-by-keeping leaves the draft (that's the
  point).

**AppModel**: expose `vaultID` to the editor via a small computed
(`public var currentVaultID: String?`) or route DraftStore calls through AppModel
methods (preferred — keeps views out of the crypto module's internals, matching how
everything else flows through the model). Add `model.saveDraft/loadDraft/clearDraft`
wrappers that no-op when locked.

**Lifecycle**: `destroy(client:)` must also `clearAll` drafts for that client (a
destroyed client's draft surviving would violate the destruction promise). `lock()`
does NOT clear drafts (they're encrypted with the index key, which survives lock).

## Constraints
- No plaintext on disk, ever: the draft file must be ciphertext under the index key.
  If `indexKey(vaultID:)` returns nil, hold the draft in memory only for that run.
- NotesVaultCore stays dependency-free: the Codable draft struct may live in Core (pure
  data), the storage in Crypto.
- Zero warnings; follow the existing serial-queue rule — DraftStore calls from AppModel
  go through the same `run`/queue plumbing as other vault-adjacent work, but must never
  block typing (the debounced save can be fire-and-forget onto the queue).
- Update README's "Open engineering items" — remove nothing, add a line that drafts are
  now covered and where.

## Tests
- Round-trip: save → load returns equal draft; clear removes; load for a different
  client/vault returns nil.
- Ciphertext check: the stored file's bytes do not contain a distinctive word from the
  draft body (reuse `CiphertextCheck.holdsNoPlaintext` — it's public in Core).
- Destroy-clears-drafts: after `clearAll(vaultID:)` nothing loads.
- Use a stubbed/static key so tests don't touch the real keychain (mirror how existing
  crypto tests avoid the keychain — read `Tests/NotesVaultCryptoTests` first; if
  IndexStore is untested against the keychain, give DraftStore an injectable key).

## Verify
`swift build` (zero warnings) and `swift test` (all green, new tests included).

## Out of scope
- Draft sync between devices. Autosaving to the vault itself (a half-written clinical
  note must never become a vault record). UI beyond the notice line.
