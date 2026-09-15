# Searching

The syntax is **the same in the app and on the command line**. FTS5 syntax is
never required.

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
| `spectro*` | prefix, **at least 4 letters** before the `*` |
| `-biology` | exclusion, **whole document**: any document where the word appears is dropped |
| `near:5 nitrogen reduction` | the words within 5 words of each other |
| `folder:Thesis enthalpy` | restrict to one folder, by its label |
| `folder:"My courses" enthalpy` | the same when the label contains a space |
| `ext:pdf` | restrict to one extension |
| `name:report` | documents whose **name** carries "report" |
| `text:report` | "report" in the **pages** only; the file name does not count |
| `path:Offers` | the whole **path** contains this, folders included |
| `-ext:md` | exclude an extension |
| `-folder:Courses` | exclude a folder |
| `-name:draft` | exclude documents whose **name** matches |
| `-path:Archive` | exclude documents whose **path** contains this |
| `1512,50` | an amount: both spellings, with and without the thousands separator |

**The six filters**, each with a French alias, because the app speaks both:

| Filter | Alias | Example | What it does |
|---|---|---|---|
| `folder:` | `dossier:` | `folder:"My courses" enthalpy` | one folder, by its label |
| `ext:` | — | `ext:pdf nitrogen` | one extension |
| `near:` | `pres:` | `near:5 nitrogen reduction` | the words that follow, within 5 words |
| `name:` | `nom:` | `name:"analysis JB"` | the file name and its parent folder name **only** |
| `text:` | `texte:` | `text:report nitrogen` | an ordinary page word; the file name stops counting |
| `path:` | `chemin:` | `path:Offers nitrogen` | the whole path of the document |

**Four of them also exist in the negative**: `-folder:`, `-ext:`, `-name:` and
`-path:`, with the same aliases and the same quoting rules
(`-folder:"My courses"`). They drop whole documents, like `-word` does. Until
13/09/2026 they were **accepted and did nothing**: the leading `-` fell into the
word-exclusion branch and produced a search for the string "ext:md", which no
page carries — the filter removed nothing and the results looked right. A filter
that lies is worse than a filter that is missing.

**Those four are exactly the ones that pick documents, and the other two have
no negative.** Proximity is not a set of documents, and the negative of
`text:word` is `-word`. Writing `-near:5` or `-text:report` is refused (**64**)
naming the four that can be excluded — and so is any other `-word:value`,
under the same rule as its positive form. Until 14/09/2026, `-type:pdf` was
accepted and excluded the *phrase* "type pdf": it did not drop the PDFs that
were asked for, and could drop a document carrying those two words in a row.
That was the last silent exclusion left.

**`path:` searches the whole path, `name:` does not.** The table of document
names holds the file name and the name of the folder holding it, and nothing
more: on a real index, `name:Offers` returned 6 documents where 178 are filed
under `Internship/Offers/…`, because most of them sit one folder deeper. `path:`
matches anywhere in the path, ignoring case **and** accents, so
`path:polymeres` finds `Books/Polymères/`. Several `path:` are all required,
and `path:` alone lists the matching documents, exactly like `name:` alone.

**Accents may be typed or pasted.** A path copied from the Finder or from `ls`
carries its accents in the *decomposed* form; what you type carries them
composed. They look identical and were not equal: `--path-contains "Polymères"`
returned 225 documents typed and 0 pasted. Fouine now recomposes what it
receives, in the query language and in `fouine list` alike.

These prefixes belong to the **query language**: you type them, they are not
translated, and they are the same whatever language the app is in.

**`name:` searches names, not pages.** It queries the table of document names
(the file name without its extension, then the name of the folder holding it)
with the singular and plural forms of the word, so `name:report` finds
"Reports.docx". A quoted value is a phrase, and since the tokenizer cuts on `_`
and `-`, `name:"analysis JB"` finds `IP2022__Analysis_JB_DELIVERABLE`. Several
`name:` terms are all required.

- **On its own** (possibly with `folder:`, `ext:`, `-word` or the app's
  filters), it returns **the documents themselves**: one line per document,
  opened at its first page carrying text, the snippet is the file name, the
  totals count documents, and the order is name relevance then most recent. The
  name banner does not appear, since it would repeat the list. Meaning has
  nothing to encode, so the search stays lexical.
- **With words** (`name:report nitrogen`), it restricts the documents the words
  are searched in: the pages carrying "nitrogen" among the documents whose name
  carries "report". In hybrid mode, meaning is restricted to the same
  documents.

**`text:` switches the file name off.** Searching a word in the body used to
push forward the files that also carry it in their name, and to show the name
banner. `text:report` is an ordinary page word, same pages, same totals, same
text sent to meaning, but the presence of **at least one** `text:` removes the
name bonus and the banner for the whole query. `text:"ideal gas"` is an exact
phrase.

