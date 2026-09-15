#!/usr/bin/env python3
# evaluate.py — nDCG@10, P@10, MRR par système, à partir des jugements et des
# classements de `runs/`.
#
# Propriété : A-Embed. python3 système, AUCUNE dépendance.
#
# Six choix qu'il faut connaître pour lire les chiffres :
#
# · **Les jugements viennent de deux endroits, le second prime.** La colonne
#   `grade` de `candidates.tsv` (annotation au tableur, à l'ancienne) et le
#   fichier `grades.tsv` qu'écrit `annotate.py` — clé (requête, doc_id, page),
#   indépendant du pool, partageable entre plusieurs pools (`--grades`). Une
#   note posée dans l'un ou l'autre compte ; en cas de doublon, `grades.tsv`.
# · **Annotation PARTIELLE acceptée.** Seules les requêtes qui portent au moins
#   un jugement entrent dans les moyennes ; les autres sont comptées à part.
#   Annoter dix requêtes donne donc un résultat lisible tout de suite.
# · **Un candidat non noté vaut 0.** C'est la convention TREC. Elle est juste
#   tant qu'on ne compare que des systèmes qui ont contribué au pool — d'où
#   l'importance de refaire tourner `pool.py` quand on ajoute un système — et
#   tant qu'une requête commencée est finie : passer un candidat n'est pas
#   neutre, il compte contre le système qui l'a remonté.
# · **Une exécution en échec écarte la requête pour TOUS les systèmes.** Un
#   `timeout` ou une sortie non nulle dans `runs/` (pool.py les note) donnait
#   un classement vide, donc un nDCG de 0 : une panne de mesure lue comme un
#   défaut de classement. La comparaison reste APPARIÉE : même jeu de
#   requêtes pour tous, et la liste des écartées est imprimée.
# · **Deux points de vue : la page et le document.** Le nDCG par page est la
#   mesure classique ; mais l'application montre des DOCUMENTS (les pages
#   groupées, trois par document depuis la diversité du lot R1), et la leçon
#   du 05/09/2026 est qu'un classement se juge de ce point de vue-là. Le nDCG
#   par document prend les documents dans l'ordre de leur première page du
#   top-k, avec pour gain la meilleure note de leurs pages présentes ; l'idéal
#   vient des meilleures notes par document sur tous les jugements connus.
# · **Un écart de nDCG n'est pas une preuve.** Sur vingt requêtes, 0,61 contre
#   0,59 est du bruit. Le tableau « contre la référence » donne, par système,
#   l'écart moyen apparié, victoires / égalités / défaites par requête, et la
#   p-valeur d'un test de permutation par renversement de signe (2 000 tirages,
#   graine fixe) : p < 0,05 se lit « l'écart tient », sinon « on ne sait pas ».
# · **Le taux de bruit absurde** (dernière colonne) n'a pas besoin de jugements :
#   une requête de la catégorie « absurde » ne devrait produire AUCUN hit
#   sémantique pur. C'est la mesure directe du constat C2-01.
#
# Usage :
#   python3 Tools/ranking/evaluate.py --dir verif/ranking/2026-09-03
#   python3 Tools/ranking/evaluate.py --dir … --grades ~/Fouine-verif/ranking/grades.tsv --by-category
#   python3 Tools/ranking/evaluate.py --dir … --baseline lexical-nomorph --per-query

import argparse
import json
import math
import os
import random
import sys


def read_tsv_grades(path, label):
    """Un TSV portant query/doc_id/page/grade → {(query, doc_id, page): note}.

    Coupe sur les tabulations seulement : le module csv mangerait les
    guillemets de `"energie libre"` et la confondrait avec `energie libre`."""
    grades = {}
    with open(path, encoding="utf-8") as handle:
        header = handle.readline().rstrip("\n").split("\t")
        try:
            iq, idoc, ipage, igrade = (header.index("query"),
                                       header.index("doc_id"),
                                       header.index("page"),
                                       header.index("grade"))
        except ValueError:
            sys.exit("%s : en-tête sans query/doc_id/page/grade" % path)
        for line in handle:
            if not line.strip():
                continue
            cells = line.rstrip("\n").split("\t")
            if len(cells) <= igrade:
                continue
            raw = cells[igrade].strip()
            if raw == "":
                continue
            try:
                grade = int(raw)
            except ValueError:
                print("%s : note illisible ignorée : %r" % (label, raw), file=sys.stderr)
                continue
            grades[(cells[iq], int(cells[idoc]), int(cells[ipage]))] = grade
    return grades


