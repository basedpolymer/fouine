// SearchModelExclusionTests.swift — audit F1 : `-terme` dans l'app.
// Propriété : A-App.
//
// Le bogue corrigé ici : `QueryParser.fts()` retire les `.not` de l'expression
// MATCH (arbitrage T5, l'exclusion porte sur le DOCUMENT), si bien que
// l'exclusion ne vit plus que dans `plan.negative`. `SearchModel` la calculait
// puis la jetait partout sauf sur le chemin hybride — éteint par défaut. En
// mode lexical, `-terme` n'avait donc AUCUN effet, en silence.
//
// La référence est la CLI (`fouine search`, `CommandsSearch.run`) : elle appelle
// `store.search(q, excludingDocsMatching: negative)` et
// `store.facets(q, by:, excludingDocsMatching: negative)`. Chaque test compare
// donc l'app à cet appel-là, sur la MÊME base.

import XCTest
import FouineCore
@testable import FouineApp

@MainActor
final class SearchModelExclusionTests: XCTestCase {

    /// Deux documents : l'un porte « alpha beta », l'autre « alpha » seul.
    private func fixture() throws -> (db: TempAppDB, avecBeta: Int64,
                                      sansBeta: Int64, model: SearchModel) {
        let db = try TempAppDB()
        let avecBeta = try db.addDoc(
            relPath: "Users/essai/un.txt",
            pages: ["alpha beta gamma : ce document doit être écarté."])
        let sansBeta = try db.addDoc(
            relPath: "Users/essai/deux.txt",
            pages: ["alpha delta epsilon : ce document doit rester."])
        return (db, avecBeta, sansBeta, SearchModel(service: db.service))
    }

    // MARK: - Le chemin lexical (le défaut de l'app)

    func testExclusionAppliqueeEnLexical() async throws {
        let f = try fixture()
        await run(f.model, "alpha")
        XCTAssertEqual(Set(f.model.hits.map(\.docID)), [f.avecBeta, f.sansBeta],
                       "sans exclusion, les deux documents répondent")
        XCTAssertEqual(f.model.totalDocs, 2)

        await run(f.model, "alpha -beta")
        XCTAssertEqual(f.model.hits.map(\.docID), [f.sansBeta],
                       "F1 : « alpha -beta » ne doit rendre que le document sans beta")
        XCTAssertEqual(f.model.totalPages, 1)
        XCTAssertEqual(f.model.totalDocs, 1)
        XCTAssertEqual(f.model.executedNegative, "beta",
                       "l'exclusion doit être retenue pour les requêtes suivantes")
    }

    /// L'app doit rendre EXACTEMENT ce que rend la CLI sur la même base.
    func testMemeResultatQueLaCLI() async throws {
        let f = try fixture()
        await run(f.model, "alpha -beta")

        let plan = try QueryParser.searchPlan("alpha -beta",
                                              limit: SearchModel.pageSize)
        let cli = try f.db.store.search(plan.query,
                                        excludingDocsMatching: plan.negative)
        XCTAssertEqual(f.model.hits.map(\.docID), cli.hits.map(\.docID))
        XCTAssertEqual(f.model.hits.map(\.page), cli.hits.map(\.page))
        XCTAssertEqual(f.model.totalPages, cli.totalPages)
        XCTAssertEqual(f.model.totalDocs, cli.totalDocs)
    }

    /// Portée DOCUMENT et non page (arbitrage T5) : une page sans « beta » d'un
    /// document qui en contient ailleurs reste écartée.
    func testExclusionPorteSurLeDocumentEntier() async throws {
        let db = try TempAppDB()
        let mixte = try db.addDoc(
            relPath: "Users/essai/mixte.txt",
            pages: ["alpha seul sur cette page.", "beta seul sur celle-ci."])
        let propre = try db.addDoc(relPath: "Users/essai/propre.txt",
                                   pages: ["alpha seul, partout."])
        let model = SearchModel(service: db.service)

        await run(model, "alpha")
        XCTAssertEqual(Set(model.hits.map(\.docID)), [mixte, propre])
        await run(model, "alpha -beta")
        XCTAssertEqual(model.hits.map(\.docID), [propre],
                       "T5 : la page 1 de « mixte » part avec son document")
    }

