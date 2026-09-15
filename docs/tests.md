# Testing Fouine

For contributors: what runs, where, with what, and why some of it skips.
`git clone && make test` exercises the product on a real corpus (formats,
indexing, search, OCR, schema creation, packaging). What stays optional (the
maintainer's personal corpus, the 220 MB semantic model) skips cleanly and says
what to do about it.

- [Build and test fast](#build-and-test-fast)
- [The suites](#the-suites)
- [The versioned fixture corpus](#the-versioned-fixture-corpus)
- [The two regimes of the integration recipe](#the-two-regimes-of-the-integration-recipe)
- [Schema creation](#schema-creation)
- [The semantic model](#the-semantic-model)
- [The gate, and continuous integration](#the-gate-and-continuous-integration)
- [Rules for writing a test](#rules-for-writing-a-test)
- [What is not tested, and why](#what-is-not-tested-and-why)

---

## Build and test fast

Every minute of compilation is paid on every iteration, so run **the suite you
touched**, not the whole gate.

```sh
swift build --build-tests                    # once: everything, tests included
swift test --filter FouineCoreTests          # ONE suite; rebuilds what changed
swift test --skip-build --filter FouineAgentTests.AgentTests   # one class, no rebuild
make release-cli && swift test --filter IntegrationTests       # the CLI recipe
./Tools/l10n-lint.sh                         # after any visible string
make check-docs check-changelog              # after any doc or CHANGELOG change
```

| Touched | Run | Alone |
|---|---|---:|
| `Sources/FouineCore/Store`, `Schema.swift` | `FouineCoreTests`, then `make ci-unit` and `make ci-integration` before merging | 21 s |
| `Sources/FouineCore` (query, settings, lock) | `FouineCoreTests`, `FouineIndexTests` | 21 s |
| `Sources/FouineCrawl` | `FouineCrawlTests`, `FouineIndexTests` | 6 s |
| `Sources/FouineExtract` | `FouineExtractTests`, then `make ci-corpus` | 3 to 6 min |
| `Sources/FouineOCR` | `FouineOCRTests`, `FouineIndexTests` | 36 s |
| `Sources/FouineIndex` | `FouineIndexTests`, `FouineAgentTests` | 8 s |
| `Sources/FouineEmbed` | `FouineEmbedTests`, `FouineMCPTests/SemanticModelTests` | 20 s |
| `Sources/FouineLicense` | `FouineLicenseTests` | 2 s |
| `Sources/FouineMCPKit`, `Sources/FouineMCP` | `make ci-mcp`, plus `docs/mcp.md` and `Packaging/mcpb/manifest.json` when a tool changes | 19 s |
| `Sources/FouineApp` | `FouineAppTests`, plus `./Tools/l10n-lint.sh` when a string changes | 25 s |
| `Sources/FouineApp/Resources/Localizable.xcstrings` | `FouineAppTests/L10nTests`, `./Tools/l10n-lint.sh`, then `make ci-bundle-i18n` | 25 s |
| `Sources/FouineAgent` | `FouineAgentTests` | 2 s |
| `Sources/fouine` (CLI) | `make release-cli && make ci-integration`, the only test of the CLI | 3 min + build |
| `Tests/Fixtures/corpus`, `Tools/make_fixtures.swift` | `make ci-corpus` | 30 s |
| `docs/`, `CHANGELOG.md` | `make check-docs check-changelog` | < 1 s |

`FouineExtractTests` is minutes, not seconds, and one test is nearly all of it:
it transcribes 99 seconds of synthesised speech with on-device recognition (see
«Where the time goes»). When what you touched is not the media path,
`swift test --skip-build --filter FouineExtractTests.<Class>` is the honest
shortcut.

The «alone» column is the serial run of that suite on a warm bundle, measured
on 14/09/2026 on an i5-8257U (4 cores, 8 threads, 8 GB, Swift 6.2.3) **while a
second build was running on the same machine** — which is the normal state of
this project. On a free machine, halve them; the ranking is what matters, not
the absolute value.

Four things about the build worth knowing.

**`swift test --filter X` still compiles every test target.** SwiftPM links all
of them into a single bundle, `FouinePackageTests.xctest`, and `--filter` only
sorts at run time. `--skip-build` reruns without rebuilding. `swift build
--target FouineCore` compiles one library alone (useful for a syntax error) but
does not produce anything runnable.

**`make release-cli` passes `--product fouine`**, so it builds the engine and
the CLI without linking `FouineApp` or `FouineAgent`. That binary is enough for
`IntegrationTests`, `ci-corpus` and `ci-mcp`. Cold, it is 327 s here (under a
second build); after it, `make ci-bundle ARCHS=$(uname -m)` adds only
`FouineApp` and `FouineAgent`, 195 s, because both write to the same
`.build/x86_64-apple-macosx/release` — see the gate section.

**`IntegrationTests` drives the release binary** `.build/release/fouine`.
Without `make release-cli` first, the whole recipe skips **green**.

**A SIGBUS in a search test is a stale incremental build**, not a bug: after a
merge that changes a shared public struct (`Contracts.swift`, `Settings.swift`,
`GRDBStore`), purge `.build/debug`, `.build/release` and
`.build/x86_64-apple-macosx/{debug,release}`, or run `make gate PURGE=1`.

### Where the time goes

Measured on 14/09/2026, same machine, with a second build running: every suite
alone and in series (`swift test --skip-build --filter <Suite>`), and a clean
build under `-warn-long-function-bodies=150
-warn-long-expression-type-checking=150`. Absolute values move with the load;
the ranking does not.

**Execution.** The ten unit suites run 2 058 tests in about 270 s in series,
and **one test is 40 to 60 % of that**:

| Test | Alone | Why it costs that |
|---|---:|---|
| `MediaExtractorTests.testSpeechLongerThanAMinuteIsWrittenDownWhole` | 111–272 s | `say` synthesises 99 s of French speech, then on-device recognition transcribes all of it. The defect it fences (only the last minute of each ten-minute window was kept) does not show on a shorter recording. |
| `MediaExtractorTests.testStopDuringAWindowRaisesTheNamedCase` | 8 s | two minutes of audio, stop asked two seconds in |
| `MediaExtractorTests.testRecordingLongerThanTheCapNamesTheCap` | 3–13 s | same synthesis, then the refusal that names the cap |
| `ImageExtractorTests.testRealOCRRecognizesTextOnStandaloneImage` | 2–8 s | real Vision OCR on a real image |
| `QuantizerTests.testCosineSurvivesQuantization` | 2.7 s | 2 000 pairs of 384-dimension unit vectors quantised and compared — the arithmetic in a debug build, *not* the 2 000 assertions (removing them changed nothing, measured) |
| `T6FixtureTests` (two tests) | 3–5 s each | real OCR on a real scan; they skip without `Tests/Fixtures/paths.json` |
| `RendererTests.testRenderGiantStandaloneImageIsBounded` | 3.7 s | renders a deliberately enormous image to prove the budget holds |
| `FSEventsWatcherTests.testAQuietRestartOnAValidCursorAsksForNothing` | 3.4 s | 0.4 s for `fseventsd` to hand out an id, then an **inverted** expectation, which by construction waits its whole 3 s |
| `RealModelTests.testTokenizerParity` | 3.4 s | loads the real CoreML encoder (shared, once per suite) |
| `SchemaCreationTests.testAFreshDatabaseIsCreatedAtTheCurrentSchema` | 2.3 s | creates the whole schema, FTS5 tables included |

**The speech tests take turns, and fail instead of hanging.** The four tests
that run `say` or on-device recognition — the three above and
`testTranscriptionOfSpokenAudio` — first take a file lock,
`fouine-tests-speech.lock` under `NSTemporaryDirectory()`: under `--parallel`
each test is its own process, and only a file lock orders processes. The body
then runs on a thread of its own under a watchdog, 600 s for the long test and
90 s for the others, counted once the lock is held. The long test's budget was
300 s until a pass at a load average of 159 turned it red while recognition was
still producing text, at least six times slower than on a quiet machine (49 s). When the watchdog falls,
the running `say` is killed, the test fails with the step it had reached and
the load average, and the lock is released. On 14/09 three of them started
together at a load average of 361 and sat at 0 % CPU for 24 minutes. One of
the three never starts a recognition — its only unbounded step is `say` — and
the three `say` processes were found four hours later, orphaned and still
waiting on a message from the synthesis service; a SIGTERM ends one at once.
The hang was upstream of recognition, where `FOUINE_SPEECH_TIMEOUT` does not
reach: that deadline bounds the wait for an answer once the audio is in, not
the synthesis, nor the synchronous Speech calls before it.

Two rules come out of that list. **Real work is the cost** — speech
recognition, Vision, CoreML, SQLite — and it is the proof, so it stays.
**A proof of a negative costs its whole window**: an inverted expectation, or
the network-silence windows of `NetworkSilenceTests`, wait on purpose. Keep
those windows short and let one measured test guard the margin — that file's
counter-proof measures how long the listener really takes to see a connection
(10 ms) and fails if it ever approaches the window (300 ms).

**Compilation.** A clean `swift build --build-tests` is 247 s here (384 s with
the two warning flags on, which is their cost, not the build's). Type-checking
function bodies over 150 ms totals about 116 s of CPU across the package, and
it concentrates:

| File | Bodies > 150 ms | Worst one |
|---|---:|---|
| `Tests/FouineExtractTests/TextEncodingTests.swift` | 35.4 s → 0 | one line: `Array("l".utf8) + [0x92] + [0x9C] + Array("uvre".utf8)`, 34.5 s |
| `Sources/FouineApp/Views/ResultsView.swift` | 13.2 s | `hitRow` 8.6 s |
| `Sources/FouineCore/Query/GRDBStore+Search.swift` | 10.5 s → 2.0 s | `searchOnce` 5.5 s, all of it one `StatementArguments(…)` concatenation |
| `Sources/fouine/CommandsConfig.swift` | 7.9 s → 0 | `canonicalOCRLanguages` 5.9 s, a five-part `+` of strings |
| `Sources/FouineApp/Views/ContentView.swift` | 4.1 s | `body` 3.5 s |
| `Tests/FouineEmbedTests/EmbedTests.swift` | 2.9 s → 0.8 s | `reduce(0, +)` on untyped literals |
| `Tests/FouineEmbedTests/RankFusionTests.swift` | 2.7 s → 0.8 s | `1 / 62 + 1 / 66` inside an assertion |
| `Tests/FouineExtractTests/LegacyOfficeBuilder.swift` | 2.7 s → 0.3 s | `UInt8(value & 0xFF)` four times in one array literal |

The pattern is always the same, and it is **not** the size of the function: a
chain of `+` over untyped literals, or a heterogeneous array literal, makes the
type-checker try every overload. The fix is to name the type once — a `let`
with an annotation, a string interpolation instead of `+`,
`UInt8(truncatingIfNeeded:)` instead of a mask. Those six files went from 62 s
to 4 s that way, and the package total from 116 s to 54 s; untouched files vary
by up to a fifth between two builds, so trust the per-file column, not the
total. `Sources/FouineApp/Views` is untouched and is now the largest remaining
share.

**What actually saves time, verified.**

- Run the suite you touched, in series. `swift test --skip-build --filter
  <Target>.<Class>` runs one class without rebuilding: `FouineCoreTests` alone
  is 21 s, `FouineCoreTests.FuzzyTests` under 2 s.
- Touching one test file and rebuilding is 13 s (recompile plus the link of
  `FouinePackageTests`); touching `Sources/FouineCore` rebuilds everything that
  depends on it, so expect two to four minutes under load.
- `make ci-unit` cannot go below its slowest process, because `--parallel`
  runs one process per test (2 058 tests, 0 failures, 460 s measured on 14/09
  under a second build; the speech test alone was 272 s of it, with three
  recognitions overlapping). Since the speech tests queue behind one file lock,
  that floor is their sum rather than the longest of them: 57 s in series at a
  load of 3, 49 s of it for the long test. `swift test --parallel --filter
  FouineExtractTests` then ran three times in a row in 66, 85 and 83 s, 308
  tests, 0 failures. `make ci-integration` is 123 s for 142
  tests, 31 of them skipped without the personal corpus, and `make ci-corpus`
  31 s for 35.
- Avoid a second compilation on the machine. It is the single biggest factor in
  every number on this page.

## The suites

| Suite | Tests | What it covers |
|---|---:|---|
| `FouineCoreTests` | 519 | schema creation and the refusal of every other version, store, query parsing (path filter, filter exclusions, NFC, quorum under filters), search and its ranking bonuses, fuzzy matching (distance cap by scope), transcript moments, page layout, hit relevance, `fouine://` links, the language, date and provenance filters, backup and maintenance, the named lock, read-only opening in its three awkward cases, the disk budget projection, the status objects three surfaces share, the printed page number of a PDF, the exclusion rules kept per root (and the column a v9 index only receives with its first rule) |
| `FouineCrawlTests` | 100 | walking, root policy, FSEvents lifecycle and stress, build-folder exclusion under a project, `Name.mbox/` packages, the `.fouineignore` rules (pure, then on a real crawl: an excluded document leaves with its vectors), the rules kept by Fouine (validated when typed, united with the file, applied without it) and the event a hidden file raises |
| `FouineExtractTests` | 302 | the 114 extensions, the 19 images under `extract.images` and the 19 media under `extract.media` (metadata, named refusal without ffmpeg, on-device transcription, ten-minute windows), mail attachments, guards, deadlines, the versioned corpus, network silence |
| `FouineOCRTests` | 63 | Vision, page rendering (webp, psd, animated gif, Sketch and Figma previews), thermal governor, deadlines, cancellation |
| `FouineIndexTests` | 122 | the shared indexing pass, OCR priority, pinned roots, Spotlight donation against a fake donor, language catch-up at the end of a pass, Apple Notes, Bear and Anki against SQLite bases built at the real schema (an Anki collection held open in WAL mode), a copy recognised by where it lives and named as in its app, a rule kept in the settings taking a document and its vectors out of a real pass |
| `FouineEmbedTests` | 131 | quantisation, vector index, RRF, `EmbedRun`, semantic windowing, lock released per batch, model download, parity with the Python reference, a page encoded on the fly byte for byte like the campaign |
| `FouineAppTests` | 546 | the pure models behind the window: `SearchModel`, sorting, export, facets and restored session, preview, the single index state, the deep-link router, the menu-bar search, Shortcuts actions, uninstalling, the licence model, the “What Fouine skips…” sheet, plus accessibility and localisation |
| `FouineAgentTests` | 68 | the pure state machine, transitions, the §5.7 conditions, the 0o600 log, `agent_status`, the trial guard, the roots walked again when their kept exclusion rules change |
| `FouineMCPTests` | 176 | stdio framing, `stdout` hygiene, thirteen golden transcripts, read-only proved on all five tools, pagination, response budget, semantic fallback, the search parameters (`since`, `fuzzy`, `facet`, `compact`, `marks`), citation fields, semantic scope, network silence, the `.mcpb` manifest against `tools/list`, client configuration, the agent verdict and the per-root coverage, `encode_if_missing` and `compact` on neighbours, the `--folders` scope (served roots, refusals naming only them, an out-of-scope document unknown, exact pagination across roots) |
| `FouineLicenseTests` | 31 | the five licence states, the file (atomic write, unreadable counts as absent, clock moved back), the monthly check, the relay client behind a stand-in `URLProtocol` answering the bodies Creem really returned in its sandbox (`CreemReplies.swift`) |
| `IntegrationTests` | 142 | the recipe: the CLI driven by `Process`, `read` and `similar`, `search --mark`, the citation keys and `bm25` of `search --json`, `--hybrid-auto`, `similar --encode`, `mcp --folders`, `root list ignore_rules`, `root ignore add`, `remove` and `list`, named refusals in 64, `status --unreadable`, a copy without `-wal` repaired by `maintain`, `ocr` under lock exiting 3, semantics disarmed end to end |

The ten unit suites make **2 058 tests** and are what `make ci-unit` runs, in
`--parallel`; `IntegrationTests` counts separately, as `make ci-integration`. Counts are refreshed at the end of a
session, after a green gate, not on every change.

**Skips are expected, and each says what to do.** Three unit tests skip
everywhere: `P8RealVocabularyTests` (wants `FOUINE_P8_DB`), the DjVu test that
exists only for a missing djvulibre, and `PDFExtractorTests.testRealCorpusBookIfPresent`
(wants `FOUINE_TEST_DB` on top of `Tests/Fixtures/paths.json`, because ten
seconds of extracting a 600-page book do not belong in every run). The three
`T6FixtureTests` skip wherever `paths.json` is missing, which includes a fresh
worktree, since the file is gitignored. On the CI runner, where the semantic
model is absent, there are ten more unit skips and five more integration skips;
`.github/workflows/ci.yml` lists them in its header.

`make ci-unit` runs in `--parallel`, whose log carries neither per-test
durations nor the `Executed N tests, with M skipped` line. To time a test or
count skips, run the suite alone and in series.

### Where a CLI regression test goes

**In `VersionedCorpusTests`.** It is the only integration suite that runs
everywhere: its corpus is in the repository (`Tests/Fixtures/corpus/`), so
`git clone && make ci-integration` runs it on any machine.

| Suite | What makes it run | What goes in it |
|---|---|---|
| `VersionedCorpusTests` | nothing (versioned corpus) | every CLI contract regression: exit code, JSON key, refused argument, observable behaviour |
| `StatusContractTests`, `MaintenanceRecetteTests` | nothing | the `--json` contract of `status` and `doctor`, backup and maintenance |
| `CorpusSearchTests` | `FOUINE_TEST_DB` | what really needs a large real corpus: ranking, volume, latency |
| `OCRRecetteTests` | `FOUINE_TEST_DB` | OCR on real scans |

`CorpusSearchTests` and `OCRRecetteTests` need the maintainer's personal
corpus, an opt-in that is absent from CI and from a contributor's worktree: an
assertion written there **skips** in silence, and a test that skips proves
nothing. The lesson was paid for once, when a regression test for a negative
`--limit` was written there, was inert, and had to be moved.

There is **no test target for the `fouine` executable**: the integration recipe
is its test, since it runs the real binary and reads its `--json` output and
exit codes. A unit target on the CLI would test the least interesting subset.

## The versioned fixture corpus

`Tests/Fixtures/corpus/` holds 39 files and packages (42 indexable documents,
392 KiB), in the repository. The manifest
[`Tests/Fixtures/corpus/manifest.json`](../Tests/Fixtures/corpus/manifest.json)
describes each one, file by file, with its witness terms, expected pages and
target state in `docs`; the tests read it and it is authoritative. The
[folder README](../Tests/Fixtures/corpus/README.md) explains its fields.

It exists because everything the recipe could do on a real document used to
depend on `Tests/Fixtures/paths.json`, which is gitignored and names the
maintainer's personal corpus: on any other machine those tests skipped **green**.

What it covers: a PDF with a text layer (six query forms on its own), a
**scanned** PDF with none, txt/md/csv/log/tex/json, html/htm, rtf,
docx/xlsx/pptx/odt, epub, cbz, djvu, and three traps (a hostile archive, two
OLE formats refused cleanly, an extension outside the registry that must not
enter `docs`).

```sh
make fixtures                              # -> Tests/Fixtures/corpus
make fixtures-media                        # -> Tests/Fixtures/media (sound and video)
swift Tools/make_fixtures.swift /tmp/elsewhere
```

Four things to know about regenerating them.

1. **The generated files are committed.** The tests read them as they are and
   never call the generator: a contribution must run without it.
2. **It is not reproducible byte for byte.** CoreGraphics stamps every PDF with
   a creation date and `zip` with a modification date, so `git status` shows
   every binary modified after `make fixtures`, even with no change of content.
   That is why the manifest describes expected **content** (witness terms,
   pages, `native`/`ocr_accurate` provenance, `docs.state`) and never a digest.
3. **djvulibre is optional.** Without it, `notice.djvu` is not produced, the
   manifest carries `"requires": "djvulibre"`, and the tests concerned skip
   while naming `brew install djvulibre`.
4. **Sound and video live apart.** `Tests/Fixtures/media/` (`voix.aiff`,
   `voix.m4a`, `clip.mp4`) is versioned but outside the manifest, like the
   images: the family enters only under `extract.media`, which the recipe does
   not turn on, so a media fixture in `corpus/` would never be indexed and
   would skew its counts.

The manifest is the single source: a file added to the folder without an entry,
or an entry without a file, fails `FouineExtractTests.CorpusFixturesTests`. To
add a fixture, edit `Tools/make_fixtures.swift` (the content **and** the
manifest entry, side by side), run `make fixtures`, then `make ci-corpus`, and
commit the generator together with the regenerated files.

One writing rule: **disjoint vocabularies**. A witness term must appear only
where the manifest says it does, which is what allows an assertion of the form
«this term, in this file, on this page». The two existing repetitions are
deliberate and tested («markovnikov» on two pages, for phrase search;
«polymere» in two documents, for exclusion, which applies to the *document*).

## The two regimes of the integration recipe

`Tests/Integration/` drives the `fouine` binary through `Process` and asserts
only on `--json` output, exit codes and the state of the base, never on a CLI
sentence.

**Disposable base, the default, nothing to install.** Each test builds its own
base and its own root in a temporary folder, then indexes.
`Recette.makeIndexedScratch` gives a root of synthetic `.txt` records plus the
nuisances the crawl must skip (`._*`, `.DS_Store`, `.git/`, a `.pages`
package), for what tests the *product*: crawl hygiene, the `status` contract.
`Recette.makeIndexedCorpus` gives the versioned corpus, copied outside the
repository, for what tests *formats*, OCR and query forms. That is all a
contributor needs.

**Full corpus, on explicit opt-in.** What only makes sense on the real corpus
(performance thresholds, OCR benches) requires `FOUINE_TEST_DB`, which must
name a **copy** of the base:

```sh
sqlite3 "file:$HOME/Library/Application Support/Fouine/fouine.db?mode=ro" \
        ".backup /tmp/fouine-recette.db"
FOUINE_TEST_DB=/tmp/fouine-recette.db make test
```

Without the variable those tests **skip**. With a variable that names the
**production** base, the recipe **refuses** to run, with a hard failure: it
would reindex the corpus there and consume the OCR queue while the agent writes
into it. They will never run in CI, which is deliberate: a performance
threshold measured on a shared runner would mean nothing.

> **No test writes into your production base, in either regime.** Every factory
> prints the path of its disposable base in the output of `make test`, so the
> guarantee is checked at a glance in the log rather than by reading the code.

## Schema creation

There is no schema migration: no old-base fixture, no migration suite, no
migration chain. `FouineCoreTests.SchemaCreationTests` (14 cases) proves, on
disposable bases:

- a new base is born at the current schema, with its sixteen tables,
  `ocr_layout` on the structured rowid, the windowing geometry in `vec_meta`,
  `integrity_check` at `ok`, and every table empty;
- it is usable immediately: settings written and read back, agent state
  published;
- a base at any earlier schema is refused, for EVERY earlier version, with the
  gesture («delete it and index again»), without promising a migration that
  does not exist, and **without the refused base being touched**;
- a base at a newer schema is refused with the OTHER gesture (update the
  binary): confusing the two would destroy an index that an update was enough
  to open;
- read-only opening refuses with the same sentence, which is the one the MCP
  server writes on `stderr`;
- creation takes the named lock and opening an up-to-date base does not,
  otherwise `search`, `status` and `doctor` would fail during indexing;
- reopening is idempotent: `created_at` does not move and the data stays;
- moving a document erases nothing: pages, OCR layer, queue and vectors follow
  the `doc_id`, and swapping two paths fits in one transaction;
- vector invalidation follows the window rowid: rewriting a page takes its
  three windows, sentinel included, and nothing else;
- search answers on the base thus created: native, OCR, accent fallback.

Bases «at another schema» are built inside the test by `/usr/bin/sqlite3`: a
`meta` table and one `schema_version` row describe everything the store looks
at before deciding. No fixture to version, therefore no fixture to maintain.

## The semantic model

The e5 model (`multilingual-e5-small` converted to CoreML) weighs 220 MB. It is
not in the repository and never will be.

```sh
fouine model download            # 220 MB, from the release asset
fouine model status --json       # `installed`: the gate the tests read
```

Without it, **14 tests skip**: the 3 parity tests and the floor test of
`FouineEmbedTests`, the 3 of `FouineMCPTests.SemanticModelTests`, the 2 seeded
semantic journeys of `FouineAppTests.SeedTests`, and the 5 of
`IntegrationTests.HybridCorpusTests`. Everything else runs, deliberately:
semantic fallback, lazy loading and the MCP server's network silence are all
about the model's absence, so they are proved without it.

To work on a copy without touching the installation:

```sh
FOUINE_MODEL_DIR=/tmp/e5 fouine model download --url file:///path/e5-small-v1.zip
FOUINE_MODEL_DIR=/tmp/e5 make ci-unit
```

CoreML loading costs about 2,5 s on an i5, so **each suite loads the model once
per process** and shares it (`sharedRealEncoder()` in `FouineEmbedTests`,
`fixtureEncoder` in `SemanticModelTests`, `SharedModel.encoder()` in
`FouineAppTests`). The exception is the test that exercises loading itself,
`SemanticModelTests.testTheModelIsLoadedOnceAndOnlyWhenNeeded`, which measures
the server's own load. A new test that needs the real model takes the shared
instance; it builds one only when it tests `E5Encoder(modelDir:)`.

In CI the model comes from `actions/cache`, keyed by its **expected SHA-256**,
so changing model changes the key and therefore the cache without anyone
remembering to invalidate it. Failing that, `fouine model download` writes into
a `FOUINE_MODEL_DIR` **under the workspace**, never into the runner's
`~/Library`. A missing asset is not a failure: while the asset is unpublished
the download returns 404, and the step warns (`::warning::` plus a note in the
job summary) and exits 0. A red job for a file the maintainer has not published
yet would teach reviewers to ignore red.

## The gate, and continuous integration

`make gate` runs the four lines below in order and stops at the first red one.
Use `make gate PURGE=1` after a change to a shared public struct.

```sh
make check-docs && make check-changelog && make check-ranking && make check-l10n
make ci-unit                       # the ten unit suites in --parallel
make release-cli && make ci-integration
make ci-bundle ARCHS=$(uname -m) && make ci-bundle-i18n
```

`make check-l10n` runs the Python tests of the localisation tools
(`Tools/l10n/test_lint.py`: the lint's extraction, French typography,
`add-strings.py` recognising a key by its whole line), then
`./Tools/l10n-lint.sh`. The gate calls it in place of the bare lint: until
14/09/2026 no target ran those tests, and a broken tool went unnoticed until
the day it was needed.

**The gate compiles release once, and only if `ARCHS` is your own
architecture.** `make release-cli` and the `release-build` behind `ci-bundle`
pass the same `CONST_VALUES_FLAGS` and, for a single native `--arch`, write to
the same `.build/x86_64-apple-macosx/release`: measured on 14/09/2026, a `make
ci-bundle ARCHS=$(uname -m)` right after a cold `make release-cli` recompiles
`FouineApp` and `FouineAgent` and nothing else. Drop the `ARCHS` and the
default is universal, which builds a second tree under
`.build/apple/Products/Release` — five minutes of engine you did not need.

`.github/workflows/ci.yml` has three jobs. `test` runs on every push and pull
request: `make check-version`, `check-docs`, `check-changelog`, `check-ranking`
(the bench scripts on a fabricated pool), `swift build`, `make release-cli`,
the semantic model on a best-effort basis, `make ci-unit`, `make
ci-integration`. `bundle` runs `make ci-bundle` (bundle, `plutil -lint`, `lipo
-archs`, ad-hoc signature) and `make ci-bundle-i18n`. `release-tests` runs
`make ci-unit CONFIG="-c release"` on `main` only.

**The commands live in the `Makefile`, not in the YAML**, so the CI reproduces
locally: `make ci-unit`, `make ci-mcp`, `make ci-integration`, `make ci-bundle
ARCHS=$(uname -m)`, `make ci-bundle-i18n`.

Why a release pass on `main` alone: `make ci-unit` takes 61 s in debug and
250 s in release, for 3 s of execution saved, and almost all of the difference
is compilation that every pull request would pay. That pass caught nothing the
day it was added; it is there for what only it can find, since `assert`
disappears in release while `precondition` stays, and `Schema.ftsRowID` relies
on a `precondition` to refuse a rowid that would belong to the next document.

## Rules for writing a test

- **Never assert on prose.** New assertions are about `--json` output, exit
  codes and the state of the base. CLI wording changes; a recipe that broke on
  a translation would not be testing the product.
- **Never use unseeded randomness.** A test that draws lots must draw the same
  lot everywhere (`SeededGenerator` in `FouineEmbedTests`, an explicit seed
  elsewhere). A test that is red one time in ten is noise people learn to
  ignore.
- **A skip always names the gesture.** `XCTSkip("model missing — `fouine model
  download` installs it")`, not `XCTSkip("preconditions not met")`.
- **A missing repository file is a failure, not a skip.** `manifest.json` is
  versioned, so its absence is a regression. `paths.json` and the model are
  personal, so their absence is a machine precondition.
- **One counter-proof per strong claim.** «This term appears on this page»
  holds only if it is also shown NOT to appear elsewhere; «the hybrid finds
  this page» holds only after showing that full text does not.
- **A test that proves a lock refusal uses `lockTimeout: 0.3`**, never the
  default five seconds.
- **Application tests write into a disposable preferences domain**, named after
  the process pid (`TestPrefs.isolate`, called by `TempAppDB.init`). They used
  to write into the real `io.github.basedpolymer.fouine.plist`: in `--parallel`
  the session remembered by one test was read back by another, and the
  machine's search history filled up with test queries. A test that touches
  `Prefs` without going through `TempAppDB` calls `_ = TestPrefs.isolate` in
  its `setUp`.

Suites can run in separate processes because each test builds its base and its
folder under a UUID (`TempDB`, `TempIndex`, `TempStore`, `TempAppDB`,
`IndexScratch`), the network-silence listeners take an ephemeral port, and the
`setenv` calls (`FOUINE_PDF_TIMEOUT`, `FOUINE_OCR_TIMEOUT`, `FOUINE_MODEL_*`)
are undone in a `defer`. The CoreML model is read, never written.

## What is not tested, and why

- **`Agent.start()` in a real daemon environment.** The infinite loop under
  `launchd` needs an installed LaunchAgent. Its decision logic and state
  transitions are extracted into a pure state machine (`Agent.tick`,
  `Agent.postBatchTick`, `Agent.timerTick`), covered at **82,5 %** by
  `FouineAgentTests`, with a clean stop through an injected `onExit` and a full
  simulation of the blocking and resuming conditions.
- **`fouine license` against the real seller.** An offline recipe must not go
  out on the network: `LicenseRecetteTests` drives `activate`, `deactivate` and
  the monthly check of `status` through `LocalLicenceRelay`, a stand-in relay
  on `127.0.0.1` (`FOUINE_LICENSE_RELAY`) answering Creem's real sandbox
  bodies. The round trip with Creem itself is played by hand, in its sandbox,
  when the licence code changes (lot LC2).
- **The `rtfd`, `webarchive` and `cbr` extensions.** No versioned fixture:
  proprietary formats, packages, or a RAR archive no free tool produces. They
  stay covered by unit tests on fixtures built on the fly.
- **The 68 source extensions and the six XML ones.** Four versioned fixtures
  represent them (`script.py`, `composant.tsx`, `configuration.xml`,
  `reglages.plist`, plus the trap `pieges/page.min.js`): they all go through the
  same extractor, and demanding one per extension would put seventy files in the
  repository without proving anything more. `CorpusFixturesTests` records that
  gap by name.
- **Performance thresholds.** Opt-in only, never in CI.
- **Developer ID signing and notarisation.** They need a keychain and an
  identity. CI signs **ad hoc**, which proves the bundle structure is signable;
  the real signature is the work of `.github/workflows/release.yml`.
