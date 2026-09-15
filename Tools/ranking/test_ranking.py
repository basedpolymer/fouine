#!/usr/bin/env python3
# test_ranking.py — les trois scripts du banc sur un pool fabriqué.
#
# python3 système, AUCUNE dépendance : `python3 -m unittest Tools/ranking/test_ranking.py`
# (cible `make check-ranking`). Pas de `fouine` ici : on ne teste ni la
# recherche ni le serveur MCP, seulement la lecture des fichiers, les
# métriques et leurs conventions (candidat non noté = 0, requête en échec
# écartée pour tous, idéal sur tous les jugements connus, nDCG par document).

import io
import json
import math
import os
import shutil
import sys
import tempfile
import unittest
from contextlib import redirect_stdout, redirect_stderr

HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, HERE)

import annotate    # noqa: E402
import evaluate    # noqa: E402
import pool        # noqa: E402


def write_run(runs_dir, system, records):
    with open(os.path.join(runs_dir, system + ".jsonl"), "w", encoding="utf-8") as handle:
        for record in records:
            handle.write(json.dumps(record, ensure_ascii=False) + "\n")


def hit(doc, page, semantic_only=False):
    return {"doc_id": doc, "page": page, "path": "Livres/d%d.pdf" % doc,
            "semantic_only": semantic_only}


class PoolFixture:
    """Deux systèmes, trois requêtes : `a` (les deux classent différemment),
    `"b c"` (même classement), `zz` (B en échec) ; une absurde sans hit."""

    def __init__(self):
        self.dir = tempfile.mkdtemp(prefix="fouine-banc-")
        runs = os.path.join(self.dir, "runs")
        os.makedirs(runs)
        write_run(runs, "A", [
            {"query": "a", "category": "simple", "system": "A",
             "hits": [hit(1, 1), hit(1, 2), hit(2, 5), hit(3, 7)]},
            {"query": '"b c"', "category": "exacte", "system": "A",
             "hits": [hit(4, 1), hit(5, 2)]},
            {"query": "zz", "category": "simple", "system": "A", "hits": [hit(6, 1)]},
            {"query": "tarte", "category": "absurde", "system": "A",
             "hits": [hit(9, 9, semantic_only=True)]},
        ])
        write_run(runs, "B", [
            {"query": "a", "category": "simple", "system": "B",
             "hits": [hit(2, 5), hit(3, 7), hit(1, 1), hit(1, 2)]},
            {"query": '"b c"', "category": "exacte", "system": "B",
             "hits": [hit(4, 1), hit(5, 2)]},
            {"query": "zz", "category": "simple", "system": "B",
             "error": "timeout", "hits": []},
            {"query": "tarte", "category": "absurde", "system": "B", "hits": []},
        ])
        rows = [
            ("a", 1, 1, "2", "A:1;B:3"), ("a", 1, 2, "", "A:2;B:4"),
            ("a", 2, 5, "1", "A:3;B:1"), ("a", 3, 7, "0", "A:4;B:2"),
            ('"b c"', 4, 1, "2", "A:1;B:1"), ('"b c"', 5, 2, "", "A:2;B:2"),
            ("zz", 6, 1, "1", "A:1"), ("tarte", 9, 9, "", "A:1"),
        ]
        with open(os.path.join(self.dir, "candidates.tsv"), "w", encoding="utf-8") as handle:
            handle.write("query\tdoc_id\tpage\tgrade\tpath\tsnippet\tsystems\n")
            for query, doc, page, grade, systems in rows:
                handle.write("\t".join([query, str(doc), str(page), grade,
                                        "Livres/d%d.pdf" % doc, "extrait", systems]) + "\n")
        with open(os.path.join(self.dir, "queries.json"), "w", encoding="utf-8") as handle:
            json.dump({"queries": [{"query": "a", "category": "simple"},
                                   {"query": '"b c"', "category": "exacte"},
                                   {"query": "zz", "category": "simple"},
                                   {"query": "tarte", "category": "absurde"}],
                       "systems": [{"name": "A", "args": []}, {"name": "B", "args": ["--x"]}],
                       "limit": 10}, handle)

    def evaluate(self, *extra):
        out = io.StringIO()
        argv = sys.argv
        sys.argv = ["evaluate.py", "--dir", self.dir] + list(extra)
        try:
            with redirect_stdout(out):
                evaluate.main()
        finally:
            sys.argv = argv
        return out.getvalue()

    def close(self):
        shutil.rmtree(self.dir, ignore_errors=True)


