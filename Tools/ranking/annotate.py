#!/usr/bin/env python3
# annotate.py — annotation guidée, au terminal, d'un pool produit par pool.py.
#
# Propriété : A-Embed. python3 système, AUCUNE dépendance (règle des trois
# dépendances, CONTRIBUTING.md § Conventions).
#
# Ce que ça fait, en une phrase : présenter un à un les candidats de
# `candidates.tsv`, requête par requête et document par document, avec le
# TEXTE de la page (lu par `fouine mcp --stdio`, en lecture seule), et
# enregistrer la note tapée — 0, 1 ou 2 — dans `grades.tsv`, à côté.
#
# Trois choix qu'il faut connaître :
#
# · **Les jugements vivent dans un fichier À PART** (`grades.tsv`), clé
#   (requête, doc_id, page). La pertinence d'une page pour une requête ne
#   dépend ni du système ni de la date du pool : le même fichier sert à tous
#   les pools qui partagent des requêtes, et survit à une relance de pool.py.
#   Clé sur `doc_id` et non sur le chemin — entre les pools du 03/09 et du
#   05/09/2026, 98 candidats communs s'écrivaient avec ou sans le « / » de tête.
# · **L'ordre de passage est celui du rendement.** D'abord les requêtes dont
#   les systèmes ne rendent pas le même top-k : un candidat classé au même rang
#   partout apporte le même gain à tous les nDCG et ne départage rien. Mesuré
#   le 05/09/2026 sur le pool M1 : 236 lignes sur 350 étaient dans ce cas.
#   `--only-diff` ne montre que celles qui départagent.
# · **Chaque note est écrite tout de suite** (fichier réécrit en entier, puis
#   renommé) : quitter à tout moment ne perd rien, relancer reprend où on en
#   était. Un candidat déjà noté n'est plus proposé, sauf avec `--review`.
#
# Le texte des pages vient de `fouine mcp --stdio`, qui ouvre la base en
# lecture seule et ne prend jamais le verrou : l'outil peut tourner sur la
# base de production pendant que l'agent indexe. Sans binaire, ou avec
# `--no-text`, il reste l'extrait du pool.
#
# Usage :
#   python3 Tools/ranking/annotate.py --dir verif/ranking/2026-09-05 --status
#   python3 Tools/ranking/annotate.py --dir verif/ranking/2026-09-05 --only-diff
#   python3 Tools/ranking/annotate.py --dir … --grades ~/Fouine-verif/ranking/grades.tsv

import argparse
import json
import os
import re
import shutil
import subprocess
import sys
import time
import unicodedata

GRADE_LABELS = {0: "hors sujet", 1: "utile", 2: "ce qu'il fallait"}

# Le barème. Il est écrit ICI, une fois, avant la première note, parce que les
# trois cas qui reviennent partout — sommaire, titre courant, page qui traite —
# ne se jugent pas de la même façon à 9 h et à 17 h si la règle n'est pas
# fixée. Le propriétaire du corpus peut l'amender ; il doit alors le faire
# avant de continuer, pas au milieu.
BAREME = [
    "2  ce qu'il fallait : la page TRAITE le sujet de la requête — elle le",
    "   définit, le développe ou y répond. C'est la page qu'on espérait ouvrir.",
    "1  utile : la page en parle en passant ; on la lirait, mais ce n'est pas",
    "   elle qu'on cherchait.",
    "0  hors sujet : le mot y est dans un autre sens, ou seulement dans un",
    "   sommaire, un index, un catalogue d'éditeur, un titre courant, une page",
    "   de garde. Un livre SUR le sujet ne rend pas toutes ses pages pertinentes.",
    "",
    "On juge la PAGE, pour CETTE requête. Une même page revient sous plusieurs",
    "requêtes : chaque fois sa note. Un candidat sans note vaut 0 dans le calcul",
    "(convention TREC) : passer n'est pas neutre — une requête commencée se",
    "finit. Vingt requêtes bien jugées valent mieux que quarante bâclées.",
]

KEYS_HELP = [
    "0 1 2      noter ce candidat, et passer au suivant",
    "espace     passer sans noter (le candidat restera à faire)",
    "m          la suite du texte de la page",
    "o          ouvrir le fichier d'origine (macOS `open`)",
    "n          attacher une remarque libre à ce candidat",
    "b          revenir au candidat précédent",
    "u          annuler la dernière note de la session et y revenir",
    "j          sauter à la requête suivante",
    "?          cette aide et le barème",
    "q          quitter — tout est déjà enregistré",
]


# ─── Lecture des fichiers du pool ───────────────────────────────────────────


