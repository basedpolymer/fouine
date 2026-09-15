# Contributing to Fouine

How to build, how to test without breaking your own installation, and which
conventions hold the code together. It is short because the project is: three
dependencies, no code generator, nothing to install beyond Xcode.

## Build

```sh
git clone https://github.com/basedpolymer/fouine.git
cd fouine
make build            # debug, every target
make release-cli      # .build/release/fouine, the CLI in release
make release          # Fouine.app, universal and signed
make release ARCHS=arm64        # one architecture, to iterate (or x86_64)
```

You need macOS 13 or later (required by `SMAppService` and by revision 3 of
Vision text recognition) and an Xcode providing Swift 5.10 or later. The
project is developed on Xcode 26.2 / Swift 6.2.3, in pure SwiftPM: there is no
`.xcodeproj` file, and none is needed. `make release` produces a **universal**
binary (x86_64 + arm64) by default, which costs about three minutes on a slow
machine.

**Signing.** `IDENTITY` is **empty by default** and the signature is then **ad
hoc**: the application works on the machine that produced it and nowhere else.
That is the normal mode for development and needs no Apple account. To sign
with a real Developer ID certificate, create `Makefile.local` at the root, which
is gitignored and never committed:

```make
IDENTITY := Developer ID Application: First Last (TEAMID)
FOUINE_NOTARY_PROFILE := notarytool-profile-name
```

No certificate, no `.p8` or `.p12` key, no team identifier goes into the
repository; `.gitignore` already refuses them. The full publication chain is in
[`RELEASING.md`](RELEASING.md).

## Test

```sh
make test                                  # everything, in release
make ci-unit                               # the nine unit suites, as CI runs them
make ci-integration                        # the integration recipe, as CI runs it
make ci-corpus                             # the recipe on the versioned corpus alone
swift test --filter FouineCoreTests        # one suite
```

Five points that save hours.

- **`make test` depends on `release-cli`, and that is not decoration.** The
  integration recipe drives the `fouine` binary through `Process`, but in
  SwiftPM terms it depends only on the libraries: without that prerequisite the
  whole recipe skips **green** on «`fouine` binary missing». Running `swift
  test --filter IntegrationTests` by hand means running `make release-cli`
  first.
- **No test writes into your production index.** Every suite builds its own
  temporary base, and the integration recipe builds a disposable root as well.
  That rule has no exception.
- **The full recipe needs a corpus, therefore an opt-in.** What only makes
  sense on a real corpus (performance, the OCR recipe, benches) skips without
  `FOUINE_TEST_DB`, which must name a **copy** of the index:

  ```sh
  sqlite3 "file:$HOME/Library/Application Support/Fouine/fouine.db?mode=ro" \
          ".backup /tmp/fouine-recette.db"
  FOUINE_TEST_DB=/tmp/fouine-recette.db make test
  ```

  Pointing it at the production base is **refused** by a hard failure, not by a
  skip. Personal fixture paths live in `Tests/Fixtures/paths.json`, which is
  gitignored; the versioned template is `Tests/Fixtures/paths.example.json`.
- **The tests that need the semantic model** skip cleanly without it, and the
  suite still passes. To exercise them, install it once with `fouine model
  download` (or, offline, `FOUINE_MODEL_URL=file:///…/e5-small-v1.zip` into a
  `FOUINE_MODEL_DIR` of your choice, never the production copy).
- **The versioned corpus** (`Tests/Fixtures/corpus/`) is enough for the
  essential recipe: indexing, six query forms, OCR, status, diagnosis, moved
  files, a hostile archive, a trapped `.doc`. `make fixtures` regenerates it,
  and `Tests/Fixtures/corpus/manifest.json` describes it file by file with
  witness terms, pages and expected state. The tests read the manifest and it
  is authoritative.

Continuous integration (`.github/workflows/ci.yml`) runs the unit suites, the
integration recipe on a disposable base and the versioned corpus, the suites in
release on `main`, the semantic model on a best-effort basis, and a packaging
job that checks the localisation files. A change that turns it red is not
merged. Everything about the suites, the skips and the fixtures is in
[`docs/tests.md`](docs/tests.md).

## Conventions

**French, and where.** Code comments, logs, commit messages and the internal
specification are in French; the public documentation, the CHANGELOG and the
licence are in English, which is authoritative. Identifiers stay in English
where the domain uses it (`Store`, `Extractor`, `Hit`). Commit messages carry a
zone prefix (`core:`, `cli:`, `app:`, `agent:`, `crawl:`, `mcp:`, `l10n:`,
`tests:`, `doc:`) and say *why*.

