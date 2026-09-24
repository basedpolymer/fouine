# Searching

The syntax is the same in the app and on the command line. You never need FTS5
syntax.

- [1. Query syntax](#1-query-syntax)
- [2. What moves a page up](#2-what-moves-a-page-up)
- [3. Typing mistakes](#3-typing-mistakes)
- [4. Search by meaning](#4-search-by-meaning)
- [5. Filters](#5-filters)
- [6. Reading a result](#6-reading-a-result)
- [7. The bench, in numbers](#7-the-bench-in-numbers)

---

## 1. Query syntax

| What you type | What it does |
|---|---|
| `nitrogen reduction` | both words (implicit AND), on the same page |
| `"ideal gas"` | exact phrase |
| `spectro*` | prefix, at least 4 letters before the `*` |
| `-biology` | exclusion, whole document: any document where the word appears is dropped |
| `near:5 nitrogen reduction` | the words within 5 words of each other |
| `folder:Thesis enthalpy` | restrict to one folder, by its label |
| `folder:"My courses" enthalpy` | the same when the label contains a space |
| `ext:pdf` | restrict to one extension |
| `name:report` | documents whose name contains "report" |
| `text:report` | "report" in the pages only; the file name does not count |
| `path:Offers` | the whole path contains this, folders included |
| `-ext:md` | exclude an extension |
| `-folder:Courses` | exclude a folder |
| `-name:draft` | exclude documents whose name matches |
| `-path:Archive` | exclude documents whose path contains this |
| `1512,50` | an amount: both spellings, with and without the thousands separator |

There are six filters, each with a French alias, because the app is available in
both languages:

| Filter | Alias | Example | What it does |
|---|---|---|---|
| `folder:` | `dossier:` | `folder:"My courses" enthalpy` | one folder, by its label |
| `ext:` | none | `ext:pdf nitrogen` | one extension |
| `near:` | `pres:` | `near:5 nitrogen reduction` | the words that follow, within 5 words |
| `name:` | `nom:` | `name:"analysis JB"` | the file name and its parent folder name only |
| `text:` | `texte:` | `text:report nitrogen` | an ordinary page word; the file name stops counting |
| `path:` | `chemin:` | `path:Offers nitrogen` | the whole path of the document |

Four of them also exist in the negative: `-folder:`, `-ext:`, `-name:` and
`-path:`, with the same aliases and the same quoting rules (`-folder:"My
courses"`). Like `-word`, they drop whole documents.

These four are the ones that select documents, and the other two have no
negative. Proximity is not a set of documents, and the negative of `text:word`
is `-word`. `-near:5` and `-text:report` are refused (exit 64), with a message
naming the four filters that can be excluded. Any other `-word:value` is
refused too, under the same rule as its positive form, so an unknown negative
filter never turns into a silent exclusion of a phrase.

`path:` searches the whole path; `name:` does not. The table of document names
holds the file name and the name of the folder that contains it, and nothing
more. On a real index, `name:Offers` returned 6 documents where 178 are filed
under `Internship/Offers/…`, because most of them sit one folder deeper. `path:`
matches anywhere in the path, ignoring case and accents, so `path:polymeres`
finds `Books/Polymères/`. Several `path:` terms are all required, and `path:`
alone lists the matching documents, exactly like `name:` alone.

Accents can be typed or pasted. A path copied from the Finder or from `ls`
carries its accents in the *decomposed* form, while what you type carries them
composed. The two look identical but are different strings, so Fouine
recomposes what it receives, in the query language and in `fouine list` alike.

These prefixes belong to the query language: you type them, they are not
translated, and they are the same whatever language the app is in.

`name:` searches names, not pages. It queries the table of document names (the
file name without its extension, then the name of the folder that contains it)
with the singular and plural forms of the word, so `name:report` finds
"Reports.docx". A quoted value is a phrase, and since the tokenizer cuts on `_`
and `-`, `name:"analysis JB"` finds `IP2022__Analysis_JB_DELIVERABLE`. Several
`name:` terms are all required.

- On its own (possibly with `folder:`, `ext:`, `-word` or the app's filters),
  `name:` returns the documents themselves: one line per document, opened at its
  first page that carries text. The snippet is the file name, the totals count
  documents, and the order is name relevance, then most recent. The name banner
  does not appear, since it would repeat the list. There is nothing to encode for
  meaning, so the search stays lexical.
- With words (`name:report nitrogen`), it restricts the documents the words are
  searched in: the pages that contain "nitrogen" among the documents whose name
  contains "report". In hybrid mode, meaning is restricted to the same
  documents.

`text:` switches the file name off. Without it, a word that also appears in a
file's name pushes that file forward and shows the name banner. `text:report` is
an ordinary page word (same pages, same totals, same text sent to meaning), but a
single `text:` removes the name bonus and the banner for the whole query.
`text:"ideal gas"` is an exact phrase.

Curly quotes count as straight quotes. macOS replaces typed quotes with
typographic ones by default, so `“ideal gas”` and `« catalysis »` would
otherwise be words surrounded by extra characters rather than exact phrases.
`“ ” „ ‟ « » ″` become `"` before any parsing, the curly apostrophe `’` becomes
`'`, and the French spaces inside the quotes are trimmed. Nothing else is
normalised.

A filter that does not exist is refused with its name, rather than searched as
a word. `type:pdf` or `in:Books` would otherwise return nothing, with no
explanation. The answer names the valid filters: exit 64 on the command line, a
tool error in the assistant server, a line under the field in the app.

```
$ fouine search 'type:pdf nitrogen' ; echo $?
Error: “type:” is not a filter — filters are dossier:/folder:, ext:, pres:/near:, nom:/name:, texte:/body:, chemin:/path:
64
```

The rule is narrow, so that it breaks nothing people actually type: it takes at
least two letters before the colon and a non-empty value that does not start
with `/`. A URL (`https://example.org`), a time (`10:30`), a one-letter notation
(`a:b`) and anything in quotes (`"Chapter:3"`) stay ordinary search terms. The
same rule applies to `-type:pdf`, with the same message: the leading `-` does
not change what the word is.

On the command line, a query that starts with a `-` has to come after `--`
(`fouine search -- '-ext:md nitrogen'`), because the argument parser reads it as
an option before Fouine sees the string. The error message shows that form.

A folder label that does not exist is refused too. Otherwise, `folder:Cour`
would filter on an unknown label and return nothing, which looks exactly like a
corpus that does not contain the term:

```
$ fouine search 'folder:Cour enthalpy' ; echo $?
Error: unknown folder “Cour” — yours are: Books, M2SU
64
```

Case is the only tolerated difference: `folder:books` does filter on "Books". A
missing accent is refused, because a refusal that says what to type is more
useful than a filter on a folder you did not name. While no folder is
registered, nothing is refused, since there is nothing to compare with.

A folder's label is, by default, the last segment of its path, so "My courses"
or "Course notes" contain a space. The label then goes in quotes, after the
colon: `folder:"My courses"`. Without them, `folder:My courses` searches for
"courses" in the text and filters on a folder called "My". The app's Folders
facet never needs this syntax: it passes the label as it is.

There is no `OR` and no explicit `AND`: positive terms are always combined with
AND. An empty query, a prefix that is too short and an exclusion on its own are
refused with a message that says what to do, and, on the command line, with
exit 64, an argument error rather than a failure.

```
$ fouine search 'chr*'
Error: prefix too short, give at least 4 letters
```

`AND`, `OR` and `NOT` in capitals are refused the same way, and case matters.
They are FTS5 keywords: passed through, they would produce an SQL error and an
exit code meaning "database corrupted" for what is only a typo.

```
$ fouine search 'polymer OR catalysis' ; echo $?
Error: “OR” is a search operator, not a word: Fouine combines words with AND by
default; to exclude a word, write -word (put it in quotes to search for the word
itself)
64
```

In lower case they are ordinary words and stay searchable; `"OR"` in quotes
searches for the word itself. `NEAR` is an FTS5 operator only when followed by a
parenthesis, so `nitrogen NEAR carbon` searches for the word "near".

The exclusion covers the whole document rather than the page: `enthalpy
-biology` drops every document where "biology" appears anywhere, even a hundred
pages from the hit. That is what you expect from a thematic filter.

Accents are ignored when indexing and when searching: `polymere` and `polymère`
are the same query.

A word stands for its plural. A word typed in the singular also finds the plural,
and the other way round: `polymere` finds "polymères", `liaisons` finds
"liaison", `metal` finds "métaux". This is grammar applied to the query, not
fuzzy matching. Short words are protected: under five letters, a word ending in
-s keeps its s (`mois`, `fois`, `pays`, `sens`, `bras`), and a short list
protects `temps`, `corps`, `cours`, `fonds`. The cost is that at four letters
`lois` does not find `loi`: type the singular. A quoted phrase, a `*` prefix,
the words of a `near:` and a `--raw-fts` string are never inflected. In a
bilingual library, a French word whose plural is a common English word raises
the total, and the Languages facet separates them. `fouine search '<query>'
--no-morphology` turns this off.

An amount is found in both its spellings. French documents write "1 512,50 €"
with a narrow no-break space, which the tokenizer cuts into two tokens. A number
with a decimal part and at least four digits before the comma is therefore
searched under both forms. There is no variant for a three-digit number or a
year: `2003` would become `"2 003"`, and the year is the number people type most
often.

For the cases the simple syntax does not cover, `--raw-fts` passes the string
straight to FTS5:

```sh
fouine search 'NEAR(nitrogen reduction, 3)' --raw-fts
fouine search 'chemistry NOT organic' --raw-fts
```

Pagination on the command line is `--limit N` (50 by default) and `--offset N`;
JSON output carries `offset` and the boolean `has_more`.

A prefix needs four letters before the `*` because the database has no prefix
index: `prefix='2 3'` was removed because it cost 480 MB. A short prefix
therefore sweeps a disproportionate share of the vocabulary.

---

## 2. What moves a page up

Six rules change the order of the results. None of them changes which pages are
found: the announced totals, the facets and the pages themselves are the same
with or without them. Each has a command-line flag that disarms it, for
calibration.

| Rule | What it does | Flag |
|---|---|---|
| Exact phrase | on `free energy`, the page carrying the two words in a row goes ahead of the one that has them thirty words apart | `--no-proximity` |
| Nearby words | within about a dozen words of each other, the page moves up as well, a little less | `--no-proximity` |
| Name of the file or folder | from two words on, the pages of a "Polymers.pdf" (or of anything filed under a "Polymers" folder) go ahead of an isolated mention in an unrelated book. On a single word, nothing moves: one book would fill the screen | `--no-proximity` |
| The form you typed | a page carrying the word exactly as you typed it goes ahead of one carrying only an inflected form. Both stay findable | `--no-typed-form` |
| One document does not take the whole screen | the three best pages of each document compete at full strength, and the following ones count for half. They do not disappear, they come after the other documents. Measured on the reference corpus, this takes a screen from 5.5 to 6.4 distinct documents | `--no-diversity` |
| Tables of contents move down | the text of the first fifty results is read again, and the ones that are contents pages, indexes or keyword lists go behind the others. Nothing is removed | `--no-demote-toc` |

These rules stay out of the way when the query already says what you want: a
quoted phrase, a `near:` or a `spectro*` prefix keeps the ranking you asked for.

A page counts as a contents page when two of three signs are present: at least
30 % of its non-empty lines end in a page number, at least 5 % of its characters
are leader dots or tabs, or its shape is a list (40 % of lines under six words,
or very few distinct words per word). The verdict is based on the whole page,
never on the snippet. Known limitation: a glossary with short entries,
cross-references and trailing page numbers has the shape of an index, and gets
moved down.

**When few pages contain all your words, the search keeps those that contain
most of them.** Fouine requires every word on the same page, function words
included, and that costs recall: `how to measure the heat released by a
reaction` returns 0 pages where `the heat released by a reaction` returns 10,
and the difference is "how" and "measure", not meaning. So when the strict search
returns fewer than ten pages and the query has at least three bare words, the
search runs again, requiring only 60 % of the words longer than three letters.
Pages that contain every word keep the lead; the others follow, ranked as usual,
and a line explains it: *"Few pages carry all your words: here are also the
pages that carry most of them."*

Words that carry no meaning are never required, whatever their length: about
eighty French and English function words ("dans", "avec", "pour", "cette",
"with", "that", "which"…) are left out of the count, on top of the three-letter
rule. And a question with more than six meaningful words keeps the six longest
instead of giving up: a question in plain language often has seven or eight, and
that is exactly where the strict AND fails.

Some queries stay strict: a quoted phrase, a `near:`, a `*` prefix, a `-word`
exclusion, a `name:` filter and a query restricted to one origin. They are
applied as typed. A folder, an extension, a language or a date do not disarm
this rule: otherwise the same question could return 28 pages on its own and zero
under `folder:Books`, which is exactly how an assistant writes its queries. A
filter narrows the set of documents; it has no bearing on how many words a page
must contain. When the strict search returns ten pages or more, nothing changes,
not even one extra query. There is no setting in the app; `--no-quorum` disarms
it.

Search by meaning does not disarm it either. The merge uses the same lexical
channel, so `fouine search --hybrid` reports the quorum like a full-text search:
`quorum: true` in JSON, and the same line on standard error. `--no-quorum`
covers both modes. The quorum was judged on full-text results (see the bench
below); in hybrid mode it still has to be judged on a fully vectorised corpus,
which is why this convention can be reversed.

A result that comes from the loosened pass is not presented as exact: its "why
this result" says *partial* and lists the words the excerpt shows, without
concluding that the others are missing, since an excerpt proves no absence.

A bench of 42 queries and 963 human relevance judgements settles which of these
rules earn their place. The quorum gains 0.031 nDCG@10 with no query made worse.
The contents-page demotion gains 0.021, and 0.101 on prefix queries. Diversity
costs 0.010 on pages and gains 0.065 on documents, which is the number the app
shows. Morphology is the clearest win of full-text search, 0.744 against 0.703.
The typed-form rule is inside the noise, and is kept because it is defensible,
not because it was measured. Every figure, its paired test and the reservations
that go with it are in "the bench, in numbers", at the end of this page.

---

## 3. Typing mistakes

Fuzzy matching is not a second search: it widens the terms of the query. For each
word that can be substituted, Fouine looks up the vocabulary and keeps the
candidates within a bounded edit distance.

- Under 6 letters, there is no widening. Short words are too close to one
  another; `gibbs` and `mayer` stay exact.
- From 6 letters, at most 12 variants are kept, and the tolerated distance
  depends on where the search widens. On scanned pages it stays 2: "rn" read as
  "m" costs two edits on a short word, and those are recognition mistakes.
  Across every document (the fallback, and `--fuzzy-scope all`), two edits on a
  six-letter word change the word: with 2, `Kenvue` would return 125 pages
  carrying "kenne", "kene", "cevue". The limit there is 1 from 6 to 8 letters,
  and 2 from 9, where two edits are still a plausible typo (`Villeurbane` →
  "Villeurbanne", 11 letters, one edit, unchanged).
- Exact matches come first: at equal relevance the exact match wins, but a dense
  and relevant fuzzy variant beats a weak exact page.
- There are no duplicates: each page appears once, with its best score.

A result found through a variant carries the `≈1` (or `≈2`) badge in the app,
and the `fuzzy_distance` field in JSON.

There are three modes (`--fuzzy`, or the sidebar selector):

| Mode | Behaviour |
|---|---|
| `off` | no expansion |
| `auto` *(default)* | expansion only when the exact query returns fewer than 20 pages |
| `on` | expansion always |

And two scopes (`--fuzzy-scope`):

| Scope | Behaviour |
|---|---|
| `ocr` *(default)* | widens only pages read from scans, where machine mistakes come from |
| `all` | the whole index |

**When a search returns nothing, it runs once more, tolerating mistakes across
every document**, and each surface says so: `No exact match — showing close
spellings from every document.` on the command line (`fuzzy_fallback: true` in
JSON), "No exact match: here are the closest spellings, in every document."
under the field in the app, and the same sentence in the assistant server's
`note`.

Four conditions must all hold: the query matched no page at all, it has at least
one parsed word (`--raw-fts` has none), mistakes are not refused (`--fuzzy
off`), and the query was not already this fallback. It costs nothing on the
normal path: there is no extra query as soon as there is one result. Measured on
a copy of a real 2.15 GB index, the fallback adds about 4 ms, and only when the
first pass found nothing.

Widening also happens without the fallback. In `auto` mode (the default), the
ordinary pass widens as soon as the exact query matches fewer than 20 pages. The
JSON then carries `fuzzy_expanded: true` whenever a result shown carries a close
spelling, and the command line prints *"some results carry a close spelling of
your word, not the word itself — see why.found"*.

Results from the fallback all carry a distance, so they are close spellings
rather than the words you asked for. In hybrid mode the fallback applies to the
lexical channel and the flag travels through the merge, so all three surfaces
report the same thing in both modes.

---

## 4. Search by meaning

Besides exact and fuzzy matching, Fouine can search by meaning: "catalyst
selectivity" finds a page about *regioselectivity* that shares not one word with
it.

Each page is cut into windows of 1 400 characters, and each window is summarised
as a 384-dimension vector by a local multilingual model (`multilingual-e5-small`,
converted to CoreML; nothing leaves the machine), quantised to 384 bytes. A
`--hybrid` query then merges two rankings by RRF (reciprocal rank fusion): the
usual FTS5 lexical ranking, and the pages closest to the query's vector. The
`folder:`, `ext:` and exclusion filters apply to both channels, and a purely
semantic result is marked as such.

A page has up to three windows, at characters `[0, 1400)`, `[1300, 2700)` and
`[2600, 4000)`, with 100 characters of overlap so that no sentence is cut in both
windows at once. On the reference corpus this covers 97.4 % of the text for 2.13
inferences per page; beyond 4 000 characters (4.9 % of pages) the rest is not
vectorised. A page never takes three places in the ranking: the index folds its
windows back onto the page and keeps the best one.

In the app, words come first and meaning second. The lexical channel runs alone
and its results appear, then the merge starts. In between, the count line shows a
spinner and "searching by meaning…", and "Load more" is unavailable. When the
merge arrives, it replaces the list: RRF re-ranks, which is its purpose. The
lexical channel therefore runs twice, once for the immediate display and once
inside the merge. That is one more FTS5 query, a few milliseconds, against
several seconds in front of an empty screen. The command line and the assistant
server have nothing to show in between, so they work as before.

A quoted phrase does not use meaning. The semantic channel has no quotes: it
compares vectors, and a page about the same subject entered the ranking without
containing the phrase, four results out of ten on the bench's exact-phrase
queries. `"ideal gas"` therefore returns exactly what full-text search returns,
and each surface says so: `meaning search not used: the query asks for an exact
phrase` on the command line, with `hybrid: false` and `hybrid_disarmed:
"exact_phrase"` in JSON; "Meaning is not used when you ask for an exact
phrase." under the field in the app, where the switch stays as it is.

Semantic ranks are scaled back to the whole corpus. Until a `fouine embed`
campaign has vectorised everything, the semantic channel compares only part of
the pages. A page ranked first among a sixth of the corpus is not first among all
of them, so the merge multiplies its rank by `indexed pages / vectors` before
combining. The scale is 1 once everything is vectorised. `--raw-semantic-ranks`
disarms it, and the JSON publishes `semantic_rank_scale`. Judged on the bench,
the scale helps: 0.587 nDCG@10 against 0.560 without it, and it helps most where
full-text search was already enough, which is what it is for.

### What hybrid search is worth

Judged on 42 queries and 790 relevance ratings, against full-text search:

| | queries | full text | hybrid | difference |
|---|---:|---:|---:|---:|
| full text returned **ten** results | 32 | **0.693** | 0.656 | **−0.037** |
| it returned **fewer than ten**, absurd queries aside | 5 | 0.104 | **0.603** | **+0.499** |
| the five **absurd** queries | 5 | 0.000 | 0.126 | +0.126 (noise) |

The overall gain of hybrid search comes from five queries, the ones where
full-text search returned nothing or almost nothing. **Everywhere else it makes
things worse.** Of the 420 results hybrid search returned, the 72 that contain no
word of the query are rated irrelevant 93 % of the time, and none of them is
rated "what I needed". A page that answers without sharing a single word with
the query does not exist in that corpus.

That is why "Also search by meaning" is off by default, and why `--hybrid` is
explicit on the command line. The semantic channel is most dangerous where
full-text search is safest: on a technical term outside the small model's
vocabulary, it offers pages about a similarly spelled subject.

### What the cosine does not say

A semantic result is shown with a margin, not with a cosine:

```
• [318] …/Wade.pdf p.261 — rrf 0.0164 · sem#1 z+4.7
```

`z+4.7` means: *this page is 4.7 standard deviations above the average page of
the corpus, for this query*. The raw cosine stays in the JSON (`cosine`) and is
shown nowhere, because it misleads. Measured on 64 872 vectors, every cosine of
this model falls between 0.78 and 0.88, and the position inside that band
follows the *shape* of the query more than its subject. A "cos 0.85" badge reads
as "85 % relevant", and it does not mean that.

Every search publishes the statistics of its own population in the JSON
(`semantic_stats`: `mu`, `sigma`, `cos_max`, `z_max`, `z_at_10`, `z_at_200`,
`scanned`, `zero_vectors`), so calibration needs no guessing.

> **There is no threshold, and that is a measurement result.** The obvious idea
> is to keep a semantic result only above a margin. Twelve control queries, six
> out of domain and six relevant, were replayed on a real index: the margin
> separates them backwards. An out-of-domain query is far from everything, so its
> mean is low and its best neighbour stands out by +4.5 to +7.7 σ; a relevant
> query is close to the whole corpus, so the mean is high and its best neighbour
> exceeds it by only +3.9 to +4.7 σ. A floor would first cut into the queries the
> channel serves best. The mechanism exists (`--vec-floor <z>`, 0 by default,
> disarmed) until a statistic separates the two. Judged on the bench, a +4 σ
> floor changes six queries out of 42 for a net −0.008, and on the one query
> where the semantic channel really helped, it truncated the list and cut the two
> pages that answered.

> So a sentence replaces the filter. The next idea was to drop
> "hallucinated" results on the raw cosine: above 0.82 with no lexical anchor,
> hide them. The measurements rule it out. The five absurd queries spread from
> 0.7975 to 0.8517, and perfectly relevant queries fall in the same band. A
> threshold at 0.82 would remove one and let three absurd ones through. One thing
> does hold: the five absurd queries have no lexical page, though two legitimate
> paraphrases have none either. So when the full-text channel found nothing and
> results come out anyway, the app shows "None of your words appears in your
> documents: these results are suggested by meaning only", and the command line
> and the assistant server put the same sentence in `note`. You judge; nothing
> is hidden.
>
> There are two sentences, not one. "No lexical page" means "no page contains
> them all", which is not the same as "none of your words exists". A nine-word
> question restricted to one folder can have one of its words in 22 documents of
> that very folder. So the search checks which of the typed words the index
> contains, and in that case shows "Your words are in your documents, but never
> together on the same page" instead; the command line and the assistant server
> name them: `(words present: reactor, residence)`. The first sentence is kept
> for the case it describes, where nothing you typed exists at all.

### Coverage

The `fouine embed` campaign is incremental, so the semantic channel often sees
only part of the corpus. Search reports it, because a hybrid result drawn from
16 % of the pages does not mean the same as one drawn from all of them:

```
$ fouine search 'catalysis' --hybrid
fouine: warning — semantic channel covers 16.6 % of the pages (64872 / 390114) — hybrid results are drawn from that subset; `fouine embed` extends it
```

The warning appears only under 50 % coverage. The JSON carries the same numbers
(`vectors`, `pages_indexed`, `semantic_coverage_pct`), and the app shows "·
meaning search sees only 64 872 pages out of 390 114" next to its counts.

Coverage follows the filter. A campaign fills the index in the order it found the
documents, so one folder can be fully vectorised while another has nothing at
all. Measured on a real index: 73 % on one root, 0 % on a second. A global
percentage then describes the corpus and not the search: a hybrid search
restricted to the second folder would compare no vector at all while announcing
68 % coverage. The assistant server (`fouine_search`) and the command line
(`fouine search --hybrid`, `--hybrid-auto`) therefore compute coverage for the
scope actually searched (`semantic_scope`: pages in scope, how many are
vectorised, and whether a filter narrowed it). A scope without a single vector
does not even load the model: the answer comes back as full-text, says so, and
names the command that would prepare that folder. Counting costs a few
milliseconds, and nothing at all when no document filter applies.

### Getting started

Install the model once:

```sh
fouine model download
```

The model is 220 MB, downloaded only when you ask, from the project's releases
page, and checked against its SHA-256 before installation. The command states
what it will contact before it connects. `fouine model status` shows what is
installed, and `fouine model remove` deletes it. See [privacy](privacy.md).

The app does the same without a terminal: ⌘, ▸ **Search by meaning** ▸
**Download the model (220 MB)…**. A sheet first lists what will be contacted,
what will be sent and what will be checked, and nothing happens until you click
Download.

> **Mac offline?** Copy the `e5-small-v1.zip` archive from another machine,
> then run
> `FOUINE_MODEL_URL=file:///Volumes/USB/e5-small-v1.zip fouine model download`.
> No connection is opened.

Then produce the vectors. Run the command as many times as needed, since the
campaign is incremental and can resume:

```sh
fouine embed                    # until done; Ctrl-C stops cleanly
fouine embed --budget-minutes 60
fouine embed --status           # vector coverage
fouine search 'catalysis' --hybrid
```

The background agent can also do it, ten minutes at a time, when the Mac is
plugged in and idle, if **Also prepare search by meaning in the background** is
ticked in Settings ▸ Indexing (it is unticked by default; see
[the agent](agent.md)). Vectors follow the life of the index: a page that is
extracted or recognised again is vectorised again at the next `embed` pass.

### Limits worth knowing

- The model is 220 MB and has to be downloaded. It is not bundled, because
  everyone would pay for its size, including people who never search by meaning.
- The scan is exhaustive, with no vector index. That is fast at the measured
  scale (about 6 ms over 363 058 vectors), but it is linear: on a corpus ten
  times larger it will show.
- The window is the unit that is vectorised, and the page is the unit that is
  shown. Beyond 4 000 characters the rest of the page is not vectorised at all,
  and a page that covers several subjects is poorly served by a window: the cut
  is mechanical, and follows neither paragraphs nor sections.
- The semantic channel always returns results. It returns its best pages even
  when the query has nothing to do with the corpus. The lexical channel returns
  zero when nothing matches, which is worth keeping: in hybrid mode, `lexical: 0
  page(s)` in the header means that everything that follows comes from vector
  proximity alone.
- Command line against resident server: hybrid search on the command line loads
  the engine at every call, while the assistant server and the app keep the
  model and the index in memory. Measured, that is about 1.1 s per call against
  0.39 s for the second call in a server.

---

## 5. Filters

The app computes five facets, plus Dated when results carry a date of their own,
and shows the first twelve values of each. Two of them, Modified in and Dated,
do not re-run the query, and their tooltips say so:

| Facet | Behaviour |
|---|---|
| Folders | a real filtered query on the folder |
| File types | a real filtered query on the extension |
| Languages | a real filtered query on the document's language |
| Text origin | a real filtered query on the origin of the page: typed text, scanned and read by Fouine, recognised before Fouine, transcribed from the audio |
| Dated | the year the document itself carries, when it carries one; filters the results already loaded |
| Modified in | filters the results already loaded |

Text origin is the only facet that applies to the page rather than the document:
origins are stored per page, and one book can mix typed pages and scanned
plates. The origins partition the pages: asking for one never returns another.

The Languages facet appears only when the results contain at least two
languages, since a monolingual corpus has no choice to offer. Codes are shown
under the name the system gives them in your language, and documents whose
language could not be determined form the "language not determined" value.

Dated is the year written in the document itself (PDF, Word, EPUB, email,
photo), as opposed to Modified in, which counts the last modification of the
file. A book from 2003 copied onto the Mac in 2024 falls under 2024 in one and
2003 in the other. The date is read when the document is indexed, and only then:
a document already indexed without one gets one only if it is indexed again.

On the command line, `--facet doc_year|modified_year|folder|ext|source|lang`
adds the counts to the result (and to the `facets` key of the JSON); `--lang fr`
(repeatable, `und` for undetermined), `--since YYYY-MM-DD` and `--source
native|ocr|transcript` filter. The assistant server has `lang` and `source`.

`doc_year` comes first on purpose: it is the year the document carries, the one
people mean by "a book from 2003". `modified_year` is the year the file was last
modified, which on a real corpus puts most of the index in the year it was
copied onto the Mac. For compatibility with existing scripts, `--facet year` is
still accepted, but the key returned in `--json` is always `modified_year`.

### Quick filters

Above the facets, four chips cover the filters people use most often:

| Chip | What it does |
|---|---|
| Modified this year | a real query: documents modified since 1 January |
| Modified in the last 5 years | a real query: since 1 January four years ago |
| PDF only | a real query on the extension |
| Scans only | a real query on the origin of the page |

Date windows are calendar years, like the Modified in facet: "this year" means
"since 1 January", not "the last twelve months". The two date chips exclude each
other, and an active chip turns off with a click.

The chips are not an extra filter: they drive the same state as the facets.
Unticking "pdf" in File types turns off the **PDF only** chip, and **Clear all**
removes them all.

---

## 6. Reading a result

The percentage in front of a line is relative. `fouine search` prints `100 %`,
`86 %`, `81 %`: each result's score as a share of the best one in that answer.
It means nothing absolute. 100 % means "nothing here scores higher", never "this
is the answer", and the same page can be 100 % for one query and 40 % for
another. The assistant server and `search --json` return the same number
(`relevance_pct`), from one shared computation, on the fused score in hybrid mode
so that a page found by meaning alone has one too. When the quorum has widened a
search, the pages that contain every word stay at the top of the list even if
another scores higher.

In the app, each result line shows:

- the snippet, with one colour per term of the query;
- the page number;
- an origin icon: typed text, read by Fouine from a scan, recognised before
  Fouine, or a sound wave for a page transcribed from a recording;
- the `≈1` / `≈2` badge if the result came from a fuzzy variant.

The preview on the right is a real PDF view positioned on the page found. On a
typed page, PDFKit selects the occurrences; on a scanned page, the boxes recorded
during recognition are drawn as highlights. Comic archives, `docx`, `pptx` and
`xlsx` are rendered as images.

Highlighting marks whole words, at the same boundaries as the tokenizer
(anything that is neither letter nor digit, the apostrophe included), so "or"
gets no colour inside "sort". A prefix (`spectro*`) covers the word to its end,
which is what it means.

Every other format (`txt`, `md`, `html`, `epub`, `rtf`, `djvu`…) shows the
indexed text of the page, terms highlighted in the same colours, selectable and
copyable, with arrows to move through the pages of the document that carry text.
That text comes from the database rather than from the file, so the preview
works when the volume is unplugged or the permission refused. "Preview not
available for this format" appears only when the database has nothing for that
page, typically a scanned page still waiting to be read.

### Why this result

Under the snippet of the selected result, and only that one, a grey line gives
the reason the page is there:

| What happened | What the line says |
|---|---|
| all your words are on the page | "Found because this page contains “kinetics” and “chemistry”." |
| only some of them | "Found because this page contains “energy”; “free” is not on it." |
| a close spelling | "Found with a close spelling: “converslon” → “conversion”." |
| none of your words, meaning alone | "None of your words is on this page, but it deals with the same subject." |
| both channels | "Found by your words and by meaning." |

The line shows no number: neither the distance of the variant nor the margin in
standard deviations. Most people do not read standard deviations, and "≈2" says
no more than "a close spelling"; the tooltips of the `≈` badge keep the figures
for anyone who wants them. The words quoted are yours, inside the quotation
marks of your language, and an excluded term is never named, since that would
show exactly what you asked to leave out.

A line on every result would make a wall of text, so the sentence is computed
when you select a result, on the indexed text of the page, off the main thread,
and it disappears before the next one is read. VoiceOver reads it in the line's
value, with the snippet.

The app is the only surface that reads the whole page, so it is the only one
that can say a word is not on it. `fouine search --json` and the assistant server
publish the same verdict in a `why` object, computed on the snippet: see
[the command line](cli.md) and [the assistant server](mcp.md).

**Search inside this document…** restricts the query to the current document
(`--in <doc_id>` on the command line).

The **Sort by** menu (relevance, modification date, name, path) reorders the
documents found, and the choice is remembered. How much of the result set a sort
covers is described in [the guide](app.md#sorting).

**File ▸ Export the results…** (⇧⌘E) writes the loaded results as CSV, JSON or
Markdown. The panel states how many lines will be exported, out of what total.

The global shortcut ⌥⌘F brings the cursor back to the search field from any app.
It needs no accessibility permission, and if the system refuses it, the app works
without it.

---

## 7. The bench, in numbers

None of the settings above (a floor, a weight, a depth) can be decided without
human judgements. The tooling lives in
[`Tools/ranking/`](../Tools/ranking/README.md). `pool.py` runs a set of queries
against several configurations and pools the results into a sheet to annotate.
`annotate.py` collects the ratings at the terminal (one keystroke per page, with
the text of the page in front of you). `evaluate.py` computes nDCG@10, P@10 and
MRR, per page and per document, with a paired test against a reference system
that says whether a difference holds. Count two to three hours of annotation,
starting with the queries the configurations rank differently.

The bench has 42 queries (exact terms, phrases, prefixes, paraphrases,
multi-word questions, OCR typos, and five deliberately absurd ones), rated 0
(irrelevant), 1 (useful) or 2 (what I needed). There were 790 judgements on
09/09/2026, and 963 after the 149 new candidates raised by the quorum and the
contents-page demotion were read on 11/09/2026. **A candidate nobody has judged
counts as 0**, which is why a new ranking has to be pooled and judged again
before its figures can be trusted.

### Hybrid against full text (09/09/2026, 790 judgements)

| | queries | full text | hybrid | difference |
|---|---:|---:|---:|---:|
| full text returned **ten** results | 32 | **0.693** | 0.656 | **−0.037** (13 gains, 18 losses) |
| it returned **fewer than ten**, absurd aside | 5 | 0.104 | **0.603** | **+0.499** |
| the five **absurd** queries | 5 | 0.000 | 0.126 | +0.126 (noise) |

Page by page, hybrid search brings in 236 pages (123 of them rated 0) and pushes
out 147 (42 of them rated 2): 99 more off-topic pages than it removes, for 17
more pages rated "what I needed". That is why meaning is off by default. Since
these figures were measured, the fuzzy fallback has made full-text search answer
more often, and the five queries that carried the whole gain are exactly those
where the lexical channel returned nothing. The comparison therefore has to be
run again on a newer pool.

### Putting semantic ranks back on the corpus scale

| | nDCG@10 | per document | MRR | exact phrases | single terms | paraphrases | multi-word |
|---|---:|---:|---:|---:|---:|---:|---:|
| `hybrid` (scaled, shipped) | **0.587** | **0.624** | **0.779** | **0.574** | **0.585** | 0.489 | 0.726 |
| `hybrid-raw` (no scaling) | 0.560 | 0.593 | 0.689 | 0.441 | 0.503 | **0.507** | **0.744** |

The scaling helps, and helps most where full text was already enough, which is
what it is for. One nuance: `hybrid-raw` is better on paraphrases and on
multi-word questions. The shipped setting is defensible, not dominant.
`--raw-semantic-ranks` gives the other one back.

### A margin floor cuts the wrong queries

A +4 σ floor changes 6 queries out of 42 for a net −0.008, and on the one query
where meaning really helped, it truncated the list and cut the two pages that
answered. Twelve control queries explain why: an out-of-domain query is far from
everything, so its best neighbour stands out by +4.5 to +7.7 σ, while a relevant
query is close to the whole corpus and its best neighbour exceeds the mean by
only +3.9 to +4.7 σ. The mechanism stays (`--vec-floor`, 0 by default,
disarmed) until a statistic separates the two.

### The two ranking rules, judged then armed (11/09/2026)

| Rule | nDCG@10 | per document | won / equal / lost | p |
|---|---:|---:|---:|---:|
| quorum | **+0.031** | +0.032 | 6 / 43 / 0 | 0.040 |
| contents pages moved down | **+0.021** | +0.014 | 13 / 33 / 3 | 0.019 |
| both together | **+0.052** | n/a | n/a | < 0.001 |

The quorum never pushes down a page already found: it adds pages underneath, and
what it adds is mostly *useful* (rated 1) rather than *the answer*. That is a
recall gain, and ten mediocre results including one good one beat an empty page.
The demotion pays off most on prefix queries, +0.101, the clearest case being
`polymer*` at 0.312 → 0.806: six contents pages and two indexes leave the top
ten, and the four pages about the subject move up. Its one real loss is
`chromato*` (−0.103): the IUPAC Compendium glossary, with short entries,
cross-references and trailing page numbers, has the shape of an index.

Also measured on 11/09/2026: on prefix queries, hybrid search is well below
lexical search (0.441 against 0.618) because bibliography pages attract the
semantic channel. They concentrate the vocabulary of a field without saying
anything about it (for `chromato*`, the first four ranks are reference lists
where "J. Chromatogr." recurs). A demotion for reference pages, of the same kind
as the one for contents pages, has not been evaluated yet.
