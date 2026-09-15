# The `fouine` command line

`fouine` does everything the app does, plus JSON export and external
recognition. It works on **the same database** as the app.

This document is checked against `fouine <command> --help` for version
**1.0.0**. Subcommand names, options, exit codes and the shape of the JSON are a
**frozen contract** (SPEC §4.3): other programs depend on them.

**`fouine` speaks English.** That is the project's base language: the help, the
messages, the lines of `doctor` and `status`, the agent's log. There is no
French command line. An error phrase ends up in a bug report or a search
engine, so it stays in one language, like `git` or `brew`. French lives in the
**app**, which follows the system language (see [`i18n.md`](i18n.md)).

**A read never creates an index.** `search`, `status`, `doctor` (without
`--deep`), `root list`, `config list`, `config get` and `embed --status` open
the database **read-only** and **refuse** if it does not exist:

```
$ FOUINE_DB=/tmp/typo.db fouine search nitrogen ; echo $?
fouine: database: no Fouine index at /tmp/typo.db — index some folders first (open Fouine.app, or `fouine root add <folder>` then `fouine index`)
3
```

Exit **3**, and **nothing on disk**: no database, no folder, no lock, no `-wal`.
Creating one stays the explicit gesture of `root add`, `index`, `crawl`,
`extract`, `ocr`, `embed`, `config set`, `maintain`, and of the app. On a new
machine, `fouine status` therefore says "no index, here is the gesture" instead
of showing an empty one.

