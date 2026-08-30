# Running it, and getting it onto your iPhone

The hard constraint: **iPhone apps can only be built by Xcode, and Xcode only runs on
macOS.** There is no way round that from Windows. So this is written for a borrowed Mac,
and it is deliberately arranged so that by the end of the session you no longer need one —
new versions reach your phone over the air after that.

Nothing in this app has ever been on a screen. Expect rough edges, and treat finding them as
the point of the exercise rather than a setback.

---

## Part 0 — Before you borrow the Mac

Do these on Windows, now. The first one is the only thing here that cannot be hurried on the
day.

**1. Enrol in the Apple Developer Program.** <https://developer.apple.com/programs/enroll/>
— £79/year. **Approval can take 24–48 hours**, so start it at least two days before you
expect to have the Mac. You will need the Apple ID you want to own the app.

**2. Check your iPhone can run it.** Settings → General → About → Software Version. It needs
**iOS 17 or later**. If it is older, either update it or tell me and I will lower the app's
minimum — it costs a few small features, nothing structural.

**3. Find a USB cable** that connects your iPhone to the Mac. A Lightning or USB-C cable,
whichever your phone takes. Borrow one with the Mac if you need to.

**4. Make a folder for the vault** in iCloud Drive, so there is somewhere ready to point the
app at. On your iPhone: Files app → Browse → iCloud Drive → tap ⋯ → New Folder → call it
`Clinical Notes`. Leave it empty.

---

## Part 1 — The Mac session

Budget **three hours**, of which about ninety minutes is waiting for downloads. The order
below starts the slow things first so they run while you do the rest.

### Step 1 — Start the Xcode download immediately

On the Mac, open the **App Store**, search **Xcode**, click **Get** / **Install**.

It is roughly 10 GB and takes 30–60 minutes on a decent connection. **Start it before
anything else** and carry on with the next steps while it downloads.

### Step 2 — Install the two tools we need

Open **Terminal** (press ⌘ + Space, type `terminal`, press Return). Paste this and press
Return:

```bash
/bin/bash -c "$(curl -fsSL https://raw.githubusercontent.com/Homebrew/install/HEAD/install.sh)"
```

It will ask for the Mac's password — that is the login password of whoever's Mac it is. It
prints instructions at the end about adding Homebrew to your PATH; follow whatever it says,
then:

```bash
brew install xcodegen
```

### Step 3 — Get the code

```bash
git clone https://github.com/mc392/notes-vault.git
```
```bash
cd notes-vault
```

### Step 4 — Run the tests, before anything else

```bash
swift test
```

**What you should see:** it ends with `Executed 73 tests, with 0 failures`. Takes about a
minute — the pauses are real encryption running.

This is worth doing first because it separates two questions. If the tests pass here, the
storage and encryption work on this machine, so anything that goes wrong later is the app's
interface, not its foundations.

### Step 5 — Open the project

Wait for Xcode to finish installing. Then, in Terminal:

```bash
xcodegen generate
```
```bash
open NotesVault.xcodeproj
```

Xcode opens. The first launch asks to install additional components — say yes and let it.

> **A thing to know.** `NotesVault.xcodeproj` is generated from `project.yml`, and is not
> stored in the repository. If you ever re-run `xcodegen generate`, it is rebuilt from
> scratch and any settings you changed by hand in Xcode — including the signing team in the
> next step — are wiped. Just set them again.

### Step 6 — See it on the Mac first

Before dealing with the phone, run the Mac version. It is the fastest way to find out
whether the app works at all.

At the top of the Xcode window there is a dropdown showing the run destination. Set it to
**My Mac**. Press the **▶ Play button** (or ⌘R).

**What you should see:** the app opens showing "GroundWork Notes — Clinical notes that stay
yours", with three explanation rows and a **Choose a folder** button.

Try the whole flow: choose any empty folder on the Mac, set a passphrase, write the recovery
key down, type it back, add a client code like `SM2`, write a note, lock it, unlock it.

**If it crashes**, Xcode stops and highlights a line in red. Copy the red error text from the
bottom panel and send it to me — that is a real bug and exactly what this session is for.

### Step 7 — Sign the app with your Apple account

In Xcode's left sidebar click the blue **NotesVault** project icon at the very top. Then:

1. Select the **NotesVault** target in the middle column.
2. Click the **Signing & Capabilities** tab.
3. Tick **Automatically manage signing**.
4. In **Team**, choose your name / the Developer Program account.

Xcode will churn for a moment and create the certificates it needs. If it shows an error
about the bundle identifier already being in use, change **Bundle Identifier** to something
unique — for example add your initials: `com.charlottebloor.groundworknotes.mc`.

### Step 8 — Connect your iPhone