def read_pool_keys(path):
    """Les (requête, doc_id, page) que le pool a effectivement proposés."""
    keys = set()
    with open(path, encoding="utf-8") as handle:
        header = handle.readline().rstrip("\n").split("\t")
        iq, idoc, ipage = header.index("query"), header.index("doc_id"), header.index("page")
        for line in handle:
            if not line.strip():
                continue
            cells = line.rstrip("\n").split("\t")
            if len(cells) > max(iq, idoc, ipage):
                keys.add((cells[iq], int(cells[idoc]), int(cells[ipage])))
    return keys


def read_runs(runs_dir):
    """runs/*.jsonl → {système: {requête: enregistrement}}."""
    runs = {}
    for name in sorted(os.listdir(runs_dir)):
        if not name.endswith(".jsonl"):
            continue
        system = name[: -len(".jsonl")]
        records = {}
        with open(os.path.join(runs_dir, name), encoding="utf-8") as handle:
            for line in handle:
                if not line.strip():
                    continue
                record = json.loads(line)
                records[record["query"]] = record
        runs[system] = records
    return runs


def dcg(gains):
    return sum((2 ** g - 1) / math.log2(i + 2) for i, g in enumerate(gains))


def ndcg_at_k(ranked_grades, ideal_grades, k):
    actual = dcg(ranked_grades[:k])
    ideal = dcg(sorted(ideal_grades, reverse=True)[:k])
    return actual / ideal if ideal > 0 else 0.0


def mean(values):
    return sum(values) / len(values) if values else float("nan")


def doc_gains(hits, grades, query, k):
    """Les documents du top-k dans l'ordre de leur première page, chacun avec
    la meilleure note de ses pages présentes dans le top-k."""
    order, best = [], {}
    for hit in hits[:k]:
        doc = hit["doc_id"]
        grade = grades.get((query, doc, hit["page"]), 0)
        if doc not in best:
            order.append(doc)
            best[doc] = grade
        else:
            best[doc] = max(best[doc], grade)
    return [best[doc] for doc in order]


def per_query_metrics(records, queries, grades, ideal_pages, ideal_docs, k):
    """→ {requête: {"ndcg", "p", "rr", "doc_ndcg", "docs"}} d'un système."""
    out = {}
    for query in queries:
        record = records.get(query)
        if record is None:
            continue
        hits = record.get("hits", [])
        ranked = [grades.get((query, hit["doc_id"], hit["page"]), 0) for hit in hits]
        top = ranked[:k]
        rank = next((i + 1 for i, g in enumerate(ranked) if g >= 1), None)
        out[query] = {
            "ndcg": ndcg_at_k(ranked, ideal_pages[query], k),
            "p": sum(1 for g in top if g >= 1) / float(k),
            "rr": 1.0 / rank if rank else 0.0,
            "doc_ndcg": ndcg_at_k(doc_gains(hits, grades, query, k), ideal_docs[query], k),
            "docs": len({hit["doc_id"] for hit in hits[:k]}),
        }
    return out


def summarize(per_query, queries):
    rows = [per_query[q] for q in queries if q in per_query]
    return (len(rows),
            mean([r["ndcg"] for r in rows]), mean([r["p"] for r in rows]),
            mean([r["rr"] for r in rows]), mean([r["doc_ndcg"] for r in rows]),
            mean([r["docs"] for r in rows]))


def paired_test(diffs, draws=2000, seed=0):
    """Test de permutation par renversement de signe sur des écarts appariés :
    sous l'hypothèse « aucun système n'est meilleur », chaque écart aurait
    pu être de l'autre signe. p = part des tirages dont la moyenne absolue
    atteint celle observée."""
    if not diffs:
        return float("nan")
    observed = abs(mean(diffs))
    if observed == 0.0:
        return 1.0
    rng = random.Random(seed)
    hits = 0
    for _ in range(draws):
        flipped = [d if rng.random() < 0.5 else -d for d in diffs]
        if abs(mean(flipped)) >= observed - 1e-12:
            hits += 1
    return hits / float(draws)


