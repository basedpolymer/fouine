# Privacy

This is the privacy policy of Fouine, the Mac application, and of the licence
service behind it. Last updated 24 September 2026.

Fouine reads all your documents; that is what it is for. So the question “where
does that text go?” needs an answer you can check, not just a promise.

The answer: nowhere. No document, no search and no usage data leaves your Mac.
Fouine makes five kinds of outgoing connection, listed below. Four happen only
when you click or type something. The fifth is a licence check, at most once
every 30 days, and only if a key is installed.

| | What triggers it | What it contacts | What it sends |
|---|---|---|---|
| Update check | **Off by default**. The **Check for updates…** menu item, or the switch in Settings | `github.com` ([details](updates.md)) | nothing |
| Downloading the search-by-meaning model | The `fouine model download` command, or the button in Settings | `github.com`, then `release-assets.githubusercontent.com` | nothing |
| Activating a licence key | The **Activate** button (Settings ▸ Licence), or `fouine license activate` | `basedpolymer.eu` (hosted by Vercel), which passes the request on to **Creem**, the seller | your key, and the **name of your Mac** |
| Releasing a Mac | The **Deactivate this Mac** button, or `fouine license deactivate`; also attempted when you uninstall | the same | your key, and the activation ID |
| Background key check | Launching the app, or `fouine license status`, **at most once every 30 days**, and only if a key is installed | the same | your key, and the activation ID |

None of them sends anything about your documents. Your Mac's name is sent once,
at activation, for one reason: it is the label you will see in your Creem
customer portal when you want to free one of the three Macs your key covers.
Without it, you would see three identical lines.

**Nothing goes out while Fouine indexes, reads your documents or searches.** An
automated test checks that sentence on every change to the code (see below).

---

## 1. What Fouine does not do

- **Only two files in the code open a network connection.** The first,
  `Sources/FouineEmbed/ModelDownload.swift`, downloads the search-by-meaning
  model when you ask for it: a private session that writes no cookies or cache
  to disk, a single `GET` with a single `User-Agent: Fouine/1.0.0` header, and a
  SHA-256 check of the file before it is installed. The second,
  `Sources/FouineLicense/LicenseClient.swift`, talks to the licence relay: the
  three calls described below, also in a private session, with the same single
  header, a JSON object of two or three fields, and a 15-second timeout. The
  update check is not Fouine's code at all. It is Sparkle, an open-source
  updater, and it ships switched off: with `SUEnableAutomaticChecks` set to
  `false`, Sparkle does not even ask whether to check. When you do check, it
  fetches one XML file from the project's releases page and sends no identifier,
  no description of your Mac and nothing about your documents. See
  [updates](updates.md).
- **There is no account.** Fouine is sold, and a key is activated online (table
  above), but you never sign up or sign in. Activation uses only the key you
  bought, and nothing links one launch to the next or one Mac to another.
- **There is no telemetry.** Fouine collects no usage statistics and sends no
  crash reports.
- **Everything is analysed on your Mac.** Text recognition is Apple's Vision
  framework, running locally. Search by meaning uses a CoreML model (384
  dimensions) that also runs locally: it is downloaded once, then works offline.
  No text is ever sent anywhere to be analysed.
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
product is, not improve it. Three exceptions have been allowed, each under the
same conditions: a published address, full disclosure to the user, and no call
unless the user did something that asks for it.

1. **Updates**, because Fouine is distributed outside the App Store and has no
   other way to get a security fix to people who have already downloaded it.
2. **The search-by-meaning model**, because making people build it themselves
   with Python and `torch` would keep half the product for developers.
3. **The licence**, because Fouine is sold: a key must be installable on one
   Mac, removable from another, and must stop working if the purchase is
   refunded. It is the only exception with a call that no click triggers, the
   background check, and that call happens at most once a month, only if a key
   is installed, and changes nothing when you are offline.

A fourth exception would need the same discussion.

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

### What `fouine model download` does, step by step

Nothing, until you type it. Indexing, `fouine embed`, `fouine search --hybrid`
and `fouine doctor` never download anything: they tell you what to type. When
you do type it, the command says what it is about to do, then:

- it requests
  `https://github.com/basedpolymer/fouine/releases/download/e5-small-v1/e5-small-v1.zip`;
- GitHub redirects to `release-assets.githubusercontent.com`, which serves the
  file, so two hosts appear in your firewall. That is how every GitHub download
  works;
- it follows the redirect only over `https:`. A redirect to `http:` is refused,
  the command stops and nothing is installed: a 220 MB model that will run on
  your Mac is never downloaded unencrypted, where anyone on the network could
  tamper with it;
- it sends one `GET` with the `User-Agent: Fouine/1.0.0` header: no cookie, no
  identifier, no referrer, nothing from your documents;
- it caps what it writes during the download at twice the expected size. Both
  the announced `Content-Length` and the bytes actually received are checked
  against that cap, anything beyond it is cut off, and the temporary file never
  grows past it. The cap also applies when you set `FOUINE_MODEL_SHA256`, which
  is exactly when the archive comes from somewhere else;
- it checks the size, then the SHA-256 of the archive. If a single byte is
  wrong, nothing is installed;