1. Plug the iPhone into the Mac with the cable.
2. On the iPhone a dialogue asks **Trust This Computer?** — tap **Trust**, enter your
   passcode.
3. On the iPhone: Settings → Privacy & Security → scroll to the bottom → **Developer Mode** →
   turn it **on**. The phone restarts.

### Step 9 — Run it on the phone

Back in Xcode, click the destination dropdown at the top and choose **your iPhone by name**
(it appears under a heading like "iOS Device"). Press **▶** again.

The first build for a device takes a few minutes.

**The first time only**, the app will refuse to open on the phone with a message about an
untrusted developer. Fix it on the iPhone: Settings → General → **VPN & Device Management** →
tap your Apple ID → **Trust**.

Then open **GroundWork Notes** from your home screen. iOS truncates the label, so it reads
"GroundWork No…" under the icon.

---

## Part 2 — What to check on the phone

These are the things no test and no compiler can answer. In value order.

**1. The document picker into iCloud Drive.** Tap **Choose a folder**, navigate to iCloud
Drive → `Clinical Notes`, select it. This is the single biggest unknown in the whole project
— it is the mechanism the entire "your cloud, not ours" design rests on, and it has never
been tried. If it fails, tell me exactly what happens.

**2. Create a vault and write down the recovery key.** Use a real piece of paper. You will
be made to type it back — that is deliberate.

**3. Write a note.** Add client `SM2`, write a session note, save it.

**4. Look at what actually landed in iCloud.** Open the **Files** app → iCloud Drive →
`Clinical Notes`. You should see a folder called `d` and, inside it, folders and files with
meaningless names. **You should not be able to find `SM2`, the date, or any word you typed.**
This is the product's central promise, and this is you checking it with your own eyes.

**5. Lock and unlock.** Close the app, leave it five minutes, reopen it. It should ask for
your passphrase again.

**6. Face ID.** On the unlock screen, tick "Unlock with Face ID next time", unlock once with
the passphrase, then lock and reopen. It should offer Face ID.

**7. Write a correction.** Open a note, tap **Write a correction**, change some words, save.
The original must still be there under "Show corrected" — nothing is ever overwritten.

**8. Export.** Settings → Export everything. Pick a folder. Then open one of the exported
`.note` files in the Files app — it should be readable plain text.

---

## Part 3 — The one check that needs the Mac, not the phone

**Open your vault in Cryptomator's own app.** This is the highest-value single check in the
project.

On the Mac: install Cryptomator from <https://cryptomator.org> (free). Open it, choose
**Add Existing Vault**, point it at the same `Clinical Notes` folder in iCloud Drive, enter
the same passphrase.

**If it opens and you can see `SM2/2026-08-30T…note` with your note inside it**, the
encryption format is confirmed correct by a completely independent implementation — not just
by our own tests agreeing with themselves. That is the strongest evidence available that the
notes are genuinely recoverable without us, which is the promise the whole product is built
on.

If it does not open, that is a serious finding and worth stopping for. Send me what
Cryptomator says.

---

## Part 4 — After you give the Mac back

Set this up **while you still have the Mac**, so that afterwards new versions reach your
phone without one.

**TestFlight** is Apple's system for trying apps before release. Once it is wired up,
GitHub's Mac servers build every change you push and send it to your phone automatically;
you install it from the TestFlight app like any other update. No Mac involved.

It needs, roughly:
- an app record created in App Store Connect;
- an App Store Connect API key, stored as a GitHub secret;
- a signing certificate and provisioning profile, also stored as secrets;
- a `release` job added to `.github/workflows/ci.yml` that archives and uploads.

That is a chunk of fiddly setup with a lot of specific names and IDs, and it is much easier
to do with the Mac in front of you. **Tell me when you get to this point and I will write
the whole thing** — the workflow job and a step-by-step for the App Store Connect side.

---

## If it goes wrong

**Xcode says "Command Line Tools not found"** — run `xcode-select --install` in Terminal.

**`brew: command not found` after installing Homebrew** — Homebrew printed two lines to run
at the end of its install. Scroll back up in Terminal, run them, then try again.

**"Untrusted Developer" on the iPhone** — Settings → General → VPN & Device Management → tap
your Apple ID → Trust. Covered in Step 9.

**"Unable to install" / "device is locked"** — unlock the iPhone and leave it on the home
screen while Xcode installs.

**The app installs but immediately closes** — that is a crash on launch. In Xcode, press ▶
again while the phone is connected; Xcode will catch the crash and show you the line. Send
me that.

**Signing errors mentioning a provisioning profile** — the most common cause is that the
Developer Program enrolment has not finished yet. Check
<https://developer.apple.com/account> shows an active membership.

**Anything at all that looks wrong on screen** — take a screenshot (iPhone: side button +
volume up) and send it. Layout on a real phone has never been seen by anyone.
