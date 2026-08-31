# N5 — Upstream cryptolib-swift change to retire the plaintext scratch file

**Model:** Opus · **Depends on:** nothing · **Touches:** a fork of
`cryptomator/cryptolib-swift` (separate repo), then `Package.swift` +
`Sources/NotesVaultCrypto/CryptomatorEngine.swift` + `PlaintextScratch.swift` here

## Why
README § Open engineering items, first entry, flagged "worth doing before launch":
cryptolib-swift only exposes content encryption as `encryptContent(from: URL, to: URL)`;
the stream overloads that would keep a note in memory are `internal`. So every note —
and every note of a bulk import — briefly exists as a plaintext scratch file.
`PlaintextScratch` handles this carefully, but the honest fix is upstream, and it
deletes the whole code path.

## Part 1 — the upstream PR
1. Fork and clone `https://github.com/cryptomator/cryptolib-swift`. Locate the internal
   stream/Data-based content-encryption overloads the README refers to (in the Cryptor
   type). Confirm exactly what is internal vs public before writing anything.
2. Prepare a minimal PR: make the Data/stream overloads `public`, with doc comments and
   tests matching the project's own style (study their existing public API tests and
   mirror them — an upstream maintainer should see zero friction). No behaviour change,
   no new API surface beyond visibility + docs.
3. PR description: motivate from the caller's side — an append-only notes app wanting to
   avoid plaintext touching disk; the file-URL API forces a scratch file. Short, factual,
   links to the relevant lines. (The user pushes the fork and opens the PR from their
   own GitHub account — prepare the branch, commit, and the PR text in a file
   `PR-DESCRIPTION.md` in the fork; do not attempt to open the PR yourself unless `gh`
   is authenticated and the user has said to.)

## Part 2 — adopt in this repo (can precede the merge, via the fork)
1. `Package.swift`: point the `cryptolib-swift` dependency at the fork's branch (a
   `.package(url: fork, branch:)` entry) with a `// TODO: return to upstream release
   once <PR link> is merged` marker. Keep `Package.resolved` updated.
2. `CryptomatorEngine`: switch `encryptContent`/`decryptContent` to the in-memory
   overloads. Delete the scratch usage; if nothing else uses `PlaintextScratch`, delete
   the file and its mentions.
3. README: rewrite the first "Open engineering items" entry to record the fix and the
   upstream PR link; update the import section's scratch-file caveat.

## Constraints
- The 14 integration tests (`VaultIntegrationTests`) run real crypto against a real
  folder — they are the proof the swap is faithful. All must pass unchanged, plus add
  one asserting a written note's ciphertext file appears WITHOUT any intermediate
  plaintext file in the scratch location (assert the scratch directory is absent/empty
  during a write — or simply that the directory is never created once the path is gone).
- Vaults written before and after the change must be mutually readable (same format;
  nothing about the on-disk format may change). The Cryptomator-interop acceptance check
  still applies at Stage 2.
- If the internal API turns out to be genuinely unsuitable (e.g. it exists only for
  chunked files), STOP and report findings instead of forcing a design — the scratch
  path is safe enough to ship behind if the upstream shape is wrong.

## Verify
- In the fork: their test suite passes.
- Here: `swift build` zero warnings, `swift test` fully green including the new
  no-scratch assertion.

## Out of scope
- Any other upstream change. Bumping vault format. Import pipeline changes.
