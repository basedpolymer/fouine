# Fouine

Search inside every document on your Mac.

Fouine is a full-text search app for macOS. Point it at your folders and it
reads every document in them, page by page. Pages that carry no text layer
(scanned PDFs, comic pages, photographs pasted into a `.docx`) go through
Apple's text recognition. Type a few words: each result is a passage with its
page number, and the document opens at that page. Everything happens on your
Mac, and none of your documents, searches or usage data goes out on the
network.

![Fouine's main window. A search for "round-bottom flask" across a library of
chemistry books; the results list one page per hit, and the right-hand pane
shows page 18 of a 1921 PDF with both words highlighted in the
text.](docs/images/hero.png)

---

## Start in five minutes

1. Download the disk image from the
   [latest release](https://github.com/basedpolymer/fouine/releases/latest). The product page is
   [basedpolymer.eu/fouine](https://basedpolymer.eu/fouine).
2. Open the disk image and drag `Fouine.app` onto `Applications`, then leave it
   there. macOS files privacy permissions by path and signature, so an app that
   moves around asks for them again every time.
3. Open Fouine. Nothing is indexed until you choose a folder.
4. Click **Add a folder…**, or drop a folder into the window: a thesis, a
   library of PDFs, an archive drive.
5. Accept the macOS prompt. It appears when the folder is under Documents,
   Desktop or Downloads, or on a removable volume or a network share, and this
   is the only moment it can appear. If you refuse, the folder is not added and
   an alert offers **Open System Settings** and **Retry**. See
   [permissions](docs/permissions.md).
6. Search. Indexing starts on its own, results arrive as they are found, and
   you can search while the index is still being built.

To keep the index current without thinking about it, turn on **Keep the index
up to date automatically** under the Index card. Fouine then watches your
folders in the background, and reads scanned pages when the Mac is plugged in
and idle. See [the background agent](docs/agent.md).

Fouine needs macOS 13 or later, on Intel or Apple Silicon (universal binary).
The app follows the system language and is available in English and French,
macOS permission prompts included. The `fouine` command and the agent's log are
in English, like `git` or `brew`.

---

## What Fouine reads

PDF, EPUB, Word (including the old `.doc`), Excel, PowerPoint, ODF, RTF, Pages,
Numbers, Keynote, HTML and web archives, mail (EML, MBOX), plain text, Markdown,
CSV, LaTeX, subtitles, Jupyter notebooks, comic archives (CBZ, CBR), DjVu, and
source code. Old `.doc`, `.xls` and `.ppt` files are identified by their first
bytes, never by their extension, so a file that has lost its name is still read.
Images, audio and video are indexed too: photos go through text recognition and
recordings are transcribed, both on your Mac. Each of these has its own checkbox
in Settings ▸ Indexing, ticked by default.

The full list, family by family, with what each one needs:
[formats](docs/formats.md). The text recognised on a page with no text layer is
stored in Fouine's own database. **None of your files is ever modified.**

![A search for "name:notebook nitric acid" in a scanned PDF that carries no
text layer. The sidebar counts the page under "scanned, recognised by Fouine",
and the highlights are drawn on the image of page 27.](docs/images/ocr.png)

The search tolerates typing mistakes and recognition errors. An optional local
model also searches by meaning: "catalyst selectivity" finds a page about
*regioselectivity* that shares none of its words. That model is a 220 MB
download that only starts when you ask for it (Settings ▸ Search by meaning, or
`fouine model download`), and full-text search never needs it. See
[searching](docs/search.md).

---

## What Fouine does not do

| | |
|---|---|
| Document management | Fouine does not file, sort or rename anything. It reads your folders where they are. If you want a library with tags, notes and attachments, Fouine is not that app. |
| Syncing | There is one index per Mac. Nothing goes to a cloud, so nothing arrives from another device. |
| PDF editing | The preview is read-only. Fouine never writes into your documents, not even to add the text layer it recognised. |
| Chat | Fouine has no built-in assistant and writes no summaries. Search by meaning is a local 384-dimension embedding model and nothing more. |
| Other systems | Fouine runs on macOS 13 and later only: text recognition uses Vision, the background agent uses `SMAppService`. There is no Windows or Linux version, and there will not be one. |
| Notion and Craft | Their notes cannot be read on this Mac: Notion keeps an encrypted cache, and Craft keeps files with no readable name. Export your pages as Markdown and add the export folder. |

---

## Price, trial and key

The trial lasts 30 days and includes everything: every format, every folder,
scanned page recognition, search by meaning. You don't need a card or an
account.

After that, Fouine costs €39, paid once. Updates are free for life, one key
covers three Macs, and there is no subscription. Creem handles the sale, the
payment and VAT; the key appears after payment and arrives by email.

When the trial ends, search, preview, export, the assistant server and the
read-only command line keep working on the index you have. Only updating the
index stops, so everything you indexed stays searchable.

To enter a key, use **Fouine ▸ Enter licence key…** (Settings ▸ Licence), or
`fouine license activate <key>`. To free the Mac for another one, click
**Deactivate this Mac**, or run `fouine license deactivate`.

---

## Privacy

None of your documents, searches or usage data leaves your Mac. There is no
account and no password to create, and Fouine sends no telemetry and no crash
reports.

Fouine makes five kinds of outgoing connection. Four happen only when you click
or type something: checking for updates (off by default), downloading the
search-by-meaning model, activating a licence key and releasing a Mac. The fifth
is a licence check at launch, at most once every 30 days, and only if a key is
installed. None of them sends anything about your documents, and nothing goes
out while Fouine indexes, reads or searches.

An automated test checks that last sentence on every change to the code:
`NetworkSilenceTests` runs a local server while an indexing pass reads
deliberately booby-trapped fixtures, and fails at the first connection the
server accepts.

The index is one SQLite file, `~/Library/Application
Support/Fouine/fouine.db`. It holds the text extracted from your documents, so
it is as confidential as they are: back it up and encrypt it the same way.
Details, and how to check all of this yourself: [privacy](docs/privacy.md).

---

## Command line

`fouine` does everything the app does, plus JSON export. It ships inside the app
and works on the same index. To install it, open Settings ▸ Advanced and click
**Install the command line tool…**, which creates a symlink at
`/usr/local/bin/fouine`.

```sh
fouine root add ~/Documents/Thesis --label Thesis   # add a folder
fouine search '"ideal gas" -biology'                # exact phrase, exclusion
fouine search 'catalysis' --hybrid --json           # meaning, JSON output
```

Every command and option: [the command line](docs/cli.md).

`fouine mcp --stdio` lets an AI assistant read your index. It serves Claude
Code, Claude Desktop, Cursor, Codex or Antigravity, read-only and with no
network, through five tools to search, read a page, jump to nearby pages and
see what is indexed. The server cannot change the index, start indexing or hand
over your original files.

`fouine mcp install` configures those five clients in one command. Until you
install the command line from Settings ▸ Advanced, it lives inside the app, at
`/Applications/Fouine.app/Contents/Helpers/fouine`. On the welcome screen,
**Copy the request for your assistant** puts the whole request on the
clipboard. For Claude Desktop you can skip the command: the
`.mcpb` file attached to each
[release](https://github.com/basedpolymer/fouine/releases) installs with a
double-click. See [the assistant server](docs/mcp.md).

---

## Building from source

```sh
git clone https://github.com/basedpolymer/fouine.git
cd fouine
make release ARCHS=$(uname -m)     # Fouine.app, ad-hoc signed
```

You need Xcode (Swift 5.10 or later) and nothing else. There are three SwiftPM
dependencies: [GRDB.swift](https://github.com/groue/GRDB.swift) (MIT),
[swift-argument-parser](https://github.com/apple/swift-argument-parser)
(Apache-2.0) and [Sparkle](https://github.com/sparkle-project/Sparkle) (MIT).
Without a Developer ID certificate the signature is ad hoc, and the app runs
only on the machine that built it. See [`CONTRIBUTING.md`](CONTRIBUTING.md).

---

## Troubleshooting

| Symptom | What to do |
|---|---|
| Anything at all | Run `fouine doctor` first. It tests the *effective* read of every folder, names unmounted volumes, counts the scanned pages still to read and reports a missing djvulibre. |
| "Fouine is damaged and can't be opened" | Gatekeeper shows this for an app that is not notarised, typically one you built yourself. An official release opens without it. |
| A folder you added stays empty, with no error | Almost always a refused macOS permission. The warning banner offers **Open Settings**, and the Index card offers **Allow access…**. See [permissions](docs/permissions.md). |
| A folder under Downloads stays empty | Same cause, another checkbox: Privacy & Security ▸ Files and Folders ▸ Fouine ▸ Downloads Folder. |
| `.djvu` files are "skipped" | djvulibre is missing: `brew install djvulibre`, then index again. It is optional, like ffmpeg for a few video containers. |
| A drive is unplugged | This is not an error. Search keeps working on what is indexed, and `fouine doctor` names the missing volume. |

Trickier cases are in [`docs/pitfalls.md`](docs/pitfalls.md).

---

## Licence

Fouine is source-available under [`LICENSE`](LICENSE) (Fouine Source-Available
Licence 1.0, held by Mathis Demory), on the Aseprite model.

You may read all the code, compile it, modify it for your own use and propose a
contribution. You may install Fouine on the Macs you use, and keep backups.

You may not redistribute Fouine, as source (modified or not) or as a binary,
including one you compiled yourself. You may not rent it, lend it or offer it as
a service. The code is open to read, but it is not free software in the FSF
sense: the app is sold under a perpetual licence.

By proposing a contribution, you grant the holder the right to use and
redistribute it under any licence (article 4, and
[`CONTRIBUTING.md`](CONTRIBUTING.md)). There is no separate agreement to sign.

GRDB.swift (MIT), swift-argument-parser (Apache-2.0) and Sparkle (MIT) ship with
the app; the `multilingual-e5-small` model is MIT, from Microsoft. Their notices
are in [`THIRD_PARTY_LICENSES.md`](THIRD_PARTY_LICENSES.md), and `fouine
licenses` prints them in a terminal. Which licence covers which part, the MCP
server included: [`LICENSING.md`](LICENSING.md).

To report a vulnerability, follow [`SECURITY.md`](SECURITY.md) rather than
opening a public issue. Release notes: [`CHANGELOG.md`](CHANGELOG.md).

---

## Documentation

Everything else is listed in [`docs/README.md`](docs/README.md): the app guide,
the background agent, search syntax, formats, the command line, the assistant
server, privacy, permissions, updates and installation, then the documents for
people who read the code.