def split_tsv(path):
    """TSV → (en-tête, lignes). Coupe sur les tabulations SEULEMENT.

    Pas de module csv : il mange les guillemets, et `"energie libre"` (la
    requête exacte) se confondrait avec `energie libre` (la requête libre)."""
    with open(path, encoding="utf-8") as handle:
        header = handle.readline().rstrip("\n").split("\t")
        rows = []
        for line in handle:
            if not line.strip():
                continue
            cells = line.rstrip("\n").split("\t")
            cells += [""] * (len(header) - len(cells))
            rows.append(dict(zip(header, cells)))
    return header, rows


def clean(text):
    return " ".join(str(text).replace("\t", " ").split())


class Candidate:
    __slots__ = ("query", "doc_id", "page", "path", "snippet", "ranks",
                 "category", "differs", "pool_grade")

    def __init__(self, row):
        self.query = row["query"]
        self.doc_id = int(row["doc_id"])
        self.page = int(row["page"])
        self.path = row.get("path", "")
        self.snippet = row.get("snippet", "")
        self.pool_grade = row.get("grade", "").strip()
        self.ranks = {}
        for item in row.get("systems", "").split(";"):
            if ":" in item:
                name, rank = item.rsplit(":", 1)
                try:
                    self.ranks[name] = int(rank)
                except ValueError:
                    pass
        self.category = ""
        self.differs = False

    @property
    def key(self):
        return (self.query, self.doc_id, self.page)

    @property
    def best_rank(self):
        return min(self.ranks.values()) if self.ranks else 999

    @property
    def basename(self):
        return os.path.basename(self.path)

    @property
    def abs_path(self):
        return self.path if self.path.startswith("/") else "/" + self.path


class QueryBlock:
    def __init__(self, query, category, pool_index):
        self.query = query
        self.category = category
        self.pool_index = pool_index
        self.cands = []

    def sort(self):
        # Document par document (ouvrir un livre coûte plus qu'une page de
        # plus), les documents dans l'ordre de leur meilleur rang, les pages
        # dans l'ordre du livre.
        best = {}
        for cand in self.cands:
            best[cand.doc_id] = min(best.get(cand.doc_id, 999), cand.best_rank)
        self.cands.sort(key=lambda c: (best[c.doc_id], c.doc_id, c.page))

    @property
    def n_diff(self):
        return sum(1 for c in self.cands if c.differs)


def load_pool(directory):
    """→ (blocs de requêtes dans l'ordre du pool, systèmes, limite)."""
    tsv = os.path.join(directory, "candidates.tsv")
    if not os.path.exists(tsv):
        sys.exit("introuvable : %s (lancez pool.py d'abord)" % tsv)
    _, rows = split_tsv(tsv)

    systems, limit, ordered = [], 10, []
    meta_path = os.path.join(directory, "queries.json")
    if os.path.exists(meta_path):
        with open(meta_path, encoding="utf-8") as handle:
            meta = json.load(handle)
        # pool.py écrit les systèmes en objets {name, args} depuis le 05/09/2026
        # au soir ; les pools antérieurs portent une liste de noms.
        systems = [s["name"] if isinstance(s, dict) else s
                   for s in meta.get("systems", [])]
        limit = int(meta.get("limit", 10))
        ordered = [(q["query"], q.get("category", "")) for q in meta.get("queries", [])]

    blocks, by_query = [], {}
    for query, category in ordered:
        block = QueryBlock(query, category, len(blocks))
        blocks.append(block)
        by_query[query] = block
    for row in rows:
        cand = Candidate(row)
        block = by_query.get(cand.query)
        if block is None:
            block = QueryBlock(cand.query, "", len(blocks))
            blocks.append(block)
            by_query[cand.query] = block
        cand.category = block.category
        block.cands.append(cand)
        for name in cand.ranks:
            if name not in systems:
                systems.append(name)
    for block in blocks:
        for cand in block.cands:
            cand.differs = (len(cand.ranks) < len(systems)
                            or len(set(cand.ranks.values())) > 1)
        block.sort()
    return blocks, systems, limit


# ─── Les jugements ──────────────────────────────────────────────────────────


