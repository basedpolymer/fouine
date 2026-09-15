#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""Vérifie que rien de visible n'échappe aux catalogues (palier 3.2, audit U1).

Cinq contrôles, et chacun correspond à une façon dont la traduction se perd
dans un projet qui en a une :

  1. TOUTE clé des deux catalogues a une traduction `fr` à l'état `translated`.
     Une clé ajoutée sans traduction se voit à l'écran, en anglais, au milieu
     d'une fenêtre française — et personne ne s'en aperçoit avant un
     utilisateur.

  2. TOUTE chaîne visible de Sources/FouineApp/** existe dans le catalogue de
     l'app. C'est le contrôle qui compte : il attrape la prochaine
     contribution qui écrira `Text("Nouveau bouton")` sans passer par
     Sources/FouineApp/Resources/Localizable.xcstrings.

  3. TOUTE traduction emploie, à chaque position, le MÊME TYPE d'argument que
     sa clé. Une clé en `%@` traduite par `%lld` fait lire à Foundation le
     pointeur de la chaîne comme un entier : l'app a affiché
     « 105 553 137 941 168 pages encore à reconnaître » (04/09/2026). Le
     contrôle 2 est aveugle à ça — il réduit `%@`, `%lld` et `\\(x)` au même
     jeton —, celui-ci compare le catalogue à lui-même.

  4. Les clés TCC de Packaging/Info.plist sont TOUTES dans
     Packaging/InfoPlist.xcstrings. Une description d'usage sans traduction
     est une boîte de dialogue système en anglais chez un francophone — celle
     qui demande l'accès à ses documents, et qu'il refusera.

  5. TOUTE valeur française est écrite comme du français : apostrophe courbe,
     espace fine insécable devant `: ; ? !`, aucune parenthèse d'accord
     (« ignoré(s) »). L'audit du 09/09/2026 a compté 233 apostrophes droites
     et 178 espaces ordinaires dans le catalogue livré (BU-10, AP-20, AP-19) :
     ce n'est pas un détail sur un produit vendu, et rien ne le voyait.
     `python3 Tools/l10n/typography.py` pose les deux premières.

Le rapprochement entre source et catalogue se fait sur la FORME : les
interpolations Swift (`\\(x)`) et les spécificateurs de format (`%@`, `%lld`,
`%.2f`) sont réduits au même jeton, parce que la source ne dit pas le type et
que le catalogue ne dit pas l'expression.

    python3 Tools/l10n/lint.py        # 0 = tout va bien
"""
import json
import os
import re
import sys

ROOT = os.path.abspath(os.path.join(os.path.dirname(os.path.abspath(__file__)),
                                    "..", ".."))
APP = os.path.join(ROOT, "Sources", "FouineApp")
APP_CATALOG = os.path.join(APP, "Resources", "Localizable.xcstrings")
PLIST_CATALOG = os.path.join(ROOT, "Packaging", "InfoPlist.xcstrings")
INFO_PLIST = os.path.join(ROOT, "Packaging", "Info.plist")

HOLE = "\x01"

# Les positions où SwiftUI et Foundation cherchent une clé de catalogue. Un
# littéral qui suit IMMÉDIATEMENT l'une d'elles est une chaîne visible ;
# `Text(verbatim:)`, `Label(uneVariable, …)` et `accessibilityIdentifier`
# n'en sont pas, et le « ( guillemet » collé les écarte tout seul.
MARKERS = [
    "String(localized: ",
    "Text(", "Button(", "Label(", "Toggle(", "Picker(", "Section(",
    "TextField(", "Stepper(", "LabeledContent(", "Window(", "Menu(",
    ".help(", ".alert(", ".navigationTitle(",
    ".accessibilityLabel(", ".accessibilityHint(", ".accessibilityValue(",
    # Les fonctions d'assistance de l'app qui prennent une `LocalizedStringKey`
    # (compteurs de la feuille d'indexation, pas-à-pas et cases des réglages,
    # sections de facettes).
    "counter(", "check(", "title: ",
    # Les actions Raccourcis (App Intents, lot INT-R1) : titre d'une intention
    # (`static var title: LocalizedStringResource = "…"`), sa description
    # (`IntentDescription("…")`), le nom d'un type d'entité, la description
    # d'un paramètre (`@Parameter(title: "…", description: "…")`) et le résumé
    # (`Summary("Open \(\.$hit) in Fouine")`, dont la clé de catalogue s'écrit
    # `Open ${hit} in Fouine` — voir `shape_of_key`).
    "LocalizedStringResource = ", "IntentDescription(",
    "TypeDisplayRepresentation(name: ", "description: ", "Summary(",
]

FORMAT = re.compile(r"%(?:\d+\$)?[-+ #0]*[0-9]*(?:\.[0-9]+)?(?:lld|ld|lf|[@dfs])")


# Le trou d'un résumé d'action Raccourcis : `${hit}`, `${query}` — la forme
# sous laquelle App Intents cherche la clé d'un `Summary("… \(\.$hit) …")`.
PARAMETER_REF = re.compile(r"\$\{[A-Za-z_][A-Za-z0-9_]*\}")


def shape_of_key(key):
    """La forme d'une clé de catalogue : les spécificateurs de format et les
    paramètres `${nom}` des résumés Raccourcis deviennent des trous."""
    return FORMAT.sub(HOLE, PARAMETER_REF.sub(HOLE, key))


def shape_of_literal(text):
    """La forme d'un littéral Swift : interpolations ET spécificateurs de
    format deviennent des trous — un littéral passé à `String(format:)` porte
    ses `%.2f` en clair, là où le catalogue les a comme clé."""
    out = []
    i = 0
    while i < len(text):
        if text[i] == "\\" and i + 1 < len(text) and text[i + 1] == "(":
            depth = 0
            j = i + 1
            while j < len(text):
                if text[j] == "(":
                    depth += 1
                elif text[j] == ")":
                    depth -= 1
                    if depth == 0:
                        break
                j += 1
            out.append(HOLE)
            i = j + 1
            continue
        out.append(text[i])
        i += 1
    return FORMAT.sub(HOLE, "".join(out))


def ternary_literals(segment):
    """Les deux branches d'un ternaire de littéraux, `cond ? "A" : "B"`.

    Supporte les ternaires sur une seule ligne ainsi que multilignes où les
    branches `? "A"` et `: "B"` sont séparées par des retours à la ligne.
    """
    if "?" not in segment:
        return []
    out = []
    for m in re.finditer(r'\?\s*"', segment):
        start = m.end() - 1
        text, _ = read_literal(segment, start)
        if text:
            out.append(text)
    for m in re.finditer(r':\s*"', segment):
        start = m.end() - 1
        text, _ = read_literal(segment, start)
        if text:
            out.append(text)
    return out


def first_argument(lines, line_idx, start):
    """Le premier argument d'un appel : de `start` à la virgule de même niveau
    (ou à la parenthèse fermante), potentiellement étendu sur plusieurs lignes."""
    depth = 0
    out = []
    for i in range(line_idx, min(line_idx + 10, len(lines))):
        cur = lines[i] if i > line_idx else lines[i][start:]
        j = 0
        while j < len(cur):
            c = cur[j]
            if c == '"':
                lit, end = read_literal(cur, j)
                if lit is not None:
                    out.append(cur[j:end])
                    j = end
                    continue
            if c in "([{":
                depth += 1
            elif c in ")]}":
                if depth == 0:
                    return "".join(out)
                depth -= 1
            elif c == "," and depth == 0:
                return "".join(out)
            out.append(c)
            j += 1
    return "".join(out)


def second_argument(lines, line_idx, start):
    """Le second argument d'un appel : après la première virgule de niveau zéro."""
    depth = 0
    comma_idx = -1
    comma_col = -1
    for i in range(line_idx, min(line_idx + 10, len(lines))):
        cur = lines[i] if i > line_idx else lines[i][start:]
        col_offset = 0 if i > line_idx else start
        j = 0
        while j < len(cur):
            c = cur[j]
            if c == '"':
                lit, end = read_literal(cur, j)
                if lit is not None:
                    j = end
                    continue
            if c in "([{":
                depth += 1
            elif c in ")]}":
                if depth == 0:
                    return None
                depth -= 1
            elif c == "," and depth == 0:
                comma_idx = i
                comma_col = col_offset + j + 1
                break
            j += 1
        if comma_idx >= 0:
            break
    if comma_idx < 0:
        return None
    return first_argument(lines, comma_idx, comma_col)


def read_literal(line, start):
    """Lit le littéral Swift qui commence au guillemet d'indice `start`.

    Rend `(texte brut avec ses échappements, indice après le littéral)`, ou
    `(None, …)` si le littéral n'est pas fermé sur la ligne (auquel cas ce
    n'est pas une chaîne d'interface : celles-ci tiennent sur une ligne, voir
    docs/i18n.md)."""
    i = start + 1
    out = []
    while i < len(line):
        c = line[i]
        if c == "\\" and i + 1 < len(line):
            nxt = line[i + 1]
            if nxt == "(":          # interpolation : recopiée telle quelle
                depth = 0
                j = i + 1
                while j < len(line):
                    if line[j] == "(":
                        depth += 1
                    elif line[j] == ")":
                        depth -= 1
                        if depth == 0:
                            break
                    j += 1
                if j >= len(line):
                    return None, len(line)
                out.append(line[i:j + 1])
                i = j + 1
                continue
            out.append({"n": "\n", "t": "\t", '"': '"', "\\": "\\"}.get(nxt,
                                                                       nxt))
            i += 2
            continue
        if c == '"':
            return "".join(out), i + 1
        out.append(c)
        i += 1
    return None, len(line)


def swift_literals():
    """Les chaînes visibles des sources de l'app : {forme: [emplacements]}."""
    found = {}
    for base, _dirs, files in os.walk(APP):
        for name in sorted(files):
            if not name.endswith(".swift"):
                continue
            path = os.path.join(base, name)
            rel = os.path.relpath(path, ROOT)
            # Un tableau de `LocalizedStringKey` (l'argumentaire de l'écran
            # d'accueil, les intervalles de Sparkle) porte des littéraux qu'aucun
            # marqueur ne précède : on les prend tous, jusqu'au crochet fermant.
            in_key_array = False
            # Un accesseur `var localizedStringResource: LocalizedStringResource {`
            # (les messages d'erreur d'une action Raccourcis) rend ses chaînes
            # par `return "…"` sous un `switch` : aucun marqueur ne les précède,
            # on prend tous les littéraux du bloc, jusqu'à l'accolade fermante
            # à la même indentation que l'ouverture.
            in_resource_block = False
            resource_indent = 0
            with open(path, encoding="utf-8") as handle:
                lines = handle.readlines()
            for number, line in enumerate(lines, 1):
                line_idx = number - 1
                stripped = line.lstrip()
                if stripped.startswith("//") or stripped.startswith("///"):
                    continue
                if "LocalizedStringKey" in line and "[" in line:
                    in_key_array = True
                elif in_key_array and stripped.startswith("]"):
                    in_key_array = False
                indent = len(line) - len(stripped)
                if (not in_resource_block and "LocalizedStringResource {" in line
                        and "var " in line):
                    in_resource_block = True
                    resource_indent = indent
                    continue
                if (in_resource_block and stripped.startswith("}")
                        and indent <= resource_indent):
                    in_resource_block = False
                if in_key_array or in_resource_block:
                    at = 0
                    while True:
                        at = line.find('"', at)
                        if at < 0:
                            break
                        text, end = read_literal(line, at)
                        at = end if text else at + 1
                        if text:
                            found.setdefault(shape_of_literal(text),
                                             []).append(
                                "%s:%d  %s" % (rel, number, text[:70]))
                    continue
                for marker in MARKERS:
                    at = 0
                    while True:
                        at = line.find(marker + '"', at)
                        if at < 0:
                            break
                        start = at + len(marker)
                        text, _end = read_literal(line, start)
                        at = start + 1
                        if not text:
                            continue
                        found.setdefault(shape_of_literal(text), []).append(
                            "%s:%d  %s" % (rel, number, text[:70]))
                # Ternaires et arguments non immédiats (y compris multilignes).
                for marker in MARKERS:
                    at = 0
                    while True:
                        at = line.find(marker, at)
                        if at < 0:
                            break
                        start = at + len(marker)
                        at = start
                        if start < len(line) and line[start] == '"':
                            continue

                        # Cas particulier : check(...) dans les réglages où
                        # LocalizedStringKey est le second argument.
                        if marker == "check(" and (rel.endswith("SettingsView.swift") or "SettingKeys" in line):
                            arg2 = second_argument(lines, line_idx, start)
                            if arg2:
                                s2 = arg2.strip()
                                if s2.startswith('"'):
                                    text, _ = read_literal(s2, 0)
                                    if text:
                                        found.setdefault(shape_of_literal(text),
                                                         []).append(
                                            "%s:%d  %s" % (rel, number, text[:70]))
                                for text in ternary_literals(arg2):
                                    found.setdefault(shape_of_literal(text),
                                                     []).append(
                                        "%s:%d  %s" % (rel, number, text[:70]))
                            continue

                        # Cas général : premier argument — un littéral SEUL sur
                        # la ligne suivante (`IntentDescription(\n "…",`, lot
                        # INT-R1), ou un ternaire, multiligne ou non.
                        arg = first_argument(lines, line_idx, start)
                        s1 = arg.strip()
                        if s1.startswith('"'):
                            text, _ = read_literal(s1, 0)
                            if text:
                                found.setdefault(shape_of_literal(text),
                                                 []).append(
                                    "%s:%d  %s" % (rel, number, text[:70]))
                        for text in ternary_literals(arg):
                            found.setdefault(shape_of_literal(text),
                                             []).append(
                                "%s:%d  %s" % (rel, number, text[:70]))
    return found


def catalog(path):
    with open(path, encoding="utf-8") as handle:
        return json.load(handle)


def check_translations(path, problems):
    data = catalog(path)
    rel = os.path.relpath(path, ROOT)
    for key, entry in sorted(data.get("strings", {}).items()):
        fr = entry.get("localizations", {}).get("fr")
        if fr is None:
            problems.append("%s : « %s » n'a aucune traduction fr." % (rel, key))
            continue
        units = []
        if "stringUnit" in fr:
            units.append(fr["stringUnit"])
        for variation in fr.get("variations", {}).values():
            for case in variation.values():
                if "stringUnit" in case:
                    units.append(case["stringUnit"])
        if not units:
            problems.append("%s : « %s » a une entrée fr vide." % (rel, key))
        for unit in units:
            if unit.get("state") != "translated":
                problems.append("%s : « %s » est fr/%s, pas « translated »."
                                % (rel, key, unit.get("state")))
            if not unit.get("value"):
                problems.append("%s : « %s » a une valeur fr vide." % (rel, key))
    return data


# Une référence de substitution (`%#@total@`) n'est PAS un argument : c'est la
# substitution elle-même qui déclare sa position (`argNum`) et son type.
SUBSTITUTION_REF = re.compile(r"%#@[^@]+@")

KIND = {"@": "objet (%@)", "lld": "entier (%lld)", "ld": "entier (%ld)",
        "d": "entier (%d)", "lf": "réel (%lf)", "f": "réel (%f)",
        "s": "chaîne C (%s)"}
TYPED = re.compile(r"%(?:(\d+)\$)?[-+ #0]*[0-9]*(?:\.[0-9]+)?(lld|ld|lf|[@dfs])")


def argument_types(text):
    """Position (1, 2, …) → famille de type, pour une clé ou une traduction.

    Les spécificateurs sans position explicite se numérotent dans l'ordre
    d'apparition, comme le fait Foundation."""
    types, auto = {}, 0
    for match in TYPED.finditer(SUBSTITUTION_REF.sub("", text)):
        if match.group(1):
            position = int(match.group(1))
        else:
            auto += 1
            position = auto
        types.setdefault(position, KIND[match.group(2)])
    return types


def translated_values(node):
    """Les valeurs traduites d'une localisation, HORS substitutions : celles-ci
    portent des `%arg`, pas des arguments de la chaîne porteuse."""
    out = []
    if isinstance(node, dict):
        unit = node.get("stringUnit")
        if isinstance(unit, dict) and isinstance(unit.get("value"), str):
            out.append(unit["value"])
        for name, child in node.items():
            if name not in ("stringUnit", "substitutions"):
                out.extend(translated_values(child))
    return out


def check_format_agreement(path, problems):
    """La clé et la traduction doivent parler du MÊME TYPE à chaque position.

    C'est le contrôle qui manquait le 04/09/2026. Vingt et une clés annonçaient
    `%@` — parce que le code interpolait `Format.integer(n)`, donc une chaîne —
    pendant que la traduction écrivait `%lld`, imposé par `xcstringstool` qui
    refuse `%@` dans un pluriel. Foundation lisait alors le POINTEUR de la
    chaîne comme un entier 64 bits : la barre latérale annonçait
    « 105 553 137 941 168 pages encore à reconnaître », et la règle de pluriel,
    tranchée sur ce même pointeur, ne pouvait plus jamais choisir le singulier.

    Le contrôle 2 ne peut pas voir ça : il réduit `%@`, `%lld` et `\\(x)` au même
    trou, faute de connaître le type d'une expression Swift. Ici, on ne compare
    que le catalogue à lui-même — et cela suffit, parce que la CLÉ est engendrée
    par le compilateur à partir du type réellement passé.
    """
    data = catalog(path)
    rel = os.path.relpath(path, ROOT)
    for key, entry in sorted(data.get("strings", {}).items()):
        expected = argument_types(key)
        for lang, localization in sorted(
                (entry.get("localizations") or {}).items()):
            for value in translated_values(localization):
                for position, kind in sorted(argument_types(value).items()):
                    if position not in expected:
                        problems.append(
                            "%s : « %s » — la traduction %s emploie un argument "
                            "%d que la clé n'a pas :\n      « %s »"
                            % (rel, key, lang, position, value))
                    elif kind != expected[position]:
                        problems.append(
                            "%s : « %s » — argument %d : la clé dit %s, la "
                            "traduction %s dit %s.\n      « %s »\n      → le code "
                            "doit passer la valeur du type de la CLÉ ; sinon "
                            "Foundation affiche l'adresse mémoire de l'argument."
                            % (rel, key, position, expected[position], lang,
                               kind, value))
            # Deux entiers dans la clé, et une variation de pluriel au
            # PREMIER NIVEAU : `xcstringstool` ne peut plus deviner lequel des
            # deux commande l'accord — il prend le premier, et la phrase dit
            # « 1 page dans 1 documents ». L'outil le signale par un
            # avertissement, que personne ne lit dans la sortie d'un build.
            integers = [p for p, k in expected.items() if k.startswith("entier")]
            if len(integers) > 1 and "plural" in (
                    localization.get("variations") or {}):
                problems.append(
                    "%s : « %s » (%s) — la clé porte %d entiers et une "
                    "variation de pluriel de premier niveau : l'accord se fait "
                    "sur le premier, les autres noms restent au pluriel.\n"
                    "      → donnez à chaque nom sa `substitution` "
                    "(argNum + formatSpecifier), comme « Page %%lld of %%lld "
                    "pages carrying text »."
                    % (rel, key, lang, len(integers)))
            for name, substitution in sorted(
                    (localization.get("substitutions") or {}).items()):
                position = substitution.get("argNum")
                kind = KIND.get(substitution.get("formatSpecifier"))
                if position not in expected:
                    problems.append(
                        "%s : « %s » — la substitution « %s » (%s) vise "
                        "l'argument %s, absent de la clé."
                        % (rel, key, name, lang, position))
                elif kind != expected[position]:
                    problems.append(
                        "%s : « %s » — substitution « %s » (%s) : la clé dit "
                        "%s, la substitution dit %s."
                        % (rel, key, name, lang, expected[position], kind))


# ─── 5. La typographie française (lot L2 ; audits BU-10, AP-20, AP-19) ─────
#
# Trois défauts que rien ne voyait, et que l'audit du 09/09/2026 a mesurés sur
# le catalogue COMPILÉ du bundle :
#
#   · 233 valeurs françaises sur 802 portaient l'apostrophe DROITE (`'`) là où
#     macOS écrit « barre d’outils » (BU-10) ;
#   · 178 ponctuations doubles précédées d'une espace ORDINAIRE, aucune d'une
#     insécable : le « : » partait seul en début de ligne dans la barre
#     latérale (AP-20) ;
#   · trois « ignoré(s) », « chargée(s) », « prise(s) en charge » : une
#     parenthèse d'accord est l'aveu qu'on n'a pas compté (AP-19).
#
# La correction se pose par `python3 Tools/l10n/typography.py` (les deux
# premières) et par une variation de pluriel du catalogue (la troisième) ; ce
# contrôle est ce qui empêche la PROCHAINE chaîne de les réintroduire.
STRAIGHT_APOSTROPHE = "'"
NARROW_NBSP = " "
LOOSE_PUNCTUATION = re.compile(r" [:;?!]")
FAKE_PLURAL = re.compile(r"\((?:s|e|es)\)")


def french_values(node):
    """Toutes les valeurs traduites d'une localisation, substitutions COMPRISES.

    Contrairement à `translated_values`, on prend aussi le texte des
    substitutions : « %arg pages » est du français affiché, il porte des
    apostrophes et de la ponctuation comme le reste."""
    out = []
    if isinstance(node, dict):
        unit = node.get("stringUnit")
        if isinstance(unit, dict) and isinstance(unit.get("value"), str):
            out.append(unit["value"])
        for name, child in node.items():
            if name != "stringUnit":
                out.extend(french_values(child))
    return out


def check_french_typography(path, problems):
    """L'apostrophe courbe, l'espace insécable, et pas de parenthèse d'accord."""
    data = catalog(path)
    rel = os.path.relpath(path, ROOT)
    for key, entry in sorted(data.get("strings", {}).items()):
        fr = (entry.get("localizations") or {}).get("fr")
        if fr is None:
            continue                      # déjà signalé par le contrôle 1
        for value in french_values(fr):
            if STRAIGHT_APOSTROPHE in value:
                problems.append(
                    "%s : « %s » — la traduction fr porte une apostrophe "
                    "DROITE, pas « ’ » :\n      « %s »\n      → `python3 "
                    "Tools/l10n/typography.py` la corrige (audit BU-10)."
                    % (rel, key, value))
            if LOOSE_PUNCTUATION.search(value):
                problems.append(
                    "%s : « %s » — espace ordinaire devant une ponctuation "
                    "double ; il faut l'espace fine insécable U+202F, sinon le "
                    "signe part seul en début de ligne :\n      « %s »\n"
                    "      → `python3 Tools/l10n/typography.py` (audit AP-20)."
                    % (rel, key, value))
            if FAKE_PLURAL.search(value):
                problems.append(
                    "%s : « %s » — parenthèse d'accord dans la traduction fr :"
                    "\n      « %s »\n      → une `variations.plural` (`one` / "
                    "`other`) si la clé porte un `%%lld`, sinon une phrase qui "
                    "ne compte pas (audit AP-19)."
                    % (rel, key, value))


def main():
    problems = []
    app = check_translations(APP_CATALOG, problems)
    plist = check_translations(PLIST_CATALOG, problems)

    # 2. Les chaînes des sources sont-elles toutes au catalogue ?
    shapes = {shape_of_key(k) for k in app.get("strings", {})}
    used = swift_literals()
    for shape, places in sorted(used.items()):
        if shape in shapes:
            continue
        problems.append(
            "chaîne visible absente de Localizable.xcstrings :\n"
            "    « %s »\n    %s\n    → ajoutez-la (clé anglaise + traduction fr) à "
            "Sources/FouineApp/Resources/Localizable.xcstrings (docs/i18n.md)."
            % (shape.replace(HOLE, "…"), "\n    ".join(places[:3])))

    # 3. La clé et la traduction parlent-elles du même type ?
    check_format_agreement(APP_CATALOG, problems)
    check_format_agreement(PLIST_CATALOG, problems)

    # 4. Les clés TCC de l'Info.plist sont-elles traduites ?
    with open(INFO_PLIST, encoding="utf-8") as handle:
        info = handle.read()
    wanted = set(re.findall(r"<key>(NS\w*UsageDescription)</key>", info))
    wanted.add("NSHumanReadableCopyright")
    missing = wanted - set(plist.get("strings", {}))
    for key in sorted(missing):
        problems.append("Packaging/InfoPlist.xcstrings : « %s » manque, alors "
                        "que Packaging/Info.plist la porte." % key)

    # 5. Le français est-il écrit comme du français ?
    check_french_typography(APP_CATALOG, problems)
    check_french_typography(PLIST_CATALOG, problems)

    # Informatif : une clé que plus personne n'emploie. Ce n'est PAS une
    # erreur — le catalogue peut légitimement garder une clé le temps d'une
    # transition —, mais une liste qui enfle finit par cacher les vraies.
    orphans = sorted(shapes - set(used))
    if orphans:
        print("l10n-lint : %d clé(s) du catalogue sans emploi dans "
              "Sources/FouineApp/ :" % len(orphans))
        for shape in orphans:
            print("    « %s »" % shape.replace(HOLE, "…"))

    if problems:
        print("\nl10n-lint : %d problème(s)\n" % len(problems), file=sys.stderr)
        for problem in problems:
            print("  · " + problem, file=sys.stderr)
        return 1
    print("l10n-lint : %d clés d'app, %d clés d'Info.plist, %d chaînes "
          "visibles — tout est traduit."
          % (len(app.get("strings", {})), len(plist.get("strings", {})),
             len(used)))
    return 0


if __name__ == "__main__":
    sys.exit(main())
