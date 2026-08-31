# Releasing GroundWork Notes

## First: pick one delivery route, not two

There are now two ways to get a build to TestFlight, and **only one should be switched
on**. Both uploading at once means two builds racing for the same build number, and Apple
rejects the loser — a confusing failure that looks like a signing problem.

| | Xcode Cloud | GitHub Actions (`testflight.yml`) |
|---|---|---|
| Set up | in Xcode / App Store Connect; `ci_scripts/ci_post_clone.sh` runs `xcodegen` because the project file is gitignored | three repository secrets, all in the repo |
| Signing | handled by Apple, nothing to store | an App Store Connect API key you create |
| Cost | 25 compute hours/month free, then paid | free — GitHub's macOS runners are free on public repos, and this one is public |
| Lives where | mostly in Apple's UI, invisible to the repo | entirely in the repo, reviewable in a diff |

**Xcode Cloud is already part-configured** (that is what `ci_scripts/ci_post_clone.sh` is
for). If you finish that, delete `.github/workflows/testflight.yml` and ignore the rest of
this page's automation section — the manual and compliance notes still apply.

`testflight.yml` is the alternative, and is **dormant** until you either push a `notes-v*`
tag or start it by hand, so leaving it in place while you decide is safe.

---

Whichever you choose, note that CI and delivery are different things:

| | What runs | When |
|---|---|---|
| `ci.yml` | `swift test`, then unsigned builds for macOS and iOS Simulator | every push and PR |
| `testflight.yml` | tests, then a **signed** build uploaded to App Store Connect | a `notes-v*` tag, or a manual run |

CI proving the app compiles says nothing about whether testers have your changes. Only a
tagged release does that.

## Cutting a build

The version lives in `project.yml` — `MARKETING_VERSION` (what people see) and
`CURRENT_PROJECT_VERSION` (the build number, which **Apple rejects if it repeats**). In
CI the build number is taken from the tag, so `project.yml` only needs touching when the
marketing version changes.

```bash
# optional: edit MARKETING_VERSION in project.yml first, then commit
git tag notes-v0.1.0-b2
git push && git push --tags
```

The `-b<number>` suffix is what the workflow reads as the build number. Keep incrementing
it; every upload needs a number Apple has not seen for this version.

**From your own Mac instead** (and the fallback if the workflow misbehaves):

```bash
xcodegen generate && open NotesVault.xcodeproj
```

then *Any iOS Device* → Product → Archive → Distribute App → TestFlight & App Store.

## One-time setup

The workflow needs an App Store Connect API key — the same key both apps use, so if you
have already set this up for GroundWork, reuse it. App Store Connect → Users and Access →
Integrations → App Store Connect API → **Team key**, role **App Manager**, download the
`.p8` (one chance only).

Add three secrets under GitHub → Settings → Secrets and variables → Actions:
`APP_STORE_CONNECT_KEY_ID`, `APP_STORE_CONNECT_ISSUER_ID`,
`APP_STORE_CONNECT_PRIVATE_KEY` (the whole `.p8`, BEGIN/END lines included).

## Export compliance — read this once, properly

This app is not in the same position as GroundWork. It performs **real encryption of user
content** with the Cryptomator library, which is more than the "standard encryption in the
OS" exemption most apps claim.

In practice apps using standard, published algorithms (AES, scrypt) for their own data
storage are exempt under the "mass market" / standard-cryptography provisions, and
declare so annually with a self-classification report. That is very likely your position,
but it is a compliance question with legal weight, not an engineering one — **confirm it
before the first public release**, and answer App Store Connect's questions from that
confirmation rather than from a guess. Set
`ITSAppUsesNonExemptEncryption` in the Info.plist once you know the answer, and the
question stops being asked per build.

## Before the first TestFlight build

Stage 2 in [RUNNING.md](../RUNNING.md) and the 14-point acceptance run in the README are
the release gate, and TestFlight is how most of it gets done — the document picker into a
live iCloud Drive folder, placeholder downloads, Face ID and two-device sync cannot be
answered any other way. Cut a build early for yourself; open it to other testers only
once checks 1, 2, 5, 6, 7 and 12 are green.

## Version numbering

Separate app, separate record, separate tags. GroundWork uses `ios-v*` in its own repo;
this one uses `notes-v*`. They share a brand, not a release train.