**Curly quotes count as straight quotes.** macOS replaces typed quotes with
typographic ones by default, so `“ideal gas”` and `« catalysis »` used to be
words flanked by invisible characters rather than exact phrases. `“ ” „ ‟ « » ″`
become `"` before any parsing, the curly apostrophe `’` becomes `'`, and the
French spaces inside the quotes are trimmed. Nothing else is normalised.

**A filter that does not exist is named, not searched.** `type:pdf` and
`in:Books` used to be searched as words, which means they returned nothing in
silence. Fouine now answers by naming the filters: exit **64** on the command
line, a tool error in the assistant server, a line under the field in the app.

```
$ fouine search 'type:pdf nitrogen' ; echo $?
Error: “type:” is not a filter — filters are dossier:/folder:, ext:, pres:/near:, nom:/name:, texte:/body:, chemin:/path:
64
```

The rule is narrow, so as to break nothing people actually type: it takes at
least **two letters** before the colon and a non-empty value that does not start
with `/`. A URL (`https://example.org`), a time (`10:30`), a one-letter notation
(`a:b`) and anything in quotes (`"Chapter:3"`) stay ordinary search terms. The
same rule applies to `-type:pdf`, with the same message: the leading `-` does
not change what the word is.

On the command line, a query that **starts** with a `-` has to come after `--`
(`fouine search -- '-ext:md nitrogen'`): the argument parser reads it as an
option before Fouine ever sees the string. The refusal prints that form.

**A folder label that does not exist is named too.** `folder:Cour` used to
filter on an unknown label and return nothing, indistinguishable from a corpus
that does not hold the term:

```
$ fouine search 'folder:Cour enthalpy' ; echo $?
Error: unknown folder “Cour” — yours are: Books, M2SU
64
```

Case is the only tolerated difference: `folder:books` does filter on "Books". A
missing accent is refused, because filtering on a folder you did not name is
worth less than a refusal that says what to type. While no folder is
registered, nothing is refused: there is nothing to contradict.

A folder's label is, by default, the last segment of its path, so "My courses"
or "Course notes" carry a space. The label then goes **in quotes, after the
colon**: `folder:"My courses"`. Without them, `folder:My courses` searches for
"courses" in the text and filters on a folder called "My". The app's Folders
facet never needs this syntax: it passes the label as it is.

**There is no `OR` and no explicit `AND`**: positive terms are always combined
with AND. An empty query, a prefix that is too short and an exclusion on its
own are refused with a message that says what to do, and, on the command line,
with **exit 64**: an argument error rather than a breakdown.

```
$ fouine search 'chr*'
Error: prefix too short, give at least 4 letters
```

**`AND`, `OR` and `NOT` in capitals are refused the same way**, and case
matters. They are FTS5 keywords, and letting them through produced a dump of
SQL and an exit code that meant "database corrupted" for what was a typo.

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

The exclusion covers the **whole document** rather than the page: `enthalpy
-biology` drops every document where "biology" appears anywhere, even a hundred
pages from the hit. That is what one expects from a thematic filter.

Accents are ignored at indexing and at search time: `polymere` and `polymère`
are the same query.

**A word stands for its plural.** A word typed in the singular also finds the
plural, and the other way round: `polymere` finds "polymères", `liaisons` finds
"liaison", `metal` finds "métaux". This is grammar applied to the query rather
than fuzzy matching. Short words are protected: under five letters, a word
ending in -s keeps its s (`mois`, `fois`, `pays`, `sens`, `bras`), and a short
list protects `temps`, `corps`, `cours`, `fonds`. The price is that at four
letters `lois` does not find `loi`: type the singular. A quoted phrase, a `*`
prefix, the words of a `near:` and a `--raw-fts` string are never inflected.
In a bilingual library, a French word whose plural is a common English word
raises the total, and the **Languages** facet separates them. `fouine search
'<query>' --no-morphology` gives the earlier behaviour.

**An amount is found in both its spellings.** French documents write
"1 512,50 €" with a narrow no-break space, which the tokenizer cuts into two
tokens. A number with a decimal and at least four digits before the comma is
therefore searched under both forms. There is no variant for a three-digit
number or a year: `2003` would become `"2 003"`, and the year is the most typed
number of all.

For the cases the simple syntax does not cover, `--raw-fts` passes the string
straight to FTS5:

```sh
fouine search 'NEAR(nitrogen reduction, 3)' --raw-fts
fouine search 'chemistry NOT organic' --raw-fts
```

Pagination on the command line is `--limit N` (50 by default) and `--offset N`;
JSON output carries `offset` and the boolean `has_more`.

**Why four letters before a `*`?** There is no prefix index in the database:
`prefix='2 3'` was removed because it cost 480 MB. A short prefix therefore
sweeps a disproportionate share of the vocabulary.

---

## 2. What moves a page up

