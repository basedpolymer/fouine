# The Fouine guide

Fouine is a local search app for macOS. It walks the folders you give it,
extracts the text of every document, and lets you find a page again by its words
or by its meaning. Nothing leaves your Mac.

- [1. The main window](#1-the-main-window)
- [2. The preview](#2-the-preview)
- [3. Taking results away](#3-taking-results-away)
- [4. The Index card](#4-the-index-card)
- [5. The Your index window](#5-the-your-index-window)
- [6. All your documents](#6-all-your-documents)
- [7. Keeping the index up to date](#7-keeping-the-index-up-to-date)
- [8. The menu bar](#8-the-menu-bar)
- [9. Search options and filters](#9-search-options-and-filters)
- [10. Citing a page](#10-citing-a-page)
- [11. Settings](#11-settings)
- [12. Fouine in Spotlight](#12-fouine-in-spotlight)
- [13. Fouine in Shortcuts and Siri](#13-fouine-in-shortcuts-and-siri)
- [14. Keyboard shortcuts](#14-keyboard-shortcuts)
- [15. The Help menu](#15-the-help-menu)

---

## 1. The main window

The window has three panes:

| Pane | What it holds |
|---|---|
| **Sidebar** (left) | the Index card, the switch that keeps the index up to date, your folders, search options and filters |
| **Results** (middle) | the documents found, each unfolding page by page with a snippet, your words highlighted, and where the text came from |
| **Preview** (right) | the selected document, opened at the right page, with the occurrences highlighted |

Until a folder has been added, the window shows a welcome screen inviting you to
name one. Its last line is for people who use an AI assistant: to use Fouine
with Claude, Codex, Antigravity or another one, ask the assistant to install
the Fouine MCP server. The **Copy the request for your assistant** button under
it puts the whole request on the clipboard, ready to paste into the assistant:
the command to run, with the real location of Fouine's command line inside the
app, what it configures (Claude Desktop, Claude Code, Cursor, Codex,
Antigravity) and its options, so the assistant needs nothing else. Fouine
waits until it has read the real state of your folders before showing the
interface, so nothing flickers.

**If you refuse the permission macOS asks for** when adding that first folder,
or if the file's own permissions forbid the read, the folder is not added and
Fouine says so. The alert then carries **two gestures** besides OK: **Open
System Settings**, which goes straight to Privacy & Security ▸ Files and
Folders, and **Retry**, which offers the folder chooser again. A folder that is
missing or empty gets neither button: there is nothing to allow.

The index opens **at launch**, whether the window shows or not, so a Fouine
started with your session and left without a window still answers in the menu
bar panel.

### Dropping a folder on Fouine's icon

A folder taken from the Finder and **dropped on Fouine's icon in the Dock** does
one of two things, depending on whether Fouine already knows it.

- **The folder is watched**, or lives inside a watched folder: the window comes
  forward and the search field receives the folder filter, ready to complete,
  with the cursor behind it. **Nothing is started**: what you are looking for in
  there is yours to know. The label used is that of the **watched folder**
  rather than of the subfolder you dropped, since the filter only knows the
  folders in your list.
- **Nobody watches that folder**: Fouine **asks**, "Search “Invoices” with
  Fouine?", "Fouine will index this folder and keep it up to date.", with **Add
  this folder** and **Cancel**. That is the difference with dropping onto the
  **folder list in the sidebar**, which adds without asking: there you aim at
  the list, which already says "add it", while on the Dock icon you aim at the
  app, and the same gesture could mean "search". Several folders dropped at once
  fit in one question. Once added, the folder follows the ordinary path: no
  reading starts on its own, it is **Update now** or automatic updates.

A **file** dropped on the icon does nothing, and says nothing: Fouine searches
folders, it does not open documents. It never appears in the "Open with" menu of
a folder either; the double-click stays with the Finder, and the Dock icon
accepts the drop, that is all.

### The search field

The field says **"Search your documents"**. The syntax (quotes for an exact
phrase, an asterisk for a prefix, a hyphen before a term to exclude it) is in its
tooltip and in its spoken help. Three ordinary mistakes used to find nothing
without a word; a line under the field now names them:

| What you typed | What appears |
|---|---|
| `"energy` | A quote is not closed. |
| `near:` (or `near:` followed by a single word) | `near:` expects two words. |
| `-energy` | A search that only excludes finds nothing. |

Nothing shows for a search that is simply fruitless: the line names a mistake of
form, never a reproach.

### When nothing is found

Under **"No result for “…”"**, Fouine offers the gestures that can still bring
something back in this state, and only those:

- **Tolerate typos**, if the setting is not already on "always";
- **Remove the filters**, if a filter, a facet or a scope is active;
- **Also search by meaning**, if the model is ready and the switch is off.

Then the sentence "Try fewer words, or check the spelling." Each gesture changes
the setting it names and runs the search again. Fouine never changes a rule on
its own. In this state, empty facet sections stay hidden: they would only push
those gestures out of sight.

### What you can do with a result

- **Right-click**: "Show in Finder", "Open" (in its usual app), "Search inside
  this document", and, only if pages of that document are waiting to be read,
  "Read its scanned pages first". Plus "Open the preview in its own window" and
  "Copy a reference to this page".
- **Drag** a line to Mail, a Finder folder or a bibliography app: it is the
  **file** that travels.
- **Space** on the selected line: macOS Quick Look, as in the Finder.
- **Double-click** or **⌘↩**: the page in its own preview window.

The toolbar buttons (sort, export, "Within results") and those of the preview
are not in the **Tab** cycle: that is normal macOS behaviour while System
Settings ▸ Keyboard ▸ "Full Keyboard Access" is off. With it on, Tab reaches
them all.

### The counts, and the list

Above the list, a line says what was found and how long it took ("29 037 pages
in 776 documents · 120 ms").

When **"Also search by meaning"** is on, the two searches no longer start
together: Fouine looks for the words, **shows those results**, then asks
meaning. During that second step the counts stay readable with a spinner beside
them and "searching by meaning…", or, on the very first try, "preparing the
meaning search: the first one takes a few seconds…". When meaning answers, the
list is **re-ranked**: the two searches are merged, the order changes, and pages
that carry none of the words you typed can appear. Until then, "Load more"
waits, since one more slice would arrive in a list about to be rebuilt. Typing
again cancels both searches.

Each document found carries, to the right of its name, the number of its pages
in the list. Fouine shows the **best pages of each document** first, so that a
single six-hundred-page book does not fill the screen: a book with three hundred
matching pages therefore shows only a few.

When that happens the count becomes a **gesture**: "3 of 300 pages · See them
all". A click restricts the search to that document and brings back every page
found in it, first to last. A chip "in “document name”" then appears under the
search field, and closing it gives the search back to all your folders. Under
that chip the count becomes a plain count again: there is nowhere else to go,
and further pages come with "Load more" at the bottom of the list.

The count stays **honest** in every case: while Fouine has not finished counting
the matching pages of the whole document, it says "pages loaded" and nothing
more; when everything is on screen it shows one number and offers no gesture.

**No percentage on the lines.** Fouine shows no "relevance: 47 %". The figure
that once existed compared a page's score with the best score of the slice
loaded, so it changed at every "Load more" and did not mean the same thing from
one search to the next. What remains, and is true: the **order** of the
documents, and the "Found because…" line under the selected result.

---

## 2. The preview

The right-hand pane shows the page found. Its header carries the **document's
name** and, under it, the **shortened** path, the same as in the results list.
The whole path is in the tooltip, on demand, and nowhere else.

**Four kinds of preview**, depending on what the document is:

| What you see | For which documents |
|---|---|
| The **page of the PDF**, with the words highlighted | `.pdf` |
| An **image of the page**, rendered from the file | comic archives, `.docx`, `.pptx`, `.xlsx`, images, Figma and InDesign files |
| The **document as macOS draws it** | `.rtf`, `.doc`, `.odt`, Pages, Numbers, Keynote, web pages, `.csv`, `.tsv`, `.svg`, `.ai`, old `.xls` and `.ppt` |
| The **text Fouine kept**, with your words picked out | everything else: EPUB, DjVu, notebooks, subtitles, mailboxes, text and code files |

Above the preview, a **Document | Text** selector switches between the two
whenever both exist. "Document" is what the Finder's space bar shows, the
layout, the pictures, the colours, but **your search words are not highlighted
there**: macOS draws that page, Fouine has no hand in it, and the selector's
tooltip says so. The last choice holds for every document **until Fouine
quits**; it is not stored in the settings, so the display does not change from
one month to the next without anything saying so.

That "Document" mode always **starts at the first page** for the documents macOS
draws (`.rtf`, `.doc`, `.odt`, Pages, web pages…): macOS owns the rendering,
and there is no way to ask it for a page. A **PDF** does open at the page found,
because Fouine draws it.

**"Open the document"** (the button at the top right of the preview) opens the
file in the app that would open it from the Finder, and **at the page Fouine is
showing, when that app can go there**. That holds for **PDFs** only: page 3 of an
e-book depends on the body size the reader chose, and page 3 of a recording is a
ten-minute slice Fouine invented.

| What opens your PDFs | What happens |
|---|---|
| **Preview**, the macOS reader | the document opens at its first page |
| **Chrome**, **Edge**, **Brave**, **Vivaldi**, **Opera**, **Arc**, **Firefox** | the document opens at the page found |
| **Safari** | the document opens at its first page |
| another reader | the document opens as a double-click would open it |

Preview **cannot** open a PDF at a given page: macOS offers no way to ask it,
and that is not something Fouine can work around. The button's tooltip says as
much without promising anything: "Open in the default application — at page 412
when it can". When the page cannot be asked for, the document opens as before,
with no message and no wait; if anything prevents opening at the page, Fouine
opens the document itself rather than doing nothing.

To have your PDFs open at the page found, change the app that opens PDFs: in the
Finder, right-click a PDF ▸ "Get Info" ▸ "Open with" ▸ choose the browser ▸
"Change All".

**From one match to the next.** Under the page number, a line says how many
times each of your words appears on the page: a **dot in the word's colour**,
the word, the count, so "nitrogen 3". A word and the forms Fouine searched
alongside it ("polymer", "polymers") share one colour and one count; a word
absent from the page has no dot. Five fit on the line, the rest are in the
tooltip. "400+" means highlighting stopped at 400 occurrences of that word on
the page.

On the page of a **PDF**, the same line carries **"3 / 27"** and two chevrons:
**⌘G** goes to the next occurrence, **⇧⌘G** to the previous one, or Edit ▸ **Next
occurrence** / **Previous occurrence**. Occurrences are walked in reading order,
top to bottom then left to right, and the one you reach is selected. **The walk
stays inside the page**: after the last one you come back to the first, and
changing page means scrolling the PDF. On a page read from an image, each line
where a word was found counts once. In **Text** mode only the dots appear: that
pane cannot scroll to a word, and a "3 / 27" with no possible gesture would
promise a jump that never comes.

**Audio and video** have their **player**, with the transcript below. The text is
cut into paragraphs each carrying its **timestamp** ("12:40"), and each one is a
button that sends the player to that passage. Opening a result puts the playhead
at the start of the passage found and **starts nothing**: sound going off by
itself in a room or a train is a bad surprise. The previous and next page arrows
walk the recording in ten-minute slices, like the pages of a book.

**When the drive is unplugged**, the preview shows the text Fouine had kept and
says so in one line: "The disk holding “Books” is not plugged in. Here is the
text Fouine kept.", with a **Copy this text** button. The other pages of the
document stay readable: the text comes from the index rather than from the disk.

When the search is restricted to one document, the **Leave this document**
button gives it back to all your folders.

**Detached preview windows**, the ones from a double-click, from the menu bar
panel and from `fouine://` links, follow two rules: **one window per document**
(a second link to the same book changes the page of its window and brings it
forward) and **three at most** (beyond that, the least recently used window
takes the new document). A PDF of several hundred pages costs memory; three open
side by side is a use, ten forgotten during the day is a problem.

**A page that no longer exists.** A link cited a year ago may name page 99 999 of
a document that has since been shortened. Fouine then opens the **first page**
and says so: "Page 99 999 no longer exists in this document."

**"Read this page again"** (right-click on the page). The gesture appears only
when the text of the page shown was **read from an image**, which the header
already says next to the page number. A page whose document carried the text, or
a page transcribed from audio, has no image to read again.

On click, the page goes back into the queue and a line appears under the
preview: **"This page will be read again next time the scans are read. Its text
will only change if you have just ticked its language in Settings ▸
Indexing."** Again, nothing starts: the reading of scanned pages will pick it
up. If the index is busy with a write: "The index is being updated. Try again in
a moment." The line disappears as soon as you change page.

---

## 3. Taking results away

### Exporting (⇧⌘E, or the share button above the list)

The save panel offers **three formats** and says, in plain words, what is
leaving: "Export: 200 lines — the results currently loaded, out of 29 037 pages
found." It is the **loaded set** that is exported, in the order shown, sort and
filters included, never a total you have not seen on screen.

| Format | What for |
|---|---|
| **CSV (spreadsheet)** | Numbers, Excel, LibreOffice. Columns `path, page, score, snippet, root, modified, link`, in English and stable: this is data, for a script to read. |
| **JSON (script)** | the same fields, for automatic processing. |
| **Markdown (notes)** | a notebook (Obsidian, Bear, Notion), a Word document, a bibliography. |

The Markdown file is a title, then **one line per page found**:

```
# Fouine — chloride (3 results)

- [Organic Chemistry — volume 2.pdf, page 87](fouine://open?…) — … the snippet …
```

The clickable reference is **exactly the one "Copy the reference" gives**, and
the snippet is cut at two hundred characters. No table, no technical header: the
file pastes straight into a notebook.

**"Copy every reference" (⌥⌘C**, in the Edit menu, under "Copy the reference to
this page"**)** puts one reference per loaded result on the clipboard, in the
order shown. With no results, the menu item is disabled.

### Sorting

The sort menu above the list orders documents by **relevance** (the default),
**modification date** (newest or oldest first), **file name** or **path**.

As soon as an order other than relevance is chosen, Fouine **loads the whole set
before sorting**: sorting the first two hundred results of a twenty-nine-thousand
page corpus did not return the two hundred most recent, it returned the most
relevant ones reordered, and "the most recent document about X" had no answer.
While it loads, the line under the counters says **"Loading every result before
sorting them…"**; the selector stays live, and going back to relevance
interrupts everything.

Loading stops at **two thousand results**, a handful of seconds on the reference
corpus. Beyond that Fouine says so rather than letting you believe in a complete
ranking: **"Sorted by date ↓ over the first 2 000 results, out of 29 037 pages
found."** When everything fits under the ceiling there is nothing to confess and
the line disappears. A new search stops the loading.

Search by meaning does not paginate: it returns a complete set, so its sort is
always whole.

### Saved searches

The history (the clock icon, to the right of the field) keeps the last forty
queries, then forgets them. To keep "my 2025 invoices" from one month to the
next, its first item is **"Save this search…"**: Fouine offers the query itself
as a name, and you replace it with what you want.

Saved searches appear in the sidebar, in the **Saved searches** section, above
the quick filters, and only when there are any. A click replays the search; a
right-click offers **Rename…** and **Remove**. Drag one up or down to change its
place; Fouine keeps the new order. Fifty at most; beyond that the oldest one
goes.

**What is kept, and what is not.** The query **as you typed it**, prefixes
included: `folder:Invoices 2025`, `"exact phrase"`, `-draft` are saved as they
are. The **filters ticked in the sidebar** are not part of it: they are one click
away, and above all they are counted on the corpus of the moment. A folder
selection saved last year might name no document today, and the replayed search
would return nothing without saying why.

---

## 4. The Index card

At the top of the sidebar, the **Index** card says the essentials: what Fouine
is doing, whether the index is up to date, and whether something is expected of
you. It carries only that:

- a **state sentence** ("Up to date", "Reading scanned pages"…) and, under it, a
  **detail** when there is one ("Updated 3 min ago", "They will be read once the
  Mac is plugged in.");
- during a job, a **progress bar** and, when Fouine knows it, the **time left**
  ("about 2 h left"). Neither the current document nor the page count, which
  change constantly: they are in the "Your index" window;
- **at most one button**, when a gesture is expected;
- the **disk space** sentence, only when Fouine may run out of room to finish;
- on the last line, the **Details…** link, which opens the **"Your index"**
  window, where everything else is.

Under the card, the switch "Keep the index up to date automatically".

**The Stop button.** It answers at once: on click it disables itself, a small
spinner appears next to the sentence, and the sentence says what Fouine is
waiting for, **"Stopping — finishing “course.mp4”…"** when one document is being
read, **"Stopping — 3 documents are finishing…"** when there are several. Fouine
reads up to four documents at a time: those are the ones being waited for, and
the wait is a few seconds. A reading in progress now stops between two pages
(PDF, DjVu) or during the writing down of a recording, rather than running to
the end. A document interrupted that way is **neither read nor failed**: it
stays to be done, and the next update takes it from the beginning. Nothing is
lost and nothing is half written. Reading scanned pages and preparing search by
meaning stop the same way, with their own sentences.

### States of the card

One state at a time, chosen in this order: checking, no folder, a pass started
from the app, a gesture expected, another program writing, automatic updates,
up to date.

| Title | Second line | Meaning | Button |
|---|---|---|---|
| **Checking…** | — | Fouine is reading the state of the index at launch | none |
| **No folder to index** | — | no folder has been added | Add a folder… |
| **Updating the index** | the time left when known | walking the folders, extracting text | Stop *(pass started from the app)* |
| **Reading scanned pages** | "about 2 h left" | recognising the text of scanned pages | Stop *(idem)* |
| **Preparing search by meaning** | the time left when known | preparing the pages for search by meaning | Stop *(idem)* |
| **The index is being updated** | "Another program is writing to the index; searching still works." | the command line is updating the index | none |
| **Up to date — N scanned pages to read** | "They will be read once the Mac is plugged in." (or: once Low Power Mode is off, once the Mac has cooled down, once the other program has finished, once every folder can be read again) | the text is current; reading scanned pages is waiting for the machine | none *("Read scanned pages…" is in the "Your index" window)* |
| **Fouine is not allowed to read “…”** | "Its documents stay searchable. Allow Fouine in System Settings ▸ Privacy & Security ▸ Files and Folders…" | macOS refuses to read the folder | Allow access… |
| **The disk holding “…” is not plugged in** | "Its documents stay searchable. Plug the disk in…" | the folder is on an absent drive | Check again |
| **Automatic updates are waiting for your approval** | "Allow Fouine in System Settings ▸ General ▸ Login Items & Extensions." | macOS is waiting for your confirmation | Open System Settings |
| **Automatic updates are not starting** | "Restarting them usually fixes it…" | the service never reported, or stopped | Restart automatic updates |
| **Several copies of Fouine are installed** | "Keep only the one in the Applications folder…" | two Fouine.app are fighting over the place | Restart automatic updates |
| **Automatic updates are unavailable** | "Fouine must be installed in the Applications folder…" | the app is not installed in Applications | Show in the Finder *(the copy to drop into Applications)* |
| **Up to date** | "Updated 3 min ago" | nothing to do | none |
| **Up to date — N scanned pages to read** | "They are read automatically when the Mac is plugged in and idle." | the text is current, the scanned pages will follow | none |
| **Manual updates** (— N scanned pages to read) | "Fouine only updates the index when you ask." | automatic updates are off | Update now |

A service that is alive but has been silent for a few minutes (a Mac waking from
sleep) shows as **Up to date** rather than broken: only a service that never
reported, or whose process has disappeared, triggers "not starting".

### What the trial adds to the card

- **During the trial**, a quiet line at the bottom of the card: "Trial: 12 days
  left · **Buy**". Nothing else: no window at launch, no countdown in large
  letters, no reminder coming back. The rest of the card says what it would say
  anyway.
- **When the trial ends**, the card replaces its action button with the sentence
  "Your trial is over: searching still works, the index is no longer updated"
  and two buttons, **Enter licence key…** and **Buy**. The "Update now" button
  goes: offering it when it can no longer do anything would be a promise that
  breaks on click.
- **The switch does not change**, and that is not an oversight: automatic
  updates fall silent by themselves, and greying the switch out would mean
  explaining why in a place where the card has just said it.
- **If the seller disabled your key**, the card says "This key was disabled by
  the seller" and the same two buttons come back.

---

## 5. The Your index window

Open it with the **Details…** link of the Index card, or with **Window ▸ Your
index**. There is only one: reopening it brings back the one that exists. It
reads everything again when it opens, then keeps itself current while Fouine is
in front. While the index is being updated, its counts follow: they are read
again every ten seconds at most, and once more when the update ends.

It says, in four parts, what the card no longer says.

**What Fouine is doing.** The card's state sentence, with its **complete**
detail, the current document included, the progress bar and the page count
("312 / 1 200 pages · about 2 h left"). The gestures of the state are there too:
the card's button and, second, as a link, **Read scanned pages…** when scanned
pages are waiting. A gesture that opens a sheet brings the main window forward
first.

**Automatic updates.** The same **Keep the index up to date automatically**
switch as under the card; the sentence that says what it does ("Fouine checks
your folders from time to time and updates the index by itself, even when its
window is closed."); the answer to the last gesture, confirmations included
("Automatic updates are on. macOS may ask you to confirm in System Settings ▸
General ▸ Login Items."); and where the moments it works are set: **Settings ▸
Indexing ▸ When to update automatically**.

**What the index holds.**

- **"1 527 documents · 408 951 pages"**, two numbers grouped the same way. **That
  line is a gesture**: it opens "All your documents". It stays plain text while
  the statistics have not answered, or when the index is empty, since opening a
  list of zero lines teaches nothing.
- When documents could not be read, **"23 unreadable documents"**, which opens
  the window listing them, and what that means: "These files are in your
  folders, but Fouine could not read them. Your files are untouched."
- When automatic updates read new pages while Fouine was closed: **"Since your
  last visit: 4 200 new pages"**. The line holds for the session, with no close
  box: you came to this window to read.
- The space left on the disk, **only when it is running short** (below).

**When the disk is running short.** This line appears only when space is running
out on the disk holding the index. Fouine never compares the index with an
"expected size": that figure is a design promise, and a "planned" number reads
as a ceiling to anyone without the specification in front of them.

| Situation | Sentence | Where |
|---|---|---|
| more than 5 GB free | *no line* | — |
| less than 5 GB free | "Your disk has 3.2 GB left; your index uses 2.15 GB" | the "Your index" window |
| less than 1 GB free, or less than what preparing search by meaning still has to write | "Your disk has only 800 MB left and your index uses 2.15 GB: Fouine may run out of room to finish it. Free up some space, or remove a folder you no longer need" | the window **and** the Index card |

Three things about that line: **nothing ever stops**, neither indexing, nor
reading scanned pages, nor preparing meaning. Fouine warns, and that is all; the
system will refuse to write the day the disk is really full. There is **no
button**: the possible gesture is to free space or remove a folder, and the
sentence says so. And the free space is the one **macOS promises to a large
write**, the Finder's figure, purgeable space included, read at the same time as
the index counts; if the volume does not answer, the line stays quiet rather
than announcing a false figure. Sizes are written the way the Finder writes them
("2.15 GB").

**Scanned pages without readable text.** This part appears only when there are
any. A scanned page can have been **read** without Fouine getting sure text out
of it; its document is in the index, so these are not "unreadable documents".
Two cases, each on its line:

```
3 157 scanned pages with no text Fouine could recognize
    Usually blank pages, pictures or drawings.
1 053 scanned pages read with uncertain letters
    Faint or skewed scans, handwriting, unusual fonts: a search may miss some
    of their words.
```

**There is no button to read them again, and that is deliberate.** Fouine read
them as well as it can: another reading goes through the same recognition, with
the same settings, and returns the same result. Queueing them again, measured on
a real index, leaves the same pages in place once the queue has drained.

**The one case where reading again changes something**: a document written in a
language that is not ticked in **Settings ▸ Indexing ▸ Languages of the scanned
documents**. Tick it, then right-click the page in the preview and choose **Read
this page again**. The line under the preview says as much.

On the command line, `fouine ocr requeue [--doubtful|--no-lines]` always queues
those pages again, and both counts are in `fouine status`.

---

## 6. All your documents

Open it with the count in the "Your index" window, or with **Window ▸ All your
documents (⌘⇧L)**. There is only one: reopening it brings back the one that
exists.

- a **Filter by name** field (it searches the name **and** the folder; the list
  is read again 300 ms after the last keystroke);
- a **Folder** menu (your watched folders, or "All folders");
- a **Type** menu (the extensions actually present, most frequent first, or "All
  types");
- an order menu: **Recent** (default), **Name**, **Pages**;
- the **count** of everything matching the filters, not only what is on screen;
- the list, in slices of **200**, with "Load more (N left)".

A line carries the file name, the **shortened** folder, the number of pages and
the date in plain words ("Modified yesterday"). The whole path stays in the
tooltip. Documents Fouine could not read **are in the list**, with the sentence
saying why; hiding them would recreate the hole this window fills. Documents
still waiting carry "Not read yet — it will be at the next update".

**A click** opens the document's preview at its first page, in its own window
(same rules as elsewhere: one window per document, three at most). **A
right-click** offers "Show in Finder", "Open" and "Search inside this document",
the last of which closes the window and sets the scope in the main window.

When nothing matches: **"No document matches"**.

The same list is available on the command line with `fouine list`.

---

## 7. Keeping the index up to date

Placed directly under the Index card, the **Keep the index up to date
automatically** switch hands the watching of your folders to the system. It is
the same switch as in the "Your index" window: one name, one gesture.

When you flip it, **nothing is written underneath**: the card already says the
new state, and waiting for macOS to agree has a state of its own ("Automatic
updates are waiting for your approval"). Only a **refusal** appears there. The
switch then goes back, and the sentence says why: no folder ("Add a folder
first: there would be nothing to keep up to date."), folders not yet allowed, or
Fouine installed somewhere other than the Applications folder. The "Your index"
window keeps the answer to the last gesture, confirmations included.

As soon as a document is created, modified or deleted in an indexed folder,
Fouine takes the change into account within seconds.

To spare the battery and the machine, reading scanned pages waits until the Mac
can spare the effort:

1. the Mac is plugged in;
2. Low Power Mode is off;
3. the Mac is not hot;
4. no other program is writing to the index;
5. every folder can be read.

The first three are settings (Settings ▸ Indexing). As soon as one condition
fails, the card says which ("They will be read once the Mac is plugged in.") and
reading resumes by itself afterwards. To skip the wait, **Read scanned pages…**,
in the "Your index" window, starts a pass now, with a duration to choose.

What runs in the background, its log and its settings: the "Keeping the index up to date" page of the documentation.

---

## 8. The menu bar

Fouine keeps a quiet presence in the macOS menu bar.

**The icon changes with what the index is doing**, and three shapes are enough:

| Icon | When | What the panel's state line says |
|---|---|---|
| **Magnifier** | nothing running: up to date, manual updates, paused, no folder, checking | "Up to date", "Manual updates", "No folder to index" |
| **Circular arrows** | the index is working | "Updating the index", "Reading scanned pages", "Preparing search by meaning" |
| **Triangle** | Fouine is waiting for a gesture | "Fouine is not allowed to read “…”", "Automatic updates are waiting for your approval"… |

A changing icon says something is happening; the panel's state line says what.
VoiceOver announces the icon with that same state sentence, never as "icon".

**The panel.** A click on the icon opens a small panel. **The cursor is already
in the field**: you type.

- **Results arrive as you type**, after a quarter of a second of silence. One
  line is one page: the file name, its page number, and the snippet on one line.
  Pages of the same document follow one another. If you turned **Search as I
  type** off (§ 11), typing no longer searches: the first **↩** searches in the
  panel, the next one opens the window on the same question.
- **Eight pages at most.** When there are more, a **Show all in Fouine** line
  closes the panel and puts the question in the window, where the filters, the
  facets and the preview are.
- **A click on a page** opens it in its own preview window, the same one a
  double-click on a result gives, at the same page, with the same highlights.
- **⌘-click** opens the file in its usual app.
- **↑ and ↓** walk the lines, **↩** opens the one selected; with no line
  selected, **↩** hands the question to the main window.
- **Escape** closes the panel. **⌘Q** quits Fouine.

This panel searches the **words** of your documents only: search by meaning,
which needs a model to load, stays in the window, because a panel has to answer
at once. It touches nothing that is open beside it: the filters, the selection
and the query of the main window stay where they are. The global shortcut
**⌥⌘F** always opens the window.

**Under the results**, a state line then two gestures, and nothing else. The
line is the Index card's state sentence, in grey, with no button: it explains
the shape of the icon. Then **Open Fouine**, which shows or brings forward the
main window (also in the Window menu, ⌘0), and **Quit Fouine**. When automatic
updates are on, a tooltip recalls that the index keeps updating itself after
Fouine is closed; with them off, the tooltip stays away, since nothing would be
running. ⌘Q works from the panel, but its glyph is not drawn there: a menu bar
panel is not a menu, and macOS does not draw shortcuts in one.

**Closing the window does not quit Fouine**: with the menu bar option on,
closing the window hides the Dock icon and leaves the app available in the menu
bar. "Open Fouine" or ⌥⌘F brings the window back. A setting also lets Fouine
start with your session, straight into the menu bar, without opening a window.

---

## 9. Search options and filters

### Typos

A three-position selector adjusts tolerance to spelling and recognition
mistakes:

| Option | Behaviour |
|---|---|
| **Never** | strict word-for-word search |
| **Auto** (default) | tolerance only when a word gives no exact result |
| **Always** | search always widened to close variants |

### Also search by meaning

Search by meaning brings back passages whose subject matches your query, even
with no words in common. The **Also search by meaning** switch merges the pages
found by your words with the pages found by meaning. If your documents have not
been prepared for it yet, a button starts the preparation. The whole mechanism, and what it is
worth: the "Searching" page of the documentation.

### Filters

Under the search field, five sections narrow the view:

- **Folders**: filter by folder;
- **File types**: filter by format (PDF, DOCX, EPUB…);
- **Languages**: filter by the document's language (the section appears from two
  languages on);
- **Text origin**: typed text, pages scanned and read by Fouine, recognition
  done before Fouine, and speech transcribed from a recording. Those four names
  are the same everywhere: the facet, the preview header, the icon on a line,
  and the screen reader;
- **Modified in**: the year the **file** was last changed, not the year of the
  work. A book from 2003 copied onto the Mac in 2024 files under 2024, and the
  section's tooltip says so.

**Dated** appears above "Modified in" as soon as results carry a date of their
own: the year written **in the document itself** (PDF, Word, EPUB, email,
photo). Ticking a year keeps only those documents. It is a display filter, like
"Modified in", and its tooltip says so.

Each section shows at most **twelve values**, the fullest ones; beyond that a
line says "Only the first 12 are shown". They all re-run the search, and the
announced totals follow, except **Modified in** and **Dated**, which only sort
the results already shown.

"Text origin" is the only one that bears on the **page**: one book can mix typed
pages and scanned plates, and the **Scans only** quick filter sets exactly the
same filter.

### Quick filters

Above the facets, four chips cover the filters people set most often: **Modified
this year**, **Modified in the last 5 years**, **PDF only**, **Scans only**. The
date windows are calendar years. The chips drive the same state as the facets,
so unticking "pdf" in File types turns the "PDF only" chip off, and **Clear
all** removes them all.

### Why this result

Under the snippet of the **selected** result, and under it alone, a quiet line
says why that page is there: "Found because this page contains “kinetics” and
“chemistry”.", "Found with a close spelling: “converslon” → “conversion”.",
"None of your words is on this page, but it deals with the same subject.",
"Found by your words and by meaning."

No number appears there. The words quoted are yours, and a term you excluded is
never named: that would point at exactly what you asked to drop.

---

## 10. Citing a page

A page found can be **cited**: its name, its page number, and a link that leads
straight back to it. That is what lets you send someone, or yourself six months
later, to the right page of a thousand-page book.

Two gestures, the same words in both places: in the preview pane, the **Copy a
reference to this page** button, and, by right-clicking any result line, the
submenu of the same name. At the keyboard, **⇧⌘C** (Edit ▸ **Copy the reference
to this page**) acts on the selected result.

Each offers **Copy the reference** and **Copy the link**. The reference is two
lines:

```
Organic Chemistry — volume 2.pdf, page 87
fouine://open?path=/Users/…/Organic%20Chemistry.pdf&page=87
```

The link is alone on its line on purpose: Mail, Notes, Pages and Word only make
an address clickable when nothing follows it. For the same reason, the
**brackets** in a file name are written `%28` and `%29`: one academic book in two
carries its year in brackets, and those same detectors cut an address on a
closing bracket.

**A page of audio or video is cited by its moment.** "Page 2" of a two-hour
course sends nobody anywhere, so the reference gives the moment, and the link
carries it:

```
chemistry lecture 12 March.m4a, 12:40
fouine://open?path=/Users/…/chemistry%20lecture.m4a&page=2&t=760
```

The `t` parameter is a number of **seconds** from the start of the recording:
the moment the playhead was at when you copied the reference. On opening, Fouine
puts the player there, without starting it. Only the app emits `t`; `fouine
search --json` and the assistant server cite the page.

**What a `fouine://` link does.** Clicked from any app, it brings Fouine
forward and opens the page in its own preview window. When the link also carries
the search that led to that page, the search is replayed in the document and the
words are highlighted again.

**"Fouine does not know this document."** A link cited last year may name a
document that has been moved, renamed, or is no longer in a watched folder.
Fouine says so, with the file name. An index update catches up with most of
those cases.

The **Open the file** button appears only for a **document** Fouine could have
indexed: an ordinary file, **inside one of the folders you watch**, and not a
program. A link can come from anywhere, a web page or an email, and its author
chooses the path it carries, so there is no reason to open an app, a folder, a
script, or anything living outside your folders. When a file exists at that path
without meeting those conditions, the window says so, "It is outside the folders
Fouine watches, so Fouine will not open it.", and offers no button. (An `.rtfd`,
technically a folder, is still a document and opens normally.)

The link also travels in the export of results (the `link` column), in `fouine
search --json` and in the assistant server's answers: that is how an assistant
can cite a page of your documents in a way you can check.

---

## 11. Settings

Settings open with ⌘, and have seven tabs.

### General

- **Keep Fouine in the menu bar** (on by default): keeps the icon in the menu
  bar and stops Fouine quitting when the window closes. "The small icon at the
  top of the screen lets you search your documents and open Fouine. It also
  shows what the index is doing."
- **Search as I type** (on by default): "Results appear as you type. Off, press
  Return to search." The setting covers the window **and** the menu bar panel,
  and applies from the next keystroke. Off, typing only suggests words under the
  field; **↩** runs the search. Nothing else changes: same filters, same
  results, same history.
- **Open Fouine when I log in**: starts the app in the background at login.
- **Tell me when the scanned pages are all read**: posts a macOS notification
  when the queue empties. **The permission is asked for first**: Fouine ticks the
  box only if macOS said yes. A banner ignored, a refusal, or a permission
  withdrawn later in System Settings, and the box goes back to zero with a line
  under it, "macOS hasn't allowed Fouine's messages yet", and an **Open System
  Settings** button. The state is read again each time the tab opens: the box
  never promises a message that will not come.
- **Spotlight**: see § 12.
- **Keyboard shortcut**: a reminder of ⌥⌘F.

### Licence

The second tab, right after General: it is the one you open after buying, and
the only place where a trial that ends gets resolved.

- **The state, in one sentence**: "Trial: 12 days left", "Your trial is over:
  searching still works, the index is no longer updated", "Licensed — key ending
  in ·····XYZ456" with the date of the last check, "This key was disabled by
  the seller", or, when the monthly check learns that you freed this Mac from
  your customer area, "This Mac was released from your customer portal. Enter
  your key again to use it here."
- **A Licence key field and an Activate button**, inactive while the field is
  empty. The field accepts what you paste: spaces, line breaks and lower case
  are cleaned up before sending.
- **A Buy Fouine — €39 button**, which opens the payment page in your browser.
  Fouine never asks for a card number itself.
- **Once the key is in**, the field gives way to **Deactivate this Mac**, which
  asks for confirmation: "This Mac will stop counting toward your 3 activations.
  You can activate it again later."
- **Refusals appear under the field, in one sentence and one gesture**: "No
  connection: connect to the Internet and try again.", "This key is not
  recognised. Check for typos, or look for it in the e-mail Creem sent you.",
  "This key is already in use on 3 Macs. Deactivate one of them from Settings, or
  from your Creem customer portal.", "The licence service is unavailable right
  now. Your trial continues; try again later."
- **The foot of the tab says what goes out and when**, as the updates tab does:
  the key and the name of this Mac, at activation, at release, and during one
  silent check a month. Nothing while Fouine indexes or searches. Detail:
  the "Privacy" page of the documentation.

The **Fouine ▸ Enter licence key…** menu item opens this tab directly, and
**About Fouine** recalls the state in one line.

### Folders

- The list of your folders with their name and location, and buttons to add or
  remove one.
- Per folder: **Read its scanned pages first** (that folder's scanned pages go
  ahead of the others), and **What Fouine skips…** (below).
- The box on the left enables or disables the folder.
- When a setting is greyed out (Fouine outside the Applications folder, a value
  forced by the environment), the reason appears **in plain words under the
  control** rather than only on hover.

**Keeping part of a folder out.** Under each folder, **What Fouine skips…**
opens a sheet that lists, in plain words, what Fouine leaves out of that folder:
"The folder “Health”", "Every .md file", "Files named “INDEX.md”". A cross next
to a line stops skipping it. Three buttons add one, without typing any pattern:

- **Skip a folder…** opens a folder picker on that folder. Choose a folder
  inside it. The folder itself is refused ("That is the whole folder. To stop
  indexing it, untick it in the list."), and so is a folder elsewhere.
- **Skip a kind of file** is a menu of the kinds of file really present in that
  folder, the most numerous first, each with its count.
- **Skip files named…** shows a field for one file name, such as `INDEX.md`.

Something already skipped is not added twice: the sheet says "Fouine already
skips this." Before you save, one sentence says what will happen: "About 41
documents will leave the index at the next update. Your files are not touched."
Removing a line says "What you no longer skip comes back at the next update."
Nothing changes until you click **Save**. Then, if automatic updates are off,
**Update now** applies the change at once; if they are on, Fouine applies it on
its own within a few minutes.

**Fouine writes nothing into your folder.** It keeps these rules in its own
index, so they go away if you remove the folder from Fouine (unticking it keeps
them). A small file named **`.fouineignore`** at the top of a folder still works,
for a folder you share or copy to another Mac: one line per thing to leave out —
a folder name followed by a slash (`Health/`), a kind of file (`*.md`), or the
exact name of a file (`INDEX.md`). Its lines appear in the same sheet, greyed
out, with "from the .fouineignore file in this folder" and no cross: Fouine
only reads that file, so a line is removed by editing it. Fouine applies both
together. What they name leaves the index, and searches stop finding it. **Your
files are never touched**, only what Fouine remembers of them.

**Applications.** Under the folder list, one box per app whose notes Fouine can
read: **Apple Notes**, **Bear** and **Anki**. Ticked, Fouine copies the text of
the notes into its own folder so it can search them. The line under the boxes
says that, and says that **nothing leaves this Mac**. Unticking deletes the
copies and removes the notes from the index; your notes themselves are never
modified. Under each box, the state in plain words: "not installed on this Mac"
(the box is greyed out), "Fouine is not allowed to read these notes" with an
**Open System Settings** button (Apple Notes keeps its notes in a protected
place, which takes **Full Disk Access**, a different pane from "Files and
Folders"), or "N notes searchable".

Adding Anki's, Apple Notes' or Bear's own folder with "Add a folder…" does not
work, and says so: the alert tells you to tick the application here instead, and
its **Open Settings** button opens this tab.

Fouine shows these notes as they are **in their app**, never as the copy it
made: a note found carries its title and the icon of Notes or Bear, and opens in
its app — in the preview, the "Show in Finder" button becomes **Open in Notes**
(or **Open in Bear**), because what you want to edit is the note. The preview
shows its text, and Quick Look, dragging the result away and "Open" are not
offered, since they would only show Fouine's copy. In "Your folders" and in the
list above, the folder of an application carries that application's icon; its
menu has no "Show in Finder", "Rename" or "Remove": the application is turned
off here, with its box.

**Anki** flashcards arrive one deck at a time: each deck is one document in the
list, under its name, with the Anki icon and the decks you nested it in shown
above it ("Anki › Chemistry"). Its pages are its **cards**: the list says "card
12" and "74 cards", the preview "card 3 of 642", and a copied reference cites
the card. A search that matches forty cards of the same deck therefore shows
that deck once, with "See them all" to go through the cards. The name of a deck
is not a word of its cards: find a deck by its name, like a file. Anki can stay open while
Fouine reads it; a card added a minute ago is found at the next update. In the
preview, the button becomes **Open in Anki**: Anki for Mac cannot open a given
card from outside, so it opens Anki, where the card is one search away. The
preview shows the text of the card, then its **pictures**, read from Anki's own
folder: a picture deleted in Anki is simply not shown. The words inside a picture
are not searched, only the text of the card; sounds, hints and tags stay in Anki.

**Notion and Craft** have no box: their notes cannot be read on this Mac. Export
your pages as Markdown, then add the export folder with "Add a folder…". A page
exported from Notion reopens in Notion from the preview.

### Indexing

- **When to update automatically**: three tickable conditions (only when the Mac
  is plugged in, not in Low Power Mode, not when the Mac is hot).
- **Also prepare search by meaning in the background**, unticked by default.
  Fouine then produces, in short stretches and under those same three
  conditions, what search by meaning needs, once every scanned page has been
  read. Under the box, a sentence says when that will happen, or, if the model is
  not downloaded yet, where to get it.
- **Languages of the scanned documents**: the languages Fouine expects on
  scanned pages, most likely first. They are also the languages used when
  writing down recordings. Languages carry **their name**, in alphabetical order
  of that name, and the technical code goes into the tooltip.
- **Index images (photos, scans, camera RAW files)**, on by default. Ticked,
  the photos, scans and RAW files of your watched folders enter the index and go
  through text recognition. Two sentences accompany it, and they say what
  matters: **each image goes through text recognition**, which can keep Fouine
  busy for hours on a large photo folder; and **Fouine reads the text of
  photographed documents**, a receipt, a letter, a page, while shop signs, labels
  and decorative lettering often escape it.
- **Index audio and video files (titles, artists, chapters…)**, on by default;
  untick it if a watched folder is a music library rather than a set of
  documents. Ticked, the titles, artists, albums,
  lyrics and chapters of a recording become searchable without listening to a
  second of it. Under it, **Also write down what is said in them**, on by
  default too: Fouine listens on this Mac and writes the words, nothing is sent
  anywhere; count
  roughly the length of the recording, and the language must be installed in
  System Settings ▸ Keyboard ▸ Dictation (otherwise the document is set aside
  saying so). **Longest recording to write down (minutes)** bounds the effort
  (120 by default; beyond it, only the metadata is indexed). One page is ten
  minutes of recording, each paragraph headed by its `[mm:ss]` timestamp.

### Search by meaning

Turning search by meaning on, the state of the model (a single 220 MB download,
stored locally), the count of pages prepared and a **Prepare search by meaning…**
button. When Fouine handles it by itself (the box above ticked, the model
installed, automatic updates on), that button disappears, replaced by "Fouine
takes care of it in the background, when the Mac is plugged in and idle.": the
work happens, there is nothing to click.

### Updates

A manual **Check for updates…**, and a switch for periodic checking, off by
default. No personal data and nothing about your documents is ever sent. **When
a check does not succeed** (no network, silent server), the "Last check" line
says "could not reach the server", and the tab adds: "Fouine could not check
whether a newer version exists. Try again later. Fouine keeps working as it
is." Details: the "Updates" page of the documentation.

### Advanced

- How much Fouine does at once: how many documents it reads together, how many
  scanned pages, and how many documents when it works in the background.
- The length of a recognition batch, in minutes.
- How often the state is checked again, in seconds.
- The scope of typo tolerance: scanned pages only, or the whole index.
- **Install the command line tool…**: sets up the symlink.
- **Open the activity log**: opens the diagnostic file.
- The location and size of the index, with a button to show it in the Finder.

---

## 12. Fouine in Spotlight

Spotlight, the magnifier at the top right of the screen (⌘-Space), does not read
everything: a scanned PDF, a DjVu, a comic or a mail archive gives it **no
text**. Fouine has read them, so it hands Spotlight what it read, and Spotlight
shows it like any other result.

**What appears.** The file name, the first lines of the text, the name of the
folder Fouine watches. Clicking opens **Fouine**, at the page where your words
are when Spotlight passes on what you typed, at the first page otherwise. A
pleasant side effect: Fouine does not search file names, Spotlight does, so the
documents handed over become findable by name.

**Why only scans, by default.** Handing over an ordinary `.docx` or `.pdf`,
which macOS already reads, would show **two** results for the same file. So
Fouine hands over only what Spotlight cannot read: documents with at least one
page from text recognition, recordings whose speech Fouine wrote down (Spotlight
reads the title of a video, never what is said in it), and the formats measured
as mute (`.djvu`, `.cbz`, `.cbr`, `.epub`, `.ai`, `.sketch`, `.fig`, `.indd`).
The second radio button, **Every document Fouine has read**, lifts that
reservation.

**The two buttons.** **Update Spotlight now** erases what Fouine had handed over
and hands everything again. It is the only gesture that removes from Spotlight a
document deleted from the disk since, the index keeping no trace of a deletion.
**Remove Fouine's documents from Spotlight** (with confirmation) puts the Mac
back exactly as it was: your documents are untouched, and Fouine keeps finding
them.

**Proof that a handover happened.** Under the two buttons, a line: "Last
handover on <date> · <N> documents", read from the index itself. With no count
(a handover made by an earlier version), the date alone; before the first
handover, or after a removal, "Not handed over yet". It is the only check
possible from outside: `mdfind` does not query the Spotlight index Fouine feeds.

**When the update happens by itself.** At the end of every index update, and
every time Fouine opens. The `fouine` command and background updates cannot talk
to Spotlight: what they index goes over the next time the app opens.

**What it costs.** Fouine hands over at most **one megabyte of text per
document**, whole pages that fit, never a page cut in the middle. On the
reference corpus (1 527 documents, mostly scanned books) the first handover
sends 561 MB to Spotlight in 25 seconds, in the background; after that, each
update touches only what changed and takes milliseconds. The ceiling is a
command-line setting (`spotlight.text_kb`).

**Nothing leaves the Mac.** Spotlight's index is local, like Fouine's, and
uninstalling removes the documents handed over before erasing anything (see
the "Privacy" page of the documentation).

---

## 13. Fouine in Shortcuts and Siri

The **Shortcuts** app that comes with macOS can chain actions together. Fouine
adds **three**, which appear as soon as it is installed when you type "Fouine"
in the action list.

| Action | What it takes | What it returns |
|---|---|---|
| **Search in Fouine** | what you are looking for, and how many results (10 by default, 50 at most) | a list of pages found |
| **Open in Fouine** | a page found | nothing: Fouine opens on that page |
| **Get the text of a page** | a page found | the text Fouine read on that page |

Each page found carries its **file name**, its **page**, a **snippet**, the
**folder** it comes from, its **path** and its **Fouine link**: six variables to
drag into the next action.

A first chain, finding a page and opening it: *Search in Fouine* → "crosslinking
kinetics", then *Choose from list*, then *Open in Fouine*. A second, making
notes out of a course: *Search in Fouine* → "electrolysis", 5 results, then
*Repeat with each*, then *Get the text of a page*, then *Create note* (Notes), or
*Send email*, or *Add to clipboard*.

On **macOS 26 and later**, these same actions are offered directly in Spotlight:
⌘-Space, type "Fouine", and "Search in Fouine" is there.

**They can also be dictated to Siri**: "Hey Siri, search Fouine", or "Hey Siri,
search my documents with Fouine". Siri starts the action, then Shortcuts asks
*what* to search for: a spoken phrase cannot carry a free word, only a list of
choices known in advance.

**What these actions do not do.** They read the index only, never the original
file: "Get the text of a page" returns what Fouine extracted or recognised,
rather than the PDF. They index nothing and modify nothing. They search **the
text**, like the window, without search by meaning, which loads a model that
takes two seconds to open, and a shortcut does not tolerate that. Only "Open in
Fouine" brings the app to the front; the other two work without disturbing
anything, even if Fouine was not open.

**If Fouine has read nothing yet**, the action says so ("Fouine has not indexed
anything yet. Open Fouine and add a folder.") rather than returning an empty
list, which would read as "that word is nowhere".

---

## 14. Keyboard shortcuts

| Shortcut | Action |
|---|---|
| **⌘F** | select the search field in the window |
| **⌥⌘F** | global shortcut: show Fouine and search from any app |
| **⇧⌘E** | export the results of the search |
| **⇧⌘C** | copy the reference to the selected page (name, page, link) |
| **⌥⌘C** | copy every reference of the results loaded |
| **Tab** | move focus from the search field to the results list; ↑ and ↓ then move the selection, ↩ opens |
| **⌘↩** | open the preview of the selected page in its own window |
| **Space** | Quick Look on the selected document, from the results list |
| **⌘G** | PDF preview: go to the next occurrence of your words on the page (Edit ▸ Next occurrence; after the last one, back to the first) |
| **⇧⌘G** | PDF preview: go back to the previous occurrence |
| **⌘?** | open the Fouine guide (Help menu) |
| **⌘,** | open Settings |
| **⌘W** | close the main window (the app stays in the menu bar) |
| **⌘0** | reopen the main window (Window ▸ Open Fouine) |
| **⌘⇧L** | open "All your documents" (Window menu) |
| **⌘Q** | quit the app |

---

## 15. The Help menu

The **Help** menu holds **Fouine Guide** (**⌘?**): it opens, in its own window,
the page you are reading. It ships **with the app**, so no connection is needed
and nothing is asked of the Internet to show it. It exists in English and in
French, and follows the language of the app.

- Internal cross-references stay inside the guide's window.
- A link to a website opens in **your usual browser**, never in the guide's
  window.

**About Fouine** (Fouine menu) gives the version, the sentence that matters,
Fouine reads your documents on this Mac and nothing leaves it, then three links:
**the licence** (source-available, shipped with the app), **the third-party
components** and **the source code** of the project. The first two open files
included in the app; the third opens the project page in your browser.
