# The assistant server

`fouine mcp --stdio` lets an assistant (Claude Code, Claude Desktop, Cursor,
Codex, Antigravity…) read the index Fouine keeps of your documents, on your
machine, with nothing going out on the network. The server is read-only: it
cannot modify the index, start an indexing pass or hand over your original
files.

- [Installing](#installing)
- [The four tools](#the-four-tools)
- [Citing a page](#citing-a-page)
- [What the server does not do](#what-the-server-does-not-do)
- [What it costs](#what-it-costs)
- [The log](#the-log)
- [Troubleshooting](#troubleshooting)
- [The protocol, for the curious](#the-protocol-for-the-curious)

---

## Installing

The most direct way is `fouine mcp install`, which configures your local clients
in one command. Manual configuration and the standalone `.mcpb` extension are
also available.

### Where the command lives

The `fouine` command line ships inside the application, at
`/Applications/Fouine.app/Contents/Helpers/fouine`. It is on your `PATH` as
plain `fouine` only once you have clicked Settings ▸ Advanced ▸ "Install the
command line tool…", which links it from `/usr/local/bin`. Without that step,
the full path works just as well and needs no administrator password:

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

The command looks for your applications and configures the server:

- Claude Desktop: updates `claude_desktop_config.json` in Application Support
  (backup first as `.fouine-bak`, atomic write);
- Claude Code: runs `claude mcp add --scope user fouine -- <path> mcp --stdio`
  if the `claude` client is on the `PATH`;
- Cursor: configures `~/.cursor/mcp.json`;
- Codex (CLI, app and VS Code extension): adds a `[mcp_servers.fouine]` table to
  `~/.codex/config.toml`, replacing it if it is already there and leaving every
  other line of the file untouched;
- Antigravity (2.0, IDE and CLI): configures `~/.gemini/config/mcp_config.json`,
  or `~/.gemini/antigravity/mcp_config.json` on an installation that has not
  migrated yet.

A client whose folder does not exist is reported as skipped ("Codex is not
installed"). An entry that Fouine already wrote keeps the other keys you may
have added to it, such as an `env` block. The command uses
`/usr/local/bin/fouine` when that symlink points at the current binary, so the
configuration survives app updates.

Useful options: `--client claude-desktop` (or `claude-code`, `cursor`, `codex`,
`antigravity`) targets one client; `--dry-run` shows what would be written
without touching a file; `--json` prints a machine-readable result.

### Claude Desktop, the `.mcpb` extension

Download `Fouine-<version>.mcpb` from the releases page, then double-click it:
Claude Desktop opens its installer, which shows the four tools and one optional
setting. You can also drop the file in **Settings ▸ Extensions ▸ Advanced
Extensions**.

The setting is called "Fouine index". Leave it empty: the server then uses the
standard location, `~/Library/Application Support/Fouine/fouine.db`, the one the
app uses. Fill it in only if you keep several indexes and want to serve one of
them in particular.

The `.mcpb` file is an archive that contains its own copy of the `fouine`
program, signed and notarised by Apple. If all you want is to let an assistant
read an existing index, you have nothing else to install, not even the app. The
app is still what builds that index: the extension is read-only and does not
index.

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

This assumes the command line is installed (Settings ▸ Advanced ▸ "Install the
command line tool…"). Restart Claude Desktop.

The server's log is in `~/Library/Logs/Claude/mcp-server-fouine.log`. Look there
first when something goes wrong, whichever way you installed it.

### Claude Code

```sh
claude mcp add --scope user fouine -- /usr/local/bin/fouine mcp --stdio
```

The `--` is required. It separates the options of `claude mcp add` from the
command to run; without it, `mcp` and `--stdio` are read as options of the
client, and the command either fails or registers a server that does not start.
Check with `claude mcp list`.

Claude Code does not install `.mcpb` extensions: use the command above, with
`/usr/local/bin/fouine` installed (or the full path inside the app).

### Cursor

`fouine mcp install --client cursor` writes `~/.cursor/mcp.json`. By hand, the
file has the same `mcpServers` shape as Claude Desktop's.

### Codex

`fouine mcp install --client codex` writes `~/.codex/config.toml`, the file that
the Codex CLI, the Codex app and its VS Code extension all read. By hand, either
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

The command only ever touches that one table, so a `[mcp_servers.fouine.env]`
sub-table you added stays. The one shape it refuses is `mcp_servers` written as
an inline table (`mcp_servers = { … }`), because TOML forbids extending it
afterwards: the command then reports the problem and leaves the file alone.

### Antigravity

`fouine mcp install --client antigravity` writes
`~/.gemini/config/mcp_config.json`, the configuration shared by Antigravity 2.0,
the Antigravity IDE and the Antigravity CLI. Older installations keep it in
`~/.gemini/antigravity/mcp_config.json`, which the command uses when the new
folder does not exist. By hand, in the IDE: agent panel ▸ **…** ▸ **MCP
Servers** ▸ **Manage MCP Servers** ▸ **View raw config**, then the same
`mcpServers` entry as Claude Desktop's:

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

`--print --json` gives `{"command": …, "args": […]}` alone, for a script. Known
locations, as of September 2026: Gemini CLI reads `mcpServers` in
`~/.gemini/settings.json`; Windsurf in `~/.codeium/windsurf/mcp_config.json`;
VS Code reads a `servers` object in its `mcp.json` (User ▸ MCP: add server),
with `"type": "stdio"` next to `command` and `args`. A client with no MCP
support at all can still call the command line: `fouine search <query> --json`,
`fouine read <doc_id> <page>`, `fouine list --json`, `fouine status --json`.

### Two copies of the same program, and why

If you have both the app and the extension, there are two copies of the `fouine`
program on your disk: the one inside `Fouine.app`, and the one Claude Desktop
unpacked when it installed the extension. That is deliberate: the `.mcpb` exists
so that an installation depends on nothing else, and a manifest pointing at
`/usr/local/bin/fouine` would send the user back to the installation they were
avoiding. The cost is about 10 MB, and both copies read the same index.

As a consequence, the two update separately. After a Fouine update, reinstall the
extension if the message "this Fouine index was written by a newer version"
appears.

### Another index

`--db <path>` on the command line, the `FOUINE_DB` variable and the "Fouine
index" setting of the extension are the same thing: the extension only sets the
variable. Empty or absent means `~/Library/Application Support/Fouine/fouine.db`.

### Restricting what an assistant can see

`--folders Livres,M2SU` serves only those roots, by label. The option can be
repeated and accepts commas. `fouine mcp install --folders Livres,M2SU` writes
it into the client configurations, and running `install` again without it keeps
the scope already written.

What is outside the scope does not exist for that server:

- `fouine_status.roots` lists only the served roots, and `scope` carries them
  (`null` without the option);
- `fouine_search` never returns a page from elsewhere. A `folder` outside the
  scope is refused with a message naming only the served roots, the same refusal
  an invented label gets. A `lang` outside the scope is refused the same way, and
  the refusal names only the languages of the served documents, so it reveals
  nothing about the documents outside the scope;
- `fouine_read_page` gives the same answer for a `doc_id` outside the scope as for a `doc_id` that does not exist, so the
  refusal cannot be used to learn that the document is there;
- `fouine_list_documents` lists and counts the scope only.

`documents` in `fouine_status` is the count inside the scope; `pages_indexed`
still describes the whole index, which `scope.note` states explicitly. A label that names no root does not stop the
server: it starts, and every tool returns an error naming the roots that exist.
`fouine mcp` on a readable index, however, exits with code 64 before answering
anything.

```json
"scope": {
  "folders": ["Livres", "M2SU"],
  "note": "This server only serves these roots; anything else is invisible to it. …"
}
```

This is a reading scope: the documents stay indexed, searched by the app and
counted by `fouine status`. To keep a folder out of the index altogether, so that
nothing can search it, quote it or count it, exclude it instead: **What Fouine
skips…** in the app's settings, `fouine root ignore add`, or a `.fouineignore`
file at the top of the root. See
[excluding a folder](formats.md#excluding-a-folder-or-a-file-type-fouineignore).

---

## The four tools

| Tool | What it answers |
|---|---|
| `fouine_status` | what is in the index, and is anything missing from it right now? |
| `fouine_search` | which pages talk about this? (and, per hit, what the page really is: a slide, a moment in a recording, a picture inside a file) |
| `fouine_read_page` | what does this page say, exactly, and what does "page N" actually mean here? |
| `fouine_list_documents` | what is in the index, and why is this document missing? |

That is also the order in which an assistant should discover them, and the order
of `tools/list`.

Each tool returns its result twice: in `structuredContent`, validated by its
`outputSchema`, and in a `content` block of type `text` that carries the same
JSON, serialised. The specification recommends this, and it lets a client that
does not handle structured output work anyway. It is also why the size limit
counts the payload twice.

All four carry the same annotations: `readOnlyHint: true`, `destructiveHint:
false`, `idempotentHint: true`, `openWorldHint: false`. A client reads them
before calling, and they let it skip a confirmation prompt on every call: none of
these tools can modify anything, and they only reach your index.

### An example, end to end

```json
{"jsonrpc":"2.0","id":4,"method":"tools/call",
 "params":{"name":"fouine_search",
           "arguments":{"query":"electrolyse","limit":2}}}
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
     "why": {"kind": "exact", "terms_found": ["electrolyse"]}},
    {"doc_id": 63, "page": 6, "…": "…",
     "bm25": -9.7413, "relevance_pct": 98,
     "why": {"kind": "exact", "terms_found": ["electrolyse"]}}
  ],
  "total_pages": 53, "total_docs": 18, "totals_approximate": false,
  "note": null,
  "name_matches": [], "fuzzy_fallback": false, "fuzzy_expanded": false,
  "quorum": false, "documents": {}, "facets": null, "has_more": true,
  "next_cursor": "eyJmIjoiMGExZjEzY2Q5NTc1YmFlNWQ2YzliZjcwIiwibyI6MywidiI6MX0",
  "elapsed_ms": 214.02
}
```

### `fouine_status`

Health and coverage of the index. An assistant should call it first: it gives the
number of documents and pages in the index, how many scanned pages are still
waiting to be read (`ocr_queue`), and whether a folder is missing because its
volume is not mounted. It has two optional parameters, `include_roots` and
`include_agent`, both `true` by default.

The fields that need an explanation:

- `ocr_queue` is the number of scanned pages still waiting for text
  recognition. Their text is not searchable yet, so read it before concluding
  that a folder has nothing to say.
- `disk_budget` gives the size of the index (`bytes`), the budget
  (`budget_bytes`, 2.5 GB), and where the index stands against it (`ratio_now`,
  `level`: `ok`, `near`, `over`). `pages_at_budget` estimates how many pages the
  index would hold when it reaches the budget, and is `null` on an empty index.
  Nothing stops at 100 %: `level` is a warning, not a failure. **Read
  `disk_budget.level` before advising to add folders**: on a corpus already
  `over` budget, every new folder makes the index larger still.
- `write_lock`: another Fouine process (the app, the agent, a command) is writing
  to the index. That blocks no read, because SQLite's WAL allows concurrent
  readers. The field explains why a count can change between two calls.
- `agent.report_detail` describes what the background agent is doing, in
  English. The database stores a language-neutral token, which each surface
  renders in its own language; an unknown token, from an agent of another
  version, is passed through as it is.
- `agent.healthy`, `agent.alive` and `agent.stale` give the same verdict as
  `fouine status --json` on the command line. `healthy` is false when the agent
  has published a report but is no longer registered with launchd: it ran and
  it is gone. It stays true when no report exists at all, because nobody ever
  turned automatic updates on, which is a setting and not a fault.
- `roots[].path` is `null` when the volume is not mounted, which answers "why have
  my archives disappeared?".
- `scope` is `null` when the whole index is served, and otherwise names the only
  roots this server serves (`fouine mcp --folders`). `documents` is then the count
  inside that scope, while `pages_indexed` stays index-wide. See
  [restricting what an assistant can see](#restricting-what-an-assistant-can-see).

`write_lock` is read on every call. Everything else is cached for 60 s, and the
agent report has its own 60 s cache, because asking launchd can take up to
500 ms; `include_agent: false` skips it.

### `fouine_search`

Full-text search, with typing mistakes tolerated. It returns pages, not
documents: the `(doc_id, page)` pair is the key the next two tools take.

| Parameter | Default | Effect |
|---|---|---|
| `query` | *required* | bare words = AND, `"phrase"` = exact, `term*` = prefix (4 letters minimum), `-term` = exclude the whole document, `pres:5` (or `near:5`) = within 5 words, `dossier:X` (or `folder:X`) and `ext:pdf` = filters. Never `AND`, `OR` or `NOT`: words are already combined with AND. Any other `word:value` is refused, with the list of filters. `nom:X` (or `name:X`) searches file names only, and on its own returns one line per document; `texte:X` (or `body:X`) searches pages only. Curly quotes count as straight quotes |
| `limit` | `10` | 1 to 50 pages |
| `cursor` | none | the `next_cursor` of a previous result |
| `folder` | none | one root label (see `fouine_status.roots`); an unknown label is refused by name |
| `ext` | none | one extension, without the dot |
| `lang` | none | documents written in that language (ISO 639-1); `und` = undetermined |
| `source` | none | pages whose text has that origin: `native`, `ocr` or `transcript` |
| `doc_ids` | none | "search within the results": at most 50 documents; an id that names no document is refused |
| `since` | none | only documents modified on or after that date, `YYYY-MM-DD`. A date written any other way is a tool error naming the format, never a filter silently dropped |
| `fuzzy` | `auto` | `off`, `auto` (widen only when the exact search finds fewer than 20 pages) or `on` |
| `facet` | none | also count the results by `doc_year`, `modified_year`, `folder`, `ext`, `source` or `lang`, returned in `facets`. First page only |
| `compact` | `false` | move the paths out of the hits and into `documents`, one entry per document |
| `marks` | `guillemets` | what surrounds the matched words in a snippet: `«…»`, `brackets`, `asterisks` or `none` |
| `snippet_chars` | `240` | limit on each snippet, 80 to 800 characters. It cuts, it does not widen |

`folder`, `ext` and `lang` are real filters: they enter the query, and the
totals follow them.

A filter value that does not exist is refused with the list of values that do,
for `folder`, `lang` and `doc_ids`. Zero results would read exactly like "your
corpus does not cover this subject", and an assistant would read it that way.
The refusal is an `isError` that carries the list, which the model reads and
uses to correct the call:

```
fouine_search: unknown language “xx” — languages in this index: cs, da, de, en,
es, fi, fr, hu, id, is, it, nb, nl, pl, pt, ro, sv, tr, und, vi
fouine_search: unknown document id(s): 999999 — use fouine_list_documents to
find the right ones
```

`source` is the only filter that applies to the page rather than the document:
one PDF can contain typed pages and scanned pages, and `"source": "ocr"` returns
only the second kind, in the totals, the facets and `name_matches` too. A document without a single page of that origin does not
match a query restricted to it. The three values partition the pages.

The two years answer two different questions. `facet: "doc_year"` counts the
year each document carries (its own date, present on most of them);
`facet: "modified_year"` counts the year its file was last changed. On a corpus
of course material the second says 2026 for handouts written in 2024, because
that is when the files were last touched. Facets are computed on the first page
of results only: they describe the whole search, not the slice, and a cursor
would recompute the same numbers at the cost of a full scan.

`compact: true` solves two problems at once. Ten hits usually come from three or
four documents, and a flat list makes a model read "ten sources"; and the three
paths (`path`, `abs_path`, `link`) make up more than half of a normal reply.
Under `compact`, each hit keeps `doc_id`, `page`, `snippet` and the scores, and
`documents` lists each document once: `path`, `abs_path`, `folder`, `ext`,
`n_pages`, `hits` (how many hits of this reply come from it) and `link` to its
page 1. The link of another page is that link with `&page=N` (plus
`&t=<time_seconds>` for a recording). Measured: 10 hits over eight documents,
21 752 → 18 408 bytes; 7 hits from one document, 13 346 → 7 224.

Reading the output:

- `name_matches` is a second channel: the documents whose file name matches,
  five at most, with a `link` to their page 1. They are not pages, so they are
  counted in neither `hits` nor `total_pages`. The key is always present, and
  empty when no name matches, because an absent field tells a model nothing.
- `fuzzy_fallback` is `true` when the exact search returned nothing and the query
  was run once more, tolerating typos across every document. It covers that
  second run only. **`fuzzy_expanded` is the flag to read**: it is `true` whenever
  a hit contains a spelling close to a word asked for rather than the word
  itself, since the ordinary pass also widens below twenty exact pages. What
  comes back is then not the literal answer to the question asked: each hit
  carries its `fuzzy_distance`, its `why` says `fuzzy` and names what was
  `found`, and `note` reports it.
- `quorum` is `true` when fewer than ten pages contained all the words and the
  search also returned the pages that contain most of them. The top of the list
  contains every word, the rest does not: for a model, that is the difference
  between "these pages answer" and "these pages cover part of the subject". The
  key is always present, and the command line reports the quorum exactly as
  this server does. A hit that comes from it says `why: {"kind":
  "partial"}` with the words its snippet shows, never `exact` with words the page
  may not contain.
- `bm25` is FTS5's raw score. It is negative, unbounded, and not comparable
  between queries. It is a sort key, not a relevance out of 100.
- `relevance_pct` is the readable one: this hit's score as a share of the
  best-scoring hit of this reply, 0 to 100, the number the command line prints.
  It is relative and says nothing absolute: 100 means "nothing here scores
  higher", never "the answer", and two queries cannot be compared through it.
  The order of the list can differ from it: under
  `quorum`, the pages that contain every word stay at the top.
- `total_pages` counts plurals with singulars, so `polymer` also counts the pages
  that only say "polymers".
- `totals_approximate` is `true` beyond 50 000 pages found: the totals are then
  capped, and the real ones are *at least* that. `note` then carries "very
  common word — add a second word to narrow the search". Notes accumulate,
  separated by "·".
- `link` reopens Fouine on that page, which is what makes an answer citable. For
  a transcribed page it carries `&t=<seconds>` and reopens at the right moment.
- `time_seconds`, `slide` and `embedded_image` say what the page really is. A
  page of a recording covers about ten minutes of speech, so `time_seconds` (the
  moment of the excerpt, `null` for anything not transcribed) is what to cite:
  "at 12 min 40", not "page 2". In a slideshow (`.pptx`, `.odp`), the pictures
  embedded in the file are pages too, numbered after the slides: a 53-slide deck
  has 202 pages. `slide` gives the slide number, `embedded_image` says "this is
  the Nth picture in the file, read by text recognition", and both are `null`
  for a PDF, whose pages are pages. The boundary is read from the index, and no
  migration was needed.
- `why` gives the reason the page is there: `kind` is `exact` (`terms_found`
  lists the words), `partial` (some of them, under `quorum`) or `fuzzy`
  (`typed`, `found`, `distance`). It is computed on the snippet, so it never
  concludes that a word is missing: an exact hit contains every positive word by
  construction, and the snippet often shows only one. `terms_missing` comes only
  from the app, which reads the whole page. `why` is `null` when the snippet
  supports no verdict.
- A refused query is a tool error (`isError: true`), not a JSON-RPC error. The
  `query` argument is a valid string; what the model must rewrite is its
  content. A `-32602` breaks out of the tool loop in several clients, while an
  `isError` puts the sentence where the model reads it and tries again. The
  command line makes the same choice: exit 64 (usage), never 1.
- `has_more` / `next_cursor`: the cursor is opaque and carries a fingerprint of
  the arguments. Pass it back with the same arguments; a cursor taken from
  another query is refused (`-32602`), which is better than silently returning
  page 2 of a different search.

### `fouine_read_page`

The indexed text of a page: what Fouine extracted or recognised, not the
original file. Parameters: `doc_id` and `page` (required, `page` is 1-indexed),
`max_chars` (8 000 by default, 200 to 40 000, per page), `offset` (0), and
`context_pages` (0 to 2 pages before and after).

- An average page is about 2 500 characters, so the 8 000 default covers almost
  every page in one call.
- For a longer page, pass `next_offset` back as `offset` until it is `null`.
  `total_chars` always gives the whole length.
- Context pages come back closest first (p−1, p+1, p−2, p+2), which is what
  survives if the answer has to be shortened.
- `ocr_confidence` has a value only for a recognised page. In the output,
  `source` carries the exact value from the table (`native`, `ocr_accurate`,
  `transcript`); the input filter `ocr` of `fouine_search` returns
  `ocr_accurate` pages.
- A page that exists but whose text was never indexed, such as an image still
  waiting for recognition, comes back as a success, with empty text and a
  `note`. Asking for a page the document does not have is a tool error instead:
  `no page 340 in document 780 (it has 312 pages)`.
- Four fields say what "page N" really is, because this is the page an
  assistant is about to quote: `slide` and `embedded_image` for a slideshow,
  `time_seconds` for a recording (the same as in `fouine_search`, and the `link`
  carries `&t=`), plus `page_label`, the number printed on the page when it
  differs from its rank. All four are always present, `null` when they do not
  apply; the context pages carry them too.
- `page_label` is read from the PDF itself, which no other page read does.
  Measured against the same index: a page of a 428-page book goes from 12 ms to
  142 ms, a 1 173-page one from 11 ms to 238 ms (medians of three, interleaved).
  That is fine for one read and far too much per hit, which is why
  `fouine_search` does not carry it.
- `page_label` has one limit: a book whose printed number appears only in the
  running head, with no `/PageLabels` dictionary in the file. PDFKit then returns
  the rank, and the field is `null` rather than a wrong number. This was measured
  on a real book where page 233 of the index prints "234". A book with roman
  front matter, on the other hand, is handled: rank 12 comes back as `xi` or
  `3`. Of 25 books of more than twelve pages, 11 (44 %) have such a shift.

This tool shares its whole implementation with `fouine read` on the command
line: same reading, same slicing, same keys.

### `fouine_list_documents`

The contents of the index, with filters. With `state: "failed"`, it answers "why
is this document not showing up?" in one call. Parameters: `folder`, `ext`,
`path_contains` (a path fragment, matched literally), `state` (`indexed` by
default, or `failed`, `skipped`, `pending`, `any`), `limit` (50, up to 200),
`cursor`, `order` (`path`, `pages`, `recent`).

- The four states: `indexed` (the text is in the index), `failed` (the
  extraction failed, and `error` gives the reason), `skipped` (too big, or a
  format not supported), `pending` (seen by the crawler, not extracted yet).
- `total` is the number of documents the filter keeps, not the number returned.
- `ocr_pages` gives how many pages come from text recognition. A page
  transcribed from a recording does not count in it.
- `modified` is when the file was last changed, ISO 8601 in UTC. It is what
  `order: "recent"` sorts on, so an assistant can see the date it sorts by.
  `fouine list --json` returns the same instant in the machine's own time zone;
  this server writes every timestamp in UTC, so that they can be compared with
  one another. It has nothing to do with `doc_date`.
- `doc_date` is the date the document carries (`YYYY-MM-DD`, UTC), read from its
  metadata at extraction: PDF `CreationDate`, EPUB `dc:date`, office
  `dcterms:created`, EXIF `DateTimeOriginal`, an email's `Date:` header. It has
  nothing to do with the file's date, and it is `null` when the document carries
  none. That is a minority: on a real corpus of 1 883 documents, 1 390 (74 %)
  have one. `fouine_search`'s `facet: "doc_year"` counts them.

---

## Citing a page

The three tools that return a page or a document carry a `link` field, a `fouine://` address
that reopens Fouine on exactly that page. That is what makes an assistant's
answer verifiable. The citation to write is:

```
Organic Chemistry — volume 2.pdf, page 87
fouine://open?path=/Users/…/Organic%20Chemistry.pdf&page=87
```

The file name, the page, then the link alone on its line (Mail, Notes and word
processors only make an address clickable when nothing follows it).

**"Page N" is not always what the reader will look for.** Three cases, all
returned by `fouine_search` itself, plus one from `fouine_read_page`:

| The hit carries | Cite | Rather than |
|---|---|---|
| `slide: 12` | "slide 12" | page 12: a slideshow's embedded pictures are pages too, after the slides |
| `time_seconds: 760` | "at 12 min 40" | page 2: a page of a recording is ten minutes of speech |
| `embedded_image: 117` | "a picture inside the file" | page 170, which the reader will never find by flipping through slides |
| `page_label: "xi"` (read page only) | "page xi" | page 12: the rank in the file, not what is printed on the paper |

For a book with front matter, use `fouine_read_page`, which returns
`page_label`: the number printed on the page when it differs from its rank (`xi`
for rank 12). It is deliberately absent from `fouine_search`, because it requires
opening the PDF, which is fine once and not ten times. One case is not covered: a
book whose number appears only in the running head, with no `/PageLabels` in the
file. `page_label` is then `null` rather than wrong, and the link, which is right
in every case, takes the reader to the page.

There are two forms, in order of preference:

| Form | When | What it is worth |
|---|---|---|
| `fouine://open?path=<absolute path>&page=<n>` | the document's volume is mounted (`abs_path` not null) | survives reindexing, a restored database, a change of machine |
| `fouine://open?doc=<id>&page=<n>` | the volume is not mounted | valid only on this machine and this index: `doc_id` is a row identifier, reassigned by an index rebuilt from scratch |

The server picks the form automatically; there is nothing to request.
`fouine_list_documents` returns a link without a page, because a listing names
documents rather than pages. A link can also carry the query (`&q=…`), and the
app then highlights the words of the citation again.

On a machine without the app, the link does nothing: `Fouine.app` declares the
scheme, not the server.

---

## What the server does not do

- The server never writes. The database is opened read-only at the SQLite level
  (`SQLITE_OPEN_READONLY`), the internal store exposes no write method, and no
  write tool is declared. These are three independent barriers, and a test checks
  that after two hundred calls the `.db` file is identical, byte for byte.
- It does not index. There is no "add this folder" tool and no "run recognition"
  tool: an assistant able to start an indexing pass would use your battery and
  your disk without being asked. `fouine_status` shows what is missing, and you
  act in the app.
- It does not hand over your original files. `fouine_read_page` returns the
  *text* Fouine extracted or recognised, plus the absolute path of the file.
  Opening the PDF is up to you. A search server that returned whole documents
  would leak context and raise copyright issues.
- It never returns an unlimited answer. Each answer stays under 60 000
  characters (~20 000 tokens), counted on the message as the client receives it,
  so both copies of the payload, the text block and the structured object.
  Beyond that, snippets are shortened first, then items are dropped, and the
  answer carries `truncated: true` with a cursor when the tool paginates. A
  truncation is never silent, and the JSON is never cut in half. Counting both
  copies matters: counted once, `fouine_list_documents` at 200 would send 115 484
  characters on the wire, twice the limit, without setting `truncated`; counted
  twice, the same call returns 57 720 and sets it. The `content` block is still
  sent next to `structuredContent`, although the specification only recommends
  it and it doubles the cost of every answer. It will be dropped once real
  clients show they can do without it, because a structured-only server would
  return nothing readable to clients older than structured output.
- It does not go out on the network, ever. The connections Fouine can make are
  listed in [privacy](privacy.md), and none of them comes from the server.

---

## What it costs

Measured on a real 2.15 GB index (408 951 pages), release build, first call
then the median of four:

| Call | Cold | Warm |
|---|---:|---:|
| `initialize` | 29.6 ms | n/a |
| `tools/list` | 15.5 ms | n/a |
| `fouine_status` | 800 ms | 2.6 ms (60 s cache) |
| `fouine_search` | 354 ms | **214 ms** |
| `fouine_read_page` (2 context pages) | 36.7 ms | 35.2 ms |
| `fouine_list_documents` | 102.7 ms | 64.8 ms |

Resident memory is 5.8 MiB at startup and 15.7 MiB after the first search.

---

## The log

Everything goes to standard error, never to standard output, which carries
protocol messages only, as the specification requires. There is one line per
request:

```
2026-09-03T09:41:11Z info start fouine/1.0.0 "/Users/…/fouine.db" schema=v5
2026-09-03T09:41:23Z info initialize - 4.4 437
2026-09-03T09:41:32Z info tools/call fouine_search 473.3 3147
2026-09-03T09:43:56Z info stdin-closed - - 0
```

The columns are the timestamp, the level, the method, the tool, the duration in
milliseconds and the size of the answer in bytes. The log never contains the
text of a query, a snippet or a document path, not even in `debug`, which only
adds ignored notifications and the protocol epoch. Claude Desktop archives this
stream in a file, and writing your searches there would keep a history of them
without your knowledge.

| `FOUINE_MCP_LOG` | Effect |
|---|---|
| `quiet` | nothing at all |
| `info` | the default: start, stop, one line per request |
| `debug` | plus ignored notifications and the protocol epoch retained |

---

## Troubleshooting

### "The server does not appear"

1. Check that the binary exists and answers: `/usr/local/bin/fouine --version`.
   If it is missing, install it from the app (Settings ▸ Advanced ▸ "Install the
   command line tool…"), or point the client at the copy inside the app,
   `/Applications/Fouine.app/Contents/Helpers/fouine`. This step does not apply
   to the `.mcpb` extension, which carries its own copy; there, check that it is
   enabled in Settings ▸ Extensions.
2. Check that the `--` is there in `claude mcp add`.
3. Run the server by hand. It must answer one line of JSON:
   ```sh
   printf '%s\n' '{"jsonrpc":"2.0","id":1,"method":"initialize","params":{"protocolVersion":"2025-06-18","capabilities":{}}}' \
     | fouine mcp --stdio
   ```
4. Read the log: `~/Library/Logs/Claude/mcp-server-fouine.log` for Claude
   Desktop. Its first line gives the version, the database and the schema.

### "this Fouine index was written by a newer version"

The index was written by a newer Fouine than the binary serving MCP. That happens
when the app updated itself and `/usr/local/bin/fouine` still points at an old
binary. Reinstall the command line tool from the app, or, with the `.mcpb`
extension, reinstall the extension from the new version's file.

The server refuses to read such an index, and the refusal is clean: the
connection holds, `initialize` and `tools/list` answer, the tools return that
sentence as a tool error, and nothing is modified. This holds whether the index
changed version while the server was running (the check runs again every minute)
or was already in that state at startup: the server opens the index at the first
read, and a failed open is retried. The server therefore never exits silently,
which your client would only show as "server disconnected".

### "no Fouine index at …"

There is no database there yet. Add a folder and index it:

```sh
fouine root add ~/Documents/Thesis --label Thesis
fouine index
```

Here too the connection holds: the server answers, the tools return that
sentence, and as soon as the index exists it is served, without restarting the
client. This is what happens when someone installs the extension before indexing
anything.

### "the index has a write-ahead log that only a writer can recover"

**The most frequent cause is a copy, not a crash.** A Fouine index comes with two
companion files, `fouine.db-wal` and `fouine.db-shm`. Copying, restoring from
Time Machine or transferring the `.db` alone leaves the write-ahead log
unapplied, and no read command can open it: not the assistant server, not
`fouine search`, not `fouine status`, not `fouine doctor`. (A process killed
while writing gives the same message, and the fix is the same.)

The fix is one command allowed to write, run once:

```sh
FOUINE_DB=/path/to/the/copy.db fouine maintain
```

then restart the client. Two traps: `fouine status` repairs nothing, because it
is a read command, and opening Fouine.app does not help for a copy, since the app
always opens the standard index. To avoid the situation, `fouine backup
<destination>` makes a copy that is already clean, whereas `cp` copies one file
out of three.

### `abs_path` is `null`

The document is on a volume that is not mounted: an unplugged external drive, a
disconnected network share. Fouine stores paths relative to their volume so that
an index survives a change of mount point; without the volume, the absolute path
cannot be rebuilt.

Results still come back, since the text is in the index, readable and citable;
only the path is missing. `fouine_status` shows which root is concerned: look for
`roots[].volume_mounted: false`. Plug the volume back in and `abs_path` returns,
with no reindexing.

### "cursor does not match these arguments"

You passed a `next_cursor` with arguments different from the ones that produced
it. The cursor carries a fingerprint of the arguments, and the refusal is
deliberate: without it you would get page 2 of a search applied to another
search's results, with gaps and duplicates, and no warning. Pass exactly the same
arguments plus `cursor`. To change a filter or a limit, start again with no
cursor.

---

## The protocol, for the curious

The server speaks two revisions of MCP in the same process, and the first
request decides which. A client that sends `initialize` gets the legacy mode
(2024-11-05 through 2025-11-25, plus `ping`); one that sends `server/discover`,
or a `_meta` carrying `io.modelcontextprotocol/protocolVersion`, gets the modern
one (2026-07-28, stateless, with `resultType`, `ttlMs` and `cacheScope`). Both
are needed: Claude Code negotiates the current revision only when
`MCP_PROTOCOL_NEGOTIATION=auto` is set, and nothing documents that Claude
Desktop negotiates it at all. A server speaking only the current revision would
work with neither client today, and one speaking only the old revision would
need rewriting in six months.

Framing is line-by-line JSON-RPC, with no header. *Request* errors (unknown
tool, argument of the wrong type) are JSON-RPC errors; *tool* errors
(incompatible schema, unmounted volume) are `isError: true` results, the form a
model can read and correct. Messages are handled one at a time, so a `ping`
received during a search waits for its answer: that is the simplest stdio
model, and it is correct. `resources/list` and `prompts/list`
answer with an empty list rather than `-32601`, so that strict clients do not
warn about an incomplete protocol.

The protocol code lives in `Sources/FouineMCPKit/`, under the MIT licence and
with no dependency, so another project can reuse it as it is. The server itself
(`Sources/FouineMCP/`) links Fouine's core and falls under the source-available
licence, as does the shipped binary. See [`LICENSING.md`](../LICENSING.md).