Six rules change the **order** of the results. None of them changes which pages
are found: the announced totals, the facets and the pages themselves are the
same with them and without them. Each has a command-line flag that disarms it,
for calibration.

| Rule | What it does | Flag |
|---|---|---|
| Exact phrase | on `free energy`, the page carrying the two words in a row goes ahead of the one that has them thirty words apart | `--no-proximity` |
| Nearby words | within about a dozen words of each other, the page moves up as well, a little less | `--no-proximity` |
| Name of the file or folder | from two words on, the pages of a "Polymers.pdf" (or of anything filed under a "Polymers" folder) go ahead of an isolated mention in an unrelated book. On a single word, nothing moves: one book would fill the screen | `--no-proximity` |
| The form you typed | a page carrying the word exactly as you typed it goes ahead of one carrying only an inflected form. Both stay findable | `--no-typed-form` |
| One document does not take the whole screen | the **three best pages** of each document compete at full strength, and the following ones count for half. They do not disappear, they come after the other documents. Measured on the reference corpus, this takes a screen from 5.5 to 6.4 distinct documents | `--no-diversity` |
| Tables of contents move down | the text of the first fifty results is read again, and the ones that are contents pages, indexes or keyword lists go behind the others. Nothing is removed | `--no-demote-toc` |

Fouine does not interfere when you have already said what you want: a quoted
phrase, a `near:`, a `spectro*` prefix keep the ranking you asked for.

A page is judged to be a contents page when **two of three signs** are present:
at least 30 % of its non-empty lines end in a page number, at least 5 % of its
characters are leader dots or tabs, or its shape is a list (40 % of lines under
six words, or very few distinct words per word). The verdict is read on the
**whole page**, never on the snippet. Known limitation: a glossary with short
entries, cross-references and trailing page numbers has the shape of an index,
and gets moved down.

**When few pages carry all your words.** Fouine requires **every** word on the
**same page**, function words included, and that costs recall: `how to measure
the heat released by a reaction` returns 0 pages where `the heat released by a
reaction` returns 10, and the difference is "how" and "measure" rather than
meaning. So when the strict search returns fewer than **ten** pages and the
query has at least three bare words, Fouine replays it requiring only **60 % of
the words longer than three letters**. Pages carrying everything keep the lead;
the others follow, ranked as usual, and a line says so: *"Few pages carry all
your words: here are also the pages that carry most of them."*

Words that carry no meaning are never required, whatever their length: about
eighty French and English function words ("dans", "avec", "pour", "cette",
"with", "that", "which"…) are left out of the count, on top of the three-letter
rule. And a question with more than six meaningful words keeps the **six
longest** rather than giving up: a question asked in plain language often has
seven or eight, and that is exactly where the strict AND fails.

What stays strict: a quoted phrase, a `near:`, a `*` prefix, a `-word`
exclusion, a `name:` filter and a query restricted to one origin. You said what
you wanted, and Fouine does not loosen it. **A folder, an extension, a language
or a date no longer disarm it** — until 13/09/2026 they did, and the same
question returned 28 pages on its own and **zero** under `folder:Books`, which
is precisely the shape an assistant types. A filter narrows the corpus; it says
nothing about how many words a page must carry. Nothing changes at all, not even
one extra query, when the strict search returns ten pages or more. There is no
setting in the app; `--no-quorum` disarms it.

**Meaning does not disarm it either**, since 14/09/2026: the merge runs the same
lexical channel, so it was loosening the AND without saying so, while the
assistant server armed it and announced it. `fouine search --hybrid` now says it
like a full-text search does — `quorum: true` in JSON, the same line on standard
error — and `--no-quorum` still covers both modes. The judgement behind the
quorum was made on full-text results (see the bench below); in hybrid mode it is
due again on a fully vectorised corpus, which is why this convention is
reversible.

A result that comes from the loosened pass no longer claims to be exact: its
"why this result" says *partial* and lists the words the excerpt shows, without
concluding that the others are missing — an excerpt proves no absence.

**How these were judged.** A bench of 42 queries and 963 human relevance
judgements settles which of these rules earn their place. The quorum gains
0.031 nDCG@10 with no query made worse. The contents-page demotion gains 0.021,
and 0.101 on prefix queries. Diversity costs 0.010 on pages and gains 0.065 on
documents, which is the number the app shows. Morphology is the clearest win of
full-text search, 0.744 against 0.703. The typed-form rule is inside the noise,
and is kept for being defensible rather than measured. Every figure, its paired
test and the reservations that go with it: "the bench, in numbers", at the end
of this page.

---

## 3. Typing mistakes

Fuzzy matching is not a second search: it is an **expansion of terms**. For each
substitutable word, Fouine queries the vocabulary and filters the candidates by
a bounded edit distance.

- **under 6 letters: no expansion.** Short words are too close to one another;
  `gibbs` and `mayer` stay exact.
