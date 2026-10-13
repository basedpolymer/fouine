# Privacy

This is the privacy policy of Fouine, the Mac application. Last updated
13 October 2026.

Fouine reads all your documents; that is what it is for. So the question “where
does that text go?” needs an answer you can check, not just a promise.

The answer: nowhere. No document, no search and no usage data leaves your Mac.
Fouine makes one kind of outgoing connection, listed below, and it does not
happen unless you click something.

| | What triggers it | What it contacts | What it sends |
|---|---|---|---|
| Update check | **Off by default**. The **Check for updates…** menu item, or the switch in Settings | `github.com` ([details](updates.md)) | nothing |

It sends nothing about your documents and nothing about your Mac: no name, no
serial number, no identifier of any kind.

**Nothing goes out while Fouine indexes, reads your documents or searches.** An
automated test checks that sentence on every change to the code (see below).

---

## 1. What Fouine does not do

- **No file in Fouine's code opens a network connection.** The update check
  is not Fouine's code at all. It is Sparkle, an open-source
  updater, and it ships switched off: with `SUEnableAutomaticChecks` set to
  `false`, Sparkle does not even ask whether to check. When you do check, it
  fetches one XML file from the project's releases page and sends no identifier,
  no description of your Mac and nothing about your documents. See
  [updates](updates.md).
- **There is no account.** Fouine is free to use, and you never sign up, sign
  in, or enter a key. Nothing links one launch to the next, or one Mac to
  another.
- **There is no telemetry.** Fouine collects no usage statistics and sends no
  crash reports.
- **Everything is analysed on your Mac.** Text recognition is Apple's Vision
  framework, running locally. No text is ever sent anywhere to be analysed.
- **Nothing is written into your files**, not even the text Fouine recognised on
  a scan. That text is stored in Fouine's database.
- **Speech stays on your Mac too.** When “Also write down what is said” is on
  (it is by default), Apple's speech recognition runs on the device: Fouine sets
  `requiresOnDeviceRecognition`, so if the language is not installed on the Mac,
  the request fails instead of going to a server. No recording leaves the Mac.
- **Spotlight is covered by the same rule.** Fouine gives Spotlight the text of
  the documents macOS cannot read on its own (scanned pages, DjVu, comics), so
  you can find them from the menu-bar magnifier. Spotlight's index is local,
  like Fouine's, and one button removes everything Fouine gave it (Settings ▸
  General ▸ Spotlight). What macOS does with its own index is up to you: *Siri
  Suggestions* and *Spotlight on the Web* are macOS settings, in System Settings
  ▸ Siri & Spotlight, and Fouine does not touch them. That is the one place
  where indexed text could leave the Mac.
- **Your notes are copied, on this Mac only.** If you tick Apple Notes, Bear or
  Anki (Settings ▸ Folders ▸ Applications, off by default), Fouine opens their
  database read-only, never writes to it, and copies the text of each note into
  a Markdown file under `~/Library/Application Support/Fouine/Sources/` (for
  Anki, one file per deck). To read Anki while it is open, Fouine first copies
  the collection into a temporary folder of its own, reads that copy, and
  deletes it straight away. The Markdown copies are what Fouine indexes. They
  sit in that folder on your disk, visible in the Finder, and nothing leaves the
  Mac. Unticking the box deletes the copies and removes the notes from the
  index. Password-locked notes are skipped, because their text is encrypted.

This is a design rule, written into [`CONTRIBUTING.md`](../CONTRIBUTING.md):
adding a network session, a socket or any telemetry would change what the
product is, not improve it. One exception has been allowed: **updates**,
because Fouine is distributed outside the App Store and has no other way to get
a security fix to people who have already downloaded it. It comes with three
conditions: a published address, full disclosure to the user, and no call
unless the user did something that asks for it. A second exception would need
the same discussion.

Indexing is the harder case. Fouine hands your files to macOS components
(PDFKit, Vision, the rich-text importers in AppKit), and some of them can fetch
a remote resource named inside the document itself. In principle, an `<img
src="http://…">` hidden in a `.doc` file could send a request nobody asked for,
and tell a stranger that you opened their file.

