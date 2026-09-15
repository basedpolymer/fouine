# Security policy

## Supported versions

| Version | Supported |
|---|---|
| 1.0.x | yes, the current line |
| < 1.0.0 | no: development versions, never published |

The project keeps no maintenance branch. Security fixes ship in the current
version, and updating means replacing `Fouine.app`.

## Reporting a vulnerability

**Do not open a public issue.** Use GitHub's private form:

> [github.com/basedpolymer/fouine](https://github.com/basedpolymer/fouine) ▸
> the **Security** tab ▸ **Report a vulnerability**

It opens a private thread between you and the maintainer, with attachments.
That is the only channel: the project publishes no email address for this, and
a report sent another way risks being seen late, or in public.

> The form is enabled when the repository is published. GitHub's private
> vulnerability reporting is off by default and can only be ticked on a public
> repository, so the step is part of the publication checklist. If the link
> above does not show «Report a vulnerability», open an issue that says
> **only** «I have a security report to make», with no detail.

What helps, in order of usefulness:

1. the smallest gesture that reproduces the problem, ideally a sample file and
   the `fouine …` command that triggers it;
2. the version (`fouine --version`) and the version of macOS;
3. what the attacker concretely gets (reading a file outside a root, code
   execution, a write, a denial of service);
4. a proposed fix, if you have one.

## Response times

This project is run by one person; the times below are a good-faith commitment,
not a service contract.

| Step | Target |
|---|---|
| Acknowledgement | 3 working days |
| First assessment (severity, scope) | 10 days |
| Fix published, for a confirmed code-execution or out-of-scope-read flaw | 30 days |
| Public disclosure | after the fix, or by agreement |

The fix is announced in `CHANGELOG.md`, under a **Security** entry saying what
was reachable and from when. Reports are credited unless you ask otherwise.

## Threat model

Two attackers are taken seriously, because they are the two that really exist
for a local search engine.

**The hostile document.** Fouine reads files the user did not write and does
not control: downloaded archives, PDFs received by mail, scans, comics,
attachments. Their content reaches extractors, external tools (`bsdtar`,
`djvused`) and system importers. **That content is assumed to be written by an
adversary** whose goal is to execute code, to read or write outside the indexed
root, to send a request over the network, or to block indexing. This is the
main model.

**The hostile network during the model download.** The 220 MB of the semantic
model arrive over the network, from an attacker assumed able to answer in place
of the server, to redirect, or to send more than was announced. The main
counter-measure is the SHA-256, checked before any installation: one byte out
of place and nothing is installed. Two more surround it, because a digest is
only verified at the end: **redirects are followed only in `https:`**, so a
redirect to `http:` is refused rather than silently followed, and **a size
ceiling applies IN FLIGHT**, at twice the expected size, on the announced
`Content-Length` as well as on the bytes received, truncating the chunk that
crosses it. That ceiling also applies when `FOUINE_MODEL_SHA256` is set, which
is when the archive comes from elsewhere. A flaw in that path (redirect scheme,
in-flight size, a partial write left behind) is in scope.

Two attackers are **outside** the model, and that deserves saying as clearly:

- **anyone who can already set environment variables in the process.**
  `FOUINE_DB`, `FOUINE_MODEL_URL`, `FOUINE_MODEL_SHA256` and `FOUINE_DJVUSED`
  are accepted troubleshooting levers: whoever can set them already runs code
  as the user and no longer needs Fouine;
- **the other administrator account on the same machine.** macOS protects
  `~/Library` through the home directory's permissions, and Fouine tightens its
  own files further, but an administrator goes around that by design.

## Scope

**In scope:**

- any document or archive that, once indexed, leads to code execution, to a
  read or write outside the indexed root, or to a corrupted index;
- the invocation of the external tools (`bsdtar`, `djvused`) and the
  construction of their command lines;
- privilege escalation through the background agent, its plist or its service;
- **indexed content leaving the machine.** No document, no search query and no
  usage data leaves the Mac. Fouine opens four outbound connections, and only
  one of them does not wait for a gesture: the optional model download, the
  update check (off by default), licence activation or release, and the silent
  licence check (at most once every 30 days, and only when a key is present).
  None of them carries anything about your documents. **Any other connection
  observed is a flaw in itself**, and that is exactly what `NetworkSilenceTests`
  holds in continuous integration: a local server listens while a pass indexes
  trapped fixtures (`.doc`, `.rtf`, `.rtfd`, `.html`, `.webarchive`, `.epub`,
  `.docx`, `.pdf`, `.svg`, and two media containers handed to ffprobe then
  ffmpeg), and the assertion is «zero connections». The detailed list, trap by
  trap, is in [`docs/privacy.md`](docs/privacy.md);
- the permissions of the files the product writes (index, logs, licence file);
- signing, entitlements, and the publication chain.

**Four local surfaces**, and what they expose. None of them speaks to the
network, but they all take indexed text out of the single `fouine.db` file, and
that is why they are in scope.

- **Spotlight.** Fouine copies into the macOS index, for each donated document,
  its name, its folder and up to `spotlight.text_kb` of text (1 MiB by
  default). `spotlight.enabled` is **true** by default, but only documents
  Spotlight cannot read by itself are donated. That index lives in
  `~/Library/Metadata/CoreSpotlight/`, which macOS protects through TCC: a
  program without Full Disk Access reads nothing there. To put nothing in it:
  Settings ▸ General ▸ «Remove Fouine's documents from Spotlight», or `fouine
  config set spotlight.enabled false`. A leak out of that index, or donated
  text beyond the ceiling, is a flaw.
- **App Intents.** The **«Get the text of a page»** action returns the text of
  an indexed page to **any local automation**, without confirmation and without
  opening the application. That is the intended behaviour of a Shortcuts
  action, and it is also a reminder that a user account already running code
  can read the index, which it could equally do by opening the file. An action
  returning anything other than what the index contains (the original file, a
  page outside the index) would be a flaw.
- **Copied notes.** Ticked, an application source brings the content of
  **another** application's database (Apple Notes, Bear, Anki) into extraction,
  and then into `~/Library/Application Support/Fouine/Sources/`. Those bases are
  read strictly read-only (Anki's on a private copy, so that its write-ahead log
  is read without touching the original), and a note's text is decompressed
  under a ceiling, failing which a crafted note would turn a few kilobytes into
  gigabytes. A deck name never places a copy outside that folder: every path
  component is cleaned and checked before writing. The
  boxes are **off to begin with**; Apple Notes additionally requires Full Disk
  Access.
- **The `fouine://` link.** Any web page can bring Fouine to the front and make
  it open a sheet carrying a path chosen by the link's author. The gesture that
  sheet offers is bounded to what Fouine could have indexed: an ordinary file,
  under a followed root, not executable, and a package only when its extension
  is a format Fouine reads. Widening that rule is a flaw.

One example treated on those terms: entry names read **inside** a user-supplied
archive used to go back to the extraction tool as operands with no separator,
so an entry name could be read as an **option** of that tool, and some
archiving options run a program. Fixed before the first public version, with a
regression test on a trapped archive. Every flaw of that family gets the same
priority.

**Out of scope:**

- what a user can already do with their own rights: index a folder, read their
  own index, point `FOUINE_DB` at a base of their own;
- an attacker who already has physical access to the unlocked Mac, the user's
  account, another administrator account, or the ability to set environment
  variables in the process (see *Threat model*);
- vulnerabilities in system components (SQLite, Vision, PDFKit, libarchive):
  report those to Apple. **Our use** of those components is in scope, and we
  will gladly work around a system defect that reaches our users;
- Gatekeeper warnings on a self-built, ad-hoc-signed version: that is the
  expected and documented behaviour;
- search results judged poor, performance regressions, and crashes with no
  security consequence, which are ordinary issues.
