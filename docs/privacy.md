# Privacy

> This page is also served at [basedpolymer.eu/fouine/privacy](https://basedpolymer.eu/fouine/privacy),
> which is where the app's **What Fouine sends, in detail** button and Creem's
> product page point. The two are the same text; update both together
> (RELEASING § 12).

Fouine reads all your documents. That is its job, and it is exactly why
"where does that text go?" deserves an answer you can check rather than a
promise.

The answer: nowhere. No document, no search, no usage data leaves your Mac.
Four outgoing connections exist, and only one of them does not wait for a
gesture of yours.

| | What triggers it | What it contacts | What it sends |
|---|---|---|---|
| Update check | **Off by default**; the **Check for Updates…** menu item, or the switch in Settings | `github.com` ([details](updates.md)) | nothing |
| Downloading the search-by-meaning model | The `fouine model download` command, or the button in Settings | `github.com`, then `release-assets.githubusercontent.com` | nothing |
| Activating a licence key | The **Activate** button (Settings ▸ Licence), or `fouine license activate` | `basedpolymer.eu` (hosted at Vercel), which relays to **Creem**, the seller | your key, and the **name of your Mac** |
| Releasing a Mac | The **Deactivate this Mac** button, or `fouine license deactivate`; and uninstalling, on a best-effort basis | the same | your key, and the activation id |
| Silent key check | Launching the app, or `fouine license status`, **at most once every 30 days**, and only if a key is installed | the same | your key, and the activation id |

None of them sends anything about your documents. The name of your Mac goes out
once, at activation, for one reason: it is what you will read in your customer
area the day you want to free one of the three Macs your key covers. Without
it, you would read three identical lines.

**Nothing goes out while Fouine indexes, reads your documents or searches.**
A continuous integration test holds that sentence, not a promise (see below).

---

## 1. What is not there

- **No network behind your back.** There are two `URLSession` objects in all of
  Fouine's code. The first, `Sources/FouineEmbed/ModelDownload.swift`,
  downloads the search-by-meaning model when you ask for it: ephemeral, no
  cookie or cache written to disk, one `GET` and one `User-Agent: Fouine/1.0.0`
  header, and the SHA-256 of what arrives is verified before installation. The
  second, `Sources/FouineLicense/LicenseClient.swift`, talks to the licence
  relay: three calls, described below, ephemeral as well, the same single
  header, a JSON object of two or three fields, and a 15-second timeout.
  The update check is not Fouine's code at all: it is Sparkle, whose source is
  public, shipped **off**. The `SUEnableAutomaticChecks` key set to `false`
  stops Sparkle from even asking the question. It contacts one address, an XML
  file on the project's releases page, and sends no identifier, no machine
  profile, nothing about your documents. See [updates](updates.md).
- **No account, no password, no profile.** Fouine is sold, and a key is
  activated online (table above), but there is nothing to create and nothing to
  log into. Activation knows only the key you bought. Fouine never identifies
  you, between two launches or between two Macs.
- **No telemetry**, no analytics, no crash report sent anywhere.
- **No remote model.** Text recognition is Apple Vision, on the machine. Search
  by meaning is a 384-dimension CoreML model, on the machine, downloaded once
  and then used offline. No text ever leaves to be analysed elsewhere.
- **No writing into your files**, not even to add the text layer Fouine
  recognised. The result of recognition lives in Fouine's database.
- **Speech stays on the machine too.** With "Also write down what is said" on
  (off by default), Apple's speech recognition runs on the device, and Fouine
  requires it to (`requiresOnDeviceRecognition`): when the language is not
  installed locally, the request fails rather than going to a server. No
  recording leaves the Mac.
- **Spotlight is no exception.** Fouine hands Spotlight the text of the
  documents macOS cannot read by itself (scanned pages, DjVu, comics) so they
  can be found from the magnifier. Spotlight's index is local, exactly like
  Fouine's, and one button takes it all back (Settings ▸ General ▸ Spotlight).
  What macOS then does with its own index is yours to command: *Siri
  Suggestions* and *Spotlight on the Web* are macOS settings, in System
  Settings ▸ Siri & Spotlight, and Fouine does not touch them. That is the one
  place where indexed content could leave the machine.
- **Your notes are copied, on this Mac.** If you tick Apple Notes, Bear or Anki
  (Settings ▸ Folders ▸ Applications, off by default), Fouine reads their
  database read-only, never writing to it, and copies the **text** of each note
  into a Markdown file under `~/Library/Application Support/Fouine/Sources/`
  (for Anki, one file per deck). To read Anki while it is open, Fouine first
  copies the collection into a temporary folder of its own, reads that copy and
  deletes it straight away.
  That copy is what it indexes. It sits on your disk, in your folder, visible in
  the Finder, and nothing leaves the Mac. Unticking the box **deletes** those
  copies and removes the notes from the index. Password-locked notes are
  skipped: their text is encrypted, and Fouine reads it no better than anyone.

This is a design rule written into [`CONTRIBUTING.md`](../CONTRIBUTING.md): any
`URLSession`, any socket, any telemetry changes the nature of the product
rather than improving it. Three exceptions have been admitted, each under the
same conditions, which are an announced address, everything said to the user,
and no call that does not answer a gesture:

1. **Updates**, because distributed outside the App Store, Fouine has no other
   way of getting a security fix to someone who already downloaded the disk
   image;
2. **The search-by-meaning model**, because reserving it to whoever can run a
   Python script with a `torch` environment would reserve half the product to
   developers;
3. **The licence**, because Fouine is sold: a key must be installable on a Mac,
   removable from another, and must stop working if it was refunded. It is the
   only one of the three with a call that no click triggers, the silent check,
   and that one is capped at one per month, goes out only if a key is
   installed, and changes nothing at all when you are offline.

There will be no fourth without the same discussion.

**And indexing?** That is the real question, and it deserves better than a
promise. Fouine hands your files to system components (PDFKit, Vision, AppKit's
rich-text importers), and some of them know how to fetch a remote resource
**named inside the document itself**. An `<img src="http://…">` hidden in a
`.doc` would be enough, in principle, to send out a request nobody asked for,
and to confirm to a stranger that you opened their file.

That is why the proof this project publishes is no longer a `grep` through the
sources. A `grep` cannot see a request the system makes from an address that is
not in the code. The proof is a test held by continuous integration,
`Tests/FouineExtractTests/NetworkSilenceTests.swift`: a local HTTP server
listens while an extraction pass processes deliberately booby-trapped fixtures,
and the assertion is **zero accepted connections**. It runs on every change
(`make ci-unit`). A regression turns CI red the day it is written.

The formats covered, one per ingestion path:

| Fixture | The trap |
|---|---|
| `.doc`, `.rtf` | HTML with remote `<img>` and `<link>`, in `http:` and `https:`, plus a non-routable address |
| `.rtfd` | a package whose `TXT.rtf` carries a remote `INCLUDEPICTURE` field |
| `.html`, `.webarchive` | the same sub-resources, in their own format |
| `.epub` | a remote image and stylesheet, and an external entity in the `DOCTYPE` |
| `.docx` | a `TargetMode="External"` relationship: linked image and hyperlink |
| `.pdf` | an `/OpenAction` to an address, a remote `/GoToR`, a `/Launch` |
| `.svg` | a remote image and an external entity |
| `.mkv` (two) | an HLS playlist and an `ffconcat` script disguised as video, passed to ffprobe then ffmpeg |

### What `fouine model download` does, exactly

Nothing until you type it. Neither `fouine embed`, nor `fouine search
--hybrid`, nor `fouine doctor`, nor indexing downloads anything: they say what
to type. When you type it, the command announces what it is about to do, then:

- it requests `https://github.com/basedpolymer/fouine/releases/download/e5-small-v1/e5-small-v1.zip`;
- GitHub answers with a redirect to `release-assets.githubusercontent.com`,
  which serves the file, so **two hosts appear in your firewall**. That is
  normal, and how every GitHub release asset works;
- **the redirect is followed only in `https:`.** A redirect to `http:` is
  refused, the command stops and nothing is installed: 220 MB of a model meant
  to run on your machine will not travel in the clear, editable by whoever
  holds the network;
- it sends a `GET` and the `User-Agent: Fouine/1.0.0` header. No cookie, no
  identifier, no referrer, nothing from your corpus;
- **it bounds what it writes during the transfer**, at twice the expected size:
  the announced `Content-Length` and the bytes actually received are both
  compared to that ceiling, the chunk that crosses it is truncated, and the
  temporary file never exceeds it. The ceiling applies when you set
  `FOUINE_MODEL_SHA256` too, which is precisely when the archive comes from
  elsewhere;
- it checks the size, then the SHA-256 of the archive. One byte wrong and
  nothing is installed;
- it installs into `~/Library/Application Support/Fouine/models/e5-small`.
  `fouine model remove` deletes it; `fouine model status` says what is there.

`FOUINE_MODEL_URL` installs from another source, a local file
(`file:///…/e5-small-v1.zip`) copied from a USB stick for instance: **Fouine
then opens no connection at all.** That is the recommended path on a machine
kept offline.

### What activating a key does, exactly

Nothing until you paste a key and click **Activate** (or type `fouine license
activate`). Then, and only then, Fouine sends **one** JSON object of three
fields, the action (`activate`), the key, and the name of your Mac as macOS
knows it, to `https://basedpolymer.eu/api/fouine/license`.

- **Creem is not called directly, and that is not a detail.** Creem's licence
  endpoints require the merchant's **secret** API key. An app distributed to
  everyone that carried it would give it to everyone. The relay carries it, on
  a server, in one place; the app does not know it and therefore cannot leak
  it. The relay is hosted at **Vercel**, and its code is the site's
  (`api/fouine/license.js`).
- **The name of the Mac** is the only machine-shaped fact Fouine ever sends. It
  is not a fabricated identifier: it is the label you will read in your Creem
  customer area to know which Mac to free. You can replace it with anything:
  `fouine license activate <key> --instance-name "Laptop"`.
- **Nothing else goes out.** No IP address deliberately attached (the one every
  server sees on an HTTPS call, yes, as for any website), no serial number, no
  hardware identifier, no account, no password, not one byte of your documents,
  not a single usage statistic.
- **The answer is written to a file you can read with your own eyes**:
  `~/Library/Application Support/Fouine/license.json`. Open it: the trial start
  date, the key, the activation id, the name of the Mac, two timestamps. That
  is everything Fouine keeps of your purchase, and you can delete it whenever
  you like, which puts the trial back on its course.
- **The silent check** goes out when the app launches, or when you type
  `fouine license status`, at most once every 30 days, and only if a key is
  installed. It sends the key and the activation id. Offline, or if the service
  does not answer, **nothing changes**: not your licence, not the date of the
  last check. It will try again next time. Nobody loses their software because
  a server went down, or because they worked for a month with no network.
- **If you freed this Mac from your customer area**, the next check learns it:
  the key is removed from `license.json`, which keeps only the trial start date
  and the word `released`, and Fouine says "This Mac was released from your
  customer portal. Enter your key again to use it here." Search keeps working;
  index updates follow the trial again, so they stop once it is over, until a
  key is entered.
  A key disabled by the seller (a refund, for instance) is a different case: it
  stays in the file, marked `revoked`.
- **The background agent never calls anything.** It reads the file, and that is
  all. A daemon talking to a licence server while you sleep is exactly what
  this page promises does not exist.
- **Another address, for testing only.** The `FOUINE_LICENSE_RELAY` environment
  variable replaces `https://basedpolymer.eu/api/fouine/license` as the address
  the three calls go to. It is **an address contacted**, with your key in the
  request, so Fouine accepts only an `https://` address, or
  `http://127.0.0.1:<port>` for a relay running on the Mac itself; anything else
  is ignored, with a warning from the command line. It exists so the licence
  can be tried against the seller's sandbox without touching the real relay.
  Nothing sets it in normal use.

---

## 2. How to check it yourself

Four checks, from the quickest to the most conclusive, and a fifth that proves
more than the others and runs in continuous integration rather than here.

**The entitlements the app asks for.** The dictionary is empty:

```sh
codesign -d --entitlements - /Applications/Fouine.app
```

The source is in the repository,
[`Packaging/Fouine.entitlements`](../Packaging/Fouine.entitlements), with a
commented inventory of what Fouine does and what that requires. The bundle uses
the hardened runtime without a sandbox:
`com.apple.security.network.client` is not requested,
`com.apple.security.automation.apple-events` is not either (Fouine drives no
other app), and neither is `allow-jit` (no component generates code at
runtime).

**What the signature says:**

```sh
codesign -dv --verbose=4 /Applications/Fouine.app
```

`flags=0x10000(runtime)` confirms the hardened runtime; `TeamIdentifier` names
who signed. On a copy you built yourself, `TeamIdentifier=not set` is normal:
that is an ad-hoc signature.

**The source code, and why reading it is not enough.**

Two files of Fouine open a connection, and only two:
`Sources/FouineEmbed/ModelDownload.swift`, the model download, and
`Sources/FouineLicense/LicenseClient.swift`, the three licence calls. Read
them: everything is there and commented, the addresses as constants
(`LicenseTerms.swift` for the second), the ephemeral sessions, the single
header, the SHA-256 check, and the exact JSON object activation sends.

This page once offered `grep 'URLSession\|https://' Sources/` as a
demonstration. That command proved nothing, for two reasons, and saying so is
better than leaving it:

1. it returns more than twenty lines (comments, documentation addresses,
   download constants) where the sentence next to it announced zero;
2. more to the point, **no reading of the code can establish the network
   silence of a product that hands untrusted files to system components.** The
   request a booby-trapped document would send is issued by the system, from an
   address that comes from the document. It appears in no file under
   `Sources/`.

So the proof is a test rather than an inspection: `NetworkSilenceTests` (§1),
which listens on a local socket while booby-trapped fixtures are extracted and
fails on the first connection. It runs in CI on every change, and it is
reproducible on your machine: `make ci-unit`.

The update check is not in `Sources/` at all: the call is made by Sparkle,
whose source is public, and the address it contacts is in plain text in
`Packaging/Info.plist` under the `SUFeedURL` key. On an installed copy:

```sh
plutil -p /Applications/Fouine.app/Contents/Info.plist | grep SU
```

**What is open, at the moment you look:**

```sh
sudo lsof -nP -iTCP -a -c Fouine -c fouine
```

Index a whole corpus, run text recognition, search: the command returns
**nothing**. It lists a socket during the connections in the table above, and
only then. That is an observation rather than a demonstration: it says nothing
about what might happen on documents other than yours, which is what the test
above is for.

**The check that settles it: an outgoing firewall.** Little Snitch, LuLu, Radio
Silence. Install one, index a whole corpus, run recognition and search: Fouine
never appears. Then provoke the connections, one by one:

- **Fouine ▸ Check for Updates…** gives one request to `github.com`. Refuse it,
  and the app carries on normally;
- `fouine model download` gives one request to `github.com`, **then a second to
  `release-assets.githubusercontent.com`** (the redirect that serves the
  asset). Refuse them, the command fails and says so, and nothing is installed;
  full-text search never needed it;
- **Settings ▸ Licence ▸ Activate**, or `fouine license activate <key>`, gives
  one request to `basedpolymer.eu`. Refuse it: Fouine says "No connection", and
  nothing is written. Same for **Deactivate this Mac**.

Those are the only ones Fouine can produce, and you have just provoked all of
them.

---

## 3. What the database holds, and where

What Fouine knows lives in **one SQLite file**:

```
~/Library/Application Support/Fouine/fouine.db   (+ -wal, -shm)
```

It holds:

| | |
|---|---|
| the **text extracted** from your documents | that is the point; it is readable in the clear by whoever opens the file |
| the **paths** of the indexed files | volume by UUID plus relative path |
| the **geometry of the lines** recognised by text recognition | compressed; it is what draws the highlights on a scan |
| the **meaning vectors** of the pages, if you ran `fouine embed` | 384 bytes per page |

> **The database is as confidential as the documents it indexes.** A corpus of
> medical files, legal papers or personal notes gives a database just as
> sensitive. Back it up and encrypt it the way you would the documents.
> FileVault covers the whole disk and is enough in most cases.

The other locations:

| | Path |
|---|---|
| Write lock | `~/Library/Application Support/Fouine/fouine.lock` |
| **Licence**: trial start, key, activation id, Mac name, two timestamps | `~/Library/Application Support/Fouine/license.json` (readable with your own eyes, permissions `0600`) |
| Search-by-meaning model | `~/Library/Application Support/Fouine/models/e5-small` |
| Agent log | `~/Library/Logs/Fouine/fouine.log` (+ `.log.1`) |
| Preferences | `~/Library/Preferences/io.github.basedpolymer.fouine.plist` |
| **Copies of your notes** (Apple Notes, Bear, Anki), if you ticked an app | `~/Library/Application Support/Fouine/Sources/<App>/` |
| **The text handed to Spotlight**: name, folder, and up to 1 MiB of text per document handed over | the macOS index, `~/Library/Metadata/CoreSpotlight/` (protected by the system) |

The log holds **file paths** and counters, not the content of documents.

The last two lines are the only places outside the database where text from
your documents is written, on this Mac and on this Mac alone. The note copies
disappear when you untick the app; the text handed to Spotlight comes back with
one button (Settings ▸ General ▸ "Remove Fouine's documents from Spotlight"),
and uninstalling from Fouine's own window does that first.

`FOUINE_DB` moves the database elsewhere (the lock follows);
`FOUINE_AGENT_LOG` moves the log.

---

## 4. Erasing everything

Deleting the index affects none of your documents:

```sh
rm -rf ~/Library/Application\ Support/Fouine/
rm -rf ~/Library/Logs/Fouine/
```

**Full uninstall.** The simplest way is to ask Fouine: **Fouine ▸ Uninstall
Fouine…**. The sheet lists exactly what will happen (the background agent
unregistered, the `/usr/local/bin/fouine` symlink removed if it really points
at this copy, the index, logs and preferences deleted if you leave the boxes
ticked), then moves `Fouine.app` to the Trash. If you moved the database with
`FOUINE_DB`, its path is shown but **not deleted** once it sits outside
`~/Library`: that one is yours to do, knowingly.

If a licence key is installed, uninstalling **frees this Mac** with the seller
first, so your key becomes available elsewhere: one call, five seconds at most,
and no waiting at all if the network is down. You can always free the Mac from
your customer area. The `license.json` file then goes with the rest.

Installed by Homebrew, removed by Homebrew:

```sh
brew uninstall --cask fouine          # the app, the index stays
brew uninstall --zap --cask fouine    # the app AND the index, logs,
                                      # preferences and caches
```

By hand: untick "Keep the index up to date automatically" first (which
unregisters the agent), or remove it in **System Settings ▸ General ▸ Login
Items & Extensions**; then delete `/Applications/Fouine.app`, the two folders
above and `~/Library/Preferences/io.github.basedpolymer.fouine.plist`.

In all three cases the **privacy permissions** you granted stay listed in
**System Settings ▸ Privacy & Security**: macOS keeps them, and you alone can
withdraw them.

Uninstalling from Fouine's own window **removes the documents handed to
Spotlight first**: it is the only moment the app is still running, and leaving
behind results that open a deleted app would be a broken promise. Deleted by
hand, the app can no longer take them back, so use the "Remove Fouine's
documents from Spotlight" button (Settings ▸ General) BEFORE.

**Nothing was ever written into the folders you indexed.**

---

## 5. What Fouine asks macOS for, and why

Fouine requests **no entitlement**. What it asks for are the macOS privacy
permissions, one per protected location, and only when you add a folder that
lives there:

| Permission | Why |
|---|---|
| Documents folder | to read the documents to index; it never writes there |
| Desktop | the same |
| Downloads | the same, and the most often forgotten |
| Removable volumes | a corpus on an external drive |
| Network volumes | a corpus on an SMB or AFP share, common in a lab or a practice |
| Speech recognition | to write down what is said in your audio and video, only if you asked for it, and all of it on this Mac |
| Full Disk Access | to read Apple Notes, whose database sits in a protected place, only if you ticked the app in Settings ▸ Folders |

The exact texts macOS displays are in
[`Packaging/Info.plist`](../Packaging/Info.plist). What a refused permission
breaks, and how to give it back: [permissions](permissions.md).

---

## 6. Reporting a problem

A network connection observed from Fouine **outside the ones in the table at
the top**, so without your having clicked "Check for Updates…", run `fouine
model download`, or touched your licence key, would be **a vulnerability in
itself**, and it is explicitly in scope in
[`SECURITY.md`](../SECURITY.md). Do not open it as a public issue: use GitHub's
private form.
