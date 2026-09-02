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

**The runner image decides the SDK, and Apple polices it.** Uploads built against anything
older than the iOS 26 SDK are refused — *"This app was built with the iOS 17.5 SDK. All
iOS and iPadOS apps must be built with the iOS 26 SDK or later"* — and that rejection
arrives at the very last step, after a successful archive, sign and export. `macos-14`'s
default Xcode is 15.4, which is exactly that. The workflow therefore runs on a newer image
and selects the newest Xcode on it explicitly, checking the SDK version up front so a
too-old image costs seconds rather than five minutes. If GitHub retires an image or ships
one without Xcode 26, that check is what will say so, and it prints the versions available.

**From your own Mac instead** (and the fallback if the workflow misbehaves):

```bash
xcodegen generate && open NotesVault.xcodeproj
```

then *Any iOS Device* → Product → Archive → Distribute App → TestFlight & App Store.

**Archiving by hand reads `CURRENT_PROJECT_VERSION` from `project.yml`, so bump it first.**
The sentence above about CI taking the number from the tag is true of CI only; nothing
increments it for a hand-made archive, and Apple rejects a build number it has already
accepted for this marketing version — at upload, after the archive, with a message about
the version rather than about the setting. Bump, commit, `xcodegen generate`, then archive.

## One-time setup

The workflow needs an App Store Connect API key — the same key both apps use, so if you
have already set this up for GroundWork, reuse it. App Store Connect → Users and Access →
Integrations → App Store Connect API → **Team key**, role **Admin**, download the `.p8`
(one chance only).

**The role must be Admin, not App Manager.** App Manager cannot reach cloud-managed
distribution certificates, and the export step fails with *"Cloud signing permission
error — You haven't been given access to cloud-managed distribution certificates"*
followed by *"No profiles for com.charlottebloor.groundworknotes were found"*. Neither
message mentions the key or its role, which is what makes it worth writing down. Worse,
the failed run leaves behind an Apple **Development** certificate it created while
casting about for something to sign with; its private key died with that runner, and a
later run can trip over it with *"your account already has a signing certificate for this
machine, but its private key is not installed"*. If that happens, revoke that certificate
— and only that one — at
<https://developer.apple.com/account/resources/certificates/list>, checking the created
date so an Apple **Distribution** certificate, or a development one belonging to a real
Mac, is left alone.

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