- **6 letters and more**: at most 12 variants kept, and the tolerated distance
  depends on where Fouine widens. On **scanned pages** it stays 2: "rn" read as
  "m" costs two edits on a short word, and those are the machine's mistakes.
  Over **every document** — the fallback, and `--fuzzy-scope all` — two edits on
  a six-letter word change the word: `Kenvue` used to return 125 pages carrying
  "kenne", "kene", "cevue". The ceiling there is **1 from 6 to 8 letters, 2 from
  9**, where two edits are still a plausible typo (`Villeurbane` →
  "Villeurbanne", 11 letters, one edit, unchanged).
- **exact first**: at equal relevance the exact match wins, but a dense and
  relevant fuzzy variant beats a weak exact page.
- **no duplicates**: each page appears once, on its best score.

A result found through a variant carries the `≈1` (or `≈2`) badge in the app,
and the `fuzzy_distance` field in JSON.

**Three modes** (`--fuzzy`, or the sidebar selector):

| Mode | Behaviour |
|---|---|
| `off` | no expansion |
| `auto` *(default)* | expansion only when the exact query returns fewer than 20 pages |
| `on` | expansion always |

**Two scopes** (`--fuzzy-scope`):

| Scope | Behaviour |
|---|---|
| `ocr` *(default)* | widens only pages read from scans, where machine mistakes come from |
| `all` | the whole index |

**When a search returns nothing, Fouine replays it once** tolerating mistakes
across **every document**, and says so: `No exact match — showing close
spellings from every document.` on the command line (`fuzzy_fallback: true` in
JSON), "No exact match: here are the closest spellings, in every document."
under the field in the app, the same sentence in the assistant server's `note`.

Four conditions, all necessary: the query matched **no** page at all, it has at
least one parsed word (`--raw-fts` has none), mistakes are not refused
(`--fuzzy off`), and the query was not already this fallback. It costs nothing
on the normal path: no extra query as soon as there is one result. Measured on a
copy of a real 2.15 GB index, the fallback adds about 4 ms, and only when the
first pass found nothing.

**Widening also happens without any fallback**, and now says so. In `auto`
mode — the default — Fouine widens as soon as the exact query matches fewer
than 20 pages, inside the ordinary pass: `Kenvue` returned eleven pages, all of
them carrying a near spelling, with `fuzzy_fallback: false` and no note at all.
The JSON now carries `fuzzy_expanded: true` whenever a result shown carries a
close spelling, and the command line says *"some results carry a close spelling
of your word, not the word itself — see why.found"*.

Results from a fallback all carry a distance, so they are **close** spellings
rather than the words you asked for. In hybrid mode the fallback applies to the
lexical channel and the flag travels through the merge, so all three surfaces
say the same thing in both modes.

---

## 4. Search by meaning

Besides exact and fuzzy matching, Fouine can search **by meaning**: "catalyst
selectivity" finds a page about *regioselectivity* that shares not one word with
it.

Each page is cut into **windows** of 1 400 characters, and each window is
summarised as a 384-dimension vector by a **local** multilingual model
(`multilingual-e5-small`, converted to CoreML, nothing leaves the machine),
quantised to 384 bytes. A `--hybrid` query then merges two rankings by RRF
(reciprocal rank fusion): the usual FTS5 lexical ranking, and the pages closest
to the query's vector. The `folder:`, `ext:` and exclusion filters apply to
**both** channels, and a purely semantic result is marked as such.

A page carries up to **three** windows, at characters `[0, 1400)`, `[1300,
2700)` and `[2600, 4000)`, with 100 characters of overlap so that no sentence is
cut in both windows at once. On the reference corpus this covers 97.4 % of the
text for 2.13 inferences per page; beyond 4 000 characters (4.9 % of pages) the
rest is not vectorised. A page never takes three places in the ranking: the
index folds its windows back onto the page and keeps the best one.

**In the app, words come first and meaning second.** Fouine runs the lexical
channel alone, shows its results, then launches the merge. In between, the count
line carries a spinner and the phrase "searching by meaning…", and "Load more"
is refused. When the merge arrives, **it replaces the list**: RRF re-ranks, that
is the point. The lexical channel therefore runs twice, once for the immediate
display and once inside the merge: one more FTS5 query, a few milliseconds,
against several seconds in front of an empty screen. The command line and the
assistant server do not change, having nothing to show in between.

**A quoted phrase does not consult meaning.** The semantic channel has no
quotes: it compares vectors, and a page about the same subject entered the
ranking without carrying the phrase asked for, four results out of ten on the
bench's exact-phrase queries. `"ideal gas"` therefore returns exactly what
full-text search returns, and each surface says so: `meaning search not used:
the query asks for an exact phrase` on the command line, with `hybrid: false`
and `hybrid_disarmed: "exact_phrase"` in JSON; "Meaning is not used when you ask
for an exact phrase." under the field in the app, where the switch stays where
it is.

