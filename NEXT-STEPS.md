# Start here

Last updated 30 August 2026. Written to be followed by someone who has never done this
before. Every command is meant to be copied and pasted exactly.

---

> ## ✅ This is done — 30 August 2026
>
> The code is on GitHub at <https://github.com/mc392/notes-vault>, it compiles for Mac and
> iPhone with no errors and no warnings, and all 73 tests pass. It took two rounds of fixes,
> neither of which was in the app itself.
>
> **You do not need to follow the steps below again.** They are kept because they still
> describe how the build-and-fix loop works, and you will use it again whenever a change
> stops the build. Steps 6 to 10 are the loop; steps 1 to 5 were one-time setup.
>
> **What is next is Stage 2 in [README.md](README.md), and it needs a Mac.** The single most
> valuable thing there: create a vault with this app, then open it with Cryptomator's own
> app. If Cryptomator can read it, the encryption format is confirmed correct by an
> independent implementation rather than by our own tests agreeing with themselves.

---

## What you are doing today

Putting the code on GitHub, so that GitHub's Mac computers can try to build it and tell you
what is wrong with it.

The code has never been compiled. It was written on a Windows machine, and this app can only
be built on a Mac. Rather than buying one, you are going to borrow one: GitHub gives you
free use of Mac computers to build code that lives in a public repository. That is what
"CI" means throughout this document — it is just a Mac somewhere else, running the build
each time you upload a change.

**Time:** about 30 minutes to get set up, then a repeating loop that depends on how many
errors there are.

**You will need:** your GitHub username and password (the account already used for
GroundWork), and a web browser.

**Expect the first build to fail.** That is normal and is the entire point of today. Six
thousand lines of code have never been checked by a compiler. The build failing is it doing
its job.

---

## Step 1 — Open a terminal

A terminal is a window where you type commands instead of clicking.

