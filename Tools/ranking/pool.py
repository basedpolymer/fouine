#!/usr/bin/env python3
# pool.py — met en commun les résultats de plusieurs « systèmes » de recherche
# pour fabriquer la feuille d'annotation d'un banc de classement.
#
# Propriété : A-Embed. python3 système, AUCUNE dépendance (règle des trois
# dépendances, CONTRIBUTING.md § Conventions).
#
# Ce que ça fait, en une phrase : pour chaque requête de `queries.txt` et
# chaque système de `systems.json`, exécuter `fouine search --json`, écrire le
# classement complet dans `runs/<système>.jsonl`, et verser les top-k de tous
# les systèmes dans un unique `candidates.tsv` où l'humain met les notes.
#
# La mise en commun (« pooling ») est la méthode TREC : on n'annote que ce
# qu'au moins un système a remonté, ce qui rend le travail fini — et le biais
# est connu et accepté (un document qu'aucun système ne trouve reste invisible).
#
# LECTURE SEULE : `fouine search` n'écrit rien et ne prend jamais le verrou
# (SPEC §5.1). Ce script peut donc tourner sur la base de production.
#
# Usage :
#   python3 Tools/ranking/pool.py --out verif/ranking/2026-09-03
#   python3 Tools/ranking/pool.py --fouine .build/release/fouine --limit 10
#   python3 Tools/ranking/pool.py --out … --grades ~/Fouine-verif/ranking/grades.tsv
#
# `--grades` pré-remplit la colonne `grade` depuis le fichier de jugements
# d'annotate.py : relancer le pool (nouveau système, nouveau binaire) ne fait
# pas perdre une note, et la feuille dit d'un coup d'œil ce qui reste à juger.

import argparse
import json
import os
import shutil
import subprocess
import sys
import time

HERE = os.path.dirname(os.path.abspath(__file__))


def read_queries(path):
    """Rend [(requête, catégorie)]. Une ligne « # nom » ouvre une catégorie."""
    out = []
    category = "(sans catégorie)"
    with open(path, encoding="utf-8") as handle:
        for line in handle:
            line = line.rstrip("\n")
            stripped = line.strip()
            if not stripped:
                continue
            if stripped.startswith("#"):
                label = stripped.lstrip("#").strip()
                # Les lignes d'en-tête du fichier (phrases) ne sont pas des
                # catégories : une catégorie tient en trois mots.
                if label and len(label.split()) <= 3:
                    category = label
                continue
            out.append((stripped, category))
    return out


def read_systems(path):
    with open(path, encoding="utf-8") as handle:
        data = json.load(handle)
    systems = data["systems"]
    for system in systems:
        if "name" not in system or "args" not in system:
            sys.exit("systems.json : chaque système veut « name » et « args »")
    return systems


def run_one(binary, query, args, limit, database, timeout):
    """Exécute une recherche et rend (payload JSON, secondes, erreur)."""
    cmd = [binary, "search", query] + list(args) + ["--limit", str(limit), "--json"]
    env = dict(os.environ)
    if database:
        env["FOUINE_DB"] = database
    start = time.time()
    try:
        proc = subprocess.run(cmd, capture_output=True, text=True,
                              env=env, timeout=timeout)
    except subprocess.TimeoutExpired:
        return None, time.time() - start, "timeout"
    except FileNotFoundError:
        sys.exit("binaire introuvable : %s (voir --fouine)" % binary)
    wall = time.time() - start
    if proc.returncode != 0:
        return None, wall, "exit %d: %s" % (proc.returncode,
                                            proc.stderr.strip()[:200])
    try:
        return json.loads(proc.stdout), wall, None
    except json.JSONDecodeError as exc:
        return None, wall, "JSON illisible: %s" % exc


def describe_binary(binary):
    """Ce qui permet de savoir, plus tard, QUEL classement le pool a mesuré :
    version annoncée, date du fichier, commit du dépôt s'il y en a un. Le pool
    M1 du 05/09/2026 (10 h 21) a été jugé caduc par un commit de 11 h 58 sans
    que rien dans le pool ne le dise."""
    info = {"fouine": binary}
    resolved = shutil.which(binary) if os.sep not in binary else binary
    if resolved and os.path.exists(resolved):
        info["fouine_resolved"] = os.path.abspath(resolved)
        info["fouine_mtime"] = time.strftime(
            "%Y-%m-%dT%H:%M:%S", time.localtime(os.path.getmtime(resolved)))
        # Un binaire livré dans Fouine.app (Contents/Helpers/fouine, ou le lien
        # /usr/local/bin/fouine qui y mène) porte le numéro de build de l'app :
        # c'est lui qui distingue deux « 1.0.0 ».
        real = os.path.realpath(resolved)
        plist = os.path.join(os.path.dirname(real), "..", "Info.plist")
        if os.path.exists(plist):
            try:
                out = subprocess.run(["defaults", "read", os.path.abspath(plist),
                                      "CFBundleVersion"], capture_output=True,
                                     text=True, timeout=10)
                if out.returncode == 0:
                    info["fouine_build"] = out.stdout.strip()
            except (OSError, subprocess.SubprocessError):
                pass
    try:
        out = subprocess.run([binary, "--version"], capture_output=True,
                             text=True, timeout=10)
        if out.returncode == 0:
            info["fouine_version"] = out.stdout.strip()
    except (OSError, subprocess.SubprocessError):
        pass
    try:
        out = subprocess.run(["git", "-C", HERE, "rev-parse", "--short", "HEAD"],
                             capture_output=True, text=True, timeout=10)
        if out.returncode == 0:
            info["git_head"] = out.stdout.strip()
    except (OSError, subprocess.SubprocessError):
        pass
    return info