**Semantic ranks are put back on the scale of the corpus.** Until a `fouine
embed` campaign has vectorised everything, the semantic channel compares only
part of the pages. A page ranked first among a sixth of the corpus is not first
among all of them, so the merge multiplies its rank by `indexed pages /
vectors` before combining. The scale is 1 once everything is vectorised.
`--raw-semantic-ranks` disarms it, and the JSON publishes
`semantic_rank_scale`. Judged on the bench, the scale helps: 0.587 nDCG@10
against 0.560 without it, and it helps most where full-text search was already
enough, which is exactly its job.

### What hybrid search is worth

Judged on 42 queries and 790 relevance ratings, against full-text search:

| | queries | full text | hybrid | difference |
|---|---:|---:|---:|---:|
| full text returned **ten** results | 32 | **0.693** | 0.656 | **−0.037** |
| it returned **fewer than ten**, absurd queries aside | 5 | 0.104 | **0.603** | **+0.499** |
| the five **absurd** queries | 5 | 0.000 | 0.126 | +0.126 (noise) |

The overall gain of hybrid search is carried by five queries, the ones where
full-text search returned nothing or almost nothing. **Everywhere else it makes
things worse.** Of the 420 results hybrid search returned, the 72 that carry no
word of the query are rated irrelevant 93 % of the time, and **none** of them is
rated "what I needed": the pure vocabulary bridge, a page that answers without
sharing a word, does not exist in that corpus.

**That is why "Also search by meaning" is off by default**, and why `--hybrid`
is explicit on the command line. The semantic channel is at its most dangerous
where full-text search is at its safest: on a technical term outside the small
model's vocabulary, it offers pages about a similarly spelled subject.

### What the cosine does not say

A semantic result is shown with a **margin**, not with a cosine:

```
• [318] …/Wade.pdf p.261 — rrf 0.0164 · sem#1 z+4.7
```

`z+4.7` reads as: *this page is 4.7 standard deviations above the average page
of the corpus, for this query*. The raw cosine stays in the JSON (`cosine`) and
is shown nowhere, and that is a correction rather than a matter of taste.
Measured on 64 872 vectors, **every** cosine of this model lives between 0.78
and 0.88, and the position inside that band follows the *shape* of the query
more than its subject. A "cos 0.85" badge reads as "85 % relevant". It does not
mean that.

Every search publishes the moments of its own population in the JSON
(`semantic_stats`: `mu`, `sigma`, `cos_max`, `z_max`, `z_at_10`, `z_at_200`,
`scanned`, `zero_vectors`), which is the instrument for calibrating without
guessing.

> **There is no threshold, and that is a measurement result.** The natural idea
> is to keep a semantic result only above a margin. Twelve control queries, six
> out of domain and six relevant, were replayed on a real index: the margin
> **separates them backwards**. An out-of-domain query is far from everything,
> so its mean is low and its best neighbour stands out by +4.5 to +7.7 σ; a
> relevant query is close to the whole corpus, so the mean is high and its best
> neighbour exceeds it by only +3.9 to +4.7 σ. A floor would cut first into the
> queries the channel serves best. The mechanism exists (`--vec-floor <z>`, 0 by
> default, disarmed) and waits for a statistic that separates. Judged on the
> bench, a +4 σ floor changes six queries out of 42 for a net −0.008, and on the
> one query where the semantic channel really helped it truncated the list and
> cut precisely the two pages that answered.

> **So Fouine says it instead of filtering.** The next idea was to drop
> "hallucinated" results on the raw cosine: above 0.82 with no lexical anchor,
> hide them. The measurements say no. The five absurd queries spread from 0.7975
> to 0.8517, and perfectly relevant queries fall in the same band. A threshold
> at 0.82 would kill one and let three absurd ones through. What does hold: the
> five absurd queries have **no** lexical page, though two legitimate paraphrases
> have none either. So it is a sentence rather than a filter: when the full-text
> channel found nothing and results come out anyway, the app says "None of your
> words appears in your documents: these results are suggested by meaning only",
> and the command line and the assistant server say the same in `note`. You
> judge; nothing is hidden.
>
> **Two sentences, not one.** "No lexical page" means "no page carries them
> **all**", which is not "none of your words exists". A nine-word question
> restricted to one folder was told its words were nowhere, while one of them
> was in 22 documents of that very folder — the surest way to conclude that a
> library is mute and stop looking. Fouine now checks which of the typed words
> the index actually carries, and says "Your words are in your documents, but
> never together on the same page" instead; the command line and the assistant
> server name them: `(words present: reactor, residence)`. The old sentence is
> kept for the case it describes, where nothing you typed exists at all.

### Coverage

The `fouine embed` campaign is incremental, so the semantic channel often sees
only **part** of the corpus. Search says so, because a hybrid result does not
read the same drawn from 16 % of the pages as from all of them:

