#!/usr/bin/env python3
"""Ajoute des clés à Localizable.xcstrings SANS réécrire le fichier.

Xcode range les clés selon une collation ICU qu'aucun `sorted()` de Python ne
reproduit : réécrire le catalogue avec `json.dump` produit un diff de 800
lignes pour trois chaînes ajoutées. Ce script insère donc les blocs
TEXTUELLEMENT, à la place approchée (comparaison insensible à la casse), et ne
touche à rien d'autre.

    ./Tools/l10n/add-strings.py paires.json
    # paires.json : { "English source": "Traduction française", … }
    #
    # Un PLURIEL (clé avec « %lld … (s) », rendu « one »/« other ») se donne
    # sous forme d'objet, dans le même fichier :
    #   "%lld page(s) to read": { "en": ["%lld page to read", "%lld pages to read"],
    #                             "fr": ["%lld page à lire", "%lld pages à lire"] }

    ./Tools/l10n/add-strings.py paires.json --replace
    # RÉÉCRIT le bloc des clés déjà présentes, au lieu de les sauter. C'est ce
    # qui rend une correction de traduction REJOUABLE : le lot L2 a dû donner
    # une variation de pluriel à des clés existantes (« %lld ignoré(s) » →
    # « %lld ignoré » / « %lld ignorés », audit AP-19), et l'orchestrateur
    # rejoue le même fichier de paires sur la version de `main` du catalogue
    # plutôt que de fusionner un diff. Sans ce drapeau, une clé existante est
    # laissée telle quelle — le comportement d'origine, celui qu'on veut quand
    # on ajoute des chaînes.
    #
    # Le bloc remplacé est repéré par ses accolades, pas par un compte de
    # lignes : une entrée peut porter des variations, des substitutions, une
    # langue de plus. La virgule finale suit celle du bloc remplacé — la
    # DERNIÈRE entrée du catalogue n'en a pas, et en poser une casse le JSON
    # (piège rencontré au lot UX3, dans l'autre sens).
"""
import json
import re
import sys

CATALOG = "Sources/FouineApp/Resources/Localizable.xcstrings"
KEY = re.compile(r'^    ("(?:[^"\\]|\\.)*"): \{$')


def block(key: str, en: str, fr: str) -> list[str]:
    def q(s: str) -> str:
        return json.dumps(s, ensure_ascii=False)
    return [
        f"    {q(key)}: {{",
        '      "extractionState": "manual",',
        '      "localizations": {',
        '        "en": {',
        '          "stringUnit": {',
        '            "state": "translated",',
        f'            "value": {q(en)}',
        "          }",
        "        },",
        '        "fr": {',
        '          "stringUnit": {',
        '            "state": "translated",',
        f'            "value": {q(fr)}',
        "          }",
        "        }",
        "      }",
        "    },",
    ]


def plural_block(key: str, en: list[str], fr: list[str]) -> list[str]:
    def q(s: str) -> str:
        return json.dumps(s, ensure_ascii=False)
    def lang(code: str, forms: list[str], last: bool) -> list[str]:
        one, other = forms
        return [
            f'        "{code}": {{',
            '          "variations": {',
            '            "plural": {',
            '              "one": {',
            '                "stringUnit": {',
            '                  "state": "translated",',
            f'                  "value": {q(one)}',
            "                }",
            "              },",
            '              "other": {',
            '                "stringUnit": {',
            '                  "state": "translated",',
            f'                  "value": {q(other)}',
            "                }",
            "              }",
            "            }",
            "          }",
            "        }" + ("" if last else ","),
        ]
    return ([f"    {q(key)}: {{",
             '      "extractionState": "manual",',
             '      "localizations": {']
            + lang("en", en, False) + lang("fr", fr, True)
            + ["      }", "    },"])


def block_end(lines: list[str], start: int) -> int:
    """L'indice de la ligne qui FERME le bloc ouvert à `start`.

    Compte les accolades hors chaîne : une clé ou une traduction peut en
    contenir (« Fouine {n} », une phrase avec un guillemet échappé), et un
    `str.count("{")` naïf déséquilibrerait le compte."""
    depth = 0
    for i in range(start, len(lines)):
        line, j = lines[i], 0
        while j < len(line):
            c = line[j]
            if c == '"':
                j += 1
                while j < len(line):
                    if line[j] == "\\":
                        j += 2
                        continue
                    if line[j] == '"':
                        break
                    j += 1
            elif c == "{":
                depth += 1
            elif c == "}":
                depth -= 1
                if depth == 0:
                    return i
            j += 1
    raise SystemExit("add-strings : bloc « %s » non fermé." % lines[start])


def main() -> int:
    args = [a for a in sys.argv[1:] if not a.startswith("--")]
    replace = "--replace" in sys.argv[1:]
    pairs = json.load(open(args[0]))
    lines = open(CATALOG).read().split("\n")
    for en, fr in pairs.items():
        entries = [(i, json.loads(m.group(1)))
                   for i, l in enumerate(lines) if (m := KEY.match(l))]
        at = next((i for i, k in entries if k == en), None)
        if at is not None and not replace:
            print("déjà là :", en)
            continue
        if isinstance(fr, dict):
            new = plural_block(en, fr["en"], fr["fr"])
        else:
            new = block(en, en, fr)
        if at is not None:
            end = block_end(lines, at)
            if not lines[end].endswith(","):      # la dernière entrée du fichier
                new[-1] = new[-1].rstrip(",")
            if lines[at:end + 1] == new:
                print("inchangée :", en)
                continue
            lines[at:end + 1] = new
            print("remplacée :", en)
            continue
        where = next((i for i, k in entries if k.lower() > en.lower()),
                     entries[-1][0])
        lines[where:where] = new
        print("ajoutée :", en)
    open(CATALOG, "w").write("\n".join(lines))
    return 0


if __name__ == "__main__":
    sys.exit(main())
