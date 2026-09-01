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

1. **Anchor** on the latest known session for the client.
   - Notes: the session date of the latest note in the vault, `series-start` if there are
     no notes at all, and nothing otherwise.
   - GroundWork: the latest row in `S.sessions` for that code.
2. **Step** forward from the anchor in `cadenceDays` increments.
3. **Snap** each candidate to `usual-day` when one is set, by moving at most three days in
   either direction. Every cadence is a whole number of weeks, so this only ever bites on
   the first step — which is the point: one session moved to a Thursday should not shift
   the whole series off Tuesdays forever.
4. **Set the time of day** from `usual-time` when one is set; otherwise keep the anchor's.
5. **Stop** at the end of today. A session that has not happened yet cannot be written up.
6. **Drop** any candidate falling on the same local calendar day as a session that already
   has a note. Same *day*, not same instant — a note written at 09:35 for a 09:30
   appointment is that appointment.
7. **Order** most recent first and cap the list at six.

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
  prediction then keeps the anchor's own day and time.
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
status, cadence, usual day, usual time and series start, and writes a metadata event only
for the clients that actually differ. Without that, an append-only vault would gain one
file per client per sync, forever.

A client in the roster that the vault has never seen is created. A client in the vault that
is not in the roster is left completely alone — the roster is not authoritative about who
exists, only about who GroundWork knows the cadence for.

## What this deliberately cannot know

**Cancellations and DNAs.** A cancelled session leaves no trace in the vault, so the
prediction will offer its date anyway. That is why these are presented as *suggested
dates to pick from* and not as a to-do list: choosing the wrong one is one tap from being
right, whereas a to-do list that is confidently wrong is worse than no list.
