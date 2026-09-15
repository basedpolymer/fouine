# The assistant server

`fouine mcp --stdio` lets an assistant (Claude Code, Claude Desktop, Cursor,
Codex, Antigravity…) read the index Fouine keeps of your documents, on your
machine, with nothing going out on the network. It is a **read-only** server: it never modifies the index, never
starts an indexing pass, and never hands over your original files.

Running it as a server rather than calling `fouine search` for every question
pays off on hybrid search, which loads the semantic model at **every** call of
the command line. A resident server pays once: measured on a real index, 2.16 s
for the first hybrid call and 0.32 s for the next.

- [Installing](#installing)
- [The five tools](#the-five-tools)
- [Citing a page](#citing-a-page)
- [What the server does not do](#what-the-server-does-not-do)
- [What it costs](#what-it-costs)
- [The log](#the-log)
- [Troubleshooting](#troubleshooting)
- [The protocol, for the curious](#the-protocol-for-the-curious)

---

## Installing

The most direct way is `fouine mcp install`, which configures your local clients
in one command. Manual configuration and the standalone `.mcpb` extension stay
available.

### Where the command lives

The `fouine` command line ships **inside the application**, at
`/Applications/Fouine.app/Contents/Helpers/fouine`. It is on your `PATH` as
plain `fouine` only once you have used Fouine ▸ Settings ▸ Advanced ▸ "Install
the command-line tool…", which links it from `/usr/local/bin`. Without that
step, the full path works just as well and needs no administrator password:

```sh
/Applications/Fouine.app/Contents/Helpers/fouine mcp install
```

### If you are an assistant asked to "install the Fouine MCP"

Run the command above (or `fouine mcp install` when `fouine` is on the `PATH`).
It configures every supported client in one go and skips the ones that are not
installed, keeping the other servers and settings of each configuration file.
`--dry-run` previews what would be written, `--json` gives a machine-readable
report, `--client <name>` restricts the run to one client and `--folders
<labels>` restricts what the server will serve. Nothing else is needed: no
`sudo`, no download, no manual edit. Restart the client afterwards. If your
client is not one of the five, `fouine mcp install --print` gives the server
entry to add to its configuration by hand (see [another
client](#another-client)). The welcome screen of the app has a **Copy the
request for your assistant** button that puts exactly these instructions, with
the real path of the binary, on the clipboard. The same guide, with the
installation of the app itself, is online at
[basedpolymer.eu/fouine/mcp](https://basedpolymer.eu/fouine/mcp).

### The short way

```sh
fouine mcp install
```

The command inspects your applications and configures the server:

- **Claude Desktop**: updates `claude_desktop_config.json` in Application
  Support (backup first as `.fouine-bak`, atomic write);
- **Claude Code**: runs `claude mcp add --scope user fouine -- <path> mcp
  --stdio` if the `claude` client is on the `PATH`;
- **Cursor**: configures `~/.cursor/mcp.json`;
- **Codex** (CLI, app and VS Code extension): adds a `[mcp_servers.fouine]`
  table to `~/.codex/config.toml`, replacing it if it is already there and
  leaving every other line of the file untouched;
- **Antigravity** (2.0, IDE and CLI): configures
  `~/.gemini/config/mcp_config.json`, or `~/.gemini/antigravity/mcp_config.json`
  on an installation that has not migrated yet.

A client whose folder does not exist is reported as skipped ("Codex is not
installed"). An entry Fouine already wrote keeps the other keys you may have
added to it, such as an `env` block. It prefers `/usr/local/bin/fouine` when
that symlink points at the current binary, so the configuration survives app
updates.

Useful options: `--client claude-desktop` (or `claude-code`, `cursor`, `codex`,
`antigravity`) targets one client; `--dry-run` shows what would be written
without touching a file; `--json` prints a machine-readable result.

### Claude Desktop, the `.mcpb` extension

Download `Fouine-<version>.mcpb` from the releases page, then **double-click**
it: Claude Desktop opens its installer, showing the five tools and one optional
setting. You can also go through **Settings ▸ Extensions ▸ Advanced Extensions**
and drop it there.

The setting is called **"Fouine index"**. **Leave it empty**: Fouine then uses
the standard location, `~/Library/Application Support/Fouine/fouine.db`, the
one the app uses. Fill it in only if you keep several indexes and want to serve
one of them in particular.

The `.mcpb` file is an archive carrying its **own copy** of the `fouine`
program, signed and notarised by Apple. There is **nothing else to install**,
not even the app, if all you want is to let an assistant read an existing index.
Nothing replaces the app for *building* that index: the extension is read-only
and does not index.

### Claude Desktop, without the extension

If you prefer to configure it by hand, in
`~/Library/Application Support/Claude/claude_desktop_config.json`:

```json
{
  "mcpServers": {
    "fouine": {
      "command": "/usr/local/bin/fouine",
      "args": ["mcp", "--stdio"]
    }
  }
}
```

That assumes the command line is installed (Fouine ▸ "Install the command-line
tool…"). Restart Claude Desktop.

The server's log is in `~/Library/Logs/Claude/mcp-server-fouine.log`, the first
place to look when something is wrong, whichever way you installed it.

### Claude Code

```sh
claude mcp add --scope user fouine -- /usr/local/bin/fouine mcp --stdio
```

**The `--` is required.** It separates the options of `claude mcp add` from the
command to run; without it, `mcp` and `--stdio` are read as options of the
client, and the add either fails or registers a server that does not start.
Everyone makes that mistake once. Check with `claude mcp list`.

Claude Code does not install `.mcpb` extensions: the command above is the way,
and `/usr/local/bin/fouine` must exist (or give the full path inside the app).

### Cursor

`fouine mcp install --client cursor` writes `~/.cursor/mcp.json`. By hand, the
file has the same `mcpServers` shape as Claude Desktop's.

### Codex

`fouine mcp install --client codex` writes `~/.codex/config.toml`, the file the
Codex CLI, the Codex app and its VS Code extension all read. By hand, either
run Codex's own command:

```sh
codex mcp add fouine -- /usr/local/bin/fouine mcp --stdio
```

or add the table yourself:

```toml
[mcp_servers.fouine]
command = "/usr/local/bin/fouine"
args = ["mcp", "--stdio"]
```

Fouine only ever touches that one table; a `[mcp_servers.fouine.env]` sub-table
you added stays. The one shape it refuses is `mcp_servers` written as an inline
table (`mcp_servers = { … }`), because TOML forbids extending it afterwards: the
command then says so and leaves the file alone.

### Antigravity

`fouine mcp install --client antigravity` writes
`~/.gemini/config/mcp_config.json`, the configuration Antigravity 2.0, the
Antigravity IDE and the Antigravity CLI share (older installations keep it in
`~/.gemini/antigravity/mcp_config.json`, which Fouine uses when the new folder
does not exist). By hand, in the IDE: agent panel ▸ **…** ▸ **MCP Servers** ▸
**Manage MCP Servers** ▸ **View raw config**, then the same `mcpServers` entry
as Claude Desktop's:

```json
{
  "mcpServers": {
    "fouine": {
      "command": "/usr/local/bin/fouine",
      "args": ["mcp", "--stdio"]
    }
  }
}
```

### Another client

Any client that speaks MCP over standard input and output can run the server;
nothing in Fouine is specific to the five above. `fouine mcp install --print`
prints what to copy, with the binary resolved for this machine:

```
$ fouine mcp install --print
binary: /usr/local/bin/fouine (/usr/local/bin/fouine (survives application updates))
command line: /usr/local/bin/fouine mcp --stdio
entry for an mcpServers-style configuration (Claude Desktop, Cursor, Antigravity, Gemini CLI, Windsurf…):
{
  "mcpServers" : {
    "fouine" : {
      "args" : [ "mcp", "--stdio" ],
      "command" : "/usr/local/bin/fouine"
    }
  }
}
table for a TOML configuration (Codex):
[mcp_servers.fouine]
command = "/usr/local/bin/fouine"
args = ["mcp", "--stdio"]
```

`--print --json` gives `{"command": …, "args": […]}` alone, for a script.
Known places, as of September 2026: Gemini CLI reads `mcpServers` in
`~/.gemini/settings.json`; Windsurf in `~/.codeium/windsurf/mcp_config.json`;
VS Code reads a `servers` object in its `mcp.json` (User ▸ MCP: add server),
with `"type": "stdio"` next to `command` and `args`. A client with no MCP
support at all can still call the command line: `fouine search <query> --json`,
`fouine read <doc_id> <page>`, `fouine list --json`, `fouine status --json`.

### Two copies of the same program, and why

If you have both the app and the extension, there are two copies of the `fouine`
program on your disk: the one inside `Fouine.app`, and the one Claude Desktop
unpacked when installing the extension. That is deliberate: the `.mcpb` exists
precisely so an installation depends on nothing else, and a manifest pointing at
`/usr/local/bin/fouine` would send the user back to the installation they were
avoiding. The cost is about 10 MB, and both copies read the **same** index.

One consequence: the two update separately. After a Fouine update, reinstall the
extension if the message "this Fouine index was written by a newer version"
appears.

### Another index

`--db <path>` on the command line, the `FOUINE_DB` variable, or the "Fouine
index" setting of the extension: they are the same thing, the extension only
sets the variable. Empty or absent means
`~/Library/Application Support/Fouine/fouine.db`.

### Restricting what an assistant can see

`--folders Livres,M2SU` serves **only** those roots, by label. The option is
repeatable and accepts commas; `fouine mcp install --folders Livres,M2SU` writes
it into the client configurations, and running `install` again without it keeps
the scope already written.

What is outside the scope does not exist for that server:

- `fouine_status.roots` lists only the served roots, and `scope` carries them
  (`null` without the option);
- `fouine_search` never returns a page from elsewhere, and a `folder` outside
  the scope is refused **naming only the served roots** — the same refusal an
  invented label gets. A `lang` outside the scope is refused the same way, and
  the refusal names **only the languages of the served documents**: until
  14/09/2026 it listed the languages of the whole index, which returned no
  document but taught the model that there was German behind the scope;
- `fouine_read_page` and `fouine_similar_pages` answer, for a `doc_id` outside
  the scope, exactly what they answer for a `doc_id` that does not exist. The
  refusal cannot be used to learn that the document is there;
- `fouine_list_documents` lists and counts the scope only.

`documents` in `fouine_status` is the count **inside** the scope;
`pages_indexed`, `vectors` and `vector_coverage_pct` still describe the whole
index, which `scope.note` says in as many words. A label naming no root does not
kill the server: it starts, and every tool answers an error naming the roots
that exist — but `fouine mcp` on a readable index refuses in **64** before
saying anything at all.

```json
"scope": {
  "folders": ["Livres", "M2SU"],
  "note": "This server only serves these roots; anything else is invisible to it. …"
}
```

This is a **reading** scope: the documents stay indexed, searched by the app and
counted by `fouine status`. To keep a folder out of the index altogether — so
that nothing can search it, quote it or count it — exclude it instead: **What
Fouine skips…** in the app's settings, `fouine root ignore add`, or a
`.fouineignore` file at the top of the root:
[excluding a folder](formats.md#excluding-a-folder-or-a-file-type-fouineignore).

---

## The five tools

| Tool | What it answers |
|---|---|
| `fouine_status` | what does Fouine know? is search by meaning available? |
| `fouine_search` | which **pages** talk about this? (and, per hit, what the page really is: a slide, a moment in a recording, a picture inside a file) |
| `fouine_read_page` | what does this page say, exactly — and what does "page N" actually mean here? |
| `fouine_similar_pages` | which pages are close to this one? |
| `fouine_list_documents` | what is in the index, and why is this document missing? |

That is also the order an assistant should discover them in, and the order of
`tools/list`.

Each tool returns its result twice: in `structuredContent`, validated by its
`outputSchema`, and in a `content` block of type `text` carrying the same JSON
serialised. That is what the specification recommends, and it is what lets a
client that does not know structured output work anyway. It is also why the size
ceiling counts the payload **twice**.

All five carry the same annotations: `readOnlyHint: true`, `destructiveHint:
false`, `idempotentHint: true`, `openWorldHint: false`. A client reads those
*before* calling, and they are what lets it skip a confirmation prompt on every
call: none of these tools can modify anything, and the world is closed to your
index.

### An example, end to end

```json
{"jsonrpc":"2.0","id":4,"method":"tools/call",
 "params":{"name":"fouine_search",
           "arguments":{"query":"electrolysis","mode":"hybrid","limit":2}}}
```

```json
{
  "hits": [
    {"doc_id": 116, "page": 286,
     "path": "Users/…/Modern Aspects of Electrochemistry No. 26.pdf",
     "abs_path": "/Users/…/Modern Aspects of Electrochemistry No. 26.pdf",
     "folder": "Books", "ext": "pdf",
     "link": "fouine://open?path=/Users/…/Modern%20Aspects…pdf&page=286",
     "snippet": "…La Physicochemie des Bains d'«Electrolyse» de l'Aluminium…",
     "bm25": -9.9472, "relevance_pct": 100, "source": "native",
     "engine": "none", "fuzzy_distance": 0,
     "time_seconds": null, "slide": null, "embedded_image": null,
     "cosine": 0.861, "z": 3.61, "lex_rank": 28, "vec_rank": 31,
     "rrf": 0.015424, "semantic_only": false,
     "why": {"kind": "both", "terms_found": ["electrolysis"]}},
    {"doc_id": 63, "page": 6, "…": "…",
     "bm25": null, "relevance_pct": 98, "cosine": 0.875, "z": 4.42,
     "lex_rank": null, "vec_rank": 1, "rrf": 0.015149, "semantic_only": true,
     "why": {"kind": "semantic"}}
  ],
  "total_pages": 53, "total_docs": 18, "totals_approximate": false,
  "mode_used": "hybrid", "semantic_available": true,
  "semantic_coverage_pct": 16.63,
  "semantic_scope": {"pages": 390114, "vectorised": 64872, "filtered": false},
  "semantic_stats": {"mu": 0.7971, "sigma": 0.0176, "cos_max": 0.8748,
                     "z_max": 4.42, "z_at_10": 3.8, "z_at_200": 2.96,
                     "scanned": 64449, "zero_vectors": 423},
  "semantic_rank_scale": 6.01,
  "note": "only 16.6 % of the pages in the index are vectorised — semantic hits are drawn from that subset; `fouine embed` extends it",
  "name_matches": [], "fuzzy_fallback": false, "fuzzy_expanded": false,
  "quorum": false, "documents": {}, "facets": null,
  "hybrid_disarmed": null, "has_more": true,
  "next_cursor": "eyJmIjoiMGExZjEzY2Q5NTc1YmFlNWQ2YzliZjcwIiwibyI6MywidiI6MX0",
  "elapsed_ms": 2162.02
}
```

### `fouine_status`

Health and coverage of the index. This is the call an assistant should make
first: it says how many documents Fouine knows, whether search by meaning is
available, and whether a folder is missing because its volume is not mounted.
Two optional parameters, `include_roots` and `include_agent`, both `true` by
default.

Fields worth a sentence:

- **`vector_coverage_pct`**: the share of pages carrying a meaning vector. At
  16 %, a semantic search sees a sixth of the corpus. That is information rather
  than a fault, and `fouine embed` raises it.
- **`roots[].coverage_pct`** is the same share **for that folder alone**, next
  to `pages` and `vectorised_pages`. It is the number that matters, because the
  global figure hides whole folders: on a real corpus, 67.85 % overall breaks
  down into `Livres` 73.34 %, `M2SU` **0 %** and `Personnel` **0 %** — search by
  meaning sees nothing at all of two of the three folders, however many pages
  they hold. Read it before concluding that a folder has nothing to say.
- **`disk_budget`** says what the index weighs (`bytes`), what it will weigh at
  full meaning coverage (`bytes_at_full_vectors`), and where that stands against
  the 2.5 GB budget (`ratio_now`, `ratio_at_full_vectors`, `level`: `ok`,
  `near`, `over`). **Nothing stops at 100 %** — `level` is a warning, not a
  failure. `pages_at_budget` is `null` on an empty index.
- **`meaning_background`** says whether the background agent prepares meaning
  (`enabled`), in what batches (`budget_minutes`), when it last ran
  (`last_batch`, `null` if never) and how many indexed pages still have no
  vectors (`pages_left`). Read `disk_budget.level` and
  `meaning_background.pages_left` **before advising `fouine embed`**: on a
  corpus already `over` budget with 139 638 pages left, that advice costs hours
  of CPU and gigabytes.
- **`write_lock`**: another Fouine process (the app, the agent, a command) is
  writing to the index. **That blocks no read**: SQLite's WAL allows concurrent
  readers. The field exists to explain why a count moves between two calls.
- **`agent.report_detail`** says what the background agent is doing, in English.
  The database carries a language-free token, which each surface renders in its
  own language; an unknown token, from an agent of another version, passes
  through as it is.
- **`agent.healthy`, `agent.alive`, `agent.stale`** are now the same verdict as
  `fouine status --json` on the command line. `healthy` is false when the agent
  is **no longer registered with launchd although it has published a report**:
  it ran and it is gone. It stays true when no report exists at all, because
  nobody ever turned automatic updating on — that is a setting, not a fault.
- **`roots[].path`** is `null` when the volume is not mounted, which is the
  answer to "why have my archives disappeared?".
- **`scope`** is `null` when the whole index is served, and otherwise names the
  only roots this server serves (`fouine mcp --folders`). `documents` is then
  the count inside that scope, while `pages_indexed` and `vectors` stay
  index-wide. See [restricting what an assistant can
  see](#restricting-what-an-assistant-can-see).
- **`semantic.model_loaded`** says whether the CoreML model is resident *in this
  server*. It loads lazily, at the first hybrid `fouine_search`, never before.
  `model_installed` is about the disk, `model_loaded` about memory.
- **`index_freshness`** says when the vector index was loaded and how many rows
  it carries. It reloads when the number of vectors in the database differs from
  its own by more than 10 %, or every ten minutes, whichever comes first, so the
  server can stay open next to a running `fouine embed`.

`write_lock`, `semantic.model_loaded` and `index_freshness` are read on **every**
call; everything else is cached for **60 s**.

Per-root coverage is the expensive part: measured on the same 434 372-page
index, a cold `fouine_status` goes from 1 959 ms to 2 907 ms (median of three,
interleaved), and `include_roots: false` brings it back to 1 939 ms. It has its
own 60 s cache, so an assistant that calls the tool three times in a minute
pays it once.

### `fouine_search`

Full-text search, and semantic search when it is possible. **It returns pages**,
not documents: the `(doc_id, page)` pair is the key the next two tools take.

| Parameter | Default | Effect |
|---|---|---|
| `query` | *required* | bare words = AND, `"phrase"` = exact, `term*` = prefix (4 letters minimum), `-term` = exclude the **whole document**, `pres:5` (or `near:5`) = within 5 words, `dossier:X` (or `folder:X`) and `ext:pdf` = filters. **Never `AND`, `OR` or `NOT`**: words are already combined with AND. Any other `word:value` is refused by naming the filters. `nom:X` (or `name:X`) searches file names only, and on its own returns one line per document; `texte:X` (or `body:X`) searches pages only. Curly quotes count as straight quotes |
| `limit` | `10` | 1 to 50 pages |
| `cursor` | — | the `next_cursor` of a previous result |
| `mode` | `auto` | `auto`, `lexical` or `hybrid` |
| `folder` | — | one root label (see `fouine_status.roots`); an unknown label is refused by name |
| `ext` | — | one extension, without the dot |
| `lang` | — | documents written in that language (ISO 639-1); `und` = undetermined |
| `source` | — | pages whose text has that origin: `native`, `ocr` or `transcript` |
| `doc_ids` | — | "search within the results": at most 50 documents; an id that names no document is refused |
| `since` | — | only documents modified on or after that date, `YYYY-MM-DD`. A date written any other way is a **tool error naming the format**, never a filter quietly dropped |
| `fuzzy` | `auto` | `off`, `auto` (widen only when the exact search finds fewer than 20 pages) or `on` |
| `facet` | — | also count the results by `doc_year`, `modified_year`, `folder`, `ext`, `source` or `lang`, returned in `facets`. First page only |
| `compact` | `false` | move the paths out of the hits and into `documents`, one entry per document |
| `marks` | `guillemets` | what surrounds the matched words in a snippet: `«…»`, `brackets`, `asterisks` or `none` |
| `snippet_chars` | `240` | **ceiling** on each snippet, 80 to 800 characters. It cuts, it does not widen |

`folder`, `ext` and `lang` are real filters: they enter the query, the totals
follow them, and hybrid mode applies them to **both** channels, so a result
"suggested by meaning" cannot come from a document the filter excludes.

**A filter value that does not exist is refused by naming the ones that do**,
for `folder`, for `lang`, for `doc_ids`. Zero results is not information: it
reads exactly like "your corpus does not cover this subject", and an assistant
would read it that way. The refusal is an `isError` carrying the list, which the
model reads and corrects:

```
fouine_search: unknown language “xx” — languages in this index: cs, da, de, en,
es, fi, fr, hu, id, is, it, nb, nl, pl, pt, ro, sv, tr, und, vi
fouine_search: unknown document id(s): 999999 — use fouine_list_documents to
find the right ones
```

`source` is the only filter that bears on the **page** rather than the document:
one PDF can carry typed pages and scanned pages, and `"source": "ocr"` returns
only the second kind, totals, facets, semantic channel **and `name_matches`**
included — a document without a single page of that origin does not answer a
query that asked for nothing else. The three values partition the pages.

**The two years are two different questions.** `facet: "doc_year"` counts the
year each document CARRIES (its own date, present on most of them);
`facet: "modified_year"` counts the year its FILE was last changed. On a corpus
of course material the second says 2026 for handouts written in 2024, because
that is when the files were last touched. Facets are computed on the **first
page of results only**: they describe the whole search, not the slice, and a
cursor would recompute the same numbers at the price of a full scan.

**`compact: true`** is the answer to two things at once. Ten hits usually come
from three or four documents, and a flat list makes a model read "ten sources";
and the three paths (`path`, `abs_path`, `link`) are more than half of a normal
reply. Under `compact`, each hit keeps `doc_id`, `page`, `snippet` and the
scores, and `documents` carries each document once — `path`, `abs_path`,
`folder`, `ext`, `n_pages`, `hits` (how many hits of this reply come from it)
and `link` to its page 1. **The link of another page is that link with
`&page=N`** (plus `&t=<time_seconds>` for a recording). Measured: 10 hits over
eight documents, 21 752 → 18 408 bytes; 7 hits from one document,
13 346 → 7 224.

Reading the output:

- **`mode: "auto"`** takes hybrid if the model is installed **and** there are
  vectors, otherwise full text. The fallback is **never** an error, the search
  worked, and it is **never** silent either: `mode_used`, `semantic_available`
  and `note` say so. A silent fallback would make the assistant conclude your
  corpus holds nothing.
- **`name_matches`** is a second channel: the documents whose FILE NAME matches,
  five at most, with a `link` to their page 1. They are not pages, so they enter
  neither `hits` nor `total_pages`. The key is **always** present, empty when no
  name matches: an absent field teaches a model nothing.
- **`fuzzy_fallback`** is `true` when the exact search returned nothing and the
  query was replayed **once** tolerating typos across every document. That is the
  replay only. **`fuzzy_expanded`** is the flag to read: it is `true` whenever any
  hit carries a spelling CLOSE to a word asked for rather than the word itself —
  the ordinary pass widens too, below twenty exact pages. What comes back is then
  NOT the literal answer to the question asked: each hit carries its
  `fuzzy_distance`, its `why` says `fuzzy` and names what was `found`, and `note`
  says so. Both hold in both modes.
- **`quorum`** is `true` when fewer than ten pages carried **all** the words and
  the search also returned the pages carrying most of them. The head of the list
  carries everything, the rest does not: for a model, that is the difference
  between "these pages answer" and "these pages cover part of the subject". The
  key is always present, in **both** modes — the lexical channel of the fusion
  plays the quorum too, and since 14/09/2026 the command line arms and announces
  it in hybrid mode exactly as this server does — and a hit that comes from it says
  `why: {"kind": "partial"}` with the words its snippet shows, never `exact` with
  words the page may not carry.
- **`hybrid_disarmed`** says why the semantic channel did **not** serve although
  it was available: `"exact_phrase"` when the query asks for a quoted phrase,
  which meaning cannot honour; `"no_vectors_in_scope"` when not one page of the
  folder or the documents searched carries a vector — the model is then **not
  loaded at all**, which saves seconds, and `note` names the folder, the count
  and the command that prepares it. The answer is then the full-text one, with
  `mode_used: "lexical"`, `semantic_available: true` and the sentence in `note`.
  `null` the rest of the time, including when the model is missing, since the
  reason is in `note` then and two reasons for one fact stop being
  distinguishable.
- **`bm25`** is FTS5's raw score. It is negative, unbounded, and **not
  comparable between queries**. It is a sort key rather than a relevance out of
  100, and it is `null` for a page found by the semantic channel alone.
- **`relevance_pct`** is the readable one: this hit's score as a share of the
  best-scoring hit **of this reply**, 0 to 100 — the number the command line
  prints. It is relative and says nothing absolute: 100 means "nothing here
  scores higher", never "the answer", and two queries cannot be compared through
  it. In hybrid mode it is computed on the fused `rrf` score, so that a page
  found by meaning alone has one too. The order of the list can differ from it:
  under `quorum`, the pages carrying every word keep the head.
- **`semantic_scope`** says what the meaning channel can see of **this** search:
  `pages` (indexed pages in scope), `vectorised` (how many carry a vector), and
  `filtered` (`true` when a document filter narrowed the scope).
  `semantic_coverage_pct` is that ratio. Without a filter both describe the whole
  index, as before; with one they describe what was actually searched — a folder
  with no vector at all reads 0 %, where the global figure used to claim 67 %.
- **`cosine` is not relevance either**, and that is a measurement: on a real
  corpus every cosine of this model lives between 0.78 and 0.88, and the position
  in that band follows the shape of the query more than its subject. What reads
  is **`z`**, the hit's margin in the population scanned for *this* query, and
  `semantic_stats` gives μ and σ so you can judge for yourself.
- **`semantic_rank_scale`** is the factor applied to semantic ranks before the
  merge (`indexed pages / vectorised pages`, 1 once everything is vectorised,
  `null` in lexical mode): while 16 % of pages carry a vector, semantic rank 1 is
  worth lexical rank 6. It is what makes `rrf` readable:
  `1/(60 + lex_rank) + 1/(60 + vec_rank × scale)`.
- **`total_pages` counts plurals with singulars**, so `polymer` also counts the
  pages that only say "polymers".
- **`totals_approximate`** is `true` beyond 50 000 pages found: the totals are
  then capped, and the real ones are *at least* that. `note` then carries "very
  common word — add a second word to narrow the search". Notes accumulate,
  separated by "·".
- **`link`** reopens Fouine on that page. It is what makes an answer CITABLE. For
  a transcribed page it carries `&t=<seconds>` and reopens at the right moment.
- **`time_seconds`, `slide`, `embedded_image`: what the page really is.** A page
  of a recording covers about ten minutes of speech, so `time_seconds` (the
  moment the excerpt sits at, `null` for anything not transcribed) is what to
  cite — "at 12 min 40", not "page 2". In a slideshow (`.pptx`, `.odp`) the
  pictures embedded in the file are pages too, numbered **after** the slides: a
  53-slide deck has 202 pages. `slide` gives the slide number, `embedded_image`
  says "this is the Nth picture in the file, read by text recognition", and both
  are `null` for a PDF, whose pages are pages. The frontier is read from the
  index, nothing was migrated.
- **`why`** says why the page is there: `kind` is `exact` (`terms_found` lists
  the words), `fuzzy` (`typed`, `found`, `distance`), `semantic` (none of the
  words, meaning alone) or `both`. It is computed on the **snippet**, so it never
  concludes that a word is **missing**: a lexical hit carries every positive word
  by construction, and the snippet often shows only one. `terms_missing` comes
  only from the app, which reads the whole page. `null` when there is nothing
  honest to say.
- **None of your words in the corpus.** In hybrid mode, when `total_pages` is 0
  on the full-text side and hits come out anyway, `note` carries "none of your
  words is in your documents — these results come from meaning alone". For a
  model, that is the difference between "the corpus covers this" and "the corpus
  does not, here is the closest thing".
- **A refused query is a TOOL error** (`isError: true`), not a JSON-RPC error.
  The `query` argument is a perfectly valid string: it is its *content* the model
  must rewrite. A `-32602` breaks out of the tool loop in several clients; an
  `isError` puts the sentence where the model reads it and tries again. The
  command line makes the same choice: exit 64 (usage), never 1.
- **`has_more` / `next_cursor`**: the cursor is opaque and carries a fingerprint
  of the arguments. Pass it back with **the same** arguments; a cursor taken from
  another query is refused (`-32602`), which beats silently returning page 2 of a
  different search.

### `fouine_read_page`

The **indexed text** of a page: what Fouine extracted or recognised, not the
original file. Parameters: `doc_id` and `page` (required, `page` is 1-indexed),
`max_chars` (8 000 by default, 200 to 40 000, per page), `offset` (0), and
`context_pages` (0 to 2 pages before and after).

- An average page is about 2 500 characters, so the 8 000 default covers almost
  every page in one call.
- For a longer page, pass `next_offset` back as `offset` until it is `null`.
  `total_chars` always gives the whole length.
- Context pages come back **closest first** (p−1, p+1, p−2, p+2), which is what
  survives if the answer has to be shortened.
- `ocr_confidence` has a value only for a recognised page. In the output,
  `source` carries the exact value from the table (`native`, `ocr_accurate`,
  `transcript`); the input filter `ocr` of `fouine_search` returns
  `ocr_accurate` pages.
- A page that exists but whose text was never indexed, an image still waiting
  for recognition, comes back as a **success**, empty text, with a `note`. Asking
  for a page the document does not have is a tool error instead: `no page 340 in
  document 780 (it has 312 pages)`.
- **Four fields say what "page N" really means**, and they are here because this
  is the page an assistant is about to quote. `slide` and `embedded_image` for a
  slideshow, `time_seconds` for a recording — the same as in `fouine_search`,
  and the `link` carries `&t=` — plus **`page_label`**, the number *printed* on
  the page when it differs from its rank. All four are always present, `null`
  when they have nothing to say; the context pages carry them too.
- **`page_label` is read from the PDF itself**, which no other page read does.
  Measured against the same index: a page of a 428-page book goes from 12 ms to
  142 ms, a 1 173-page one from 11 ms to 238 ms (medians of three, interleaved).
  That is fine for one read and far too much per hit, which is why
  `fouine_search` does not carry it.
- **What `page_label` does not fix**: a book whose printed number lives only in
  the running head, with no `/PageLabels` dictionary in the file. PDFKit then
  returns the rank, and Fouine returns `null` rather than claim otherwise —
  measured on a real book where page 233 of the index prints "234". A book with
  roman front matter, on the other hand, is fixed: rank 12 comes back as `xi` or
  `3`. On 25 books of more than twelve pages, 11 (44 %) carry such a shift.

This tool shares its whole implementation with `fouine read` on the command
line: same reading, same slicing, same keys.

### `fouine_similar_pages`

Pages semantically close to a given page. **By default this tool never loads the
model**: the neighbours are read from the vector already in the database.
Parameters: `doc_id`, `page` (required), `limit` (10, up to 50), `min_cosine`
(0), `exclude_same_document` (`true`), `folder`, `ext`, `preview_chars` (200),
`encode_if_missing` (`false`), `compact` (`false`).

- **`min_cosine` is 0 by default, and that is not an oversight.** The 0.80
  threshold one is tempted to set was tried and measured: the 0.78-0.88 band of
  this model does not separate relevant from irrelevant, and a floor would cut
  first into the most useful neighbourhoods. The parameter stays for whoever
  knows what they are doing with it.
- **`source_has_vector: false`** is a success rather than an error: the page
  exists, it simply has not been vectorised yet (or is too short to carry a
  direction). `note` says so, the list is empty, and the note names
  `encode_if_missing`.
- **`encode_if_missing: true` encodes the source page on the spot**, which
  **does** load the model — about 2 s and 570 MB the first time in the life of
  the server, then roughly 0.3 s per page. It exists because a whole folder can
  sit at 0 % coverage, and "no neighbours" then reads as "nothing resembles this
  page" when the truth is "the campaign has not been here". Measured on a real
  index, a page of an unvectorised folder: 2 476 ms and no neighbour without it,
  4 237 ms and three neighbours (cosine 0.884, 0.882, 0.875) with it, then
  650 ms for the next page once the model and the index are resident.
- **`source_vector`** says where the vector that served came from: `stored`
  (read from the index), `computed` (encoded for this call), `null` (there is
  none). `source_has_vector` keeps describing **the index**, so it stays `false`
  on a page that was encoded on the spot — the campaign still has not been
  there.
- The vector computed on the spot is **the one the campaign would have written**:
  same windows, same null-vector rules, same quantisation. A page too short, or
  made of numbers, is refused with that reason rather than compared, because a
  null vector has a null dot product everywhere and its neighbourhood would be
  arbitrary.
- **`cosine` is returned per PAGE**, never per fragment of a page.
- Coverage under 50 % sets a `note`: neighbours are looked for only among
  vectorised pages, and that is worth knowing before concluding there is nothing.
- A neighbour taken from a recording carries **`time_seconds`**, and `compact`
  moves the paths out of the neighbours into a `documents` object keyed by
  `doc_id` — the same shape as in `fouine_search`, and it shows when several
  neighbours are pages of the same file.

### `fouine_list_documents`

What Fouine knows, with filters. With `state: "failed"`, it is the one-call
answer to "why is this document not showing up?". Parameters: `folder`, `ext`,
`path_contains` (a path fragment, matched literally), `state` (`indexed` by
default, or `failed`, `skipped`, `pending`, `any`), `limit` (50, up to 200),
`cursor`, `order` (`path`, `pages`, `recent`).

- The four states: **`indexed`** (the text is in the index), **`failed`** (the
  extraction failed, `error` says why), **`skipped`** (too big, or a format not
  supported), **`pending`** (seen by the crawler, not extracted yet).
- **`total`** is the number of documents the filter keeps, not the number
  returned.
- `ocr_pages` and `vectorised_pages` say how many pages come from recognition
  and how many carry a meaning vector. A page transcribed from a recording does
  not count in `ocr_pages`.
- **`modified`** is when the FILE was last changed, ISO 8601 in **UTC**. It is
  what `order: "recent"` sorts on, and until now an assistant sorted on a date
  it never saw. `fouine list --json` returns the same instant in the machine's
  own time zone; this server writes every timestamp in UTC, so that they can be
  compared with one another. It has nothing to do with `doc_date`.
- **`doc_date`** is the date the document CARRIES (`YYYY-MM-DD`, UTC), read from
  its metadata at extraction: PDF `CreationDate`, EPUB `dc:date`, office
  `dcterms:created`, EXIF `DateTimeOriginal`, an email's `Date:` header. It has
  **nothing to do** with the file's date, and it is `null` when the document
  carries none — a minority: on a real corpus of 1 883 documents, 1 390 (74 %)
  carry one. `fouine_search`'s `facet: "doc_year"` counts them.

---

## Citing a page

The four tools that return a page carry a **`link`** field, a `fouine://`
address that **reopens Fouine on exactly that page**. That is what makes an
assistant's answer verifiable. The sentence to write is:

```
Organic Chemistry — volume 2.pdf, page 87
fouine://open?path=/Users/…/Organic%20Chemistry.pdf&page=87
```

The file name, the page, then the link alone on its line (Mail, Notes and word
processors only make an address clickable when nothing follows it).

**With one reservation, and it is not cosmetic: "page N" is not always what the
reader will look for.** Three cases, all returned by `fouine_search` itself:

| The hit carries | Cite | Rather than |
|---|---|---|
| `slide: 12` | "slide 12" | page 12 — a slideshow's embedded pictures are pages too, after the slides |
| `time_seconds: 760` | "at 12 min 40" | page 2 — a page of a recording is ten minutes of speech |
| `embedded_image: 117` | "a picture inside the file" | page 170, which the reader will never find by flipping through slides |
| `page_label: "xi"` (read page only) | "page xi" | page 12 — the rank in the file, not what is printed on the paper |

A book with front matter is answered by **`fouine_read_page`**, which returns
`page_label` — the number printed on the page when it differs from its rank
(`xi` for rank 12). It is deliberately absent from `fouine_search`: it costs
opening the PDF, which is fine once and not ten times. One case stays open:
a book whose number lives only in the running head, with no `/PageLabels` in
the file. `page_label` is then `null` rather than wrong, and the link, which is
right in every case, is what carries the reader there.

Two forms, and the order of preference matters:

| Form | When | What it is worth |
|---|---|---|
| `fouine://open?path=<absolute path>&page=<n>` | the document's volume is mounted (`abs_path` not null) | survives reindexing, a restored database, a change of machine |
| `fouine://open?doc=<id>&page=<n>` | the volume is not mounted | valid only on this machine and this index: `doc_id` is a row identifier, reassigned by an index rebuilt from scratch |

The server chooses on its own; there is nothing to ask for.
`fouine_list_documents` returns a link **without a page**, because a listing
names documents rather than pages. A link can also carry the query (`&q=…`), and
the app then puts the highlights back on the words of the citation.

A link received by a machine without the app does nothing: the scheme is
declared by `Fouine.app`, not by the server.

---

## What the server does not do

- **It never writes.** The database is opened read-only at the SQLite level
  (`SQLITE_OPEN_READONLY`), the internal store exposes no write method, and no
  write tool is declared. Three independent barriers, and a test checking that
  after two hundred calls the `.db` file is identical to the byte.
- **It does not index.** No "add this folder" tool, no "run recognition" tool.
  An assistant able to start an indexing pass would spend your battery and your
  disk without being asked. `fouine_status` says what is missing; you act, in the
  app.
- **It does not hand over your original files.** `fouine_read_page` returns the
  *text* Fouine extracted or recognised, plus the absolute path of the file.
  Opening the PDF is your gesture. A search server pouring out whole documents
  would be a context leak and a copyright risk.
- **It never returns an unlimited answer.** Each answer stays under **60 000
  characters** (~20 000 tokens), and those 60 000 count the message **as the
  client receives it**, so both copies of the payload, the text block and the
  structured object. Beyond that, snippets are shortened first, then items, and
  the answer carries `truncated: true` with a cursor when the tool paginates.
  Never a silent truncation, and never a JSON cut in half. Counting one copy was
  a measured mistake: `fouine_list_documents` at 200 returned 115 484 characters
  on the wire, twice the announced ceiling, without ever setting `truncated`.
  The same call now returns 57 720 and sets it. The `content` block is still
  emitted next to `structuredContent`, although the specification only
  recommends it and it doubles the cost of every answer: it will go the day a
  real client shows it can do without, because a structured-only server would be
  mute for clients older than structured output, and "mute" is the worst state
  here.
- **It does not go out on the network.** Nothing, ever. The connections Fouine
  can make are listed in [privacy](privacy.md), and none of them comes from
  here.

---

## What it costs

Measured on a real 2.15 GB index (408 951 pages, 582 086 vectors, 67 %
coverage), release build, first call then the median of four:

| Call | Cold | Warm |
|---|---:|---:|
| `initialize` | 29.6 ms | — |
| `tools/list` | 15.5 ms | — |
| `fouine_status` | 800 ms | 2.6 ms (60 s cache) |
| `fouine_search`, full text | 354 ms | **214 ms** |
| `fouine_search`, **hybrid** | **2 135 ms** | **385 ms** |
| `fouine_read_page` (2 context pages) | 36.7 ms | 35.2 ms |
| `fouine_similar_pages` | 195.8 ms | 187.5 ms |
| `fouine_list_documents` | 102.7 ms | 64.8 ms |

Vector coverage is what moves these: at a third of that coverage,
`fouine_similar_pages` cost 38 ms, because it swept three times fewer vectors.
Hybrid search does not move: its cost is the model rather than the sweep.

Three later additions have a price of their own, measured on a 2.6 GB index of
434 372 pages (medians of three, interleaved against the previous build):
per-root coverage takes `fouine_status` from 1 959 ms to 2 907 ms cold, and
`include_roots: false` cancels it; `page_label` takes `fouine_read_page` from
12 ms to 142 ms on a 428-page book and from 11 ms to 238 ms on a 1 173-page one;
`encode_if_missing` takes `fouine_similar_pages` from 2 476 ms to 4 237 ms on
the first call of the server, then 650 ms once the model is resident.

Resident memory: 5.8 MiB at startup, 15.7 MiB after the first full-text search,
358 MiB after the first hybrid search at 16 % coverage, 524 MiB at 67 %. That
gives a fixed part of about 300 MiB (the model) plus around 325 MiB of vector
index at full coverage, so **count about 630 MiB** on a fully vectorised corpus
of 400 000 pages. Someone who only searches full text pays none of it, which is
why the model is loaded **lazily**, and `fouine_status` says where they stand
through `semantic.model_loaded`.

---

## The log

Everything goes to **standard error**, never to standard output, which carries
protocol messages only: that is a requirement of the specification. One line per
request:

```
2026-09-03T09:41:11Z info start fouine/1.0.0 "/Users/…/fouine.db" schema=v5
2026-09-03T09:41:23Z info initialize - 4.4 437
2026-09-03T09:41:32Z info tools/call fouine_search 473.3 3147
2026-09-03T09:43:56Z info stdin-closed - - 0
```

The columns are the timestamp, the level, the method, the tool, the duration in
milliseconds and the size of the answer in bytes. **Never the content of a
query, never a snippet, never a document path**, not even in `debug`, where only
ignored notifications and the protocol epoch are added. Claude Desktop archives
this stream in a file, and pouring your searches into it would amount to keeping
a history behind your back.

| `FOUINE_MCP_LOG` | Effect |
|---|---|
| `quiet` | nothing at all |
| `info` | the default: start, stop, one line per request |
| `debug` | plus ignored notifications and the protocol epoch retained |

---

## Troubleshooting

### "The server does not appear"

1. Check that the binary exists and answers: `/usr/local/bin/fouine --version`.
   If it is missing, the app installs it (Fouine ▸ Settings ▸ Advanced ▸
   "Install the command-line tool…"), or point the client at the copy inside
   the app, `/Applications/Fouine.app/Contents/Helpers/fouine`. That step does
   **not** concern the `.mcpb` extension, which carries its own copy; there,
   check that it is enabled in Settings ▸ Extensions.
2. Check that the `--` is there in `claude mcp add`.
3. Run the server by hand. It must answer one line of JSON:
   ```sh
   printf '%s\n' '{"jsonrpc":"2.0","id":1,"method":"initialize","params":{"protocolVersion":"2025-06-18","capabilities":{}}}' \
     | fouine mcp --stdio
   ```
4. Read the log: `~/Library/Logs/Claude/mcp-server-fouine.log` for Claude
   Desktop. Its first line gives the version, the database and the schema.

### "this Fouine index was written by a newer version"

The index was written by a Fouine newer than the binary serving MCP. That
happens when the app updated itself and `/usr/local/bin/fouine` still points at
an old binary. Reinstall the command-line tool from the app, or, with the
`.mcpb` extension, reinstall the extension from the new version's file.

The server **refuses rather than guesses**, and the refusal is clean: the
connection holds, `initialize` and `tools/list` answer, the tools return that
sentence as a tool error, and nothing is modified. That is true whether the index
changed version *while* the server was running (the check is redone every
minute) or was already in that state **at startup**: the server opens the index
at the first read, and a failed open is retried. So it never dies silently,
which is the only symptom your client would show ("server disconnected").

### "no Fouine index at …"

There is no database there yet. Add a folder and index it:

```sh
fouine root add ~/Documents/Thesis --label Thesis
fouine index
```

Again the connection holds: the server answers, the tools say that sentence, and
**as soon as the index exists it is served**, with no need to restart the client.
That is the case of someone installing the extension before indexing anything.

### "the index has a write-ahead log that only a writer can recover"

**The most frequent cause is not a crash: it is a copy.** A Fouine index comes
with two companion files, `fouine.db-wal` and `fouine.db-shm`. Copying,
restoring from Time Machine or transferring the `.db` alone leaves the
write-ahead log unapplied, and **no read command opens it**: not the assistant
server, not `fouine search`, not `fouine status`, not `fouine doctor`. (A
process killed while writing gives the same message; the gesture is the same.)

The gesture is one command allowed to **write**, once:

```sh
FOUINE_DB=/path/to/the/copy.db fouine maintain
```

then restart the client. Two traps: `fouine status` repairs nothing, being a
read command, and opening Fouine.app does not help for a copy, since the app
always opens the standard index. To avoid the situation, `fouine backup
<destination>` makes a copy that is already clean, where `cp` copies one file
out of three.

### `semantic.model_installed` is false

The 220 MB meaning model is not installed. It is an optional download: `fouine
model download`, or Settings ▸ Search by meaning in the app. Without it, search
stays full text, which is Fouine's normal regime rather than a fault.

### `semantic_available` is false although the model is installed

`fouine_search` needs **two** things for hybrid: the model, and **vectors**.
`semantic_available: false` with `semantic.model_installed: true` means there are
none yet, so the campaign has not run: `fouine embed`. It is resumable and can
run in several sittings; `fouine_status` shows the progress through `vectors`
and `vector_coverage_pct`. Meanwhile `fouine_search` answers in full text and
says so in `note`: it is never an error.

The neighbouring case, real but low coverage, is not a fault either. Under 50 %,
`fouine_search` and `fouine_similar_pages` set a `note` giving the percentage.

### `abs_path` is `null`

The document is on a **volume that is not mounted**: an unplugged external
drive, a disconnected network share. Fouine files paths relative to their volume
precisely so an index survives a change of mount point; without the volume, it
cannot rebuild the absolute path.

Results still come back, the text being in the index, readable and citable; only
the path is missing. `fouine_status` says which root is concerned: look for
`roots[].volume_mounted: false`. Plug the volume back in and `abs_path` returns
with no reindexing.

### "cursor does not match these arguments"

You passed a `next_cursor` with arguments different from the ones that produced
it. The cursor carries a fingerprint of the arguments, and the refusal is
deliberate: without it you would get page 2 of a search applied to another
search's results, with holes and duplicates, and no warning. Pass **exactly** the
same arguments plus `cursor`. To change a filter or a limit, start again with no
cursor.

---

## The protocol, for the curious

The server speaks **two revisions** of MCP in the same process, and the first
request decides which. A client that sends `initialize` gets the legacy regime
(2024-11-05 through 2025-11-25, plus `ping`); one that sends `server/discover`,
or a `_meta` carrying `io.modelcontextprotocol/protocolVersion`, gets the modern
one (2026-07-28, stateless, with `resultType`, `ttlMs` and `cacheScope`). Both,
because the current revision is negotiated by Claude Code only when
`MCP_PROTOCOL_NEGOTIATION=auto` is set, and nothing documents that Claude
Desktop negotiates it at all: a server speaking only the current revision would
work with neither client today, and one speaking only the old revision would
need rewriting in six months.

Framing is line-by-line JSON-RPC, with no header. *Request* errors (unknown
tool, argument of the wrong type) are JSON-RPC errors; *tool* errors
(incompatible schema, unmounted volume) are `isError: true` results, which is
the form a model can read and correct. Messages are handled one at a time, so a
`ping` received during a cold hybrid search waits about two seconds: that is the
simplest stdio regime, and it is correct. `resources/list` and `prompts/list`
answer with an empty list rather than `-32601`, which keeps strict clients from
warning about an incomplete protocol.

The protocol code lives in `Sources/FouineMCPKit/`, **under the MIT licence and
with no dependency**: it is reusable as it is by another project. The server
itself (`Sources/FouineMCP/`) links Fouine's core and falls under the
source-available licence, as does the shipped binary. See
[`LICENSING.md`](../LICENSING.md).
