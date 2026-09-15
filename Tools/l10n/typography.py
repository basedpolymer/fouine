#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""Pose la typographie française sur les valeurs `fr` des catalogues (lot L2).

Deux constats de l'audit du 09/09/2026, mesurés sur le catalogue compilé du
bundle :

  · BU-10 — 233 valeurs françaises sur 802 portaient l'apostrophe DROITE
    (`'`, U+0027) là où macOS écrit « barre d’outils » : une signature
    d'amateur sur chaque fenêtre d'un produit vendu.
  · AP-20 — 178 ponctuations doubles (`: ; ? !`) précédées d'une espace
    ORDINAIRE (U+0020), aucune d'une insécable : dans la barre latérale
    (230 pt) et dans le panneau des réglages, un retour à la ligne renvoyait
    le « : » seul en début de ligne.

POURQUOI UN SCRIPT, ET PAS UNE CORRECTION À LA MAIN. Le catalogue reçoit des
chaînes à chaque lot, et une correction manuelle serait défaite au premier
`add-strings.py` suivant — ou perdue au premier conflit de fusion. Cette passe
est REJOUABLE et IDEMPOTENTE : la relancer sur un catalogue déjà propre ne
change rien, et la relancer après un ajout ne corrige que l'ajout. C'est aussi
ce qui permet à l'orchestrateur de la rejouer sur la version de `main` du
catalogue plutôt que de fusionner un diff de 250 lignes.

    python3 Tools/l10n/typography.py            # corrige les deux catalogues
    python3 Tools/l10n/typography.py --check     # ne touche à rien, sort 1 s'il reste à faire

CE QU'ELLE NE TOUCHE PAS. Les CLÉS (le texte anglais : ce sont des clés de
code, engendrées par le compilateur depuis les littéraux Swift), les valeurs
ANGLAISES (l'anglais n'a ni apostrophe courbe imposée ni espace avant sa
ponctuation), et l'intérieur des spécificateurs de format (`%@`, `%lld`,
`%1$@`, `%#@n@`, `%arg1`) — la valeur est découpée sur eux, et seuls les
morceaux de PHRASE sont réécrits.

