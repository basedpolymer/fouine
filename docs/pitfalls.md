# Known pitfalls

Behaviour that surprises, and why it is what it is. None of these is a defect
waiting to be fixed: they are trade-offs, and knowing them saves hours.

**Index and command line** — [the agent holds the write
lock](#the-agent-holds-the-write-lock) · [a binary from another
schema](#a-binary-from-another-schema-wrote-into-the-base) · [macOS
authorisation](#macos-authorisation-is-pitfall-number-one) · [a wrong
FOUINE_DB](#a-wrong-fouine_db-no-longer-builds-a-ghost-index) · [a copy that
will not open](#a-copy-of-the-index-will-not-open-and-status-does-not-repair-it)
· [a moved root](#a-moved-root-is-not-a-permissions-problem) · [OCR is
long](#ocr-is-long) · [the index size is the tight
budget](#the-index-size-is-the-tight-budget) · [Time
Machine](#time-machine-backs-up-the-index-and-the-index-changes-constantly)

**Search** — [fuzzy ignores short words](#fuzzy-ignores-short-words) · [one
facet in five](#one-facet-in-five-does-not-rerun-the-query) · [a plural is not
a typo](#a-plural-is-not-a-typo-fuzzy-fixtures) · [an AND that became an
OR](#two-words-that-decline-into-each-other-an-and-that-became-an-or)

**Formats** — [`.xls` and `.ppt`](#xls-and-ppt-are-read-but-never-by-nsattributedstring)
· [`.djvu` and djvulibre](#djvu-files-need-djvulibre) · [what is not
walked](#what-is-not-walked) · [a very long page](#a-very-long-page-is-truncated)
· [the semantic model](#semantic-search-needs-a-downloaded-model) · [nothing
blocks a pass](#a-document-no-longer-blocks-a-pass) · [iWork and
QuickLook](#iwork-documents-and-the-quicklook-preview) · [a recognition that
returns one minute](#a-recognition-that-returns-only-its-last-minute) · [a
callback that never comes](#a-callback-that-never-comes-the-sfspeechrecognizer-queue)

**Packaging and the system** — [two copies of
Fouine.app](#two-copies-of-fouineapp) · [an old DMG in
dist/](#an-old-dmg-in-dist) · [LaunchServices strips the
fragment](#launchservices-strips-the-fragment-of-a-file-url)

**SwiftUI and the interface** — [a fifteen-digit
count](#a-fifteen-digit-count-in-the-interface) · [a sidebar sentence that
truncates](#a-sidebar-sentence-that-truncates-instead-of-wrapping) · [a column
that overflows](#the-results-column-that-overflows-the-window) · [two gestures
in a card](#two-gestures-in-a-sidebar-card) · [the `isInserted`
binding](#an-empty-window-at-99--cpu-the-isinserted-binding-of-menubarextra) ·
[a modifier after
`.environmentObject`](#a-modifier-placed-after-environmentobject-kills-the-app-at-launch)
· [`application(_:open:)` silences
`.onOpenURL`](#application_open-silences-onopenurl) · [ten children in
`commands`](#commands-caps-out-at-ten-children) · [a date that loses its
sub-seconds](#a-date-that-round-trips-through-json-loses-its-sub-seconds)

---

## The agent holds the write lock

Every write goes through an exclusive `flock` on `fouine.lock`, taken at the
first write and **released at every resting point**: end of pass, end of an OCR
or embedding batch. While the background agent is writing, `fouine index`,
`crawl`, `extract` and `ocr` fail with **exit 3**, «database locked by another
process — the database is being written by the agent (pid 1234) since 10:32»;
between two batches they go through. `search`, `status` and `doctor` never take
the lock and always work.

**A `fouine.lock` that names a dead process blocks nothing, and no longer shows
up.** A process that was killed goes through neither `release()` nor `stamp()`,
so its name stays in the file, but the kernel released the `flock` when it
died. `doctor` probes the `flock` rather than believing the file, answers
`free`, and cleans up the stale name. If you still read a holder's name, it
really holds the lock.

Before a large command-line pass, turn off «Keep the index up to date
automatically», then turn it back on.

## A binary from another schema wrote into the base

Back when a `fouine` binary would open any base, one from before semantic
windowing wrote about 11 000 rows into `page_vec` with the rowids of the old
formula (`doc × 100000 + page` instead of `page × 8 + window`). Those rows are
not inert: semantic search folds them back onto page `rowid / 8`, and when that
page exists it returns a perfectly credible snippet for a page that has nothing
to do with the query.

The scenario cannot happen again: a binary refuses any base whose
`schema_version` is not exactly its own, in either direction, and does not
modify it. What remains is a `FOUINE_DB` that names a base you did not mean,
and cleaning up rows already written:

```sh
fouine backup ~/fouine-before-repair.db   # always first
fouine doctor --deep                      # counts and names the bad rows
fouine maintain --repair                  # removes them
fouine embed                              # rebuilds what is missing
```

`--repair` removes only what is **provable**. A row in slot `≥ 3`, or one whose
page does not exist, can only come from elsewhere. A row of the old formula
that happens to land on slot `< 3` of a real page is **indistinguishable** from
a legitimate window and stays: on the production index that was 615 rows over
206 pages, against 11 051 removed without ambiguity. Settle the doubt by
throwing away rather than guessing: delete **all** the windows of the suspect
pages and let `fouine embed` redo them, which it does by itself as soon as the
completeness sentinel is gone. Do not try to «fix» the rowids: two formulas do
not translate into each other without knowing which one wrote each row, and
that is exactly what is unknown.

**The corollary, at every schema change.** A changed `Schema.version` makes the
existing index unreadable in both directions: the new binary says «predates
1.0.0 … delete it and index again», the old one «written by a newer version —
update the fouine binary». There is no recovery path, on purpose. Two
consequences: two versions never share a base (after an update, the app, the
CLI and the agent all come from the same build), and changing the schema costs
the user a full reindex, which is decided rather than slipped in.

## macOS authorisation is pitfall number one

A folder under Documents, Desktop, Downloads, a removable volume or a network
share, **without the matching authorisation, indexes as if it were empty, with
no error message at all**. It is the worst failure mode in the project, which
is why `fouine doctor` tests **effective** reading (it opens a file, not a
`stat`) and exits 5 naming the root and the gesture.

Watch the context: the CLI inherits the authorisations of the **terminal** that
launches it, the application its own. `doctor` can succeed in Terminal while
the application is refused, and the reverse. Keeping a stable signing identity
and install path stops macOS asking again after every rebuild. Detail:
[`permissions.md`](permissions.md).

## A wrong `FOUINE_DB` no longer builds a ghost index

If `FOUINE_DB` names a path that does not exist, a read command (`search`,
`status`, `doctor`, `root list`, `config list`, `embed --status`) **refuses**,
with exit 3, the path and the gesture. It creates neither the base, nor the
folder, nor `fouine.lock`, nor the `-wal`. It was not always so: a typo used to
build an empty index and the command answered «0 results» forever, on a ghost
index nobody was looking for. If a command refuses an index you believe you
have, check `FOUINE_DB` and `--db` first: the message prints the exact path it
tried to open.

## A copy of the index will not open, and `status` does not repair it

A Fouine index runs in `journal_mode = wal`, so it lives in **three** files:
`fouine.db`, `fouine.db-wal` and `fouine.db-shm`. Copying the `.db` alone (a
`cp`, a Time Machine restore, a transfer to another Mac) leaves a write-ahead
log that **no reader can recover**:

```
fouine: database: cannot open …/copy.db read-only: the index has a
write-ahead log that only a writer can recover (this happens after a crash, or
when the .db was copied without its -wal).
Run `fouine maintain` once, or open Fouine.app, then try again.
```

Every read command fails the same way, with exit 3: `search`, `status`,
`doctor`, `mcp --stdio`. Two false leads: **`fouine status` repairs nothing**
(it is a read command and hits the same error; the gesture is `fouine
maintain`, which writes), and **opening `Fouine.app` does not help** for a copy
(the application opens the standard index, never the one `FOUINE_DB` names).

```sh
FOUINE_DB=/path/to/copy.db fouine maintain    # once, then everything works
```

To avoid landing there: **`fouine backup <destination>`** produces a clean copy
through SQLite's backup API. That is what to use to send an index elsewhere or
to work on a copy.

## A moved root is not a permissions problem

When the log says «FSEvents burst … matched no active root», the folder moved:
run `fouine root list`, then add it again. `doctor` tells the two cases apart
and mentions authorisation only when a read was refused. An **unplugged
volume** is not an error at all: search keeps answering on what is indexed, and
that volume's index is kept, which is why `root remove` without `--purge`
deletes nothing.

A folder renamed **inside** a root costs nothing: the crawl recognises the file
by its volume file identifier (`docs.inode`) and simply changes the path, which
the command line reports (`· moved 3`). Three deliberate limits: the size and
modification date must not have changed either (a file renamed *and* modified
is re-extracted, since nothing can be guessed); the root itself is still the
special case above; and on a volume that does not guarantee file identifiers
(FAT, an SMB share) `docs.inode` is 0 and the old behaviour applies.

## OCR is long

Count about twenty hours for a queue of 46 000 pages on a 2019 Intel machine.
Work **on mains power** (the agent refuses to OCR on battery, but the CLI has
no such guard and will drain it) and under `caffeinate -i` so the machine does
not fall asleep halfway. `--budget-minutes` cuts the work into slices: exit 4
signals a clean stop, the queue stays coherent and the resumption is exact. The
`fouine embed` campaign follows the same logic and has no energy guard either.

## The index size is the tight budget

On the reference corpus, the index weighs about 1,65 GB before OCR and reaches
1,9 to 1,95 GB once the OCR queue is fully processed. It is the only criterion
that **tightens** as OCR advances. The dominant cost is the text itself, by
far: on a 2,151 GB production index (1 527 documents, 408 951 pages, semantic
preparation at 67 %), `page_fts_content` is 58,0 %, `page_fts_data` 19,2 %,
`page_vec` 11,4 %, the fuzzy machinery 5,8 %, `ocr_layout` 4,5 %. The fuzzy
apparatus is not the problem; the text and its index are 77 % of the file.

At full vector coverage of that same corpus the index reaches about **2,27 GB,
or 91 % of the 2,5 GB budget**, without a single new document. At 5,5 KiB per
page the budget is crossed around **451 000 pages**, about 42 000 pages of
headroom. `fouine status` (the `database` line), `fouine doctor` and the Index
card all say so; **nothing stops** at 100 %, and the gesture is `fouine
maintain --vacuum` or removing a folder. A collection of letters and invoices
costs 8,3 KiB per page but only 3 pages per document, so it reaches the ceiling
at about 100 000 documents.

## Time Machine backs up the index, and the index changes constantly

`~/Library/Application Support/Fouine/` weighs more than two gigabytes on a
large collection, and an index update rewrites much of it. Time Machine, which
runs hourly, therefore keeps **one more copy per hour** for as long as the
index moves, filling a backup disk far faster than expected and shortening the
history of the real data.

The remedy is to exclude the folder, and it costs nothing: the index is not
irreplaceable data, it rebuilds from the documents (at the price of letting
Fouine read them again and redo the recognition of scanned pages, which is long
but automatic).

> System Settings ▸ **General** ▸ **Time Machine** ▸ **Options…** ▸ **+**, then
> choose `~/Library/Application Support/Fouine`. The folder is hidden: ⌘⇧G in
> the picker, then paste the path.

The **documents** stay backed up: Fouine never writes to them and never moves
them. To keep a copy of the index without hourly snapshots, use `fouine backup
<destination>`.

## Fuzzy ignores short words

No expansion below 6 letters, deliberately: at that length a distance of 2
connects words that have nothing to do with each other, so `gibbs` and `mayer`
stay exact whatever mode is chosen. A prefix likewise needs **at least 4
letters** before `*`: there is no prefix index in the base (it cost +480 MB),
and a short prefix sweeps a disproportionate share of the vocabulary.

## One facet in five does not rerun the query

*Folders*, *Document types*, *Languages* and *Text origin* run a real filtered
query. Only *Years* filters the results **already loaded**, and the section's
tooltip says so.

«Scanned pages only» was a display filter for three days, and that is the part
worth remembering. Provenance is a property of the **page** (`page_src`), not
of the document, and `SearchQuery` could not express it, so the chip hid the
pages with native text among the 200 already loaded while the totals, the other
facets and «Load more» went on counting the hidden ones. The estimate that a
real filter would cost «a subquery over 390 000 rows of `page_src` on every FTS
run» was wrong: a JOIN on the primary key `(doc_id, page)` costs one B-tree
hop per matching page, not a scan. `energie` (29 005 pages) went from 263 ms to
81 ms under «scanned pages» and to 273 ms under «typed text»; with no filter
the join is not written at all.

Three implementation traps, each held by a test. The join alias cannot be `s`
(the fuzzy branch already joins `page_src s` in the same query in `ocr` scope;
the provenance filter uses `pf`). The native case needs a LEFT JOIN, because a
page ABSENT from `page_src` is native text and an inner join would make it
vanish from a «typed text» filter. And the vector channel cannot take this
filter as a document list: `VectorIndex.topK(allowedDocs:)` knows only
documents, and on a MIXED document it would let the wrong pages through, so the
vector list is sieved after the scan by `pageMeta`, over at most `depth * 2`
rowids.

## A plural is not a typo: fuzzy fixtures

Four fuzzy tests started failing the day morphology reached the query, because
their fixtures used «polymeres» as a *fuzzy variant at distance 1* of
«polymere». A plural is now an **exact form** of the word (`Morphology`): it
comes out of the exact branch with `fuzzyDistance = 0`, its score is no longer
halved, and a test expecting `1` read `0`.

The rule: a fixture meant to exercise fuzzy matching uses a real OCR typo, a
letter substitution («polymrre», «thermodynamlque»), never a change of number.
And a fixture that counts the exact pages of a word counts the pages carrying
its plural too, since that is what the query finds. The same trap awaits any
assertion on the `total_pages` of a French word whose plural is a common
English word (`energie` and «energies»).

## Two words that decline into each other: an AND that became an OR

`Morphology.expansions` used to decline each bare word **independently**, so
`entropy entropie` became `("entropy" OR "entropies") AND ("entropie" OR
"entropies")`, which any page carrying only «entropies» satisfies. On the real
index, 77 pages became 943 and six of the top ten carried **neither** typed
word; `energy energie` went from 95 pages to 26 081.

The rule since: a form that is another typed word, or a form of another typed
word, is given to **neither** (`Morphology.variants(of:among:)`). Three
surfaces share it (the FTS string, the bonus probes, the explanation and
highlighting), and any new surface that declines a word goes through `among:`,
never through `variants(of:)` alone.

Two neighbouring traps. **A raw FTS5 string is not rewritten**: `--raw-fts`
promises «as typed», and morphology was rewriting `body:polymere` into
`("body" OR "bodies" OR …):polymere`, an FTS5 error and exit 3 with an SQL
dump. The guard lives in the core (`GRDBStore.morphologyApplies`: no analysed
term, no morphology) AND in the CLI. **The cost guards read the MORPHOLOGICAL
count**: bonus probes and diversity disarm past 50 000 matching pages, counted
AFTER expansion, and a word whose plural is a common English word gets there
much sooner than before (`metal` 46 051, `these` 50 000), losing bonuses,
diversity and exact totals at once. That is intended, but a measurement
comparing «with» and «without» morphology must check which side of the
threshold each query falls on.

## `.xls` and `.ppt` are read, but never by `NSAttributedString`

The binary OLE formats from before Office 2007 are read by a reader written
here: `Support/CompoundFile` for the container, `LegacyExcelExtractor`
(BIFF5/BIFF8) and `LegacyPowerPointExtractor` for the content. What stays true,
and what got these formats refused for five versions, is that
**`NSAttributedString` returns a false success on them**: `NSPlainText` and
316 411 characters of mojibake, without raising anything. Never hand them to
it. The plausibility check stays in the way: a page that fails it is not
emitted.

What is still refused, and says so: an ENCRYPTED workbook or presentation
(`docs.err = "password-protected workbook"` / `"password-protected
presentation"`), and an OLE container with no workbook or presentation stream.
These land as `skipped`, never `failed`: a password-protected document is not a
broken document. Likewise `emf`, `wmf` and `svg` are excluded from embedded
media, because ImageIO does not decode them and admitting them would only queue
pages for OCR that no renderer would produce. `webp` is accepted.

## `.djvu` files need djvulibre

It is the only external dependency macOS does not provide, and it is optional:
without it, `.djvu` files land in `skipped` with the reason `"djvu: djvulibre
is missing (missing-tool:djvused)"`. `brew install djvulibre` is enough, and
`fouine doctor` says so. The tool is looked up by explicit paths
(`/opt/homebrew/bin`, `/usr/local/bin`, `/opt/local/bin`, then
`FOUINE_DJVUSED`) because an application launched from the Finder does not have
Homebrew in its `PATH`.

**Installing the tool is now enough; there is nothing to do afterwards.** Until
the reason carried a token, a `.djvu` indexed before the installation stayed
`skipped` forever, since installing djvulibre changes neither the size nor the
modification date of the file and the delta crawl looks only at those two; the
only recourse was to `touch` each file. The reason now carries
`missing-tool:<executable>`, which the crawl re-reads at every walk, checks,
and requeues the document if the tool is there. No other family of `skipped` is
re-examined: «unsupported format» and «file too large» do not change on their
own.

## What is not walked

The crawl skips what is not a document: `.DS_Store`, `.git`,
`.Spotlight-V100`, resource files `._*`, and `.pages` / `.key` packages. On top
of that:

- **packages** are recognised through `URLResourceKey.isPackageKey`, with a
  fallback list for when Launch Services does not answer: `.app`,
  `.framework`, `.xcodeproj`, and the Photos libraries (`.photoslibrary`,
  `.aplibrary`). `.rtfd`, which is a package and also a document, stays
  indexable;
- **dependency and cache folders** (`node_modules`, `.venv`, `Pods`,
  `DerivedData`, `.build`, `.git`) are skipped wholesale: one `node_modules`
  routinely exceeds 30 000 files for zero documents;
- **hidden files** and `~/Library` are ignored;
- **iCloud or File Provider files that are not downloaded** (the `SF_DATALESS`
  flag) are marked `skipped` with «not downloaded (iCloud/File Provider) — it
  will be indexed once present» and are **never opened**, since opening them
  would trigger a download of the whole folder. They are re-examined at every
  crawl and picked up as soon as they are there.

The log and `fouine status` remain the way to know what was seen and what was
ignored.

## A very long page is truncated

For **unpaginated** formats (plain text, HTML, RTF), text is cut into pages of
4 000 characters. The other limits: 2 GiB per file, 50 MiB of text per
document, 99 999 pages per document. Past those the document is refused with a
readable reason rather than silently truncated.

## Semantic search needs a downloaded model

`fouine search --hybrid` and `fouine embed` need a 220 MB model that is **not**
embedded in the application: `fouine model download` installs it, `fouine
doctor` says whether it is there. Without it, `embed` refuses to start and says
so, and `--hybrid` falls back to full-text search, which never needed it.

Together with the update check and licence activation, it is one of the few
commands that opens a connection. It contacts **two** hosts, `github.com` then
`release-assets.githubusercontent.com`, because GitHub serves release assets by
redirection: an outbound firewall sees two requests, and that is normal.
Nothing is installed if the SHA-256 does not match. On an offline machine, copy
the archive and set `FOUINE_MODEL_URL=file:///path/e5-small-v1.zip`: no
connection is opened at all. Detail: [`privacy.md`](privacy.md).

## A document no longer blocks a pass

Vision, PDFKit and `pmset` are synchronous calls that no option interrupts, and
one of them hanging used to freeze the whole pass. They all carry a deadline
now, deliberately wide (120 s for an OCR page that measures 2 to 4 s). Past it,
an OCR page returns to the queue with one more attempt and is abandoned only on
the third, its reason in `docs.err`; a document whose extraction overruns falls
to `failed` with its reason, and the pass moves on; an unreadable `pmset`
disables the thermal guard **and says so**, as when it is absent.
`FOUINE_OCR_TIMEOUT`, `FOUINE_RENDER_TIMEOUT` and `FOUINE_PDF_TIMEOUT`
(seconds) tune them, for instance to reproduce a hang. An unreadable or zero
value is ignored: a guard is not disarmed by a typo.

## iWork documents and the QuickLook preview

Fouine extracts the text of iWork documents through their internal
`QuickLook/Preview.pdf`, handed to the PDF extractor. Two behaviours follow.
**The preview can lag behind the document**: Pages, Numbers and Keynote
regenerate `QuickLook/Preview.pdf` only when the file is actually saved. And
**without a preview the document is refused**: if Pages is configured not to
include one, or the file comes from an incomplete export, it is marked `failed`
with «iWork document without a QuickLook preview — open it once in Pages to
generate one». Opening and saving it once in Pages, Numbers or Keynote is
enough.

## A recognition that returns only its last minute

Two twelve-minute lectures kept 879 and 510 characters of transcript instead of
about 8 800, and the pass reported success. On macOS 15, on-device
`SFSpeechRecognizer` fed by `SFSpeechAudioBufferRecognitionRequest` returns
speech in **chunks of about 60 s**: each arrives as a result with `isFinal ==
false` carrying `speechRecognitionMetadata`, and only the last is `isFinal`.
Keeping `isFinal` alone kept 722 characters out of 2 110 for 0 to 180 s of a
lecture. Turning on `shouldReportPartialResults` changes nothing (same three
chunks, text restarting from zero after each, 365 callbacks). The remedy is to
accumulate the chunks (`TranscriptChunks`).

Why the tests could not see it: `voix.aiff` lasts a few seconds and the audit
extracts thirty, so both are **one chunk**, final, and kept whole. Two rules
came out of it. **A speech test lasts more than a minute**
(`testSpeechLongerThanAMinuteIsWrittenDownWhole`: about 100 s said by `say -v
Thomas -r 175`, with a witness word in the first fifteen seconds and one in the
last fifteen, both required). And **an extraction path that changes enough to
justify re-reading everything changes its mark**
(`MediaExtractor.transcriptRevision`, read by `IndexPass`): an `extracted`
document is never revisited, so without a new mark the fixed defect would stay
in the index.

## A callback that never comes: the `SFSpeechRecognizer` queue

An extractor is synchronous: it starts the recognition, then blocks its thread
on a semaphore waiting for the result. With `SFSpeechRecognizer` as it comes,
that callback **never arrives**: no result, no error, no timeout, while the
Speech daemon spins at 100 % of a core retrying and logging
(`SFLocalSpeechRecognitionClient stopSpeech` then `speechRecordingDidFail`, in
a loop). Measured: 120 s without a single callback, by both routes (streaming
and file).

The cause is that `SFSpeechRecognizer.queue` defaults to the **main** queue,
and that is where the recogniser delivers its callbacks, so a caller blocking
the main queue waits for a callback nobody can deliver. The remedy is one line
(`recognizer.queue = OperationQueue()` in
`SpeechTranscriber.recognizer(languages:)`): 1,5 s for 1,95 s of audio. Second
trap in the same area: a task abandoned without `cancel()` keeps retrying in
the background at full CPU after the caller has returned, so the task is
cancelled in **all** cases on the way out (`defer`), not only on a deadline,
and only the first answer releases the wait.

## Two copies of Fouine.app

**The symptom.** «Keep the index up to date automatically» is on, but nothing
is ever indexed. `fouine doctor` says:

```
background agent : registered, spawn failed (EX_CONFIG, 21 runs) — re-register it from Fouine.app ▸ “Keep the index up to date automatically”
```

and `launchctl print gui/$(id -u)/io.github.basedpolymer.fouine.agent` adds
`job state = spawn failed`, `last exit code = 78: EX_CONFIG`, and a retry every
60 seconds.

**The cause.** There is more than one `Fouine.app` on the Mac. macOS opens the
one with the highest `CFBundleVersion`, not the one that is installed. The
agent, however, was registered from `/Applications/Fouine.app`, and
`SMAppService.register()` freezes at that moment both the bundle path (the
agent plist uses `BundleProgram`, a path **relative** to the registering
bundle) and a code requirement taken from its signature. When another copy
takes over, launchd cannot resolve the program and refuses to launch it. The
extra copy almost always comes from the repository, whose `CFBundleVersion` is
the commit count and therefore quickly overtakes the installed application.

**What does NOT repair it.** Deleting the stray copy, then `lsregister -f
/Applications/Fouine.app`. The code requirement is frozen in Background Task
Management: the existing registration stays broken whatever the disk looks
like.

**The repair.**

1. Find the copies: `fouine doctor` (the `application` line), then
   `mdfind "kMDItemCFBundleIdentifier == 'io.github.basedpolymer.fouine'"`.
2. Delete every copy that is not `/Applications/Fouine.app` (`rm -rf` is
   enough; if a ghost entry persists, `lsregister -u <path>` then delete).
3. Open `/Applications/Fouine.app`, turn the background indexing switch
   **off**, then **on**. That step is the repair: it unregisters and
   re-registers the service with the right path and signature.
4. Check: `fouine doctor` must say `background agent : registered, running
   (pid …)` and `application : /Applications/Fouine.app`.

**When the repair is not enough: an orphaned registration.** If the copies are
gone, the switch has been cycled from a single `/Applications/Fouine.app`, and
nothing changes, read the launchd log (`/usr/bin/log show --last 5m --info
--debug --predicate 'process == "launchd"'`; under zsh, plain `log` is a
builtin that hides `/usr/bin/log` and returns nothing). «Could not find and/or
execute program specified by service … The specified path is not a bundle»,
plus `sfltool dumpbtm` showing TWO application registrations at the same URL,
means Background Task Management no longer recomposes the program path. Nothing
purges the orphan, neither `SMAppService.unregister()` nor System Settings; the
remaining remedy is `sudo sfltool resetbtm` followed by a restart, which resets
the background items of EVERY application and is therefore a gesture for the
user alone, never for a script. The lesson: never change the bundle identifier
without unregistering the old agent first.

LaunchServices answers only for the CURRENT bundle identifier, so an
application carrying another one, even sitting in `/Applications`, does not
exist for it, and `doctor` would report «no copy known to macOS» while
something clearly occupies the place. The probe therefore also reads
`/Applications/Fouine.app/Contents/Info.plist` from disk and publishes it as
`app_at_expected_path` in `doctor --json`: when the two contradict each other,
that field tells the truth. What prevents a relapse: `make ci-bundle` builds
its control bundle under `.build/bundle/Fouine.app`, which Spotlight does not
index, and refuses to start if a `Fouine.app` sits at the root of the
repository; the application refuses to arm the switch from the wrong copy, and
says why; `fouine doctor` lists the copies macOS knows about; and
`RELEASING.md` says to delete `Fouine.app` from the root after `make dmg`.

## An old DMG in dist/

`make dmg` used to produce `dist/Fouine-1.0.0.dmg` every time, so without
cleaning `dist/` first, two successive builds carried the same file name, and
an old build was once reinstalled into `/Applications` by mistake,
reintroducing the agent failures above. Two guards now stand in the way.
Outside CI and outside a tag (`git describe --exact-match --tags` fails),
`Packaging/dmg.sh` and `Packaging/mcpb.sh` suffix the artefact with the build
number: `dist/Fouine-1.0.0-b<CFBundleVersion>.dmg`. On an official tag or in
release CI, the canonical name is kept. And `make dist-clean` removes `dist/`
without wiping the `.build/` cache.

## LaunchServices strips the fragment of a `file:` URL

`NSWorkspace.shared.open(URL("file://…/x.pdf#page=3"))` opens the PDF at page
1. So does `open([url], withApplicationAt:)`, and so does `/usr/bin/open`: all
three go through LaunchServices, which reduces the URL to a path. Measured with
a witness page (`document.title = location.hash`) opened by the three routes:
the hash is **empty** every time, and `location.href` carries no fragment.
Launching the reader's executable directly does keep it
(`…/Google Chrome.app/Contents/MacOS/Google Chrome "file://…#page=11"` gives
`HASH=#page=11`).

The consequence for «Open the document»: the page number can only travel on the
**command line of the reader's executable**, which is what `ExternalOpen`
plans, and only for readers known to accept a URL as an argument. Preview
cannot go to a page by any route (its scripting dictionary has no page command
and no page property), and Safari ignores a URL passed as an argument.

## A fifteen-digit count in the interface

The sidebar once announced «105 553 137 941 168 pages left to recognise». That
was not a count: it was the **memory address** of the string «392 559». Three
pieces, each fine on its own: the code interpolated `Format.integer(n)`, which
returns a **string**, so the compiler produced a `%@` key; the translation
wrote `%lld`, because `xcstringstool` refuses `%@` inside a plural variation;
and Foundation then read the string's pointer as a 64-bit integer. Twenty-one
keys were in that state. In **base English** everything looked fine, because
`swift test` does not run from `Fouine.app`, `Bundle.main` has no `.lproj`, and
`String(localized:)` returns the KEY, which did say `%@`. The defect existed
only in the shipped app, with the catalogue compiled. A quieter second symptom:
the plural form was chosen on that same huge pointer, so «1 page left to
recognise» could never appear.

What stops it coming back: `Tools/l10n-lint.sh` compares, for every key, the
TYPE of each argument with that of each translation, and also refuses a
top-level plural variation on a key with two integers (agreement would fall on
the first, and «1 page in 1 documents» would pass). `L10nTests` compiles both
catalogues, renders every key in French and English, and fails on any number of
ten digits or more. The rule in one line: **in a localised string, a count
interpolates as a bare integer**. See [`i18n.md`](i18n.md).

## A sidebar sentence that truncates instead of wrapping

In a `List` of style `.sidebar`, a row offers its content the height of one
line of text. `.fixedSize(horizontal: false, vertical: true)` is enough for a
`Text` on its own, but not for a `Text` sharing its row with something else, a
glyph or a switch: the sentence ends in «…». The three modifiers together make
it fit on two or three lines:

```swift
Text(verbatim: sentence)
    .lineLimit(nil)
    .fixedSize(horizontal: false, vertical: true)
    .frame(maxWidth: .infinity, alignment: .leading)
```

A `Toggle` label truncates whatever you tell it: put the label BESIDE the
switch (`labelsHidden()` on the `Toggle`, the `Text` in the same `HStack`, an
`accessibilityLabel` so VoiceOver keeps the sentence). Second trap in the same
area: `Text.foregroundStyle(_:)` returns a `Text` only from macOS 14 onwards;
on macOS 13, Fouine's minimum target, it returns a `View`. A helper that takes
a `Text` parameter must therefore be generic over `View`, or the package stops
compiling as soon as a caller colours its text.

## The results column that overflows the window

The previous pitfall applies INSIDE a `List`, where `fixedSize(horizontal:
false, vertical: true)` is the remedy. In a `NavigationSplitView` column that
is neither a `List` nor a `ScrollView` (the status line of `ResultsView`, the
footer of `PreviewPane`), the same modifier does the opposite: the column is
also measured at zero width, the fixed text counts one line per word or per
character, and that height becomes the MINIMUM height of the root view. The
whole `NavigationSplitView` then measured **1 053 pt inside a 676 pt window**,
centred, so it overflowed top and bottom: the Index card slid under the traffic
lights, the search field disappeared behind the title, and the middle column
looked empty. The symptom appeared only on an empty query, the one state where
the status line carries two lines of text.

Outside a `List`, the remedy is a frame and nothing else:

```swift
Text(verbatim: sentence)
    .frame(maxWidth: .infinity, alignment: .leading)   // wraps
```

To check a new view: read the accessibility tree (`osascript` plus System
Events) and compare the size of the window's `AXSplitGroup` with the window
itself.

It came back on 24/09/2026 through a notice added later to the same status
line: "Few pages carry all your words…" kept `fixedSize(horizontal: false,
vertical: true)` while its neighbours had the frame. In a 691 pt window the
`AXSplitGroup` measured 973 pt and started at y = −6; the search field sat
behind the title bar, out of reach, until a query without the notice was run.
`WindowLifecycleTests.testResultsStatusBarNeverFixesATextHeight` now reads
`ResultsView.swift` and refuses that modifier in the status line and in every
`…Notice` view.

The same day, four more lines turned out to have the same defect: the
permission banner above the columns (`TCCBannerView`, window pushed to
2 808 pt), the "disk not plugged in" line of the preview (`OfflineNoticeLine`),
the header of the text preview (`TextPreviewNotices`, 2 005 pt) and the
"page no longer exists" line of a detached preview window
(`OutOfRangeNotice`). Placing the frame BEFORE `fixedSize` changes nothing:
the modifier itself is the cause, wherever it sits in the chain. At the root
of a window (a `VStack` holding the banner and the split view) the effect is
worse than in a column: the window grows past the screen.
`ColumnOverflowTests` lays each of these views out in an off-screen window
built like `ContentView` and reads the height of the `NSSplitView`, which is
the `AXSplitGroup` of the accessibility tree; a control test proves that the
harness still sees the defect. A view that only appears after a `.task` must
be extracted with its conditions as parameters: SwiftUI does not run the
`.task` of a window that is never shown, and the test would stay green on the
defect.

## Two gestures in a sidebar card

An `HStack` of 231 points does not hold two French labels: the button gets cut
mid-word («Mettre à jou…») and the second one overflows on top of it. In a
card, gestures go one BELOW the other, the primary button with `.lineLimit(1)`
and `.minimumScaleFactor(0.85)`, and a `.buttonStyle(.link)` gets its colour
explicitly (`.foregroundStyle(.tint)`): on a card background, the `.link` style
draws in white and becomes unreadable.

## An empty window at 99 % CPU: the `isInserted` binding of `MenuBarExtra`

The window stays empty, the main thread spins at 99 % inside SwiftUI view
updates, and `sample` shows `FouineDesktopApp.body.getter` and
`InterfacePreferences.showsMenuBarIcon.setter` on every turn. On an EMPTY base
nothing shows, because each turn is instantaneous, which is exactly why a
by-eye check saw nothing.

The mechanism: `MenuBarExtra(isInserted:)` WRITES its binding on every scene
update, with the value it already has. Passing `$object.property` of a
`@Published` fires `objectWillChange` before any comparison (the `didSet` that
compares comes too late), the `App` is re-evaluated, the scene rewrites the
binding, and so on. The loop saturates the main thread and delays everything,
`AppModel.start()` included, whose continuations wait on that same thread.

The rule: a binding that a scene or a system view writes by itself
(`isInserted`, `isPresented`, a selection) never goes through the `$` of a
`@Published`; it is built with a `Binding` that writes **only when the value
changes** (`FouineDesktopApp.menuBarInserted`).

Two corollaries for anyone checking a panel on screen. Off-screen rendering
with `ImageRenderer` has a trap of its own: a view placed in a `ScrollView` or
a `LazyVStack` draws **empty**, since neither computes its content outside a
window, and `ImageRenderer` also refuses AppKit controls (`TextField`,
`Toggle`), where the crossed yellow rectangle is not an app bug. And a
`@FocusState` written on an invisible panel costs a cycle per update: the
content of a `MenuBarExtra` in `.window` style is hosted from launch with the
panel hidden, so `.task` and `onAppear` run once, immediately, into the void.
Writing `fieldFocused = true` there gave `=== AttributeGraph: cycle detected
===` on stderr every 2 to 4 seconds for the life of the process, at 0 % CPU and
with nothing visible (measured: 0 cycles before, 17 to 34 per minute after,
0 again with that single write removed). A panel field's focus follows the
WINDOW (`NSWindow.didBecomeKeyNotification`, released on `didResignKey`), never
the appearance of the view. Before merging work that touches a scene, run the
app for a minute on a test base and count the `cycle detected` lines in its
log: `top` and `sample` do not show them.

## A modifier placed after `.environmentObject` kills the app at launch

`ContentView().environmentObject(app).modifier(DeepLinkReceiver(…))` dies
before any window appears, on `SwiftUICore/EnvironmentObject.swift:92: Fatal
error: No ObservableObject of type AppModel found`. The binary compiles and the
tests pass: only launching shows it. A modifier placed AFTER the injections
**wraps** the view that carries them, so its own `@EnvironmentObject`
properties read the scene's environment, where no model has been injected yet.

The rule: a `ViewModifier` that reads an `@EnvironmentObject` goes BEFORE the
`.environmentObject(...)` calls of the same chain. And a new view is LAUNCHED
at least once against a disposable base (`FOUINE_DB=<tmp>/x.db
.build/debug/FouineApp`) before being delivered: compiling proves nothing about
the environment.

## `application(_:open:)` silences `.onOpenURL`

Implementing `application(_:open:)` in the delegate of an
`@NSApplicationDelegateAdaptor` can take the place of the handler SwiftUI
installs and deprive the scene of `.onOpenURL`. Anything that adds that method
without thinking about it breaks the `fouine://` links **in silence**: the link
simply does nothing.

The remedy is one mailbox for both routes. `FouineAppDelegate.application(_:open:)`
and `.onOpenURL` both deposit into `AppModel.openedURLs`, and the view sorts
them out (a file becomes a dropped folder, anything else goes to the deep-link
router). A new view that receives URLs plugs into that mailbox rather than
adding a second entry point, and a change on either route is tested against
both: an app open, and an app closed.

## `commands` caps out at ten children

Adding an eleventh `CommandGroup` to the `commands` builder of a SwiftUI
`Scene` fails compilation on «extra argument in call», without naming the
cause: the result builder has overloads up to ten children. The fix is to
merge two related items into one existing group rather than adding a group.

## `showSettingsWindow:` opens nothing since macOS 14

Opening the settings window from a button or a menu item with
`NSApp.sendAction(Selector(("showSettingsWindow:")), to: nil, from: nil)` works
on macOS 13 and does **nothing** from macOS 14 on: SwiftUI only logs "Please use
SettingsLink for opening the Settings scene." **Enter licence key…** (menu item
and Index card button), **Manage in Settings…** and **Open Settings** stayed
silent that way from their creation until 14/09/2026, and no test could see it.

The remedy is SwiftUI's own action. `@Environment(\.openSettings)` exists only
inside a view, and only from macOS 14, so `SettingsWindowRegistrar` (a
zero-size view behind the main window and the menu bar panel) reads it when it
appears and hands it to `SettingsWindow`; `openSettings(on:)` goes through it
and keeps the selector for macOS 13 alone. The tab asked for is set **before**
the window opens: a window being created has not subscribed to the notification
yet, and picks the tab up when it appears. After a change here, click, then
check that `log show --last 5m --predicate 'process == "Fouine"' | grep
SettingsLink` prints nothing.

## A date that round-trips through JSON loses its sub-seconds

A `Date` written to a JSON file in ISO 8601 and read back is not `==` to the
one held in memory: the format carries whole seconds. A state computed in
memory therefore differs from the same state read back from disk, which no
product behaviour depends on, but which a naive test comparing two values falls
straight into. Compare the fields that matter, or round both sides to the
second.
