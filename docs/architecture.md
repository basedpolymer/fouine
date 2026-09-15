# Architecture

How a file becomes a searchable page, what extracts it, where the result is
stored, and what it costs.

- [1. The path of a document](#1-the-path-of-a-document)
- [2. What is extracted, and by what](#2-what-is-extracted-and-by-what)
- [3. OCR](#3-ocr)
- [4. The SQLite schema](#4-the-sqlite-schema)
- [5. Where the data lives](#5-where-the-data-lives)
- [6. Bundle layout](#6-bundle-layout)
- [7. Repository layout and SwiftPM targets](#7-repository-layout-and-swiftpm-targets)
- [8. Orders of magnitude](#8-orders-of-magnitude)
- [9. Spotlight](#9-spotlight)
- [10. Shortcuts (App Intents)](#10-shortcuts-app-intents)
- [11. Application sources: Apple Notes, Bear, Anki](#11-application-sources-apple-notes-bear-anki)
- [12. The MCP server](#12-the-mcp-server)

---

## 1. The path of a document

```
  roots (the folders the user added)
        │
        │  crawl            FouineCrawl: delta or full walk, exclusions
        │                   (.DS_Store, .git, .Spotlight-V100, ._*, .pages/.key…)
        ▼
   docs table              one row per file: volume + rel_path, inode, size,
        │                  mtime, state (discovered/extracted/failed/skipped)
        │
        │  extract          FouineExtract: one extractor per format family,
        │                   text split into PAGES
        ▼
   page_fts (FTS5)  ◄──────────────────────────────┐   rowid = doc_id·100000 + page
        │                                           │   unicode61 remove_diacritics 2
        │  pages under 100 useful characters        │
        ▼                                           │
   ocr_queue  ──►  Vision OCR .accurate  ──►  page_src + ocr_layout + page_fts
                   (150 dpi grayscale render)       │   text, zlib geometry,
                                                    │   confidence, engine
   vocab_tri (FTS5 trigram) ◄── vocabulary ─────────┘
        │
        ▼
   search: exact (FTS5) + fuzzy (trigrams then Levenshtein)
           + semantic (page_vec, windows, RRF fusion)
        │
        ├──►  Fouine.app     three-column window, highlighted PDF preview
        └──►  fouine search  text or JSON
```

Seven decisions explain most of the observable behaviour.

**The unit is the page.** The `page_fts` rowid is `doc_id × 100000 + page`,
which caps a document at 99 999 pages. Grouping by document is presentation
only: a document scores as the sum of its five best pages.

**Writes take an exclusive lock, reads never do.** One process indexes at a
time, and the lock is released at every resting point (end of pass, end of an
OCR or embedding batch), so search answers while indexing runs. This is the
first entry in [`pitfalls.md`](pitfalls.md).

**Document language is decided on the text, and caught up later.** `docs.lang`
is written at extraction. For a scanned document, whose text arrives with the
OCR, `completeOCR` resets `docs.lang` to NULL when it held `und`, so the
language is decided again at the end of the OCR pass. Documents with no
language are retried at the end of a pass, 300 at most, read from `page_fts`
without re-extracting anything. A document whose language cannot be decided
gets the `und` token rather than nothing, otherwise it would be re-read on
every pass, and the Language facet counts `und` and absent as one value.
`fouine maintain --detect-languages` catches up what has no language;
`--redetect-languages` replays every document, which is the only way to recover
an index built before a fix to the detector.

**The language sample is three slices that vote**, never the top of the
document: the opening of a real document is rarely prose (Gutenberg preamble,
publisher front matter, mail headers, scan noise). Three slices of 1 333
characters are taken near 10 %, 50 % and 90 % of the material, each on a word
boundary; the majority wins and a tie decides nothing. Offsets are computed
from page lengths, so only the pages crossed are read, and RFC 822 headers in
the first forty lines are stripped first. Measured on a copy of the real index
(1 504 documents, 26,6 s): `en` 602 to 798, `und` 246 to 127, improbable
languages 62 to 32, against 63 documents moving from a language to `und`.

**An extraction cancels between two pages, or between two speech windows.**
`ExtractLimits.shouldStop` runs from the pass down into the extractors, which
read it once per page, and into the transcriber, which reads it between windows
and during one. An extractor that sees it true throws `FouineError.cancelled`,
the only case that leaves its document unmarked: it stays `.discovered` and the
next pass starts it over. Without this, Stop waited for the reads in flight, up
to `extract.jobs` documents, and a transcribed video is counted in minutes.
Measured: 99 s of speech, stop asked at 2 s, returned at 2,1 s.

**Paths are stored in one Unicode form: NFC.** «é» is written U+00E9 or
U+0065 U+0301; both display the same, Swift's `String` treats them as equal,
and SQLite, which compares bytes, does not. A decomposed path in the index was
found neither by `docID(volUUID:relPath:)`, nor by the root filter, nor by
`--only`, and said nothing. Every `rel_path` goes through `RelPath.normalized`
on the way in: crawler, `root add`, and every lookup by path.

**Renaming or moving a file costs nothing.** `docs.inode` holds the volume's
file identifier. In a delta crawl, a path that disappeared and a path that
appeared carrying the same inode, size and mtime are the same file: the `docs`
row changes `rel_path` and nothing else moves, since `page_fts`, `page_src`,
`ocr_layout`, `ocr_queue` and `page_vec` are keyed by `doc_id`. A folder of a
thousand documents moves in one transaction. Before that, a plain `mv` was a
deletion followed by a rediscovery, destroying hours of OCR and vectorisation.

**OCR is non-destructive.** Nothing is ever written into the user's files, and
the highlights in the PDF preview are `PDFAnnotation` objects added in memory.

**Off is never gone.** The crawl's extension list is rebuilt from the settings
at every pass, so a pass run without `extract.images` no longer sees the `.png`
files in the folder. It used to take them for deleted files and remove them
with their OCR: 16 images and 12 OCR pages, 24,5 s of Vision, erased by a
single `fouine index`. The deletion pass now removes only what has an extension
in the current list. `fouine config set extract.images false` therefore removes
nothing; it only stops adding. Removal belongs to `root remove --purge` or to a
file that really disappeared from a category that is on.

## 2. What is extracted, and by what

| Extensions | Tool | Notes |
|---|---|---|
| `pdf` | PDFKit | `PDFDocument` reopened every 100 pages (memory) |
| `txt` `md` `csv` `tsv` `tex` `json` `log` | direct read | BOM (UTF-16 LE/BE, UTF-8), then the encoding named by the `com.apple.TextEncoding` extended attribute, then UTF-8, Windows-1252, ISO-8859-1, MacRoman, each fallback under a plausibility check. A run of 2 000 characters without a space in the head sample gives `skipped`, `err = "no readable text: <n>-character run without a space — data dump?"` — except when the file parses as JSON (up to 4 MB: a compacted export is a syntax, not a dump), and `data:` addresses do not count in the run (a Markdown file carrying its pictures inline) |
| `doc` `rtf` `rtfd` | `NSAttributedString` | plausibility check (rejects mojibake) |
| `docx` `odt` `ods` `odp` `xlsx` `pptx` | `/usr/bin/bsdtar` + XML parser | embedded media become OCR pages; DOCX footnotes and endnotes indexed after the body; `xlsx` indexes both forms of a cell (below) |
| `html` `htm` `webarchive` | in-house HTML parser | `.webarchive` is a binary plist. The target of an `http://`, `https://`, `mailto:` or `doi:` link is kept after its text; the target alone for a link without text, nothing when the text repeats it. Anchors, relative paths and `javascript:` are dropped. Also used for EPUB XHTML and HTML mail bodies |
| `eml` `emlx` `olk15MsgSource` | RFC 822 / MIME parser | From, To, Date, Subject, `text/plain` body or `text/html` fallback, then the attachments as extra pages (below) |
| `mbox` (file or `Name.mbox/` package) | split on the «From» line | one page per message; a quoted `>From ` is not a boundary. Attachments are not read here |
| `epub` | `bsdtar` | spine order from `META-INF/container.xml` |
| `cbz` `cbr` | `bsdtar` (libarchive reads ZIP and RAR) | no text: every page goes to OCR |
| `djvu` | `djvutxt` / `djvused` | missing tool gives `skipped`, `err = "djvu: djvulibre is missing"` |
| `srt` `vtt` | subtitle parser | cues only: timestamps, numbers, tags and consecutive duplicates dropped |
| `ipynb` | notebook JSON parser | markdown, code and raw cells in order; outputs ignored |
| `xls` | in-house OLE + BIFF5/BIFF8 reader | one page per sheet; shared strings, `LABEL`, `NUMBER`, `RK`, `MULRK`, text result of `FORMULA`. Encrypted gives `skipped`, `err = "password-protected workbook"` |
| `ppt` | in-house OLE + PPT record reader | one page per slide, presenter notes attached to their slide. Encrypted gives `skipped`. Images in the `Pictures` stream do not go to OCR |
| `xml` `xsd` `xsl` `xslt` `svg` `plist` | `XMLParser` in SAX mode | node text, attributes ignored; falls back to raw text when malformed; `plist` rendered as «key: value». No text gives `skipped` |
| 68 source and configuration extensions (`py` `js` `ts` `swift` `rb` `go` `rs` `sh` `sql` `css` `yaml` `toml` …) | direct read | as plain text. Minified source (`.min.js`, `.min.css`, or mean line over 1 000 characters) gives `skipped` |
| `pages` `numbers` `key` | `QuickLook/Preview.pdf` then PDFKit | package directory or ZIP. No preview gives `failed`, and the reason says to open the file once in Pages |
| `ai` | «%PDF-» sniff then PDFKit | an `.ai` saved «PDF compatible» is a PDF; the `%!PS-Adobe` header that sometimes precedes it is skipped through a temporary copy |
| `sketch` | `bsdtar` + JSON | one Sketch page is one page: page name, artboard names, text layers. `previews/preview.png` becomes a final OCR page under `extract.images` |
| twelve sound and seven video extensions (`mp3` `m4a` `wav` `flac` `opus` `mp4` `mov` `mkv` `webm` …) | AVFoundation, ffmpeg for foreign containers, Speech for the words | under `extract.media` only. Page 1 is the metadata, then one page per ten-minute window under `extract.transcribe` |
| nineteen image extensions (`png` `jpg` `heic` `tiff` `avif` `webp` `psd`, RAW…) | ImageIO render then Vision | under `extract.images` only. Zero native characters, one page per image, queued for OCR |
| `fig` `indd` | preview image only | the Figma canvas (binary «kiwi») and InDesign text are never parsed. Under `extract.images`, one OCR page from the embedded preview; otherwise `skipped`, and the reason names the export to run |

**A mail attachment becomes a page of the mail.** An invoice received by mail
is often the only copy there is, so indexing the header and the body without
the attachment keeps only the pleasantries. An `.eml` decodes each part
(base64, quoted-printable, 7/8bit), drops it in a temporary folder of its own
(name cleaned: no `/`, no `..`, no control character, 120 bytes at most,
extension kept), hands it to the extractor registry, and adds its pages after
the body, each starting with the file name alone on its line. The temporary
folder disappears in a `defer`, and an unreadable attachment does not fail the
mail: it is named in `meta.attachments_skipped`, along with the parts left out
on purpose (archives, sound, video, images, anything past ten attachments or
past `maxFileBytes`, and the attachments of an attached mail, which is read
in-process, one level deep). Attachment pages use an OCR threshold of **zero**:
the 100-character threshold leaves a thin page to OCR, and an attachment has no
OCR, so leaving it would lose it.

**A spreadsheet is indexed the way it is read.** The cell that displays
«05/01/2026» contains `46027`, the one that displays «1 512,50 €» contains
`1512.5`, and indexing the stored value alone meant that searching for a date
or an amount found nothing. `SpreadsheetFormat` reads `xl/styles.xml` and
`workbookPr date1904`, and `WorksheetParser` indexes both forms, rendered then
raw, separated by a space. Two families only, date/time and decimal; the
rendering is hard-coded French (dd/mm/yyyy, decimal comma) rather than the
system locale, so `page_fts` survives a change of regional settings.
`.numbers`, `.xls` and `.ods` do not go through this parser.

**Words hyphenated at end of line are rejoined.** A typeset document is
justified, therefore hyphenated: the French tax notice 2042 carries
`dispen-\nser` and 564 other breaks over 41 351 words, and as many unfindable
words. `Dehyphenation.rejoin` adds the joined form after the second fragment
and keeps the broken one, so there is nothing to arbitrate between a
hyphenation and a compound; lower case is required on both sides, so a date
range, an acronym or a dialogue dash is never rejoined. Measured on that
notice: 263 959 to 270 267 indexed characters (+2,4 %).

**Two floors keep thumbnails out of OCR**, with two distinct reasons: a file
under **8 KiB** gives `err = "image file below the OCR weight floor: N bytes"`,
a side under **300 px** gives `err = "image below the OCR size floor: WxH px"`.
Both are `skipped`, never failures. The weight floor used to be 64 KiB and
rejected whole A4 pages as soon as they compressed well; a byte count is not an
amount of information, and the dimension floor does the real work. A
multi-page TIFF is worth all of its images (`pageCount =
CGImageSourceGetCount`), which is the normal output of an office scanner; an
animated GIF is worth its first image; a RAW file is not developed, its
embedded thumbnail is rendered at 4 096 px, which Vision is happy with.

**Media come in two stages, and only the first is free.** Metadata (title,
artist, album, description, chapters, duration) is always read by AVFoundation
and forms page 1, provenance `native`, as «Title: …» lines, for the cost of a
few milliseconds. Transcription (`extract.transcribe`, off) writes the speech
down **on the machine**: `SFSpeechRecognizer` with `requiresOnDeviceRecognition
= true`, the flag that makes the request FAIL rather than travel to Apple.
Audio is read as a stream, nothing is written to disk, and each ten-minute
window becomes one page of provenance `transcript`, in paragraphs of about 40 s
preceded by their `[mm:ss]` timestamp. Past `transcribe.max_minutes` (120) only
the metadata is kept. Cost on an i5: about the duration of the recording.

Three things about that path are easy to break. Transcription is **serialised**
by a semaphore of 1, because `SFSpeechRecognizer` serves one at a time and
returns an EMPTY result to the others with no error: at `extract.jobs = 4`,
three recordings out of four from a dictaphone folder were lost in silence,
with a success line. Chunks are **accumulated**: on macOS 15 the recogniser
returns a window in pieces of about a minute, each marked as an end of
utterance, and only the last carries `isFinal`, so keeping the final one alone
put the last minute of every ten-minute window into the index. And a change of
setting triggers a **re-read**: `IndexPass` compares
`meta.transcription_revision` with the setting and, when they differ, puts the
affected media back to `discovered` in one transaction before writing the new
mark, so unticking and re-ticking the box transcribes everything once more.
Refusals are named and all `skipped` (`no metadata`, `no metadata (no audio
track)`, `no metadata (no speech)`, no dictation language installed, no TCC
authorisation); when metadata is there, the refusal goes into `docs.meta`
instead of dropping the document.

Containers AVFoundation will not open (`mkv` `avi` `wmv` `webm` `ogg` `oga`
`opus`) go through **ffmpeg** when it is installed. Without it the document is
`skipped` on a token reason, `err = "mkv: ffmpeg is missing
(missing-tool:ffmpeg)"`, which the crawl re-reads so it can revisit the refusal
the day the tool appears, exactly like djvulibre. Both invocations set
`-protocol_whitelist file` **before** `-i`: an `.mkv` that is in fact an HLS
playlist carries an `http://` address, and without that bound ffmpeg decides
for itself whether to open it. Two fixtures in `NetworkSilenceTests` hold that.

**What is not read, and why.** The Figma canvas is a compressed «kiwi» format,
neither published nor stable between versions. InDesign text is a proprietary
container for which Adobe offers IDML as the reading path, and that is another
file, which only the user can export. An Illustrator 8 `.ai` is pure
PostScript, with no PDF layer. In all three cases the refusal names the
gesture; it does not make the document findable, since Fouine does not index
file names.

Two external binaries only, always reading to `stdout`: `/usr/bin/bsdtar`,
present on every macOS, and djvulibre, optional. Their environment is fixed
(`PATH=/usr/bin:/bin:/usr/sbin:/sbin`, `LANG=LC_ALL=C.UTF-8`) rather than
inherited, and entry names read from an archive are always separated from the
options by `--`. djvulibre is looked up by explicit paths (`/opt/homebrew/bin`,
`/usr/local/bin`, `/opt/local/bin`, then `FOUINE_DJVUSED`) because an
application launched from the Finder and a launchd agent both have a minimal
`PATH` where Homebrew does not appear.

Letting source code in would let whole project trees in. A `dist`, `build`,
`out`, `target`, `.next`, `coverage`, `vendor`, `node_modules`,
`site-packages` or `__snapshots__` folder is therefore excluded **under a
software project**, meaning a folder carrying `package.json`, `Cargo.toml`,
`pyproject.toml`, `go.mod`, `Package.swift`, `Gemfile` or `.git`, and only
there: `~/Documents/House/build` is an ordinary folder of documents.

**Extraction limits**: 2 GiB per file, 50 MiB of text per document, 4 000
characters per page for unpaginated formats, **5 000 pages** at most for those
same formats (`ExtractLimits.maxSplitPages`), and **under 100 useful characters
on a page means queued for OCR**. The page ceiling is what text alone did not
provide: an 80 KiB `.docx` whose body is 80 MiB of «A» produced 13 108 pages of
noise, and as many identical vector windows. It applies only to the formats
Fouine re-paginates itself; PDF, DjVu, comics, images and media have the
schema's ceiling (`Schema.maxPage`). Past it, pages 1 to 5 000 are kept and
`docs.meta` carries `truncated = "pages beyond 5000 dropped (N pages)"`.

The cut of a fabricated page falls on a paragraph boundary, otherwise a line,
otherwise a word, and hard only when the chunk holds no whitespace at all. The
end of line is found with `Character.isNewline`: in a CRLF file, and *War and
Peace* from Project Gutenberg is one, `\r\n` is ONE Swift character that a
search for «\n\n» did not see, and all 806 cuts of the book fell mid-word.

## 3. OCR

One pass, in `.accurate` (the `.fast` mode was removed: 90,5 % recall against
19,9 %). Page rendered in greyscale at **150 dpi**, capped at about 4 Mpx.
Vision revision 3, languages `fr-FR` and `en-US`, language correction on. Lines
below **0.30** confidence are excluded from the index but kept in `ocr_layout`,
so the preview can still show them.

A thermal governor reads `CPU_Speed_Limit` (`pmset -g therm`) every 30 s rather
than `thermalState`, which stays at `.fair` while the machine throttles to
46 %: below 70 % concurrency drops to 2, below 50 % on two consecutive readings
OCR suspends until it returns to 50 %.

**Nothing waits forever.** Every call that may not return carries a deadline:
external tools (`bsdtar`, `djvused`, `pmset`) through `Subprocess`, which kills
its child; framework calls (`VNImageRequestHandler.perform`,
`PDFDocument(url:)`, `PDFPage.string`, `PDFPage.draw`) through `Deadline`,
which runs them on a dedicated thread and returns on time. An OCR timeout puts
the page back in the queue with one more attempt; an extraction timeout drops
the document to `failed` with its reason in `docs.err`, and the pass continues.
The deadlines are deliberately wide (120 s for a Vision page that measures 2 to
4 s): they catch real hangs only.

## 4. The SQLite schema

Version **9** (`Schema.version`), written in `meta.schema_version`. It is the
only version the binary creates, and the **only one it opens**. The schema is
laid down in one go at creation by `GRDBStore.createSchema`, in one transaction
and under the named lock; a base already at the right version opens without
taking any lock, which is the case for every read.

**There is no migration chain.** Fouine was never distributed, and a recovery
path that no real index exercises is a risk with nothing on the other side.
Three cases on opening, and three only:

- no `meta.schema_version`, so the base is absent or empty: it is **created**
  at the current schema, under the named lock, in one transaction;
- `schema_version` equal to the current version: it **opens**, without a lock;
- any other value: it is **refused**, untouched. Older, the message carries the
  gesture *delete it and index again*; newer, *update the fouine binary*.

`GRDBStore.schemaMismatch` is the only place those two sentences are written,
so the core, the CLI, the MCP server and the application's failure screen all
say the same thing, read-write and read-only alike. The consequence, to weigh
before touching the schema: changing `Schema.version` makes the existing index
unreadable and forces the user to build it again. That is decided, not slipped
into a batch of work.

| Table | Role |
|---|---|
| `meta` | schema version and persistent settings |
| `volumes`, `roots` | volumes by UUID, roots by `vol_uuid + rel_path`; an unplugged disk does not lose its index. `roots.ignore_rules` keeps the exclusion rules saved in the app or by `fouine root ignore` (see below) |
| `docs` | one row per file: state, size, mtime, `inode` (volume file identifier, 0 when unknown), `doc_date`, error reason (`err`) |
| `page_fts` | FTS5 `unicode61 remove_diacritics 2`, structured rowid |
| `docs_fts` | FTS5 of the document name and its folder name, `rowid = docs.id`: one row per document, never per page, because copying the name onto 378 000 pages would dilute the `bm25` IDF until it carried no weight |
| `page_src` | provenance and confidence of each page (native text, Vision OCR, imported OCR) |
| `ocr_queue` | OCR queue, priority, attempt counter, shortest-remaining-first ordering |
| `ocr_layout` | geometry of recognised lines, zlib-compressed; this is what allows highlighting on a scanned page |
| `vocab_tri`, `vocab_seen` | FTS5 trigram vocabulary for fuzzy expansion, and what has already been poured into it |
| `page_vec`, `vec_meta` | 384-byte semantic vectors per page window, rowid `page * 8 + chunk`, plus the model that produced them and the windowing geometry |
| `settings` | the eleven typed settings, read by the three executables; environment variables still win |
| `agent_status` | what the background agent publishes: phase, current document, done/total, timestamp, pid |

**Where the exclusion rules live.** Two sources, applied together by the crawl
(`IgnoreRules.load(root:stored:)`, FouineCrawl), compiled by the same code:

- `roots.ignore_rules`, a JSON array of rule texts (`["Santé/","*.md"]`) or
  NULL, written by the app's **What Fouine skips…** sheet and by `fouine root
  ignore add|remove`. The column is part of `Schema.ddl`; a v9 index created
  before it receives it through `ALTER TABLE roots ADD COLUMN` at the **first
  rule saved**, not at opening, so `schema_version` stays 9, opening an index
  still writes nothing, and read-only openings (MCP, `search`, `status`) read
  both shapes. The write takes no `fouine.lock`, like `settings`: no pass writes
  the column, and the agent may hold that lock for a whole OCR batch;
- the `.fouineignore` file at the top of the root, which Fouine only reads.

The app never writes into a watched folder. A kept rule leaves with its root
(`root remove --purge` deletes the row); the file travels with the folder. The
agent compares the kept rules of every root at each tick and walks those that
changed, since saving one raises no FSEvents burst.

There is **no secondary index on `page_fts`**: every access goes through the
structured rowid, purging a document included (by rowid range, measured at
143 ms in a full scan against 3 ms by range). There is no prefix index either:
`prefix='2 3'` cost +480 MB and was removed, hence the floor of four letters
before `*` in a query.

### The document date, and the file date

`docs.mtime` dates the **file**. It answers beside the point: copying a book
from 2003 onto the Mac in 2024 files it under 2024. `docs.doc_date` holds the
date the **document** carries itself, read from its metadata at extraction,
with no extra read: PDF `CreationDate` (never the modification date, which
would be `mtime` under another name), the first `<dc:date>` of an EPUB OPF,
`dcterms:created` for docx/xlsx/pptx, `meta:creation-date` for odt/ods/odp,
EXIF `DateTimeOriginal` for images, the `Date:` header for mail. The date
written in a file NAME is not metadata and is not read; formats that date
nothing (`.txt`, `.md`, `.html`, `.djvu`, `.cbz`) leave the column empty.

The value is a **civil day at noon UTC** (`DocumentDate`), never an instant: a
document date has no time and no zone, and `strftime('%Y', doc_date,
'unixepoch')`, without `'localtime'` unlike the `mtime` facet, then yields the
same year everywhere. Anything before 2 January 1900 or after tomorrow is
refused: `D:19000101000000` is the filler value of PDF producers, and years
like 2099 come from wrong clocks. An ambiguous string («12/04/2003») is not
parsed, since nothing says whether it is 12 April or 4 December. Measured on a
copy of the production index: 1 299 dated documents out of 1 516, 32 distinct
years (1915 to 2026), where the `mtime` facet showed 5.

### The `fouine://` deep link

A page that has been found is quotable, and the link that quotes it is the
`DeepLink` type (`Sources/FouineCore/DeepLink.swift`): pure, dependency-free,
in the core because three surfaces write it (the application, `fouine search
--json`, the MCP server) and one reads it. Two copies of a URL grammar always
diverge by one escaping character.

| Form | Emitted when | What it is worth |
|---|---|---|
| `fouine://open?path=<absolute>&page=<n>[&q=…]` | the document's volume is mounted | survives reindexing, a restored base, a change of machine |
| `fouine://open?doc=<id>&page=<n>[&q=…]` | the volume is not mounted | `docs.id` is a rowid, reassigned by an index built from scratch: the link is worth only this machine and this index |
| `fouine://search?q=…` | always available | replays a search in the window |

`DeepLink.link(absolutePath:docID:page:)` is the single point of that
arbitration. Value encoding removes `& = + # ? %` from the allowed set: a real
corpus path contains some, and `urlQueryAllowed` would let them through, after
which the link reads back as two parameters, or as nothing.
`GRDBStore.docID(forAbsolutePath:)` retraces the exact route of indexing
(`VolumeResolver.resolve` by longest mount-point prefix, NFC normalisation,
then one probe on `(vol_uuid, rel_path)`); comparing raw strings would fail on
a decomposed `é`, on a symbolic link, and on a volume mounted elsewhere. The
application declares the scheme in `Packaging/Info.plist`, and `DeepLinkRouter`
(pure, two closures, five actions) decides what to do. A link received before
the base is open waits in `DeepLinkQueue`.

## 5. Where the data lives

| | Path | Override |
|---|---|---|
| Index | `~/Library/Application Support/Fouine/fouine.db` (+ `-wal`, `-shm`) | `FOUINE_DB` |
| Write lock | `~/Library/Application Support/Fouine/fouine.lock` | follows `FOUINE_DB` |
| Campaign lock | `~/Library/Application Support/Fouine/fouine-embed.lock` | follows `FOUINE_DB` |
| Licence file | `~/Library/Application Support/Fouine/license.json` | follows `FOUINE_DB` |
| Semantic model | `~/Library/Application Support/Fouine/models/e5-small` | `FOUINE_MODEL_DIR` (source: `FOUINE_MODEL_URL`) |
| Agent log | `~/Library/Logs/Fouine/fouine.log` (rotates at 10 MiB to `.log.1`) | `FOUINE_AGENT_LOG` |
| Preferences | `~/Library/Preferences/io.github.basedpolymer.fouine.plist` | — |
| LaunchAgent | `Fouine.app/Contents/Library/LaunchAgents/…agent.plist` | — |

The LaunchAgent plist is never dropped into `~/Library/LaunchAgents`: it stays
in the bundle, and `SMAppService.agent(plistName:)` loads it.

**Two locks, for two different jobs.** `fouine.lock` protects writes, and is
taken and released at every batch, vectorisation included, so the application
can index during a twenty-hour campaign. That is also why nothing stopped two
`fouine embed` runs from working on the same base and redoing the same work.
`fouine-embed.lock` answers that question: held with `flock(LOCK_EX|LOCK_NB)`
for the life of the process, carrying «pid N since <ISO 8601>», it makes a
second start exit with 3 naming the first. `fouine status` turns it into the
`semantic_campaign` key. It protects no write, and the kernel releases it when
the process dies.

The bundle identifier is `io.github.basedpolymer.fouine`, and it does not
change: macOS authorisations and the agent's registration are keyed by it.

## 6. Bundle layout

```
Fouine.app/Contents/
  Info.plist                                   authorisation prompt strings
  MacOS/Fouine                                 the SwiftUI application
  MacOS/FouineAgent                            the background agent, no interface
  Helpers/fouine                               the command line, signed with the app
  Resources/Fouine.icns
  Resources/Metadata.appintents                the Shortcuts actions (§ 10)
  Library/LaunchAgents/…agent.plist            loaded by SMAppService
```

The CLI lives in `Contents/Helpers/` rather than `Contents/MacOS/`: a Mac disk
is case-insensitive, and `fouine` there would name `Fouine`, the application
executable. The menu item **Fouine ▸ Install the command line tool…** makes a
symbolic link in `/usr/local/bin`. The bundle uses the hardened runtime,
without the sandbox, and its entitlements dictionary is deliberately empty (see
[`privacy.md`](privacy.md)).

## 7. Repository layout and SwiftPM targets

```
Sources/FouineCore/     SQLite schema, GRDB store, queries, fuzzy (trigrams + Levenshtein)
Sources/FouineCrawl/    root walking, exclusions, root policy, FSEvents
Sources/FouineExtract/  one extractor per format family, bsdtar/HTML/XML helpers
Sources/FouineIndex/    the shared indexing pass, Spotlight donation, app sources
Sources/FouineOCR/      page rendering, Vision engine, thermal governor, OCR loop
Sources/FouineEmbed/    e5-small CoreML model, tokenizer, vectorisation campaign,
                        model download (the only URLSession under Sources/)
Sources/FouineLicense/  30-day trial, licence file, five states, monthly check, relay client
Sources/FouineMCPKit/   MCP framing, JSON-RPC, router, budgets (MIT, no dependency)
Sources/FouineMCP/      the MCP server itself: read-only store and tools
Sources/fouine/         swift-argument-parser CLI (see cli.md)
Sources/FouineApp/      SwiftUI app: App/, Model/, Views/, Intents/
Sources/FouineAgent/    headless launchd agent: conditions, pipeline, log
Tests/                  unit tests per module, plus Tests/Integration (the recipe)
Packaging/              bundle.sh, dmg.sh, notarize.sh, Info.plist, entitlements, INSTALL.md
Tools/                  convert_e5.py, package_model.sh, the l10n scripts, the ranking bench
docs/                   this documentation
.github/workflows/      ci.yml (tests and packaging) and release.yml (tag v*)
SPEC.md                 the implementation contract
```

Two targets deserve a note.

**`FouineMCPKit` has no dependency**, not even on `FouineCore`. That is what
makes its MIT licence real rather than decorative, and one line of
`Package.swift` would undo it. See [`../LICENSING.md`](../LICENSING.md).

**`FouineLicense` depends on Foundation alone.** The verdict «may the index
update?» is taken by all three executables, and the agent must be able to take
it at every wake-up without opening the base. `license.json` is derived from
`databaseURL.deletingLastPathComponent()`, so `FOUINE_DB` isolates it and no
test can write into the owner's real folder. Writing is atomic (temporary file
then `replaceItemAt`, mode `0600`); an unreadable file counts as absent and the
trial starts again. Only indexing depends on the verdict: search, preview,
export, the MCP server and every read command work in all five states. What a
monthly check changes to the file is decided once, in `LicenseCheck`, for the
two callers that run it: the app at launch and `fouine license status`.

**Where a shared sentence lives.** A phrase or a predicate that two surfaces
publish belongs to the module that owns the *fact*, never to the surfaces: the
scope predicate "does this query narrow the set of documents?" is
`SearchQuery.filtersDocuments` (FouineCore), and the sentence "no vectorised
page in this scope…" is `SemanticDisarmReason.noVectorsInScopeNote`
(FouineEmbed). The command line and the MCP server call them. Both had been
copied word for word between `Sources/fouine` and `Sources/FouineMCP` for a
day, which is how two surfaces end up publishing two different figures for the
same search.

Convention: views in `Sources/FouineApp/Views/` carry stable, hierarchical
`accessibilityIdentifier` values (`search.field`, `sidebar.root.<id>`,
`facet.<key>.<value>`, `results.hit.<doc>.<page>`, `preview.text`) for future
interface tests, and spoken labels live as pure functions in
`Views/AccessibilityText.swift`. `Fouine.app`, `dist/` and `.build/` are build
outputs and are not committed. The icon is copied into the bundle by
`bundle.sh` before signing, since it is a sealed resource.

Building, testing, publishing: [`../CONTRIBUTING.md`](../CONTRIBUTING.md) and
[`../RELEASING.md`](../RELEASING.md).

## 8. Orders of magnitude

Measured on one machine and one corpus, so they are orders of magnitude and
nothing more:

> MacBook Pro 16,3, Intel Core i5-8257U at 1,40 GHz, 4 cores / 8 threads,
> 8 GiB of RAM, an index of 1 527 documents and 408 951 pages.

| Quantity | Measure |
|---|---:|
| `fouine search energie --limit 50` | **317 ms** (110 ms with `--no-morphology`) |
| `fouine search metal` (46 000 matching pages) | **522 ms** |
| `fouine search 'energie libre' --hybrid` | **1 792 ms** |
| `fouine status` | **673 ms** |
| `fouine doctor` | **696 ms** |
| fixed cost of one process (`fouine --version`) | 49 ms |
| PDFKit extraction, 1 thread | **77,9 pages/s** aggregate (41 to 183 per book) |
| rendering one page for OCR | median **0,073 s**, p95 0,234 s |
| Vision on a dense scan | median **2,335 s**, p95 3,270 s |
| fuzzy expansion of one term | **0,90 to 3,00 ms** over 1 487 881 terms |
| exhaustive semantic scan | about **6 ms** over the whole corpus |
| resident memory, 4 threads | **1,148 GB** |

On `energie`, morphology accounts for 207 ms of the latency, diversity 47 ms,
and the typed form 22 ms. A recent Apple Silicon machine is much faster on OCR
and on semantic inference; the size of the index depends only on the corpus.

**What a page costs, by collection.** The budget in the specification is
**2,5 GB** (criterion P5), and two profiles were measured:

| | **books** | **letters and invoices** |
|---|---:|---:|
| documents / pages | 1 527 / 408 951 | 63 / 2 858 |
| index size | 2,151 GB | 22,7 MiB compacted |
| per page, vectors complete | **5,5 KiB** | **8,3 KiB** |
| pages per document | about 268 | about 3 |
| budget reached around | about **451 000 pages** | about 300 000 pages |

A page of a scanned book costs less than a page of correspondence (a page of a
novel carries less text than a 4 000-character form), but a collection of books
has a hundred times more pages per document. In practice, 10 000 three-page
letters make about 240 MiB, and it would take about 100 000 such documents to
approach the budget: the ceiling is a subject for a collection of books, not
for the intended audience.

Breakdown on the same index (`SELECT name, sum(pgsize) FROM dbstat GROUP BY
name`, semantic preparation at 67 %): `page_fts_content` 1 186 MiB (58,0 %),
`page_fts_data` 392 MiB (19,2 %), `page_vec` 232 MiB (11,4 %), the fuzzy
vocabulary 119 MiB (5,8 %), `ocr_layout` 92 MiB (4,5 %), everything else 22 MiB.
`page_vec` holds 764 872 rows of which 582 086 are real windows (the others are
empty completeness sentinels): 384 bytes of vector plus about 26 bytes of
SQLite row. At full coverage of the current corpus, about 868 000 windows in
about 1 141 000 rows come to about 346 MiB, which is the 2,27 GB `fouine
status` projects.

## 9. Spotlight

Fouine **donates** its documents to the Spotlight index (`CSSearchableIndex`,
CoreSpotlight): a donated result shows up under Fouine's name, and clicking it
reopens Fouine on the page through the `fouine://` path. Four pieces, in
`Sources/FouineIndex/Spotlight/`: `SpotlightPolicy` decides which documents go
and up to what volume of text, `SpotlightItemBuilder` builds the value handed
over (identifier, title, snippet, text, keywords), `SpotlightDonor` is the only
code that talks to `CSSearchableIndex`, and `SpotlightSync` runs the mechanism.
The first three are pure.

**The marker.** `docs.indexed_at` says when a document was last indexed; the
setting `spotlight.synced_at` says how far the donation has gone. A donation
reads `indexed_at >= synced_at`, with `>=` and not `>`, because the marker is
in whole seconds and a strict `>` would lose what was written during the
current second. A full batch (`maxDocumentsPerRun`, 5 000) advances the marker
only as far as the last donated document. `completeOCR` also touches
`indexed_at`: without that, the text of a scan, the only text that document
will ever have, would never have «changed».

**Deletions.** `purgeDoc` leaves no trace, so an incremental donation cannot
know that a document disappeared. That is the job of the FULL donation (marker
at 0): it erases the `io.github.basedpolymer.fouine.documents` domain and
donates everything again, which happens the first time, on the «Update
Spotlight now» button, and on any change of scope.

**Who donates.** `SpotlightDonor.isAvailable` requires the process to be the
executable of the `io.github.basedpolymer.fouine` bundle. The `fouine` command
(no bundle), the background agent (it lives in `Contents/MacOS/FouineAgent`, so
it borrows the app's identity without being its executable) and `swift test`
donate nothing: the application catches their documents up at launch and at the
end of a pass. The reason is in `Notifier.swift`: a system service called
without an identity of its own does not refuse politely, it TERMINATES the
process.

**Cost.** A donation makes two reads: `documentsChanged` (one query on `docs`
with a correlated `count(*)` on `page_src`) and `pageTexts`, which reads text
in slices of 32 pages up to `spotlight.text_kb` (1 MiB by default), so a
three-thousand-page book is never loaded whole. The next slice is asked for by
PAGE CURSOR rather than `OFFSET`: the `page_fts` rowid is structured, and an
`OFFSET` would force SQLite to read the skipped rows, bodies included (measured:
a full donation was still running after fourteen minutes). On a copy of the
production index, median of three passes: a full donation of the default scope
gives 940 documents and 561 MB in **24,6 s**, the «everything» scope 1 504
documents and 606 MB in 27,2 s, an incremental donation with nothing new
**3 ms**, and with one new document 10 ms. The incremental line is the one that
matters, since it runs at the end of every pass. Anyone who finds 561 MB of
donated text expensive lowers `spotlight.text_kb` (256 divides it by about
four); what is lost is the tail of very long documents, which Fouine finds
anyway.

## 10. Shortcuts (App Intents)

Three actions (`SearchFouineIntent`, `OpenInFouineIntent`, `GetPageTextIntent`),
one entity (`FouineHitEntity`, a page that was found) and its lookup query, in
`Sources/FouineApp/Intents/`. What Shortcuts displays is described in
[`app.md`](app.md); what follows is what keeps the build chain intact.

**The metadata is the delicate part.** Shortcuts does not read the binary: it
reads `Fouine.app/Contents/Resources/Metadata.appintents`, a folder Xcode
produces in a step of its own that SwiftPM knows nothing about. Fouine
reproduces that step in two moves. `make release-build` compiles with
`CONST_VALUES_FLAGS` (`-emit-const-values`, plus `-const-gather-protocols-file
Packaging/appintents-protocols.json`), so the compiler writes one
`<source>.swiftconstvalues` per file describing conformances and literal values.
Then `Packaging/bundle.sh` runs `appintentsmetadataprocessor` (shipped with
Xcode) over the source list and the matching `.swiftconstvalues` list, before
signing, as with every sealed resource. It fails outright if the processor is
missing, if the release was built without the flags, or if nothing was
extracted: a bundle without that folder launches perfectly and simply has no
actions in Shortcuts, which nothing else would report.

Two consequences. A value that goes into the metadata **must be a literal**:
`@Parameter(default: IntentSupport.defaultLimit)` fails to compile («expect a
compile-time constant literal»), because it is read before any Fouine code
runs. And the `.swiftconstvalues` list is derived from the source list rather
than gathered in bulk: a deleted file leaves its own behind, and the processor
stops on «Unable to find matching source file».

Shortcuts launches the application in the background to run an action, so
`AppModel.start()` has not run and `StoreService` does not exist. Each action
opens its own read through `GRDBStore.openReadOnly`, which takes no lock, so a
shortcut can search while the agent indexes. `OpenInFouineIntent` opens no
window of its own: it opens the `fouine://` URL the entity carries, on the same
path as Spotlight. What is pure, therefore tested, is `IntentSupport`: the
query plan (`QueryParser.searchPlan`, exactly like `fouine search`), the bounds
on the result count, the `<docID>:<page>` identifier and its inverse, the
snippet cut to 240 characters on a word boundary, the 20 000-character ceiling
on a page's text, and the «nothing indexed» guard. The intents themselves are
not tested in XCTest, since outside a bundle they do not exist for the system;
`make ci-bundle` checks that `Metadata.appintents` names them.

## 11. Application sources: Apple Notes, Bear, Anki

Apple Notes, Bear and Anki do not store files: their notes live in a SQLite base
under `~/Library/`, where no crawl descends and from which no extractor takes
text. Rather than open a second indexing path, with its own schema, state and
special cases in search and preview, Fouine **materialises** them: it reads the
base, writes Markdown files in a folder of its own (one per note for Apple Notes
and Bear, one per deck for Anki), and that folder becomes an ordinary root.

| Source | Base | Text |
|---|---|---|
| Apple Notes | `~/Library/Group Containers/group.com.apple.notes/NoteStore.sqlite` (`ZICCLOUDSYNCINGOBJECT`, `ZICNOTEDATA`) | `ZDATA`: gzipped protobuf, path `2 → 3 → 2` |
| Bear | `~/Library/Group Containers/9K33E3U3T4.net.shinyfrog.bear/Application Data/database.sqlite` (`ZSFNOTE`) | `ZTEXT`, in the clear, already Markdown |
| Anki | `~/Library/Application Support/Anki2/<profile>/collection.anki2` (`notes`, `cards`, `decks`; before schema 15, `col.decks` as JSON) | `notes.flds`: HTML fields separated by U+001F |

Reading is strictly read-only (`sqlite3_open_v2` with `SQLITE_OPEN_READONLY`
and the URI `?mode=ro&immutable=1`); `immutable` avoids touching the `-wal` and
`-shm` of a live application, and the accepted price is reading a state a few
seconds old, which the next pass catches up. Optional columns are read from
`PRAGMA table_info`, so a base from a macOS version that lacks them still
reads. Decompression is capped at **128 MiB**, the archive value, checked
before every append to the buffer: `ZDATA` is a blob from elsewhere, and
nothing bounds its compression ratio. Locked notes and the trash are skipped;
an archived Bear note is kept, since archiving is filing rather than throwing
away.

Each note becomes `~/Library/Application Support/Fouine/Sources/<App>/<cleaned
title>-<8 characters of the identifier>.md`, written atomically, its `mtime`
set to the note's modification date, and opening with two HTML comments
(`fouine-source`, `fouine-open`) then `# Title`. Three decisions carry that
format: the title is in the body, because Fouine does not index file names; the
`mtime` is the note's, without which the delta crawl would re-extract
everything at every pass; and the name carries the identifier, because two
notes can be called «Groceries». The comments are **not** indexed:
`MaterializedText.pages` drops them before paginating, since their words made
page 1 of every copy match «anki», «source» or «fouine». The preview reads them
from the head of the file to offer «Open in Notes» instead of «Show in Finder».

**A copy is recognised by where it lives, and shown as what it is.**
`SourceDocumentLocator` (pure, in FouineIndex) takes a volume-relative path, as
stored in `docs.rel_path`, and answers whether it lies under
`<Sources>/<Notes|Bear|Anki>/`; if so it returns a `SourceDocument`: the source,
the title (the deck's name, or the file name without its identifier suffix for
Notes and Bear, `AppSource.documentTitle`) and the parent decks. What a file
writes at its top no longer makes it a copy: any `.md` in an ordinary root
could declare `fouine-source: notes` and have the preview open its
`fouine-open:` link, whatever it was. A note's link is now read from the head of
its own file and must use its application's scheme. In the app,
`DocumentDisplay` is the single gate every surface goes through (results,
preview, detached window, «All your documents», menu bar, citations, export,
Shortcuts; Spotlight takes the title in `SpotlightSync`): a copy gets the name
of its note or deck, a breadcrumb («Anki › Chemistry») instead of a path, its
application's icon from LaunchServices (`AppSource.bundleIdentifiers`, no logo
is bundled), and, for a deck, cards instead of pages (`PageUnit`). A copy is
previewed as text only, and the file gestures (Quick Look, drag and drop,
Finder, Open) give way to opening its application.

Synchronisation happens at the start of any pass that walks (`IndexPass.run`),
before the crawl, so the files are up to date when the crawl looks at them. With
no source enabled it costs two boolean reads from a snapshot that is already
loaded, and a pass with no crawl (`extract`, `ocr`) does not synchronise. No
error is fatal: a base refused by TCC, an uninstalled application, a schema
changed by a macOS update, all leave a sentence in the report and the pass
continues. An indexing pass that fell over because Apple changed a table would
be an unacceptable failure mode for an index that runs by itself.

Two details look like exceptions and are not. `RootPolicy` refuses `~/Library`
to a user gesture, rightly, but this folder is not chosen by anyone: Fouine
builds it and knows its contents file by file, so it registers it through
`addRoot`, and the crawl excludes `~/Library` exactly, not what lies below it.
A user who picks an application's own data folder (`Anki2`, the Notes or Bear
group container) gets a refusal of its own, `.applicationData`, which points at
the application's box in Settings rather than calling the folder empty.
And a `.md` file is not a «blind» format, so the default Spotlight policy does
not donate these files: Spotlight reads them itself, and donating them would
produce two results for the same note. `NoteStore.sqlite` is protected by
**Full Disk Access** (measured: even Terminal gets «authorization denied»), and
refusal is distinguished from absence (`SourceError.accessDenied` against
`.missing`), since sending someone into System Settings for an application they
never installed is the opposite of help.

**Anki differs on three points.** *Reading*: Anki writes in WAL mode without a
`-shm` file and does not fold its log back into the base while it stays open.
Measured on 14/09/2026 on a real collection with Anki open, `immutable=1` saw
3 235 notes where the base held 3 359: two days of cards existed only in
`collection.anki2-wal`. A plain `mode=ro` open reads them but creates a `-shm`
next to the collection. So `AnkiSource` clones the log **then** the base into a
temporary folder of its own (an APFS clone, instant and lock-free), starts again
if either changed during the copy (three tries), and opens the copy with
`SQLiteReader.Access.privateCopy` (`mode=ro`, without `immutable`, so the copied
log is replayed). The order matters: a checkpoint falling between the two copies
writes into the base pages that the log already copied replays identically,
where the reverse order would lose the pages of a log that has been reset. The
`unicase` collation Anki indexes its deck names under is declared on the
connection, since without it SQLite refuses to prepare any statement its planner
routes through that index. *Shape*: one file per **deck**, one page per
**note**. A card averages 250 characters: one file per note would turn every
result into a one-line document and let forty cards fill the screen ahead of the
lectures, where a deck document shows "3 of 42 pages · See them all" and falls
under the three-best-pages diversity rule. The deck hierarchy becomes folders
(`SourceNote.relativePath`, checked component by component by the materializer,
which also removes emptied folders and compares names without case, as the disk
does), and a deck beyond 2 000 notes is split into volumes to stay under the
5 000-page ceiling of a re-paginated format. Pages are separated by U+000C, which
`PlainTextExtractor` honours **only** in a file whose first line is a
`fouine-source:` marker (`MaterializedText`): an RFC or a GNU source carrying
form feeds keeps its pagination. *Text*: `AnkiText` resolves cloze deletions to
their answer (innermost first, hint dropped), drops image-occlusion masks,
`[sound:…]` and the `[latex]`/`[$]` markers, then strips the HTML with the
extractor's own `HTMLText`. Field names and tags are not copied: "Front",
"Text" or `lot::2026-09-14` would recur on every page of a deck. The pictures of
a card are named after its text, one `<!-- fouine-image: name -->` line each;
`MaterializedText.pages` takes those lines out of the page text (a name such as
`m2su-822-courssimprocedes2627part1-p139.png` would put five false words in the
index and in fuzzy expansion, on every card) and attaches them to the first page
of their card. The preview reads the file through that same function, so the
picture shown belongs to the card shown even when a long card spans pages, and
loads each picture from the profile's `collection.media` through
`AnkiSource.mediaFile(named:in:)`, which re-checks the name, since a `.md` in
any root could carry one. No text recognition runs on card pictures: on the
collection measured, 2 937 notes out of 3 359 carry one, mostly screenshots of
lecture pages already indexed as PDFs. The file carries
no `fouine-open:` line, since Anki for Mac has no link to a note: the preview
opens the application found by its bundle identifier (`net.ankiweb.anki`, then
`net.ankiweb.dtop`), never a path read from a file. Unlike a note, a deck file
has no `# Title` line (`SourceNote.titleInText`): the deck's name belongs to no
card, and above the first one every word of it made that card match. A deck is
found by its name, like a file. One card is one page, so the app counts cards;
a card longer than 4 000 characters would take two numbers (none of 3 352
measured, the longest has 2 885 characters).

**Notion and Craft are not read.** Notion keeps its pages on its server (the
local cache is a private, encrypted format) and Craft stores them in a
container nothing promises to keep stable. The answer is the export: a folder
of Markdown or HTML that Fouine already reads, added as an ordinary root.
Notion appends the page identifier to the exported file name (32 hexadecimal
characters), which `SourceLinks.notionURL(forFileName:)` turns into
`notion://www.notion.so/<id>`; Craft writes no identifier, so there is nothing
to reopen, and that is said rather than guessed.

## 12. The MCP server

`fouine mcp --stdio` exposes the index to an MCP client over JSON-RPC on stdin
and stdout. Five read-only tools: search, list documents, read a page, find
similar pages, index status. The server never writes, never starts an indexing
pass, never returns the original files, and never opens a network connection.
It opens the base through `GRDBStore.openReadOnly` and takes no lock, so it
answers while the agent indexes. `stdout` carries protocol frames and nothing
else; every log line goes to `stderr`, because one stray `print` breaks the
session. Two targets, because the split is what makes the framework's MIT
licence real: `FouineMCPKit` (transport, JSON-RPC, router, result envelopes,
token budget, pagination cursors) and `FouineMCP` (read-only store, server
lifecycle, tools). Tools, response shape, golden transcripts and the `.mcpb`
manifest: [`mcp.md`](mcp.md).
