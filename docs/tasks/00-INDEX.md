# GroundWork Notes — implementation task index

Orchestration plan from the 30 Aug 2026 release review. Each task file is self-contained:
give one file to one Claude Code session. Kickoff prompt:

> Read `docs/tasks/<FILE>` and implement it exactly. Read README.md's "Status" and
> "Open engineering items" sections first. Do not do anything the task marks out of scope.

Rules for EVERY task in this repo:

- `swift test` must pass (73+ tests) and the code must compile with **zero warnings** —
  that is the repo's stated bar. Run `swift build` too.
- The project file is generated: edit `project.yml`, never a `.pbxproj`.
- `NotesVaultCore` must keep zero crypto/platform dependencies; platform code goes in
  `NotesVaultCrypto`, UI in `NotesVaultApp`.
- Nothing may ever write plaintext note content to disk outside `PlaintextScratch`'s
  deliberate handling — new persistence must be encrypted (see N1).
- The vault is append-only: no task may add an update-in-place or delete path outside
  the existing destroy flow.
- Match the existing comment voice (each file explains *why*, plainly).

| # | Task file | Model | Depends on | One-line scope |
|---|---|---|---|---|
| 1 | N1-draft-autosave.md | **Opus** | — | Encrypted draft autosave so an unsaved note survives iOS killing the app |
| 2 | N2-device-identity-and-category.md | Sonnet | — | Unique per-install device names; App Store category → Business |
| 3 | N3-keychain-unlock-hygiene.md | Sonnet | — | Forget keychain items with the vault; surface biometric-unlock failures |
| 4 | N4-reissue-typeback.md | Sonnet | — | Reissued recovery keys require the same typed confirmation as new ones |
| 5 | N5-scratch-upstream.md | **Opus** | — | Upstream cryptolib-swift PR to remove the plaintext scratch file |

All five are independent of each other; N1 is the most valuable, N5 can run any time
(it's mostly work in a fork of another repo).

**Not a model task — the release gate:** Stage 2 in RUNNING.md (real Mac + iPhone), then
the 14-point acceptance run in README.md. Do acceptance checks 1, 2, 5, 6, 7 and 12
first. Model sessions can fix whatever those runs surface.

**Manual housekeeping before the repo goes public:** rename the local folder/repo so the
Notes app isn't in a directory called `GroundWork` while the tracker is in
`therapy-tracker` (affects remotes/CI — do by hand, not via a session).

- [x] N1 · [x] N2 · [x] N3 · [x] N4 · [ ] N5 · [ ] Stage 2 hardware run

**N1–N4 shipped (Aug 2026).** N5 (the upstream cryptolib-swift PR to retire the plaintext
scratch file) remains open, and Stage 2 on real hardware is still the release gate.
Also delivered outside this plan: session-schedule sync with GroundWork via a shared
roster file — see `docs/schedule-sync.md`.
