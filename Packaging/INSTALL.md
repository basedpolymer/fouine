# Installing Fouine

Two paths, depending on where the app came from.

- **You downloaded a release**: open the disk image, drag `Fouine.app` onto
  `Applications`, and resume at **step 3**. Steps 1 and 2 are not for you.
- **You are building from source**: start at step 1.

Everything from step 3 on is a **user gesture**: each step goes through a system
prompt or a privacy setting, and none of it can be automated. **The order
matters**, and reversing it condemns automatic updates to a silent refusal.

To **publish** a version (notarisation, DMG, tag, CI secrets),
[`../RELEASING.md`](../RELEASING.md) is what counts; this page only covers
installing on a machine.

---

## 1. Building and signing

```sh
make release                          # universal x86_64 + arm64 (default)
make release ARCHS=$(uname -m)        # one slice only, for fast iteration
```

`make release` chains: `swift build -c release`, `Packaging/bundle.sh`, stamping
the versions into `Contents/Info.plist`, `codesign` **from the inside out**
(`MacOS/FouineAgent`, then `Helpers/fouine`, then `MacOS/Fouine`, then the bundle
with `Packaging/Fouine.entitlements`), then the checks.

The result is `Fouine.app`, at the root of the repository. It is **not**
committed (`.gitignore`).

### The signing identity

`IDENTITY` is **empty by default**, and the signature is then **ad hoc**: the app
works on the machine that produced it and nowhere else, and it cannot be
notarised. That is the normal mode for development, and it needs no Apple
account. `make release` announces it in plain words:

```
==============================================================
 SIGNATURE AD HOC : l'app ne s'ouvrira que sur cette machine
 et ne peut PAS être notarisée. …
==============================================================
```

To sign with a real Developer ID certificate, create a `Makefile.local` at the
root of the repository, **gitignored, never committed**:

```make
IDENTITY := Developer ID Application: <First Last> (<TEAMID>)
FOUINE_NOTARY_PROFILE := <notarytool-profile-name>
```

No certificate, no `.p8` or `.p12` key, no team identifier ever enters the
repository.

### Expected check

```sh
codesign -dv --verbose=4 Fouine.app      # flags=0x10000(runtime)
codesign --verify --deep --strict Fouine.app
```

`make verify` does both and reads the `TeamIdentifier` **from the certificate**;
it hard-codes none. With an ad-hoc signature, `TeamIdentifier=not set` is
**normal** and does not fail the target.

### Disk image

```sh
make dmg            # dist/Fouine-<VERSION>.dmg, hdiutil alone
```

The disk image holds the app, a link to `/Applications` and the `LICENSE`. It is
signed only when `IDENTITY` is set. See `RELEASING.md` for the exact order
relative to notarisation: `make dmg` deliberately does not rebuild the app when
one already exists, so as not to destroy the staple.

---

## 2. Installing

```sh
rm -rf /Applications/Fouine.app
cp -R Fouine.app /Applications/
```

Copying into `/Applications` is not cosmetic: privacy permissions are filed by
**path and signature**. An app launched sometimes from the repository and
sometimes from `/Applications` asks for its permissions again every time.

For the same reason, keep the **signing identity stable** from one version to
the next: without it, macOS asks for "Documents Folder" access at every
recompilation, and on this project a lost permission means a half-empty index.

---

## 3. First launch: add a folder and accept the prompt

Open **Fouine.app** (double-click, or `open /Applications/Fouine.app`).

**No folder is indexed by default.** The app opens on a welcome screen: click
**Add a folder…**, or drop a folder into the window.

If that folder is under **Documents**, **Desktop**, **Downloads**, on a
**removable volume** or a **network volume**, macOS shows:

> "Fouine would like to access files in your Documents folder."

**Accept.** That is the only moment the prompt can appear: automatic updates run
in the background with no interface and cannot show it, so they would be refused
without a word. Without the permission, the folder stays **empty with no error
message at all**. It is the project's worst failure mode.

If the prompt was refused by mistake: **System Settings ▸ Privacy & Security ▸
Files and Folders ▸ Fouine**. The app's warning banner offers an **Open
Settings** button that leads straight to that pane, and a **Retry** button; the
Index card offers **Allow access…**.

Some folders are **refused**: the root of the disk, the whole home folder,
`~/Library`, `/System`, `/Library`, `/Applications`, `/private`. Their children
stay legitimate. A folder under `~/Downloads` is accepted but flagged, because
it is the most frequently forgotten permission.

Full details: [`../docs/permissions.md`](../docs/permissions.md).

---

## 4. Checking

In the app, the warning banner must be gone and the sidebar must list your
folders. On the command line:

```sh
fouine doctor          # “effective read of a file: OK” for each folder
```

`fouine doctor` tests the **effective** read: it opens a file rather than doing
a `stat`. On refusal: exit **5**, with the name of the folder and the exact
gesture.

Mind the context: the CLI inherits the permissions of the **terminal** that runs
it, the app has its own. `fouine doctor` can succeed in Terminal while the app
is refused, and the reverse.

### Installing the command line

`fouine` travels **inside the app**, at `Contents/Helpers/fouine`, signed with
it and pointing at the same database. Menu **Fouine ▸ Install the command line
tool…** (or Settings ▸ Advanced): the app creates a symlink
`/usr/local/bin/fouine`. If the folder does not exist or is not writable, it
shows the command to paste and puts it on the clipboard. It never asks for your
administrator password:

```sh
sudo mkdir -p /usr/local/bin
sudo ln -sf /Applications/Fouine.app/Contents/Helpers/fouine /usr/local/bin/fouine
```

---

## 5. Turning on automatic updates

In the sidebar, under the Index card, turn on **Keep the index up to date
automatically** (the same switch is in the "Your index" window, Window menu).