class MetricsTests(unittest.TestCase):
    def test_dcg_and_ndcg(self):
        self.assertAlmostEqual(evaluate.dcg([2, 0, 1]), 3.0 + 0.0 + 1.0 / math.log2(4))
        self.assertAlmostEqual(evaluate.ndcg_at_k([2, 1], [2, 1], 10), 1.0)
        self.assertAlmostEqual(evaluate.ndcg_at_k([1, 2], [2, 1], 10),
                               (1 + 3 / math.log2(3)) / (3 + 1 / math.log2(3)))
        self.assertEqual(evaluate.ndcg_at_k([0, 0], [], 10), 0.0)

    def test_doc_gains_take_the_best_page_in_first_appearance_order(self):
        grades = {("q", 1, 1): 0, ("q", 1, 2): 2, ("q", 2, 5): 1}
        hits = [hit(1, 1), hit(2, 5), hit(1, 2)]
        self.assertEqual(evaluate.doc_gains(hits, grades, "q", 10), [2, 1])
        self.assertEqual(evaluate.doc_gains(hits, grades, "q", 2), [0, 1])

    def test_paired_test_is_one_on_no_difference_and_small_on_a_clear_one(self):
        self.assertEqual(evaluate.paired_test([0.0, 0.0, 0.0]), 1.0)
        self.assertTrue(math.isnan(evaluate.paired_test([])))
        self.assertLess(evaluate.paired_test([0.2] * 12), 0.01)
        self.assertGreater(evaluate.paired_test([0.2, -0.2, 0.1, -0.1]), 0.3)


class EvaluateReportTests(unittest.TestCase):
    def setUp(self):
        self.fixture = PoolFixture()

    def tearDown(self):
        self.fixture.close()

    def test_failed_query_is_excluded_for_every_system(self):
        report = self.fixture.evaluate()
        self.assertIn("requêtes écartées pour échec d'exécution : **1** — `zz` (B)", report)
        # `zz` porte une note, mais la comparaison reste appariée : 2 requêtes.
        self.assertIn("| `A` | 2 |", report)
        self.assertIn("| `B` | 2 |", report)

    def test_page_and_document_ndcg_follow_the_conventions(self):
        report = self.fixture.evaluate()
        # Requête a, système A : notes [2, 0(non notée), 1, 0], idéal [2, 1, 0].
        ideal = evaluate.dcg([2, 1, 0])
        a_ndcg = evaluate.dcg([2, 0, 1, 0]) / ideal
        b_ndcg = evaluate.dcg([1, 0, 2, 0]) / ideal
        # "b c" : [2, 0] / idéal [2] = 1 pour les deux.
        line_a = next(l for l in report.splitlines() if l.startswith("| `A` |"))
        line_b = next(l for l in report.splitlines() if l.startswith("| `B` |"))
        self.assertIn("| %.3f |" % ((a_ndcg + 1.0) / 2), line_a)
        self.assertIn("| %.3f |" % ((b_ndcg + 1.0) / 2), line_b)
        # Par document, requête a : A → docs [1 (2), 2 (1), 3 (0)] = idéal → 1 ;
        # B → [2 (1), 3 (0), 1 (2)].
        b_doc = evaluate.dcg([1, 0, 2]) / evaluate.dcg([2, 1, 0])
        # docs / top-10 : 3 documents sur `a`, 2 sur `"b c"` → 2,5 pour les deux.
        self.assertIn("| 1.000 | 2.5 |", line_a)
        self.assertIn("| %.3f | 2.5 |" % ((b_doc + 1.0) / 2), line_b)
        # Bruit absurde : A a rendu un hit sémantique pur sur « tarte ».
        self.assertIn("| 1 / 1 |", line_a)
        self.assertIn("| 0 / 1 |", line_b)

    def test_paired_table_names_the_baseline_and_counts_wins(self):
        report = self.fixture.evaluate("--baseline", "A")
        self.assertIn("Contre la référence `A`", report)
        paired = report.split("Contre la référence", 1)[1]
        line = next(l for l in paired.splitlines() if l.startswith("| `B` | "))
        # B perd sur `a`, égalité sur `"b c"` : 0 victoire, 1 égalité, 1 défaite,
        # par page comme par document.
        self.assertEqual(line.count("| 0 / 1 / 1 |"), 2)

    def test_per_query_and_by_category_tables(self):
        report = self.fixture.evaluate("--per-query", "--by-category")
        self.assertIn("## Requête par requête", report)
        self.assertIn('| `"b c"` | exacte | 1.000 | 1.000 |', report)
        self.assertIn("## Par catégorie", report)
        self.assertIn("| exacte | 1 | `A` |", report)

    def test_grades_file_wins_over_the_pool_column(self):
        with open(os.path.join(self.fixture.dir, "grades.tsv"), "w", encoding="utf-8") as handle:
            handle.write("query\tdoc_id\tpage\tgrade\tnote\tjudged_at\tpath\n")
            handle.write("a\t1\t1\t0\t\t\t\n")          # la colonne disait 2
        report = self.fixture.evaluate()
        self.assertIn("(1 notes lues dans `grades.tsv`", report)
        line_a = next(l for l in report.splitlines() if l.startswith("| `A` |"))
        a_ndcg = evaluate.dcg([0, 0, 1, 0]) / evaluate.dcg([1, 0, 0])
        self.assertIn("| %.3f |" % ((a_ndcg + 1.0) / 2), line_a)


