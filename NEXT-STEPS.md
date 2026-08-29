# Start here

Written 29 August 2026, for picking this up cold.

**Where you are.** The app is written — about 5,800 lines of Swift, 73 tests — and has never
been compiled, because it was written on a Windows machine with no Swift toolchain. It is
committed to a local git repository at `C:\Users\mattc\ClaudeCode\NotesVault` with no remote.

**What tomorrow is for.** Getting it to compile. You do not need a Mac for this — GitHub's
macOS runners will do it. You need about an hour of attention and a tolerance for a long
list of errors, which is normal and expected for code this size that has never been built.

**What tomorrow is not for.** The iPhone, iCloud, Face ID, the App Store. All of that comes
after it compiles. Don't skip ahead — chasing a sync bug in code that has a type error in it
is a bad afternoon.

---

## Step 1 — Decide: public or private (2 minutes)

You have to answer this before creating the repository, so answer it first.

- **Public** — free macOS runner minutes, and "you can read exactly what we do with your
  notes" is a genuinely strong claim for a zero-knowledge product. Cryptomator itself is
  open source.
- **Private** — macOS runners bill at 10× the Linux rate, so CI costs real money against
  your Actions allowance.

There is no wrong answer. Pick one and carry on. The command below assumes public; swap
`--public` for `--private` if you chose otherwise.

## Step 2 — Put it on GitHub (5 minutes)

Open a terminal in `C:\Users\mattc\ClaudeCode\NotesVault`.

Check you are signed in to the GitHub CLI:

```bash
gh auth status
```

If that fails, run `gh auth login` and follow the prompts.

Then create the repository and push:

```bash
gh repo create notes-vault --public --source=. --remote=origin --push
```

That creates the repo, adds it as `origin`, and pushes `main`. CI starts on its own.

## Step 3 — Watch the first build (5 minutes of waiting)

```bash
gh run watch
```

Two jobs run: **Core and crypto tests** and **Build the app**. The first run takes about
five minutes, mostly downloading Xcode's toolchain and the one dependency.

**It will almost certainly fail.** That is the expected outcome, not a setback — it is the
first time a compiler has ever looked at this code.

## Step 4 — Get the errors out (2 minutes)

```bash
gh run view --log-failed > ci-errors.txt
```

Open `ci-errors.txt`. The lines that matter look like:

```
Sources/NotesVaultCore/NoteRecord.swift:142:19: error: cannot convert value of type ...
```

Ignore warnings entirely for now. Only lines containing `error:` matter.

## Step 5 — Fix them (the actual work)

**The fastest way:** paste `ci-errors.txt` into Claude Code and say "fix these". The code was
written in that session; the context for every design decision is in `README.md` and in the
comments.

**If you would rather do it by hand,** three things worth knowing:

1. **Work top to bottom.** Swift errors cascade — one wrong type produces five downstream
   complaints. Fixing the first often clears the next four.
2. **Fix a batch, then push once.** Each push costs a five-minute round trip, so it is worth
   fixing everything you can see before pushing rather than going one at a time.
3. **The likeliest sources of trouble,** in order: the Cryptomator library's exact API
   (`Sources/NotesVaultCrypto/`), SwiftUI modifiers that need a newer or older OS than
   expected (`Sources/NotesVaultApp/Views/`), and Swift's type inference in closures
   (`Sources/NotesVaultApp/AppModel.swift`).

Then:

```bash
git add -A
git commit -m "Fix compile errors from first CI run"
git push
gh run watch
```

Repeat until both jobs are green. Expect two or three rounds.

## Step 6 — Read what the tests tell you (10 minutes)

Once **Build the app** is green, the compiler is satisfied. Now look at whether the tests
passed, because that is a different and more interesting question.

```bash
gh run view --log | grep -E "Test Case.*(passed|failed)" | grep failed
```

A failing test here is worth more than a green one. In particular:

- Anything in `VaultIntegrationTests` failing means the vault format is wrong — the app is
  not producing a real Cryptomator vault. Fix this before anything else.
- Anything in `RetentionTests` failing means a date rule is wrong. The expected values in
  that file were worked out from the BACP rule, not copied from the code, so trust the test
  over the implementation until you have checked by hand which is right.

## Step 7 — Stop and take stock

When both jobs are green, you have proved: it compiles, it links, the Xcode project is
valid, and what the app writes to disk is a genuine encrypted Cryptomator vault. That is the
whole of what can be verified without hardware.

Write down where you got to, then go to **Stage 2** in `README.md`, which needs a Mac. The
single highest-value thing there is the Cryptomator interop check: create a vault with this
app, open it with Cryptomator's own app. If that works, the format is verified against the
reference implementation rather than against my own assumptions about it.

---

## If something goes wrong

**`gh: command not found`** — install the GitHub CLI from <https://cli.github.com>, then
reopen the terminal.

**`gh repo create` says the name is taken** — pick another name; nothing depends on it.

**CI does not start after pushing** — check the Actions tab on GitHub. On a brand-new repo
Actions is enabled by default, but an organisation policy can disable it.

**`xcodegen: command not found` in CI** — the workflow installs it with Homebrew. If that
step fails, it is a transient Homebrew problem; re-run the job.

**The iOS Simulator build fails with "destination not found"** — the runner image has moved
on from iPhone 15. Open `.github/workflows/ci.yml` and change the simulator name in the last
step to a device the log says is available.

**You want to check something without pushing** — you cannot compile Swift on Windows, so
there is no local shortcut. Push to a branch instead of `main` if you would rather keep the
history tidy:

```bash
git switch -c fixing-build
git push -u origin fixing-build
```

---

## What has not been decided yet

Not blocking tomorrow, but do not let these quietly become defaults:

- The product name. "Notes Vault" is a working title.
- Which features sit behind the paid tier.
- Terms of service and liability posture — this is being sold to other professionals.
- The support policy for lost recovery keys. The app tells the counsellor plainly that
  nobody can recover their notes. Support needs to say the same thing, in the same words,
  without sounding like it is hiding something.