class Grades:
    COLUMNS = ["query", "doc_id", "page", "grade", "note", "judged_at", "path"]

    def __init__(self, path):
        self.path = path
        self.rows = {}
        if os.path.exists(path):
            header, rows = split_tsv(path)
            for name in ("query", "doc_id", "page", "grade"):
                if name not in header:
                    sys.exit("%s : en-tête sans %s" % (path, name))
            for row in rows:
                if row["grade"].strip() == "":
                    continue
                try:
                    key = (row["query"], int(row["doc_id"]), int(row["page"]))
                    grade = int(row["grade"])
                except ValueError:
                    print("note illisible ignorée dans %s : %r" % (path, row),
                          file=sys.stderr)
                    continue
                self.rows[key] = {
                    "grade": grade,
                    "note": row.get("note", ""),
                    "judged_at": row.get("judged_at", ""),
                    "path": row.get("path", ""),
                }

    def get(self, key):
        return self.rows.get(key)

    def set(self, cand, grade, note=""):
        self.rows[cand.key] = {
            "grade": int(grade),
            "note": clean(note),
            "judged_at": time.strftime("%Y-%m-%dT%H:%M"),
            "path": cand.path,
        }
        self.save()

    def delete(self, key):
        if key in self.rows:
            del self.rows[key]
            self.save()

    def import_pool_column(self, blocks):
        """Les notes déjà posées dans la colonne `grade` de candidates.tsv (au
        tableur, à l'ancienne) entrent dans grades.tsv ; grades.tsv prime."""
        imported = 0
        for block in blocks:
            for cand in block.cands:
                if cand.pool_grade and cand.key not in self.rows:
                    try:
                        grade = int(cand.pool_grade)
                    except ValueError:
                        continue
                    # « pré-remplie » : la colonne peut venir d'un tableur comme
                    # d'un `pool.py --grades` relu depuis un autre fichier — on
                    # ne prétend pas savoir lequel (AUDIT-R1 M7).
                    self.rows[cand.key] = {
                        "grade": grade, "note": "pre-remplie dans candidates.tsv",
                        "judged_at": "", "path": cand.path}
                    imported += 1
        if imported:
            self.save()
        return imported

    def save(self):
        # Réécrit en entier puis renomme : un Ctrl-C au milieu laisse l'ancien
        # fichier intact, jamais un fichier à moitié écrit.
        tmp = self.path + ".tmp"
        with open(tmp, "w", encoding="utf-8") as handle:
            handle.write("\t".join(self.COLUMNS) + "\n")
            for key in sorted(self.rows):
                row = self.rows[key]
                handle.write("\t".join([
                    clean(key[0]), str(key[1]), str(key[2]), str(row["grade"]),
                    clean(row.get("note", "")), row.get("judged_at", ""),
                    clean(row.get("path", "")),
                ]) + "\n")
        os.replace(tmp, self.path)


# ─── Le texte des pages, par le serveur MCP ─────────────────────────────────


class PageReader:
    """Pilote `fouine mcp --stdio` : un processus pour toute la session.

    Lecture seule par construction (SPEC § 5.1, docs/mcp.md) : c'est pour cela
    qu'on passe par lui plutôt que d'ouvrir la base soi-même — l'outil ne
    connaît ni le schéma ni le rowid, et ne risque pas une migration."""

    def __init__(self, binary, database):
        self.error = None
        self.proc = None
        self.next_id = 1
        cmd = [binary, "mcp", "--stdio"]
        if database:
            cmd += ["--db", database]
        try:
            self.proc = subprocess.Popen(
                cmd, stdin=subprocess.PIPE, stdout=subprocess.PIPE,
                stderr=subprocess.DEVNULL, text=True, encoding="utf-8",
                bufsize=1)
            self._call("initialize", {
                "protocolVersion": "2025-06-18", "capabilities": {},
                "clientInfo": {"name": "annotate.py", "version": "1"}})
            self._send({"jsonrpc": "2.0", "method": "notifications/initialized"})
        except FileNotFoundError:
            self.error = "binaire introuvable : %s (voir --fouine)" % binary
        except (OSError, RuntimeError, ValueError) as exc:
            self.error = "serveur MCP indisponible : %s" % exc

    @property
    def ok(self):
        return self.error is None

    def _send(self, obj):
        self.proc.stdin.write(json.dumps(obj, ensure_ascii=False) + "\n")
        self.proc.stdin.flush()

    def _call(self, method, params):
        ident = self.next_id
        self.next_id += 1
        self._send({"jsonrpc": "2.0", "id": ident, "method": method, "params": params})
        while True:
            line = self.proc.stdout.readline()
            if not line:
                raise RuntimeError("le serveur MCP s'est arrêté")
            try:
                message = json.loads(line)
            except ValueError:
                continue
            if message.get("id") != ident:
                continue
            if "error" in message:
                raise RuntimeError(message["error"].get("message", "erreur"))
            return message.get("result", {})

    def read_page(self, doc_id, page):
        """→ (charge utile ou None, message d'erreur ou None)."""
        if not self.ok:
            return None, self.error
        try:
            result = self._call("tools/call", {
                "name": "fouine_read_page",
                "arguments": {"doc_id": doc_id, "page": page,
                              "max_chars": 40000}})
        except (OSError, RuntimeError, ValueError) as exc:
            self.error = "serveur MCP perdu : %s" % exc
            return None, self.error
        content = result.get("content") or []
        text = content[0].get("text", "") if content else ""
        if result.get("isError"):
            return None, text or "erreur d'outil"
        try:
            return json.loads(text), None
        except ValueError:
            return None, "réponse illisible"

    def close(self):
        if self.proc is None:
            return
        try:
            self.proc.stdin.close()
            self.proc.wait(timeout=2)
        except (OSError, subprocess.TimeoutExpired):
            self.proc.kill()