- it installs the model in `~/Library/Application
  Support/Fouine/models/e5-small`. `fouine model remove` deletes it; `fouine
  model status` shows what is installed.

`FOUINE_MODEL_URL` installs from another source, such as a local file copied
from a USB stick (`file:///…/e5-small-v1.zip`). Fouine then opens no connection
at all. That is the recommended way on a Mac kept offline.

### What activating a key does, step by step

Nothing, until you paste a key and click **Activate** (or type `fouine license
activate`). Then, and only then, Fouine sends one JSON object with three fields
(the action, `activate`; the key; and your Mac's name as macOS knows it) to
`https://basedpolymer.eu/api/fouine/license`.

- **Fouine does not call Creem directly, for a reason.** Creem's licence service
  requires the seller's secret API key. An app that carried that key would hand
  it to everyone who downloads it. The relay keeps it on a server, in one place;
  the app never has it, so it cannot leak it. The relay is hosted by Vercel, and
  its code is part of the website (`api/fouine/license.js`).
- **Your Mac's name** is the only fact about your machine that Fouine ever
  sends. It is not an identifier made up for tracking: it is the label you will
  see in your Creem customer portal, to know which Mac to free. You can replace
  it with anything you like: `fouine license activate <key> --instance-name
  "Laptop"`.
- **Nothing else is sent**: not your serial number or any other hardware
  identifier, not a byte of your documents, and no usage statistics. Like any
  website, the server sees the IP address the request comes from; Fouine adds
  nothing to it.
- **The reply is saved in a plain text file** that you can open and read:
  `~/Library/Application Support/Fouine/license.json`. It holds the date your
  trial started, the key, the activation ID, your Mac's name and two timestamps.
  That is everything Fouine keeps about your purchase. You can delete the file
  at any time; Fouine then goes back to trial mode.
- **The background check** happens when the app launches, at most once every 30
  days, and only if a key is installed. It sends the key and the activation ID.
  If you are offline or the service does not answer, nothing changes: not your
  licence, not even the date of the last check. Fouine tries again at the next
  launch. Nobody loses their software because a server was down, or because they
  worked offline for a month.
- **The background indexing agent never goes online.** It only reads
  `license.json`.

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

**The source code, and why reading it is not enough.** Two files in Fouine open
a connection, and only two: `Sources/FouineEmbed/ModelDownload.swift`, the model
download, and `Sources/FouineLicense/LicenseClient.swift`, the three licence
calls. Everything is in them, with comments: the addresses as constants (in
`LicenseTerms.swift` for the second), the private sessions, the single header,
the SHA-256 check, and the exact JSON object that activation sends.

An earlier version of this page suggested `grep 'URLSession\|https://' Sources/`
as proof. It proved nothing, for two reasons:

1. it returns more than twenty lines (comments, links to documentation, download
   constants), when the page claimed it would return none;
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
nothing. It lists a connection only during the ones in the table above. This is
an observation, not a proof: it tells you nothing about what other documents
than yours might do, which is what the test is for.

**The most thorough check: an outgoing firewall** such as Little Snitch, LuLu or
Radio Silence. Install one, index a whole folder, let text recognition run,
search: Fouine never shows up. Then trigger the connections one at a time:

- **Fouine ▸ Check for updates…** makes one request, to `github.com`. Block it,
  and the app carries on as normal;
- `fouine model download` makes one request to `github.com`, **then a second to
  `release-assets.githubusercontent.com`** (the redirect that serves the file).
  Block them, and the command stops with a message and installs nothing;
  full-text search never needed the model;
- **Settings ▸ Licence ▸ Activate**, or `fouine license activate <key>`, makes
  one request, to `basedpolymer.eu`. Block it: Fouine shows “No connection” and
  writes nothing. The same goes for **Deactivate this Mac**.

Those are the only connections Fouine can make, and you have just triggered all
of them.

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
| the **meaning vectors** of the pages, if you prepared search by meaning | 384 bytes per page |

> **The database is as confidential as the documents it indexes.** A folder of
> medical records, legal papers or personal notes gives a database that is just
> as sensitive. Back it up and encrypt it as you would the documents themselves.
> FileVault encrypts the whole disk, which is enough in most cases.

Other locations:

| | Path |
|---|---|
| Write lock | `~/Library/Application Support/Fouine/fouine.lock` |
| **Licence**: trial start date, key, activation ID, Mac name, two timestamps | `~/Library/Application Support/Fouine/license.json` (a plain file you can read, permissions `0600`) |
| Search-by-meaning model | `~/Library/Application Support/Fouine/models/e5-small` |
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

If a licence key is installed, uninstalling frees this Mac with the seller
first, so your key can be used elsewhere. That is one call, five seconds at
most, and no wait at all if the network is down. You can always free the Mac
from your Creem customer portal instead. The `license.json` file is deleted with
the rest.

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

Any network connection from Fouine **other than those in the table at the top**,
that is, without your clicking “Check for updates…”, running `fouine model
download` or doing something with your licence key, would be a security
vulnerability in itself, and it is explicitly covered by
[`SECURITY.md`](../SECURITY.md). Please don't report it in a public issue: use
GitHub's private reporting form.