Le fichier est modifié LIGNE À LIGNE, jamais réécrit par `json.dump` : Xcode
range les clés selon une collation ICU qu'aucun `sorted()` de Python ne
reproduit, et une réécriture produirait un diff de 20 000 lignes (voir
add-strings.py).
"""
import json
import os
import re
import sys

ROOT = os.path.abspath(os.path.join(os.path.dirname(os.path.abspath(__file__)),
                                    "..", ".."))
CATALOGS = [
    os.path.join(ROOT, "Sources", "FouineApp", "Resources",
                 "Localizable.xcstrings"),
    os.path.join(ROOT, "Packaging", "InfoPlist.xcstrings"),
]

# L'espace fine insécable — celle que macOS et les règles typographiques
# françaises mettent devant `: ; ? !`. U+00A0 (insécable normale) ferait le
# même travail de non-coupure mais dessine un blanc trop large devant un
# deux-points dans un libellé court.
NARROW_NBSP = " "
CURLY = "’"

# Un morceau à NE PAS réécrire : spécificateur de format, référence de
# substitution (`%#@total@`) ou argument substitué (`%arg1`).
SPECIFIER = re.compile(
    r"%#@[^@]+@"
    r"|%arg\d*"
    r"|%(?:\d+\$)?[-+ #0]*[0-9]*(?:\.[0-9]+)?(?:lld|ld|lf|[@dfs])")

DOUBLE_PUNCTUATION = re.compile(r" +([:;?!])")


def fix_phrase(text):
    """La typographie française sur un morceau de phrase (hors format)."""
    return DOUBLE_PUNCTUATION.sub(NARROW_NBSP + r"\1", text.replace("'", CURLY))


def fix_value(value):
    """La typographie française sur une valeur de catalogue entière."""
    out, last = [], 0
    for match in SPECIFIER.finditer(value):
        out.append(fix_phrase(value[last:match.start()]))
        out.append(match.group(0))
        last = match.end()
    out.append(fix_phrase(value[last:]))
    return "".join(out)


def strings_and_braces(line):
    """Les chaînes JSON de la ligne, et ses accolades HORS chaîne.

    Un mini-parseur suffit : chaque ligne d'un `.xcstrings` porte au plus une
    paire clé/valeur, mais une clé peut contenir `{`, `}` ou `"` échappé —
    « Fouine {n} » ou une phrase avec des guillemets — et un `str.count("{")`
    naïf déséquilibrerait alors la pile."""
    items = []
    i = 0
    while i < len(line):
        c = line[i]
        if c == '"':
            j = i + 1
            while j < len(line):
                if line[j] == "\\":
                    j += 2
                    continue
                if line[j] == '"':
                    break
                j += 1
            items.append(("str", json.loads(line[i:j + 1])))
            i = j + 1
            continue
        if c in "{}[]:,":
            items.append(("sym", c))
        i += 1
    return items


VALUE_LINE = re.compile(r'^(\s*"value"\s*:\s*)("(?:[^"\\]|\\.)*")(,?)\s*$')


def rewrite(path, language="fr"):
    """Corrige les valeurs d'une langue. Rend (lignes, [(clé, avant, après)])."""
    with open(path, encoding="utf-8") as handle:
        lines = handle.read().split("\n")

    stack = []          # les noms des objets ouverts, du plus externe au plus interne
    key = None          # la clé de catalogue courante (le texte anglais)
    changes = []
    out = []
    for line in lines:
        # `stack` décrit l'état AVANT cette ligne : une ligne de valeur est
        # dans la langue si la pile contient « localizations » puis le code.
        in_language = False
        for depth, name in enumerate(stack):
            if (name == "localizations" and depth + 1 < len(stack)
                    and stack[depth + 1] == language):
                in_language = True
                break

        match = VALUE_LINE.match(line)
        if in_language and match:
            before = json.loads(match.group(2))
            after = fix_value(before)
            if after != before:
                changes.append((key, before, after))
                line = (match.group(1) + json.dumps(after, ensure_ascii=False)
                        + match.group(3))
        out.append(line)

        pending = None
        for kind, item in strings_and_braces(line):
            if kind == "str":
                pending = item
            elif item in "{[":
                stack.append(pending)
                pending = None
                # Niveau 2 = une clé de catalogue (`{` racine, puis `strings`).
                if len(stack) == 3 and stack[1] == "strings":
                    key = stack[2]
            elif item in "}]":
                if stack:
                    stack.pop()
            elif item == ",":
                pending = None
    return out, changes


def main(argv):
    check = "--check" in argv[1:]
    total = 0
    for path in CATALOGS:
        rel = os.path.relpath(path, ROOT)
        if not os.path.exists(path):
            print("typography : %s introuvable." % rel, file=sys.stderr)
            return 1
        lines, changes = rewrite(path)
        total += len(changes)
        if not changes:
            print("typography : %s — rien à corriger." % rel)
            continue
        apostrophes = sum(before.count("'") for _, before, _ in changes)
        spaces = sum(len(DOUBLE_PUNCTUATION.findall(before))
                     for _, before, _ in changes)
        print("typography : %s — %d valeur(s) fr : %d apostrophe(s) droite(s), "
              "%d espace(s) avant une ponctuation double."
              % (rel, len(changes), apostrophes, spaces))
        for key, before, after in changes[:8]:
            print("    « %s »\n      %s\n      %s" % (key, before, after))
        if len(changes) > 8:
            print("    … et %d autre(s)." % (len(changes) - 8))
        if not check:
            with open(path, "w", encoding="utf-8") as handle:
                handle.write("\n".join(lines))
            # Le catalogue doit rester du JSON valide : une ligne de valeur mal
            # recomposée se verrait ici, pas trois lots plus tard.
            json.load(open(path, encoding="utf-8"))
    if check and total:
        print("typography : %d valeur(s) à corriger — lancez "
              "`python3 Tools/l10n/typography.py`." % total, file=sys.stderr)
        return 1
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv))
