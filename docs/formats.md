# What Fouine reads

Fouine reads over a hundred file types, and the rule is the same for all of
them: it extracts the text of a document and indexes it page by page. When a page
carries no text, Fouine reads it from the image with Apple's text recognition.
Your files are never modified.

Three families have their own checkbox in Settings, ticked by default: images,
audio and video, and the transcription of what is said in recordings. One
format needs a tool that macOS does not include: DjVu.

- [Documents and office files](#documents-and-office-files)
- [Books, comics and scans](#books-comics-and-scans)
- [Mail](#mail)
- [Web pages](#web-pages)
- [Text, notes and code](#text-notes-and-code)
- [Design files](#design-files)
- [Images](#images)
- [Audio and video](#audio-and-video)
- [What Fouine will not read](#what-fouine-will-not-read)
- [Limits](#limits)

---

## Documents and office files

| Extension | What Fouine reads |
|---|---|
| `.pdf` | the text layer, page by page. Pages without one go to text recognition, and pictures inside a page are recognised too. |
| `.docx`, `.xlsx`, `.pptx` | the text, plus the pictures embedded in the file, which go to text recognition. |
| `.odt`, `.ods`, `.odp` | the text of OpenDocument files, read the same way as their OOXML counterparts. |
| `.doc`, `.xls`, `.ppt` | the old binary Microsoft formats, fully read. The type is decided on the first bytes, so a `.doc` that is really an RTF or a `.docx` is read as what it is. Password-protected files are skipped, with a reason. |
| `.rtf`, `.rtfd` | rich text, pictures included. |
| `.pages`, `.numbers`, `.key` | the QuickLook preview Apple stores inside the document, read as pages. A document saved by a very old version of Pages may have none: open it once in Pages to generate one. |

## Books, comics and scans

| Extension | What Fouine reads |
|---|---|
| `.epub` | the text of every chapter, split into pages. |
| `.cbz`, `.cbr` | one page per image in the archive, each read by text recognition. |
| `.djvu` | one page per page of the document. It needs djvulibre: `brew install djvulibre`, then index again. Without it, the file is skipped, with a reason. |

Scanned PDFs belong here in practice. A PDF whose pages are photographs of paper
has no text layer, so every page goes to text recognition. Spotlight finds
nothing in such a file.

## Mail

| Extension | What Fouine reads |
|---|---|
| `.eml`, `.emlx`, `.olk15msgsource` | one message: headers, body, and the text of the attachments Fouine can read. |
| `.mbox` | a whole mailbox, one page per message. Apple Mail's `Name.mbox/` package works too. |

## Web pages

| Extension | What Fouine reads |
|---|---|
| `.html`, `.htm` | the text of the page, without the markup. |
| `.webarchive` | the same, from Safari's own archive format. |

Nothing is fetched from the network while these files are read. A page that
links to a remote image stays a page of text.

## Text, notes and code

| Extension | What Fouine reads |
|---|---|
| `.txt`, `.md`, `.markdown`, `.csv`, `.tsv`, `.tex`, `.json`, `.log` | the text, split into pages of readable length. |
| `.srt`, `.vtt` | subtitles, timestamps kept. |
| `.ipynb` | Jupyter notebooks: the code and the prose of each cell, without the cell outputs. |
| `.xml`, `.xsd`, `.xsl`, `.xslt`, `.plist`, `.svg` | the text the document carries, without the tags. An SVG made only of paths has none and is skipped, with a reason. |
| source files | around eighty extensions: `.swift`, `.py`, `.js`, `.ts`, `.java`, `.c`, `.cpp`, `.h`, `.rb`, `.rs`, `.go`, `.php`, `.sh`, `.css`, `.yaml`, `.toml`, `.rst`, `.adoc` and similar. Minified sources (`jquery.min.js` and the like) are skipped: nobody searches them by word, and every "word" in them pollutes fuzzy matching. |

A file that is nothing but data is skipped, with a reason. When a text document
contains a run of 2 000 characters without a single space, such as a column of
base 64 or an export dump, it has no word to search, and each of those "words"
pollutes fuzzy matching. Two kinds of file are indexed anyway. A Markdown file
that carries its pictures inline (`![curve](data:image/png;base64,…)`, as
Typora and Obsidian export it) is indexed, because those addresses do not count
in the run. A compacted JSON file is indexed too: its single long line is syntax
rather than a dump, and anything that parses as JSON is indexed whatever its
line lengths, up to 4 MB. Above that size, it counts as a dump.

Your Apple Notes and Bear notes join this family when you tick them in Settings ▸
Folders ▸ Applications. Fouine copies their text into a folder of its own and
indexes the copy. Your notes are never modified, and nothing leaves the Mac.
Notes locked with a password are skipped.

Your Anki flashcards join it the same way. Each deck becomes one document and
each card one page of it, so a result points at the card, and decks nested
inside other decks become folders. Fouine copies the text of every field, with
cloze deletions shown as their answer. The pictures of a card appear in the
preview, under its text, but the words inside them are not searched: Fouine does
not run text recognition on them. Sounds, hints, tags and field names are not
copied, and a card made of a picture alone has nothing to search. Anki can stay
open while Fouine reads it.

## Design files

| Extension | What Fouine reads |
|---|---|
| `.ai` | Illustrator files carry a PDF layer, and Fouine reads it. For a file saved without "Create PDF Compatible File", a message says so, rather than a silent failure. |
| `.sketch` | the text of every Sketch page: page names, artboard names, then each text layer. The preview becomes one more page when image indexing is on. |
| `.fig`, `.indd` | Figma and InDesign keep their text in undocumented containers, so Fouine does not read it. With image indexing on, the preview picture becomes a page to recognise. Otherwise the document is skipped, with the step that works: export as PDF, SVG or IDML. |

## Images

**Index images (photos, scans, camera RAW files)**, in Settings ▸ Indexing, is
on by default. Every image goes through text recognition, which can keep Fouine
busy for hours on a large photo library. What it finds is the text of
photographed documents: a receipt, a letter, a page. Shop signs, labels and
decorative lettering often escape it.

Nineteen extensions are read: `.png`, `.jpg`, `.jpeg`, `.heic`, `.heif`, `.tif`,
`.tiff`, `.avif`, `.webp`, `.gif`, `.bmp`, `.psd`, and the camera RAW formats
`.cr2`, `.nef`, `.raf`, `.dng`, `.arw`, `.rw2`, `.orf`. A multi-page TIFF has as
many pages as it holds.

Two thresholds keep interface graphics out of the index: files under 8 KiB, and
images whose shorter side is under 300 pixels. Both are skipped, with a reason
that names the threshold. Photos libraries (`.photoslibrary`) stay excluded.

Unticking the setting stops new images from being added; the ones already
indexed stay, with their text.

## Audio and video

**Index audio and video files (titles, artists, chapters…)**, in Settings ▸
Indexing, is on by default; untick it if a watched folder is a music library
rather than a set of documents. With it on, the title, artist, album, author,
description, comment, lyrics, date, duration and chapters of each recording
become searchable without playing a second of it.

Twelve audio extensions (`.mp3`, `.m4a`, `.m4b`, `.aac`, `.wav`, `.aiff`,
`.aif`, `.flac`, `.caf`, `.ogg`, `.oga`, `.opus`) and seven video ones (`.mp4`,
`.m4v`, `.mov`, `.avi`, `.mkv`, `.wmv`, `.webm`) are read.

Under that setting, **Also write down what is said in them**, also on by
default, transcribes speech on this Mac, with timestamps; nothing is sent
anywhere. Count roughly the length of the recording, and install the dictation
language in System Settings ▸ Keyboard ▸ Dictation. Otherwise the file is
skipped with a message that names what is missing. One page is ten minutes of
recording, each paragraph headed by its `[mm:ss]` timestamp. A limit (120
minutes by default) caps the effort; beyond it, only the tags are indexed.

The `.mkv`, `.avi`, `.wmv`, `.webm` and `.ogg` containers go through ffmpeg when
it is installed (Homebrew or MacPorts). Without it, those files are skipped with
`ffmpeg is missing`, and the next pass picks them up as soon as the tool is
there.

## What Fouine will not read

- Notion and Craft: Notion keeps an encrypted cache, and Craft keeps files with
  no readable name. Export your pages as Markdown or HTML and add the export
  folder; a Notion page found that way reopens in Notion.
- Encrypted or password-protected documents: a locked PDF, workbook or
  presentation is skipped, with a reason. Fouine does not ask for the password
  and does not try to guess it.
- File names: Fouine indexes the text of pages, not names, so a document with no
  readable page never appears in a text search. Names have their own filter,
  `name:` (see [searching](search.md)).

Every document Fouine could not read is listed, with the reason, in the
**Documents Fouine could not read** window, in `fouine status --unreadable` and
in `fouine list --state failed --state skipped`.

## Excluding a folder or a file type: `.fouineignore`

Some folders don't belong in an index at all (health records, passwords,
accounts), and some files only get in the way. The `INDEX.md` a tool generated,
for example, ranks above the lecture it lists, because it repeats every word of
it.

These rules can live in two places, and Fouine applies both together:

- in the app, under **Settings ▸ Folders ▸ What Fouine skips…**, or with `fouine
  root ignore add` in a terminal. Fouine keeps these rules in its own index and
  writes nothing into your folder. They go away with the folder when you remove
  it from Fouine;
- in a file named `.fouineignore` that you put at the top of an indexed folder
  yourself, one rule per line. The file travels with the folder (a shared
  folder, a backup, a copy on another Mac), and Fouine only ever reads it.

The rules are the same in both places, and so is their effect. Both are read at
the start of every pass, so a rule added today applies tonight, with nothing to
restart. A rule written in both places counts once.

```
# What Fouine must not see
Santé/
Comptes_et_Codes/
*.md
INDEX.md
```

A rule takes one of three forms:

| Rule | What it covers |
|---|---|
| `Santé/`, `Cours/Archives/` | that folder and everything under it, from the top of the root. The path is the one you see in the Finder. |
| `Cours/INDEX.md` | exactly that file (or that folder), at that place. |
| `*.md`, `INDEX.md`, `*draft*` | a name, anywhere under the root: a pattern with `*` and `?`, and no `/`. |

Case and accents are ignored, as they are on the disk: `Santé/` covers `sante/`
and `SANTÉ/`. Lines starting with `#` are comments, blank lines are ignored, and
a leading `/` is accepted (`/Santé/` and `Santé/` are the same rule). Negation
(`!file`) is not supported: the line is dropped, with a warning in the log.

A document already indexed that becomes excluded leaves the index at the next
pass, with its pages, its recognised text and its meaning vectors. Its content
no longer comes back in searches, in the app or through the assistant server.
Remove the rule, and the document comes back at the pass after that: an
exclusion never touches your files.

There is one file per root, at its top, never deeper, so the answer to "what is
excluded from this folder?" is always in one file. The sheet in the app lists
that file's rules too, greyed out, next to its own. `fouine root list` shows how
many rules each root has and where they come from; `fouine root ignore list
<root>` lists them.

A rule typed into the app or into `fouine root ignore add` is checked before it
is kept: a negation, a line starting with `#`, several lines or a path with `..`
are refused, with a message. The file, by contrast, can only warn about them in
the log.

To let an assistant read only part of the index without excluding anything,
see `fouine mcp --folders` in [the assistant server](mcp.md).

## Limits

| | |
|---|---|
| One file | 2 GiB. Beyond that it is skipped. |
| Formats whose pages Fouine cuts itself (text, mail, office) | 5 000 pages per document. A PDF, a DjVu or a comic archive has the pages the file has. |
| One page | the text of the page, whatever its length. |