# ─── Surlignage des termes ──────────────────────────────────────────────────


def fold(text):
    """Sans accents ni casse — la même règle que `unicode61 remove_diacritics`."""
    return "".join(c for c in unicodedata.normalize("NFD", text)
                   if not unicodedata.combining(c)).lower()


def fold_with_map(text):
    """→ (texte replié, index[i du replié] = i de l'original)."""
    folded, index = [], []
    for i, char in enumerate(text):
        for fch in fold(char):
            folded.append(fch)
            index.append(i)
    return "".join(folded), index


def query_terms(query, snippet):
    """Les mots à surligner : ceux de la requête (sans opérateurs ni
    exclusions), plus les formes que fouine a marquées « … » dans l'extrait —
    c'est ainsi qu'une coquille (`thermodynamlque`) surligne la vraie forme."""
    terms = set()
    for token in query.split():
        if token.startswith("-") or ":" in token:
            continue
        token = token.strip("\"'«»")
        prefix = token.endswith("*")
        token = fold(token.rstrip("*"))
        if prefix and token:
            terms.add((token, True))
        elif len(token) >= 3:
            terms.add((token, False))
    for match in re.finditer(r"«([^»]+)»", snippet or ""):
        term = fold(match.group(1)).strip()
        if term:
            terms.add((term, False))
    return terms


def find_spans(text, terms):
    """Intervalles [début, fin[ à surligner dans le texte d'origine, fusionnés."""
    if not text or not terms:
        return []
    folded, index = fold_with_map(text)
    spans = []
    for term, prefix in terms:
        pattern = r"(?<!\w)" + re.escape(term) + (r"\w*" if prefix else r"(?!\w)")
        for match in re.finditer(pattern, folded):
            start, end = match.start(), match.end() - 1
            spans.append((index[start], index[end] + 1))
    spans.sort()
    merged = []
    for start, end in spans:
        if merged and start <= merged[-1][1]:
            merged[-1] = (merged[-1][0], max(end, merged[-1][1]))
        else:
            merged.append((start, end))
    return merged


def wrap_ranges(text, width):
    """Découpe en lignes d'écran, en rendant des intervalles sur l'original
    (pas des chaînes) : le surlignage se pose ensuite sans casser la largeur."""
    ranges, pos, blank = [], 0, False
    for line in text.split("\n"):
        start, end = pos, pos + len(line)
        pos = end + 1
        while end > start and text[end - 1] in " \t\r":
            end -= 1
        if end == start:
            if not blank and ranges:
                ranges.append((start, start))
            blank = True
            continue
        blank = False
        i = start
        while i < end:
            if end - i <= width:
                ranges.append((i, end))
                break
            cut = text.rfind(" ", i, i + width + 1)
            if cut <= i:
                cut = i + width
            ranges.append((i, cut))
            i = cut
            while i < end and text[i] == " ":
                i += 1
    return ranges


# ─── L'écran ────────────────────────────────────────────────────────────────


class Screen:
    def __init__(self, color):
        self.tty = sys.stdin.isatty() and sys.stdout.isatty()
        self.color = color and self.tty and not os.environ.get("NO_COLOR")

    def size(self):
        size = shutil.get_terminal_size((100, 32))
        return max(60, size.columns), max(20, size.lines)

    def style(self, text, *codes):
        if not self.color or not codes:
            return text
        return "\033[%sm%s\033[0m" % (";".join(codes), text)

    def bold(self, text):
        return self.style(text, "1")

    def dim(self, text):
        return self.style(text, "2")

    def mark(self, text):
        return self.style(text, "1", "33")

    def clear(self):
        if self.tty:
            sys.stdout.write("\033[2J\033[H")

    def rule(self, width, char="─"):
        print(self.dim(char * width))

    def read_key(self, prompt):
        sys.stdout.write(prompt)
        sys.stdout.flush()
        if not self.tty:
            line = sys.stdin.readline()
            if not line:
                return "q"
            line = line.rstrip("\n")
            print()
            return line[:1] if line else " "
        import termios
        import tty
        fd = sys.stdin.fileno()
        old = termios.tcgetattr(fd)
        try:
            tty.setraw(fd)
            char = sys.stdin.read(1)
        finally:
            termios.tcsetattr(fd, termios.TCSADRAIN, old)
        print()
        if char in ("\x03", "\x04"):
            raise KeyboardInterrupt
        if char in ("\r", "\n"):
            return " "
        return char

    def read_line(self, prompt):
        try:
            return input(prompt)
        except EOFError:
            return ""