    // MARK: - Le repli du chemin hybride

    /// Requête dont il ne reste RIEN à encoder une fois les filtres et les
    /// exclusions retirés : `runHybrid` retombe immédiatement sur `runLexical`.
    /// C'est l'un des cinq sites de l'audit F1, et le seul atteignable sans
    /// modèle CoreML.
    func testRepliLexicalGardeLesExclusions() async throws {
        let f = try fixture()
        // `semanticEnabled` sans disponibilité laisse `useSemantic` faux : on
        // vérifie donc la branche directement, avec la même entrée que
        // `runHybrid` lui passerait.
        XCTAssertEqual(SearchModel.semanticText(of: "-beta alpha"), "alpha")
        XCTAssertEqual(SearchModel.semanticText(of: "dossier:Essai -beta"), "",
                       "rien à encoder : le chemin hybride retombe sur le lexical")

        await run(f.model, "alpha -beta")
        XCTAssertFalse(f.model.isHybrid)
        XCTAssertEqual(f.model.hits.map(\.docID), [f.sansBeta])
    }

    // MARK: - « Charger plus »

    /// La tranche suivante doit porter les mêmes exclusions que la première,
    /// sinon « Charger plus » réintroduit les documents écartés.
    func testChargerPlusGardeLesExclusions() async throws {
        let db = try TempAppDB()
        // Plus d'une tranche de résultats sans beta, plus quelques documents
        // avec : la pagination doit ignorer les seconds de bout en bout.
        let attendus = SearchModel.pageSize + 60
        for i in 0..<attendus {
            try db.addDoc(relPath: "Users/essai/sans-\(i).txt",
                          pages: ["alpha numéro \(i), sans le mot interdit."])
        }
        for i in 0..<5 {
            try db.addDoc(relPath: "Users/essai/avec-\(i).txt",
                          pages: ["alpha numéro \(i) avec beta dedans."])
        }
        let model = SearchModel(service: db.service)

        await run(model, "alpha -beta")
        XCTAssertEqual(model.totalPages, attendus,
                       "le total annoncé exclut déjà les documents à beta")
        XCTAssertEqual(model.hits.count, SearchModel.pageSize)
        XCTAssertTrue(model.canLoadMore)

        model.loadMore()
        await settle(model)
        XCTAssertEqual(model.hits.count, attendus)
        XCTAssertFalse(model.canLoadMore)
        let chemins = model.hits.map(\.path)
        XCTAssertFalse(chemins.contains { $0.contains("avec-") },
                       "F1 : « Charger plus » ne doit ramener aucun document exclu")
        XCTAssertEqual(Set(chemins).count, attendus, "aucun doublon de pagination")
    }

    // MARK: - Facettes

    /// Les facettes comptent SANS les documents exclus : sinon la barre
    /// latérale annonce 2 documents là où la liste en montre 1.
    func testFacettesComptentSansLesDocumentsExclus() async throws {
        let db = try TempAppDB()
        try db.addDoc(relPath: "Users/essai/un.txt", folder: "Essai",
                      pages: ["alpha beta : écarté."])
        try db.addDoc(relPath: "Users/essai/deux.txt", folder: "Essai",
                      pages: ["alpha seul : gardé."])
        try db.addDoc(relPath: "Users/essai/trois.md", ext: "md", folder: "Essai",
                      pages: ["alpha en markdown, gardé aussi."])
        let model = SearchModel(service: db.service)

        await run(model, "alpha")
        XCTAssertEqual(model.facets[.folder]?.first(where: { $0.0 == "Essai" })?.1, 3)

        await run(model, "alpha -beta")
        XCTAssertEqual(model.facets[.folder]?.first(where: { $0.0 == "Essai" })?.1, 2,
                       "F1 : la facette « Dossiers » ne compte pas le document exclu")
        XCTAssertEqual(model.facets[.ext]?.first(where: { $0.0 == "txt" })?.1, 1,
                       "un seul .txt survit à l'exclusion")
        XCTAssertEqual(model.facets[.ext]?.first(where: { $0.0 == "md" })?.1, 1)

        // Et la CLI compte pareil.
        let plan = try QueryParser.searchPlan("alpha -beta")
        let cli = try db.store.facets(plan.query, by: .folder,
                                      excludingDocsMatching: plan.negative)
        XCTAssertEqual(model.facets[.folder]?.map(\.1), cli.map(\.1))
    }

