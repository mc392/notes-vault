# Session schedules, shared between GroundWork and GroundWork Notes

This is the specification both apps implement. It is written down once because the two
implementations are in different languages, in different repositories, and a silent
disagreement between them shows up as *the wrong dates offered to a counsellor*, which
nobody would notice for months.

**Nothing clinical crosses between the apps, and there is no back-feed.** GroundWork Notes
is never told which sessions have notes; it already knows. GroundWork is never told that a
note was written; that tick stays manual.

---

## Why a schedule and not a worklist

The obvious integration is "GroundWork sends a list of sessions awaiting write-up". It
would need live cross-device sync, because the admin is done on a phone and the notes are
written on a Mac.

The list of outstanding sessions is a function of two things: the appointment series, and
which of its sessions have been written up. GroundWork Notes already holds the second
half — every note in the vault carries its session date. So it only needs the first half,
and the first half changes about once per client, ever.

So: sync the cadence, compute the worklist locally. A Mac that has not spoken to
GroundWork in a month still offers the right dates, because iCloud has been syncing the
vault the whole time and the cadence has not changed.

## Where the schedule is stored

In the client metadata log, inside the vault — `ClientMetadataEvent`, three new headers:

```
cadence-days: 7
usual-day: tue
usual-time: 09:30
series-start: 2026-04-07T00:00:00Z
```

That log was already append-only, folded latest-wins, encrypted with the vault key and
synced between the counsellor's own devices by whatever holds the vault folder. It needed
no new sync mechanism, and it keeps a client's standing appointment slot — which is a
behavioural pattern about a real person — inside the encryption rather than beside it.

`ClientMetadataEvent.parse` already preserved unknown headers in `extraHeaders`, so a
vault written by this version stays readable by the version before it, and a note
round-tripped through the older build does not lose these.

## The prediction algorithm

Both apps implement exactly this. GroundWork Notes: `SessionPrediction.expected(…)`.
GroundWork: `predictSessions(…)`.

1. **Anchor** on the **earliest** known session for the client.
   - Notes: the session date of the *first* note in the vault, `series-start` if there are
     no notes at all, and nothing otherwise.
   - GroundWork: the earliest row in `S.sessions` for that code.
2. **Step** forward from the anchor in `cadenceDays` increments.
3. **Snap** each candidate to `usual-day` when one is set, by moving at most three days in
   either direction. Every cadence is a whole number of weeks, so this only ever bites on
   the first step — which is the point: one session moved to a Thursday should not shift
   the whole series off Tuesdays forever.
4. **Set the time of day** from `usual-time` when one is set; otherwise keep the time the
   walk is carrying (see *No appointment time* below).
5. **Claim** a session that already has a note when one falls within **half a cadence** of
   the candidate, nearest first, each note claimed at most once. A claimed candidate is not
   offered, and the walk **re-anchors onto the note's own date and time** before stepping
   on — so a session moved by a day or two corrects the series rather than dragging it.
6. **Stop** at the end of today. A session that has not happened yet cannot be written up.
7. **Reach back** no further than **730 days** before today. Everything inside that window
   that was not claimed is offered.
8. **Order** most recent first. **No cap.**

### Anchoring on the first session, not the latest

Anchoring on the *latest* note is the obvious reading of "what is outstanding", and it is
wrong. Suppose three Tuesdays have gone by unwritten and the counsellor writes up the most
recent one: the anchor moves to it, the walk starts after it, and the two sessions still
owed disappear off the list. That was a reported bug, not a hypothetical.

Walking from the first session and claiming the notes as it goes gives the same answer for
the recent end of the list and keeps the gaps behind it. It costs a longer walk, which is
what the 730-day reach-back and the step guard are for.

### No appointment time

`usual-time` is often absent — GroundWork does not always know one. The prediction then
carries down the time of the last session it claimed, which is a real appointment time and
worth keeping.

When there is no such session either — a client with a cadence, a series start and no notes
yet — there is **no time at all**, and the prediction says so: GroundWork Notes returns
`PredictedSession.timeIsKnown == false` and the app shows the date alone. The date itself is
set to **midday local time**, which is what the note editor opens on if one of these is
tapped.

Midday, rather than midnight, throughout: `series-start` is a *day*, and a day read as
midnight UTC is 01:00 in a British summer and the day before in New York. Reading days at
midday makes them land on the right date everywhere — and 01:00 appointments appearing for
clients who had no appointment time is exactly how this was found.

### The cadence mapping is 28 days, not a calendar month

GroundWork's `freqDays()` maps its frequency labels by substring:

| Label | Days |
|---|---|
| Weekly | 7 |
| Every 2 weeks | 14 |
| Every 3 weeks | 21 |
| Monthly | **28** |