def shorten(text, width):
    if width <= 1:
        return ""
    return text if len(text) <= width else text[: width - 1] + "…"


def doc_label(cand):
    name = cand.basename
    stem, _ = os.path.splitext(name)
    return "%s p.%d" % (stem or name, cand.page)


# ─── Les vues ───────────────────────────────────────────────────────────────


def status_table(blocks, systems, grades, only_diff, order="priority"):
    """Le tableau d'avancement, dans l'ordre de passage."""
    lines = []
    ordered = walk_order(blocks) if order == "priority" else [b for b in blocks if b.cands]
    head = "%3s  %-46s %-22s %6s %4s %6s %6s" % (
        "#", "requête", "catégorie", "cand.", "≠", "notés", "reste")
    lines.append(head)
    tot = [0, 0, 0, 0]
    for n, block in enumerate(ordered, start=1):
        cands = [c for c in block.cands if not only_diff or c.differs]
        if not cands:
            continue
        graded = sum(1 for c in cands if grades.get(c.key))
        diff = sum(1 for c in cands if c.differs)
        tot[0] += len(cands); tot[1] += diff; tot[2] += graded
        tot[3] += len(cands) - graded
        lines.append("%3d  %-46s %-22s %6d %4d %6d %6d" % (
            n, shorten(block.query, 46), shorten(block.category, 22),
            len(cands), diff, graded, len(cands) - graded))
    lines.append("%3s  %-46s %-22s %6d %4d %6d %6d" % (
        "", "total", "", tot[0], tot[1], tot[2], tot[3]))
    empty = [b.query for b in blocks if not b.cands]
    if empty:
        lines.append("")
        lines.append("%d requête(s) sans candidat (aucun système n'a rien rendu) : %s"
                     % (len(empty), ", ".join("`%s`" % q for q in empty)))
    return lines


def walk_order(blocks):
    """Les requêtes dans l'ordre de passage : celles qui départagent le plus de
    candidats d'abord, puis l'ordre du pool. Sans candidat : écartées."""
    return sorted((b for b in blocks if b.cands),
                  key=lambda b: (-b.n_diff, b.pool_index))


def show_query_card(screen, block, position, total, systems, limit, grades):
    width, _ = screen.size()
    screen.clear()
    screen.rule(width, "═")
    graded = sum(1 for c in block.cands if grades.get(c.key))
    print(screen.bold("Requête %d/%d · «%s» · %s" % (
        position, total, block.query, block.category or "sans catégorie")))
    print("%d candidat(s) · %d départagent les systèmes · %d déjà noté(s)"
          % (len(block.cands), block.n_diff, graded))
    # Les top-k côte à côte : voir d'un coup ce que chaque système a mis en
    # tête, et où ils divergent (≠), avant de juger page par page. Autant de
    # colonnes que la largeur en loge à 16 caractères : le pool du 05/09/2026
    # a quatre systèmes, et le plafond de trois d'avant les cachait tous.
    col = (width - 6 - 3 * (len(systems) - 1)) // max(1, len(systems))
    if 1 < len(systems) and col >= 16:
        by_rank = {name: {} for name in systems}
        for cand in block.cands:
            for name, rank in cand.ranks.items():
                by_rank[name][rank] = cand
        print()
        print("      " + " │ ".join(screen.bold(shorten(n, col).ljust(col)) for n in systems))
        for rank in range(1, limit + 1):
            cells, keys = [], set()
            for name in systems:
                cand = by_rank[name].get(rank)
                keys.add(cand.key if cand else None)
                cells.append(shorten(doc_label(cand) if cand else "—", col).ljust(col))
            if all(k is None for k in keys):
                break
            marker = screen.mark(" ≠") if len(keys) > 1 else ""
            print("  %2d  %s%s" % (rank, " │ ".join(cells), marker))
    print()
    print(screen.dim("Barème : 2 traite le sujet · 1 en parle en passant · 0 hors sujet "
                     "(sommaire, index, titre courant, autre sens) — ? pour le détail"))
    screen.rule(width, "═")
    return screen.read_key("Entrée pour commencer · j passer cette requête · q quitter  ")