```
$ fouine search 'catalysis' --hybrid
fouine: warning — semantic channel covers 16.6 % of the pages (64872 / 390114) — hybrid results are drawn from that subset; `fouine embed` extends it
```

The warning appears only under 50 % coverage. The JSON carries the same numbers
(`vectors`, `pages_indexed`, `semantic_coverage_pct`), and the app shows
"· meaning search sees only 17 % of the pages" next to its counts.

**Coverage follows the filter.** A campaign fills the index in the order it
discovered documents, so one folder can be fully vectorised while another has
nothing at all — measured on a real index: 73 % on one root, **0 %** on a second.
A global percentage then describes the corpus and not the search, and a hybrid
search restricted to the second folder compared **no vector at all** while
announcing 68 % coverage. The assistant server (`fouine_search`) and the command
line (`fouine search --hybrid`, `--hybrid-auto`) therefore compute coverage
**for the scope actually searched** (`semantic_scope`: pages in scope, of which
vectorised, and whether a filter narrowed it), and a scope without a single
vector does not even load the model: the answer comes back full-text, saying so
and naming the command that would prepare that folder.
The cost of the count is a few milliseconds, and nothing at all when no document
filter applies.

### Getting started

Install the model once:

```sh
fouine model download
```

220 MB, downloaded **on demand** from the project's releases page and checked
against its SHA-256 before installation. The command says what it will contact
before it goes. `fouine model status` says what is installed, `fouine model
remove` deletes it. See [privacy](privacy.md).

**From the app** it is the same work without a terminal: ⌘, ▸ **Search by
meaning** ▸ "Download the model (220 MB)…". A sheet first announces what will be
contacted, what will be sent and what will be checked; nothing moves until you
click Download.

> **Machine offline?** Copy the `e5-small-v1.zip` archive from another machine,
> then run
> `FOUINE_MODEL_URL=file:///Volumes/USB/e5-small-v1.zip fouine model download`.
> No connection is opened.

Then produce the vectors, as many times as needed, since the campaign is
incremental and resumable:

```sh
fouine embed                    # until done; Ctrl-C stops cleanly
fouine embed --budget-minutes 60
fouine embed --status           # vector coverage
fouine search 'catalysis' --hybrid
```

The background agent does this by itself, ten minutes at a time, when the Mac
is plugged in and idle ([the agent](agent.md)). Vectors follow the life of the
index: a page that is extracted or recognised again is vectorised again at the
next `embed` pass.

### Limits worth knowing

- **The model weighs 220 MB and is downloaded.** It is not bundled: half its
  weight would be paid by everyone, including people who will never run a
  semantic search.
- **The scan is exhaustive**, with no vector index. That is fast at the measured
  scale (about 6 ms over 363 058 vectors), but it is linear: on a corpus ten
  times larger it will show.
- **The window is the unit vectorised, the page is the unit shown.** Beyond
  4 000 characters the rest of the page is not vectorised at all, and a
  thematically varied page is poorly served inside a window: the cut is
  mechanical, following neither paragraphs nor sections.
- **The semantic channel cannot keep quiet.** It always returns its best pages,
  even when the query has nothing to do with the corpus. The lexical channel
  returns a frank zero, which is a quality worth keeping: in hybrid mode,
  `lexical: 0 page(s)` in the header means everything that follows comes from
  vector proximity alone.
- **Command line against resident server.** Hybrid search on the command line
  pays for loading the engine at **every** call; the assistant server and the
  app amortise it by keeping the model and the index in memory. Measured, that
  is about 1.1 s per call against 0.39 s for the second call in a server.

---

## 5. Filters

The app computes five facets and shows the first twelve values of each. **One of
them does not re-run the query, and its tooltip says so:**

| Facet | Behaviour |
|---|---|
| **Folders** | a real filtered query on the folder |
| **File types** | a real filtered query on the extension |
| **Languages** | a real filtered query on the document's language |
| **Text origin** | a real filtered query on the origin of the **page**: typed text, scanned and read by Fouine, recognised before Fouine, transcribed from the audio |
| **Dated** | the year the document itself carries, when it carries one |
| **Modified in** | filters the results **already loaded** |

"Text origin" is the only one that bears on the **page** rather than the
document: origins are stored per page, and one book can mix typed pages and
scanned plates. The three origins partition the pages: asking for one never
returns another.

The **Languages** facet appears only when the set found carries **at least
two**: a monolingual corpus has no choice to offer. Codes are shown under the
name the system gives them in your language, and documents whose language could
not be determined form the "language not determined" value.

**Dated** is the year written **in the document itself** (PDF, Word, EPUB,
email, photo), as opposed to **Modified in**, which counts the last modification
of the FILE. A book from 2003 copied onto the Mac in 2024 falls under 2024 in
one and 2003 in the other. The date is read when the document is indexed, and
only then: a document already indexed that carries none will not gain one
without being indexed again.

