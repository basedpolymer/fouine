# Changelog

Format: [Keep a Changelog](https://keepachangelog.com/en/1.1.0/).
Versioning: [SemVer](https://semver.org/).

**Convention.** Entries for the version being prepared go under
`## [X.Y.Z] — unreleased`, in the sections `### Added`, `### Changed`,
`### Fixed` and `### Security`, with the batch identifier in italics between
parentheses. At the tag, «unreleased» becomes the publication date. There is no
«Unreleased» section: release notes are extracted from the single
`## [X.Y.Z]` section and would come out truncated, which `make check-changelog`
and `Packaging/appcast.sh` both refuse.

The authoritative version number lives in the `VERSION` file and in
`Sources/FouineCore/Version.swift`; the two must agree (`make check-version`).
See `RELEASING.md`.

## [1.0.2] — unreleased

### Fixed

- **The search field stays in place when some results carry only part of your
  words.** As soon as the line "Few pages carry all your words: here are also
  the pages that carry most of them." appeared above the results, the whole
  window content slid up under the title bar: the search field ended up out of
  reach, and the only way back was to run another search from outside the
  window. *(QN1)*
- **Three other messages no longer push the window content out of view.** The
  banner shown when macOS refuses access to a folder, the line saying that the
  disk holding a document is not plugged in, and the header of a text preview
  ("text read from the scan…") each made the window content slide under the
  title bar, or made the window taller than the screen for the banner. The
  same happened in a separate preview window when the page asked for no
  longer exists. *(QN1)*
- **An unplugged disk no longer shows the permission banner.** When the disk
  holding a folder was not plugged in, the top of the window said "Fouine
  cannot read “Documents”" with an "Open Settings" button, although no setting
  can bring a disk back, and the sentence ended with the words "disk not
  plugged in" stuck after a full stop. The banner now appears only when macOS
  refuses access to a folder, and it names the place in System Settings where
  to allow it. A disk that is not plugged in is still shown in the sidebar,
  where the Index card offers "Check again". *(PB1)*
- **The Index card no longer sends you to System Settings for a folder that
  was moved.** Any folder Fouine could not read was reported as "Fouine is not
  allowed to read" with an "Open System Settings" button, even when the folder
  had been moved, renamed or deleted, held no file Fouine could open, or sat on
  a disk that answered with an error. The card now says "Fouine cannot find"
  the folder, and explains how to add it again from its new place, or "Fouine
  cannot open the files in" it. Both offer "Check again". System Settings is
  offered only when macOS refuses access. *(PB2)*

## [1.0.1] — 2026-09-15

### Changed

- **Images, audio and video files, and what is said in them, are now indexed
  by default.** The three boxes of Settings ▸ Indexing ("Index images",
  "Index audio and video files", "Also write down what is said in them") start
  ticked. Untick the second one if a watched folder is a music library rather
  than a set of documents. A box you set yourself keeps its value; a box you
  never touched takes the new default. *(DF1)*
- **"Also prepare search by meaning in the background" is now off by
  default.** Preparing search by meaning stays a deliberate choice: tick the
  box, or click "Prepare search by meaning…" in the sidebar. *(DF1)*

## [1.0.0] — 2026-09-15

First public version. Fouine indexes the documents in the folders you choose
and searches them, on your Mac, without sending anything anywhere.

### Added

- **Full-text search across your documents**, page by page, with the folder,
  the file type, the language, the year and the origin of the text as facets.
  Results are grouped by document, and every result says why it was found.
- **Search that tolerates typos**, which matters on scanned pages: a word of at
  least six letters is matched through trigrams and edit distance, and a plural
  is treated as an exact form of its singular rather than as a mistake.
- **Search by meaning**, optional. A 220 MB model, downloaded on request, finds
  pages that use other words than the query. Full-text search never needs it,
  and quoting a phrase disarms it.
- **Text recognition for scanned pages** (Vision, on the machine), with
  highlighting on the page image. Nothing is ever written into your files.
- **Around 150 file formats**: PDF, DjVu, text, Markdown, HTML, EPUB, comics,
  Office (including the pre-2007 `.xls` and `.ppt`), OpenDocument, iWork,
  Sketch, Illustrator, mail (`.eml`, `.mbox`, with attachments read as pages),
  subtitles, notebooks, and 68 source-code extensions. Images and media are
  behind two switches: images go to text recognition, audio and video give
  their metadata and, on request, an on-device transcription with timestamps.
- **A background agent** that keeps the index up to date on its own, and stops
  on battery, under thermal pressure, or when you are working. Its state is
  visible in the window.
- **A command line** (`fouine`) with a stable `--json` contract, exit codes,
  `status`, `doctor`, `backup` and `maintain`. It is installed from the
  application's menu.
- **An MCP server** (`fouine mcp`), read-only, so an assistant such as Claude
  Desktop can search the index, read a page and find similar pages, with no
  connection of its own.
- **Fouine's documents in Spotlight**, for the formats macOS cannot read
  itself, and **three Shortcuts actions** (search, open, get the text of a
  page).
- **A preview that quotes**: a `fouine://` link points at a page, survives
  reindexing, and reopens the document at the right place.
- **Apple Notes and Bear** as sources: their notes are materialised as Markdown
  files in Fouine's own folder and indexed like any other document.
- **The application in English and French**, with the system prompts, the
  accessibility labels and the plurals in both.
- **Automatic updates**, signed, off by default and never checked without a
  gesture.
- **A 30-day trial**, then one licence key per person, valid on up to three
  Macs of the same household. When the trial ends, only index updating stops:
  searching, reading and exporting keep working.
- **A path filter and four negative filters in the query language**:
  `path:Offers` (`chemin:`) matches the whole path of a document, folders
  included, ignoring case and accents, and lists the matching documents when
  used on its own; `-ext:`, `-folder:`, `-name:` and `-path:` drop whole
  documents, with the same aliases and quoting rules as their positive forms.
  *(MC1)*
- **The assistant server can now search the way the command line does.** Its
  search tool takes a date (`since`), a spelling tolerance (`fuzzy`), a facet to
  count by (`facet`, with the year the document carries distinguished from the
  year its file changed), the marks that surround matched words in an excerpt
  (`marks`), and a `compact` mode that moves the paths out of every hit into one
  entry per document — which also answers "how many sources is this, really?".
  *(MC2)*
- **An assistant can now cite a slide, a moment, or a page — whichever the page
  really is.** A result from a recording carries the second it sits at, and its
  link reopens there; a result from a slideshow carries its slide number, and a
  picture embedded in the file says it is one rather than passing for page 170.
  Every result also carries a readable relevance out of 100, the same number the
  command line prints. *(MC2)*
- **Two command-line commands: `fouine read` and `fouine similar`.** `read`
  prints the indexed text of one page (`--max-chars`, `--offset`, `--context`,
  `--json`), `similar` lists the pages closest in meaning to a given page from
  the vectors already in the index, without loading the model. Both are
  read-only, and their `--json` carries exactly the keys of the matching
  assistant tools — they share the implementation, so the two surfaces cannot
  drift apart. A page with no vector exits 1 saying so, rather than 0 with an
  empty list. *(MC3)*
- **`fouine embed --folder <label>`** prepares one folder only (repeatable, an
  unknown label is refused before the model is loaded), and **`--include-tables`**
  puts spreadsheets back into a campaign. *(MC3)*
- **A setting, `embed.skip_spreadsheets`** (true by default): spreadsheets are
  left out of search by meaning. *(MC3)*
- **You can keep a folder or a kind of file out of the index.** Put a
  `.fouineignore` file at the top of an indexed folder, one rule per line: a
  subfolder (`Health/`), one exact path (`Notes/INDEX.md`), or a name pattern
  applied anywhere under the folder (`*.md`, `*draft*`). Case and accents do not
  matter, `#` opens a comment. Fouine re-reads the file at the start of every
  pass, so a rule takes effect on its own within a minute; what it names leaves
  the index — text, recognised pages and meaning vectors alike — and comes back
  if you remove the rule. Your files are never touched. `fouine root list` says
  how many rules each folder carries, and `fouine root add` reports a file it
  finds. *(IG1)*
- **`fouine mcp --folders Livres,M2SU`**: an assistant server that serves only
  the folders you name. Everything else is invisible to it — absent from its
  status, from every search, and from a page read by its identifier, which is
  refused exactly as an identifier that does not exist. A folder outside the
  scope is refused naming only the folders served, `fouine_status` carries a
  `scope` object saying what is served, and an unknown name exits 64 before the
  server starts. `fouine mcp install --folders …` writes the scope into the
  client configurations, and installing again without it keeps the scope already
  there. *(IG1)*
- **"What Fouine skips…", under each folder in Settings ▸ Folders.** A sheet
  lists in plain words what Fouine leaves out of that folder ("The folder
  “Health”", "Every .md file", "Files named “INDEX.md”"), with a cross to stop
  skipping one. Three buttons add a rule without typing a pattern: **Skip a
  folder…** (a picker opened on that folder), **Skip a kind of file** (the kinds
  really present there, with their counts), **Skip files named…**. Before you
  save, one sentence says how many documents will leave the index at the next
  update; after, **Update now** is offered when automatic updates are off. The
  rules are kept by Fouine: **nothing is written into your folder**. A
  `.fouineignore` file keeps working, its lines shown greyed out in the same
  sheet, and both apply together. With automatic updates on, a saved rule is
  applied within a few minutes, with no file change needed. *(IG2)*
- **`fouine root ignore list|add|remove <folder> [<rule>]`**: the same rules
  from a terminal, with `--json`. A refused rule (a negation, a line starting
  with `#`, a path with `..`) exits 64 naming it, and so does removing a rule
  that is not kept, or that comes from the `.fouineignore` file. `fouine root
  list` now counts both sources in `ignore_rules` and lists each rule with its
  source under `ignore_rule_list`. *(IG2)*
- **The assistant's index status now says what an assistant needs before giving
  advice**: the disk budget and its level, how many indexed pages are still
  waiting for search by meaning, and — per folder — how many of its pages carry
  a meaning vector. On a real corpus, 68 % coverage overall turned out to be
  73 % for one folder and **0 %** for the two others, which is the difference
  between "search by meaning found nothing" and "search by meaning has never
  looked there". *(MC4)*
- **The assistant can now ask for the neighbours of a page that has no vector
  yet** (`encode_if_missing`, off by default): the page is encoded on the spot
  by exactly the path the background preparation uses. Off, the tool keeps its
  promise never to load the model; on, it costs about two seconds the first
  time. The answer says where the vector came from. *(MC4)*
- **Reading a page says what "page N" really means**: the slide number for a
  slideshow, the moment for a recording (and the link opens at it), whether the
  page is a picture stored inside the file, and the number *printed* on the page
  when it differs from its rank — a book with roman front matter now says
  "page xi" rather than "page 12". *(MC4)*
- **The assistant's document list carries the file's date**, which the command
  line already printed; sorting by "most recent" was until now sorting on a date
  nobody could see. *(MC4)*
- **`fouine search --mark brackets`** (or `asterisks`, or `none`) chooses what
  surrounds the matched words in an excerpt. French documents quote with the
  very characters used by default, and the highlight could not be told from a
  quotation. *(CL2)*
- **`fouine search --hybrid-auto`** searches by meaning when the model and the
  vectors are there, and full text otherwise — no warning, no failure. It is
  what a script wants when it does not know whether meaning search has been
  prepared on this Mac. *(CL2)*
- **`fouine similar --encode`** finds the neighbours of a page that has no
  vector yet, by encoding it on the spot exactly as the background preparation
  would. A whole folder can sit at zero vectors until the preparation reaches
  it, and "no neighbour" then reads as "nothing resembles this page". Off by
  default: without it the command still never loads the model. *(CL2)*
- **Every result of `fouine search --json` now says how relevant it is**
  (`relevance_pct`, the percentage the plain output has always printed), where
  it sits in a recording (`time_seconds`, and the link opens at that moment),
  which slide it is, and whether it is a picture stored inside the file. The
  same four appear when reading a page. *(CL2)*
- **Anki flashcards as a source** (Settings ▸ Folders ▸ Applications, or
  `fouine sources enable anki`), off by default. Each deck becomes one document
  and each card one page of it, so a result points at the card and forty
  matching cards of one deck show as that deck once; nested decks become
  folders. The text of every field is copied, cloze deletions shown as their
  answer; the preview shows the card's pictures under its text, without
  searching the words inside them. Sounds, hints, tags and field names are not
  copied. Anki can stay
  open: Fouine reads a private copy of the collection and its write-ahead log,
  where the newest cards live until Anki quits, and never writes next to it. The
  preview offers **Open in Anki**. Exported `.apkg` files are not read (their
  collection is zstd-compressed since Anki 2.1.50). *(AN1)*
- **The welcome screen says how to use Fouine from an AI assistant.** Under the
  button that adds a first folder, one line reads "To use Fouine with your AI
  assistant (Claude, Codex, Antigravity…), ask it to install the Fouine MCP!"
  *(WL1)*
- **"Copy the request for your assistant"**, under that line: the clipboard
  receives the whole request to paste into the assistant — the command to run
  with the real path of Fouine's command line inside the app, what it
  configures and its options. An assistant told to "install the Fouine MCP"
  used to type `fouine mcp install` and stop at "command not found", the
  command being on the `PATH` only after Settings ▸ Advanced ▸ "Install the
  command-line tool…". `fouine mcp --help` and `docs/mcp.md` now say where the
  command lives too. *(MI1)*
- **`fouine mcp install` configures Codex and Antigravity**, next to Claude
  Desktop, Claude Code and Cursor: a `[mcp_servers.fouine]` table in
  `~/.codex/config.toml` (added or replaced, every other line kept) and the
  `fouine` entry of `~/.gemini/config/mcp_config.json` (or the older
  `~/.gemini/antigravity/` folder). `--client codex` and `--client antigravity`
  target one of them; a client that is not installed is skipped; an entry
  already there keeps the other keys you added to it. For any other client,
  `fouine mcp install --print` prints the server entry to copy (JSON and TOML
  shapes, or `--json` for a script) without touching a file. A page written
  for assistants, [basedpolymer.eu/fouine/mcp](https://basedpolymer.eu/fouine/mcp),
  covers installing the app, the server and an unlisted client; the copied
  request links to it. *(MI1)*

### Changed
- The **What Fouine sends, in detail** button (Settings ▸ Privacy) now opens the privacy page of the website, which carries the same text as `docs/privacy.md`, instead of a GitHub page that returns 404 while the repository is private. *(PV2)*

- **Every sentence in the application and in the guide has been read again, and
  says one thing at a time.** The words of the implementation are gone from what
  you read: "semantic search" is search by meaning, "OCR running — 12 pages
  left" is "12 pages left to read", "the background agent" is background
  indexing, and the model download no longer mentions a GET request or a
  User-Agent header. Ninety-five strings in both languages, and a test that
  refuses the banned words in the catalogue. *(HU1)*
- Fouine is **source-available, not open source**: the code can be read,
  compiled and modified for personal use, and it cannot be redistributed. One
  directory stays MIT, `Sources/FouineMCPKit`, and it has no dependency on the
  rest, which is what makes that MIT real.
- **The command line, the logs and the index error messages are in English**,
  the application is bilingual: a command's output is data, and a script that
  greps it must not break when the Mac changes language.
- **Search by meaning is off until the model is installed**, and the update
  check is off until you turn it on. Nothing reaches the network without a
  gesture.
- **Search by meaning now prepares the pinned folders first.** `roots.pinned`
  only ordered the recognition queue: on a real index, the two pinned folders
  carried exactly zero vectors while a third one, not pinned, was 73 % done —
  the campaign went by document discovery order. It now runs one full phase on
  the pinned folders and then the rest of the index, from the command line and
  from the background agent alike. *(MC3)*
- **Spreadsheets and pages that are tables of numbers no longer get a vector.**
  A vector built from a column of figures is close to every other table and to
  nothing useful, and it took a place in every result by meaning. Those pages
  are counted as done, without inference, and stay findable word for word.
  `embed.skip_spreadsheets` and `fouine embed --include-tables` govern it. *(MC3)*
- **`fouine list --json` now carries `error` and `vectorised_pages`**, the two
  keys the assistant server already published: why a document is missing, and
  how many of its pages search by meaning can see. The table writes the cause
  after the state. *(MC3)*
- **The `year` facet is now `modified_year`, and `doc_year` comes first.** It
  counts the year the FILE was last modified, which its old name did not say —
  on one witness query, 193 of 409 pages fell under the year they were copied
  onto the Mac. `--facet year` is still accepted so no script breaks; the key
  returned is always `modified_year`. *(MC3)*
- **The documentation for contributors is in English** and has been rewritten:
  architecture, tests, strings, pitfalls, agents, contributing, releasing,
  security. The internal specification stays in French. *(DC2)*

- **The documentation for people who use Fouine is in English, sorted and
  halved.** English is now the language of the project: `README.md`,
  `docs/app.md`, `docs/agent.md`, `docs/cli.md`, `docs/mcp.md` and
  `Packaging/INSTALL.md` are rewritten in the present tense, with no batch
  identifiers, no dates and no amendment blocks; `docs/recherche.md`,
  `docs/faq-tcc.md`, `docs/vie-privee.md` and `docs/mises-a-jour.md` become
  `docs/search.md`, `docs/permissions.md`, `docs/privacy.md` and
  `docs/updates.md`. Three pages are new: `docs/formats.md` (every format
  Fouine reads, family by family), `docs/README.md` (the index) and
  `docs/fr/app.md`, the French translation of the in-app guide. The Help menu
  guide now exists in both languages: `bundle.sh` ships `Guide.en.md` and
  `Guide.fr.md`, and `GuideLocator` picks the one matching the language of the
  app, falling back to English. *(DC1)*
- **A search by meaning restricted to a folder that has none no longer spends
  four seconds finding that out.** It used to load the model and the whole set
  of vectors to compare zero of them, then announce the coverage of the entire
  index — 68 % — as though it described that folder. The scope is now read
  first: the answer comes back full text, whole, saying how many of the pages
  searched carry a vector (none) and which command prepares them. *(CL2)*
- **The command line and the assistant now call the same number by the same
  name.** `bm25` sits beside `score` in every result of `fouine search --json`,
  with the same value; `score` is kept for existing scripts and is deprecated.
  The relevance percentage has one shared computation instead of one per
  surface. *(CL2)*
- **Tests no longer assert on wall-clock deadlines they cannot hold.** Three
  measured the machine's load as much as the product: the fuzzy expansion
  budget, the cancellation of an indexing pass, and the age of the agent's last
  report, which failed as «94 ≠ 93» under a second build. They now assert what
  they actually prove — a ratio between a small and a large vocabulary, the
  number of documents processed after the stop, an age range — and the
  network-silence windows wait 300 ms instead of one second, with their
  counter-proof measuring the listener's real latency (10 ms) and failing if
  that margin ever thins. The slowest expressions to type-check in the package
  were also split, which is worth about 50 s of compilation. *(BT1)*

- **Anki decks, Apple Notes and Bear notes look like they do in their app.**
  Fouine copies them into Markdown files to search them, and those files showed
  everywhere: "Organic chemistry.md" under a path inside
  `Library/Application Support/Fouine`, a Markdown icon, "p. 1" and "74 p.".
  A copy now carries the name of its note or deck, the deck path as a
  breadcrumb ("Anki › Chemistry") and the application's own icon — in the
  results, the preview, "All your documents", the menu bar, citations and
  exports — and an Anki deck counts, pages through and cites **cards** ("card
  12", "74 cards", "card 3 of 642"). The preview shows a copy as text only, and
  Quick Look, drag and drop, "Show in Finder" and "Open" give way to "Open in
  Anki", "Open in Notes" or "Open in Bear". The folder of an application has its
  icon in "Your folders" and in Settings; it can no longer be revealed, renamed
  or removed there, since the next update would bring it back, and its menu
  leads to the Applications section where it is turned off. *(AN2)*
- **The command line and the assistant now say the same thing about the same
  results.** When fewer than ten pages carry every word of a question, Fouine
  also shows the pages that carry most of them, and says so; in hybrid mode the
  command line was doing it silently while the assistant announced it.
  `fouine search --hybrid` now announces it too, in its text output and in
  `--json`, and `--no-quorum` still turns it off in both modes. *(MN1)*
- **`fouine list --json` gained `ocr_pages`**, the number of pages of a document
  whose text was read off the image — the last key the assistant's document
  listing had and the command line did not. A page transcribed from a recording
  does not count there. *(MN1)*
- **`fouine embed --folder` no longer hides half of what the campaign does**:
  its help says that spreadsheets stay out of the inference in either case, as
  the documentation already did. *(MN1)*
- **Saved searches can be put in the order you want**: drag one up or down in
  the sidebar, and Fouine keeps the new order. Until now a new saved search
  always went to the bottom, under the ones nobody opens any more. *(MN2)*
- **The "Your index" window follows an update while it is open.** It read its
  counts once, when it opened, and kept showing them unchanged for the whole
  update. They are now read again every ten seconds at most while Fouine is
  working, and once more when it has finished. *(MN2)*

### Fixed
- **`fouine mcp install --folders …` now writes the scope it was given.** The
  `mcp` command declares the same `--folders` option as its `install`
  subcommand, and the parser handed the value to the former, so the scope was
  silently dropped since it was introduced *(IG1)*; the recette now proves the
  three spellings through the binary. *(MI1)*

- **Enter licence key… opens the Licence settings again.** On macOS 14 and
  later, the menu item, the button on the Index card once the trial is over,
  **Manage in Settings…** on an application's folder and **Open Settings** in
  the alert that refuses such a folder did nothing: they asked for the settings
  window in a way macOS no longer honours. They now open the settings window on
  the right tab, whether it was already open or not. *(LB1)*
- **A Mac freed from the customer portal stops being licensed at the next
  check.** The monthly check only looked at the key, which stays active while
  it is used on other Macs, so a Mac released from the portal kept its licence
  forever, and the three-Mac limit protected nothing. The check now looks at
  this Mac's activation too: once it is released, the key is removed from the
  licence file and Fouine says "This Mac was released from your customer
  portal. Enter your key again to use it here." Search keeps working; index
  updates follow the trial again. `fouine license status` runs the same check
  when a key has not been checked for 30 days, and reports `released`. A refused
  activation mentions "3 Macs" only when the activation limit is the reason.
  The behaviour now matches what the seller's service actually answered in a
  full sandbox round trip. *(LC2)*
- **`fouine license deactivate` cleans a Mac that was already released**
  instead of failing with exit 7 and leaving a dead key behind: it says "This
  Mac was already released." and exits 0. *(LC2)*
- **A slow transcription is no longer cut short.** Each ten-minute window of a
  recording had a fixed 30-minute deadline, and on a busy or throttled Mac
  speech recognition can be slower than that: the rest of the window was
  silently dropped and the recording counted as read, never to be tried again.
  Two lecture videos lost more than half of their text this way. A window is
  now given up only when recognition has said nothing for 15 minutes; such a
  recording is listed among the documents Fouine could not read, with a
  sentence that says so, and is read again when its file changes or when
  transcription improves. Recordings already written down are transcribed again
  once. The sentence for an empty transcription no longer asks for a gesture the
  app does not offer. *(BT2)*
- **An assistant is no longer told the background agent is fine when it has
  died.** Two surfaces read the same table and gave opposite answers: the
  command line said the agent was stopped and stale, the assistant said it was
  healthy — in the same breath as the signal that killed it. They now agree.
  "Never set up" stays a healthy state, because turning automatic updating off
  is a choice, not a failure. *(MC4)*
- **Moving or renaming a file no longer costs its text recognition.** The crawl
  recognises the file by its identifier on the volume and only changes the
  path, so a folder of a thousand documents moves in one transaction.
- **Turning off image indexing no longer removes the images already indexed**,
  with the recognised text they carry. The switch stops adding; it does not
  delete.
- **A long recording is transcribed whole.** On-device recognition returns
  speech in one-minute chunks, and only the last one was being kept, so a
  twelve-minute lecture was reduced to its last minute.
- **A copy of the index that will not open says what to do.** An index copied
  without its journal file is refused with the gesture that repairs it
  (`fouine maintain`), instead of an error about a locked database.
- **Counts in the interface are counts.** A formatting mistake could display a
  fifteen-digit number in place of a page count, and never showed the singular.
- **A negative filter now filters.** `-ext:md` and `-name:draft` were accepted
  and did nothing at all: they were searched as words no page carries, so the
  results looked right and were not. *(MC1)*
- **An accent pasted from the Finder finds what the same accent typed finds.**
  Pasted paths carry their accents in another Unicode form, and
  `--path-contains "Polymères"` returned 225 documents typed and 0 pasted.
  *(MC1)*
- **A question asked in plain language inside a folder returns pages.** Any
  filter used to disarm the rule that loosens the AND on all your words, so the
  same nine-word question returned 28 pages on its own and zero under
  `folder:Books`. Function words such as "dans", "with" or "that" are no longer
  required either, and a question with more than six meaningful words keeps the
  six longest instead of giving up. *(MC1)*
- **"None of your words is in your documents" is no longer said when they
  are.** The sentence was printed whenever no single page carried them *all*,
  even when a word was in twenty-two documents of the folder being searched.
  Fouine now names the words the index carries. *(MC1)*
- **A result found through a close spelling says so.** Widening happens in the
  ordinary pass as soon as the exact search matches few pages, and nothing in
  the reply mentioned it (`fuzzy_expanded` in JSON). Over the whole library the
  tolerated distance now follows the length of the word — `Kenvue` returned 125
  pages carrying "kenne" and "cevue" — while scanned pages, where the machine
  makes the mistakes, are unchanged. *(MC1)*
- **A result that carries only some of your words no longer claims to carry
  them all.** "Why this result" said *exact*, listing nine words, on a page
  holding three. *(MC1)* The assistant server said it too, in both of its
  search modes. *(MC2)*
- **Search by meaning inside a folder that has none says so, and stops
  wasting six seconds on it.** The vector campaign fills the index in the order
  documents were discovered, so one folder can be complete while another has
  nothing; a search restricted to the second compared no vector at all, loaded
  the model for nothing, and reported the coverage of the whole index (68 %) for
  a folder covered at 0 %. Coverage now describes what was actually searched,
  and a scope without a single vector answers in full text, names the folder and
  the command that would prepare it. *(MC2)*
- **The file-name channel obeys the filters of the query.** Asking for
  transcriptions only still returned five PDFs beside the results, by their
  name; the language, the date and the document filters were ignored there too.
  *(MC2)*
- **An invalid parameter now says what the valid ones are, where the assistant
  reads it.** The list of accepted values was carried in a field many clients
  never show, leaving the model with "Invalid params" and nothing to correct.
  *(MC2)*
- **The assistant's search tool documents the whole query language.** Three
  filters that exist and are documented elsewhere — search in file names, in
  page text, or in the whole path — were missing from the only description a
  model ever reads, along with the four negative filters. *(MC2)*
- **A long Apple Notes or Bear note offers "Open in Notes" on every page.** The
  button read the page on screen, and only the first page of a copied note says
  where it comes from: from the second page on, the preview offered "Show in
  Finder" on Fouine's own copy instead. *(AN1)*
- **Choosing Anki's, Apple Notes' or Bear's own folder says where to go.**
  "Add a folder…" on `~/Library/Application Support/Anki2` answered that
  `~/Library` is a system folder holding no documents, with nothing but "OK".
  The folder is still not added, but the alert now says to turn the application
  on in Settings ▸ Folders, under "Applications", with an "Open Settings" button
  that opens that tab; `fouine root add` names `fouine sources enable <id>`.
  *(RP1)*

- **Searching "anki" no longer finds the first card of every deck.** The two
  technical lines at the top of a copied note or deck (the name of the source,
  the reopening link) were indexed like text: "anki", "source" or "fouine"
  matched page 1 of every copy, and the excerpt of an Anki deck's first card
  began with "…anki -->". They stay in the file and no longer reach the index.
  The name of a deck is no longer written above its first card either, where
  every word of it made that card match; a deck is found by its name, like a
  file. The next update rewrites the decks and reads them again. *(AN2)*
- **Excluding a filter that cannot be excluded is refused instead of doing
  something else.** `-type:pdf` was accepted and quietly excluded the phrase
  "type pdf": it did not drop the PDFs that were asked for, and could drop a
  document that happened to carry those two words in a row. Writing it, or
  `-text:word`, or `-near:5`, is now refused naming the four filters that can be
  excluded — a folder, an extension, a name, a path. And when a query typed on
  the command line starts with a `-`, the refusal that follows now prints the
  form that works (`fouine search -- '-ext:md nitrogen'`) instead of leaving a
  bare "unknown option". *(MN1)*
- **Two kinds of perfectly readable file are no longer skipped as "data
  dumps"**: a Markdown file carrying its pictures inline (what Typora and
  Obsidian export) and a compacted JSON export. A two-paragraph meeting note was
  refused whole because of the picture in it. A column of base 64 with nothing
  around it is still skipped, which is what the rule was for. *(MN1)*
- **An assistant restricted to some folders (`fouine mcp --folders`) no longer
  names languages from the rest of the index** when it refuses an unknown one.
  It returned no document, but it taught the assistant that there was something
  behind the scope. *(MN1)*
- **Excluding a filter that cannot be excluded gets its own refusal.**
  `-texte:nitrogen` or `-near:5` was refused as "not a filter", which is untrue:
  `texte:` is one, it just cannot be excluded. The app, the command line and the
  assistant now say "“texte:” cannot be excluded", name the filters that can,
  and give the gesture that leaves out a word (`-word`). `-type:pdf`, which is
  not a filter at all, keeps its refusal. *(MN2)*
- **The line "Few pages carry all your words" now appears when search by
  meaning is on.** Fouine showed the pages carrying most of the words in that
  mode too, but the app never said so. *(MN2)*
- **The text preview no longer keeps the previous page on screen** when two
  pages have text of the same length and the same search words (twin Anki
  cards, sheets of a spreadsheet). *(MN2)*
- **Next and previous occurrence follow the reading order on a rotated page.**
  On a scan straightened by 90° or 270°, ⌘G jumped around the page. *(MN2)*
- **Counts are grouped the same way on one line**: «1 527 documents · 408 951
  pages», no longer «1527 documents · 408 951 pages». *(BU-07, MN2)*
- **The app no longer logs "Using your own bundle identifier as an
  NSUserDefaults suite name" at every launch.** Inside its bundle it reads its
  preferences from the standard domain, which is the same file. *(BU-29)*

### Security

- **Nothing leaves the Mac while Fouine indexes, reads or searches**, and that
  is held by a test rather than by a claim: a local server listens while a pass
  indexes deliberately trapped documents (`.doc`, `.rtf`, `.html`,
  `.webarchive`, `.epub`, `.docx`, `.pdf`, `.svg`, two media containers), and
  the assertion is zero connections. Four outbound connections exist, all
  named, three of which wait for a gesture: the model download, the update
  check, licence activation or release, and the silent licence check (at most
  once every 30 days, and only when a key is present).
- **A trapped archive can no longer turn an entry name into a tool option.**
  Names read inside a user-supplied archive are separated from the options, and
  the external tools run with a fixed environment, with a cap on the
  decompressed volume, and with no shell.
- **A `fouine://` link can no longer offer to open anything.** The gesture is
  bounded to what Fouine could have indexed: an ordinary file, under a followed
  folder, not executable.
- **The model download verifies its SHA-256 before installing anything**,
  follows redirects only in `https:`, and caps the transfer in flight at twice
  the announced size.
- **The MCP server is read-only and proved to be**: it never writes, never
  starts an indexing pass, never returns the original files, and opens no
  connection.
- The application runs under the **hardened runtime with an empty entitlements
  dictionary**; the index, the logs and the licence file are written with
  restrictive permissions; and the background agent's plist stays inside the
  bundle rather than in `~/Library/LaunchAgents`.
- **A Markdown file can no longer pass itself off as a copied note.** Any `.md`
  in an indexed folder could declare itself an Apple Notes or Bear copy in its
  first lines and give the preview an "Open in Notes" button that opened a link
  of its choosing, a `file://` application included. A copy is now recognised
  by where it lives — Fouine's own copy folder — and its link must use its
  application's scheme (`notes:`, `bear:`). *(AN2)*

[1.0.1]: https://github.com/basedpolymer/fouine/releases/tag/v1.0.1
[1.0.0]: https://github.com/basedpolymer/fouine/releases/tag/v1.0.0
