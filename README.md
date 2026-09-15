# Fouine

Spotlight never read your scans. Fouine does.

Fouine is a full-text search engine for macOS. It reads the folders you point
it at, extracts the text of every document, indexes it **page by page**, and
runs Apple's text recognition on the pages that carry no text layer: scanned
PDFs, comic pages, photographs pasted into a `.docx`. Everything happens on
your Mac. No document, no search, no usage data ever goes out on the network.

![Fouine's main window. A search for "round-bottom flask" across a library of
chemistry books; the results list one page per hit, and the right-hand pane
shows page 18 of a 1921 PDF with both words highlighted in the
text.](docs/images/hero.png)

---

## Start in five minutes

1. **Download the disk image.** `Fouine-1.0.0.dmg`, from the releases page of
   this repository. The product page is
   [basedpolymer.eu/fouine](https://basedpolymer.eu/fouine).
2. **Open the disk image and drag `Fouine.app` onto `Applications`.** macOS
   files privacy permissions by path and signature, so an app that moves around
   asks for them again every time. Leave it in `/Applications`.
3. **Open Fouine.** Nothing is indexed until you name a folder.
4. **Click "Add a folder…"**, or drop a folder into the window: a thesis, a
   library of PDFs, an archive drive.
5. **Accept the macOS prompt.** If the folder sits under Documents, Desktop,
   Downloads, a removable volume or a network share, macOS asks for permission.
   This is the only moment it can appear, and a refusal leaves the folder
   indexing as if it were empty, with no error. See
   [permissions](docs/permissions.md).
6. **Search.** Indexing starts, results arrive as they are found, and search
   answers while the index is still being built.

To keep the index current on its own, turn on **"Keep the index up to date
automatically"** under the Index card: Fouine then watches your folders in the
background, and reads scanned pages when the Mac is plugged in and idle. See
[the background agent](docs/agent.md).

**Requirements:** macOS 13 or later, Intel or Apple Silicon (universal binary).
**Language:** the app follows the system language and speaks English and French,
macOS permission prompts included; the `fouine` command and the agent's log are
in English, like `git` or `brew`.

---

## What Fouine reads

PDF, EPUB, Word (including the old `.doc`), Excel, PowerPoint, ODF, RTF, Pages,
Numbers, Keynote, HTML and web archives, mail (EML, MBOX), plain text, Markdown,
CSV, LaTeX, subtitles, Jupyter notebooks, comic archives (CBZ, CBR), DjVu, and
source code. Old `.doc`, `.xls` and `.ppt` files are read for real: the type is
decided on the leading bytes, never on the extension. Images, audio and video
are read on request.

The full list, family by family, with what each one needs:
[formats](docs/formats.md). Pages with no text layer go to Apple's text
recognition, and the result lives in Fouine's own database. **None of your
files is ever modified.**

![A search for "name:notebook nitric acid" in a scanned PDF that carries no
text layer. The sidebar counts the page under "scanned, recognised by Fouine",
and the highlights are drawn on the image of page 27.](docs/images/ocr.png)

Typing mistakes and meaning are covered too. Fuzzy matching catches recognition
errors, and an optional local model searches by meaning: "catalyst selectivity"
finds a page about *regioselectivity* that shares none of its words. That model
is a **220 MB download**, asked for by an explicit gesture (Settings ▸ Search by
meaning, or `fouine model download`), and full-text search never needs it. See
[searching](docs/search.md).

---

## What Fouine does not do

| | |
|---|---|
| **No document management** | Fouine files nothing, sorts nothing, renames nothing. It reads your folders where they are. If you want a library with tags, notes and attachments, this is not it. |
| **No syncing** | One index per Mac. Nothing goes to a cloud, so nothing arrives from another device. |
| **No PDF editing** | The preview is read-only. Fouine never writes into your documents, not even to add the text layer it recognised. |
| **No chat** | No assistant, no summaries, no language model. Search by meaning is a local 384-dimension embedding model, nothing more. |
| **macOS 13 and later only** | Text recognition uses Vision, the background agent uses `SMAppService`. There is no Windows or Linux version, and there will not be one. |
| **No Notion, no Craft** | Their notes cannot be read on this Mac: Notion keeps an encrypted cache, Craft keeps files with no readable name. Export your pages as Markdown and add the export folder. |

---

## Price, trial and key

Fouine runs for **30 days with nothing held back**: every format, every folder,
scanned page recognition, search by meaning. No card, no account.

**Then €39, once.** Updates for life, **3 Macs** per key, no subscription. The
sale goes through Creem, which takes the payment and handles VAT; the key
appears after payment and arrives by email.

**When the trial ends**, search, preview, export, the assistant server and the
read-only command line keep working on the index you have. Only **index
updates** stop: nothing you indexed is held hostage.

To enter a key: **Fouine ▸ Enter a licence key…** (Settings ▸ Licence), or
`fouine license activate <key>`. To free the Mac for another one: **Deactivate
this Mac**, or `fouine license deactivate`.

---

## Privacy

**No document, no search, no usage data leaves your Mac.** There is no account,
no password, no server, no telemetry, no crash report sent anywhere.

Four outgoing connections exist, and only one of them does not wait for a
gesture of yours: downloading the search-by-meaning model, checking for
updates (off by default), activating or releasing a licence key, and a silent
key check at launch, at most once every 30 days. None of them sends anything
about your documents, and nothing goes out while Fouine indexes, reads or
searches.

That last sentence is held by a continuous integration test rather than by a
promise: `NetworkSilenceTests` runs a local server while an indexing pass reads
deliberately booby-trapped fixtures, and asserts zero accepted connections.

What Fouine knows lives in one SQLite file, `~/Library/Application
Support/Fouine/fouine.db`. It holds the text extracted from your documents, so
it is **as confidential as they are**: back it up and encrypt it the same way.
Details, and how to check any of this yourself: [privacy](docs/privacy.md).

---

## Command line

`fouine` does everything the app does, plus JSON export. It ships inside the app
and works on the same index. Install it from **Fouine ▸ Install the command-line
tool…**, which creates a symlink at `/usr/local/bin/fouine`.

```sh
fouine root add ~/Documents/Thesis --label Thesis   # add a folder
fouine search '"ideal gas" -biology'                # exact phrase, exclusion
fouine search 'catalysis' --hybrid --json           # meaning, JSON output
```

Every command and option: [the command line](docs/cli.md).

**Letting an assistant read your index.** `fouine mcp --stdio` serves the index
to Claude Code, Claude Desktop, Cursor, Codex or Antigravity, read-only and with
no network: five tools to search, read a page, jump to nearby pages and see what
is indexed. It never writes, never indexes, and never hands over your original
files. `fouine mcp install` configures those five clients in one command; the
command line lives inside the app
(`/Applications/Fouine.app/Contents/Helpers/fouine`) until you install it from
Settings ▸ Advanced, and the welcome screen copies the whole request for your
assistant. For Claude Desktop there is also nothing to type, the
`Fouine-<version>.mcpb` file attached to each release installing with a
double-click. See [the assistant server](docs/mcp.md).

---

## Building from source

```sh
git clone https://github.com/basedpolymer/fouine.git
cd fouine
make release ARCHS=$(uname -m)     # Fouine.app, ad-hoc signed
```

Xcode (Swift 5.10 or later) and nothing else. Three SwiftPM dependencies:
[GRDB.swift](https://github.com/groue/GRDB.swift) (MIT),
[swift-argument-parser](https://github.com/apple/swift-argument-parser)
(Apache-2.0) and [Sparkle](https://github.com/sparkle-project/Sparkle) (MIT).
Without a Developer ID certificate the signature is ad hoc, and the app runs only
on the machine that built it. See [`CONTRIBUTING.md`](CONTRIBUTING.md).

---

## Troubleshooting

| Symptom | What to do |
|---|---|
| Anything at all | `fouine doctor` first. It tests the *effective* read of every folder, names unmounted volumes, counts the scanned pages still to read and says when djvulibre is missing. |
| "Fouine is damaged and can't be opened" | Gatekeeper on an app that is not notarised, typically one you built yourself. An official release opens without a word. |
| A folder you added stays empty, with no error | Almost always a refused macOS permission. The warning banner offers **Open Settings**, and the Index card offers **Allow access…**. See [permissions](docs/permissions.md). |
| A folder under Downloads stays empty | Same cause, another checkbox: Privacy & Security ▸ Files and Folders ▸ Fouine ▸ Downloads Folder. |
| `.djvu` files are "skipped" | djvulibre is missing: `brew install djvulibre`, then index again. It is optional, like ffmpeg for a few video containers. |
| A drive is unplugged | Not an error. Search keeps answering on what is indexed, and `fouine doctor` says which volume is missing. |

Trickier cases are in [`docs/pitfalls.md`](docs/pitfalls.md).

---

## Licence

Fouine is **source-available** under [`LICENSE`](LICENSE) (Fouine
Source-Available Licence 1.0, held by Mathis Demory), on the Aseprite model.

**What you may do.** Read all the code, compile it, modify it for your own use,
propose a contribution. Install Fouine on the Macs you use, and keep backups.

**What you may not do.** Redistribute Fouine, as source, modified or not, or as
a binary, including one you compiled yourself; rent it, lend it, or offer it as
a service. The code is open to read. It is not free software in the FSF sense,
and that is not an oversight: the app is sold under a perpetual licence.

**Contributions.** By proposing one you grant the holder the right to use and
redistribute it under any licence (article 4, and
[`CONTRIBUTING.md`](CONTRIBUTING.md)). There is no separate agreement to sign.

**Third-party components.** GRDB.swift (MIT), swift-argument-parser (Apache-2.0)
and Sparkle (MIT) ship with the app; the `multilingual-e5-small` model is MIT,
Microsoft. Their notices are in
[`THIRD_PARTY_LICENSES.md`](THIRD_PARTY_LICENSES.md), and `fouine licenses`
prints them in a terminal. Which licence covers which part, the MCP server
included: [`LICENSING.md`](LICENSING.md).

Reporting a vulnerability goes through [`SECURITY.md`](SECURITY.md), **not** a
public issue. Release notes: [`CHANGELOG.md`](CHANGELOG.md).

---

## Documentation

Everything else is indexed in [`docs/README.md`](docs/README.md): the app guide,
the background agent, search syntax, formats, the command line, the assistant
server, privacy, permissions, updates and installation, then the documents for
whoever reads the code.
