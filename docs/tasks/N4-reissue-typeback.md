# N4 — Reissued recovery keys get the same typed confirmation as new ones

**Model:** Sonnet · **Depends on:** nothing · **Touches:**
`Sources/NotesVaultApp/Views/SettingsView.swift` (ReissueRecoveryKeyView),
possibly a small shared view extracted from
`Sources/NotesVaultApp/Views/OnboardingViews.swift` (RecoveryKeyView)

## Why
Creating a vault forces the counsellor to TYPE the recovery key back before continuing —
the app's best safety decision. Reissuing a key is *more* dangerous (the old key stops
working the instant the button is tapped, because the new recovery masterkey file is
already on disk) yet `ReissueRecoveryKeyView` shows the new key with a plain "I have
written it down" button, and the toolbar Close dismisses freely. A counsellor who taps
through has destroyed the paper key in their safe without a verified replacement — and
won't find out until the day they need it.

## Changes

1. **Type-back on reissue.** Once `model.pendingRecoveryKey` is set in
   `ReissueRecoveryKeyView`, require the same confirmation as `RecoveryKeyView`:
   a monospaced text field, live "That matches / Not a match yet" feedback via
   `RecoveryKey(typed:)` entropy comparison, and "I have written it down" disabled until
   it matches. Extract the shared piece (key display + hide-while-typing toggle +
   type-back field + match label) into one small reusable view used by BOTH screens, so
   the two can never drift — read `RecoveryKeyView` first and lift its exact behaviour,
   including the "Hide it and type it back" toggle.
2. **Say the consequence above the fold.** In the reissue result state, the first line
   under the key becomes: "Your old key stopped working the moment this one was issued.
   Write this one down and destroy the old paper copy." (The current footer text moves
   up / merges — keep it to two sentences.)
3. **No casual dismissal while unverified.** While a new key is showing and the
   type-back hasn't matched, the toolbar Close triggers a confirmation dialog:
   title "Close without confirming your new key?", message "The old key no longer works.
   If you have not written this one down, you will have no recovery key." Buttons:
   "Go back" (cancel) / "Close anyway" (destructive). After a successful match-and-
   acknowledge, Close behaves normally. The pre-issue state (passphrase entry) keeps
   free dismissal — nothing has changed at that point.

## Constraints
- No change to `VaultBootstrap.regenerateRecoveryKey` or any crypto path — this is
  purely the ceremony around it.
- `model.dismissRecoveryKey()` must still be called on every exit path, or the pending
  key lingers in memory.
- Match the codebase's comment voice: one comment on the shared view explaining why the
  type-back exists (borrow the reasoning from RecoveryKeyView's header comment).
- Zero warnings; `swift test` green (no test changes expected — this is view-layer, and
  the repo's tests don't render SwiftUI; say so in the summary).

## Verify
- `swift build && swift test`.
- Walkthrough in the summary: reissue → key shown → Close → dialog → Go back → type
  wrong key (no match) → type right key (match) → button enables → acknowledge →
  dismissed, `pendingRecoveryKey` nil.

## Out of scope
- The creation-flow screen's behaviour (already correct — only refactor, don't change).
- Passphrase change flow.
