// ExclusionRefusalTests.swift — ce qui s'exclut, ce qui se refuse (lot MN1).
// Propriété : A-Core. SPEC §4, §5.5.1.
//
// CE QUI EST PROUVÉ ICI, ET POURQUOI. `-type:pdf` n'était ni un filtre ni un
// refus : il devenait la négation du MOT « type:pdf », c'est-à-dire, une fois
// échappé pour FTS5, la phrase « type pdf » — elle n'exclut pas les PDF (ce
// qui était demandé) et peut exclure un document qui porte ces deux mots à la
// suite (ce qui ne l'était pas). Deux fautes en une, et aucune ne se dit.
//
// La décision du 14/09/2026 : les quatre filtres qui désignent un ensemble de
// DOCUMENTS s'excluent tous (c'était déjà le cas depuis MC1) ; tout autre
// `-préfixe:valeur` est REFUSÉ en nommant la règle, au négatif comme au
// positif. Et quand aucune exclusion n'est écrite, le SQL est celui d'avant au
// caractère près.

import XCTest
@testable import FouineCore

final class ExclusionRefusalTests: XCTestCase {

    private func plan(_ input: String) throws -> (query: SearchQuery, negative: String?) {
        try QueryParser.searchPlan(input)
    }

    // MARK: - Les quatre qui s'excluent (rappel, lot MC1)

    func testTheFourDocumentFiltersStillExclude() throws {
        XCTAssertEqual(try plan("azote -dossier:Cours").query.folderExcludes, ["Cours"])
        XCTAssertEqual(try plan("azote -folder:Cours").query.folderExcludes, ["Cours"])
        XCTAssertEqual(try plan("azote -ext:MD").query.extExcludes, ["md"])
        XCTAssertEqual(try plan("azote -nom:brouillon").query.nameExcludes, ["brouillon"])
        XCTAssertEqual(try plan("azote -name:brouillon").query.nameExcludes, ["brouillon"])
        XCTAssertEqual(try plan("azote -chemin:Archive").query.pathExcludes, ["Archive"])
        XCTAssertEqual(try plan("azote -path:Archive").query.pathExcludes, ["Archive"])
        // La valeur entre guillemets, comme au positif.
        XCTAssertEqual(try plan("azote -dossier:\"Mes cours\"").query.folderExcludes,
                       ["Mes cours"])
    }

    // MARK: - Ce qui ne s'exclut pas se REFUSE

    /// `-type:pdf` : le même refus que `type:pdf`, et la même phrase — c'est la
    /// même faute, et le tiret n'en change pas la nature.
    func testAnUnknownPrefixIsRefusedInTheNegativeToo() throws {
        for input in ["azote -type:pdf", "azote -dans:Livres", "azote -TYPE:pdf"] {
            XCTAssertThrowsError(try plan(input), input) { error in
                guard case .unknownPrefix(let prefix, _)? = error as? QueryError else {
                    return XCTFail("refus attendu pour « \(input) » : \(error)")
                }
                XCTAssertTrue(["type:", "dans:"].contains(prefix), prefix)
                XCTAssertEqual((error as? QueryError)?.errorDescription,
                               "“\(prefix)” is not a filter — filters are "
                               + "dossier:/folder:, ext:, pres:/near:, "
                               + "nom:/name:, texte:/body:, chemin:/path:")
            }
        }
    }

    /// `-texte:` et `-pres:` EXISTENT au positif et ne désignent pas un
    /// ensemble de documents : un refus DÉDIÉ (lot MN2), qui ne prétend plus
    /// que `texte:` n'est pas un filtre, nomme ceux qui s'excluent et dit le
    /// geste qui écarte un mot.
    ///
    /// Le préfixe est cité sans son tiret, en minuscules, tel que la
    /// grammaire le connaît.
    func testAKnownPrefixThatCannotBeExcludedIsRefusedWithTheRule() throws {
        for (input, prefix) in [("azote -texte:reacteur", "texte:"),
                                ("azote -body:reactor", "body:"),
                                ("azote -pres:5", "pres:"),
                                ("azote -NEAR:5", "near:")] {
            XCTAssertThrowsError(try plan(input), input) { error in
                XCTAssertEqual(error as? QueryError,
                               .notExcludable(prefix,
                                              excludable: QueryParser.excludablePrefixLabels),
                               input)
                let expected = "“\(prefix)” cannot be excluded. The filters that "
                    + "can are dossier:/folder:, ext:, nom:/name:, chemin:/path:. "
                    + "To leave out a word, write -word."
                XCTAssertEqual((error as? QueryError)?.errorDescription, expected)
            }
        }
    }

    /// CE QUI RESTE UNE EXCLUSION DE MOT. Mêmes exceptions qu'au positif : des
    /// chiffres avant le deux-points, une adresse, une seule lettre, une valeur
    /// vide — plus le mot ordinaire, qui est le cas courant.
    func testWordExclusionsAreUntouched() throws {
        for (input, negative) in [("azote -biologie", "biologie"),
                                  ("azote -10:30", "\"10:30\""),
                                  ("azote -https://exemple.org",
                                   "\"https://exemple.org\""),
                                  ("azote -t:x", "\"t:x\""),
                                  ("azote -ext:", nil)] {
            let plan = try plan(input)
            XCTAssertEqual(plan.negative, negative, input)
            XCTAssertEqual(plan.query.fts, "azote", input)
        }
        // Entre guillemets, rien n'est un filtre : c'est une phrase.
        XCTAssertEqual(try QueryParser.parse("\"-type:pdf\"").fts(), "\"-type:pdf\"")
    }

    // MARK: - Le SQL ne bouge pas quand aucune exclusion n'est écrite

    /// Le patron du lot P3, repris par MC1 : à exclusion non écrite, le SQL est
    /// celui d'avant au caractère près — la garde de ce lot est un REFUS dans
    /// l'analyseur, elle n'ajoute pas une clause.
    func testSQLIsUnchangedWhenNothingIsExcluded() throws {
        let db = try makeDB()
        let positives = ["azote", "azote dossier:Livres", "azote ext:pdf",
                         "azote nom:rapport", "azote chemin:Offres",
                         "azote texte:reacteur", "pres:5 azote reacteur"]
        for input in positives {
            let q = try plan(input).query
            XCTAssertTrue(q.folderExcludes.isEmpty && q.extExcludes.isEmpty
                          && q.nameExcludes.isEmpty && q.pathExcludes.isEmpty,
                          input)
            XCTAssertTrue(GRDBStore.pathAndExcludeClauses(q, alias: "").clauses
                            .filter { $0.contains("NOT IN") }.isEmpty, input)
            XCTAssertNil(GRDBStore.nameExcludeExpression(q), input)
        }
        // Une requête nue : aucune clause du tout, comme avant MC1.
        let plain = try plan("azote").query
        let filter = db.store.docFilter(plain, column: "d", page: "p", negative: nil)
        XCTAssertEqual(filter.sql, "")
        XCTAssertEqual(filter.join, "")
        XCTAssertTrue(filter.args.isEmpty)
        // Un filtre POSITIF de dossier : la clause est exactement celle d'avant.
        let folder = try plan("azote dossier:Livres").query
        XCTAssertEqual(db.store.docFilter(folder, column: "d", page: "p",
                                          negative: nil).sql,
                       " AND d IN (SELECT id FROM docs WHERE top_folder IN (?))")
    }
}
