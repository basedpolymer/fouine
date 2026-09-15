#!/usr/bin/env python3
"""Retire des clés de Localizable.xcstrings SANS réécrire le fichier.

Le pendant d'`add-strings.py`, pour la même raison : Xcode range les clés selon
une collation ICU qu'aucun `sorted()` de Python ne reproduit, et réécrire le
catalogue avec `json.dump` produit un diff de 800 lignes. Les blocs sont
repérés par leur ligne d'ouverture et leurs accolades (`block_end`, repris tel
quel d'`add-strings.py`), puis ôtés, sans toucher à rien d'autre.

    python3 Tools/l10n/remove-strings.py clés.json    # une liste JSON de clés exactes
    python3 Tools/l10n/remove-strings.py --orphans    # les clés sans emploi selon lint.py

`--orphans` applique EXACTEMENT le critère informatif de `lint.py` : la forme
de la clé n'apparaît dans aucun littéral de `Sources/FouineApp/`. Ce que le
lint annonce est ce qui part, rien de plus. Une clé construite à l'exécution
(`LocalizedStringKey(variable)`) échappe au lint : relire la liste avant de
lancer. Ensuite, `./Tools/l10n-lint.sh` et `make ci-bundle-i18n`.

LA VIRGULE. La dernière entrée du catalogue n'en porte pas. Retirer celle-là
reporte l'absence de virgule sur l'entrée qui devient dernière — le piège
d'`add-strings.py` au lot UX3, pris dans l'autre sens.
"""
import importlib.util
import json
import os
import sys

HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, HERE)


def _add_strings():
    # Le nom porte un tiret : il ne s'importe pas par `import`.
    spec = importlib.util.spec_from_file_location(
        "add_strings", os.path.join(HERE, "add-strings.py"))
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    return module


_ADD = _add_strings()
CATALOG = _ADD.CATALOG
KEY = _ADD.KEY
block_end = _ADD.block_end


def orphan_keys() -> list[str]:
    """Les clés dont la forme manque aux littéraux de l'app (critère de lint.py)."""
    import lint
    app = lint.catalog(lint.APP_CATALOG)
    used = set(lint.swift_literals())
    return sorted(k for k in app.get("strings", {})
                  if lint.shape_of_key(k) not in used)


def main() -> int:
    args = [a for a in sys.argv[1:] if not a.startswith("--")]
    if "--orphans" in sys.argv[1:]:
        wanted = orphan_keys()
    elif args:
        wanted = json.load(open(args[0]))
    else:
        print(__doc__)
        return 64

    lines = open(CATALOG).read().split("\n")
    removed = 0
    for key in wanted:
        entries = [(i, json.loads(m.group(1)))
                   for i, l in enumerate(lines) if (m := KEY.match(l))]
        at = next((i for i, k in entries if k == key), None)
        if at is None:
            print("absente :", key)
            continue
        end = block_end(lines, at)
        was_last = not lines[end].endswith(",")
        del lines[at:end + 1]
        if was_last:
            lines[at - 1] = lines[at - 1].rstrip(",")
        print("retirée :", key)
        removed += 1

    open(CATALOG, "w").write("\n".join(lines))
    json.load(open(CATALOG))          # le JSON doit rester valide
    print("remove-strings : %d clé(s) retirée(s)" % removed)
    return 0


if __name__ == "__main__":
    sys.exit(main())
