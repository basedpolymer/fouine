# The Fouine guide

Fouine is a search app for macOS. It goes through the folders you give it,
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
| Sidebar (left) | the Index card, the switch that keeps the index up to date, your folders, search options and filters |
| Results (middle) | the documents found, each unfolding page by page with a snippet, your words highlighted, and where the text came from |
| Preview (right) | the selected document, opened at the right page, with the occurrences highlighted |

Until you add a folder, the window shows a welcome screen that asks you to
choose one. Its last line is for people who use an AI assistant: to use Fouine
with Claude, Codex, Antigravity or another assistant, ask the assistant to
install the Fouine MCP server. The **Copy the request for your assistant**
button under that line puts the whole request on the clipboard, ready to paste.
The request contains the command to run, with the real location of Fouine's
command line inside the app, the assistants it configures (Claude Desktop,
Claude Code, Cursor, Codex, Antigravity) and its options, so the assistant needs
nothing else.

The interface appears once the real state of your folders has been read, so
nothing flickers at launch.

If you refuse the permission macOS asks for when you add that first folder, or
if the file permissions forbid reading it, the folder is not added and an alert
explains why. Besides OK, the alert has two buttons: **Open System Settings**,
which goes straight to Privacy & Security ▸ Files and Folders, and **Retry**,
which shows the folder chooser again. A folder that is missing or empty gets
neither button, since there is nothing to allow.

The index opens at launch, whether the window shows or not. If Fouine starts
with your session and without a window, the menu bar panel can still search.

### Dropping a folder on Fouine's icon

When you drag a folder from the Finder and drop it on Fouine's icon in the Dock,
the result depends on whether Fouine already indexes it.

- If the folder is watched, or sits inside a watched folder, the window comes
  forward and the search field receives the folder filter, with the cursor after
  it, ready for the rest of your query. No search starts. The filter uses the
  label of the watched folder rather than the subfolder you dropped, because the
  filter only knows the folders in your list.
- If no watched folder contains it, a question appears: "Search “Invoices” with
  Fouine?", "Fouine will index this folder and keep it up to date.", with **Add
  this folder** and **Cancel**. A folder dropped on the folder list in the
  sidebar is added without a question, because there you aim at the list. On
  the Dock icon you aim at the app, where the same gesture could mean "search".
  Several folders dropped at once share one question. Once added, the folder is
  handled like one added from the sidebar: an update starts right away.

A file dropped on the icon does nothing, and no message appears: Fouine searches
folders and does not open documents. Fouine is not in the "Open with" menu of a
folder either. Double-clicking a folder still opens it in the Finder; the Dock
icon only accepts the drop.

### The search field

The field says "Search your documents". Its tooltip and its spoken help give the
syntax: quotes for an exact phrase, an asterisk for a prefix, a hyphen before a
term to exclude it. Three common mistakes would otherwise find nothing, so a
line under the field names them:

| What you typed | What appears |
|---|---|
| `"energy` | A quote is not closed. |
| `near:` (or `near:` followed by a single word) | `near:` expects two words. |
| `-energy` | A search that only excludes finds nothing. |

A search that simply finds nothing shows no such line. The line only points out
a mistake in how the query is written.

### When nothing is found

Under "No result for “…”", the window offers the buttons that can still bring
something back, and only those:

- **Tolerate typos**, if **Typos** is set to "off";
- **Remove the filters**, if a filter, a facet or a scope is active;
- **Search by meaning too**, if the model is ready and the **Also search by
  meaning** switch is off.

Then comes the sentence "Try fewer words, or check the spelling." Each button
changes the setting it names and runs the search again. No setting changes
unless you click one. In this state, empty facet sections stay hidden so they
don't push those buttons out of sight.

### What you can do with a result

- Right-click: "Show in Finder", "Open" (in its usual app), "Search inside this
  document", and, only if pages of that document are waiting to be read, "Read
  its scanned pages first". Also "Open the preview in its own window" and "Copy
  a reference to this page".
- Drag a line to Mail, a Finder folder or a bibliography app: what you drop is
  the file itself.
- Press Space on the selected line for macOS Quick Look, as in the Finder.
- Double-click, or press ⌘↩, to open the page in its own preview window.

The toolbar buttons (sort, export, "Within results") and the buttons of the
preview are not in the Tab cycle. That is normal macOS behaviour while System
Settings ▸ Keyboard ▸ "Full Keyboard Access" is off. With it on, Tab reaches
them all.

### The counts, and the list