1. Press the **Windows key**.
2. Type `terminal`.
3. Click **Terminal** (or **Windows PowerShell** if you don't see Terminal).

A window opens with a line of text ending in `>`. That is the prompt. It is waiting for you.

Throughout this document: **type or paste one command, then press Enter.** Wait for it to
finish and for the prompt to come back before doing the next one.

Right-click pastes into a terminal window. Ctrl+V usually works too.

## Step 2 — Go to the project folder

Copy this line, paste it, press Enter:

```
cd C:\Users\mattc\ClaudeCode\NotesVault
```

**What you should see:** the prompt changes to end with `NotesVault>`. Nothing else happens.
That is correct — this command only moves you to a folder.

To check you are in the right place, run:

```
dir
```

**What you should see:** a list including `Package.swift`, `README.md`, `Sources`, `Tests`.
If you see those, you are in the right folder.

## Step 3 — Install the GitHub command-line tool

This is a small program that lets you talk to GitHub from the terminal. Run:

```
winget install --id GitHub.cli
```

**What you should see:** a progress bar, then `Successfully installed`. Takes a minute or
two.

**Now close the terminal window completely and open a new one** (Windows key → `terminal`).
This is not optional — the new program is only found by terminals opened after it was
installed.

In the new window, go back to the folder and check it worked:

```
cd C:\Users\mattc\ClaudeCode\NotesVault
gh --version
```

**What you should see:** something like `gh version 2.62.0`. If instead you see
`gh is not recognized`, see Troubleshooting at the bottom.

## Step 4 — Sign in to GitHub

Run:

```
gh auth login
```

This one asks you questions. Use the **arrow keys** to move between choices and **Enter** to
pick one. You will be asked roughly these, in this order:

| Question | Answer |
|---|---|
| What account do you want to log into? | **GitHub.com** |
| What is your preferred protocol for Git operations? | **HTTPS** |
| Authenticate Git with your GitHub credentials? | **Yes** |
| How would you like to authenticate? | **Login with a web browser** |

It then shows a **one-time code** that looks like `A1B2-C3D4`.

1. Write the code down or copy it.
2. Press Enter. Your web browser opens.
3. Sign in to GitHub if it asks.
4. Paste the code, click **Continue**, then **Authorize github**.
5. Go back to the terminal.

**What you should see:** `✓ Logged in as mc392` (or whatever your username is).

You only ever do this once on this computer.

## Step 5 — Create the repository and upload the code

This single command creates a new public repository on GitHub called `notes-vault`, connects
this folder to it, and uploads everything:

```
gh repo create notes-vault --public --source=. --remote=origin --push
```

**What you should see:** a few lines ending with a web address like
`https://github.com/mc392/notes-vault`. That is your new repository. Copy that address
somewhere — you will use it in the next step.

> **A note on "public".** This makes the code readable by anyone. It contains no client
> data, no passwords and no keys — it is the app itself, not anything anyone has written in
> it. You chose public deliberately: it gives you free use of GitHub's Mac computers, and
> for a product whose whole promise is that it cannot read your notes, being open to
> inspection is a genuine selling point.

The moment the upload finishes, GitHub starts trying to build it. You do not need to do
anything to start it.

## Step 6 — Watch the first build

Open your repository page in the browser:

```
gh browse
```

Click the **Actions** tab along the top.

You will see one entry named after your upload. Click it. Inside are two jobs:

- **Core and crypto tests** — checks the logic and the encryption
- **Build the app** — checks the whole app compiles

A **yellow dot** means running. A **green tick** means it worked. A **red X** means it
failed. The first run takes about five minutes.

**A red X is the expected result today.** Do not be discouraged by it. Carry on to Step 7.

## Step 7 — Collect the errors

This is **two** commands, and the order matters. First, find the build you want:

```
gh run list --limit 1
```

**What you should see:** one line, containing a long number like `33304076148`. That is the
run ID. Copy it.

Now save that run's errors to a file, putting your own number where `RUN_ID` is:

```
gh run view RUN_ID --log-failed > ci-errors.txt
```

> **Why the number is needed.** Without it, `gh` tries to ask you which run you mean — but it
> cannot ask a question when its output is being sent to a file, so it gives up and writes
> nothing. An empty `ci-errors.txt` means you hit this, not that there were no errors.
> Always pass the run ID.

**What this does:** writes everything that went wrong into `ci-errors.txt` in this folder.
Nothing appears on screen — that part is correct.

Check it actually has something in it:

```
notepad ci-errors.txt
```

If Notepad opens and is completely blank, go back and re-run the two commands with the run
ID. Do not carry on with an empty file.

You will see a lot of text. Most of it does not matter. The lines that matter contain the
word `error:` and look like this:

```
Sources/NotesVaultCore/NoteRecord.swift:142:19: error: cannot convert value of type 'String'
```

That means: in the file `NoteRecord.swift`, on line 142, something is wrong.

**Ignore every line that says `warning:`.** Warnings are suggestions, not problems. Only
`error:` stops the build.

## Step 8 — Get the errors fixed

The fastest way is to hand them back to Claude Code, which wrote this code and knows why
every part of it is the way it is.

In the terminal:

```
claude
```

Then type, as your message:

> Here are the CI errors from the first build. Please fix them. The file is ci-errors.txt in
> this folder.

Claude will read the file and edit the code. Let it finish.

**If you would rather look yourself,** three things are worth knowing:

1. **Start at the top.** Programming errors cascade — one mistake early on causes four more
   complaints later. Fixing the first often clears several others.
2. **Fix as many as you can before uploading again.** Each upload takes five minutes to come
   back, so it is much faster to fix ten things and upload once than to upload ten times.
3. **The likely trouble spots,** in order: the files in `Sources/NotesVaultCrypto/` (they
   talk to an outside library), then `Sources/NotesVaultApp/Views/` (the screens), then
   `AppModel.swift`.

## Step 9 — Upload the fixes

Three commands, in this order:

```
git add -A
```
```
git commit -m "Fix build errors"
```
```
git push
```

**What you should see:** after the last one, a few lines about writing objects, ending in
something mentioning `main -> main`.

GitHub starts building again automatically.

## Step 10 — Repeat

Go back to Step 6. Watch, collect errors, fix, upload.

**Two or three rounds is normal.** Each round should produce noticeably fewer errors than
the last. If a round produces *more* errors than the one before, that is worth mentioning to
Claude rather than pushing on.

---

## How you know you are done for today

Both jobs show a **green tick** in the Actions tab.

At that point you have proved four things: the code compiles, it fits together, the Xcode
project is valid, and — most importantly — what the app writes to disk is a genuine
encrypted vault. That is everything that can be checked without a real Mac and a real
iPhone.

**One thing to watch for even when it is green.** The build passing and the tests passing
are different questions. If the tests job is green, both are fine. If you ever see the build
job green but the tests job red, that is more interesting than a compile error: it means the
app builds but does the wrong thing. Errors in `VaultIntegrationTests` matter most of all —
those are the tests that check the encryption is really working.

Then stop, and write down where you got to. The next stage needs a Mac, and is described in
`README.md` under **Stage 2**.

---

## Troubleshooting

**`gh is not recognized`** — you did not open a new terminal after installing it. Close the
window completely and open a new one, then `cd C:\Users\mattc\ClaudeCode\NotesVault` again.

**`winget is not recognized`** — install GitHub CLI by hand from <https://cli.github.com>,
then close and reopen the terminal.

**`gh repo create` says the name already exists** — you already have a repository called
`notes-vault`. Either use a different name in the command, or check whether you already did
this step.

**The Actions tab is empty** — wait a minute and refresh. If it stays empty, check that the
folder `.github` was uploaded: run `gh browse` and look for it in the file list.

**`ci-errors.txt` is empty (0 bytes)** — you left out the run ID. `gh` cannot ask you which
run you meant while its output is going to a file, so it writes nothing. Run
`gh run list --limit 1`, copy the long number, and use it: `gh run view NUMBER --log-failed
> ci-errors.txt`.

**A build fails in under 30 seconds** — that is too fast to be your code; nothing has even
been compiled yet. It is almost always a setup problem, like a version mismatch between what
the build needs and what the Mac at GitHub has. Send the log to Claude rather than looking
for a mistake in the app.

**`git push` says "rejected"** — something changed on GitHub that you do not have. Run
`git pull --rebase` then `git push` again.

**A command seems stuck** — some take minutes. If you are certain it has hung, press
**Ctrl+C** to stop it, then run it again.

**You want to start the terminal steps over** — nothing here is destructive. Re-running any
command in Steps 1–4 is safe.

---

## Words you will see

- **Repository (repo)** — a folder of code stored on GitHub, with its full history.
- **Commit** — a saved snapshot of your changes, with a note about what changed.
- **Push** — upload your commits to GitHub.
- **CI** — the Mac at GitHub that tries to build your code every time you push.
- **Build** — turning written code into a program that runs. This is where errors surface.
- **Compile error** — the code is written wrongly and cannot be turned into a program. Today
  is about clearing these.
- **Test** — a small automatic check that the code does what it should. Different from, and
  more interesting than, a compile error.

---

## Still undecided (not for today)

Do not let these quietly become defaults:

- The product name. "Notes Vault" is a working title.
- Which features sit behind the paid tier.
- Terms of service and liability — this is being sold to other professionals.
- The support policy for lost recovery keys. The app tells the counsellor plainly that
  nobody can recover their notes. Support needs to say the same thing, in the same words,
  without sounding like it is hiding something.