def corpus_from_status(payload):
    """Les deux nombres qui DATENT le corpus, lus dans `fouine status --json`.

    RK-14 : les pools du 05/09 et du 09/09 ne portent pas sur le même corpus
    (22 documents indexés le 08/09), et `queries.json` ne disait que le commit
    et la date. Sans ces deux nombres, deux pools se comparent ligne à ligne
    alors qu'ils ne mesurent pas la même chose. `pages_vec` vient avec :
    l'hybride est jugé sur la couverture du moment, pas sur le corpus entier
    (RK-15)."""
    if not isinstance(payload, dict):
        return {}
    out = {}
    for field in ("docs_total", "pages_indexed", "pages_vec"):
        value = payload.get(field)
        if isinstance(value, int):
            out[field] = value
    return out


def describe_corpus(binary, database, timeout=60.0):
    """`fouine status --json` du MÊME binaire que le pool. Lecture seule (SPEC
    §5.1), donc utilisable sur la base de production comme `search`."""
    env = dict(os.environ)
    if database:
        env["FOUINE_DB"] = database
    try:
        out = subprocess.run([binary, "status", "--json"], capture_output=True,
                             text=True, env=env, timeout=timeout)
    except (OSError, subprocess.SubprocessError):
        print("état du corpus indisponible : `%s status --json` n'a pas répondu"
              % binary, file=sys.stderr)
        return {}
    if out.returncode != 0:
        print("état du corpus indisponible : `%s status --json` sort en %d"
              % (binary, out.returncode), file=sys.stderr)
        return {}
    try:
        return corpus_from_status(json.loads(out.stdout))
    except json.JSONDecodeError:
        print("état du corpus indisponible : JSON illisible", file=sys.stderr)
        return {}


def key_of(hit):
    return (int(hit.get("doc_id", -1)), int(hit.get("page", -1)))


def read_grades(path):
    """grades.tsv d'annotate.py → {(requête, doc_id, page): note}. Tabulations
    seules, pas de module csv : il mangerait les guillemets des requêtes."""
    grades = {}
    if not os.path.exists(path):
        # Premier pool d'une campagne : le fichier n'existe pas encore, et la
        # même ligne de commande doit servir à tous les pools suivants. On
        # le dit, on continue — le résumé final répète « 0 déjà jugé ».
        print("aucun jugement encore : %s n'existe pas (annotate.py le créera)"
              % path, file=sys.stderr)
        return grades
    with open(path, encoding="utf-8") as handle:
        header = handle.readline().rstrip("\n").split("\t")
        try:
            iq, idoc, ipage, igrade = (header.index("query"), header.index("doc_id"),
                                       header.index("page"), header.index("grade"))
        except ValueError:
            sys.exit("%s : en-tête sans query/doc_id/page/grade" % path)
        for line in handle:
            cells = line.rstrip("\n").split("\t")
            if len(cells) <= igrade or not cells[igrade].strip():
                continue
            grades[(cells[iq], int(cells[idoc]), int(cells[ipage]))] = cells[igrade].strip()
    return grades