Searching the source code for network calls cannot rule that out, because such a
request would be made by macOS, to an address that comes from the document, not
from the code. So the proof is a test,
`Tests/FouineExtractTests/NetworkSilenceTests.swift`: a local web server listens
while Fouine extracts deliberately booby-trapped files, and the test passes only
if the server receives no connection at all. It runs on every change to the code
(`make ci-unit`), so a regression fails the build the day it is written.

The test covers one file type for each way Fouine reads documents:

| File | The trap |
|---|---|
| `.doc`, `.rtf` | HTML with remote `<img>` and `<link>` tags, over `http:` and `https:`, plus a non-routable address |
| `.rtfd` | a package whose `TXT.rtf` holds a remote `INCLUDEPICTURE` field |
| `.html`, `.webarchive` | the same remote resources, in their own format |
| `.epub` | a remote image and stylesheet, and an external entity in the `DOCTYPE` |
| `.docx` | a `TargetMode="External"` relationship: a linked image and a hyperlink |
| `.pdf` | an `/OpenAction` pointing to an address, a remote `/GoToR`, a `/Launch` |
| `.svg` | a remote image and an external entity |
| `.mkv` (two files) | an HLS playlist and an `ffconcat` script disguised as video, passed to ffprobe and then ffmpeg |

---

## 2. How to check it yourself

Five checks, from the quickest to the most thorough, plus the automated test
described above, which proves more than any of them.

**The entitlements the app requests.** The list is empty:

```sh
codesign -d --entitlements - /Applications/Fouine.app
```

The source file is in the repository,
[`Packaging/Fouine.entitlements`](../Packaging/Fouine.entitlements), with
comments on what Fouine does and what that requires. The app uses the hardened
runtime without a sandbox. It does not request
`com.apple.security.network.client`, nor
`com.apple.security.automation.apple-events` (Fouine controls no other app), nor
`allow-jit` (nothing in it generates code while running).

**What the signature says:**

```sh
codesign -dv --verbose=4 /Applications/Fouine.app
```

`flags=0x10000(runtime)` confirms the hardened runtime, and `TeamIdentifier`
names who signed the app. On a copy you built yourself, `TeamIdentifier=not set`
is normal: that is an ad-hoc signature.

**The source code, and why reading it is not enough.** No file under
`Sources/` opens a connection: there is no `URLSession` and no socket in
Fouine's own code. The update check is made by Sparkle (see below).

An earlier version of this page suggested `grep 'URLSession\|https://' Sources/`
as proof. It proved nothing, for two reasons:

1. it returns more than twenty lines (comments, links to documentation), when
   the page claimed it would return none;
2. more importantly, **no amount of reading the code can show that an app which
   hands untrusted files to macOS stays offline.** The request a booby-trapped
   document would trigger is made by macOS, to an address taken from the
   document. It appears in no file under `Sources/`.

That is why the proof is a test rather than a code review: `NetworkSilenceTests`
(section 1) listens on a local socket while the booby-trapped files are
extracted, and fails at the first connection. It runs on every change, and you
can run it on your own Mac with `make ci-unit`.

The update check is not in `Sources/` at all: Sparkle makes the call, and the
address it contacts is in plain text in `Packaging/Info.plist`, under the
`SUFeedURL` key. On an installed copy:

```sh
plutil -p /Applications/Fouine.app/Contents/Info.plist | grep SU
```

**What is open right now:**

```sh
sudo lsof -nP -iTCP -a -c Fouine -c fouine
```

Index a whole folder, let text recognition run, search: the command returns
nothing. It lists a connection only during an update check. This is
an observation, not a proof: it tells you nothing about what other documents
than yours might do, which is what the test is for.

**The most thorough check: an outgoing firewall** such as Little Snitch, LuLu or
Radio Silence. Install one, index a whole folder, let text recognition run,
search: Fouine never shows up. Then choose **Fouine ▸ Check for updates…**: it
makes one request, to `github.com`. Block it, and the app carries on as normal.
That is the only connection Fouine can make.

---

## 3. What the database holds, and where

Everything Fouine stores is in one SQLite file:

```
~/Library/Application Support/Fouine/fouine.db   (+ -wal, -shm)
```

It holds:

| | |
|---|---|
| the **text extracted** from your documents | that is its purpose; anyone who opens the file can read it |
| the **paths** of the indexed files | the volume's UUID plus the path on that volume |
| the **position of each line** found by text recognition | compressed; it is what draws the highlights on a scan |

