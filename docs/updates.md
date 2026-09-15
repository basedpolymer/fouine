# Updates

Fouine is distributed outside the App Store: it is downloaded once, in a disk
image, and nothing replaces it afterwards. That is a security problem before it
is a convenience one. Without an update mechanism, a copy installed the day
before a fix stays vulnerable forever.

Hence [Sparkle 2](https://sparkle-project.org), the reference update library on
macOS, under the MIT licence. It ships inside
`Fouine.app/Contents/Frameworks/Sparkle.framework`, signed with the rest of the
app.

**It is off.** It stays off until you ask for something.

---

## 1. What goes out on the network, and when

The only outgoing connection this mechanism can make waits for a gesture of
yours:

| Gesture | What happens |
|---|---|
| You did nothing | nothing. No socket, ever. |
| **Fouine ▸ Check for Updates…** | one HTTPS request to the address below, once |
| You turn on "Check for updates automatically" in Settings | the same request, once a day (or at the interval you chose) |
| An update exists and you accept it | the disk image is downloaded from the project's releases |

The address contacted, and the only one:

```
https://github.com/basedpolymer/fouine/releases/latest/download/appcast.xml
```

It is a small XML file, the *appcast*, listing the published versions, their
number and the address of their disk image. Fouine downloads it, compares a
version number with its own, and shows something only if yours is older.

**What does NOT go with that request:** no identifier, no serial number, no
machine profile, nothing about your documents, your indexed folders or your
searches. Sparkle knows how to send an anonymous system profile; the
`SUEnableSystemProfiling` key is explicitly `false` in the `Info.plist`. What
is left is what any download reveals: your IP address and the time, seen by
GitHub.

---

## 2. Why it is off by default

An update library dropped in without care does more than sit idle: at the
**second launch**, Sparkle opens a dialog of its own asking for permission to
check automatically. An app that promises "nothing leaves your Mac" would lose
its promise before you even answered.

The `SUEnableAutomaticChecks` key set to `false` removes that question. Fouine
never asks it. Two practical consequences:

- you will not be told when a new version exists. Look now and then, or turn on
  the switch in Settings knowing what it does;
- an update never installs itself. `SUAllowsAutomaticUpdates` is `false` as
  well: even with the switch on, Fouine shows you what it found and waits.

---

## 3. Checking for yourself

**An outgoing firewall** (Little Snitch, LuLu, Radio Silence) is the check that
settles it. Install one, then:

1. Open Fouine, index, search, let it run. It does not appear in the firewall.
2. Click **Fouine ▸ Check for Updates…**. One request to `github.com` appears.
   It is the only one, and you just provoked it.
3. Refuse it: Fouine says it could not check, and keeps working normally.

**Without a firewall**, with the app open and left alone:

```sh
lsof -nP -i -a -c Fouine
```

No line.

**The settings pane** says the same thing as this document, on screen: the
address contacted, the state of the switch, the date of the last check.

---

## 4. How Fouine knows an update is genuine

An update mechanism is a door onto your machine: it downloads code and replaces
an app. Two locks close it.

1. **EdDSA (Ed25519) signature of the appcast and the archive.** The app
   embeds a **public** key (`SUPublicEDKey`). Every published version is signed
   with the matching **private** key, which never leaves the maintainer's
   keychain. A disk image altered in transit, or served by someone else, is
   rejected without being executed.
2. **Developer ID signature and Apple notarisation**, as for the initial
   install. Sparkle checks that the new version is signed by the same team as
   the one running.

The two are independent: you have to break both to deliver code to a Fouine
user.

---

## 5. If the menu item is greyed out

"Check for Updates…" is disabled when Sparkle could not start. Hover over it:
the tooltip gives the reason. The two real cases:

- **The copy was built without a public key.** `SUPublicEDKey`, in
  `Packaging/Info.plist`, carries the project's **public** EdDSA key. It is in
  the repository, and that is where it belongs: a public key is meant to be
  published, and it is what lets your copy verify an update without trusting
  anyone. The **private** key has never touched the repository: it lives in the
  maintainer's keychain and in a GitHub secret. So this case only happens if
  you emptied the field in your own build, or if you are building a fork with
  your own key pair. See [`RELEASING.md`](../RELEASING.md), § 1.a "The Sparkle
  signing key".
- **Fouine is not running from `Fouine.app`.** `swift run FouineApp` has no
  bundle to replace.

In both cases the app works entirely; only the version check is out of order,
and nothing is sent on the network.

---

## 6. Doing without Sparkle altogether

Nothing obliges you to use it. Download the new disk image from the project's
releases page and drag the app into `/Applications` over the old one. Your
index is untouched: it lives in `~/Library/Application Support/Fouine/`, a
folder that does not depend on the app (see [privacy](privacy.md)).