The switch stays off **until a folder has been added and allowed** (step 3), and
that is deliberate: turning automatic updates on before granting access would
produce background work unable to index and unable to show any prompt.

It registers the background service through macOS (`SMAppService`). The
configuration files stay inside the app and are never scattered through your
home folder. macOS may ask you to confirm in **System Settings ▸ General ▸ Login
Items & Extensions**, where the service appears under the name **Fouine**.
Registration needs an app **installed and signed** in `/Applications`.

What the service then does, with no interface, and its conditions for reading
scanned pages: [`../docs/agent.md`](../docs/agent.md).

---

## 6. Reading the log

```sh
tail -f ~/Library/Logs/Fouine/fouine.log
```

The background service has neither terminal nor window: this file is how you
follow it. It is timestamped, rotates at 10 MiB (`fouine.log.1`), and records
indexing and text recognition. The lines worth recognising are listed in
[`../docs/agent.md`](../docs/agent.md).

---

## 7. Before running the CLI

Every indexing write takes an exclusive lock on
`~/Library/Application Support/Fouine/fouine.lock`, held until the next resting
point (the end of a pass or of a batch). While the background service is
writing, `fouine index`, `fouine crawl`, `fouine extract` and `fouine ocr` fail
with "database locked by another process — …" (exit 3), naming the holder.

`fouine search`, `fouine status`, `fouine doctor` and `fouine list` never take
the lock and always work. For a large manual pass, **turn the switch off**
first, then back on.

### Search by meaning: a model to install

Search by meaning (`fouine search --hybrid`, or Settings ▸ Search by meaning ▸
"Download the model…" in the app) needs a 220 MB model that is not bundled with
the app:

```sh
fouine model download        # announces what it contacts, checks the SHA-256
fouine embed                 # produces the vectors (long: several hours)
```

That is one of the four connections Fouine can ever make, and it never goes on
its own: no document, no search, no usage data leaves the Mac, which the
`NetworkSilenceTests` test verifies in continuous integration on every change.
On an offline machine, copy the archive and set
`FOUINE_MODEL_URL=file:///path/e5-small-v1.zip`. Full-text search and text
recognition need none of it. See [`../docs/search.md`](../docs/search.md) and
[`../docs/privacy.md`](../docs/privacy.md).

---

## 8. Uninstalling

**The simplest way: the built-in uninstaller.** Menu **Fouine ▸ Uninstall
Fouine…**. It unregisters the background service, removes the command-line
symlink, erases Fouine's data and offers to move the app to the Trash, in that
order, which is the only one that works: an app already deleted can no longer
unregister its own background service. Erasing is **irreversible**, an index
often being hours of reading.

**By hand**, if you prefer:

1. Turn off "Keep the index up to date automatically" under the Index card
   (which unregisters the service), or go to **System Settings ▸ General ▸ Login
   Items & Extensions ▸ Fouine**.
2. `rm -rf /Applications/Fouine.app`
3. The CLI symlink, if it was created: `sudo rm -f /usr/local/bin/fouine`
4. The data. These are the **seven** paths the Homebrew cask's `zap` removes
   (`Packaging/homebrew/fouine.rb`), and the list is exhaustive:

   ```sh
   rm -rf ~/Library/Application\ Support/Fouine
   rm -rf ~/Library/Caches/io.github.basedpolymer.fouine
   rm -rf ~/Library/Caches/fouine
   rm -rf ~/Library/HTTPStorages/io.github.basedpolymer.fouine
   rm -rf ~/Library/Logs/Fouine
   rm -f  ~/Library/Preferences/io.github.basedpolymer.fouine.plist
   rm -rf ~/Library/Saved\ Application\ State/io.github.basedpolymer.fouine.savedState
   ```

   The first holds the index **and** the meaning model: deleting it erases hours
   of text recognition and means downloading 220 MB again.

**Through Homebrew**, once the cask is published: `brew uninstall --cask fouine`
leaves the data in place, `brew uninstall --zap --cask fouine` takes the seven
paths above.

**Nothing was ever written into the indexed folders.**

---

## Notarisation

Notarisation serves one purpose: letting the app open **on another machine**, or
after a transfer that sets the quarantine flag (download, AirDrop, USB stick).
For local use on the machine that built it, the signature of step 1 is enough;
`spctl -a -vv` will refuse the app, which is expected and harmless as long as it
does not leave that machine.

It requires a **Developer ID** signature (not ad hoc) and one human gesture
beforehand, **once per machine**: creating a `notarytool` keychain profile from
an App Store Connect key.

```sh
xcrun notarytool store-credentials <profile> \
  --key /path/outside-the-repo/AuthKey_<KEYID>.p8 \
  --key-id <KEYID> \
  --issuer <UUID from appstoreconnect.com>
```

The **Issuer ID** is only readable on `appstoreconnect.com` → *Users and Access*
▸ *Integrations* ▸ *Keys*: it is the UUID at the top of the page. The `.p8` can
be downloaded **once**: keep it outside the repository and back it up.

Then:

```sh
make notarize                                             # the app
make notarize NOTARIZE_TARGET=dist/Fouine-<VERSION>.dmg   # the disk image
```

Expected afterwards: `spctl -a -vv Fouine.app` → *accepted*, *source=Notarized
Developer ID*, and `xcrun stapler validate Fouine.app` → *The validate action
worked!*

`Packaging/notarize.sh` accepts a `.app` or a `.dmg`, quotes no path and no key
identifier, and **refuses an ad-hoc signature** rather than waiting for Apple's
server to reject it.

The full publishing procedure (version, changelog, DMG, tag, CI secrets,
Homebrew cask) is in [`../RELEASING.md`](../RELEASING.md).