> **The database is as confidential as the documents it indexes.** A folder of
> medical records, legal papers or personal notes gives a database that is just
> as sensitive. Back it up and encrypt it as you would the documents themselves.
> FileVault encrypts the whole disk, which is enough in most cases.

Other locations:

| | Path |
|---|---|
| Write lock | `~/Library/Application Support/Fouine/fouine.lock` |
| Background agent log | `~/Library/Logs/Fouine/fouine.log` (+ `.log.1`) |
| Preferences | `~/Library/Preferences/io.github.basedpolymer.fouine.plist` |
| **Copies of your notes** (Apple Notes, Bear, Anki), if you ticked an app | `~/Library/Application Support/Fouine/Sources/<App>/` |
| **Text given to Spotlight**: name, folder, and up to 1 MiB of text per document | the macOS index, `~/Library/Metadata/CoreSpotlight/` (protected by macOS) |

The log holds file paths and counts, never the content of documents.

The last two rows are the only places outside the database where text from your
documents is written, and only on this Mac. The note copies are deleted when you
untick the app. The text given to Spotlight is removed with one button (Settings
▸ General ▸ “Remove Fouine's documents from Spotlight”), and uninstalling from
Fouine's own window does this first.

`FOUINE_DB` moves the database elsewhere (the lock goes with it);
`FOUINE_AGENT_LOG` moves the log.

---

## 4. Erasing everything

Deleting the index leaves your documents untouched:

```sh
rm -rf ~/Library/Application\ Support/Fouine/
rm -rf ~/Library/Logs/Fouine/
```

**Uninstalling completely.** The simplest way is to let Fouine do it, with
**Fouine ▸ Uninstall Fouine…** in the menu bar. The window lists exactly what
will happen: the background agent is switched off, the `/usr/local/bin/fouine`
link is removed if it points to this copy, and the index, logs and preferences
are deleted if you leave their boxes ticked. Then `Fouine.app` goes to the
Trash. If you moved the database with `FOUINE_DB` to a place outside
`~/Library`, its path is shown but it is not deleted: that one is yours to
delete, knowingly.

If you installed Fouine with Homebrew, remove it with Homebrew:

```sh
brew uninstall --cask fouine          # the app; the index stays
brew uninstall --zap --cask fouine    # the app AND the index, logs,
                                      # preferences and caches
```

By hand: first untick “Keep the index up to date automatically” (which switches
off the background agent), or remove it in **System Settings ▸ General ▸ Login
Items & Extensions**. Then delete `/Applications/Fouine.app`, the two folders
above, and `~/Library/Preferences/io.github.basedpolymer.fouine.plist`.

In all three cases, the privacy permissions you granted stay listed in **System
Settings ▸ Privacy & Security**. macOS keeps them, and only you can remove them.

Uninstalling from Fouine's own window **removes Fouine's documents from
Spotlight first**, since it is the last moment the app is running; left behind,
those results would point to an app that no longer exists. An app deleted by
hand never gets that chance, so click “Remove Fouine's documents from Spotlight”
(Settings ▸ General) before deleting it.

Nothing was ever written into the folders you indexed.

---

## 5. What Fouine asks macOS for, and why

Fouine requests no entitlements. What it asks for are the standard macOS privacy
permissions, one per protected location, and only when you add a folder that is
in one of them:

| Permission | Why |
|---|---|
| Documents folder | to read the documents to index; Fouine never writes there |
| Desktop | the same |
| Downloads | the same, and the one people forget most often |
| Removable volumes | documents on an external drive |
| Network volumes | documents on an SMB or AFP share, common in a lab or an office |
| Speech recognition | to write down what is said in your recordings, entirely on this Mac; you can turn it off in Settings ▸ Indexing |
| Full Disk Access | to read Apple Notes, whose database is in a protected place, and only if you ticked Apple Notes in Settings ▸ Folders |

The exact wording macOS shows is in
[`Packaging/Info.plist`](../Packaging/Info.plist). What a refused permission
breaks, and how to grant it again: [permissions](permissions.md).

---

## 6. Reporting a problem

Any network connection from Fouine **other than the one in the table at the
top**, that is, without your clicking “Check for updates…” or turning on the
automatic check, would be a security
vulnerability in itself, and it is explicitly covered by
[`SECURITY.md`](../SECURITY.md). Please don't report it in a public issue: use
GitHub's private reporting form.