def main():
    parser = argparse.ArgumentParser(
        description="Met en commun les top-k de plusieurs systèmes de recherche.")
    parser.add_argument("--fouine", default="fouine",
                        help="binaire à piloter (défaut : fouine)")
    parser.add_argument("--queries", default=os.path.join(HERE, "queries.txt"))
    parser.add_argument("--systems", default=os.path.join(HERE, "systems.json"))
    parser.add_argument("--out", required=True,
                        help="répertoire de sortie (créé au besoin)")
    parser.add_argument("--limit", type=int, default=10,
                        help="profondeur du pool par système (défaut 10)")
    parser.add_argument("--database", default=None,
                        help="base à interroger (défaut : celle de fouine)")
    parser.add_argument("--timeout", type=float, default=120.0)
    parser.add_argument("--grades", default=None,
                        help="jugements déjà posés (grades.tsv d'annotate.py) : "
                             "pré-remplit la colonne grade des candidats connus")
    args = parser.parse_args()

    known_grades = read_grades(args.grades) if args.grades else {}

    queries = read_queries(args.queries)
    systems = read_systems(args.systems)
    if not queries:
        sys.exit("aucune requête dans %s" % args.queries)

    runs_dir = os.path.join(args.out, "runs")
    os.makedirs(runs_dir, exist_ok=True)

    # candidates[(query, doc_id, page)] = {"path":…, "snippet":…, "systems":[…]}
    candidates = {}
    order = []
    failures = []

    handles = {}
    try:
        for system in systems:
            handles[system["name"]] = open(
                os.path.join(runs_dir, "%s.jsonl" % system["name"]),
                "w", encoding="utf-8")

        total = len(queries) * len(systems)
        done = 0
        for query, category in queries:
            for system in systems:
                done += 1
                payload, wall, error = run_one(args.fouine, query,
                                               system["args"], args.limit,
                                               args.database, args.timeout)
                print("[%3d/%3d] %-14s %s" % (done, total, system["name"], query),
                      file=sys.stderr)
                record = {
                    "query": query,
                    "category": category,
                    "system": system["name"],
                    "args": system["args"],
                    "wall_s": round(wall, 3),
                }
                if error:
                    record["error"] = error
                    record["hits"] = []
                    failures.append((system["name"], query, error))
                else:
                    record["elapsed_ms"] = payload.get("elapsed_ms")
                    record["hybrid"] = payload.get("hybrid")
                    for field in ("total_pages", "total_docs", "lex_total_pages",
                                  "lex_total_docs", "semantic_only",
                                  "semantic_floor", "semantic_kept",
                                  "semantic_coverage_pct", "vectors",
                                  "pages_indexed", "semantic_stats"):
                        if field in payload:
                            record[field] = payload[field]
                    hits = []
                    for rank, hit in enumerate(payload.get("hits", []), start=1):
                        doc_id, page = key_of(hit)
                        hits.append({
                            "rank": rank,
                            "doc_id": doc_id,
                            "page": page,
                            "path": hit.get("path", ""),
                            "semantic_only": bool(hit.get("semantic_only", False)),
                            "z": hit.get("z"),
                            "cosine": hit.get("cosine"),
                        })
                        key = (query, doc_id, page)
                        if key not in candidates:
                            candidates[key] = {
                                "category": category,
                                "path": hit.get("path", ""),
                                "snippet": hit.get("snippet", ""),
                                "systems": [],
                            }
                            order.append(key)
                        candidates[key]["systems"].append(
                            "%s:%d" % (system["name"], rank))
                    record["hits"] = hits
                handle = handles[system["name"]]
                handle.write(json.dumps(record, ensure_ascii=False) + "\n")
                # Vidé à chaque ligne : la campagne dure des dizaines de
                # minutes, et un fichier qui reste vide pendant tout ce temps
                # ne permet pas de savoir si elle avance ou si elle est bloquée.
                handle.flush()
    finally:
        for handle in handles.values():
            handle.close()

    # La feuille d'annotation. `grade` est VIDE — sauf pour les candidats déjà
    # jugés dans --grades : c'est la seule colonne que l'humain remplit (0 hors
    # sujet, 1 utile, 2 exactement ce qu'il fallait), de préférence avec
    # annotate.py, qui montre le texte de la page et écrit grades.tsv.
    def clean(text):
        return " ".join(str(text).replace("\t", " ").split())

    prefilled = 0
    tsv = os.path.join(args.out, "candidates.tsv")
    with open(tsv, "w", encoding="utf-8") as handle:
        handle.write("query\tdoc_id\tpage\tgrade\tpath\tsnippet\tsystems\n")
        for key in order:
            query, doc_id, page = key
            entry = candidates[key]
            grade = known_grades.get((clean(query), doc_id, page), "")
            prefilled += 1 if grade else 0
            handle.write("\t".join([
                clean(query), str(doc_id), str(page), grade,
                clean(entry["path"]), clean(entry["snippet"])[:300],
                ";".join(entry["systems"]),
            ]) + "\n")

    meta = os.path.join(args.out, "queries.json")
    with open(meta, "w", encoding="utf-8") as handle:
        meta_doc = {"queries": [{"query": q, "category": c} for q, c in queries],
                    "systems": [{"name": s["name"], "args": s["args"]} for s in systems],
                    "limit": args.limit,
                    "generated_at": time.strftime("%Y-%m-%dT%H:%M:%S"),
                    "database": args.database or "(celle de fouine)"}
        meta_doc.update(describe_binary(args.fouine))
        # L'ÉTAT DU CORPUS, et pas seulement celui du binaire (RK-14) : un pool
        # se compare à un autre seulement si les deux ont vu les mêmes documents.
        meta_doc.update(describe_corpus(args.fouine, args.database, args.timeout))
        json.dump(meta_doc, handle, ensure_ascii=False, indent=2)

    print("", file=sys.stderr)
    print("%d requête(s) × %d système(s) → %d candidat(s) à annoter"
          % (len(queries), len(systems), len(order)), file=sys.stderr)
    if known_grades:
        print("  %d déjà jugé(s) dans %s, %d nouveau(x) à juger"
              % (prefilled, args.grades, len(order) - prefilled), file=sys.stderr)
    print("  %s" % tsv, file=sys.stderr)
    print("  %s" % runs_dir, file=sys.stderr)
    if failures:
        print("  %d exécution(s) en échec :" % len(failures), file=sys.stderr)
        for name, query, error in failures[:10]:
            print("    %-14s %-40s %s" % (name, query[:40], error),
                  file=sys.stderr)


if __name__ == "__main__":
    main()