def main():
    parser = argparse.ArgumentParser(
        description="nDCG@10 / P@10 / MRR par système sur un pool annoté.")
    parser.add_argument("--dir", required=True,
                        help="répertoire produit par pool.py")
    parser.add_argument("--grades", default=None,
                        help="fichier des jugements d'annotate.py (défaut : "
                             "<dir>/grades.tsv s'il existe)")
    parser.add_argument("--by-category", action="store_true",
                        help="un tableau de plus, par catégorie de requêtes")
    parser.add_argument("--per-query", action="store_true",
                        help="un tableau de plus : nDCG@k de chaque système, requête par requête")
    parser.add_argument("--baseline", default=None,
                        help="système de référence des écarts appariés "
                             "(défaut : lexical s'il existe, sinon le premier)")
    parser.add_argument("--k", type=int, default=10)
    args = parser.parse_args()

    candidates = os.path.join(args.dir, "candidates.tsv")
    runs_dir = os.path.join(args.dir, "runs")
    for path in (candidates, runs_dir):
        if not os.path.exists(path):
            sys.exit("introuvable : %s (lancez pool.py d'abord)" % path)
    grades_path = args.grades or os.path.join(args.dir, "grades.tsv")
    if args.grades and not os.path.exists(args.grades):
        sys.exit("introuvable : %s" % args.grades)

    from_column = read_tsv_grades(candidates, "candidates.tsv")
    from_file = read_tsv_grades(grades_path, "grades.tsv") if os.path.exists(grades_path) else {}
    grades = dict(from_column)
    grades.update(from_file)
    runs = read_runs(runs_dir)
    if not runs:
        sys.exit("aucun run dans %s" % runs_dir)
    k = args.k

    all_queries = set()
    categories = {}
    failed = {}                      # requête → [système…] dont l'exécution a échoué
    for system, records in runs.items():
        for query, record in records.items():
            all_queries.add(query)
            categories[query] = record.get("category", "")
            if record.get("error"):
                failed.setdefault(query, []).append(system)
    absurd = sorted(q for q in all_queries if categories.get(q) == "absurde")

    judged_all = sorted({query for query, _, _ in grades})
    judged_queries = [q for q in judged_all if q not in failed]
    ideal_pages, best_by_doc = {}, {}
    for (query, doc, _), grade in grades.items():
        ideal_pages.setdefault(query, []).append(grade)
        key = (query, doc)
        best_by_doc[key] = max(best_by_doc.get(key, 0), grade)
    ideal_docs = {}
    for (query, _), grade in best_by_doc.items():
        ideal_docs.setdefault(query, []).append(grade)

    pool_keys = read_pool_keys(candidates)
    n_lines = len(pool_keys)
    in_pool = sum(1 for key in grades if key in pool_keys)

    per_system = {system: per_query_metrics(runs[system], judged_queries, grades,
                                            ideal_pages, ideal_docs, k)
                  for system in runs}

    print("# Banc de classement — %s" % os.path.abspath(args.dir))
    print()
    print("- requêtes exécutées : **%d**" % len(all_queries))
    print("- requêtes portant au moins un jugement : **%d** (%s)"
          % (len(judged_queries),
             "les moyennes ne portent que sur celles-là"
             if judged_queries else "AUCUNE — annotez avec annotate.py"))
    print("- candidats notés : **%d** sur %d lignes de candidates.tsv"
          " (%d notes lues dans `grades.tsv`, %d dans la colonne `grade`)"
          % (in_pool, n_lines, len(from_file), len(from_column)))
    print("- requêtes absurdes : **%d**" % len(absurd))
    if failed:
        print("- requêtes écartées pour échec d'exécution : **%d** — %s"
              % (len(failed), "; ".join("`%s` (%s)" % (q, ", ".join(s))
                                        for q, s in sorted(failed.items()))))
    print()

    header = ("| système | requêtes | nDCG@%d | P@%d | MRR | nDCG@%d docs | docs / top-%d | absurdes avec ≥ 1 "
              "hit sémantique pur |" % (k, k, k, k))
    print(header)
    print("|---|---:|---:|---:|---:|---:|---:|---:|")
    for system in sorted(runs):
        count, ndcg, precision, rr, dndcg, ndocs = summarize(per_system[system], judged_queries)
        noisy = 0
        for query in absurd:
            record = runs[system].get(query)
            if record and any(hit.get("semantic_only") for hit in record.get("hits", [])):
                noisy += 1
        print("| `%s` | %d | %.3f | %.3f | %.3f | %.3f | %.1f | %d / %d |"
              % (system, count, ndcg, precision, rr, dndcg, ndocs, noisy, len(absurd)))

    if not judged_queries:
        print()
        print("> Les colonnes de qualité valent `nan` tant qu'aucun jugement")
        print("> n'existe — `python3 Tools/ranking/annotate.py --dir %s`." % args.dir)
        print("> La dernière, elle, est déjà lisible : elle ne dépend d'aucun jugement.")

    if judged_queries and len(runs) > 1:
        baseline = args.baseline or ("lexical" if "lexical" in runs else sorted(runs)[0])
        if baseline not in runs:
            sys.exit("système de référence absent des runs : %r" % baseline)
        print()
        print("## Contre la référence `%s` (écarts appariés, requête par requête)" % baseline)
        print()
        print("| système | Δ nDCG@%d | V / É / D | p (permutation) | Δ nDCG@%d docs | V / É / D | p |"
              % (k, k))
        print("|---|---:|---:|---:|---:|---:|---:|")
        for system in sorted(runs):
            if system == baseline:
                continue
            common = [q for q in judged_queries
                      if q in per_system[system] and q in per_system[baseline]]
            cells = []
            for metric in ("ndcg", "doc_ndcg"):
                diffs = [per_system[system][q][metric] - per_system[baseline][q][metric]
                         for q in common]
                wins = sum(1 for d in diffs if d > 1e-9)
                losses = sum(1 for d in diffs if d < -1e-9)
                ties = len(diffs) - wins - losses
                cells.append("%+.3f | %d / %d / %d | %.3f"
                             % (mean(diffs), wins, ties, losses, paired_test(diffs)))
            print("| `%s` | %s |" % (system, " | ".join(cells)))
        print()
        print("> V / É / D : requêtes où le système fait mieux / pareil / moins bien que la")
        print("> référence. p < 0,05 : l'écart tient sur ce jeu ; au-dessus, on ne sait pas —")
        print("> juger d'autres requêtes vaut mieux que relire le chiffre.")

    if args.by_category and judged_queries:
        # Par catégorie : c'est là que se lit ce qu'un réglage fait à UNE
        # famille de requêtes (les guillemets, les préfixes, l'anglais…) que
        # la moyenne générale noie. Une catégorie sans requête jugée n'apparaît
        # pas ; une catégorie à une ou deux requêtes se lit avec prudence.
        by_category = {}
        for query in judged_queries:
            by_category.setdefault(categories.get(query, ""), []).append(query)
        print()
        print("## Par catégorie")
        print()
        print("| catégorie | requêtes jugées | système | nDCG@%d | P@%d | MRR | nDCG@%d docs |"
              % (k, k, k))
        print("|---|---:|---|---:|---:|---:|---:|")
        for category in sorted(by_category):
            queries = by_category[category]
            for system in sorted(runs):
                count, ndcg, precision, rr, dndcg, _ = summarize(per_system[system], queries)
                print("| %s | %d | `%s` | %.3f | %.3f | %.3f | %.3f |"
                      % (category or "(sans catégorie)", count, system,
                         ndcg, precision, rr, dndcg))

    if args.per_query and judged_queries:
        systems = sorted(runs)
        print()
        print("## Requête par requête (nDCG@%d par page)" % k)
        print()
        print("| requête | catégorie | " + " | ".join("`%s`" % s for s in systems) + " |")
        print("|---|---|" + "---:|" * len(systems))
        for query in judged_queries:
            cells = []
            for system in systems:
                row = per_system[system].get(query)
                cells.append("%.3f" % row["ndcg"] if row else "—")
            print("| `%s` | %s | %s |" % (query, categories.get(query, ""), " | ".join(cells)))

    unjudged = sorted(all_queries - set(judged_all))
    if unjudged:
        print()
        print("<details><summary>%d requête(s) sans jugement</summary>"
              % len(unjudged))
        print()
        for query in unjudged:
            print("- `%s` (%s)" % (query, categories.get(query, "")))
        print()
        print("</details>")


if __name__ == "__main__":
    main()
