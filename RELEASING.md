# Releasing Fouine

An ordered checklist. It assumes macOS, Xcode and an Apple Developer account
(99 $/year) for anything beyond local use, and nothing else: no Homebrew, no
third-party tool.

## The checklist

| | Step | Command |
|---|---|---|
| 1 | [One-time setup](#1-one-time-setup) | once in the life of the project |
| 2 | [Version and changelog](#2-version-and-changelog) | `make check-version check-changelog` |
| 3 | [Build and sign](#3-build-and-sign) | `make clean && make release` |
| 4 | [Notarise the application](#4-notarise-the-application) | `make notarize` |
| 5 | [Build the disk image](#5-build-the-disk-image) | `make dmg`, then notarise it |
| 6 | [Build the appcast](#6-build-the-appcast) | `Packaging/appcast.sh dist` |
| 7 | [Build the Claude Desktop extension](#7-build-the-claude-desktop-extension) | `make mcpb` |
| 8 | [Tag, and let CI publish](#8-tag-and-let-ci-publish) | `git push origin main --follow-tags` |
| 9 | [The end-to-end update test](#9-the-end-to-end-update-test) | once, before the first public release |
| 10 | [The Homebrew cask](#10-the-homebrew-cask) | `Packaging/cask.sh` |
| 11 | [The website](#11-the-website) | another repository |

Order matters in three places: notarising comes **after** signing, the appcast
comes **after** stapling (stapling modifies the file, and the appcast publishes
its size and signature), and the `.mcpb` comes **after** notarisation (its
binary is extracted from a downloaded archive, so Gatekeeper checks it).

---

## 1. One-time setup

Four things to do once, none of which repeats at the next version.

### a. The Sparkle signing key

Sparkle downloads an update only if the appcast carries an EdDSA signature
verifiable with the public key embedded in the **already installed**
application. So **changing the key cuts updates off for every copy already
distributed**, which carries the old public key and has no way to learn the new
one. Back this key up like a master password.

```sh
swift package resolve
".build/artifacts/sparkle/Sparkle/bin/generate_keys"
```

The keychain asks permission to store the key: accept. The PRIVATE key stays in
the login keychain under the `ed25519` account and is never written into the
repository; the tool prints the PUBLIC key, in base64. Paste it into
`Packaging/Info.plist`, in place of the empty string:

```xml
<key>SUPublicEDKey</key>
<string>THE_BASE64_STRING_PRINTED</string>
```

While it is empty, the application starts normally but the menu item «Check for
updates…» stays **greyed out**, with a tooltip explaining why, and the log
carries `The EdDSA public key is not valid`. That is the intended state of the
public repository, not a failure. Check it afterwards on a built bundle: `make
release ARCHS=x86_64` then `plutil -p Fouine.app/Contents/Info.plist | grep SU`.

Then export the private key for CI:

```sh
".build/artifacts/sparkle/Sparkle/bin/generate_keys" -x /path/outside-repo/sparkle-ed25519.txt
```

The file holds one base64 line, and that is **exactly** what goes into the
`SPARKLE_PRIVATE_KEY` secret. Unlike the other secrets it is **not** re-encoded
in base64: it already is. Store the file outside the repository, back it up,
then delete the working copy. Without that secret, `release.yml` **skips** the
appcast step and says so in the job summary: the release is still publishable,
but no installed copy will see the new version.

### b. The notarytool keychain profile

```sh
xcrun notarytool store-credentials <profile> \
  --key /path/outside-repo/AuthKey_<KEYID>.p8 \
  --key-id <KEYID> \
  --issuer <UUID from appstoreconnect.com>
```

The `.p8` can be downloaded **only once** from App Store Connect: store it
outside the repository and back it up. See the header of
`Packaging/notarize.sh`.

### c. The GitHub secrets

Settings ▸ Secrets and variables ▸ Actions ▸ *New repository secret*. The names
are what `release.yml` expects, character for character.

| Secret | Content | How to get it |
|---|---|---|
| `MACOS_CERTIFICATE_P12` | the «Developer ID Application» certificate exported as `.p12`, **base64-encoded** | Keychain ▸ export as .p12, then `base64 -i cert.p12 \| pbcopy` |
| `MACOS_CERTIFICATE_PASSWORD` | the password given at export | chosen at export |
| `APPSTORE_KEY_ID` | the API key identifier, 10 characters | App Store Connect ▸ Users and Access ▸ Integrations ▸ API keys |
| `APPSTORE_ISSUER_ID` | the issuer UUID | same page, at the top |
| `APPSTORE_PRIVATE_KEY` | the `AuthKey_<KEYID>.p8` file, **base64-encoded** | `base64 -i AuthKey_<KEYID>.p8 \| pbcopy` |
| `SPARKLE_PRIVATE_KEY` | the EdDSA private key, **as it is** (already base64) | `generate_keys -x`, above |

Without the first five, which is the case of a fork, the workflow builds with an
ad-hoc signature, skips notarisation and publication, and says so in the job
summary. It does not turn red: an outside contributor must be able to watch
their branch build. The temporary keychain the workflow creates is deleted in
`always()`, even when the job fails or is cancelled, and the decrypted `.p8` is
wiped from the runner's disk in the same step.

### d. Private vulnerability reporting, and the internal reports

`SECURITY.md` names a single reporting channel, GitHub's private vulnerability
reporting. It is **off by default**, the published link returns 404 until it is
ticked, and the setting only appears on a **public** repository. Tick it the
day the repository is opened (Settings ▸ Code security and analysis ▸ Private
vulnerability reporting ▸ Enable), then check from another account, or in a
private window, that the **Security** tab shows «Report a vulnerability».
Otherwise nobody can report a flaw except in public.

At the same time: internal reports, benches and index backups live in
`~/Fouine-verif/`, outside the repository, and must stay out of the public
**history** too.

**The public repository starts with a fresh history.** The private history
(850 commits on 14 September 2026) carries things that must not be published
even though no current file does: two personal e-mail addresses on every
commit as author, `verif/*.md` and `REPORT.md` (versioned then removed early
in the project), and absolute paths of the maintainer's home folder in a
dozen commit messages. Rewriting that history with `git filter-repo` would
have to cover all three and would still leave the author identity to fix on
every commit. The simpler and safer route is to publish **one squashed
commit**, and to keep the private repository as it is, for its history:

```sh
git config --global user.email    # must be a public address (or a GitHub noreply one)
git checkout --orphan public
git commit -m "Fouine 1.0.0 — initial public release"
git remote add public git@github.com:basedpolymer/fouine.git   # a NEW, empty repository
git push public public:main
```

**The AI-agent tooling stays out of the public tree** (owner's decision, 14
September 2026): before the orphan commit, remove `.claude/`, `CLAUDE.md`,
`AGENTS.md`, `docs/ai-agents.md`, `Tools/agents/` and `.worktreeinclude` from
the index (`git rm -r --cached …`, then delete the row that points to
`ai-agents.md` in `docs/README.md`). They keep living in the private
repository, where the agents work.

Two consequences to handle first. `CFBundleVersion` is `git rev-list --count
HEAD`, and Sparkle compares that number, so the public branch must count
**higher** than every build already installed: `BUILD_OFFSET` in the
`Makefile` is added to the count for exactly that reason (set it to the last
private build number before the squash, and never lower it). And the
`CHANGELOG` keeps the full note for 1.0.0: it is the only history the public
repository has on day one.

## 2. Version and changelog

```sh
$EDITOR VERSION                            # 1.0.0
$EDITOR Sources/FouineCore/Version.swift   # the SAME string
$EDITOR Packaging/mcpb/manifest.json       # "version", the SAME string
make check-version                         # fails if the first two disagree
swift test --filter FouineMCPTests.ManifestTests   # fails if the manifest disagrees
```

Three files, one value. The `.mcpb` manifest is the third because it is what
Claude Desktop reads to know whether the installed extension is current, and a
manifest left behind shows up nowhere else. `Packaging/mcpb.sh` refuses to
package if it disagrees with `VERSION`.

Then `CHANGELOG.md`. Entries for the version being prepared sit under
`## [X.Y.Z] — unreleased`, in the sections `Security`, `Added`, `Changed` and
`Fixed`; there is no «Unreleased» section, because `Packaging/appcast.sh`
extracts the notes Sparkle shows to every user from that single section and a
competing section would truncate them. At tag time:

1. **Date the title**: `## [X.Y.Z] — unreleased` becomes
   `## [X.Y.Z] — YYYY-MM-DD`. While «unreleased» is there, `appcast.sh` refuses
   to produce notes.
2. Check there is **only one** `## ` title for this version:
   `grep -n '^## ' CHANGELOG.md`, or `make check-changelog`.
3. Add the comparison link at the bottom of the file
   (`[X.Y.Z]: https://github.com/basedpolymer/fouine/releases/tag/vX.Y.Z`).
4. Read every entry once more and ask whether it says what changes **for the
   user**.

When several batches of work are in flight, each adds its entries under those
four sections, never under a `##` title of its own. A non-empty «Unreleased»
section fails `make check-changelog`, which `ci.yml` runs, so the problem shows
up **before** the tag rather than at publication time.

Then update the versions in `THIRD_PARTY_LICENSES.md` and the constants in
`LicensesCommand.notices` if `Package.resolved` moved: they are copied by hand,
because the file cannot be read at run time. Commit all of that together.

## 3. Build and sign

Create `Makefile.local` at the root once and for all, gitignored, never
committed:

```make
IDENTITY := Developer ID Application: First Last (TEAMID)
FOUINE_NOTARY_PROFILE := notarytool-profile-name
```

Then:

```sh
make clean
make release           # universal x86_64 + arm64, bundle, signature, verify
```

`make release` prints the identity it used. If it announces **AD HOC
SIGNATURE**, `Makefile.local` is not being read and nothing that follows will
work. In the `verify` output, `flags` must contain `runtime` and
`TeamIdentifier` must be filled in.

**The sealed resources.** `bundle.sh` copies into `Contents/Resources/`, BEFORE
signing: `Fouine.icns`, the compiled `{en,fr}.lproj/` catalogues, `LICENSE`,
`THIRD_PARTY_LICENSES.md`, and `Guide.fr.md` (the guide the Help menu opens).
Each copy is a hard failure if the source is missing: added after `codesign`,
they would make Gatekeeper refuse the package.

**The Shortcuts actions.** `bundle.sh` also produces
`Contents/Resources/Metadata.appintents` with `appintentsmetadataprocessor`,
from the constant values `make release-build` emits, so Xcode is required to
package and not only to sign. The step fails outright if it produces nothing: a
bundle without that folder launches perfectly and simply has no actions in
Shortcuts. After `make release`, check both:

```sh
ls Fouine.app/Contents/Resources/Guide.fr.md
ls Fouine.app/Contents/Resources/Metadata.appintents   # extract.actionsdata, version.json
```

Once the application is installed in `/Applications`, open **Shortcuts**,
create a shortcut and type «Fouine» in the action list: «Search in Fouine»,
«Open in Fouine» and «Get the text of a page» must be there.

## 4. Notarise the application

```sh
make notarize          # zips, submits, waits, staples, verifies
```

Expected at the end: `spctl` answers `accepted` with `source=Notarized
Developer ID`, and `stapler validate` answers `The validate action worked!`.

## 5. Build the disk image

```sh
make dmg               # dist/Fouine-<VERSION>.dmg
```

Outside a tag and outside CI the file is named
`Fouine-<VERSION>-b<CFBundleVersion>.dmg`, to avoid any collision with an
earlier build; on a tag or in CI the canonical name is used. `make dist-clean`
purges `dist/` without deleting the `.build/` cache. The target does not
rebuild the application if it already exists, deliberately: rebuilding would
destroy the staple from step 4. The script signs the DMG, verifies it, mounts
it and unmounts it.

Then notarise and staple **the DMG itself**, since that is what gets
downloaded, and compute the digests **after** stapling, because stapling
modifies the file:

```sh
make notarize NOTARIZE_TARGET=dist/Fouine-<VERSION>.dmg
shasum -a 256 dist/*.dmg > dist/SHA256SUMS
```

**Then delete `Fouine.app` from the root of the repository.** This is not
tidying up.

```sh
rm -rf Fouine.app
```

While that copy is there, macOS sees it as a second installation of Fouine. Its
`CFBundleVersion` is the commit count, so it almost always exceeds the one in
`/Applications`, and LaunchServices prefers it. The background agent, however,
was registered from `/Applications`, and `SMAppService.register()` freezes both
the bundle path and a code requirement at registration time. It then cannot
find its program and loops: `job state = spawn failed`, `last exit code = 78:
EX_CONFIG`, one attempt every 60 seconds, with nothing saying why. Worse,
deleting the copy does **not** repair the registration, and neither does
`lsregister -f /Applications/Fouine.app`: you must then turn the background
indexing switch off and on again from `/Applications/Fouine.app`. Full symptoms
and remedy: [`docs/pitfalls.md`](docs/pitfalls.md), «Two copies of Fouine.app».

## 6. Build the appcast

**After stapling, never before.** The appcast publishes the size and the EdDSA
signature of the file, and stapling modifies the file. An appcast built too
early announces a signature Sparkle will reject on every user's machine,
without anything having failed on your side.

```sh
Packaging/appcast.sh dist            # key read from the keychain
```

The script pulls the release notes from the `## [X.Y.Z]` section of
`CHANGELOG.md` and embeds them in the feed. **Three guards refuse to produce
false notes** before `generate_appcast` even starts: a non-empty «Unreleased»
section (the journal was not closed, and the notes would go out truncated), no
`## [X.Y.Z]` title for the current version, or a title still carrying
«unreleased» (the notes are not dated, so step 2 was not done). Each exits 1
with the gesture rather than warning, because `appcast.sh` runs inside
`release.yml`, where a warning is invisible.

It then prints the three values that matter:
`sparkle:shortVersionString`, what the user reads (`1.0.0`);
`sparkle:version`, the monotonic `CFBundleVersion`, **the only field Sparkle
compares**; and the `enclosure` URL, which must name the asset of the release
about to be published. The script **fails** if the feed comes out without
`sparkle:edSignature`. The commonest cause by far is a `SUPublicEDKey` that is
empty or does not match the private key: `generate_appcast` then only warns and
writes an unsigned feed that nobody could install.

**The order of operations is not intuitive.** `SUFeedURL` points at
`https://github.com/<repo>/releases/latest/download/appcast.xml`, and GitHub
serves that form by redirecting to the asset of that name in the last
**published** release; a draft does not count. Three consequences: until a
release is published the URL returns 404 and «Check for updates…» answers that
the application is up to date or that it could not check, which is normal;
`appcast.xml` must be an **asset of the release**, like the DMG, which
`release.yml` adds when the secret is present; and updating only becomes live
when you **publish** the draft.

## 7. Build the Claude Desktop extension

**After `make release` AND `make notarize`, never before.**

```sh
make mcpb              # dist/Fouine-<VERSION>.mcpb
```

An `.mcpb` is a zip archive that Claude Desktop installs on a double click; it
holds `manifest.json`, the `fouine` binary under `bin/`, and the two licence
files. `Packaging/mcpb.sh` **compiles nothing**: it copies
`Fouine.app/Contents/Helpers/fouine`, the binary step 3 signed and step 4 had
Apple stamp.

Notarisation is indispensable here, while it is optional for local use, because
the binary will be **extracted from a downloaded archive** and therefore
carries the quarantine attribute. A binary signed with a Developer ID but not
notarised is refused by Gatekeeper in that situation, and the user sees nothing
but an extension that does not answer: no message, no log on Fouine's side,
since the process never started. A binary signed ad hoc is refused everywhere
except on the machine that built it, and the script stops rather than produce
that archive.

The script checks, in order: the binary exists and is **universal** (`lipo
-archs` gives `x86_64 arm64`), its signature carries a `TeamIdentifier`, the
manifest version equals `VERSION`; then, on the reopened archive, that the zip
is readable, that `manifest.json` is valid JSON, that `bin/fouine` is
executable and that its signature survived archiving. Two escape hatches exist
for local testing and must **never** be used to publish: `MCPB_ALLOW_THIN=1`
(single-architecture binary) and `MCPB_ALLOW_ADHOC=1` (ad-hoc signature); the
produced file name keeps no trace of either. `release.yml` builds the `.mcpb`
automatically from the notarised, stapled binary in the bundle and attaches it
to the release next to the DMG, `SHA256SUMS` and the appcast.

**What is still missing for the extension directory.** The manifest has no
`privacy_policies` key, and the submission documentation makes that an
immediate rejection. It is not an oversight: the key expects a **public privacy
policy address**, therefore the website. Add it in the same commit as the URL.
The other condition, the `annotations` of the four tools, is already met. None
of this blocks direct distribution: the `.mcpb` attached to the release
installs on a double click, directory or no directory.

## 8. Tag, and let CI publish

```sh
git tag -a v<VERSION> -m "Fouine v<VERSION>"
git push origin main --follow-tags
```

The tag triggers `.github/workflows/release.yml`, which redoes the whole chain
on a clean runner and **fails immediately if the tag is not `v` plus the
contents of `VERSION`**. It leaves a **draft** release with the DMG, the
`.mcpb` extension and `SHA256SUMS`; the text is still to be written by hand
from `CHANGELOG.md`, and then published. The local artefacts of steps 3 to 7
serve as a control: if the DMG produced by CI differs in size for no
explicable reason, do not publish.

## 9. The end-to-end update test

To be done once, before the first public release. Without it, the first update
problem is discovered by users.

1. Publish `v1.0.0` through steps 2 to 8, appcast included.
2. Install that DMG into `/Applications`, on a machine (or a session) **other**
   than the development one.
3. Set `VERSION` and `Version.swift` to `1.0.1`, add a `CHANGELOG.md` entry,
   commit. `CFBundleVersion` grows on its own, being the commit count.
4. Redo steps 3 to 7 and publish `v1.0.1`.
5. On the test machine, open Fouine 1.0.0 and click **Fouine ▸ Check for
   updates…**. Expected: Sparkle's window announces 1.0.1 with the notes from
   the CHANGELOG, downloads, and the application closes, replaces itself and
   reopens as 1.0.1.
6. Check that «Automatically check for updates» is still **off**: a manual
   update must not arm it.

If step 5 fails, the test Mac's Console gives the reason in the clear (filter
on `Sparkle`): invalid signature, different public key, or feed not found.

The final test, the one that catches what commands do not see: copy the DMG to
**another** machine (or give it the quarantine attribute with `xattr -w
com.apple.quarantine "0081;0;;" file.dmg`), mount it, drag the application into
`/Applications`, open it. It must open with no warning.

## 10. The Homebrew cask

The goal is `brew install --cask basedpolymer/fouine/fouine`, which installs
`Fouine.app` **and** the `fouine` command (a link to `Contents/Helpers/fouine`,
the CLI signed with the application, rather than a copy, which would diverge at
the first update).

The cask lives in `Packaging/homebrew/fouine.rb` and `Packaging/cask.sh` fills
it in. Only two lines change between versions, `version` and `sha256`, and the
script is what writes them: a `sha256` copied by hand only shows up as wrong
when someone tries to install. Homebrew refuses an application that is not
notarised, so steps 1 to 8 must be done and the DMG published with its
`SHA256SUMS`.

**Create the tap once.** A tap is a GitHub repository named `homebrew-<name>`;
ours is `github.com/basedpolymer/homebrew-fouine`.

```sh
brew tap-new basedpolymer/fouine
cd "$(brew --repository)/Library/Taps/basedpolymer/homebrew-fouine"
```

`tap-new` builds a git repository with `Casks/` and `Formula/`. Push it to
GitHub under the exact name `homebrew-fouine`, which is what makes `brew tap
basedpolymer/fouine` work.

**Then, at each version:**

```sh
Packaging/cask.sh <VERSION> dist \
  "$(brew --repository)/Library/Taps/basedpolymer/homebrew-fouine/Casks/fouine.rb"
git -C "$(brew --repository)/Library/Taps/basedpolymer/homebrew-fouine" \
    commit -am "fouine <VERSION>" && git -C … push
```

The script reads `dist/SHA256SUMS` (the one from step 5, therefore the one the
release publishes), takes the line for `Fouine-<VERSION>.dmg`, and refuses to
output anything if it does not find it. Then check:

```sh
brew style basedpolymer/fouine
brew audit --cask --online basedpolymer/fouine/fouine
brew install --cask basedpolymer/fouine/fouine
fouine --version                                # the CLI is in the PATH
brew uninstall --cask fouine                    # leaves the index in place
brew uninstall --zap --cask fouine              # takes the index and settings
```

`--online` is the part that counts: it downloads the DMG, verifies its digest,
and checks that the application is **notarised**. A cask that passes `brew
style` but fails `brew audit --online` is a cask that will install for nobody.
(`brew style Packaging/homebrew/fouine.rb`, outside the tap, applies Homebrew's
generic Ruby rules and is not a faithful check; the authoritative one is `brew
audit --cask` inside the tap.)

What the cask does: `app "Fouine.app"` installs into `/Applications`, the
location TCC indexes; `binary` puts `fouine` in the `PATH`; `uninstall
launchctl:` **unregisters the background agent**, without which `brew
uninstall` would leave a launchd agent pointing at a deleted app; `uninstall
quit:` closes Fouine first; `zap trash:` removes the index, logs, preferences,
caches and saved window state, and **no indexed folder**, since Fouine
never wrote there; `caveats` names the authorisations to grant and links to
[`docs/permissions.md`](docs/permissions.md). Privacy authorisations (TCC)
**survive** a `--zap`: macOS keeps them and only the user can remove them in
System Settings, which the caveats say, and so does uninstalling from inside
the application.

Submitting the cask to `homebrew/cask` itself, which would give `brew install
--cask fouine` with no tap, additionally requires a stable release history with
increasing version numbers and unchanging download URLs, and a project with
users, stars and issues, which their contribution guide states explicitly.
Until then, the `basedpolymer/fouine` tap is the normal route and gives exactly
the same experience, one character apart in the install command.

## 11. The website

The site lives in another repository, `basedpolymer/website` (branch `v5`,
deployed by Vercel on push), and is served at `basedpolymer.eu/fouine`.
Nothing about it is built or published from here: no `site/` folder, no
GitHub Pages workflow. What this repository owes it is the public privacy
policy address the `.mcpb` manifest expects (step 7).

Two pages there are part of the product, and a release checks them:

| Page | What it is | Where it comes from |
|---|---|---|
| `/fouine/privacy`, `/fouine/fr/confidentialite` | the privacy policy the app's **What Fouine sends, in detail** button points at | the same text as `docs/privacy.md`, converted with `pandoc -f gfm -t html --syntax-highlighting=none` and its relative links pointed at GitHub; the French page is a summary and says the English text prevails. **Change both together** |
| `/fouine/mcp`, `/fouine/fr/mcp` | how to connect an AI assistant: install, the four tools, what goes wrong | written by hand from `docs/mcp.md`; **change it when a tool changes** |

The site carries no server-side code: nothing there answers the app, and the
app asks it nothing.
