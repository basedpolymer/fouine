// SavedSearchesTests.swift — les recherches épinglées (PR-17). Propriété : A-App.

import XCTest
@testable import FouineApp

@MainActor
final class SavedSearchesTests: XCTestCase {

    override func setUp() {
        super.setUp()
        // Domaine de préférences JETABLE : rien n'est écrit chez l'utilisateur,
        // et deux processus de test ne se relisent pas (`TestPrefs`).
        _ = TestPrefs.isolate
        Prefs.defaults.removeObject(forKey: Prefs.savedSearches)
    }

    private func saved(_ name: String, _ query: String) -> SavedSearch {
        SavedSearch(name: name, query: query)
    }

    func testAjoutAuBout() {
        var list = SavedSearches.adding(saved("Factures", "dossier:Factures 2025"),
                                        to: [])
        list = SavedSearches.adding(saved("Thèse", "polymère"), to: list)
        XCTAssertEqual(list.map(\.name), ["Factures", "Thèse"])
        XCTAssertEqual(list.first?.query, "dossier:Factures 2025",
                       "la requête est gardée telle que tapée, préfixe compris")
    }

    /// Même requête : le nom est remplacé, et la ligne ne bouge pas de place.
    func testMemeRequeteRemplaceLeNomSansDoublonNiDeplacement() {
        var list = SavedSearches.adding(saved("A", "alpha"), to: [])
        list = SavedSearches.adding(saved("B", "beta"), to: list)
        list = SavedSearches.adding(saved("Alpha, mieux dit", "alpha"), to: list)
        XCTAssertEqual(list.count, 2)
        XCTAssertEqual(list.map(\.name), ["Alpha, mieux dit", "B"])
    }

    func testRenommageEtSuppression() {
        var list = SavedSearches.adding(saved("A", "alpha"), to: [])
        list = SavedSearches.adding(saved("B", "beta"), to: list)
        list = SavedSearches.renaming(query: "beta", to: "Bêta", in: list)
        XCTAssertEqual(list.map(\.name), ["A", "Bêta"])
        // Une requête inconnue ne fabrique pas de ligne.
        list = SavedSearches.renaming(query: "gamma", to: "Gamma", in: list)
        XCTAssertEqual(list.count, 2)
        list = SavedSearches.removing(query: "alpha", from: list)
        XCTAssertEqual(list.map(\.query), ["beta"])
    }

    func testDeplacement() {
        let list = [saved("A", "a"), saved("B", "b"), saved("C", "c")]
        XCTAssertEqual(SavedSearches.moving(from: 2, to: 0, in: list).map(\.name),
                       ["C", "A", "B"])
        XCTAssertEqual(SavedSearches.moving(from: 0, to: 3, in: list).map(\.name),
                       ["B", "C", "A"])
        // Hors bornes : la liste est rendue telle quelle, rien ne tombe.
        XCTAssertEqual(SavedSearches.moving(from: 9, to: 0, in: list).map(\.name),
                       ["A", "B", "C"])
    }

    /// Le glisser-déposer de la barre latérale (lot MN2) : le modèle range la
    /// liste dans le nouvel ordre ET l'écrit, et le prochain lancement la relit
    /// ainsi.
    func testDeplacementDepuisLaBarreLateraleEstRetenu() throws {
        SavedSearches.save([saved("A", "a"), saved("B", "b"), saved("C", "c")])
        let db = try TempAppDB()
        let model = SearchModel(service: db.service)

        model.moveSavedSearches(fromOffsets: IndexSet(integer: 2), toOffset: 0)
        XCTAssertEqual(model.savedSearches.map(\.name), ["C", "A", "B"])
        XCTAssertEqual(SavedSearches.load().map(\.name), ["C", "A", "B"])

        // Plusieurs lignes à la fois : aucun geste ne le fabrique, rien ne bouge.
        model.moveSavedSearches(fromOffsets: IndexSet([0, 1]), toOffset: 3)
        XCTAssertEqual(SavedSearches.load().map(\.name), ["C", "A", "B"])
    }

    /// Au-delà du plafond, c'est la PLUS ANCIENNE qui sort.
    func testPlafond() {
        var list: [SavedSearch] = []
        for i in 0...SavedSearches.limit {
            list = SavedSearches.adding(saved("n\(i)", "q\(i)"), to: list)
        }
        XCTAssertEqual(list.count, SavedSearches.limit)
        XCTAssertEqual(list.first?.query, "q1")
        XCTAssertEqual(list.last?.query, "q\(SavedSearches.limit)")
    }

    func testAllerRetourJSON() {
        let list = [saved("Factures", "dossier:Factures 2025"),
                    saved("Thèse", "\"phrase exacte\" -brouillon")]
        SavedSearches.save(list)
        XCTAssertEqual(SavedSearches.load(), list)
        // Préférence absente : une liste vide, pas une erreur.
        Prefs.defaults.removeObject(forKey: Prefs.savedSearches)
        XCTAssertEqual(SavedSearches.load(), [])
    }

    /// Le geste complet, tel que le menu horloge l'appelle : le nom par défaut
    /// est la requête elle-même.
    func testEnregistrerDepuisLeModele() async throws {
        let db = try TempAppDB()
        try db.addDoc(relPath: "Users/essai/a.txt", pages: ["alpha"])
        let model = SearchModel(service: db.service)
        await run(model, "dossier:Essai alpha")
        XCTAssertEqual(model.suggestedSavedName, "dossier:Essai alpha")
        model.saveCurrentSearch(name: "   ")
        XCTAssertEqual(model.savedSearches.map(\.name), ["dossier:Essai alpha"],
                       "un nom vide retombe sur la requête")
        model.renameSavedSearch(query: "dossier:Essai alpha", to: "Mon dossier")
        XCTAssertEqual(model.savedSearches.map(\.name), ["Mon dossier"])
        XCTAssertEqual(SavedSearches.load().map(\.name), ["Mon dossier"],
                       "et c'est écrit dans les préférences")
        model.removeSavedSearch(query: "dossier:Essai alpha")
        XCTAssertTrue(model.savedSearches.isEmpty)
        XCTAssertTrue(SavedSearches.load().isEmpty)
    }
}