On the command line, `--facet doc_year|modified_year|folder|ext|source|lang`
adds the counts to the result (and to the `facets` key of the JSON); `--lang fr`
(repeatable, `und` for undetermined), `--since YYYY-MM-DD` and `--source
native|ocr|transcript` filter. The assistant server has `lang` and `source`.

`doc_year` comes first on purpose: it is the year the **document** carries, the
one a human means by "a book from 2003". `modified_year` is the year the FILE
was last modified, which on a real corpus piles most of the index onto the year
it was copied onto the Mac. That facet used to be called `year` — a name that
said nothing of the kind. `--facet year` is still accepted, so no existing
script breaks, but the key returned in `--json` is always `modified_year`.

### Quick filters

Above the facets, four chips cover the filters people ask for most often:

| Chip | What it does |
|---|---|
| **Modified this year** | a real query: documents modified since 1 January |
| **Modified in the last 5 years** | a real query: since 1 January four years ago |
| **PDF only** | a real query on the extension |
| **Scans only** | a real query on the origin of the page |

Date windows are calendar years, like the "Modified in" facet: "this year" means
"since 1 January" rather than "for the last twelve months". The two exclude each
other, and an active chip turns off with a click.

The chips are not an extra filter: they drive the **same** state as the facets.
Unticking "pdf" in File types turns off the "PDF only" chip, and "Clear all"
removes them all.

---

## 6. Reading a result

**The percentage in front of a line is relative.** `fouine search` prints
`100 %`, `86 %`, `81 %` — each result's score as a share of the best one **of
that answer**. It says nothing absolute: 100 % means "nothing here scores
higher", never "this is the answer", and the same page can be 100 % for one
query and 40 % for another. The assistant server and `search --json` return the
same number (`relevance_pct`) — one shared computation, not three copies of a
formula — computed on the fused score in hybrid mode so that a page found by
meaning alone carries one too. When the quorum has widened a search,
the pages carrying every word keep the head of the list even if another scores
higher.

In the app, each result line carries:

- the snippet, with **one colour per term of the query**;
- the page number;
- an **origin** icon: typed text, read by Fouine from a scan, recognised before
  Fouine, or a sound wave for a page transcribed from a recording;
- the `≈1` / `≈2` badge if the result came from a fuzzy variant.

The preview on the right is a real PDF view positioned on the page found. On a
typed page the occurrences are selected by PDFKit; on a scanned page, the boxes
recorded during recognition are drawn as highlights. Comic archives, `docx`,
`pptx` and `xlsx` are rendered as images.

Highlighting marks **whole words**, at the same boundaries as the tokenizer
(anything that is neither letter nor digit, the apostrophe included), so "or"
gets no colour inside "sort". A prefix (`spectro*`) does cover the word to its
end, which is what it means.

Every other format (`txt`, `md`, `html`, `epub`, `rtf`, `djvu`…) shows the
**indexed text of the page**, terms highlighted in the same colours, selectable
and copyable, with arrows to walk the pages of the document that carry text.
That text comes from the database rather than from the file, so the preview
works when the volume is unplugged or the permission refused. "Preview not
available for this format" is left only when the database has nothing for that
page, typically a scanned page still waiting to be read.

### Why this result

Under the snippet of the **selected** result, and under it alone, a quiet line
says why that page is there:

| What happened | What the line says |
|---|---|
| all your words are on the page | "Found because this page contains “kinetics” and “chemistry”." |
| only some of them | "Found because this page contains “energy”; “free” is not on it." |
| a close spelling | "Found with a close spelling: “converslon” → “conversion”." |
| none of your words, meaning alone | "None of your words is on this page, but it deals with the same subject." |
| both channels | "Found by your words and by meaning." |

**No number appears there**: not the distance of the variant, not the margin in
standard deviations. Fouine's readers do not know what a standard deviation is,
and "≈2" says nothing more than "a close spelling"; the tooltips of the `≈`
badge keep the figures for whoever wants them. The words quoted are **yours**,
inside the quotation marks of your language, and an excluded term is never
named: that would point at exactly what you asked to drop.

One line per result would have made a wall, so the sentence is computed **on
selection**, on the indexed text of the page, off the main thread, and it
disappears before the next read. VoiceOver reads it in the line's value, with
the snippet.

The app is the only surface that reads the whole page, so the only one that can
say a word is **not** on it. `fouine search --json` and the assistant server
publish the same verdict in a `why` object, computed on the snippet: see
[the command line](cli.md) and [the assistant server](mcp.md).

A **Search inside this document…** field restricts the query to the current
document (`--in <doc_id>` on the command line).

A **Sort by** menu (relevance, modification date, name, path) reorders the
documents found, and the choice is remembered. Sorting covers the results
**loaded**; the engine ranks by relevance, and that ranking is what decides which
slice comes back, which the interface says when pages are still to load.

**File ▸ Export the results…** (⇧⌘E) writes the loaded results as CSV, JSON or
Markdown. The panel says how many lines are leaving, and out of what total.

