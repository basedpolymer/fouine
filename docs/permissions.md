# macOS permissions

When a folder stays empty in Fouine, the cause is almost always the same: macOS
refuses to read it. To an app, a folder it may not read looks exactly like an
empty folder, so Fouine tests each folder by actually opening a file in it.

This page covers every variant of "why is my folder still empty?".

---

## Why does macOS ask me for permission?

Since macOS Mojave, some locations are protected: Documents, Desktop, Downloads,
removable volumes and network volumes. This macOS security mechanism (often
called TCC, for *Transparency, Consent, and Control*) requires an app to get
your explicit consent, once, for each location.

The prompt appears when you add a folder that sits in one of them. A folder
somewhere else, such as one you created at the root of your home folder or an
unprotected mounted volume, triggers no prompt, and that is normal.

---

## I refused the prompt. What happens?

When you add the folder, Fouine opens a file in it. If macOS refuses the read,
the folder is not added, and an alert explains why. Besides OK, the alert has
two buttons:

- **Open System Settings**, which goes straight to *Privacy & Security ▸ Files
  and Folders*;
- **Retry**, which shows the folder chooser again once you have granted the
  permission.

A folder that was added earlier and can no longer be read (a permission
withdrawn, an app that moved, a new signature) stays in your list. Its documents
stay searchable, but they are no longer updated. The app then shows a
persistent orange banner at the top of the window, with two buttons:

- **Open Settings**, which goes straight to *Privacy & Security ▸ Files and
  Folders*;
- **Retry**, which checks again once the permission is granted.

The Index card at the top of the sidebar shows "Fouine is not allowed to read
'…'" and offers **Allow access…**.

---

## How do I grant the permission?

Open **System Settings ▸ Privacy & Security ▸ Files and Folders ▸ Fouine**, then
tick the location concerned (Documents Folder, Downloads Folder, Desktop
Folder…).

If Fouine is not in that list at all, the prompt was never triggered: remove the
folder and add it again.

For volumes, use **Privacy & Security ▸ Files and Folders ▸ Fouine ▸ Removable
Volumes** (or *Network Volumes*). Some versions of macOS group these under *Full
Disk Access*, which covers everything at once. That is broader than necessary,
but it works.

---

## How do I know the permission is really granted?

```sh
fouine doctor
```

It tests the effective read of every folder: it opens a file instead of relying
on a `stat`, which succeeds even when reading is refused. For each folder it
prints `effective read of a file: OK`, or exits with code 5, naming the folder
and what to do.

In the app, the orange banner is gone and the sidebar lists your folders without
an error.

---

## `fouine doctor` says OK but the app stays empty (or the other way round)

The command line and the app do not share their permissions:

> **The command line inherits the permissions of the terminal that runs it. The
> app has its own.**

If your Terminal has access to the Documents folder, `fouine doctor` succeeds
from Terminal while Fouine.app is refused, and the reverse happens too. The first
line of `fouine doctor` names the context it tests, to avoid this confusion.

Grant the permission to the app concerned: Fouine in System Settings for the
app, your terminal for the command line.

---

## My Downloads folder will not index

Same cause, another checkbox: *Privacy & Security ▸ Files and Folders ▸ Fouine
▸ **Downloads Folder***.

It is the location people forget most often. A first-time user drops their PDFs
there, adds it as a folder, and gets an empty index. For that reason, a message
appears when you add a folder under Downloads.

---

## Automatic updates index nothing

The background service that keeps the index up to date (run by macOS through
`launchd`) has no interface, so it cannot show a prompt and ask for your consent
on screen. Unless Fouine already has the permission, macOS refuses the read
silently.

That is why the **Keep the index up to date automatically** switch (under the
Index card) stays off until a folder has been added and allowed. The order of
the steps matters:

1. Open the app.
2. Add a folder, and accept the prompt.
3. Then turn on automatic updates.

If the service runs but indexes nothing, its log gives the reason:

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

macOS files permissions by path and signature. There are three possible causes:

- The app moved. Launched sometimes from a development folder and sometimes from
  `/Applications`, it asks for its permissions again each time. Install it in
  `/Applications` and leave it there.
- The signature changed. That happens with a build you made yourself: each
  ad-hoc build can produce a different identity. A notarised release keeps the
  same one.
- A major macOS update reset the pane. This is rare, but it happens.

---

## My folder disappeared from the index and `doctor` says nothing about permissions

Then it is not a permission problem. A moved or renamed folder produces a
different message, and the agent's log says "FSEvents burst … matched no active
root". The fix is different too: run `fouine root list`, then add the folder
again at its new location.

`doctor` tells the two cases apart, and mentions permissions only when a read is
actually refused.

---

## Fouine is asking for "Speech Recognition"

**Also write down what is said in them** (Settings ▸ Indexing) is ticked by
default, so macOS asks for this permission the first time Fouine transcribes a
recording. Untick the box and the permission is never requested.

With the box ticked, Fouine writes down the speech in your audio and video files
so you can search it. Everything happens on your Mac, and no recording is sent
anywhere: Fouine sets a technical flag in macOS (`requiresOnDeviceRecognition`)
that makes the request fail rather than go to a server.

Two things are needed, and macOS says which one is missing:

1. The dictation language installed: System Settings ▸ Keyboard ▸ Dictation,
   then add the language of your recordings. Without it, the files are reported
   as unreadable, with what to do;
2. the permission: System Settings ▸ Privacy & Security ▸ Speech Recognition,
   where Fouine must be ticked.

The titles, artists, albums and chapters of your audio and video files need
neither. They are indexed as long as the first box, **Index audio and video
files (titles, artists, chapters…)**, is ticked.

---

## Fouine is asking for "Full Disk Access" for my notes

This only happens if you ticked **Apple Notes** in Settings ▸ Folders ▸
Applications. That box starts unticked, and while it is unticked, no permission
is requested.

Apple Notes does not keep your notes in files. It keeps them in a database, in a
place macOS protects from every app. "Files and Folders" does not cover that
place: it takes Full Disk Access, which is a different pane.

To grant it, open System Settings ▸ Privacy & Security ▸ **Full Disk Access**,
then tick **Fouine** (the button in the Settings window takes you straight
there). macOS asks you to quit and reopen Fouine for the permission to take
effect. The background service reads the same notes: if it cannot see them,
tick the entry with the same name in that pane too.

Fouine reads the title, the text, the folder and the date of your notes there,
and nothing else, read-only. It never writes to the Notes database. It copies
the text into its own folder (`~/Library/Application Support/Fouine/Sources/Notes/`)
so it can search it, and nothing leaves your Mac. Unticking the box deletes those
copies.

Password-locked notes stay unreadable, for Fouine as for any app, and are
skipped.

Bear does not need this permission in most installations. If a message says
Fouine is not allowed to read Bear's notes anyway, the fix is the same.

Anki does not need it either: its collection sits in
`~/Library/Application Support/Anki2/`, a place macOS does not protect.

---

## Can Fouine ask for less?

It already asks for the minimum. The entitlements dictionary built into the app
is empty: no network access, no control of other apps, no JIT. The only
permissions requested are those of the locations you choose, one per location,
at the moment you add them.

Some folders cannot be added at all, so that Fouine never needs to ask for more:
the root of the disk, the whole home folder, `~/Library`, `/System`, `/Library`,
`/Applications`, `/private`.

See [privacy](privacy.md).