- [Installing](#installing)
- [Overview](#overview)
- [Folders and volumes](#folders-and-volumes)
- [Indexing](#indexing)
- [Search by meaning](#search-by-meaning)
- [Settings](#settings)
- [Notes from other applications](#notes-from-other-applications)
- [Searching](#searching)
- [Diagnosis](#diagnosis)
- [Backup and maintenance](#backup-and-maintenance)
- [Licences](#licences)
- [Assistant](#assistant)
- [Exit codes](#exit-codes)
- [Environment variables](#environment-variables)
- [Examples](#examples)

---

## Installing

Menu **Fouine ▸ Install the command-line tool…**: the app creates a symlink
`/usr/local/bin/fouine` pointing at the CLI it carries. If the folder does not
exist or is not writable, it shows the command to paste and puts it on the
clipboard. It never asks for your administrator password.

```sh
sudo mkdir -p /usr/local/bin
sudo ln -sf /Applications/Fouine.app/Contents/Helpers/fouine /usr/local/bin/fouine
fouine --version          # 1.0.0
```

A **link**, not a copy: a copy would drift at the first app update and read the
database with a stale schema.

From a clone of the repository, the binary is `.build/release/fouine` after
`make release-cli`.

---

## Overview

```
OVERVIEW: Full-text search engine for macOS, with non-destructive OCR.

USAGE: fouine <subcommand>
```

| Command | What it does |
|---|---|
| `fouine root` | manage the indexed folders, and what Fouine skips in them |
| `fouine volume` | manage volumes (the external drive case) |
| `fouine crawl` | walk the folders and update the document table |
| `fouine extract` | extract the text of the documents found |
| `fouine ocr` | run text recognition on scanned pages |
| `fouine index` | `crawl --delta` then `extract` |
| `fouine embed` | produce the meaning vectors of the pages |
| `fouine model` | install and manage the meaning model |
| `fouine search` | search the index |
| `fouine list` | browse the indexed documents, without searching |
| `fouine read` | read the indexed text of one page |
| `fouine similar` | list the pages closest in meaning to a given page |
| `fouine config` | read and write the settings shared by app, CLI and agent |
| `fouine status` | state of the index and of the folders |
| `fouine doctor` | diagnosis: volumes, effective read, recognition queue |
| `fouine sources` | index the notes of Apple Notes and Bear, and Anki flashcards |
| `fouine backup` | online snapshot backup |
| `fouine maintain` | database maintenance |
| `fouine licenses` | the licence of Fouine and of the components it ships |
| `fouine license` | your licence: trial, activation, deactivation |
| `fouine mcp` | serve the index to an assistant |

`--version` and `--help` are accepted at every level.

---

## Folders and volumes

### `fouine root add <path> [--label <label>]`

Adds a folder to index. It resolves the volume and the relative path, and tests
readability. The label is the folder's name in the "Folders" facet and in
`folder:…` queries; by default it is the last segment of the path.

Some folders are **refused**: the root of the disk, the home folder,
`~/Library`, `/System`, `/Library`, `/Applications`, `/private`. They would
swallow Fouine's own database, or hundreds of thousands of entries without a
single document. Their **children** stay legitimate (`/Volumes/Archives`, say).
The data folder of an application Fouine reads (`~/Library/Application
Support/Anki2`, Apple Notes' and Bear's group containers, and anything inside
them) is refused with its own sentence, which names `fouine sources enable
<notes|bear|anki>` ([below](#notes-from-other-applications)) instead of calling
it a system folder.
A refusal exits **64**, a usage error like a missing argument:

```
$ fouine root add ~
Error: Your entire home folder cannot be a root: it holds ~/Library, the caches and Fouine's own database. Choose a subfolder — Documents, Desktop, a folder of books…
Usage: fouine root add <path> [--label <label>]
```

The app shows the **same refusal**, in the user's language: the reason is a
type, not a copied sentence. `~/Downloads` is not refused but **announced**:
without the matching macOS permission it indexes as if it were empty.

`root add` also reports an **exclusion file** already sitting in the folder
(`.fouineignore`, below): finding it out later, when a search misses a document
you know is there, costs far more than one line here.

### `fouine root list [--json]`

Lists the folders and their state (enabled, read denied, volume not mounted).
It is the default subcommand: `fouine root` alone does the same.

Each line also carries `ignore_rules=N`, the number of exclusion rules the
folder carries, from its two sources together: the folder's `.fouineignore`
file and the rules kept by Fouine (`fouine root ignore`, or the app's **What
Fouine skips…** sheet). A rule present in both counts once. When there is at
least one, the sources follow in parentheses. The file cannot be read when the
volume is not mounted, so it counts for nothing then; kept rules always count.
The JSON output carries the same number under `ignore_rules`, and the rules one
by one, with their source (`file` or `settings`), under `ignore_rule_list`.

```
$ fouine root list
[1] Livres  /Users/you/Livres
      enabled=yes mounted=yes readable=yes ignore_rules=0
[3] Personnel  /Users/you/Personnel
      enabled=yes mounted=yes readable=yes ignore_rules=2  (file 1, settings 1)
```

```json
[
  {
    "enabled" : true,
    "id" : 3,
    "ignore_rule_list" : [
      { "rule" : "*.md", "source" : "file" },
      { "rule" : "Santé/", "source" : "settings" }
    ],
    "ignore_rules" : 2,
    "label" : "Personnel",
    "mounted" : true,
    "path" : "/Users/you/Personnel",
    "readable" : true
  }
]
```

**Excluding a folder or a file type**, two ways that add up: `fouine root
ignore add` ([below](#fouine-root-ignore-listaddremove-idlabel-rule---json)),
which keeps the rule in Fouine's index and writes nothing into the folder, or a
`.fouineignore` file you put at the top of a root yourself. Both are read at the
start of **every** pass, and a document that becomes excluded leaves the index —
with its pages, its OCR and its vectors — at the next one. The three forms and
what they cover:
[formats](formats.md#excluding-a-folder-or-a-file-type-fouineignore).

### `fouine root remove <id|label> [--purge]`

Disables a folder. Without `--purge`, the index of its documents is kept, which
is what you want for a temporarily unplugged drive. With `--purge`, its
documents and pages are deleted from the database.

### `fouine root ignore <list|add|remove> <id|label> [<rule>] [--json]`

What Fouine skips in one root, the same thing the app shows under **Settings ▸
Folders ▸ What Fouine skips…**. The rules are **kept by Fouine**, in its index:
nothing is ever written into the folder. A `.fouineignore` file in the folder
keeps working, and a pass applies both sources together.

- `fouine root ignore list <root>` lists the rules of that root with their
  source, `file` or `settings`, and how many documents still in the index they
  match (those leave it at the next pass). `fouine root ignore <root>` alone
  does the same.
- `fouine root ignore add <root> <rule>` keeps one rule. The three forms of the
  file apply: `Folder/` or `Folder/Sub/` (that folder and everything in it, from
  the top of the root), `'*.ext'` (every file of that kind), `name.ext` (every
  file of that name). **Quote a pattern**, or the shell expands `*.md` before
  Fouine sees it. The command says how many documents of the index the rules
  now match. Adding a rule that is already kept (in any case, with or without
  accents) changes nothing and exits 0; so does a rule the `.fouineignore` file
  already carries, which is not kept a second time.
- `fouine root ignore remove <root> <rule>` stops skipping a kept rule; what it
  excluded comes back at the next pass.

The rule is applied at the next pass: `fouine index`, or on its own within a
minute or so when automatic updates are on (the agent notices the change at its
next tick, since no file changed). `fouine root remove --purge` deletes the kept
rules with the root; disabling a root keeps them.

**Refusals exit 64** and name the rule: a negation (`!file`), a rule starting
with `#` (a comment in a `.fouineignore` file), an empty rule, several lines,
a path holding an empty, `.` or `..` part (`../Other/`). Removing a rule that
is not kept exits 64 too, and a rule that comes from the `.fouineignore` file
says so: Fouine never writes into your folders, so that line is removed by
editing the file.

```
$ fouine root ignore add Personnel 'Santé/'
root 3 “Personnel” now skips “Santé/” (kept in the settings; nothing written into the folder)
      41 documents of the index match these rules and leave it at the next pass (`fouine index`, or on its own when automatic updates are on) — your files are not touched

$ fouine root ignore add Personnel '!Santé/bilan.pdf'
Error: “!Santé/bilan.pdf”: negation (!) is not supported — a rule names what to skip
Usage: fouine root ignore add <selector> <rule> [--json]
```

With `--json`, the three subcommands print the same object; `add` and `remove`
add `changed` (whether anything was written):

```json
{
  "changed" : true,
  "documents_matching" : 41,
  "id" : 3,
  "label" : "Personnel",
  "mounted" : true,
  "path" : "/Users/you/Personnel",
  "rules" : [
    { "rule" : "*.md", "source" : "file" },
    { "rule" : "Santé/", "source" : "settings" }
  ],
  "warnings" : [ ]
}
```

`warnings` carries what could not be read: a refused line of the file, or a
kept rule that no longer reads (written by hand in SQL). Each is also printed
on the standard error.

### `fouine volume add --path <mount point> [--roots a,b]`

Registers a mounted volume and, optionally, the subfolders to index (separated
by commas).

### `fouine volume list`

Lists the known volumes and their mount point. Default subcommand of `fouine
volume`.

---

## Indexing

### `fouine crawl [--root <id|label>] [--full] [--delta]`

Walks the folders and updates the document table. `--delta` is the default;
`--full` also detects **deletions**. Without `--root`, every enabled folder is
walked.

With no folder registered at all, the command exits **5** saying what to do,
rather than letting you believe the corpus is empty.

```
$ fouine crawl
[Books] seen 1329 · added 0 · updated 0 · removed 0 · skipped 2
```

The report line carries a sixth term, `· moved N`, **only when there is one**:
documents found ELSEWHERE, renamed or moved. Those are neither added nor
removed, and nothing they carry (text, recognition, queue, vectors) is redone.

### `fouine extract [--jobs N] [--budget-minutes M] [--only <doc>]`

Extracts the text of the documents found. Without `--jobs`, the value comes
from the `extract.jobs` setting (4 by default, capped at 4).
`--budget-minutes` stops cleanly after M minutes (exit **4**, coherent queue,
exact resumption). `--only` handles one document, named by its absolute path or
by its path relative to the folder.

```sh
fouine extract --jobs 4 --budget-minutes 30
```

### `fouine index [--with-ocr] [--jobs N] [--budget-minutes M]`

`crawl --delta` then `extract`. With `--with-ocr`, the recognition pass follows.

```sh
caffeinate -i fouine index --with-ocr
```

### `fouine ocr [--jobs N] [--budget-minutes M] [--prio-folder <folder>] [--only <doc>]`

Runs Apple Vision text recognition in `.accurate` mode. Without `--jobs`, the
value comes from `ocr.jobs` (4 by default, capped at 4); the languages come
from `ocr.languages`. `--prio-folder` handles one folder first.

> Unlike the background agent, the CLI has **no energy guard**: it runs
> recognition on battery and will drain yours. Work on mains power, and under
> `caffeinate -i` so the machine does not fall asleep halfway.

**Lock held by another program** (the agent, the app, another command) and
**queue not empty**: the pass refuses straight away, one line on stderr, exit
**3**, queue intact, no engine warm-up. **Queue empty**: the command stays a
silent success at 0, lock or no lock, because the agent and the app call the
pass in a loop and refusing an absence of work would turn it into a failure.

### `fouine ocr export --out <file.jsonl> [--pending] [--no-lines] [--limit N] [--render-png <folder>]`

Exports pages as JSONL, to have them recognised by an external engine.
`--pending` exports the queue; `--no-lines` the scanned pages where **no** line
was recognised; with neither, the pages already recognised but **doubtful**
(confidence under the threshold). Pages transcribed from audio or video are
never included: they have no image. `--limit` is 100 000 by default.
`--render-png` also writes the page images into a folder.

```sh
fouine ocr export --pending --limit 500 --render-png /tmp/renders --out /tmp/queue.jsonl
```

### `fouine ocr import <file.jsonl>`

Reimports recognition produced elsewhere. **The import has no privilege**: it
goes through exactly the same confidence filtering as Vision.

### `fouine ocr requeue [--doubtful|--no-lines] [--limit N] [--json]`

Puts already recognised scanned pages of the chosen population back in the
queue (attempts reset, lowest priority), without touching the text already
indexed: the next `fouine ocr` pass reads them again and replaces it.

By default, or with `--doubtful`, it targets pages whose average confidence is
doubtful (`0 < conf < 0.60`). With `--no-lines`, pages where no line could be
recognised. Pages already in the queue are left alone. `--limit` is 100 000 by
default.

Only **scanned** pages qualify. A page transcribed from audio or video has no
image to read again: queueing it made it fail three times and then marked the
document as a recognition failure. Reading a page again with the same settings
gives the same text, so this command is only useful after a change that affects
recognition, a language added for instance.

```sh
fouine ocr requeue --no-lines --limit 500 --json
```

---

## Search by meaning

### `fouine embed [--budget-minutes N] [--batch N] [--folder <label>] [--include-tables] [--model-dir <folder>] [--status] [--bench N]`

Produces the meaning vectors of the pages, which feed `search --hybrid`.
Incremental and resumable: only **incomplete** pages are processed, and any page
whose text changes (re-extraction, recognition) becomes due again. Ctrl-C stops
cleanly.

**One campaign at a time.** The campaign lock `fouine-embed.lock`, next to the
database, is held for the life of the process: a second `fouine embed` on the
same index exits **3** with "a vectorisation campaign is already running (pid N,
since HH:MM)". That is not the write lock, which is released after each batch on
purpose so the app can index during a twenty-hour campaign; it is why `doctor`
answers "write lock: free" in the middle of one. `--status` and `--bench` do not
take it: one reads, the other does not even open the database.

**Usually it is the agent holding it**: with `agent.prepareMeaning` on, the
background agent prepares meaning itself, ten minutes at a time. A campaign
launched by hand during one of its batches exits **3** with "the background
agent is preparing meaning — it will stop by itself; or turn the setting off
(`fouine config set agent.prepareMeaning false`)".

A page is worth up to **three windows** of 1 400 characters (see
[searching](search.md)), so the log counts windows as well as pages, and a page
is "complete" only once all of its windows exist.

- `--status` prints vector coverage and exits, producing nothing:

  ```
  $ fouine embed --status
  indexed pages: 390114
  vectorised pages: 64872 (16.6%)
    complete (every window): 3696
    first window only: 61176
    incomplete pages left: 386418
  vectors (windows): 71460
  model: multilingual-e5-small r1, dim 384
  windows: up to 3 per page, 1400 char(s) every 1300
  windows per page (measured here): 2.13
  remaining: ~819440 window(s) at 6.36 win/s (last run) -> ~35.8 h
    (throughput measured on the run of 2026-09-04T09:22:50Z)
  ```

  **The end of a campaign is projected, not guessed.** The throughput of the
  last pass is recorded at the end of each `fouine embed`, and the number of
  windows per page is **measured on this database** (2.13 on the reference
  corpus, but a corpus of short notes fits one window per page, and projecting
  2.13 onto it would announce twice the work). Until a pass has run, the line
  says the gesture rather than an invented figure: "no throughput measured yet —
  run `fouine embed` once".
- `--batch`: pages per inference batch, 24 by default.
- `--folder <label>`: prepare **only** this folder; repeatable. An unknown
  label is refused (**64**) naming the real ones, before the model is even
  loaded. Without it, the campaign starts with the **pinned folders**
  (`roots.pinned`, the same setting the app calls "read their scanned pages
  first") and then covers the rest of the index. This matters: the selection
  scans by document discovery order, so before this a pinned folder added late
  could sit at **zero** vectors while an older folder was at 73 %. The log
  announces each phase. The background agent follows the same order, since it
  is the campaign that really runs. In **either** case spreadsheets stay out of
  the inference unless `--include-tables` is given: `--folder` chooses where the
  campaign works, never what it encodes.
- `--include-tables`: also vectorise spreadsheets (`csv`, `tsv`, `xls`, `xlsx`,
  `xlsm`, `ods`, `numbers`), which are skipped by default — see below.
- `--model-dir`: by default
  `~/Library/Application Support/Fouine/models/e5-small`, or `FOUINE_MODEL_DIR`.
- `--bench N` infers N synthetic windows **without opening the database or
  writing anything**, to measure the model's throughput on this machine and
  compare `FOUINE_EMBED_COMPUTE` back-ends. It also prints the breakdown of
  loading (`load: vocabulary … + CoreML … = …`), which is what decides where to
  optimise.

**Spreadsheets, and pages that are tables of numbers, get a null vector.** A
vector built from a column of figures describes nothing: it is close to every
other table in the corpus and to nothing useful, and it takes a place in every
result by meaning. They are therefore counted as done, without inference, and
stay findable word for word by the lexical channel. The setting
`embed.skip_spreadsheets` (true by default) governs it for the command and for
the agent alike; `--include-tables` disarms it for one campaign. This is a
**quality** decision and not a disk one: on the measured corpus it saves about
21 MB where the budget was already 110 MB over before any vectorisation.

The model installs with `fouine model download`; without it, the command says so
and points at it. Inference is CPU-heavy: run it with recognition paused, or in
slices with `--budget-minutes`.

```sh
caffeinate -i fouine embed --budget-minutes 60
```

### `fouine model <download|status|remove>`

Installs and manages the meaning model. This is, together with the app's update
check and licence activation, one of the few commands of Fouine that opens a
connection, and it never goes on its own: neither `embed`, nor `search
--hybrid`, nor `doctor`, nor indexing downloads anything. See
[privacy](privacy.md).

```
fouine model download [--url <address>] [--force]
fouine model status [--json]
fouine model remove
```

`download` **announces first** the address, the hosts contacted (`github.com`,
then `release-assets.githubusercontent.com`, since GitHub serves its assets
through a redirect), the size and the destination; then it downloads, checks the
size and the SHA-256, and installs. There is no interactive question: typing the
command is the consent. A model already installed is not reinstalled without
`--force`, and the command exits 0 saying so.

- `--url`: another source. `https://` and `file://` only. A `file://` pointing
  at an archive copied onto a USB stick opens **no** connection.
- `--force`: reinstalls over an existing model. The old one is removed only once
  the new one is complete; a wrong fingerprint leaves the existing one intact.
- `status --json` returns `installed`, `path`, `bytes`, `model_id`, `revision`,
  `url`.
- `remove` deletes the model directory. Twice in a row is not an error.

Any failure exits 1: asset not published (404), wrong fingerprint, malformed
archive, not enough disk space. In all of those cases **nothing is installed**,
the existing model is intact, and no temporary file is left behind.

```sh
fouine model download
```

---

## Settings

Settings live in the database, and **all three executables read them**: the app
(settings window, ⌘,), the command line, and the background agent. It is the
only way to configure a `launchd` agent, which has neither a window nor a
preferences domain of its own.

**Three sources, in this order, first one wins:**

1. the **environment variable**, when the key declares one. It stays ahead,
   deliberately: that is what lets you rescue an agent that will not start, and
   force a value in a test without writing into anyone's database;
2. the **settings table**, written by `fouine config set` and by the settings
   window;
3. the **default**, which is what the code did before these settings existed. A
   new database therefore behaves exactly as before.

`fouine config list` shows where each value comes from: `[default]`,
`[settings]`, `[environment]`. A value from `[environment]` **cannot** be
changed by `set` while the variable is set, and `set` says so.

### `fouine config list [--json]`

Every key, its effective value, where it comes from, the default and the
matching environment variable.

```
$ fouine config list
ocr.languages                fr-FR,en-US  [default]
      OCR recognition languages, in order of preference (BCP-47 codes, separated by commas).
      default fr-FR,en-US · variable FOUINE_OCR_LANGUAGES (takes priority over this table)
…
```

### `fouine config get <key> [--json]`

The effective value, **alone on standard output** (its origin goes to standard
error), so it can be used in a script: `$(fouine config get agent.pollSeconds)`.

### `fouine config set <key> <value>`

Validates, normalises, writes. An integer out of bounds is **clamped**, with the
value kept shown, rather than refused; an unreadable value or an unknown key
exits **64** with the list of valid keys.

```
$ fouine config set ocr.jobs 99
ocr.jobs = 4 (99 is outside 1–4)
```

Three values are **refused with 64, writing nothing**, because the machine
already knows they will name nothing: a `roots.pinned` whose identifier matches
no folder (the message names them), and an `ocr.languages` holding a language
Vision does not know **on this machine** (the warning used to arrive at the next
recognition pass, possibly days later; what is kept is the machine's canonical
form, so "fr-fr" typed by hand becomes "fr-FR").

```
$ fouine config set ocr.languages zz-ZZ ; echo $?
fouine: OCR language(s) unknown to this Mac: zz-ZZ — Vision reads: en-US, fr-FR, … (nothing was written)
64
```

### `fouine config reset <key>`

Erases the row: the value goes back to the default (or to the environment).

### The keys

| Key | Type | Default | Environment variable |
|---|---|---:|---|
| `ocr.languages` | BCP-47 list | `fr-FR,en-US` | `FOUINE_OCR_LANGUAGES` |
| `ocr.jobs` | 1–4 | 4 | `FOUINE_OCR_JOBS` |
| `extract.jobs` | 1–4 | 4 | `FOUINE_EXTRACT_JOBS` |
| `extract.images` | boolean | `false` | `FOUINE_EXTRACT_IMAGES` |
| `extract.media` | boolean | `false` | `FOUINE_EXTRACT_MEDIA` |
| `extract.transcribe` | boolean | `false` | `FOUINE_EXTRACT_TRANSCRIBE` |
| `transcribe.max_minutes` | 1–600 | 120 | `FOUINE_TRANSCRIBE_MAX_MINUTES` |
| `agent.extractJobs` | 1–4 | 2 | `FOUINE_AGENT_JOBS` |
| `agent.ocrBudgetMinutes` | 1–120 | 10 | `FOUINE_AGENT_OCR_BUDGET_MINUTES` |
| `agent.pollSeconds` | 5–3600 | 60 | `FOUINE_AGENT_POLL_SECONDS` |
| `agent.requireAC` | boolean | `true` | `FOUINE_AGENT_REQUIRE_AC` |
| `agent.pauseOnLowPower` | boolean | `true` | `FOUINE_AGENT_PAUSE_LOW_POWER` |
| `agent.pauseOnThermal` | boolean | `true` | `FOUINE_AGENT_PAUSE_ON_THERMAL` |
| `agent.prepareMeaning` | boolean | `true` | `FOUINE_AGENT_PREPARE_MEANING` |
| `agent.embedBudgetMinutes` | 1–120 | 10 | `FOUINE_AGENT_EMBED_BUDGET_MINUTES` |
| `embed.skip_spreadsheets` | boolean | `true` | `FOUINE_EMBED_SKIP_SPREADSHEETS` |
| `roots.pinned` | identifiers | *(empty)* | `FOUINE_PINNED_ROOTS` |
| `notifications.onQueueDrained` | boolean | `false` | `FOUINE_NOTIFY_QUEUE_DRAINED` |
| `spotlight.enabled` | boolean | `true` | `FOUINE_SPOTLIGHT` |
| `spotlight.all_documents` | boolean | `false` | `FOUINE_SPOTLIGHT_ALL` |
| `spotlight.text_kb` | 64–4096 | 1024 | `FOUINE_SPOTLIGHT_TEXT_KB` |
| `sources.notes` | boolean | `false` | `FOUINE_SOURCE_NOTES` |
| `sources.bear` | boolean | `false` | `FOUINE_SOURCE_BEAR` |
| `sources.anki` | boolean | `false` | `FOUINE_SOURCE_ANKI` |

A boolean accepts `true`/`false`, `1`/`0`, `yes`/`no`, `on`/`off`, and, for
compatibility with databases written before the CLI moved to English,
`oui`/`non` and `vrai`/`faux`.

**The three `spotlight.*` keys** decide what Fouine hands to Spotlight's index:
`enabled` (hand over or not), `all_documents` (everything, or only what
Spotlight cannot read by itself) and `text_kb` (ceiling on the text handed per
document, cut on a page boundary). The handover is done by the **app**: `fouine
index` and `fouine ocr` skip it, printing `Spotlight: skipped, no bundle`, a
terminal command having no bundle identity. A fourth key,
`spotlight.synced_at`, exists in the settings table without appearing in
`config list`: it is an internal marker rather than a preference.

**The three `sources.*` keys** turn on copying Apple Notes notes, Bear notes
and Anki flashcards into Fouine's folder. Off by default. Writing them by hand with `config set` works
but copies nothing right away: the copy happens at the start of the next
indexing pass, where the `enable` subcommand does it immediately.

**`extract.images`** turns on indexing images on their own: nineteen extensions
listed in [formats](formats.md). Off by default. When on, each valid image
declares a page (a multi-page TIFF declares as many as it holds) and enters the
recognition queue. Two floors keep interface clutter out, with **two distinct
reasons**: files under **8 KiB** (`image file below the OCR weight floor`) and
those whose smaller side is under 300 px (`image below the OCR size floor`) are
skipped cleanly. **`fouine config set extract.images false` removes NOTHING from
the index**: the next pass stops adding images, and the ones already indexed
stay with their recognised text. Photos libraries (`.photoslibrary`) and caches
stay excluded by the crawler. The app has no checkbox for images: this setting
is command line or environment variable.

**`extract.media`** turns on indexing audio and video, twelve audio extensions
and seven video ones. Off by default: a music library of 20 000 tracks is not a
set of documents. On, each recording yields **one metadata page** (title,
artist, album, author, description, comment, lyrics, date, duration, chapters)
of origin `native`. A recording with no tag at all and no transcription is
skipped cleanly (`no metadata`; with transcription on, the reason takes a
parenthesised form: `(no audio track)`, `(longer than N min)`, `(unknown
duration)`, `(no speech)`). The `mkv`, `avi`, `wmv`, `webm` and `ogg` containers
go through **ffmpeg** when it is installed (`/opt/homebrew/bin`,
`/usr/local/bin`, `/opt/local/bin`, then `FOUINE_FFMPEG`); without it,
`docs.err` says `ffmpeg is missing` and the crawl comes back to that refusal as
soon as the tool appears.

**`extract.transcribe`** writes down the speech of media files, **on this
machine**: nothing is sent anywhere (`requiresOnDeviceRecognition`). Without
`extract.media` it does nothing. Each ten-minute window becomes a page of origin
`transcript`, in paragraphs headed by their `[mm:ss]` timestamp. The languages
are those of `ocr.languages`, there is no extra key, and the **dictation**
language must be installed (System Settings ▸ Keyboard ▸ Dictation) along with
the "Speech Recognition" permission; failing that, the document is skipped with
a reason naming the gesture. Count roughly the length of the recording.

**`transcribe.max_minutes`** (1 to 600, 120 by default) bounds that spending:
beyond it only the metadata is indexed.

**`ocr.languages`** is filtered at runtime against the languages **this
machine** can recognise. A missing language is dropped with a warning: Vision
fails the **whole** request on a language its revision does not know, so the
page would not be recognised worse, it would not be recognised at all. If
everything is dropped, `fr-FR, en-US` takes over.

**`ocr.jobs`** and **`extract.jobs`** are the default of `--jobs` when the
option is absent; the command-line option stays ahead.

**`roots.pinned`** puts the pages of the named folders at **priority 0**, ahead
of the rest of the queue. `set` and `reset` also **re-prioritise the pages
already queued**, under the write lock (measured: 21 730 pages in 0.18 s). It is
the only `config` subcommand that can fail with **3** because the agent is
writing; the setting itself is already recorded, and the next indexing pass
applies it. Since this release it also governs the **order of the meaning
campaign**: the pinned folders are prepared first, then the rest of the index
(`fouine embed`, the agent).

**`embed.skip_spreadsheets`** leaves spreadsheets out of the meaning vectors,
and is true by default: a vector built from a column of numbers describes
nothing and would take a place in every result by meaning. Those pages stay
findable word for word. `fouine embed --include-tables` overrides it for one
campaign.

**`agent.prepareMeaning`** hands the production of vectors to the agent, which
is what `fouine embed` does. **True by default**: a batch of
`agent.embedBudgetMinutes` minutes starts when the recognition queue is empty,
the model is installed, pages are left to prepare, and the six conditions of the
agent hold. `fouine status` gives its state (line `meaning`), `fouine doctor`
warns when the setting is armed while the model is missing.

**`agent.pauseOnThermal`** covers **both** thermal conditions: they say the same
thing, the machine is hot.

```sh
fouine config set agent.ocrBudgetMinutes 30
```

---

## Notes from other applications

`fouine sources` reads the notes of **Apple Notes** and **Bear** in their local
SQLite database (strictly **read-only**, `mode=ro&immutable=1`: never a write,
never the app's own write-ahead log) and copies each one as a Markdown file
under `~/Library/Application Support/Fouine/Sources/<App>/`. That folder becomes
an ordinary indexed folder ("Notes", "Bear"), walked and indexed by the usual
pass: there is no second indexing path, and nothing special at search time.

**Anki** is read the same way with one difference: Anki keeps its newest cards
in its write-ahead log for as long as it stays open, so Fouine first **copies**
the collection and its log into a temporary folder of its own, then reads the
copy. Nothing is ever written next to the collection, and Anki can stay open.
Each profile under `~/Library/Application Support/Anki2/` is read. A **deck**
becomes one Markdown file, and each **note** one page of it, so a search result
points at a card; decks nested with `::` become folders (`Chimie::Organique` →
`Anki/Chimie/Organique.md`), and a deck of more than 2 000 notes is split into
`Deck.md`, `Deck (2).md`, and so on. What is copied: the text of each field,
cloze deletions resolved to their answer. What is not: hints, field names, tags,
sounds and image-occlusion masks. Pictures are **named** in the file, one
`<!-- fouine-image: name -->` line each, so that the app's preview can show them
from Anki's `collection.media`; those lines are removed from the indexed text,
and no text recognition runs on the pictures. A note with no text (a picture
alone) has nothing to search and is left out.

**Notion and Craft** cannot be read locally in a reliable way: export your pages
as Markdown or HTML and add the export folder with `fouine root add`. Fouine can
reopen a Notion page from the name of its export file.

**Apple Notes needs Full Disk Access**: without it, `NoteStore.sqlite` answers
"authorization denied", and Fouine says so with the gesture to make rather than
announcing zero notes.

### `fouine sources list [--json]`

Each source: installed or not, on or off, access denied where that applies, and
the number of notes currently copied (counted **on disk**, since there is no
marker in the database to be wrong). For Anki, `notes` counts the notes across
all deck files, and `store` is the `Anki2` folder that holds the profiles.

```json
{ "sources": [ { "id": "notes", "name": "Apple Notes", "enabled": true,
                 "present": true, "access_denied": false, "notes": 128,
                 "store": "/Users/…/NoteStore.sqlite" } ] }
```

### `fouine sources enable <notes|bear|anki>`

Checks access, **then** writes the key (`sources.notes`, `sources.bear`,
`sources.anki`) **and
copies straight away**: a setting with no visible effect is a setting nobody
believes. Run an indexing pass afterwards so the written files enter the index
(the background agent does it by itself).

**Order matters.** An application that is absent, or whose reading macOS
refuses, leaves the setting **unchanged**, and says so:

```
$ fouine sources enable bear ; echo $?
fouine: Bear: not installed on this Mac (nothing to read). Setting left unchanged.
1
```

### `fouine sources disable <notes|bear|anki>`

Turns the key off, removes the folder with its index **and deletes the copies**.
Leaving the files behind would make disabling a half gesture.

### `fouine sources sync`

Copies the notes of the enabled sources again. The indexing pass already does
this when it starts: this subcommand is for forcing it without waiting. One line
per source; Anki counts decks rather than notes:

```
Anki: 42 deck(s) copied (3 written, 0 removed, 0 skipped)
```

Exit **0** when all went well, **1** when a source could not be read (access
denied, unknown schema), the sentence naming the gesture. **64** for an unknown
source name.

```sh
fouine sources enable notes && fouine index
```

---

## Searching

### `fouine search <query> [options]`

| Option | Effect |
|---|---|
| `--limit N` | pages returned (50 by default) |
| `--offset N` | pages skipped (0 by default) |
| `--facet <doc_year\|modified_year\|folder\|ext\|source\|lang>` | compute a facet and its counts |
| `--in <doc_id>` | restrict to this document; repeatable |
| `--lang <code>` | restrict to documents in this language (ISO 639-1, `und` = undetermined); repeatable |
| `--since <YYYY-MM-DD>` | restrict to documents modified on or after this date |
| `--source <native\|ocr\|transcript>` | restrict to pages whose text has this origin |
| `--json` | JSON output, on the stable schema |
| `--raw-fts` | bypass the query parser: the string goes to FTS5 as it is, with no morphology and no ranking bonus |
| `--fuzzy <off\|auto\|on>` | fuzzy search (`auto` by default) |
| `--fuzzy-scope <ocr\|all>` | scope of fuzzy search (`ocr` by default) |
| `--mark <guillemets\|brackets\|asterisks\|none>` | what surrounds the matched words in a snippet (`guillemets` by default) |
| `--hybrid` | RRF merge with meaning search (needs the model and vectors) |
| `--hybrid-auto` | merge with meaning search when the model and the vectors are there, and search full text otherwise, without failing |
| `--depth N` | depth of the merged lists in hybrid mode (200 by default) |
| `--vec-floor Z` | drop semantic results whose margin `z` is below this (**0** by default, disarmed) |
| `--lex-weight W` | weight of the lexical list in the RRF merge (1) |
| `--vec-weight W` | weight of the semantic list in the RRF merge (1) |
| `--vec-center` | subtract the corpus mean vector before comparing (calibration) |
| `--no-proximity` | disarm the three ranking bonuses: exact phrase, nearby words, file name (calibration) |
| `--no-morphology` | search the words as typed, without singular and plural (calibration) |
| `--no-diversity` | do not demote the fourth and later pages of the same document (calibration) |
| `--no-typed-form` | do not promote pages carrying the words as typed over those carrying only an inflected form (calibration) |
| `--no-quorum` | require every word on the same page even when fewer than ten pages carry them all (calibration) |
| `--no-demote-toc` | leave tables of contents and indexes where the ranking puts them (calibration) |
| `--raw-semantic-ranks` | hybrid: fuse the semantic ranks as they are, without rescaling them to vector coverage (calibration) |

The query syntax is described in [searching](search.md). The `dossier:`, `ext:`,
`pres:`, `nom:`, `texte:` and `chemin:` prefixes belong to the **query
language**: they are typed rather than translated, and `folder:`, `near:`,
`name:`, `body:` and `path:` are their English aliases. A script that writes them
keeps working whatever language the Mac is in.

| Filter | What it does |
|---|---|
| `chemin:Offres` / `path:Offers` | the whole path of the document contains this, folders included, case and accents ignored; alone, it lists the matching documents |
| `-ext:md` | exclude an extension |
| `-dossier:Cours` / `-folder:Courses` | exclude a folder, by its label |
| `-nom:draft` / `-name:draft` | exclude documents whose **name** matches |
| `-chemin:Archive` / `-path:Archive` | exclude documents whose path contains this |

**Every filter that picks documents can be excluded, and nothing else can.**
The four above drop whole documents, like `-word`, and an unknown label in
`-dossier:` is refused (**64**) in the same words as `dossier:`. `pres:` and
`texte:` have no negative form: proximity is not a set of documents, and the
negative of `texte:word` is `-word`. Writing one is refused (**64**) naming the
filters that can be excluded — as is any other `-word:value`, exactly like its
positive form. Until 14/09/2026, `-type:pdf` was accepted and excluded the
*phrase* "type pdf": it did not drop the PDFs that were asked for, and could
drop a document that happened to carry those two words in a row.

A query that **starts** with a `-` has to be introduced by `--`, as with any
command-line tool: `fouine search -- '-ext:md nitrogen'`, or simply put a word
first. Options go **before** the `--`
(`fouine search --json -- '-ext:md nitrogen'`); everything after it is the
query. Without it, the argument parser reads the query as an unknown option and
refuses (**64**) — the refusal then prints the working form:

```
$ fouine search -type:pdf reactor
Error: Unknown option '-type:pdf'
Usage: fouine search <query> …
fouine: hint — a query that starts with “-” is read as an option; put it after “--” (options before it): fouine search -- '-type:pdf reactor'
```

Accents may be typed or pasted: a path copied from `ls` carries them decomposed,
and `--path-contains "Polymères"` used to return 225 documents typed and 0
pasted. Both forms now count the same, here and in the query language.

```sh
fouine search 'enthalpy' --lang en --since 2024-01-01 --facet lang
```

`--lang` and `--since` are **real filters**, like `folder:` and `ext:`: they
enter the query, the announced totals follow them, and `--hybrid` applies them
to **both** channels. The language is the one Fouine detected at indexing;
documents too short or too mixed carry none and are asked for with `--lang und`.
The date of `--since` means the start of the day, in local time, and a
malformed date is an argument error (**64**) rather than an unbounded search.

`--source` is a real filter too, and the only one that bears on the **page**
rather than the document: origins are stored per page, and a PDF whose text
layer is missing on a few plates is the common case. One value only: asking for
all three is not filtering. A page with no recorded origin counts as typed text.

**`--facet doc_year` is the year the document CARRIES, and it comes first
because it is the one a human wants.** `--facet modified_year` counts the years
of the file's last modification, so a book from 2003 copied onto the Mac in 2024
falls under 2024 — on one witness query, 193 of 409 pages fell under 2026 for
that reason alone. That facet used to be called `year`, which said nothing of
the kind; `--facet year` is still accepted so that no existing script breaks,
but the key returned in `--json` is always `modified_year`. `doc_year` counts
the date read from the document's own metadata: PDF `CreationDate`, EPUB `dc:date`, office
`dcterms:created`, EXIF `DateTimeOriginal`, an email's `Date:` header. Documents
that carry none come out under the empty key. On a real index the difference is
5 values for `modified_year` against 31 for `doc_year`, at the same cost.

```
$ fouine search 'energy' --facet doc_year
facet doc_year:
  2013  3490
  2011  2803
        2085
  2016  2008
```

What Fouine does **not** read: the date written in the file NAME
("… crystallography (2003).pdf"). That is not metadata, and reading it would
mean guessing what a number in brackets means.

The ranking bonuses are **disarmed automatically** when a query matches at least
50 000 pages (the approximate-count threshold): the exact-phrase probe would
cost seconds there, and the order of the top ten is no longer something a human
could arbitrate. The typed-form bonus also exists only where morphology actually
inflected a word, so `--no-morphology` and `--raw-fts` turn it off in passing.

**A query the parser refuses** (a prefix under four letters, an exclusion alone,
an empty query, an FTS5 keyword typed bare, a filter that does not exist, a
folder label that does not exist) is an **argument** error: exit **64**, with
the usage, like a missing argument.

```
$ fouine search 'type:pdf nitrogen' ; echo $?
Error: “type:” is not a filter — filters are dossier:/folder:, ext:, pres:/near:, nom:/name:, texte:/body:
Usage: fouine search [<options>] <query>
64

$ fouine search 'polymer OR catalysis' ; echo $?
Error: “OR” is a search operator, not a word: Fouine combines words with AND by
default; to exclude a word, write -word (put it in quotes to search for the word
itself)
64

$ fouine search 'folder:Cour enthalpy' ; echo $?
fouine: unknown folder “Cour” — yours are: Books, M2SU
64
```

**The other filters follow the same rule**: `--lang` and `--in` used to return
zero results in silence, which is indistinguishable from a mute corpus. They now
refuse with **64**, naming what exists, in the same words as the assistant
server, because it is often a model reading them. One unknown value is enough,
even next to a good one; `und` is always accepted; and an index with no detected
language at all grounds no refusal.

```
$ fouine search nitrogen --lang xx ; echo $?
fouine: unknown language “xx” — languages in this index: en, fr, und
64
```

**`--mark` chooses what surrounds the matched words** in a snippet: `«…»` by
default, `[ … ]`, `** … **` or nothing. Pick another one when the documents
themselves use `«…»` — a French corpus quotes that way, and the highlight then
cannot be told from a quotation. The four values are those of the assistant
server's `marks`, and the default does not move: snippets are part of the frozen
schema.

**`--hybrid` without the model installed** does not stop: it says so on standard
error and falls back to full-text search, which needs no model. The JSON then
carries `"hybrid": false`, so a script knows what it actually got. A database
**with no vector**, on the other hand, stays an error (**3**): the model is
there, `fouine embed` is all that is missing, and hiding the case would hide the
gesture.

**`--hybrid-auto` never fails on either count.** It merges when the model and
the vectors are there, searches full text otherwise, and says nothing about it —
exit **0**, `"hybrid": false` in the JSON. That is what a script wants when it
does not know whether meaning search has been prepared on this Mac. It is a
separate flag rather than `--hybrid=auto` because an option with an *optional*
value cannot be expressed: `--hybrid azote` would have swallowed the query.

**A scope with no vector in it does not load anything.** `dossier:Courses
--hybrid` used to spend about four seconds loading the model and the vector
index to compare **zero** vectors — the folder had none — and then announced the
coverage of the *whole* index, 67.85 %, as though it described that folder. The
scope is now read first, from two counts: when it carries no vector the answer
is the full-text one, whole, with `"hybrid": false`, `hybrid_disarmed:
"no_vectors_in_scope"`, and this line on standard error:

```
$ fouine search 'dossier:Courses reactor' --hybrid --json
fouine: warning — no vectorised page in this scope (folder Courses: 0 of 31986) — `fouine embed --folder Courses` prepares it
```

`semantic_coverage_pct` is then the coverage **of the scope**, and
`semantic_scope` (`pages`, `vectorised`, `filtered`) says what the meaning
channel sees of the search that was asked. Both keys are the assistant server's.
Every hybrid answer carries them; a full-text answer carries them when a
document filter (`dossier:`, `ext:`, `nom:`, `chemin:`, `--in`, `--lang`,
`--since`) actually narrowed the scope — that count is not taken otherwise,
because without a filter the scope *is* the index and `vectors` /
`pages_indexed` already say so. Reading the scope costs a few milliseconds
against about four seconds saved; the unfiltered search pays nothing at all.

**An exact-phrase query does not consult meaning.** `"ideal gas" --hybrid`
returns the full-text search, whole (facets, name matches, fallback), and says
so on standard error: `meaning search not used: the query asks for an exact
phrase`. The JSON carries `hybrid: false` **and** `hybrid_disarmed:
"exact_phrase"`; `hybrid: false` alone would suggest an incomplete
installation. The model is not loaded: measured on a real index, 2 688 ms → 33
ms. `--raw-fts` is not concerned, the parser never having seen the string.

**When the exact search returns nothing, the query is replayed once** tolerating
typos across **all** documents, and the command says so on standard error, in
both modes: `No exact match — showing close spellings from every document.` The
JSON then carries `fuzzy_fallback: true` (absent otherwise) and each result
keeps its `fuzzy_distance`. The normal path pays nothing. The fallback does not
happen with `--fuzzy off`, nor with `--raw-fts`, nor beyond the first slice.

**The quorum loosens the AND on *all* the words**, and only when the strict
search returns fewer than **ten** pages: the query is replayed requiring 60 % of
the words longer than three letters, pages carrying them all keep the lead, and
the command says so on standard error: `Few pages carry every word — also
showing pages that carry most of them.` The JSON then carries `quorum: true`. A
phrase, a `pres:`, a `*` prefix, an exclusion, a `nom:` filter and a query
restricted to one origin stay strict; a folder, an extension, a language or a
date **do not** disarm it any more — the same question returned 28 pages on its
own and zero under `dossier:Livres`. About eighty French and English function
words are never required, and a question with more than six meaningful words
keeps the six longest. **It applies with `--hybrid` too**, since 14/09/2026: the
merge's lexical channel was loosening the AND without saying so, and the
assistant server had been arming and announcing it since the day the flag
existed — two surfaces saying different things about the same results is worse
than one debatable convention. `--no-quorum` disarms it in both modes. The `why`
of a result that comes from the loosened pass reads `partial`, never `exact`:
the page does not carry every word.

**Some results carry a close spelling without any fallback.** In `auto` mode,
the query is widened as soon as the exact search matches fewer than 20 pages,
inside the ordinary pass — `fuzzy_fallback` says nothing about that, since it
only covers the replay. The JSON carries `fuzzy_expanded: true` whenever a
result shown has a `fuzzy_distance` above zero, and the command says so on
standard error: `some results carry a close spelling of your word, not the word
itself — see why.found`. Each result's `why` names the spelling that was found.
Over every document, the tolerated distance is **1 from 6 to 8 letters** and 2
from 9; on scanned pages it stays 2, where the mistakes are the machine's.

**Tables of contents move down**: the text of the first fifty results is read
again, and the ones that are contents pages, indexes or keyword lists go behind
the others. None is removed and the totals do not move. The `why` object of
those results then carries `table_of_contents: true`. `--no-demote-toc` disarms
it. Known limitation: a glossary (short entries, cross-references, trailing page
numbers) passes for a contents page.

**Documents found by their file NAME** come out on their own line: `fouine
search IP2022` used to return seven unrelated pages while three files are called
`IP2022__Analysis_JB_DELIVERABLE_…`. They are documents rather than pages, so
they change neither `total_pages`, nor `total_docs`, nor the order of the
results. Five at most, only when a word of the query is at least three
characters, and the `folder:`, `ext:` and `--in` filters apply to them.

```
$ fouine search IP2022 --limit 5
7 page(s) in 7 document(s) in 172.90 ms
3 document(s) whose name matches: IP2022__Analysis_JB_DELIVERABLE.raw.md · IP2022__Analysis_JB_DELIVERABLE.md · IP2022__Analysis_JB_DELIVERABLE.pdf
```

**The JSON has a stable schema**: `query`, `offset`, `has_more`, `elapsed_ms`,
`total_pages`, `total_docs`, `hits[]` (with `doc_id`, `path`, `folder`, `page`,
`score`, `bm25`, `relevance_pct`, `source`, `engine`, `fuzzy_distance`,
`snippet`, `link`, `time_seconds`, `slide`, `embedded_image`, `why`) and,
with `--facet`, `facets`. Extra keys appear when they have reason to:
`fuzzy_fallback: true`, `name_matches[]` (`doc_id`, `path`, `folder`, `link`,
the link pointing at page 1 of the document), `quorum: true`, and
`hybrid_disarmed` (with `hybrid: false`) when a quoted phrase set the semantic
channel aside. Beyond 50 000 matched pages, `total_pages` is capped at 50 000
and the boolean `totals_approximate: true` is present; in the text output the
totals carry a "> " prefix and an advice line follows: `very common word — add a
second word to narrow the search`.

`score` is **rounded to four decimals**, the same figure and now the same
rounding as the `bm25` of the assistant server's `fouine_search`. It used to
publish 17 significant digits, which is 17 digits that will move at the first
change in FTS5.

**`bm25` carries that same number under the assistant server's name**, and it is
`score` that is now **deprecated**: "score" does not say which scale it speaks
of, while `bm25` names its own. `score` stays — the schema is frozen — and will
be dropped no earlier than 1.1; write `bm25` in anything new. Unlike `score`,
`bm25` is always present and `null` for a page the semantic channel alone
returned: a missing key teaches nothing.

**`relevance_pct` is the percentage the text output has always printed**, now
published: this hit's score as a share of the **best-scoring hit of this reply**,
0 to 100. It is relative, never absolute, and it cannot be compared from one
query to the next — 100 means "nothing here scores higher", not "the answer". In
hybrid mode it reads on the `rrf` rather than on the `bm25`, since half a hybrid
list has no `bm25` at all. The order of the list can differ from it: under a
quorum pass the pages carrying every word keep the lead even when a looser page
scores better. The text output prints it for full-text searches only, where the
two channels share a scale.

**Three keys say what a page really is**, and they are always present, `null`
when the question does not arise. `slide` is the slide number for a `.pptx` or
`.odp`: cite the slide, not the page — the pictures embedded in the file are
pages too, and they come after the slides. `embedded_image` is the rank of the
picture when the page *is* one of them. `time_seconds` is where the excerpt sits
in a recording, in seconds from the start, for a transcribed page only: a page
covers ten minutes of speech, so "page 1" of a two-hour video sends nobody
anywhere. The moment is read from the timestamp that precedes the matched word,
falling back to the start of the page.

**Hybrid keys come IN ADDITION, never instead.** Hybrid mode used to remove
four of them, so a script reading `hits[].folder` broke as soon as `--hybrid`
was added. In hybrid mode, `total_pages` and `total_docs` hold the **lexical**
totals (`lex_total_pages`, `lex_total_docs`, which remain): that is the only
population one can count, the semantic channel returning a neighbourhood rather
than a set of matched pages. Only `score` stays reserved to results the lexical
channel found (`semantic_only: false`); inventing a bm25 for a page returned by
meaning alone would be a false number. Hybrid mode adds `hybrid`, `offset`,
`has_more`, `lex_total_pages`, `lex_total_docs`, `semantic_only`,
`semantic_floor`, `semantic_kept`, `vectors`, `pages_indexed`,
`semantic_coverage_pct`, `semantic_scope`, `semantic_rank_scale`,
`semantic_stats`, possibly `model_load_ms` and `index_load_ms`, and, per hit,
`rrf`, `lex_rank`, `vec_rank`, `cosine`, `z`. `quorum: true` appears there under
the same rule as in full text — only when the pass took place — so a script
reading both modes no longer has to know which one loosens the AND.

`link` is the page's **deep link**: `fouine://open?path=<absolute
path>&page=<n>`, pasteable into a dissertation or an email, and reopening the
app on that exact page. When the document's volume is not mounted the absolute
path is unknowable, and the link takes the fallback form
`fouine://open?doc=<id>&page=<n>`, valid only on this machine and this index.
The link grammar also has a `t=<seconds>` parameter, the moment in an audio or
video file, which the app puts into its player when opening. **A transcribed
page carries it**, in `search --json`, in `read --json` and in the assistant
server alike: the link then opens the recording where the words are, rather than
ten minutes earlier. Every other page cites the page, as before.

`why` says **why this page is here**: `kind` is `exact` (the page carries the
words, `terms_found` lists them), `partial` (the page carries only some of them
— the case of every result of a quorum pass, where `terms_found` lists what the
snippet shows and `terms_missing` is absent), `fuzzy` (a close spelling:
`typed`, `found`, `distance`), `semantic` (none of your words, meaning alone) or
`both`. It is
computed **on the snippet** rather than on the page read again: no cost, and the
snippet is what the caller has in front of them. Hence one rule: it **never**
concludes that a word is missing. A lexical hit carries every positive word,
which is what `a AND b` means, and the snippet often shows only one.
`terms_missing` therefore comes only from the app, which reads the whole page.
The `why` key is absent when there is nothing honest to say.

In hybrid mode, when **no** page carries the words (`lex_total_pages: 0`) and
results come out anyway, the text output adds a line. Which line depends on what
the index actually holds: `none of your words is in your documents — these
results come from meaning alone` when none of the words exists anywhere, and
`no page carries your words together — these results come from meaning alone
(words present: reactor, residence)` when they do exist but never on one page.
The first sentence used to be printed in both cases, and it was false in the
second: a nine-word question under `dossier:Livres` was told its words were
nowhere, while one of them was in 22 documents of that very folder. That is not
a filter, and it is a measurement result: see [searching](search.md).

`semantic_stats` describes the population the vector sweep crossed for THIS
query: `mu` and `sigma` (mean and standard deviation of the cosines, over
non-null vectors, pages too short being counted apart in `zero_vectors`),
`cos_max`, the margins `z_max`, `z_at_10`, `z_at_200`, and `scanned`. It is the
instrument for calibrating the ranking, and it is permanent. `cosine` is kept
for whoever knows what to do with it, and **it is not relevance**: on a real
corpus every cosine of this model sits between 0.78 and 0.88 and follows the
shape of the query. What the text output shows, and what a caller should read,
is `z`, the margin in standard deviations.

```
$ fouine search 'catalysis' --hybrid --limit 2
fouine: warning — semantic channel covers 16.6 % of the pages (64872 / 390114) — hybrid results are drawn from that subset; `fouine embed` extends it
2 hybrid hit(s) — lexical: 784 page(s) / 108 document(s), semantic only: 1, in 1697.47 ms (64872 vectors, 16.6 % of pages)

• [130] …/Advanced Inorganic Chemistry 6e - Cotton.pdf p.1180 — rrf 0.0164 · sem#1 z+5.0
    Chapter 21 FUNDAMENTAL REACTION STEPS OF TRANSITION METAL CATALYZED REACTIONS…

• [922] …/01_Catalysis course.pdf p.2 — rrf 0.0164 · lex#1
    Différents types de «catalyse» «catalyse» «Catalyse» homogène…
```

The coverage warning appears only **under 50 %** of pages vectorised.

### `fouine list [options]`

**Browse** the index, without searching for a word. It is the answer to "what
does Fouine know, exactly?": `fouine search ""` answers "empty query", and
nothing else returns the list of documents.

| Option | Effect |
|---|---|
| `--folder <label>` | one folder, by its label (`fouine root list`); an unknown label is refused with 64 and the list of the real ones |
| `--ext <ext>` | extension, without the dot |
| `--path-contains <fragment>` | a path fragment, matched literally (`%` and `_` are not wildcards) |
| `--state <indexed\|failed\|skipped\|pending>` | keep only these states; **repeatable** (`--state failed --state skipped` returns exactly what `status --unreadable` returns). Without the option: **every** state |
| `--order <path\|pages\|recent>` | `recent` = most recently modified first (**default**), `path` = alphabetical, `pages` = longest first |
| `--limit N` | documents per page (**50** by default, ceiling **500**; beyond that, 64) |
| `--offset N` | skip the first N (paging) |
| `--json` | JSON output |

**Read-only**: `fouine list` never opens the database for writing, never creates
a missing index (refusal with 3) and never takes the write lock, so it answers
during an indexing pass.

```
$ fouine list --folder Books --order pages --limit 3
  Users/mathis/Books/Chemistry/Advanced Inorganic Chemistry 6e - Cotton.pdf · 1376 p. · 2024-11-03
  Users/mathis/Books/Physics/Landau — Mechanics.pdf · 224 p. · 2025-02-14
  Users/mathis/Books/Notes/notes.txt · 3 p. · 2026-09-01 · pending
  3 of 1527 documents — `--offset 3` for the next ones
```

The date after the page count is the **file's**. When the document carries a
date of its own, it is added in plain text (`dated 2003-04-12`), and nothing
appears otherwise: most formats date nothing, and an empty column on a thousand
lines would teach only that. The state is written only when it is **not**
`indexed`, the normal case, since repeating it on a thousand lines would drown
the few that say something.

In `--json`, **exactly the keys of the assistant server's
`fouine_list_documents`**, so a script written for the assistant reads the CLI
without translation: `documents`, `total`, `has_more`, `truncated`, and per
document `doc_id`, `path`, `link`, `folder`, `ext`, `pages`, `modified`,
`state`, `doc_date`, `error`, `ocr_pages` and `vectorised_pages`. The two
surfaces now carry the same set: `modified` (ISO 8601, machine time zone)
arrived here first and the server gained it later, `ocr_pages` and
`vectorised_pages` the other way round. Only `abs_path` is missing here, and the
`link` carries it.

`error` says **why** a document is missing from the results — "iWork document
without a QuickLook preview", "encrypted PDF" — and is `null` when there is
nothing to say, which is the normal case. It is written at the end of the table
line too, right after the state, so that a failure needs no second command to be
understood. `vectorised_pages` counts the pages of that document that search by
meaning can see: it is the only way to notice that a whole folder is at zero
while the overall coverage announces two thirds. `ocr_pages` counts the pages
whose text was **read off the image**, which is what tells a scan from a typed
document; a page transcribed from speech does not count there, it has its own
origin. The `link` names the **document**,
with no page, because a listing does not claim to have found one. `truncated` is
always `false` here, the only ceiling being `--limit`, which is a request rather
than a truncation; the key is present so a script written on the assistant
contract need not tell the two surfaces apart.

### `fouine read <doc_id> <page> [options]`

Prints the indexed **text** of one page — what Fouine extracted or recognised,
not the original file. It is the answer to "I found it, now what does it say?":
`fouine search --json` gives the `doc_id` and the `page`, this reads them.

| Option | Effect |
|---|---|
| `--max-chars N` | characters read from this page and from each context page (**4000** by default, 200 to 40000) |
| `--offset N` | start reading this many characters in (paging inside a long page) |
| `--context N` | also read N pages before and after (0 to **2**) |
| `--json` | JSON output |

**Read-only**, like `list`: it never creates an index and never takes the write
lock. Same implementation as the assistant's `fouine_read_page` — the two must
not drift — and therefore the same keys in `--json`: `doc_id`, `page`, `path`,
`abs_path`, `folder`, `ext`, `link`, `page_count`, `text`, `chars`,
`total_chars`, `truncated`, `next_offset`, `source`, `engine`,
`ocr_confidence`, `note`, `page_label`, `slide`, `embedded_image`,
`time_seconds`, and `context` when it was asked for — the context pages carry
the same keys.

**Read `page_label`, `slide`, `embedded_image` and `time_seconds` before citing
a page**: they say what "page N" really means. Page 170 of a slide deck is
often the 117th picture embedded in it; page 12 of a book is printed "xi"; page
2 of a recording starts ten minutes in, and the `link` then carries `&t=`.
Each is `null` when the question does not arise.

**`page_label`** is the number *printed* on the page when it differs from its
rank — `"xi"` for page 12 of a book with roman front matter. It is `null` when
the two agree, for anything but a PDF, and for a book whose number lives only in
the running head (no `/PageLabels` in the file): Fouine returns nothing rather
than the rank dressed up as a printed number. Reading it opens the PDF, which
costs about 140 ms on a 428-page book and 240 ms on a 1 173-page one — fine for
one page, which is why `fouine search` does not carry it.

```
$ fouine read 1259 12
[1259] Users/mathis/Courses/GRC/part 3.pptx · page 12/202 · native
Heterogeneous catalysis: the reaction takes place at the surface…
… 3180 character(s) left — `--offset 4000` for the rest
```

A page that exists but carries **no indexed text** is a success with an empty
text and a `note`: it is an image waiting for recognition, not a missing page.
A page the document does not have, or an unknown `doc_id`, is a usage error
(**64**) whose message says how many pages the document really has.

### `fouine similar <doc_id> <page> [options]`

Lists the pages **closest in meaning** to a given page, read from the vectors
already in the index. It never loads the model, so it answers in milliseconds;
in exchange, a page that has not been vectorised yet has no neighbours to offer
and the command exits **1** saying so, with the gesture (`fouine embed`).

| Option | Effect |
|---|---|
| `--limit N` | neighbours returned (**10**, ceiling 50) |
| `--folder <label>` | restrict to one folder; an unknown label is refused with 64 |
| `--ext <ext>` | restrict to one extension, without the dot |
| `--no-exclude-same-document` | keep the neighbours that come from the same document (excluded by default) |
| `--min-cosine C` | floor, 0 to 1 (**0**: no floor) |
| `--preview-chars N` | characters of preview per neighbour (200) |
| `--encode` | when this page has no vector, encode it now — this loads the model |
| `--json` | JSON output |

**The cosine is not a relevance.** Measured on a real corpus, every value sits
between 0.78 and 0.88, and the position inside that band follows the shape of
the text more than its subject: that is why the floor defaults to 0. Keys of
`--json`, those of `fouine_similar_pages`: `neighbours` (each with `doc_id`,
`page`, `path`, `abs_path`, `folder`, `ext`, `link`, `cosine`, `preview`),
`vector_count`, `coverage_pct`, `model_id`, `revision`, `source_has_vector`,
`source_vector`, `note`, `elapsed_ms`.

**`--encode` is the only door through which this command loads the model**, and
it is shut by default. A whole folder can sit at zero vectors until the campaign
reaches it — measured on a real index, one root held 0 vectors for 139 638
pages — and "no neighbour" then reads as "nothing resembles this page", which is
false. `--encode` pays the encoding for *this* page: about 2 s the first time,
and the vector is the one the campaign would have produced (same windows, same
null-vector rules, same quantisation), without which the cosines would be
comparable to nothing. `source_has_vector` describes the **index** and stays
false in that case; `source_vector` says where the vector used came from —
`stored`, `computed`, or `null` when there is none. Without the option, the
refusal (exit **1**) names the option.

```
$ fouine similar 1 50 --limit 3
  0.864  [1] Users/mathis/Books/Chemistry/Cotton.pdf · page 214
         the crystal field splitting of an octahedral complex…
```

---

## Diagnosis

### `fouine status [--json] [--unreadable]`

State of the index: documents, pages, size of the database, length of the
recognition queue, folders and their state. Folders whose scanned pages are read
first carry a `★`.

It also gives:

- **the state of the background agent**: phase (`idle`, `walking the folders`,
  `extracting text`, `text recognition (OCR)`, `waiting`, `stopped`), current
  document or waiting condition, progress, pid, and how long the status has been
  still. A status whose process has disappeared, or which has not moved for five
  minutes, is marked **PROCESS GONE** or **STALE STATUS**: a bar frozen since the
  day before yesterday would mislead more than it informs;
- **the effective settings** and where they come from (see `fouine config`);
- **the vectorisation campaign in progress**, if there is one: the line
  "vectorisation: running (pid N, since HH:MM)" appears only while the campaign
  lock is held. It is the answer to "is my campaign still running?", which the
  write lock could not give, being released between batches.

```
$ fouine status
documents   total 1 · extracted 1 · failed 0 · skipped 0 · language unknown 0
pages       indexed 1 · native 1 · ocr_accurate 0
OCR pages   doubtful 0 (0 < conf < 0.6) · no recognised line 0
OCR queue   0 page(s)
vectors     0 page(s) vectorised, 0 vector(s) (0 page(s) complete — hybrid search, `fouine embed`)
database    274992 bytes (275 kB · 5.0 KiB/page · at full meaning coverage ~0.28 MB (0 % of the 2.5 GB budget) · budget reached near 9,048,000 pages) — /Users/…/fouine.db
agent       no report published yet — run `fouine doctor` to check background agent status
roots:
  [1] Corpus  /Users/…/corpus
        enabled=true mounted=true readable=true
effective settings (`fouine config list` for the details):
  ocr.languages                fr-FR,en-US  [default]
  …
```

In JSON, the agent and the settings are the keys `agent` and `settings`; every
earlier key is unchanged, and the `phase` key carries the stable identifier
(`idle`, `crawl`, `extract`, `ocr`, `waiting`, `stopped`) rather than the
sentence. What the agent SAYS it is doing is a language-free token
(`starting`, `queue-drained`, `pages-queued(20226)`, `pages-left(315)`,
`signal-received(SIGTERM)`, `document(Course.pdf)`): the text output renders it
in English, the JSON keeps the token in `agent.detail`, which is what a script
compares, and adds `agent.detail_text`, its English reading. An unknown token,
written by an agent of another version, passes through in both.

JSON also carries `db_bytes`, `bytes_per_page`, **`db_path`** (the index
actually read) and **`docs_without_language`**, the number of documents whose
language is still to be determined. The text output says that at the end of the
`documents` line ("language unknown 3"); it goes down by itself, 300 documents
per indexing pass, and `fouine maintain --detect-languages` zeroes it at once.

**`semantic_campaign`** is `null` when nobody is vectorising, and `{"pid": N,
"since": "<ISO 8601>"}` when a campaign holds the lock. The key is always
present, so a script need not tell "absent" from "no campaign".

**`write_lock`** appears in **exactly the shape `doctor --json` uses**:
`status` (`free`/`held`/`stale`), `held`, `probe` (the fact, `free` or `held`)
and, when someone is named, `role`, `pid`, `since`. `status`, `doctor` and the
assistant server's `fouine_status` describe the write lock the same way because
they share one constructor. It is a probe: `status` never takes the lock.

#### The `database` line: where the disk budget stands

The SPEC allows **2.5 GB** of index (criterion P5, decimal GB, the way the
Finder counts). The line says the real horizon rather than a linear
extrapolation:

```
database    2151145472 bytes (2.15 GB · 5.1 KiB/page · at full meaning coverage ~2.27 GB (91 % of the 2.5 GB budget) · budget reached near 451,000 pages) — /Users/…/fouine.db
```

- **`at full meaning coverage`** adds the vectors of the indexed pages that do
  not have theirs yet: 2.15 GB today, ~2.27 GB once `fouine embed` has
  finished, at unchanged corpus. The geometry is a constant rather than a
  measurement: sweeping `page_vec` to measure it costs 1.5 s on a real index to
  move the projection by less than 5 %.
- **`budget reached near N pages`** is the page count at which the budget would
  be reached, at the "complete vectors" cost per page (5.5 KiB/page on the
  reference corpus, 8.3 KiB/page on a corpus of letters).
- The line costs **no new read**: all three numbers are already computed.

In JSON, the additive object **`disk_budget`**:

| key | value |
|---|---|
| `bytes` | size of the database today (= `db_bytes`) |
| `budget_bytes` | `2500000000` |
| `bytes_at_full_vectors` | the projection at full coverage |
| `ratio_now`, `ratio_at_full_vectors` | fractions of the budget, three decimals |
| `pages_at_budget` | pages at which the budget would be reached; `null` on an empty index |
| `level` | `ok` (< 80 %), `near` (80–100 %), `over` (≥ 100 %), read on `ratio_at_full_vectors` |

**Nothing stops at 100 %**: `level` is a warning. `fouine doctor` carries the
same information in one sentence, with the gesture, and **only** when `level` is
not `ok`.

#### `--unreadable`: which documents were not read

`status` announces `failed 2 · skipped 2` and no command said **which**.
`--unreadable` adds one line per document, `path · extension · reason`, 500 at
most, then "… and N more".

```
$ fouine status --unreadable
…
documents not read (3):
  Books/damaged-scan.pdf · pdf · PDF is encrypted (password protected)
  Notes/notes.xyz · xyz · skipped (no extractor for this format)
  … and 1 more (`fouine status --unreadable --json` lists them all)
```

In JSON, two keys **present only with the option**: `unreadable`, an array of
`{path, ext, reason, status, doc_id}` (`status` uses the same vocabulary as
`fouine_list_documents`: `failed`, `skipped`), and `unreadable_total`, the real
count. **Without the option, the output of `status` is what it always was.**

### `fouine doctor [--json] [--deep]`

The first gesture when in doubt. It returns:

- the **context tested**: the CLI inherits the permissions of the **terminal**
  that runs it, the app has its own, so `doctor` can succeed in Terminal while
  the app is refused, and the reverse;
- the path and size of the database, the length of the recognition queue;
- the state of the **write lock**, PROBED without waiting: `free`, `held by
  <role> pid N since <date>` or `stale (…)`. A name left by a killed process now
  answers **`free`**, and the file is cleaned up on the way, which is the only
  way to keep a recycled pid from making Fouine announce "the index is being
  written" forever. In JSON: the `write_lock` object. A `stale` lock does **not**
  invalidate `ok`;
- the presence of **djvulibre**, with the gesture when it is missing;
- the presence of the **meaning model**: "present (revision N)" or "MISSING —
  `fouine model download` installs it". Without it, `embed` refuses to start and
  `search --hybrid` falls back to full text saying so, an absence that showed
  nowhere else. In JSON: `semantic_model` (boolean), `semantic_model_path`,
  `semantic_model_vectors`, `semantic_model_revision`;
- the state of the **background agent**, crossing the status table with
  `launchctl print`: registration, service state, failure to launch (`spawn
  failed (EX_CONFIG)`) or prolonged silence, with the matching remediation. In
  JSON: the `background_agent` object. When the service is not running AND the
  database carries a status more than an hour old, the line says how long it has
  been silent:

  ```
  background agent : not registered — has not run since 2026-09-05T23:13:07+02:00 (3 d 10 h) — turn “Keep the index up to date automatically” back on in Fouine.app
  log            : 2026-09-05 23:13:07 stopped (SIGTERM)
  ```

  In JSON, `background_agent` then gains `last_run`, `idle_seconds` and
  `guidance`. **`ok` stays `true`**: a Mac switched off for three days is not
  broken. The `log_last_line` key is **always** present (`null` with no log): it
  is the last line of `~/Library/Logs/Fouine/fouine.log`, the only place an
  incident shows;
- the **copies of `Fouine.app`** LaunchServices knows about (line
  `application`). One, in `/Applications`: the path, and nothing more. Several,
  or one outside `/Applications`: the count, the one macOS would open, the
  others, and the gesture. That is the cause, invisible everywhere else, of a
  registered agent failing with `EX_CONFIG`. In JSON: `app_copies` (always
  present, empty when the app is not installed), `app_default` and
  `app_copies_guidance` when there is a gesture. These keys do **not** invalidate
  `ok`: a missing app is the normal case for a CLI built from the repository.
  Since LaunchServices answers only for the **current** identifier, an app
  carrying another one is invisible to it, so `doctor` also reads the
  `Info.plist` at the canonical location on disk and publishes it as
  `app_at_expected_path` (always present: `null` if there is nothing in
  `/Applications`, otherwise `{path, identifier, version}`);
- for each folder: volume mounted or not, and the **effective read** of a file.
  It opens a file rather than doing a `stat`.

**`--deep`** adds a thorough check of the database. It runs `PRAGMA quick_check`,
verifies the integrity of the FTS5 tables, reports the number and size of pages,
the fragmentation of the free list, the size of the write-ahead log, the
journalling mode, and **the coherence of the vector table**, counting and naming
the rows no version of the pump could have written:

| category | what it is |
|---|---|
| `foreign_slot` | window slot out of range: no version of the pump could have written it |
| `orphan_page` | the row points at no indexed page |
| `broken_sentinel` | the page claims to be complete although its first window is missing, so `fouine embed` would never take it back |

A row counted here is a row the semantic channel folds onto some page: when that
page exists, search returns a path, a page number and a snippet that are
perfectly credible for a page **unrelated to the query**. The gesture is `fouine
maintain --repair`, then `fouine embed` to produce the missing vectors again. In
JSON, the `database.vectors` object (`rows`, `inconsistent`, a count per
category, `samples`, `elapsed_ms`); an inconsistency sets `ok` to `false`
**without changing the exit code**, repair being a gesture rather than a failure
of the command that reports it. `--deep` also publishes `database.doc_names`
(`docs`, `names`, `consistent`), the gap between the documents and the table of
their names. A gap deprives documents of their name ranking bonus; it falsifies
**no** result, so it does not set `ok` to `false`. The fix is `fouine maintain
--repair`.

**`--deep` takes several minutes on a large index**: 86 s measured on 2.2 GB
with the machine free, 177 s on 2.15 GB with a compilation running alongside.
The command announces the expected duration before starting, each step announces
itself, and the final report gives its duration:

```
  step quick_check   : 79592.8 ms
  step page_vec      : 5501.7 ms
  step docs_fts      : 8.9 ms
  step fts5_integrity: 91962.2 ms
  check duration     : 177067.4 ms
```

The two big items are roughly equal, `quick_check` reading the whole database
and the FTS5 check reading it again. In JSON, `database.steps` is the list
`{name, elapsed_ms}` in order of execution, and no progress line is written in
`--json` mode.

**During the FTS5 check, `--deep` holds the write lock** (role `cli`): the FTS5
integrity check is an `INSERT`, and SQLite opens a write transaction for its
whole duration; without the named lock, the agent or the app would hit
`SQLITE_BUSY` without knowing who was blocking them. If another process is
already writing, `--deep` exits **3** naming the holder, like `fouine index`.
Without `--deep`, `doctor` takes no lock at all.

```
$ fouine doctor
context tested : CLI — inherits the permissions of the terminal that runs it (the SMAppService agent, for its part, can show no privacy prompt at all)
database       : /Users/…/fouine.db (200808 bytes)
write lock     : free
OCR queue      : 0 page(s)
text-layer probe : available
djvulibre      : /usr/local/bin/djvused
semantic model : MISSING — `fouine model download` installs it
background agent : not registered
application    : /Applications/Fouine.app

root [1] Corpus
  path    /Users/…/corpus
  volume  75F6E680-A01E-49E2-A130-1800826B45AA — mounted
  effective read of a file: OK
```

A **`disk budget`** line is added after `database` **only** when the index
reaches 80 % of the expected size:

```
disk budget    : 86 % now, 91 % at full meaning coverage of the 2.5 GB budget — nothing stops at 100 %; free space with `fouine maintain --vacuum`, or remove folders you no longer need
```

Under 80 %, `doctor` says nothing about it: mentioning a ceiling to someone at a
tenth of it teaches nothing. That line never sets `ok` to `false` and does not
change the exit code. In JSON, `disk_budget` (the same object as `status
--json`) is always present, and `disk_budget_guidance` carries the sentence when
there is one.

Exit **5** if a folder is unreadable, naming it and giving the gesture:
"effective read of a file: FAILED — read denied (privacy settings or file
permissions)", followed by "what to do: System Settings ▸ Privacy & Security ▸
Files and Folders ▸ Fouine ▸ Documents Folder". The gesture accompanies a read
refusal ONLY: a folder that has disappeared says "folder not found (moved,
renamed or deleted)" without mentioning privacy.

---

## Backup and maintenance

### `fouine backup <destination> [--force] [--json]`

Hot online backup through the SQLite backup API.

- **No named lock**: it never takes `fouine.lock`, so the app and the agent can
  keep writing during the copy.
- **Coherent snapshot**: in WAL mode, the backup API picks up the pages changed
  by concurrent writes until the snapshot is coherent.
- **Guards**: it refuses if the destination is the source or sits under the
  database's directory; if the destination file already exists (unless
  `--force`); if the free space on the destination volume is under 1.2 times the
  size of the database. After the copy it checks the integrity of the copy
  (`PRAGMA quick_check`, FTS5 integrity check on each table); on failure the
  corrupt copy is deleted at once and the command fails (code 1). The file it
  creates is restricted to `0600`.
- **Output**: destination path, size, duration, results of the two checks. In
  `--json`: `{ "destination", "bytes", "elapsed_ms", "quick_check",
  "fts_integrity" }`.

```
$ fouine backup /Volumes/Backup/fouine-backup.db
backup completed successfully:
  destination   : /Volumes/Backup/fouine-backup.db
  size          : 1845493760 bytes (1760.00 MB)
  duration      : 2341.2 ms
  quick_check   : ok
  fts_integrity : ok
```

### `fouine maintain [--vacuum] [--force] [--repair] [--detect-languages] [--redetect-languages] [--json]`

Periodic maintenance and optimisation of the database. It takes the write lock
under the role `cli`, with the same message and the same exit code 3 as `fouine
index` when another process is writing.

Operations, in order: optimise the two FTS5 tables, `PRAGMA optimize`, then
`PRAGMA wal_checkpoint(TRUNCATE)`. With `--vacuum`, a SECOND checkpoint runs
**after** the compaction, before measuring the size: measured right after the
`VACUUM`, the sum of the three files counted the rewritten database twice, and
the command announced "23 MB → 47 MB, 0 bytes reclaimed" at the very moment it
had reclaimed 5.5.

- **`--repair`** deletes from the vector table the rows `doctor --deep` reports
  (the three categories above), **before** the optimisations, in the same
  transaction and under the same lock. Pages that lose their completeness marker
  become "to vectorise" again, and `fouine embed` picks them up with no other
  gesture. It also rebuilds the table of document names from the documents
  (a few thousand rows, instantaneous), and clears the recognition failure mark
  of documents that have **no** scanned page and nothing queued: the old
  wholesale re-reading used to set it on pages transcribed from audio. A real
  unreadable scanned page keeps its own. Output: the count per category, the
  number of pages requeued, the line `OCR failure marks cleared`; in JSON, the
  `vector_repair` object and the integer `ocr_failures_cleared`.
  **Without the option, `maintain` touches no data.**
- **`--detect-languages`** determines the language of documents that have none.
  A document's language is written at extraction, and a scanned document has no
  text then: its language only arrives after recognition. Nothing is extracted
  again, the text being in the index already, and only the first 4 000
  characters of each document are read. A document whose language cannot be
  determined gets the `und` token rather than nothing, otherwise it would be
  read again at every pass for the same answer. Output: documents read, what is
  left, the breakdown by code; in JSON, the `language_backfill` object. The
  catch-up also happens by itself, 300 documents per indexing pass: this option
  exists so you need not wait.
- **`--redetect-languages`** determines the language of **every** document
  again, including those that already have one. It is the only way to take back
  a corpus indexed before a fix to detection. Measured on a copy of a real
  index: 1 504 documents in 26.6 s.
- **`--vacuum`** compacts the database to reclaim free space. It refuses if the
  free disk space is under twice the size of the database (`VACUUM` rebuilds a
  full temporary copy), announces the expected duration and the estimated gain
  before starting, and is skipped when there is nothing to reclaim, unless
  `--force`.

```
$ fouine maintain --vacuum
running VACUUM: estimated gain 450560 bytes, reading 1760 MB, this can take ~3 s...
maintenance completed in 2840.1 ms:
  - page_fts optimize          : 120.4 ms
  - vocab_tri optimize         : 42.1 ms
  - PRAGMA optimize            : 15.2 ms
  - wal_checkpoint(TRUNCATE)   : 85.0 ms
  - VACUUM                     : 2577.4 ms
  reclaimed                    : 450560 bytes (0.43 MB)
  freelist pages               : 110 -> 0
  database size                : 1845493760 -> 1845043200 bytes
```

---

## Licences

### `fouine licenses [--full]`

Who owns what, without leaving the terminal. It returns the version, the holder
(Mathis Demory), Fouine's source-available licence, the address of the sources,
then one notice per redistributed component: GRDB.swift (MIT),
swift-argument-parser (Apache-2.0), Sparkle (MIT, plus the licences of its own
components), and the `multilingual-e5-small` model (MIT, Microsoft), which is
**used** but not shipped in the app.

The full text follows or not, depending on where the binary runs from:

- **from the app** (`Fouine.app/Contents/Helpers/fouine`, the
  `/usr/local/bin/fouine` symlink included): the complete text, read from
  `Contents/Resources/THIRD_PARTY_LICENSES.md`. That is the case of someone who
  has only the disk image, and to whom a path inside a signed package would be
  no use;
- **outside the app** (a clone, `.build/release/fouine`): the notices, then the
  path of `THIRD_PARTY_LICENSES.md` in the repository. `--full` forces the
  complete text there too.

This command does **not** open the database: it answers even when the index is
locked or absent. `fouine --version` is unchanged: it returns the number alone,
and scripts read it.

### `fouine license <status|activate|deactivate>`

**Singular**, and not to be confused with `fouine licenses` above: this one is
about **your** licence, the 30-day trial, the key you bought, and the Mac it
sits on.

Fouine runs for **30 days with nothing held back**. After that, search, preview
and export keep working; only **index updates** stop until a key is entered. A
key costs €39, once, updates for life, and covers **3 Macs**.

```
fouine license status [--json]
fouine license activate <key> [--instance-name <name>]
fouine license deactivate
```

- **`status`** says where you stand. It does **not** start the trial: the start
  date is set by the first launch of the app or the first `fouine crawl`, never
  by a command that only reads. When a key is installed and was last checked
  **more than 30 days ago**, `status` checks it first, as the app does at
  launch; offline, or if the service does not answer, nothing changes and one
  warning line goes to stderr (the JSON on stdout is unaffected).
- **`activate`** installs the key on this Mac. The key is cleaned before being
  sent (spaces, line breaks, lower case), so what you paste from an email works
  as it is. `--instance-name` replaces the name of this Mac shown in the
  seller's portal.
- **`deactivate`** releases this Mac's activation, so the key can be used
  elsewhere. If the seller answers that this Mac was **already released** (from
  the customer portal, or by an earlier deactivation), the licence file is
  cleaned all the same and the command succeeds with `This Mac was already
  released.`

The JSON of `status`:

```json
{
  "state": "trial",
  "days_left": 30
}
```

`state` is `trial`, `trial_over`, `licensed`, `revoked` or `released`;
`days_left` appears while the trial runs only; `key_suffix` (the last six
characters), `last_checked` (ISO 8601) and `activation_limit` appear only once
a key is installed.

`released` means the last check learned that **this Mac was freed elsewhere**,
from the customer portal: the key is removed from the licence file, and the
trial takes its course again (almost always over by then, so the index stops
being updated; search keeps working). It is not `revoked`, which is a key
disabled by the seller and kept in the file. Enter the key again with
`fouine license activate <key>` to use it on this Mac:

```json
{
  "state": "released"
}
```

A refused activation says why on stderr: `this key is already in use on 3
Macs` when the seller reports the activation limit, `this key was refused.
Contact the seller with the e-mail you used to buy it.` for any other refusal.
Both exit **7**, and the seller's raw text follows as a warning.

**Commands that write to the index refuse once the trial is over**: `crawl`,
`extract`, `index`, `ocr`, `embed`, with one line and exit **6**:

```
fouine: Trial over: enter a licence key (fouine license activate <key>) or buy
one at https://www.creem.io/product/prod_5ZfJoGBRk7vxCN8xMqvOcR. Search still
works.
```

`search`, `list`, `status`, `doctor`, `mcp`, `backup`, `config`, `root` and
`maintain` work in every state: the end of the trial stops the index being
updated, it does not hold hostage what is already in it. `embed --status` and
`embed --bench` stay readable for the same reason.

**What goes out on the network, exhaustively**: `activate` sends the key and the
name of this computer (the one you will see in your customer portal to
recognise the Mac to free); `deactivate` sends the key and the activation id;
`status` and the app's launch add a **check at most once every 30 days**, with
the key and the activation id. Nothing else, ever, and nothing about your
documents; `crawl` and the other indexing commands never go out. Everything goes
through a relay, `https://basedpolymer.eu/api/fouine/license`, which carries the
merchant's API key: the app does not call the seller directly, and could not.
`FOUINE_LICENSE_RELAY` replaces that address for testing (see the environment
variables below). See [privacy](privacy.md).

The licence file is `~/Library/Application Support/Fouine/license.json`, next to
the database, so `FOUINE_DB` takes it along onto a throwaway copy.

```sh
fouine license status --json
```

---

## Assistant

### `fouine mcp --stdio [--db <path>] [--folders <labels>...]`

Serves the index to an **MCP** client (Claude Code, Claude Desktop), speaking
JSON-RPC on standard input and output. A **read-only** server: it never writes
to the index, never starts an indexing pass, and never returns the original
files.

`--stdio` is **required** although there is no other transport: the day there is
one, an invocation with no transport should have been an error from the start.
Its absence exits **64**.

The log goes to **standard error** alone, one line per request, never the
content of a query or of a snippet; `FOUINE_MCP_LOG` is `quiet`, `info`
(default) or `debug`.

Five tools: `fouine_status` (health and coverage), `fouine_search` (full text
and meaning, returns **pages**), `fouine_read_page` (the indexed text of a page,
in slices), `fouine_similar_pages` (the semantic neighbours of a page, without
loading the model) and `fouine_list_documents` (what is indexed, and why a
document is not).

`--folders` **restricts** the server to some of the indexed roots, by label,
separated by commas (`--folders Livres,M2SU`); the option is repeatable. What is
outside that list does not exist for this server: it is absent from
`fouine_status.roots`, from every search, and from `fouine_read_page` even by
`doc_id` — an out-of-scope document gets the very refusal an unknown one gets. A
`folder` outside the scope is refused naming **only the served roots**.
`fouine_status` then carries a `scope` object (`null` without the option);
`documents` counts what is inside the scope, while `pages_indexed` and `vectors`
still describe the whole index, which `scope.note` says.

A label naming no root exits **64**, before the server says a word:

```
$ fouine mcp --stdio --folders Livre
Error: unknown folder “Livre” — folders in this index: Livres, M2SU, Personnel
```

`--folders` decides what an assistant may **read**; the exclusion rules
(`fouine root ignore`, or a `.fouineignore` file) decide what is **indexed at
all** (`fouine root list`, above). A folder that must never be searched, quoted
or counted belongs in the second.

The meaning model is loaded **lazily**, at the first hybrid call: a server doing
only full text stays around 16 MiB, where the semantic regime asks for a few
hundred. That is what makes the resident server worth it, hybrid search going
from 2.16 s on the first call to 0.32 s on the next, where `fouine search
--hybrid` pays the loading every time.

```sh
claude mcp add --scope user fouine -- /usr/local/bin/fouine mcp --stdio
```

Everything else, installation in both clients, one example call and answer per
tool, measurements and troubleshooting: [the assistant server](mcp.md).

### `fouine mcp install [--client all|claude-desktop|claude-code|cursor|codex|antigravity] [--folders <labels>...] [--dry-run] [--print] [--json]`

Configures the local clients to use Fouine as an MCP server. It registers
`/usr/local/bin/fouine` when that exists and resolves to the current binary (the
symlink survives app updates), otherwise the direct path of the current
executable. No administrator password is needed. When `fouine` is not on the
`PATH` (the command-line tool has not been installed from Settings ▸ Advanced),
the command line ships inside the application:

```sh
/Applications/Fouine.app/Contents/Helpers/fouine mcp install
```

- **Claude Desktop**: updates
  `~/Library/Application Support/Claude/claude_desktop_config.json`, putting the
  `fouine` server into `mcpServers` while preserving the other servers and
  settings. It backs the file up as `claude_desktop_config.json.fouine-bak` and
  writes atomically. Skipped when the `Claude` folder does not exist.
- **Claude Code**: if the `claude` command is on the `PATH`, it runs `claude mcp
  add --scope user fouine -- <path> mcp --stdio` (or reports that it is already
  configured). Otherwise it prints the manual command to copy.
- **Cursor**: configures `~/.cursor/mcp.json` in the same `mcpServers` shape,
  only if `~/.cursor` exists.
- **Codex**: adds a `[mcp_servers.fouine]` table to `~/.codex/config.toml`
  (`command` and `args`), replacing the table if it is already there and
  leaving every other line, sub-tables of `fouine` included, untouched; only if
  `~/.codex` exists. An `mcp_servers` written as an inline table is refused
  with a message, since TOML cannot extend it.
- **Antigravity**: configures `~/.gemini/config/mcp_config.json` (shared by
  Antigravity 2.0, the IDE and the CLI), or `~/.gemini/antigravity/mcp_config.json`
  when only that older folder exists, in the same `mcpServers` shape.

A client that is not installed is reported as `skipped` ("Codex is not
installed"); an entry already written keeps its other keys (an `env` block,
Antigravity's `disabled`). The order of the report is always Claude Desktop,
Claude Code, Cursor, Codex, Antigravity, and an unknown `--client` is a usage
error (exit 64) naming the six accepted values.

`--print` is for a client the command does not know: it writes nothing, needs
no client to be installed, and prints the resolved binary, the command line
(`<path> mcp --stdio`), the entry for an `mcpServers`-style JSON configuration
and the `[mcp_servers.fouine]` table for a TOML one. With `--json`, a single
object `{"command": "<path>", "args": ["mcp", "--stdio"]}`; `--folders` is
carried into `args`.

`--dry-run` writes nothing and shows, per client, the target path and **the only
entry Fouine would write**:

```
$ fouine mcp install --dry-run
would write: /Users/you/Library/Application Support/Claude/claude_desktop_config.json
{
  "mcpServers" : {
    "fouine" : {
      "args" : [ "mcp", "--stdio" ],
      "command" : "/usr/local/bin/fouine"
    }
  }
}
```

`--folders` writes the scope into each client's arguments (`"args": [ "mcp",
"--stdio", "--folders", "Livres,M2SU" ]`), the only way it survives the client
restarting the server on its own. Running `install` again **without**
`--folders` keeps the scope already written: an app update, or a binary path
that changes, must not reopen a server the user had restricted.

The **merged** configuration file is never printed: `mcpServers` is where other
MCP servers keep their API tokens, and the output of a `--dry-run` ends up in a
bug report.

The first line says which binary will be registered and **why**: `binary: <path>
(<reason>)`. The two travel separately, here as in the JSON.

`--json` returns an array of `{client, status, path, reason}` objects, with the
possible states `installed`, `already`, `skipped`, `dry_run`, `failed`, and
nothing of the files' content. Exit 0 if at least one client was configured, was
already configured, or was a dry run; 1 if all of them failed or were skipped.

---

## Exit codes

| Code | Meaning |
|---:|---|
| 0 | success |
| 1 | generic error |
| 2 | volume not mounted |
| 3 | database failure, including **locked by another process**, **index missing** (a read command refuses rather than creating one), **`FOUINE_DB` pointing at a folder** and **a copy of the `.db` alone** |
| 4 | budget exhausted: the queue is coherent, run again to resume |
| 5 | folder unreadable, missing, or no folder registered at all |
| 6 | **trial over**: `crawl`, `extract`, `index`, `ocr` and `embed` refuse to update the index until a key is entered. Search keeps working |
| 7 | **licence key refused**: unknown, disabled, expired, or already on 3 Macs. Deactivating a Mac that was already released is not a refusal: it cleans the file and exits 0 |
| 8 | **licence service unreachable**: no network, or the relay does not answer. The trial continues and nothing is changed |
| 64 | usage error: missing argument, folder refused by policy, query refused by the parser, unknown setting key, **filter value the index contradicts** (`--lang`, `--in`, `--only`, `roots.pinned`, `ocr.languages`), **exclusion rule refused or not kept** (`root ignore add`, `root ignore remove`) |

---

## Environment variables

| Variable | Effect |
|---|---|
| `FOUINE_DB` | full path of the `.db` file to open. **The lock is named after the database**: `fouine.db` → `fouine.lock`, `copy.db` → `copy.lock` |
| `FOUINE_MCP_LOG` | verbosity of the assistant server on stderr: `quiet`, `info` (default), `debug` |
| `FOUINE_MODEL_DIR` | directory of the meaning model |
| `FOUINE_MODEL_URL` | address of the model archive (`https://` or `file://`) |
| `FOUINE_MODEL_SHA256` | expected fingerprint of the archive. Setting it means trusting the archive in Fouine's stead |
| `FOUINE_LICENSE_RELAY` | address of the licence relay, for testing against the seller's sandbox. **An address contacted, with your key**: only `https://…` or `http://127.0.0.1:<port>` is accepted; anything else is ignored with a warning and the real relay is used |
| `FOUINE_EMBED_COMPUTE` | CoreML back-end for inference: `cpu`, `gpu`, or `all` (default). `all` is 1.7× faster on a campaign; `cpu` divides memory by nearly six and is faster on a single search |
| `FOUINE_OCR_TIMEOUT` | guard on one Vision page, in seconds (120) |
| `FOUINE_RENDER_TIMEOUT` | guard on rendering one page, in seconds (120) |
| `FOUINE_PDF_TIMEOUT` | guard on extracting a PDF, in seconds (default: proportional to the page count) |
| `FOUINE_DJVUSED` | path of a `djvused` installed outside the three standard directories |
| `FOUINE_FFMPEG` | path of an `ffmpeg` installed outside the three standard directories |
| `FOUINE_DISABLE_THERMAL_GOVERNOR` | benches and CI only: stop suspending recognition when `pmset` reports thermal throttling. Never in normal use |
| `FOUINE_AGENT_LOG` | path of the agent's log |
| `FOUINE_AGENT_GRACE_SECONDS` | grace period when the agent stops (15) |

Every variable listed in the settings table above is the **override** of a
`fouine config` key: it stays ahead of the database, and `fouine config list`
marks it `[environment]`.

`FOUINE_DB` is also how you work on a throwaway database without touching the
real one. Two points that cost time:

- **the write lock is named after the database**, next to it (`copy.db` →
  `copy.lock`, `copy-embed.lock` for a vectorisation campaign). It used to be
  called `fouine.lock` whatever the database, so two copies in one folder
  blocked each other and the app announced "another program is writing to the
  index" for a write happening elsewhere;
- **a copy of the `.db` alone does not open for reading.** A Fouine database is
  in `journal_mode = wal`; without its `-wal` beside it, no read command opens it
  (exit **3**). That is the case of a `cp`, a Time Machine restore, a transfer to
  another Mac. The message says the gesture: `FOUINE_DB=<copy> fouine maintain`
  once (a command allowed to write), or make the copies with `fouine backup
  <destination>`, which leaves its companions behind.

---

## Examples

```sh
# Add a folder, with a label that becomes a facet
fouine root add ~/Documents/Thesis --label Thesis
fouine root add /Volumes/Archives/Scans --label Archives

# See what is registered, and whether it can be read
fouine root list
fouine doctor              # “effective read of a file: OK” for each folder

# First indexing pass, under caffeinate so the Mac stays awake
caffeinate -i fouine index

# Resume extraction in half-hour slices
fouine extract --jobs 4 --budget-minutes 30

# Extract one document again after fixing it
fouine extract --only ~/Documents/Thesis/Chapter3.pdf

# Where are we
fouine status
```

Searching:

```sh
fouine search 'enthalpy -biology'                       # document-level exclusion
fouine search '"ideal gas"' --limit 20                  # exact phrase
fouine search 'near:10 free energy gibbs'               # proximity
fouine search 'name:report'                             # documents whose name matches
fouine search 'text:report nitrogen'                    # pages only, no name bonus
fouine search 'folder:Thesis spectro*'                  # folder plus prefix
fouine search 'polymer' --facet ext                     # with a facet
fouine search 'conversron' --fuzzy on --fuzzy-scope ocr # catch a recognition typo
fouine search 'nitrogen' --in 109 --in 174 --json       # two documents, JSON output
fouine search 'NEAR(nitrogen reduction, 3)' --raw-fts   # raw FTS5 syntax
fouine search 'catalyst selectivity' --hybrid           # lexical plus meaning
```

Browsing, without searching:

```sh
fouine list                                             # the 50 most recently modified
fouine list --folder Books --order pages                # the longest of one folder
fouine list --path-contains IP2022                      # by a piece of the name
fouine list --state failed --state skipped              # what could not be read
fouine list --limit 200 --offset 200 --json             # the second slice, for a script
```

Recognition and vectors:

```sh
# Full pass, one folder first, two hours maximum
caffeinate -i fouine ocr --prio-folder Thesis --budget-minutes 120

# One fixture, to check
fouine ocr --only ~/Documents/Thesis/Scan.pdf

# External engine: export the queue with the PNG renders, then reimport
fouine ocr export --pending --limit 500 \
       --render-png /tmp/renders --out /tmp/queue.jsonl
fouine ocr import /tmp/result.jsonl

# Meaning vectors
fouine embed --status
caffeinate -i fouine embed --budget-minutes 60
```
