# macOS permissions

Almost every problem reported on Fouine comes down to one thing: **macOS
silently refuses to read a folder**. The folder indexes as if it were empty,
and nothing says so.

This page answers every variant of "why is my folder still empty?".

---

## Why does macOS ask me for permission?

Since macOS Mojave, some locations are protected: **Documents**, **Desktop**,
**Downloads**, **removable volumes** and **network volumes**. This macOS
security mechanism (often called TCC, for *Transparency, Consent, and Control*)
requires an app to get your explicit consent, once, per location.

Fouine triggers the prompt when you add a folder that sits in one of them. If
you index a folder somewhere else, a folder you created at the root of your
home directory, an unprotected mounted volume, no prompt appears, and that is
normal.

---

## I refused the prompt. What happens?

The folder is registered, the walk finds it, and **zero files come out of it**.
With no error message: it is macOS answering "this folder is empty", and
nothing lets an app tell that apart from a folder that really is empty.

The app then shows a persistent orange banner at the top of the window, with
two buttons:

- **Open Settings**, which goes straight to *Privacy & Security ▸ Files and
  Folders*;
- **Retry**, which probes again once the permission is granted.

The **Index** card at the top of the sidebar shows **"Fouine is not allowed to
read '…'"** and offers **Allow access…**.

---

## How do I grant the permission?

**System Settings ▸ Privacy & Security ▸ Files and Folders ▸ Fouine**, then
tick the location concerned (Documents Folder, Downloads Folder, Desktop
Folder…).

If Fouine does not appear in that list at all, the prompt was never triggered:
remove the folder and add it again.

For volumes: **Privacy & Security ▸ Files and Folders ▸ Fouine ▸ Removable
Volumes** (or *Network Volumes*). Some versions of macOS group these under
*Full Disk Access*, which covers everything at once. That is broader than
necessary, but it works.

---

## How do I know the permission is really granted?

```sh
fouine doctor
```

It tests the **effective read** of every folder: it actually opens a file
rather than settling for a `stat`, which succeeds even when reading is refused.
For each folder it prints `effective read of a file: OK`, or exits **5** naming
the folder and the gesture.

In the app, the sign is simply that the orange banner is gone and the sidebar
lists your folders without an error.

---

## `fouine doctor` says OK but the app stays empty (or the other way round)

This is the trickiest trap, and it is real:

> **The command line inherits the permissions of the terminal that runs it. The
> app has its own.**

If your Terminal has access to the Documents folder, `fouine doctor` succeeds
from Terminal while Fouine.app is refused, and the reverse happens too.
`fouine doctor` prints the context it tests on its first line, precisely to
avoid this misunderstanding.

Set the permission for **the app concerned**: Fouine in Settings for the app,
your terminal for the command line.

---

## My Downloads folder will not index

Same cause, another checkbox: *Privacy & Security ▸ Files and Folders ▸ Fouine
▸ **Downloads Folder***.

It is the most often forgotten location. A first-time user drops their PDFs
there, adds it as a folder, and gets an empty index. Fouine warns you when you
add a folder under Downloads, for that reason.

---

## Automatic updates index nothing

The background service that keeps the index up to date (run by macOS through
`launchd`) **can show no prompt at all**: with no interface, it cannot ask for
your consent on screen. Unless Fouine already has the permission, macOS refuses
the read without a word.

That is why the **"Keep the index up to date automatically"** switch (under the
Index card) stays off **until a folder has been added and allowed**. The order
of the gestures matters:

1. Open the app.
2. Add a folder, **accept the prompt**.
3. *Then* turn on automatic updates.

If the service runs but indexes nothing, its log says so:

```sh
tail -f ~/Library/Logs/Fouine/fouine.log
```

The agent's log is in English, like the command line (see [`i18n.md`](i18n.md)).
Look for:

```
root “…” IGNORED — read denied (privacy settings or file permissions)
a background agent CANNOT show a permission prompt: open Fouine.app once, or grant the access by hand (§7.1).
```

---

## The permission was granted, and it vanished

macOS files permissions by **path and signature**. Three possible causes:

- **The app moved.** Launched sometimes from a development folder, sometimes
  from `/Applications`, it asks for its permissions again every time. Install
  it in `/Applications` and leave it there.
- **The signature changed.** That happens with a build you made yourself: each
  ad-hoc recompilation can produce a different identity. On a notarised
  release, it does not.
- **A major macOS update** reset the pane. Rare, but seen.

On this project a lost permission means a half-empty index with no error
message, which is why the point is laboured.

---

## My folder disappeared from the index and `doctor` says nothing about permissions

Then it is not a permission. A **moved or renamed** folder produces a different
message, and the agent's log says "FSEvents burst … matched no active root".
The gesture differs: `fouine root list`, then add the folder again at its new
location.

`doctor` tells the two cases apart and mentions permissions only for a real
read refusal.

---

## Fouine is asking for "Speech Recognition"

Only if you ticked **"Also write down what is said in them"** in Settings ▸
Indexing. That box starts off, and while it is off, Fouine asks for nothing.

Ticked, Fouine writes down the speech in your audio and video files so you can
search them. **Everything happens on your Mac**: no recording is sent anywhere,
and Fouine refuses to work rather than send anything. That is a technical
setting it imposes on macOS itself, not a promise in the air.

Two things are needed, and macOS says which one is missing:

1. **The dictation language installed**: System Settings ▸ Keyboard ▸
   Dictation, then add the language of your recordings. Without it the files
   are reported as unreadable with the gesture to make;
2. **the permission**: System Settings ▸ Privacy & Security ▸ Speech
   Recognition, where Fouine must be ticked.

The **titles, artists, albums and chapters** of your audio and video files need
neither: they are indexed as soon as the first box, "Index audio and video
files (titles, artists, chapters…)", is ticked.

---

## Fouine is asking for "Full Disk Access" for my notes

Only if you ticked **Apple Notes** in Settings ▸ Folders ▸ Applications. That
box starts off, and while it is off, Fouine asks for nothing.

**Why that pane.** Apple Notes does not keep your notes in files: it keeps them
in a database, in a place macOS protects from every app at once. That place is
not covered by "Files and Folders": it takes **Full Disk Access**, which is a
different pane.

**How.** System Settings ▸ Privacy & Security ▸ **Full Disk Access**, then tick
**Fouine** (the button in the settings window takes you straight there). macOS
asks you to quit and reopen Fouine for the permission to take effect. The
background service reads the same notes: if it cannot see them, tick the entry
with the same name in that pane too.

**What Fouine reads there, and nothing else**: the title, the text, the folder
and the date of your notes, **read-only**. It never writes to the Notes
database. It copies their text into its own folder
(`~/Library/Application Support/Fouine/Sources/Notes/`) so it can search it;
nothing leaves your Mac. Unticking the box deletes those copies.

**Password-locked notes stay unreadable**, for Fouine as for anyone: they are
skipped.

**Bear** does not need this permission in most installations. If Fouine says it
is not allowed to read its notes anyway, the gesture is the same.

**Anki** does not need it either: its collection sits in
`~/Library/Application Support/Anki2/`, a place macOS does not protect.

---

## Can Fouine ask for less?

It already asks for the minimum. The **entitlements** dictionary built into the
app is **empty**: no network access, no driving of other apps, no JIT. The only
permissions requested are those of the locations **you** name, one per
location, at the moment you name them.

Fouine also refuses to index some folders, precisely so it does not have to ask
for more: the root of the disk, the whole home folder, `~/Library`, `/System`,
`/Library`, `/Applications`, `/private`.

See [privacy](privacy.md).