class PoolAndAnnotateTests(unittest.TestCase):
    def setUp(self):
        self.fixture = PoolFixture()

    def tearDown(self):
        self.fixture.close()

    def test_missing_grades_file_is_not_an_error(self):
        err = io.StringIO()
        with redirect_stderr(err):
            grades = pool.read_grades(os.path.join(self.fixture.dir, "absent.tsv"))
        self.assertEqual(grades, {})
        self.assertIn("aucun jugement encore", err.getvalue())

    def test_read_grades_keeps_quoted_queries_apart(self):
        path = os.path.join(self.fixture.dir, "g.tsv")
        with open(path, "w", encoding="utf-8") as handle:
            handle.write("query\tdoc_id\tpage\tgrade\n")
            handle.write('"b c"\t4\t1\t2\n')
            handle.write("b c\t4\t1\t0\n")
        grades = pool.read_grades(path)
        self.assertEqual(grades[('"b c"', 4, 1)], "2")
        self.assertEqual(grades[("b c", 4, 1)], "0")

    def test_describe_binary_reports_what_it_can(self):
        info = pool.describe_binary("/nonexistent/fouine")
        self.assertEqual(info["fouine"], "/nonexistent/fouine")
        self.assertNotIn("fouine_version", info)

    def test_provenance_carries_the_state_of_the_corpus(self):
        """RK-14 : deux pools ne se comparent ligne à ligne que s'ils ont vu les
        mêmes documents. `queries.json` porte donc le compte de documents, de
        pages et de pages vectorisées, lus dans `fouine status --json`."""
        state = pool.corpus_from_status({
            "docs_total": 1541, "pages_indexed": 409156, "pages_vec": 274244,
            "db_bytes": 2157269144, "roots": []})
        self.assertEqual(state, {"docs_total": 1541, "pages_indexed": 409156,
                                 "pages_vec": 274244})
        # Un `status` d'un binaire plus ancien, ou muet : on écrit ce qu'on a.
        self.assertEqual(pool.corpus_from_status({"docs_total": 3}),
                         {"docs_total": 3})
        self.assertEqual(pool.corpus_from_status({"pages_indexed": "beaucoup"}), {})
        self.assertEqual(pool.corpus_from_status(None), {})

    def test_a_binary_that_cannot_be_asked_is_not_an_error(self):
        err = io.StringIO()
        with redirect_stderr(err):
            state = pool.describe_corpus("/nonexistent/fouine", None)
        self.assertEqual(state, {})
        self.assertIn("état du corpus indisponible", err.getvalue())

    def test_load_pool_reads_both_systems_formats_and_marks_differences(self):
        blocks, systems, limit = annotate.load_pool(self.fixture.dir)
        self.assertEqual(systems, ["A", "B"])
        self.assertEqual(limit, 10)
        by_query = {b.query: b for b in blocks}
        self.assertEqual(by_query["a"].n_diff, 4)
        self.assertEqual(by_query['"b c"'].n_diff, 0)
        self.assertEqual(by_query["zz"].n_diff, 1)     # rendu par A seul
        self.assertEqual([b.query for b in annotate.walk_order(blocks)][0], "a")
        meta = os.path.join(self.fixture.dir, "queries.json")
        with open(meta, encoding="utf-8") as handle:
            doc = json.load(handle)
        doc["systems"] = ["A", "B"]                     # format d'avant
        with open(meta, "w", encoding="utf-8") as handle:
            json.dump(doc, handle)
        _, systems, _ = annotate.load_pool(self.fixture.dir)
        self.assertEqual(systems, ["A", "B"])

    def test_absurd_queries_are_documented_as_touching_nothing(self):
        """RK-13 : la catégorie « absurde » mesure le bruit du canal sémantique.
        Deux de ses requêtes touchaient la notice d'un four à micro-ondes et ses
        recettes ; le fichier livré ne doit plus porter ces deux-là, et il doit
        dire la règle."""
        path = os.path.join(HERE, "queries.txt")
        with open(path, encoding="utf-8") as handle:
            text = handle.read()
        self.assertIn("ne doit toucher AUCUN document", text)
        absurdes = [q for q, c in pool.read_queries(path) if c == "absurde"]
        self.assertEqual(len(absurdes), 5)
        for cuisine in ("tarte", "tomates", "recette"):
            self.assertFalse(any(cuisine in q for q in absurdes),
                             "« %s » touche la notice du four (doc 1)" % cuisine)

    def test_query_terms_and_spans(self):
        terms = annotate.query_terms('pres:5 "energie libre" -chimie thermodyn*', "«énergie»")
        self.assertIn(("energie", False), terms)
        self.assertIn(("libre", False), terms)
        self.assertIn(("thermodyn", True), terms)
        self.assertNotIn(("chimie", False), terms)
        spans = annotate.find_spans("L'Énergie libre, thermodynamique.", terms)
        self.assertEqual([("L'Énergie libre, thermodynamique."[a:b]) for a, b in spans],
                         ["Énergie", "libre", "thermodynamique"])


if __name__ == "__main__":
    unittest.main()