**Every visible string of the application goes through the catalogue.** The app
speaks English (the base language) and French; the key is the **English** text
and the French translation lives in
`Sources/FouineApp/Resources/Localizable.xcstrings` (and
`Packaging/InfoPlist.xcstrings` for the macOS authorisation prompts). Write
`Text("Add a folder…")` or `String(localized: "Removal failed")` and add the
entry to the catalogue, which is the single source of truth.
`Tools/l10n-lint.sh`, which `swift test` runs, refuses any visible string that
is missing from it, naming the file and the line. Three traps come back: do not
split a visible string with `+` (concatenation produces a `String`, which
SwiftUI displays without looking at the catalogue), pass data through
`Text(verbatim:)`, and leave plurals to the catalogue rather than to an `if`.
See [`docs/i18n.md`](docs/i18n.md).

**The command line, the libraries and the agent write in English**, without a
catalogue: the «visible string means catalogue» rule applies to the application
only. A command-line tool speaks English, like `git` or `brew`, and a log line
gets pasted into a bug report. The app never reads those sentences back: it
renders each error from its **case** (`ErrorText`).

**Three dependencies, not one more.** GRDB.swift (MIT), swift-argument-parser
(Apache-2.0) and Sparkle (MIT). The first two are sources compiled with the
project; **Sparkle is a binary XCFramework** that SwiftPM downloads
(`Package.swift`), and it is the one exception to «no binary to download»,
taken because an application distributed outside the App Store has no other way
to get a security fix to someone who already downloaded the DMG.

That is a design rule rather than a preference: it guarantees that `git clone`
followed by `swift build` is enough, on any machine, with no Homebrew, no venv,
and no network beyond SwiftPM resolution. A contribution that adds an SPM
package, a Homebrew tool or a binary to download is refused until the need has
been discussed in an issue. It is also why the disk image is built with
`hdiutil` rather than `create-dmg`. The notices of these three components ship
with the product (`THIRD_PARTY_LICENSES.md`, copied into the bundle and the
DMG): adding a dependency means adding its notice, and its entry in
`LicensesCommand.notices`.

**No network access in `Sources/`, except three named exceptions.** Fouine
talks to nobody while it indexes, reads or searches: that is the central claim
of the product, and it is checked. Any `URLSession`, any socket, any telemetry
is a change in the nature of the product rather than an improvement. Three
exceptions exist, and there is no fourth:

1. **the update check** (Sparkle), outside `Sources/`, where the framework
   makes the call rather than our code;
2. **the semantic model download**, in the single file
   `Sources/FouineEmbed/ModelDownload.swift`;
3. **licence activation and verification**, in the single file
   `Sources/FouineLicense/LicenseClient.swift`.

All three meet the same three conditions, which are what the rule looks like
once software is really distributed: **never automatic** (an explicit user
gesture, never «on first launch»), **an announced address** (in the clear in
the repository, and told to the user before the connection), and **nothing sent
beyond what the request itself requires** (no profiling, nothing from the
corpus; licence activation sends the key and the name of the Mac, and says so).
A contribution that adds a fourth connection is refused until the need has been
discussed in an issue.

**The check is not a `grep`.** `URLSession` appears in two files, and that is
true, but it is not what holds the promise. Fouine hands untrusted files to
system components, and some of those components know how to fetch a remote
resource named **inside the document**: the request then goes through no
`URLSession`, no constant, no line of `Sources/`, and no static inspection can
see it. What holds the promise is a test:
`Tests/FouineExtractTests/NetworkSilenceTests.swift`, run by `make ci-unit`. A
local server listens while an extraction pass processes trapped fixtures, and
the assertion is **zero accepted connections**. A contribution that adds an
extractor, or hands a file to a new system component, must **add its trapped
fixture to that test**. What the documentation claims must stay exact:
[`docs/privacy.md`](docs/privacy.md) is read as a promise, and a false promise
is worse than none.

**Frozen contracts.** The protocols in `Sources/FouineCore/Contracts.swift`
(SPEC §4.2) and the command-line contract (SPEC §4.3: subcommand names,
options, exit codes, the shape of `--json` output) are **frozen**. Other
programs depend on them: scripts, the MCP server, Raycast and Alfred
extensions. You may **add**; nothing is renamed and nothing is removed without
a major version and a dedicated CHANGELOG entry.

**Comments explain *why*, never *what*:** what was measured, what was tried and
failed, or the trap a line avoids. Every file opens with a header naming its
responsibility and the section of `SPEC.md` that grounds it. Read three
existing files before writing one.

