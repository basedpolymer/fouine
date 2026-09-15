# Keeping the index up to date on its own

The **"Keep the index up to date automatically"** switch, under the Index card
in the sidebar (and in the "Your index" window), registers a background service
that keeps the index current: it watches your folders, extracts what is new,
and reads scanned pages when the Mac can spare the effort.

- [1. Turning it on](#1-turning-it-on)
- [2. What it does](#2-what-it-does)
- [3. Where it has got to](#3-where-it-has-got-to)
- [4. The log](#4-the-log)
- [5. Settings](#5-settings)
- [6. The agent and the command line](#6-the-agent-and-the-command-line)
- [7. It does not start](#7-it-does-not-start)

---

## 1. Turning it on

Sidebar ▸ **Keep the index up to date automatically**, under the Index card, or
from the "Your index" window (the "Details…" link of the card, or the Window
menu).

The switch stays off **until the first allowed read has succeeded**. That is
not a defect: registering the service before the macOS permission would produce
a service that runs and indexes nothing, with no way to show a prompt. A
background service with no interface is refused **without a word**.

It also needs an **installed and signed** app: registration fails from
`swift run FouineApp`.

The switch calls `SMAppService.agent(plistName:)`. The LaunchAgent's plist
stays inside the bundle (`Fouine.app/Contents/Library/LaunchAgents/`) and is
**never** dropped into `~/Library/LaunchAgents`. macOS may ask you to confirm in
**System Settings ▸ General ▸ Login Items & Extensions**, where the service
appears under the name **Fouine**.

To turn it off: the same switch, or the same pane of System Settings.

---

## 2. What it does

Two independent loops, and one background job.

**Before anything: the trial.** At every wake-up the agent re-reads
`~/Library/Application Support/Fouine/license.json`, a file of a few hundred
bytes next to the database. If the 30-day trial is over and no key is
installed, it does nothing at all: no watching, no extraction, no recognition,
no meaning preparation. It writes one line in its log, **at most once a day**:

```
licence: trial over, nothing to do — searching still works; enter a licence key
in Fouine to resume indexing
```

It demands nothing, notifies nothing, displays nothing: the app carries that
message, where someone can read it and act. **The agent never touches the
network**, not even for the licence: it reads the verdict rather than asking
anyone for it. A key activated from the app puts it back to work at the next
tick, within a minute, with no `launchd` restart. A missing or unreadable file
counts as a fresh trial, and the agent works.

**Watching.** The agent listens to your folders through FSEvents, with a
three-second latency. On each burst it walks what changed and extracts the new
documents. That is immediate and cheap: only files that changed are touched.

The `.fouineignore` file of each root is re-read at the **start of every pass**,
the agent's included: a rule added or removed applies at the next walk, with
nothing to relaunch. Saving that file is itself a change the agent sees — it is
hidden, but FSEvents does not care — so a folder excluded now stops being
indexed within seconds, and its documents leave the index on that same pass.

The rules **kept by Fouine** (the app's **What Fouine skips…** sheet, or `fouine
root ignore add`) are read at the start of every pass too, together with the
file. Saving one touches no file, so no FSEvents burst announces it: the agent
reads the kept rules of every root at **each tick** (`agent.pollSeconds`, 60 s by
default, one query) and walks the roots whose rules changed. At start, it walks
every root that carries kept rules, since they may have been saved while it was
stopped. The log says it: `ignore rules kept in the settings: pass on Personnel`.
A pass already under way, or an OCR batch, finishes first.

The cursor is saved after each batch, and the stream resumes from there at the
next start. A quiet restart asks for nothing. A real loss of history carries a
flag from the system, and that flag is what triggers a full walk; an invalid
cursor, newer than the system's own, triggers one too.

**Reading scanned pages.** In batches of ten minutes by default. The agent
starts a batch only if **all six conditions** hold:

1. plugged into **mains power**;
2. **Low Power Mode off**;
3. `CPU_Speed_Limit ≥ 70 %`;
4. `thermalState` nominal or *fair*;
5. the write lock **free**;
6. every folder actually **readable**.

The conditions are decided again at every batch rather than once and for all.
**On battery the agent does not run text recognition, and that is deliberate.**
It is the most visible difference from `fouine ocr`, which has none of these
guards. The first four can be disarmed in Settings (`agent.requireAC`,
`agent.pauseOnLowPower`, `agent.pauseOnThermal`), and the agent then says so in
its log at startup, so that an agent recognising text on battery does not read
as an agent ignoring the rules.

The third condition deserves a word. `thermalState` alone is not enough:
measured on the reference machine, it stays stubbornly at `.fair` while the CPU
is throttled to 46 %. What really drives the decision is `CPU_Speed_Limit`,
read from `pmset -g therm`: under 70 % concurrency drops to 2, and under 50 %
on two consecutive readings recognition suspends until it comes back to 50 %.

An FSEvents burst waits for the current recognition batch to finish: the agent
never does two heavy things at once.

**Search by meaning.** The agent also prepares search by meaning, which is what
`fouine embed` does, when `agent.prepareMeaning` is on (off by default since
1.0.1: the app's "Prepare search by meaning…" button or the checkbox in
Settings ▸ Indexing arms it), in batches of `agent.embedBudgetMinutes` minutes
(10 by default) and under the **same six conditions**. Four more guards, in this
order:

1. **recognition first**: a batch starts only when the recognition queue is
   **empty**. Reading a scanned page erases that page's vectors, so vectorising
   before recognition would mean vectorising twice;
2. the **model** must be installed (`fouine model download`), otherwise the
   agent logs it once and starts nothing;
3. there must be pages left to prepare;
4. the campaign lock `fouine-embed.lock` must be free: if a hand-launched
   campaign is running, the agent says nothing and tries again at the next
   tick. The other way round, a `fouine embed` launched during one of its
   batches exits **3** naming the agent (§ 6).

**Meaning preparation starts with the pinned folders.** `roots.pinned` — the
setting the app calls "read their scanned pages first" — now orders the meaning
campaign as well: one full phase on those folders, then the rest of the index.
Before this, the selection went by document discovery order alone, and a folder
pinned after the first ones could sit at zero vectors while an older folder was
two thirds done. Spreadsheets are left out of the vectors
(`embed.skip_spreadsheets`, true by default): a column of numbers describes
nothing, and those pages stay findable word for word.

The model (~90 MiB in memory) is **kept between two consecutive batches** and
**released** as soon as the agent goes idle or a condition falls. A condition
that falls **during** a batch interrupts it cleanly, between two inference
batches: the vectors already produced are written, and resuming costs nothing.
The setting is one checkbox (`agent.prepareMeaning`, § 5).

Three log lines per batch: the start (`meaning: batch of 10 min, 118302 page(s)
left`), the outcome (`meaning: 612 page(s) prepared, 117690 left, 600 s`) and
the reason it stopped (budget reached, queue empty, condition fallen).

**Spotlight: the agent hands over nothing.** Handing documents to Spotlight
happens at the end of a pass, every pass, the agent's included, but it is
refused to the agent itself. It lives in `Fouine.app/Contents/MacOS/FouineAgent`,
so `Bundle.main` hands it the app, identifier and all, although it is not the
app's main executable. That is exactly the configuration where
`UNUserNotificationCenter` terminates the process (see "Notification at the
end", § 3), and an agent dying every sixty seconds would be worse than no
Spotlight at all. What the agent indexes and recognises goes to Spotlight at the
next **opening of the app**, which catches up on everything that changed
([`app.md`](app.md), Spotlight).

---

## 3. Where it has got to

The agent publishes what it is doing in the database, and the app reads it:
every **2 seconds** while its window is in front, every **30 seconds**
otherwise. On the agent's side, the write happens **immediately at every change
of phase** and **at most every 2 seconds** the rest of the time, so that a whole
extraction pass does not cost one transaction per document.

The state and the progress appear in the **Index** card of the sidebar and, in
detail, in the **"Your index"** window:

- the **phase**: idle, walking the folders, extracting text, text recognition,
  preparing search by meaning, waiting, stopped. The app renders these from a
  language-free token rather than from the log line, so it says them in your
  language;
- a **progress bar** with its count when there is one (documents of an
  extraction pass, pages of a recognition batch), and the estimated time left
  ("about 2 h left");
- the **current document**, or what the agent is doing. This too is a
  language-free token in the database (`starting`, `queue-drained`,
  `pages-queued(20226)`, `pages-left(315)`, `signal-received(SIGTERM)`,
  `document(Cours.pdf)`), which the command line and the assistant server render
  in English and the app translates. A NAME (document, folder) and a waiting
  condition (`no AC power`, `CPU_Speed_Limit 33 %`) stay free text, shown as
  they are; an unknown token, written by an agent of another version, does too,
  because reading something beats reading nothing;
- **"updated N s ago"**, which is the only way of telling an agent that is
  working from a display that stopped moving.

The menu bar shows one part of this: its icon takes one of three shapes
(magnifier, circular arrows, triangle) and its panel carries the state
sentence, greyed out and with no gesture.

While the agent prepares search by meaning, the card shows **"Preparing search
by meaning · N pages of M"**, the same as a preparation started from the app,
with no Stop button: a setting commands it rather than a gesture. The
**"Prepare search by meaning…"** button in Settings disappears then, replaced by
"Fouine takes care of it in the background, when the Mac is plugged in and
idle."

A status whose **process has disappeared**, or which has not moved for **five
minutes**, shows as stopped or idle. `fouine status` says the same on the
command line.

**The same card serves passes you start by hand.** "Update now" and "Read
scanned pages…" announce themselves in their own sheet first, but that sheet
carries a **"Continue in the background"** button: it closes, the work goes on,
and the progress moves to the Index card with **Stop** next to it. That is what
makes the app usable during a pass: a sheet is modal to the window, and a
recognition batch is measured in hours. The sheet does not reopen by itself at
the end.

**A recognition batch started from the app lasts 30 minutes by default**, plus
an unlimited option. Stopping is clean at any moment: the current page
finishes, the queue stays intact, and resuming starts from here.

**Notification at the end.** If you tick "Tell me when the scanned pages are
all read" (Settings ▸ General), a macOS notification is posted when the queue
empties. It comes from **the app**, never from the agent: a `launchd`
executable with no bundle of its own has no notification identity, and calling
one there is a crash rather than a refusal. **So if Fouine is not open when the
queue empties, there is no notification.** The macOS permission is requested
when you tick the box, never at startup.

---

## 4. The log

A background service has neither window nor terminal. Its log is all there is:

```sh
tail -f ~/Library/Logs/Fouine/fouine.log
```

It is timestamped and rotates at 10 MiB (`fouine.log.1`). The size is checked at
every tick rather than only when a timestamped line is written, because
recognition progress arrives through redirected standard output and could grow
the file without bound.

The log is created **0600**, readable by you alone: it holds the tree of your
documents, the absolute path of every folder and of every failed page. A log
inherited from an earlier version (0644) is put back to 0600 the first time the
agent opens it.

Since the sidebar shows progress, the log is no longer the only diagnosis, but
it stays the only place where an **incident** is visible: a folder gone
unreadable, a failed page, a recognition language set aside.

**It is kept short** on purpose. The two messages that used to drown it are now
one line per recognition batch, and the deduplication of a waiting condition
keys on the **nature** of the block rather than on the sentence, whose
percentage kept changing.

**The log is in English**, like the command line: it is the project's base
language, and a log line gets pasted into a bug report or a search engine (see
[`i18n.md`](i18n.md)). The app follows the system language, and names the phases
in yours, because it renders them from their identifier.

Four lines worth recognising:

| Line | What it means |
|---|---|
| `OCR conditions (§5.7): AC power … CPU_Speed_Limit … thermalState …` | the state of the six conditions at startup: informative, and the first place to look |
| `OCR waiting — no AC power` | normal on battery; plug the Mac in |
| `root “…” IGNORED — read denied (privacy settings or file permissions)` | the macOS permission was not granted, or was revoked. See [permissions](permissions.md) |
| `FSEvents burst … matched no active root` | a folder was **moved**: `fouine root list`, then add it again. This is not a permission problem |

If no folder is readable, the agent writes it (`no readable root: FSEvents
watching suspended`) and starts nothing.

---

## 5. Settings

**In the settings window (⌘,) ▸ Indexing**, or on the command line with `fouine
config`. Settings live in the database, which the app, the command line and the
agent all open; the agent re-reads them **at every tick and at the start of
every batch**, so a change is seen within one polling period.

| Key | Default | Effect |
|---|---:|---|
| `agent.extractJobs` | 2 | extraction threads of the agent |
| `ocr.jobs` | 4 | threads of the recognition pump |
| `ocr.languages` | `fr-FR,en-US` | recognition languages |
| `agent.ocrBudgetMinutes` | 10 | length of a recognition batch |
| `agent.pollSeconds` | 60 | how often conditions, folders and settings are checked again |
| `agent.requireAC` | `true` | condition 1 |
| `agent.pauseOnLowPower` | `true` | condition 2 |
| `agent.pauseOnThermal` | `true` | conditions 3 and 4 |
| `agent.prepareMeaning` | `true` | also prepare search by meaning, after recognition |
| `agent.embedBudgetMinutes` | 10 | length of a meaning preparation batch |
| `roots.pinned` | *(empty)* | folders whose scanned pages are read first |
| `notifications.onQueueDrained` | `false` | notification at the end (posted by the app) |

Conditions 5 (lock free) and 6 (folders readable) are not adjustable: they are
conditions of correctness rather than preferences.

The defaults are deliberately modest, because the agent should be invisible.
Two threads, ten minutes of recognition at a time, and it hands the machine
back.

**Environment variables keep working** and stay **ahead** of the settings
window, which is what lets you rescue an agent that will not start. If one is
set in the LaunchAgent plist, the agent writes it in its log at startup
("settings forced by the environment…") and `fouine config list` shows
`[environment]` next to the key: a value typed in the window would have no
effect then, and it is better to know than to guess.

| Variable | Key |
|---|---|
| `FOUINE_AGENT_JOBS` | `agent.extractJobs` |
| `FOUINE_OCR_JOBS` | `ocr.jobs` |
| `FOUINE_OCR_LANGUAGES` | `ocr.languages` |
| `FOUINE_AGENT_OCR_BUDGET_MINUTES` | `agent.ocrBudgetMinutes` |
| `FOUINE_AGENT_POLL_SECONDS` | `agent.pollSeconds` |
| `FOUINE_AGENT_REQUIRE_AC` | `agent.requireAC` |
| `FOUINE_AGENT_PAUSE_LOW_POWER` | `agent.pauseOnLowPower` |
| `FOUINE_AGENT_PAUSE_ON_THERMAL` | `agent.pauseOnThermal` |
| `FOUINE_AGENT_PREPARE_MEANING` | `agent.prepareMeaning` |
| `FOUINE_AGENT_EMBED_BUDGET_MINUTES` | `agent.embedBudgetMinutes` |
| `FOUINE_PINNED_ROOTS` | `roots.pinned` |
| `FOUINE_NOTIFY_QUEUE_DRAINED` | `notifications.onQueueDrained` |

Two variables have no settings key, because they are not preferences:
`FOUINE_AGENT_GRACE_SECONDS` (grace period at shutdown, 15 s, a margin under
launchd's 20-second axe) and `FOUINE_AGENT_LOG` (path of the log).

---

## 6. The agent and the command line

Every indexing write takes an exclusive lock on `fouine.lock`. It is **taken at
the first write and released at every resting point**: end of an indexing pass,
end of a recognition batch, end of an embedding batch. Writes to settings and
to the agent's own status are **exempt**: changing a setting must not fail
because the agent is working, since it is precisely when the agent is
monopolising the machine that you want to cut its budget.

While a write is in progress:

> `fouine index`, `fouine crawl` and `fouine extract` fail with **exit 3**,
> "database locked by another process — the database is being written by the
> agent (pid 1234) since 10:32". The message names the holder.

`fouine ocr` follows the same rule, with one exception:

- **queue not empty**: it exits **3** like the other three, with one line on
  stderr. The refusal is decided **before** any work, so no engine warm-up, no
  page rendering, and the queue stays intact;
- **queue empty**: it returns **0** without touching the lock. It has nothing to
  write, so it says so and leaves. That is deliberate: the agent and the app
  call the pass in a loop, and refusing an absence of work would turn it into a
  failure.

**The lock file is named after the database**: `fouine.db` → `fouine.lock`,
`copy.db` → `copy.lock`. In production nothing changes; on a copy pointed at by
`FOUINE_DB`, two databases in the same folder no longer block each other.

The wait is therefore bounded by one batch rather than by the life of a
process: a command refused during an embedding campaign succeeds on the next
try.

`fouine search`, `fouine status`, `fouine doctor` and `fouine list` never take
the lock and always work.

**`fouine embed` and the campaign lock.** `fouine-embed.lock`, which is not
`fouine.lock`, guarantees that only one vectorisation runs at a time. Since the
agent prepares search by meaning itself, it is usually the agent holding it, ten
minutes at a time: a campaign launched by hand during one of its batches exits
**3** with "the background agent is preparing meaning — it will stop by itself;
or turn the setting off (`fouine config set agent.prepareMeaning false`)".
Waiting is enough. The other way round, an agent that finds the lock taken says
nothing and tries again at the next tick. `fouine status` carries the `meaning`
line; `fouine doctor` repeats it and adds the gesture when the setting is armed
without the model installed.

**How `doctor` knows who holds the lock.** It probes: it opens `fouine.lock`
read-only and tries the `flock` without waiting. If it gets it, the lock is free,
and if the file still named someone, that name is stale (a killed process passes
through neither release nor recovery), so it is erased while the probe holds the
lock. If it is refused, the lock really is held and the name read is the right
one. Reading the file alone made `doctor` say "stale lock" forever, and, the day
the system recycled that process number, "lock held": in the app, "The index is
being updated" before every manual pass, for good.

**Before a large pass on the command line, turn "Keep the index up to date
automatically" off, then on again afterwards.** See
[`pitfalls.md`](pitfalls.md).

---

## 7. It does not start

### Diagnosis

If the switch is armed but no progress appears, or if `fouine doctor` reports a
problem, ask `launchd`:

```sh
launchctl print gui/$(id -u)/io.github.basedpolymer.fouine.agent
```

A broken agent typically prints:

```
state = spawn scheduled
job state = spawn failed
runs = 5
last exit code = 78: EX_CONFIG
event triggers = { io.github.basedpolymer.fouine.agent => { descriptor = {
    "Executable" => "/path/to/some/Fouine.app/Contents/MacOS/FouineAgent"
} } }
```

`fouine doctor` reports that state explicitly:

```
background agent : registered, spawn failed (EX_CONFIG, 5 runs) — re-register it from Fouine.app ▸ “Keep the index up to date automatically”
```

The next line of `doctor` says **how many copies of Fouine macOS knows about**,
and which one it would open:

```
application    : /Applications/Fouine.app
```

If it announces several, that is the likely cause: go straight to the next
section. `doctor --json` also publishes `app_at_expected_path`, read from the
`Info.plist` of `/Applications/Fouine.app` without going through
LaunchServices, which is what says who occupies the place even when
LaunchServices knows of nobody.

### Cause 1: two copies of Fouine.app

The most frequent case, and the least visible. macOS opens the copy with the
highest `CFBundleVersion`, **not** the one that is installed. A `Fouine.app`
built from the repository (its build number is the commit count) therefore
takes precedence over the one in `/Applications`, and the agent registered from
`/Applications` no longer finds its program.

`doctor` shows it:

```
application    : 2 copies known to macOS — macOS opens /Users/…/fouine/Fouine.app; others: … — delete the other copies of Fouine.app (keep only /Applications/Fouine.app), then turn “Keep the index up to date automatically” off and on again in Fouine.app — deleting the copies alone does not repair an agent already registered against them
```

Deleting the copies **is not enough**: the code requirement is frozen in
Background Task Management. Delete them, **then** run the five steps below. The
full account is in [`pitfalls.md`](pitfalls.md), "Two copies of Fouine.app".

The app now **refuses** to arm the switch from a copy that is not the one and
only `Fouine.app` in the Applications folder, and says so plainly.

### Cause 2: moved path, or frozen code requirement

The agent's plist uses `BundleProgram`, a path relative to the registering
bundle. `launchd` resolves it against the location memorised when
`SMAppService.register()` was called.

If you armed the agent from a `Fouine.app` in `~/Downloads`, opened straight
from the disk image, or built in a temporary folder since deleted, the program
becomes unfindable. `launchd` then fails with code **78 (`EX_CONFIG`)** and puts
the service in the penalty box, retrying every 60 s. It also freezes, at
registration, a code requirement tied to the signature of the original bundle.

### Cause 3: an orphan registration of an old identifier

If the copies are unique and the five steps below change nothing, read
launchd's log (`/usr/bin/log show --last 5m --info --debug --predicate 'process
== "launchd"'`, the full path because `log` is a zsh builtin). The line `The
specified path is not a bundle: Contents/MacOS/FouineAgent` marks a Background
Task Management that still holds the registration of an OLD bundle identifier at
the same URL (`sfltool dumpbtm`). No app can purge it; see
[`pitfalls.md`](pitfalls.md), "Two copies of Fouine.app", last paragraph.

### Remediation in five steps

To reset the registration cleanly, **after** deleting the extra copies, without
which the five steps are useless:

1. Open **/Applications/Fouine.app** (the installed app, never a working build)
   and **turn off** "Keep the index up to date automatically" in the sidebar.
   This calls `SMAppService.unregister()`.
2. Open **System Settings ▸ General ▸ Login Items & Extensions**. Check that no
   background entry for "Fouine" is left. If an orphan entry persists, which
   happens when the original bundle has disappeared, remove it with the "—"
   button.
3. Check in a terminal that the service really is gone from `launchd`:
   ```sh
   launchctl print gui/$(id -u)/io.github.basedpolymer.fouine.agent
   ```
   It must answer `Could not find service "io.github.basedpolymer.fouine.agent"
   in domain for user gui: …` with a non-zero exit code.
4. **Turn the switch back on** from `/Applications/Fouine.app` (or click the
   **Restart automatic updates** button the app offers). The new registration
   memorises the canonical path under `/Applications` and the bundle's stable
   signature.
5. Check with `fouine doctor` that the agent works:
   ```sh
   fouine doctor
   ```
   The line must read `background agent : registered, running (pid …)`.

> **Warning.** Never change the bundle or service identifier without
> **unregistering the old agent first** (switch off, entry removed in System
> Settings). If the identifier changes while the agent is still active, the old
> registration stays orphaned in Background Task Management, with no app able to
> purge it.
>
> **`sfltool resetbtm` is the last resort**, reserved for cause 3: it blindly
> resets the login items of every app on the system. Never from a script, never
> without the user's explicit agreement, always followed by a restart.