The global shortcut **⌥⌘F** brings the cursor back to the search field from any
app. It needs no accessibility permission, and if the system refuses it the app
carries on without it.

---

## 7. The bench, in numbers

Nothing above — a floor, a weight, a depth — can be settled without human
judgements. The tooling lives in
[`Tools/ranking/`](../Tools/ranking/README.md): `pool.py` runs a set of queries
against several configurations and pools the results into a sheet to annotate,
`annotate.py` collects the ratings at the terminal (one keystroke per page, the
text of the page under your eyes), and `evaluate.py` computes nDCG@10, P@10 and
MRR — per page and per document, with a paired test against a reference system
that says whether a difference holds. Count two to three hours of annotation,
starting with the queries the configurations rank differently.

**The bench**: 42 queries (exact terms, phrases, prefixes, paraphrases,
multi-word questions, OCR typos, and five deliberately absurd ones), rated 0
(irrelevant), 1 (useful) or 2 (what I needed). 790 judgements on 09/09/2026,
963 after the 149 new candidates that the quorum and the contents-page demotion
raised were read on 11/09/2026. **A candidate nobody has judged counts as 0**,
which is why a new ranking has to be re-pooled and re-judged before it is
believed.

### Hybrid against full text (09/09/2026, 790 judgements)

| | queries | full text | hybrid | difference |
|---|---:|---:|---:|---:|
| full text returned **ten** results | 32 | **0.693** | 0.656 | **−0.037** (13 gains, 18 losses) |
| it returned **fewer than ten**, absurd aside | 5 | 0.104 | **0.603** | **+0.499** |
| the five **absurd** queries | 5 | 0.000 | 0.126 | +0.126 (noise) |

Page by page, hybrid search brings in 236 pages (123 of them rated 0) and pushes
out 147 (42 of them rated 2): 99 more off-topic pages than it removes, for 17
more pages rated "what I needed". That is why meaning is **off by default**.
Since the fuzzy fallback (lot MP1), full text answers more often than it did
when these figures were measured — the five queries that carried the whole gain
are exactly those where the lexical channel returned nothing — so the
comparison is due again on a newer pool.

### Putting semantic ranks back on the corpus scale

| | nDCG@10 | per document | MRR | exact phrases | single terms | paraphrases | multi-word |
|---|---:|---:|---:|---:|---:|---:|---:|
| `hybrid` (scaled, shipped) | **0.587** | **0.624** | **0.779** | **0.574** | **0.585** | 0.489 | 0.726 |
| `hybrid-raw` (no scaling) | 0.560 | 0.593 | 0.689 | 0.441 | 0.503 | **0.507** | **0.744** |

The scaling helps, and helps most where full text was already enough, which is
its job. The nuance worth keeping: `hybrid-raw` is better on paraphrases and on
multi-word questions. The shipped setting is defensible; it is not dominant.
`--raw-semantic-ranks` gives the other one back.

### A margin floor cuts the wrong queries

A +4 σ floor changes 6 queries out of 42 for a net **−0.008**, and on the one
query where meaning really helped it truncated the list and cut precisely the
two pages that answered. Twelve control queries say why: an out-of-domain query
is far from everything, so its best neighbour stands out by +4.5 to +7.7 σ,
while a relevant query is close to the whole corpus and its best neighbour
exceeds the mean by only +3.9 to +4.7 σ. The mechanism stays (`--vec-floor`, 0
by default, disarmed) and waits for a statistic that separates.

### The two ranking rules, judged then armed (11/09/2026)

| Rule | nDCG@10 | per document | won / equal / lost | p |
|---|---:|---:|---:|---:|
| quorum | **+0.031** | +0.032 | 6 / 43 / 0 | 0.040 |
| contents pages moved down | **+0.021** | +0.014 | 13 / 33 / 3 | 0.019 |
| both together | **+0.052** | — | — | < 0.001 |

The quorum never pushes down a page already found: it adds underneath, and what
it adds is mostly *useful* (rated 1) rather than *the answer* — a recall gain,
and "ten mediocre results including one good one" beats an empty page. The
demotion pays off most on prefix queries, **+0.101**, the textbook case being
`polymer*` at 0.312 → 0.806: six contents pages and two indexes leave the top
ten and the four pages that treat the subject move ahead. Its one real loss is
`chromato*` (−0.103): the IUPAC Compendium glossary — short entries,
cross-references, trailing page numbers — has the shape of an index.

**Also found** (11/09/2026): on prefix queries, hybrid search is well below
lexical (0.441 against 0.618) because **bibliography pages** attract the
semantic channel — they concentrate the vocabulary of a field without saying
anything about it (`chromato*`: its first four ranks are reference lists where
"J. Chromatogr." recurs). A "reference page" demotion, of the same family as the
contents-page one, is still to be instructed.