    /// Un filtre de facette coché n'efface pas l'exclusion : les deux se
    /// composent, comme les deux se composent côté CLI.
    func testExclusionEtFiltreDeFacetteSeComposent() async throws {
        let db = try TempAppDB()
        try db.addDoc(relPath: "Users/essai/un.txt", folder: "Essai",
                      pages: ["alpha beta : écarté."])
        try db.addDoc(relPath: "Users/essai/deux.txt", folder: "Essai",
                      pages: ["alpha seul : gardé."])
        try db.addDoc(relPath: "Users/autre/trois.txt", folder: "Autre",
                      pages: ["alpha ailleurs."])
        let model = SearchModel(service: db.service)

        model.text = "alpha -beta"
        model.selectedFolders = ["Essai"]      // didSet relance la recherche
        await settle(model)
        XCTAssertEqual(model.totalDocs, 1)
        XCTAssertEqual(model.hits.first?.path.contains("deux.txt"), true)
    }

    // MARK: - Surlignage

    /// On ne surligne JAMAIS un terme qu'on a demandé d'exclure, même s'il
    /// figure aussi en positif dans la requête.
    /// AUDIT-R1 M8 et B1 : « polymere polymeres » fait deux termes de deux
    /// couleurs, et non un mot absorbé comme variante de l'autre ; « entropy
    /// entropie » ne surligne pas « entropies » — le moteur ne l'a pas cherché.
    func testSurlignageDeDeuxMotsQuiSeDeclinentLUnVersLAutre() {
        let deux = QueryTerms.extract(from: "polymere polymeres")
        XCTAssertEqual(deux.map(\.folded), ["polymere", "polymeres"])
        XCTAssertEqual(Set(deux.map(\.colorIndex)).count, 2, "deux mots tapés, deux couleurs")

        let partage = QueryTerms.extract(from: "entropy entropie")
        XCTAssertEqual(partage.map(\.folded), ["entropy", "entropys", "entropie"],
                       "« entropies », forme commune, n'est cherchée par aucun des deux mots")
        XCTAssertEqual(Set(partage.map(\.colorIndex)).count, 2)
    }

    func testSurlignageIgnoreLesTermesExclus() {
        let termes = QueryTerms.extract(from: "alpha -beta")
        // « alphas » est la forme que le moteur cherche avec « alpha » (lot R1,
        // Morphology) : elle porte la couleur du mot tapé, jamais celle d'un
        // terme de plus.
        XCTAssertEqual(termes.map(\.folded), ["alpha", "alphas"])
        XCTAssertEqual(Set(termes.map(\.colorIndex)).count, 1,
                       "le pluriel partage la couleur du mot tapé")
        XCTAssertNil(QueryTerms.match("beta", in: termes))

        let contradictoire = QueryTerms.extract(from: "pres:3 alpha beta -beta")
        XCTAssertEqual(contradictoire.map(\.folded), ["alpha"],
                       "un terme exclu est retiré même s'il apparaît en positif")

        XCTAssertEqual(QueryTerms.excluded(from: "alpha -beta -gamma"),
                       ["beta", "gamma"])
        XCTAssertEqual(QueryTerms.excluded(from: "alpha"), [])
    }

    /// L'interface doit pouvoir DIRE qu'une exclusion est active.
    func testExclusionsExposeesAlInterface() async throws {
        let f = try fixture()
        await run(f.model, "alpha -beta")
        XCTAssertEqual(f.model.excludedTerms, ["beta"])
        await run(f.model, "alpha")
        XCTAssertEqual(f.model.excludedTerms, [])
        XCTAssertNil(f.model.executedNegative)
    }

    /// Une exclusion seule est refusée par l'analyse (`exclusionOnly`) : le
    /// message doit arriver à l'interface, pas une liste vide sans explication.
    func testExclusionSeuleEstUneErreurLisible() async throws {
        let f = try fixture()
        await run(f.model, "-beta")
        XCTAssertNotNil(f.model.errorText)
        XCTAssertTrue(f.model.hits.isEmpty)
    }
}
