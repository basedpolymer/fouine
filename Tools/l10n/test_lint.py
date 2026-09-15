#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""Tests unitaires pour le linter de localisation (Tools/l10n/lint.py).

Vérifie :
  1. L'extraction des ternaires mono-ligne et multi-lignes.
  2. L'extraction des seconds arguments (fonction `check(...)` des réglages).
  3. Le respect des chaînes contenant des virgules ou parenthèses.
  4. L'absence de faux positifs et de clés orphelines sur le dépôt courant.
  5. La typographie française : la passe de `typography.py`, les trois règles
     de lint qui l'exigent, et l'état des deux catalogues du dépôt (lot L2).

    python3 Tools/l10n/test_lint.py
"""
import contextlib
import importlib.util
import io
import json
import os
import sys
import tempfile
import unittest
from unittest import mock

HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, HERE)
import lint
import typography


class TestL10nLint(unittest.TestCase):

    def test_ternary_literals_single_line(self):
        segment = 'cond ? "First Option" : "Second Option"'
        literals = lint.ternary_literals(segment)
        self.assertEqual(literals, ["First Option", "Second Option"])

    def test_ternary_literals_multiline(self):
        segment = (
            'search.semanticPreparing\n'
            '    ? "preparing semantic search…"\n'
            '    : "searching…"'
        )
        literals = lint.ternary_literals(segment)
        self.assertEqual(literals, ["preparing semantic search…", "searching…"])

    def test_ternary_literals_no_ternary(self):
        segment = '"Only a plain string"'
        literals = lint.ternary_literals(segment)
        self.assertEqual(literals, [])

    def test_first_argument_multiline_with_quotes(self):
        lines = [
            'Button("Cancel", role: .cancel) { model.cancel() }\n',
            '    .help("Stops the transfer at once. Nothing is installed, and the partial archive is deleted.")\n',
        ]
        col = lines[1].find(".help(") + len(".help(")
        arg = lint.first_argument(lines, 1, col)
        self.assertIn("Nothing is installed, and the partial archive", arg)

    def test_second_argument_extraction(self):
        # Sur une seule ligne
        lines = [
            'check(SettingKeys.agentRequireAC, "Only run OCR on mains power")\n'
        ]
        col = lines[0].find("check(") + len("check(")
        arg2 = lint.second_argument(lines, 0, col)
        self.assertIsNotNone(arg2)
        text, _ = lint.read_literal(arg2.strip(), 0)
        self.assertEqual(text, "Only run OCR on mains power")

        # Coupé sur plusieurs lignes
        multiline = [
            'check(SettingKeys.agentPauseOnThermal,\n',
            '      "Suspend when the machine heats up")\n',
        ]
        col_m = multiline[0].find("check(") + len("check(")
        arg2_m = lint.second_argument(multiline, 0, col_m)
        self.assertIsNotNone(arg2_m)
        text_m, _ = lint.read_literal(arg2_m.strip(), 0)
        self.assertEqual(text_m, "Suspend when the machine heats up")

    def test_shape_of_key_treats_shortcut_parameters_as_holes(self):
        # Le résumé `Summary("Open \\(\\.$hit) in Fouine")` d'une action
        # Raccourcis a pour clé de catalogue `Open ${hit} in Fouine`.
        self.assertEqual(lint.shape_of_key("Open ${hit} in Fouine"),
                         lint.shape_of_literal("Open \\(\\.$hit) in Fouine"))
        self.assertEqual(lint.shape_of_key("Search for ${query} in Fouine"),
                         "Search for " + lint.HOLE + " in Fouine")
        # Un dollar seul, ou un `${` sans nom, n'est pas un trou.
        self.assertEqual(lint.shape_of_key("Price: $5"), "Price: $5")

    def test_full_l10n_lint_produces_zero_orphans_and_zero_missing(self):
        app = lint.catalog(lint.APP_CATALOG)
        shapes = {lint.shape_of_key(k) for k in app.get("strings", {})}
        used = lint.swift_literals()

        missing = set(used) - shapes
        self.assertEqual(missing, set(), f"Chaînes visibles non traduites : {missing}")

        orphans = set(shapes) - set(used)
        self.assertEqual(orphans, set(), f"Clés orphelines dans le catalogue : {orphans}")


class TestAddStrings(unittest.TestCase):
    """`add-strings.py` reconnaît une clé déjà présente à sa ligne ENTIÈRE.

    Le défaut noté le 10/09 : un test par sous-chaîne croyait « Update »
    présente parce que « Update now » l'était, et la clé n'entrait jamais au
    catalogue. La comparaison porte depuis sur la clé décodée de la ligne
    `    "clé": {` ; ce test la tient (lot MN2)."""

    def _module(self):
        spec = importlib.util.spec_from_file_location(
            "add_strings", os.path.join(HERE, "add-strings.py"))
        module = importlib.util.module_from_spec(spec)
        spec.loader.exec_module(module)
        return module

    def _run(self, module, pairs):
        with tempfile.NamedTemporaryFile("w", suffix=".json", delete=False,
                                         encoding="utf-8") as handle:
            json.dump(pairs, handle, ensure_ascii=False)
        out = io.StringIO()
        try:
            with mock.patch.object(sys, "argv", ["add-strings.py", handle.name]), \
                    contextlib.redirect_stdout(out):
                module.main()
        finally:
            os.unlink(handle.name)
        return out.getvalue()

    def test_a_key_is_not_mistaken_for_a_longer_one(self):
        module = self._module()
        with tempfile.TemporaryDirectory() as tmp:
            module.CATALOG = os.path.join(tmp, "Localizable.xcstrings")
            existing = module.block("Update now", "Update now", "Mettre à jour")
            existing[-1] = existing[-1].rstrip(",")
            with open(module.CATALOG, "w", encoding="utf-8") as handle:
                handle.write("\n".join(['{', '  "sourceLanguage": "en",',
                                        '  "strings": {'] + existing
                                       + ['  },', '  "version": "1.0"', '}']))

            first = self._run(module, {"Update": "Actualiser"})
            self.assertIn("ajoutée : Update", first)
            with open(module.CATALOG, encoding="utf-8") as handle:
                keys = json.load(handle)["strings"].keys()
            self.assertEqual(set(keys), {"Update", "Update now"})

            second = self._run(module, {"Update": "Actualiser"})
            self.assertIn("déjà là : Update", second)


class TestFrenchTypography(unittest.TestCase):
    """La typographie française : ce que la passe pose, ce que le lint exige.

    Les trois défauts venaient d'un catalogue que personne ne relisait
    caractère par caractère (audits BU-10, AP-20, AP-19). Les tests ci-dessous
    sont ce qui les empêche de revenir avec la prochaine chaîne."""

    def test_curly_apostrophe_and_narrow_space(self):
        self.assertEqual(typography.fix_value("l'index n'est pas prêt"),
                         "l’index n’est pas prêt")
        self.assertEqual(typography.fix_value("Prêt : oui ; sûr ? non !"),
                         "Prêt : oui ; sûr ? non !")

    def test_specifiers_are_left_alone(self):
        # Le découpage sur les spécificateurs : rien ne doit s'insérer dedans,
        # et le texte autour reste corrigé.
        self.assertEqual(typography.fix_value("%1$@ n'a pas pu être lu : %2$@"),
                         "%1$@ n’a pas pu être lu : %2$@")
        self.assertEqual(typography.fix_value("%#@total@ : %arg1 pages"),
                         "%#@total@ : %arg1 pages")

    def test_pass_is_idempotent(self):
        once = typography.fix_value("l'index : %lld page ; prêt ?")
        self.assertEqual(typography.fix_value(once), once)

    def test_straight_apostrophe_fails_the_lint(self):
        problems = self._lint({"Ready": "l'index est prêt"})
        self.assertEqual(len(problems), 1, problems)
        self.assertIn("« Ready »", problems[0])
        self.assertIn("apostrophe", problems[0])

    def test_loose_space_before_double_punctuation_fails_the_lint(self):
        for value in ["Prêt : oui", "Prêt ; oui", "Prêt ?", "Prêt !"]:
            problems = self._lint({"Ready": value})
            self.assertEqual(len(problems), 1, value)
            self.assertIn("insécable", problems[0])
        # Collée ou déjà insécable : rien à dire. Et « dossier: » — un préfixe
        # du langage de requête — n'a pas d'espace : il ne doit pas être touché.
        for value in ["Prêt : oui", "Prêt : oui", "dossier: Thèse",
                      "10:30"]:
            self.assertEqual(self._lint({"Ready": value}), [], value)

    def test_parenthesised_agreement_fails_the_lint(self):
        for value in ["%lld ignoré(s)", "%lld chargée(s)", "prise(s) en charge"]:
            problems = self._lint({"%lld skipped": value})
            self.assertEqual(len(problems), 1, value)
            self.assertIn("parenthèse d'accord", problems[0])

    def test_substitutions_are_checked_too(self):
        """Le texte d'une `substitution` s'affiche comme le reste."""
        entry = {"extractionState": "manual",
                 "localizations": {"fr": {
                     "stringUnit": {"state": "translated",
                                    "value": "Page %lld sur %#@total@"},
                     "substitutions": {"total": {
                         "argNum": 2, "formatSpecifier": "lld",
                         "variations": {"plural": {
                             "one": {"stringUnit": {"state": "translated",
                                                    "value": "%arg page"}},
                             "other": {"stringUnit": {
                                 "state": "translated",
                                 "value": "%arg pages porteuses d'un texte"}}}}}}}}}
        problems = []
        with self._catalog({"Page %lld of %lld pages": entry}) as path:
            lint.check_french_typography(path, problems)
        self.assertEqual(len(problems), 1, problems)
        self.assertIn("apostrophe", problems[0])

    def test_both_catalogues_of_the_repository_are_clean(self):
        """La mesure de l'audit, refaite : 0 apostrophe droite, 0 espace
        ordinaire devant une ponctuation double, 0 parenthèse d'accord."""
        problems = []
        lint.check_french_typography(lint.APP_CATALOG, problems)
        lint.check_french_typography(lint.PLIST_CATALOG, problems)
        self.assertEqual(problems, [], "\n".join(problems))

    def test_the_repository_catalogues_need_no_further_pass(self):
        """`typography.py` ne trouve plus rien à corriger : la passe a été
        jouée, et le catalogue ne se corrige plus qu'à l'ajout."""
        for path in typography.CATALOGS:
            _lines, changes = typography.rewrite(path)
            self.assertEqual(changes, [], os.path.basename(path))

    # --- outillage ---------------------------------------------------------

    class _TemporaryCatalog:
        def __init__(self, strings):
            self.strings = strings

        def __enter__(self):
            self.handle = tempfile.NamedTemporaryFile(
                "w", suffix=".xcstrings", delete=False, encoding="utf-8")
            json.dump({"sourceLanguage": "en", "version": "1.0",
                       "strings": self.strings}, self.handle,
                      ensure_ascii=False)
            self.handle.close()
            return self.handle.name

        def __exit__(self, *_):
            os.unlink(self.handle.name)

    def _catalog(self, strings):
        return self._TemporaryCatalog(strings)

    def _lint(self, french):
        """Les problèmes que le contrôle 5 lève sur {clé: valeur française}."""
        strings = {
            key: {"extractionState": "manual",
                  "localizations": {
                      "en": {"stringUnit": {"state": "translated",
                                            "value": key}},
                      "fr": {"stringUnit": {"state": "translated",
                                            "value": value}}}}
            for key, value in french.items()}
        problems = []
        with self._catalog(strings) as path:
            lint.check_french_typography(path, problems)
        return problems


if __name__ == "__main__":
    unittest.main()