"Monthly" is a flat 28 days and always has been — the attendance figures in Practice ›
Trends are built on it. `Calendar.date(byAdding: .month)` would drift by a day or three
every month and the two apps would offer different dates for the same client within a
quarter. **The wire format is therefore a number of days, not a label**, so the mapping
exists in exactly one place per app and cannot disagree.

## The roster file

What GroundWork writes and GroundWork Notes reads. Client codes and cadence — no names, no
fees, no attendance, no clinical content:

```json
{
  "app": "GroundWork",
  "kind": "schedules",
  "version": 1,
  "exportedAt": "2026-08-31T08:12:44.000Z",
  "note": "Client codes and appointment cadence only. No names and no clinical content.",
  "clients": [
    {
      "code": "SM2",
      "status": "active",
      "cadenceDays": 7,
      "usualDay": "tue",
      "usualTime": "09:30",
      "seriesStart": "2026-04-07"
    }
  ]
}
```

- `status` is `active` | `paused` | `ended`, mapped from GroundWork's own statuses through
  its `clientCategories` table (`Ongoing`→active, `Paused`→paused, everything else→ended).
- `usualDay` / `usualTime` are omitted when GroundWork cannot determine them, and the
  prediction then keeps the day and time of the last session it claimed — or, if there is no
  such session, offers a date with no time at all.
- `seriesStart` is a **day**, `YYYY-MM-DD`. It is read at midday UTC, and two series starts
  on the same day are the same series start however either was written down — so a sync does
  not rewrite every client in the vault the first time the two apps spell it differently.
- Codes GroundWork holds that are not valid `ClientCode`s — under two characters, or
  carrying punctuation — are left out of the file entirely rather than exported and
  rejected at the far end.

The file is **not encrypted**, so it is written wherever the counsellor points it and is
not put inside the vault folder. An unencrypted list of appointment patterns sitting next
to a vault whose filenames are encrypted precisely to hide them would give away the thing
the vault is for.

## How the sync button works

GroundWork Notes keeps a security-scoped bookmark to the roster **file** — the same
mechanism `VaultBookmark` uses for the vault folder. The counsellor picks the file once;
after that, "Sync schedules" re-reads whatever is at that path. So keeping the two apps in
step is: GroundWork writes over the file, Notes re-reads it. Neither app needs the other to
be running, or on the same device.

**The bookmark has to be made while the file's security scope is open.** A URL that comes
back from the document picker is unusable outside a balanced
`startAccessingSecurityScopedResource()` / `stopAccessingSecurityScopedResource()` pair,
and `bookmarkData` is a use of the file like any other. Skipped, it fails with *"The file
couldn't be opened because it doesn't exist"* — the sandbox refusing, worded as though the
file were missing, which sends you looking in the wrong place entirely. The vault folder
never showed this because `FileSystemVaultStore` is already holding the folder open by the
time `VaultBookmark.store` runs; a file picked for one read has nothing holding it. Both
bookmark stores now open the scope themselves.

**A file in iCloud Drive may not be on the device yet.** A placeholder cannot be bookmarked
any more than it can be read, so `RosterBookmark.store` asks iCloud for it and waits (which
is why choosing a file runs off the main thread), and `RosterBookmark.read` downloads
*before* testing whether the path exists — a placeholder does not sit at the name the user
picked, it sits beside it as `.name.icloud`, so checking first calls every undownloaded
file gone.

Writing over the same file, per platform:

| Where | How |
|---|---|
| Chrome / Edge, desktop | File System Access API. The counsellor picks the file once; the handle is kept in IndexedDB and every later sync writes silently. |
| GroundWork on iOS (Capacitor) | The existing share sheet — Save to Files, Replace. `download()` is already wrapped natively, so this needed no new native code. |
| Safari, and anything else | An ordinary download, then replace the file by hand. |

**Sync only writes what changed.** It folds each client's current metadata, compares
status, cadence, usual day, usual time and series start (by *day*), and writes a metadata
event only for the clients that actually differ. Without that, an append-only vault would
gain one file per client per sync, forever.

**A sync does not rebuild the index.** It writes client metadata and cannot have changed a
note, so the local index has the new metadata folded into it in place. Rebuilding meant
re-reading and decrypting every note in the vault — tens of seconds on a full vault, after
a sync that could not possibly have changed one, which is what made a sync of a few hundred
clients feel like it had hung. The index is a cache; the next unlock rebuilds it anyway.

A client in the roster that the vault has never seen is created. A client in the vault that
is not in the roster is left completely alone — the roster is not authoritative about who
exists, only about who GroundWork knows the cadence for.

## What this deliberately cannot know

**Cancellations and DNAs.** A cancelled session leaves no trace in the vault, so the
prediction will offer its date anyway. That is why these are presented as *suggested
dates to pick from* and not as a to-do list: choosing the wrong one is one tap from being
right, whereas a to-do list that is confidently wrong is worse than no list.