def show_help(screen):
    width, _ = screen.size()
    screen.clear()
    print(screen.bold("Barème"))
    for line in BAREME:
        print("  " + line)
    print()
    print(screen.bold("Touches"))
    for line in KEYS_HELP:
        print("  " + line)
    print()
    screen.rule(width)
    screen.read_key("une touche pour revenir  ")


def highlight(screen, text, spans, start, end):
    """text[start:end] avec les intervalles de `spans` surlignés."""
    out, pos = [], start
    for s_start, s_end in spans:
        if s_end <= start or s_start >= end:
            continue
        a, b = max(s_start, start), min(s_end, end)
        out.append(text[pos:a])
        out.append(screen.mark(text[a:b]))
        pos = b
    out.append(text[pos:end])
    return "".join(out)


class PageView:
    """Le texte d'une page, replié à la largeur de l'écran, feuilletable."""

    def __init__(self, text, terms, width):
        self.text = text or ""
        self.spans = find_spans(self.text, terms)
        self.ranges = wrap_ranges(self.text, width)
        self.top = 0
        self.last_height = 10

    @property
    def matches(self):
        return len(self.spans)

    def render(self, screen, height):
        self.last_height = max(1, height)
        lines = [highlight(screen, self.text, self.spans, start, end)
                 for start, end in self.ranges[self.top: self.top + height]]
        rest = len(self.ranges) - (self.top + height)
        return lines, max(0, rest)

    def advance(self):
        """Page suivante ; au bout, revient au début et rend False."""
        if self.top + self.last_height < len(self.ranges):
            self.top += self.last_height
            return True
        self.top = 0
        return False


def show_candidate(screen, block, index, cand, systems, grades, view, page_info,
                   page_error, progress, pending_note):
    width, height = screen.size()
    screen.clear()
    done, remaining, total = progress
    left = "Requête «%s» · %s" % (block.query, block.category or "sans catégorie")
    right = "noté %d · reste %d · %d au total" % (done, remaining, total)
    left = shorten(left, width - len(right) - 2)
    print(screen.bold(left) + " " * (width - len(left) - len(right)) + screen.dim(right))
    screen.rule(width)
    ranks = " · ".join(
        "%s %s" % (name, ("#%d" % cand.ranks[name]) if name in cand.ranks else "—")
        for name in systems)
    marker = screen.mark("  ≠ départage") if cand.differs else screen.dim("  = même rang partout")
    print("%s  %s" % (screen.bold("[%d/%d]" % (index + 1, len(block.cands))),
                      screen.bold(shorten(cand.basename, width - 10))))
    page_total = ""
    if page_info and page_info.get("page_count"):
        page_total = " / %d" % page_info["page_count"]
    source = ""
    if page_info and page_info.get("source"):
        source = " · texte %s" % page_info["source"]
        if page_info.get("ocr_confidence") is not None and page_info["source"] != "native":
            source += " (%.0f %%)" % (100 * float(page_info["ocr_confidence"]))
    print("        p. %d%s · %s%s%s" % (cand.page, page_total, ranks, marker,
                                        screen.dim(source)))
    folder = os.path.dirname(cand.path)
    print("        " + screen.dim(shorten(folder, width - 8)))
    existing = grades.get(cand.key)
    if existing:
        note = (" — « %s »" % existing["note"]) if existing.get("note") else ""
        print("        " + screen.style(
            "déjà noté %d (%s)%s%s" % (
                existing["grade"], GRADE_LABELS.get(existing["grade"], "?"),
                (" le " + existing["judged_at"]) if existing.get("judged_at") else "",
                shorten(note, width - 40)), "36"))
    if pending_note:
        print("        " + screen.style("remarque en attente : « %s »" % shorten(pending_note, width - 32), "36"))
    snippet_spans = find_spans(cand.snippet, query_terms(cand.query, cand.snippet))
    print("Extrait : " + highlight(screen, cand.snippet, snippet_spans, 0,
                                    min(len(cand.snippet), width - 10)))
    screen.rule(width)
    # Ce qui est déjà à l'écran (7 lignes + les optionnelles), ce qui vient
    # après le texte (compteur, filet, invite sur deux lignes), et la ligne
    # « Page (…) » : le reste est pour le texte.
    used = 7 + (1 if existing else 0) + (1 if pending_note else 0) + 1
    footer = 5
    body = max(5, height - used - footer)
    if view is not None:
        head = ("%d occurrence(s) surlignée(s)" % view.matches if view.matches
                else "aucune occurrence exacte")
        print(screen.dim("Page (%d caractères, %s)" % (len(view.text), head)))
        lines, rest = view.render(screen, body)
        for line in lines:
            print(line)
        if rest:
            print(screen.dim("… %d ligne(s) de plus — m pour la suite" % rest))
        elif view.top:
            print(screen.dim("(fin de la page)"))
    elif page_error:
        print(screen.dim("Texte de la page indisponible : %s" % page_error))
        print(screen.dim("(l'extrait ci-dessus reste ; o ouvre le fichier)"))
    screen.rule(width)
    return screen.read_key(
        "%s hors sujet · %s utile · %s ce qu'il fallait · espace passer\n"
        "%s\n> "
        % (screen.bold("0"), screen.bold("1"), screen.bold("2"),
           screen.dim("m suite · o ouvrir · n note · b retour · u annuler · "
                      "j requête suivante · ? aide · q quitter")))


