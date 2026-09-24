# Updates

Fouine is distributed outside the App Store: you download it once, in a disk
image, and nothing replaces it afterwards. That is a security problem before it
is a convenience one. Without an update mechanism, a copy installed the day
before a fix stays vulnerable forever.

Fouine therefore includes [Sparkle 2](https://sparkle-project.org), the standard
update library on macOS, under the MIT licence. It ships inside
`Fouine.app/Contents/Frameworks/Sparkle.framework`, signed with the rest of the
app.

**The update check is off, and stays off until you ask for it.**

---

## 1. What goes out on the network, and when

This mechanism makes one kind of outgoing connection, and only after you do
something:

| What you do | What happens |
|---|---|
| Nothing | nothing. No connection is ever opened. |
| Fouine ▸ Check for updates… | one HTTPS request to the address below, once |
| You turn on "Check for updates automatically" in Settings | the same request, once a day (or at the interval you chose) |
| An update exists and you accept it | the disk image is downloaded from the project's releases |

This is the only address contacted:

```
https://github.com/basedpolymer/fouine/releases/latest/download/appcast.xml
```

It is a small XML file, the *appcast*, that lists the published versions, their
numbers and the address of each disk image. Fouine downloads it, compares the
version numbers with its own, and shows something only if yours is older.

The request carries no identifier, no serial number, no description of your Mac,
and nothing about your documents, your indexed folders or your searches. Sparkle
can send an anonymous system profile, and the `SUEnableSystemProfiling` key is
explicitly `false` in the `Info.plist`. What remains is what any download
reveals: your IP address and the time, seen by GitHub.

---

## 2. Why it is off by default

Left at its defaults, Sparkle opens its own dialog at the second launch to ask
for permission to check automatically. In an app whose rule is that nothing
leaves your Mac, that dialog would come up before you had asked for anything.

The `SUEnableAutomaticChecks` key set to `false` removes that dialog. This has
two practical consequences:

- nothing tells you when a new version exists. Check now and then, or turn on
  the switch in Settings knowing what it does;
- an update never installs itself. `SUAllowsAutomaticUpdates` is `false` as
  well: even with the switch on, Fouine shows you what it found and waits for
  your answer.

---

## 3. Checking for yourself

An outgoing firewall (Little Snitch, LuLu, Radio Silence) gives the clearest
answer. Install one, then:

1. Open Fouine, index, search, let it run. It does not appear in the firewall.
2. Click **Fouine ▸ Check for updates…**. One request to `github.com` appears.
   It is the only one, and you just triggered it.
3. Block it: the Updates tab shows that the check failed, and Fouine keeps
   working normally.

Without a firewall, with the app open and left alone, run:

```sh
lsof -nP -i -a -c Fouine
```

It prints nothing.

The Updates tab in Settings shows the same information as this page: the
address contacted, the state of the switch, the date of the last check.

---

## 4. How Fouine checks that an update is authentic

An update mechanism downloads code and replaces an app, so it needs strong
protection. Two independent checks provide it.

1. **EdDSA (Ed25519) signature of the appcast and the archive.** The app embeds
   a public key (`SUPublicEDKey`). Every published version is signed with the
   matching private key, which never leaves the maintainer's keychain. A disk
   image altered in transit, or served by someone else, is rejected without
   being run.
2. **Developer ID signature and Apple notarisation**, as for the first install.
   Sparkle checks that the new version is signed by the same team as the one
   running.

Someone who wanted to deliver code to a Fouine user would have to break both.

---

## 5. If the menu item is greyed out

"Check for updates…" is disabled when Sparkle could not start. Hover over it:
the tooltip gives the reason. There are two cases:

- The copy was built without a public key. `SUPublicEDKey`, in
  `Packaging/Info.plist`, holds the project's public EdDSA key. It belongs in the
  repository: a public key is meant to be published, and it lets your copy
  verify an update without trusting anyone. The private key has never been in
  the repository: it lives in the maintainer's keychain and in a GitHub secret.
  So this case only happens if you emptied the field in your own build, or if
  you are building a fork with your own key pair. See
  [`RELEASING.md`](../RELEASING.md), § 1.a "The Sparkle signing key".
- Fouine is not running from `Fouine.app`. `swift run FouineApp` has no bundle to
  replace.

In both cases the app works normally. Only the version check is unavailable,
and nothing is sent on the network.

---

## 6. Doing without Sparkle altogether

You don't have to use it. Download the new disk image from the project's
releases page and drag the app into `/Applications` over the old one. Your index
is untouched: it lives in `~/Library/Application Support/Fouine/`, a folder that
does not depend on the app (see [privacy](privacy.md)).