Above the list, a line gives what was found and how long it took ("29 037 pages
in 776 documents · 120 ms").

When **Also search by meaning** is on, the two searches don't start together.
The search by words runs first and its results appear; the search by meaning
runs next. Meanwhile the counts stay readable, with a spinner beside them and
"searching by meaning…", or, the very first time, "preparing the meaning search:
the first one takes a few seconds…". When the search by meaning returns, the
list is re-ranked: the two searches are merged, the order changes, and pages
that contain none of the words you typed can appear. Until then, "Load more"
waits, since one more slice would land in a list that is about to be rebuilt.
Typing again cancels both searches.

Each document found shows, to the right of its name, how many of its pages are
in the list. The best pages of each document come first, so that a single
six-hundred-page book does not fill the screen. A book with three hundred
matching pages therefore shows only a few.

In that case the count becomes a link: "3 of 300 pages · See them all". Clicking
it restricts the search to that document and lists every page found in it,
first to last. A chip "in “document name”" appears under the search field, and
closing it returns the search to all your folders. While the chip is there, the
count is plain text again, and further pages come with "Load more" at the bottom
of the list.

The count shows only what has been counted. Until every matching page of the
document has been counted, it reads "pages loaded" and nothing more. When
everything is on screen, it shows one number and no link.

The lines carry no percentage such as "relevance: 47 %". That figure would
compare a page's score with the best score of the slice loaded, so it would
change at every "Load more" and mean something different from one search to the
next. The order of the documents, and the "Found because…" line under the
selected result, are what the list shows instead.

---

## 2. The preview

The right-hand pane shows the page found. Its header gives the document's name
and, under it, the shortened path, as in the results list. The full path is in
the tooltip and nowhere else.

The preview takes one of four forms, depending on the document:

| What you see | For which documents |
|---|---|
| The page of the PDF, with the words highlighted | `.pdf` |
| An image of the page, rendered from the file | comic archives, `.docx`, `.pptx`, `.xlsx`, images, Figma and InDesign files |
| The document as macOS draws it | `.rtf`, `.doc`, `.odt`, Pages, Numbers, Keynote, web pages, `.csv`, `.tsv`, `.svg`, `.ai`, old `.xls` and `.ppt` |
| The text Fouine kept, with your words picked out | everything else: EPUB, DjVu, notebooks, subtitles, mailboxes, text and code files |

When both exist, a **Document | Text** selector above the preview switches
between them. "Document" is what the Finder's space bar shows: the layout, the
pictures, the colours. Your search words are not highlighted there, because
macOS draws that page and Fouine cannot mark it; the selector's tooltip says so.
Your choice applies to every document until you quit Fouine. It is not saved in
the settings, so a choice made months ago cannot change what you see without you
noticing.

For the documents macOS draws (`.rtf`, `.doc`, `.odt`, Pages, web pages…),
"Document" mode always starts at the first page: macOS does the rendering and
offers no way to ask it for a page. A PDF opens at the page found, because
Fouine draws it.

**Open the document** (the button at the top right of the preview) opens the
file in the app the Finder would use, at the page shown when that app can go
there. Only PDFs can: page 3 of an e-book depends on the text size the reader
chose, and page 3 of a recording is a ten-minute slice that exists only in
Fouine.

| What opens your PDFs | What happens |
|---|---|
| Preview, the macOS reader | the document opens at its first page |
| Chrome, Edge, Brave, Vivaldi, Opera, Arc, Firefox | the document opens at the page found |
| Safari | the document opens at its first page |
| another reader | the document opens as a double-click would open it |

Preview cannot open a PDF at a given page: macOS offers no way to ask it, and
Fouine cannot work around that. The button's tooltip reflects this: "Open in
the default application — at page 412 when it can". When the page cannot be
requested, the document opens as usual, with no message and no wait. If anything
prevents opening at the page, the document still opens, at its start.

To have your PDFs open at the page found, change the app that opens PDFs: in the
Finder, right-click a PDF ▸ "Get Info" ▸ "Open with" ▸ choose the browser ▸
"Change All".

Under the page number, a line counts how many times each of your words appears
on the page: a dot in the word's colour, the word, then the count, as in
"nitrogen 3". A word and the forms searched alongside it ("polymer",
"polymers") share one colour and one count; a word absent from the page has no
dot. Five words fit on the line, and the rest are in the tooltip. "400+" means
highlighting stopped at 400 occurrences of that word on the page.

On a PDF page, the same line shows "3 / 27" and two chevrons. ⌘G goes to the
next occurrence and ⇧⌘G to the previous one; the same commands are in Edit ▸
**Next occurrence** and **Previous occurrence**. Occurrences follow reading
order, top to bottom then left to right, and the one you reach is selected. The
walk stays inside the page: after the last occurrence you come back to the
first, and you scroll the PDF to change page. On a page read from an image, each
line where a word was found counts once. In Text mode only the dots appear,
because that pane cannot scroll to a word, and a "3 / 27" counter there would
offer a jump that cannot happen.

Audio and video files open in a player, with the transcript below. The text is
cut into paragraphs, each with its timestamp ("12:40"), and each paragraph is a
button that moves the player to that passage. Opening a result puts the playhead
at the start of the passage found without starting playback, so no sound goes
off unexpectedly in a room or on a train. The previous and next page arrows move
through the recording in ten-minute slices, like the pages of a book.

When the drive is unplugged, the preview shows the text kept in the index, with
one line: "The disk holding “Books” is not plugged in. Here is the text Fouine
kept.", and a **Copy this text** button. The other pages of the document stay
readable, because their text comes from the index and not from the disk.

When the search is restricted to one document, the **Leave this document**
button returns it to all your folders.

Detached preview windows follow two rules. These are the windows opened by a
double-click, from the menu bar panel or by a `fouine://` link. There is one
window per document: a second link to the same book changes the page of its
window and brings it forward. And there are three at most: beyond that, the
least recently used window takes the new document. A PDF of several hundred
pages uses memory; three open side by side is useful, ten forgotten during the
day is a problem.

A link cited a year ago may name page 99 999 of a document that has since been
shortened. The first page then opens, with the message "Page 99 999 no longer
exists in this document."

**Read this page again** (right-click on the page) appears only when the text of
the page shown was read from an image, which the header already says next to the
page number. A page whose document contained the text, or a page transcribed
from audio, has no image to read again.

When you click it, the page goes back into the queue and a line appears under
the preview: "This page will be read again next time the scans are read. Its
text will only change if you have just ticked its language in Settings ▸
Indexing." Nothing starts right away: the next reading of scanned pages picks it
up. If the index is busy with a write, the line says "The index is being
updated. Try again in a moment." It disappears when you change page.

---

## 3. Taking results away

### Exporting (⇧⌘E, or the share button above the list)

The save panel offers three formats and states what will be exported: "Export:
200 lines — the results currently loaded, out of 29 037 pages found." The export
contains the loaded results, in the order shown, with the sort and filters
applied. It never contains more than what you have seen on screen.

| Format | What for |
|---|---|
| CSV (spreadsheet) | Numbers, Excel, LibreOffice. Columns `path, page, score, snippet, root, modified, link`, in English and stable: this is data, for a script to read. |
| JSON (script) | the same fields, for automatic processing. |
| Markdown (notes) | a notebook (Obsidian, Bear, Notion), a Word document, a bibliography. |

The Markdown file has a title, then one line per page found:

```
# Fouine — chloride (3 results)

- [Organic Chemistry — volume 2.pdf, page 87](fouine://open?…) — … the snippet …
```

The clickable reference is exactly the one "Copy the reference" gives, and the
snippet is cut at two hundred characters. There is no table and no technical
header, so the file pastes straight into a notebook.

**Copy every reference** (⌥⌘C, in the Edit menu, under "Copy the reference to
this page") puts one reference per loaded result on the clipboard, in the order
shown. With no results, the menu item is disabled.

### Sorting

The sort menu above the list orders documents by relevance (the default), by
modification date (newest or oldest first), by file name or by path.

When you choose any order other than relevance, the whole set is loaded before
sorting. Sorting only the first two hundred results of a twenty-nine-thousand
page corpus would give the most relevant ones reordered, not the two hundred
most recent, and "the most recent document about X" would have no answer. While
it loads, the line under the counters says "Loading every result before sorting
them…". The selector stays active, and going back to relevance stops the
loading.

Loading stops at two thousand results, a few seconds on the reference corpus.
Beyond that, a line gives the real extent of the sort: "Sorted by date ↓ over
the first 2 000 results, out of 29 037 pages found." When everything fits under
the limit, the line disappears. A new search stops the loading.

Search by meaning does not paginate: it returns a complete set, so its sort
always covers everything.

### Saved searches

The history (the clock icon, to the right of the field) keeps the last forty
queries, then forgets them. To keep "my 2025 invoices" from one month to the
next, choose its first item, **Save this search…**. The query itself is offered
as the name, and you can replace it.

Saved searches appear in the sidebar, in the **Saved searches** section above
the quick filters, when there are any. A click runs the search again, and a
right-click offers **Rename…** and **Remove**. Drag one up or down to change its
place; the new order is kept. You can keep fifty at most, and beyond that the
oldest one goes.

The query is saved exactly as you typed it, prefixes included: `folder:Invoices
2025`, `"exact phrase"` and `-draft` stay as they are. The filters ticked in the
sidebar are not saved. They are one click away, and their values depend on the
documents indexed at the time: a folder selection saved last year might match no
document today, and the search would return nothing without saying why.

---

## 4. The Index card

At the top of the sidebar, the Index card shows the essentials: what Fouine is
doing, whether the index is up to date, and whether something is expected of
you. It holds only this:

- a state sentence ("Up to date", "Reading scanned pages"…) and, under it, a
  detail when there is one ("Updated 3 min ago", "They will be read once the Mac
  is plugged in.");
- during a job, a progress bar and, when it can be estimated, the time left
  ("about 2 h left"). The current document and the page count change
  constantly, so they are in the "Your index" window instead;
- at most one button, when you need to do something;
- the disk space sentence, only when the disk may run out of room before the job
  ends;
- on the last line, the **Details…** link, which opens the **Your index**
  window, where everything else is.

Under the card is the **Keep the index up to date automatically** switch.

The **Stop** button responds at once. When you click it, it turns inactive, a
small spinner appears next to the sentence, and the sentence says what is being
waited for: "Stopping — finishing “course.mp4”…" when one document is being
read, "Stopping — 3 documents are finishing…" when there are several. Fouine
reads up to four documents at a time, and the wait lasts a few seconds. A
reading in progress stops between two pages (PDF, DjVu) or while a recording is
being written down, without running to the end. A document stopped this way is
neither read nor failed: it stays to be done, and the next update starts it from
the beginning. Nothing is lost and nothing is half written. Reading scanned pages
and preparing search by meaning stop the same way, with their own sentences.

### States of the card

The card shows one state at a time, chosen in this order: checking, no folder, a
pass started from the app, an action expected from you, another program
writing, automatic updates, up to date.

| Title | Second line | Meaning | Button |
|---|---|---|---|
| Checking… | none | the state of the index is being read at launch | none |
| No folder to index | none | no folder has been added | Add a folder… |
| Updating the index | the time left when known | going through the folders, extracting text | Stop *(pass started from the app)* |
| Reading scanned pages | "about 2 h left" | recognising the text of scanned pages | Stop *(idem)* |
| Preparing search by meaning | the time left when known | preparing the pages for search by meaning | Stop *(idem)* |
| The index is being updated | "Another program is writing to the index; searching still works." | the command line is updating the index | none |
| Up to date — N scanned pages to read | "They will be read once the Mac is plugged in." (or: once Low Power Mode is off, once the Mac has cooled down, once the other program has finished, once every folder can be read again) | the text is current; reading scanned pages waits for the Mac | none *("Read scanned pages…" is in the "Your index" window)* |
| Fouine is not allowed to read “…” | "Its documents stay searchable. Allow Fouine in System Settings ▸ Privacy & Security ▸ Files and Folders…" | macOS refuses to read the folder | Allow access… |
| The disk holding “…” is not plugged in | "Its documents stay searchable. Plug the disk in…" | the folder is on an absent drive | Check again |
| Automatic updates are waiting for your approval | "Allow Fouine in System Settings ▸ General ▸ Login Items & Extensions." | macOS is waiting for your confirmation | Open System Settings |
| Automatic updates are not starting | "Restarting them usually fixes it…" | the service never reported, or stopped | Restart automatic updates |
| Several copies of Fouine are installed | "Keep only the one in the Applications folder…" | two copies of Fouine.app are installed | Restart automatic updates |
| Automatic updates are unavailable | "Fouine must be installed in the Applications folder…" | the app is not installed in Applications | Show in the Finder *(the copy to drop into Applications)* |
| Up to date | "Updated 3 min ago" | nothing to do | none |
| Up to date — N scanned pages to read | "They are read automatically when the Mac is plugged in and idle." | the text is current, the scanned pages will follow | none |
| Manual updates (— N scanned pages to read) | "Fouine only updates the index when you ask." | automatic updates are off | Update now |

A service that is running but has been silent for a few minutes (after the Mac
wakes from sleep, for example) shows as "Up to date", not as broken. Only a
service that never reported, or whose process has disappeared, leads to
"Automatic updates are not starting".

### What the trial adds to the card

During the trial, a discreet line at the bottom of the card reads "Trial: 12
days left · Buy". That line is the only reminder: nothing opens at launch and
nothing counts down in large letters. The rest of the card shows what it would
show anyway.

When the trial ends, the card replaces its action button with the sentence
"Your trial is over: searching still works, the index is no longer updated" and
two buttons, **Enter licence key…** and **Buy**. The **Update now** button
disappears, since it could no longer do anything.

The switch does not change. Automatic updates stop by themselves, and greying out
the switch would need an explanation right where the card has just given one.

If the seller disabled your key, the card says "This key was disabled by the
seller" and the same two buttons come back.

---

## 5. The Your index window

Open it with the **Details…** link of the Index card, or with **Window ▸ Your
index**. There is only one such window: opening it again brings back the
existing one. It reads everything again when it opens, then stays current while
Fouine is in front. During an index update its counts follow along: they are
read again every ten seconds at most, and once more when the update ends.

The window has four parts, which cover what the card leaves out.

**What Fouine is doing** shows the card's state sentence with its complete
detail, including the current document, the progress bar and the page count
("312 / 1 200 pages · about 2 h left"). The buttons of that state are here too:
the card's button and, second, a **Read scanned pages…** link when scanned pages
are waiting. A button that opens a sheet brings the main window forward first.

**Automatic updates** holds the same **Keep the index up to date
automatically** switch as the one under the card, with the sentence that
explains it ("Fouine checks your folders from time to time and updates the index
by itself, even when its window is closed."). It also shows the answer to your
last change, confirmations included ("Automatic updates are on. macOS may ask
you to confirm in System Settings ▸ General ▸ Login Items."), and where to set
the moments it works: Settings ▸ Indexing ▸ When to update automatically.

**What the index holds** lists:

- "1 527 documents · 408 951 pages", two numbers grouped the same way. The line
  is a link that opens "All your documents". It stays plain text while the
  statistics are loading, or when the index is empty, since a list with no
  lines would show nothing.
- When some documents could not be read, "23 unreadable documents", which opens
  the window that lists them, with the explanation "These files are in your
  folders, but Fouine could not read them. Your files are untouched."
- When automatic updates read new pages while Fouine was closed, "Since your
  last visit: 4 200 new pages". The line stays for the whole session and has no
  close box, since you opened this window to read it.
- The space left on the disk, only when it is running short (below).

The disk space line appears only when space is running out on the disk that
holds the index. The index is never compared with an "expected size": that
figure comes from the design documents, and anyone who hasn't read them would
take a "planned" number for a limit.

| Situation | Sentence | Where |
|---|---|---|
| more than 5 GB free | *no line* | nowhere |
| less than 5 GB free | "Your disk has 3.2 GB left; your index uses 2.15 GB" | the "Your index" window |
| less than 1 GB free, or less than what preparing search by meaning still has to write | "Your disk has only 800 MB left and your index uses 2.15 GB: Fouine may run out of room to finish it. Free up some space, or remove a folder you no longer need" | the window and the Index card |

Nothing ever stops because of that line: indexing, reading scanned pages and
preparing search by meaning all continue. It is a warning, and the system will
refuse to write on the day the disk is actually full. There is no button either,
because the fix is to free space or remove a folder, which the sentence says.
The free space shown is the one macOS promises for a large write, the Finder's
figure, purgeable space included, read at the same time as the index counts. If
the volume does not answer, no line appears rather than a wrong figure. Sizes are
written the way the Finder writes them ("2.15 GB").

**Scanned pages without readable text** appears only when there are such pages.
A scanned page can have been read without giving reliable text. Its document is
in the index, so these pages are not counted as "unreadable documents". There
are two cases, one line each:

```
3 157 scanned pages with no text Fouine could recognize
    Usually blank pages, pictures or drawings.
1 053 scanned pages read with uncertain letters
    Faint or skewed scans, handwriting, unusual fonts: a search may miss some
    of their words.
```

There is no button to read them again. They were read as well as possible:
another reading goes through the same recognition, with the same settings, and
returns the same result. Measured on a real index, queueing them again leaves the
same pages in place once the queue has drained.

Reading again changes something in one case only: a document written in a
language that is not ticked in **Settings ▸ Indexing ▸ Languages of the scanned
documents**. Tick the language, then right-click the page in the preview and
choose **Read this page again**. The line under the preview says so too.

On the command line, `fouine ocr requeue [--doubtful|--no-lines]` always queues
those pages again, and both counts are in `fouine status`.

---

## 6. All your documents

Open it with the count in the "Your index" window, or with **Window ▸ All your
documents (⌘⇧L)**. There is only one such window: opening it again brings back
the existing one. It contains:

- a **Filter by name** field (it searches the name and the folder; the list is
  read again 300 ms after the last keystroke);
- a **Folder** menu (your watched folders, or "All folders");
- a **Type** menu (the extensions actually present, most frequent first, or "All
  types");
- an order menu: **Recent** (default), **Name**, **Pages**;
- the count of everything that matches the filters, not only what is on screen;
- the list, in slices of 200, with "Load more (N left)".

Each line shows the file name, the shortened folder, the number of pages and the
date in plain words ("Modified yesterday"). The full path stays in the tooltip.
Documents that could not be read are in the list, with a sentence giving the
reason: this window exists to show them. Documents still waiting show "Not read
yet: it will be at the next update".

A click opens the document's preview at its first page, in its own window, with
the same rules as elsewhere: one window per document, three at most. A
right-click offers "Show in Finder", "Open" and "Search inside this document";
the last one closes the window and sets the scope in the main window.

When nothing matches, the window says "No document matches".

The same list is available on the command line with `fouine list`.

---

## 7. Keeping the index up to date

The **Keep the index up to date automatically** switch, just under the Index
card, hands the watching of your folders over to the system. It is the same
switch as in the "Your index" window, with the same name.

When you flip it, no sentence appears underneath: the card already shows the new
state, and waiting for macOS to agree has its own state ("Automatic updates are
waiting for your approval"). Only a refusal appears there. The switch then turns
back off, and the sentence gives the reason: no folder ("Add a folder first:
there would be nothing to keep up to date."), folders not yet allowed, or Fouine
installed somewhere other than the Applications folder. The "Your index" window
keeps the answer to the last change, confirmations included.

When a document is created, modified or deleted in an indexed folder, the change
reaches the index within seconds.

To spare the battery and the machine, reading scanned pages waits until:

1. the Mac is plugged in;
2. Low Power Mode is off;
3. the Mac is not hot;
4. no other program is writing to the index;
5. every folder can be read.

The first three are settings (Settings ▸ Indexing). When one condition fails, the
card names it ("They will be read once the Mac is plugged in."), and reading
resumes by itself afterwards. To skip the wait, click **Read scanned pages…** in
the "Your index" window: it starts a pass now, for a duration you choose.

What runs in the background, its log and its settings: the "Keeping the index up to date" page of the documentation.

---

## 8. The menu bar

Fouine has an icon in the macOS menu bar. The icon changes with what the index
is doing, and has three shapes:

| Icon | When | What the panel's state line says |
|---|---|---|
| Magnifier | nothing running: up to date, manual updates, paused, no folder, checking | "Up to date", "Manual updates", "No folder to index" |
| Circular arrows | the index is working | "Updating the index", "Reading scanned pages", "Preparing search by meaning" |
| Triangle | an action is expected from you | "Fouine is not allowed to read “…”", "Automatic updates are waiting for your approval"… |

A change of shape tells you something is happening; the panel's state line says
what. VoiceOver reads the icon as that same state sentence, never as "icon".

Click the icon to open a small panel. The cursor is already in the field, so you
can type straight away.

- Results arrive as you type, after a quarter of a second without a keystroke.
  One line is one page: the file name, its page number, and the snippet on one
  line. Pages of the same document follow each other. If you turned **Search as
  I type** off (§ 11), typing no longer searches: the first ↩ searches in the
  panel, and the next one opens the window with the same query.
- The panel lists eight pages at most. When there are more, a **Show all in
  Fouine** line closes the panel and puts the query in the window, where the
  filters, the facets and the preview are.
- Clicking a page opens it in its own preview window, the same one a
  double-click on a result opens, at the same page, with the same highlights.
- ⌘-click opens the file in its usual app.
- ↑ and ↓ move through the lines, and ↩ opens the one selected; with no line
  selected, ↩ sends the query to the main window.
- Escape closes the panel. ⌘Q quits Fouine.

This panel searches only the words of your documents. Search by meaning needs a
model to load, so it stays in the window: a panel has to answer at once. The
panel leaves the main window alone, and its filters, selection and query stay as
they are. The global shortcut ⌥⌘F always opens the window.

Under the results come a state line and two buttons, nothing else. The line is
the Index card's state sentence, in grey, with no button; it explains the shape
of the icon. Then come **Open Fouine**, which shows the main window or brings it
forward (also in the Window menu, ⌘0), and **Quit Fouine**. When automatic
updates are on, a tooltip on **Quit Fouine** notes that the index keeps updating
after Fouine is closed. When they are off, there is no tooltip, since nothing
would be running. ⌘Q works from the panel, but its glyph is not shown there: a
menu bar panel is not a menu, and macOS draws no shortcuts in it.

Closing the window does not quit Fouine. With the menu bar option on, closing the
window hides the Dock icon and leaves the app in the menu bar. **Open Fouine** or
⌥⌘F brings the window back. A setting also lets Fouine start with your session,
directly in the menu bar, without opening a window.

---

## 9. Search options and filters

### Typos

A three-position selector sets how much spelling and recognition mistakes are
tolerated:

| Option | Behaviour |
|---|---|
| off | strict word-for-word search |
| auto (default) | tolerance only when a word gives no exact result |
| always | search always widened to close variants |

### Also search by meaning

Search by meaning finds passages whose subject matches your query, even when they
share no words with it. The **Also search by meaning** switch merges the pages
found by your words with the pages found by meaning. If your documents have not
been prepared for it yet, a button starts the preparation. How it works, and how
well: the "Searching" page of the documentation.

### Filters

Under the search field, five sections narrow the results:

- **Folders**: by folder;
- **File types**: by format (PDF, DOCX, EPUB…);
- **Languages**: by the document's language (the section appears once there are
  two languages);
- **Text origin**: typed text, pages scanned and read by Fouine, recognition done
  before Fouine, and speech transcribed from a recording. These four names are
  the same everywhere: in the facet, the preview header, the icon on a line, and
  for the screen reader;
- **Modified in**: the year the file was last changed, not the year of the work.
  A book from 2003 copied onto the Mac in 2024 is filed under 2024, and the
  section's tooltip says so.

**Dated** appears above **Modified in** as soon as results carry a date of their
own: the year written in the document itself (PDF, Word, EPUB, email, photo).
Ticking a year keeps only those documents. Like **Modified in**, it only filters
what is displayed, and its tooltip says so.

Each section shows at most twelve values, those with the most results; beyond
that a line says "Only the first 12 are shown". Every section runs the search
again and updates the totals, except **Modified in** and **Dated**, which only
filter the results already shown.

Text origin is the only section that applies to single pages, because one book
can mix typed pages and scanned plates. The **Scans only** quick filter sets
exactly the same filter.

### Quick filters

Above the facets, four chips cover the most common filters: **Modified this
year**, **Modified in the last 5 years**, **PDF only**, **Scans only**. The date
windows are calendar years. The chips and the facets share the same state, so
unticking "pdf" in File types turns the **PDF only** chip off, and **Clear all**
removes them all.

### Why this result

Under the snippet of the selected result, and only that one, a grey line gives
the reason the page is there: "Found because this page contains “kinetics” and
“chemistry”.", "Found with a close spelling: “converslon” → “conversion”.",
"None of your words is on this page, but it deals with the same subject.",
"Found by your words and by meaning."

The line shows no number. The words quoted are yours, and a term you excluded is
never named, since that would show exactly what you asked to leave out.

---

## 10. Citing a page

You can cite a page found: its name, its page number, and a link that leads
straight back to it. That is how you send someone, or yourself six months later,
to the right page of a thousand-page book.

Two places offer it, with the same wording: the **Copy a reference to this
page** button in the preview pane, and the submenu of the same name when you
right-click a result line. From the keyboard, ⇧⌘C (Edit ▸ **Copy the reference
to this page**) acts on the selected result.

Each offers **Copy the reference** and **Copy the link**. The reference is two
lines:

```
Organic Chemistry — volume 2.pdf, page 87
fouine://open?path=/Users/…/Organic%20Chemistry.pdf&page=87
```

The link is alone on its line on purpose: Mail, Notes, Pages and Word only make
an address clickable when nothing follows it. For the same reason, brackets in a
file name are written `%28` and `%29`: one academic book in two has its year in
brackets, and those same apps cut an address at a closing bracket.

A page of audio or video is cited by its moment. "Page 2" of a two-hour lecture
sends nobody anywhere, so the reference gives the moment, and the link carries
it:

```
chemistry lecture 12 March.m4a, 12:40
fouine://open?path=/Users/…/chemistry%20lecture.m4a&page=2&t=760
```

The `t` parameter is a number of seconds from the start of the recording: where
the playhead was when you copied the reference. When the link is opened, the
player is set there without starting. Only the app writes `t`; `fouine search
--json` and the assistant server cite the page.

A `fouine://` link, clicked from any app, brings Fouine forward and opens the
page in its own preview window. When the link also carries the search that led
to that page, the search runs again in the document and the words are
highlighted again.

A link cited last year may name a document that has since been moved, renamed,
or taken out of the watched folders. The window then shows "Fouine does not know
this document", with the file name. An index update fixes most of those cases.

The **Open the file** button appears only for a document Fouine could have
indexed: an ordinary file, inside one of the folders you watch, and not a
program. A link can come from anywhere, a web page or an email, and its author
chooses the path it carries. So Fouine opens only documents that live in your
folders, and never an app, a folder or a script. When a file exists at that path
but doesn't meet those conditions, the window says "It is outside the folders
Fouine watches, so Fouine will not open it." and shows no button. (An `.rtfd`
package is technically a folder, but it is a document and opens normally.)

The link also appears in exported results (the `link` column), in `fouine search
--json` and in the assistant server's answers. That is how an assistant can cite
a page of your documents in a way you can check.

---

## 11. Settings

Settings open with ⌘, and have seven tabs.

### General

- **Keep Fouine in the menu bar** (on by default) keeps the icon in the menu bar
  and stops Fouine from quitting when the window closes. Its description reads:
  "The small icon at the top of the screen lets you search your documents and
  open Fouine. It also shows what the index is doing."
- **Search as I type** (on by default): "Results appear as you type. Off, press
  Return to search." The setting applies to the window and to the menu bar
  panel, from the next keystroke. When it is off, typing only suggests words
  under the field, and ↩ runs the search. Filters, results and history stay the
  same.
- **Open Fouine when I log in** starts the app in the background at login.
- **Tell me when the scanned pages are all read** posts a macOS notification when
  the queue empties. The permission is requested first, and the box is ticked
  only if macOS agrees. If the request is ignored or refused, or the permission
  is withdrawn later in System Settings, the box goes back to unticked, with the
  line "macOS hasn't allowed Fouine's messages yet" and an **Open System
  Settings** button under it. The state is read again each time the tab opens, so
  the box is never ticked when no notification can arrive.
- **Spotlight**: see § 12.
- **Keyboard shortcut**: a reminder of ⌥⌘F.

### Licence

This is the second tab, right after General. It is the one you open after
buying, and the only place where you deal with the end of the trial.

- The state, in one sentence: "Trial: 12 days left", "Your trial is over:
  searching still works, the index is no longer updated", "Licensed — key ending
  in ·····XYZ456" with the date of the last check, "This key was disabled by the
  seller", or, when the monthly check finds that you released this Mac from your
  customer portal, "This Mac was released from your customer portal. Enter your
  key again to use it here."
- A **Licence key** field and an **Activate** button, inactive while the field is
  empty. The field accepts what you paste: spaces, line breaks and lower case are
  cleaned up before sending.
- A **Buy Fouine — €39** button, which opens the payment page in your browser.
  Fouine never asks for a card number itself.
- Once the key is in, the field is replaced by **Deactivate this Mac**, which
  asks for confirmation: "This Mac will stop counting toward your 3 activations.
  You can activate it again later."
- Refusals appear under the field, each as one sentence with the step to take:
  "No connection: connect to the Internet and try again.", "This key is not
  recognised. Check for typos, or look for it in the e-mail Creem sent you.",
  "This key is already in use on 3 Macs. Deactivate one of them from Settings, or
  from your Creem customer portal.", "The licence service is unavailable right
  now. Your trial continues; try again later."
- The bottom of the tab lists what is sent and when, like the Updates tab: the
  key and the name of this Mac, at activation, at release, and during one
  background check a month. Nothing is sent while Fouine indexes or searches.
  Details: the "Privacy" page of the documentation.

The **Fouine ▸ Enter licence key…** menu item opens this tab directly, and
**About Fouine** shows the state in one line.

### Folders

- The list of your folders with their name and location, and buttons to add or
  remove one.
- For each folder: **Read its scanned pages first** (that folder's scanned pages
  go ahead of the others), and **What Fouine skips…** (below).
- The box on the left turns the folder on or off.
- When a setting is greyed out (Fouine outside the Applications folder, a value
  forced by the environment), the reason is written under the control, not only
  in a tooltip.

Under each folder, **What Fouine skips…** opens a sheet that lists, in plain
words, what is left out of that folder: "The folder “Health”", "Every .md file",
"Files named “INDEX.md”". A cross next to a line removes it. Three buttons add
one, without typing any pattern:

- **Skip a folder…** opens a folder picker on that folder; choose a folder
  inside it. Choosing the folder itself is refused ("That is the whole folder. To
  stop indexing it, untick it in the list."), and so is a folder elsewhere.
- **Skip a kind of file** is a menu of the kinds of file present in that folder,
  the most numerous first, each with its count.
- **Skip files named…** shows a field for one file name, such as `INDEX.md`.

Something already skipped is not added twice: the sheet says "Fouine already
skips this." Before you save, one sentence gives the effect: "About 41 documents
will leave the index at the next update. Your files are not touched." Removing a
line shows "What you no longer skip comes back at the next update." Nothing
changes until you click **Save**. Then, if automatic updates are off, **Update
now** applies the change at once; if they are on, the change is applied within a
few minutes.

Fouine writes nothing into your folder. The rules are kept in Fouine's own
index, so they go away if you remove the folder from Fouine (unticking it keeps
them). A small file named `.fouineignore` at the top of a folder also works, for
a folder you share or copy to another Mac. It has one line per thing to leave
out: a folder name followed by a slash (`Health/`), a kind of file (`*.md`), or
the exact name of a file (`INDEX.md`). Its lines appear in the same sheet, greyed
out, with "from the .fouineignore file in this folder" and no cross: Fouine only
reads that file, so you remove a line by editing it. Both sets of rules apply
together. What they name leaves the index, and searches stop finding it. Your
files are never touched, only what the index holds about them.

Under the folder list, the **Applications** section has one box per app whose
notes Fouine can read: **Apple Notes**, **Bear** and **Anki**. When a box is
ticked, Fouine copies the text of the notes into its own folder so it can search
them. The line under the boxes says so, and says that nothing leaves this Mac.
Unticking deletes the copies and removes the notes from the index; your notes
themselves are never modified. Under each box, the state appears in plain words:
"not installed on this Mac" (the box is greyed out), "Fouine is not allowed to
read these notes" with an **Open System Settings** button, or "N notes
searchable". Apple Notes keeps its notes in a protected place, which requires
Full Disk Access, a different pane from "Files and Folders".

Adding the folder of Anki, Apple Notes or Bear with "Add a folder…" does not
work: the alert tells you to tick the application here instead, and its **Open
Settings** button opens this tab.

These notes appear as they are in their app, never as Fouine's copy: a note found
shows its title and the icon of Notes or Bear, and opens in its app. In the
preview, the "Show in Finder" button becomes **Open in Notes** (or **Open in
Bear**), because the note is what you want to edit. The preview shows its text.
Quick Look, dragging the result away and "Open" are not offered, since they
would only show Fouine's copy. In "Your folders" and in the list above, the
folder of an application shows that application's icon. Its menu has no "Show in
Finder", "Rename" or "Remove": you turn the application off here, with its box.

Anki flashcards come in one deck at a time: each deck is one document in the
list, under its name, with the Anki icon and its parent decks shown above it
("Anki › Chemistry"). Its pages are its cards: the list says "card 12" and "74
cards", the preview "card 3 of 642", and a copied reference cites the card. A
search that matches forty cards of the same deck therefore shows that deck once,
with "See them all" to go through the cards. The name of a deck is not treated
as a word of its cards; look for a deck by its name, as you would a file. Anki
can stay open while Fouine reads it, and a card added a minute ago is found at
the next update. In the preview, the button becomes **Open in Anki**. Anki for
Mac cannot open a given card from outside, so the button opens Anki, where the
card is one search away. The preview shows the text of the card, then its
pictures, read from Anki's own folder; a picture deleted in Anki is simply not
shown. The words inside a picture are not searched, only the text of the card.
Sounds, hints and tags stay in Anki.

Notion and Craft have no box, because their notes cannot be read on this Mac.
Export your pages as Markdown, then add the export folder with "Add a folder…". A
page exported from Notion reopens in Notion from the preview.

### Indexing

- **When to update automatically**: three conditions you can tick (only when the
  Mac is plugged in, not in Low Power Mode, not when the Mac is hot).
- **Also prepare search by meaning in the background**, unticked by default.
  When it is ticked, Fouine prepares what search by meaning needs, in short
  stretches and under the same three conditions, once every scanned page has
  been read. A sentence under the box says when that will happen, or, if the
  model is not downloaded yet, where to get it.
- **Languages of the scanned documents**: the languages expected on scanned
  pages, most likely first. They are also the languages used to write down
  recordings. Each language appears under its name, in alphabetical order, with
  the technical code in the tooltip.
- **Index images (photos, scans, camera RAW files)**, on by default. When it is
  ticked, the photos, scans and RAW files in your watched folders enter the index
  and go through text recognition. Two sentences under it give the limits: each
  image goes through text recognition, which can keep Fouine busy for hours on a
  large photo folder; and Fouine reads the text of photographed documents (a
  receipt, a letter, a page), while shop signs, labels and decorative lettering
  often escape it.
- **Index audio and video files (titles, artists, chapters…)**, on by default;
  untick it if a watched folder is a music library rather than a set of
  documents. When it is ticked, the titles, artists, albums, lyrics and chapters
  of a recording become searchable without playing a second of it. Under it,
  **Also write down what is said in them**, also on by default, transcribes the
  speech on this Mac; nothing is sent anywhere. Count roughly the length of the
  recording. The language must be installed in System Settings ▸ Keyboard ▸
  Dictation, otherwise the document is set aside with a message saying so.
  **Longest recording to write down (minutes)** limits the effort (120 by
  default; beyond it, only the metadata is indexed). One page is ten minutes of
  recording, each paragraph headed by its `[mm:ss]` timestamp.

### Search by meaning

This tab holds the switch that turns search by meaning on, the state of the model
(a single 220 MB download, stored on your Mac), the number of pages prepared and
a **Prepare search by meaning…** button. When the preparation runs in the
background (the box above ticked, the model installed, automatic updates on), the
button is replaced by "Fouine takes care of it in the background, when the Mac
is plugged in and idle.": the work goes on, and there is nothing to click.

### Updates

The tab has a **Check for updates…** button and a switch for periodic checks,
off by default. No personal data and nothing about your documents is ever sent.
When a check fails (no network, no answer from the server), the "Last check"
line says "could not reach the server", and the tab adds: "Fouine could not
check whether a newer version exists. Try again later. Fouine keeps working as
it is." Details: the "Updates" page of the documentation.

### Advanced

- How much Fouine does at once: how many documents it reads together, how many
  scanned pages, and how many documents when it works in the background.
- The length of a recognition batch, in minutes.
- How often the state is checked again, in seconds.
- The scope of typo tolerance: scanned pages only, or the whole index.
- **Install the command line tool…**: creates the symlink.
- **Open the activity log**: opens the diagnostic file.
- The location and size of the index, with a button to show it in the Finder.

---

## 12. Fouine in Spotlight

Spotlight, the magnifier at the top right of the screen (⌘-Space), cannot read
every document: a scanned PDF, a DjVu, a comic or a mail archive gives it no
text. Fouine has read those documents, so it hands their text to Spotlight, and
Spotlight shows them like any other result.

Spotlight then shows the file name, the first lines of the text and the name of
the folder Fouine watches. Clicking the result opens Fouine at the page where
your words are when Spotlight passes on what you typed, and at the first page
otherwise. Spotlight also searches file names, which Fouine does not, so the
documents handed over become findable by name too.

By default, only documents Spotlight cannot read are handed over. Handing over an
ordinary `.docx` or `.pdf`, which macOS already reads, would show two results for
the same file. So Fouine hands over documents with at least one page from text
recognition, recordings whose speech was written down (Spotlight reads the title
of a video, never what is said in it), and the formats measured as unreadable by
Spotlight (`.djvu`, `.cbz`, `.cbr`, `.epub`, `.ai`, `.sketch`, `.fig`, `.indd`).
The second radio button, **Every document Fouine has read**, lifts that
restriction.

**Update Spotlight now** erases what Fouine had handed over and hands everything
over again. It is the only way to remove from Spotlight a document deleted from
the disk since, because the index keeps no trace of deletions. **Remove Fouine's
documents from Spotlight** (with confirmation) puts the Mac back exactly as it
was: your documents are untouched, and Fouine still finds them.

Under the two buttons, a line confirms the last handover: "Last handover on
<date> · <N> documents", read from the index itself. Without a count (a handover
made by an earlier version of Fouine), only the date appears; before the first
handover, or after a removal, the line says "Not handed over yet". It is the
only check possible from outside, because `mdfind` does not query the Spotlight
index Fouine feeds.

The handover runs by itself at the end of every index update, and every time
Fouine opens. The `fouine` command and background updates cannot reach
Spotlight: what they index is handed over the next time the app opens.

Fouine hands over at most one megabyte of text per document, as whole pages,
never a page cut in the middle. On the reference corpus (1 527 documents, mostly
scanned books) the first handover sends 561 MB to Spotlight in 25 seconds, in
the background. After that, each update touches only what changed and takes
milliseconds. The limit is a command-line setting (`spotlight.text_kb`).

Nothing leaves the Mac: Spotlight's index is local, like Fouine's, and
uninstalling removes the documents handed over before erasing anything (see the
"Privacy" page of the documentation).

---

## 13. Fouine in Shortcuts and Siri

The **Shortcuts** app that comes with macOS chains actions together. Fouine adds
three actions, which appear as soon as it is installed when you type "Fouine" in
the action list.

| Action | What it takes | What it returns |
|---|---|---|
| Search in Fouine | what you are looking for, and how many results (10 by default, 50 at most) | a list of pages found |
| Open in Fouine | a page found | nothing: Fouine opens on that page |
| Get the text of a page | a page found | the text Fouine read on that page |

Each page found carries its file name, its page, a snippet, the folder it comes
from, its path and its Fouine link: six variables you can drag into the next
action.

A first chain finds a page and opens it: *Search in Fouine* → "crosslinking
kinetics", then *Choose from list*, then *Open in Fouine*. A second turns a
course into notes: *Search in Fouine* → "electrolysis", 5 results, then *Repeat
with each*, then *Get the text of a page*, then *Create note* (Notes), or *Send
email*, or *Add to clipboard*.

On macOS 26 and later, the same actions are offered directly in Spotlight: press
⌘-Space, type "Fouine", and "Search in Fouine" is there.

You can also start them with Siri: "Hey Siri, search Fouine", or "Hey Siri,
search my documents with Fouine". Siri starts the action, then Shortcuts asks
what to search for, because a spoken phrase cannot carry a free word, only a
list of choices known in advance.

These actions read the index only, never the original file: "Get the text of a
page" returns the text Fouine extracted or recognised, not the PDF. They index
nothing and change nothing. Like the window's search by words, they search the
text without search by meaning, whose model takes two seconds to load, which is
too long for a shortcut. Only "Open in Fouine" brings the app to the front; the
other two run without disturbing anything, even when Fouine was not open.

If nothing has been indexed yet, the action returns a message ("Fouine has not
indexed anything yet. Open Fouine and add a folder.") rather than an empty list,
which would read as "that word is nowhere".

---

## 14. Keyboard shortcuts

| Shortcut | Action |
|---|---|
| ⌘F | select the search field in the window |
| ⌥⌘F | global shortcut: show Fouine and search from any app |
| ⇧⌘E | export the results of the search |
| ⇧⌘C | copy the reference to the selected page (name, page, link) |
| ⌥⌘C | copy every reference of the results loaded |
| Tab | move focus from the search field to the results list; ↑ and ↓ then move the selection, ↩ opens |
| ⌘↩ | open the preview of the selected page in its own window |
| Space | Quick Look on the selected document, from the results list |
| ⌘G | PDF preview: go to the next occurrence of your words on the page (Edit ▸ Next occurrence; after the last one, back to the first) |
| ⇧⌘G | PDF preview: go back to the previous occurrence |
| ⌘? | open the Fouine guide (Help menu) |
| ⌘, | open Settings |
| ⌘W | close the main window (the app stays in the menu bar) |
| ⌘0 | reopen the main window (Window ▸ Open Fouine) |
| ⌘⇧L | open "All your documents" (Window menu) |
| ⌘Q | quit the app |

---

## 15. The Help menu

The **Help** menu holds **Fouine Guide** (⌘?), which opens the page you are
reading in its own window. The guide ships with the app, so it needs no
connection. It exists in English and French, and follows the language of the
app.

- Links inside the guide stay in the guide's window.
- A link to a website opens in your usual browser, never in the guide's window.

**About Fouine** (Fouine menu) shows the version and the sentence "Fouine reads
your documents on this Mac and nothing leaves it.", then three links: the
licence (source-available, shipped with the app), the third-party components and
the source code of the project. The first two open files included in the app;
the third opens the project page in your browser.