# ─── La session ─────────────────────────────────────────────────────────────


def open_file(path):
    try:
        subprocess.Popen(["open", path], stdout=subprocess.DEVNULL,
                         stderr=subprocess.DEVNULL)
    except OSError:
        pass


def main():
    parser = argparse.ArgumentParser(
        description="Annotation guidée d'un pool de pool.py : 0 hors sujet, "
                    "1 utile, 2 ce qu'il fallait — dans grades.tsv.")
    parser.add_argument("--dir", required=True, help="répertoire produit par pool.py")
    parser.add_argument("--grades", default=None,
                        help="fichier des jugements (défaut : <dir>/grades.tsv ; "
                             "donnez le même à plusieurs pools pour partager les notes)")
    parser.add_argument("--fouine", default=None,
                        help="binaire pour lire le texte des pages (défaut : celui "
                             "de queries.json, sinon `fouine`)")
    parser.add_argument("--db", default=None,
                        help="base à lire (défaut : celle de fouine) — une copie convient")
    parser.add_argument("--only-diff", action="store_true",
                        help="seulement les candidats qui départagent les systèmes")
    parser.add_argument("--query", default=None,
                        help="une seule requête (texte exact)")
    parser.add_argument("--category", default=None,
                        help="une seule catégorie")
    parser.add_argument("--review", action="store_true",
                        help="repasser aussi sur les candidats déjà notés")
    parser.add_argument("--order", choices=("priority", "pool"), default="priority",
                        help="priority : requêtes qui départagent d'abord (défaut) ; "
                             "pool : l'ordre de queries.txt")
    parser.add_argument("--no-text", action="store_true",
                        help="ne pas lire le texte des pages (extrait seul)")
    parser.add_argument("--no-color", action="store_true")
    parser.add_argument("--status", action="store_true",
                        help="afficher l'avancement et sortir")
    args = parser.parse_args()

    blocks, systems, limit = load_pool(args.dir)
    grades_path = args.grades or os.path.join(args.dir, "grades.tsv")
    grades = Grades(grades_path)
    imported = grades.import_pool_column(blocks)
    screen = Screen(color=not args.no_color)

    pool_mtime = time.strftime("%d/%m/%Y %H:%M", time.localtime(
        os.path.getmtime(os.path.join(args.dir, "candidates.tsv"))))
    n_cands = sum(len(b.cands) for b in blocks)
    n_graded = sum(1 for b in blocks for c in b.cands if grades.get(c.key))

    if args.status or (not args.query and not args.category):
        screen.clear()
        print(screen.bold("Pool") + " : %s (candidates.tsv du %s) · %d système(s) : %s"
              % (os.path.abspath(args.dir), pool_mtime, len(systems), ", ".join(systems)))
        print(screen.bold("Jugements") + " : %s — %d note(s) sur %d candidat(s)%s"
              % (grades_path, n_graded, n_cands,
                 (", %d importée(s) de la colonne grade" % imported) if imported else ""))
        print()
        for line in status_table(blocks, systems, grades, args.only_diff, args.order):
            print(line)
        print()
        if args.status:
            return
        print("Ordre de passage : %s. Une requête commencée se finit — un candidat sans"
              % ("celles qui départagent les systèmes d'abord" if args.order == "priority"
                 else "celui du pool"))
        print("note vaut 0 dans le calcul. ? à tout moment pour le barème et les touches.")
        print()
        if screen.read_key("Entrée pour commencer · q quitter  ") == "q":
            return

    ordered = walk_order(blocks) if args.order == "priority" else [b for b in blocks if b.cands]
    if args.query is not None:
        ordered = [b for b in ordered if b.query == args.query]
        if not ordered:
            sys.exit("requête absente du pool : %r" % args.query)
    if args.category is not None:
        ordered = [b for b in ordered if fold(b.category) == fold(args.category)]
        if not ordered:
            sys.exit("catégorie absente du pool : %r" % args.category)

    positions = []
    for block in ordered:
        for index, cand in enumerate(block.cands):
            if args.only_diff and not cand.differs:
                continue
            if not args.review and grades.get(cand.key):
                continue
            positions.append((block, index))
    if not positions:
        print("Rien à noter : tout est déjà jugé (ou filtré). "
              "python3 Tools/ranking/evaluate.py --dir %s" % args.dir)
        return

    reader = None
    if not args.no_text:
        binary = args.fouine
        if binary is None:
            meta_path = os.path.join(args.dir, "queries.json")
            if os.path.exists(meta_path):
                with open(meta_path, encoding="utf-8") as handle:
                    binary = json.load(handle).get("fouine")
            if not binary or not os.path.exists(binary):
                binary = "fouine"
        reader = PageReader(binary, args.db)
        if not reader.ok:
            print(screen.dim("Texte des pages indisponible (%s) — l'extrait seul sera montré."
                             % reader.error))
            screen.read_key("Entrée pour continuer  ")

    session_graded, history = 0, []
    cursor, current_block, view_cache, pending = 0, None, {}, {}
    try:
        while 0 <= cursor < len(positions):
            block, index = positions[cursor]
            cand = block.cands[index]
            if block is not current_block:
                key = show_query_card(
                    screen, block, ordered.index(block) + 1, len(ordered),
                    systems, limit, grades)
                if key == "q":
                    break
                if key == "j":
                    cursor = next((i for i in range(cursor, len(positions))
                                   if positions[i][0] is not block), len(positions))
                    continue
                if key == "?":
                    show_help(screen)
                    continue
                current_block = block

            width, _ = screen.size()
            if cand.key not in view_cache:
                info, error, view = None, None, None
                if reader is not None:
                    info, error = reader.read_page(cand.doc_id, cand.page)
                    if info is not None:
                        text = info.get("text") or ""
                        if not text and info.get("note"):
                            text = "(%s)" % info["note"]
                        view = PageView(text, query_terms(cand.query, cand.snippet), width - 1)
                view_cache[cand.key] = (info, error, view)
            info, error, view = view_cache[cand.key]

            considered = [c for b in ordered for c in b.cands
                          if not args.only_diff or c.differs]
            done = sum(1 for c in considered if grades.get(c.key))
            key = show_candidate(screen, block, index, cand, systems, grades, view,
                                 info, error, (done, len(considered) - done, len(considered)),
                                 pending.get(cand.key, ""))

            if key in ("0", "1", "2"):
                grades.set(cand, int(key), pending.pop(cand.key, "")
                           or (grades.get(cand.key) or {}).get("note", ""))
                history.append(cursor)
                session_graded += 1
                cursor += 1
            elif key == " ":
                cursor += 1
            elif key == "m":
                if view is not None:
                    view.advance()
            elif key == "o":
                open_file((info or {}).get("abs_path") or cand.abs_path)
            elif key == "n":
                note = screen.read_line("remarque : ")
                existing = grades.get(cand.key)
                if existing:
                    grades.set(cand, existing["grade"], note)
                else:
                    pending[cand.key] = note
            elif key == "b":
                cursor = max(0, cursor - 1)
                current_block = positions[cursor][0]
            elif key == "u":
                if history:
                    cursor = history.pop()
                    undone = positions[cursor][0].cands[positions[cursor][1]]
                    previous = grades.get(undone.key) or {}
                    if previous.get("note"):
                        pending[undone.key] = previous["note"]
                    grades.delete(undone.key)
                    session_graded -= 1
                    current_block = positions[cursor][0]
            elif key == "j":
                cursor = next((i for i in range(cursor, len(positions))
                               if positions[i][0] is not block), len(positions))
            elif key == "?":
                show_help(screen)
            elif key == "q":
                break
    except KeyboardInterrupt:
        print()
    finally:
        if reader is not None:
            reader.close()

    n_graded = sum(1 for b in blocks for c in b.cands if grades.get(c.key))
    print()
    print(screen.bold("Session") + " : %d note(s) posée(s) · %d sur %d candidat(s) du pool sont jugés · %d reste(nt)"
          % (session_graded, n_graded, n_cands, n_cands - n_graded))
    print("Jugements : %s" % grades_path)
    print("Évaluer   : python3 Tools/ranking/evaluate.py --dir %s%s"
          % (args.dir, (" --grades %s" % grades_path) if args.grades else ""))


if __name__ == "__main__":
    main()