**Measurements.** A performance claim is measured on this machine, and the
comment says on what. The standard is SPEC § 8.2: named bench, named machine,
named corpus.

## Licences

Fouine is **source-available, not open source**: the core, the command line,
the application and the agent are under the Fouine Source-Available Licence
([`LICENSE`](LICENSE)), whose English text is authoritative. The rights holder
is Mathis Demory. You may read this code, compile it and modify it for your own
personal use or to propose a contribution; you may not redistribute it, nor
distribute a binary you built.

**One exception, and it is bounded**: `Sources/FouineMCPKit` is under the **MIT
licence** (`Sources/FouineMCPKit/LICENSE`). It is the MCP protocol frame
(transport, JSON-RPC, router, envelopes, budget, cursors) and it has **no
dependency**, not even on `FouineCore`, which is exactly what makes that MIT
real rather than decorative. `Sources/FouineMCP`, the server itself, links the
core and falls under the Fouine licence, **and so does the shipped binary**. Do
not make `FouineMCPKit` depend on a Fouine target: one line of `Package.swift`
would turn its MIT into a misleading claim. Detail:
[`LICENSING.md`](LICENSING.md).

**New files** open with an SPDX identification line, right after the title line
of the usual header:

```swift
// MyFile.swift — what this file does (SPEC §x.y).
// SPDX-License-Identifier: LicenseRef-Fouine-Source-Available
```

…or `MIT` for a file of `FouineMCPKit`. `LicenseRef-` is the form SPDX reserves
for a project's own licence; there is no registered identifier for this one.
Existing files do not all carry a licence header and will not get one in bulk:
coverage comes from the root `LICENSE`, and they are completed as they are
modified.

### Contributing, and what it implies

There is **no CLA to sign**, no form, no scan to send back. The licence says
what a contribution carries, in its article 4:

- by proposing a contribution, in any form, you grant the rights holder a
  **perpetual, worldwide, non-exclusive, royalty-free, irrevocable and
  transferable** licence, with the right to sublicense, to use, modify,
  publish, translate and redistribute it **under any licence, including a
  commercial one**;
- you warrant that you are its author, or hold the rights needed to propose it
  on those terms, and that supplying it infringes no third-party right;
- you **keep your rights** in your contribution: nothing is assigned, and you
  remain free to do what you like with it elsewhere.

In plain terms: Fouine is sold, and an accepted contribution goes into the sold
product. That is stated here so that nobody discovers it afterwards. If the
condition does not suit you, open an issue describing the problem instead; a
good bug report is often worth more than the fix.

Do not put code from elsewhere into a pull request, even under a permissive
licence, without saying so: third-party components go through
`THIRD_PARTY_LICENSES.md` and through the «three dependencies, not one more»
doctrine (`SPEC.md` § 2.2).

## Proposing a change

1. **Open an issue first** for anything touching the architecture, the frozen
   contracts, the database schema or the dependencies. For a clean fix, the
   pull request is enough.
2. Branch from `main`, one branch per subject.
3. One commit per idea. The subject line in French, short; the body explains
   *why* and quotes the measurements and checks made.
4. Add a test. A fix without a regression test is sent back.
5. Add a `CHANGELOG.md` entry under `## [X.Y.Z] — unreleased`, in the right
   section (`Security`, `Added`, `Changed`, `Fixed`). There is **no**
   «Unreleased» section: `make check-changelog` refuses one.
6. Check before sending:

   ```sh
   make check-version
   make check-changelog
   make test
   make release ARCHS=$(uname -m)     # the bundle builds and signs
   ```

7. In the pull request, say what you **checked**, not only what you wrote: the
   output of the commands beats an assertion.

Vulnerability reports do not go through issues: see
[`SECURITY.md`](SECURITY.md).

## Where to read what

| Need | File |
|---|---|
| How a document becomes a searchable page, the schema, the costs | [`docs/architecture.md`](docs/architecture.md) |
| The suites, the skips, the fixtures, the gate | [`docs/tests.md`](docs/tests.md) |
| Strings, catalogues, plurals, French typography | [`docs/i18n.md`](docs/i18n.md) |
| Mistakes already made | [`docs/pitfalls.md`](docs/pitfalls.md) |
| The CLI, the `--json` contract, the exit codes | [`docs/cli.md`](docs/cli.md) |
| Publishing, the cask, the appcast | [`RELEASING.md`](RELEASING.md) |
| Which licence covers what | [`LICENSING.md`](LICENSING.md) |
| The product contract (French, internal) | [`SPEC.md`](SPEC.md) |
