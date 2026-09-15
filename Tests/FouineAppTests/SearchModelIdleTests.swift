// SearchModelIdleTests.swift — le modèle de recherche retombe au repos (A2-01).
// Propriété : A-App.
//
// Le bogue : `execute` sur une saisie VIDE annule la recherche et le facettage
// en vol, puis remet tout l'état à zéro — sauf `isSearching` et `isFaceting`.
// Or les deux tâches annulées sortent par un `if Task.isCancelled { return }`
// placé AVANT le `isSearching = false` et avant le `defer` qui rabaisse
// `isFaceting` : personne ne les rabaissait donc. Vider le champ pendant
// qu'une recherche est en vol laissait la ligne d'état bloquée sur
// « recherche… » — champ vide, tourniquet qui tourne — jusqu'à la requête
// suivante. C'est aussi ce que fait le bouton « Effacer la requête » (croix)
// du champ de recherche.

import XCTest
@testable import FouineApp

@MainActor
final class SearchModelIdleTests: XCTestCase {

    func testClearingTheFieldWhileSearchingReturnsToIdle() async throws {
        let db = try TempAppDB()
        try db.addDoc(relPath: "Users/essai/un.txt",
                      pages: ["alpha beta gamma delta epsilon"])
        let model = SearchModel(service: db.service)

        // Aucun `await` entre les deux `execute` : la recherche et le
        // facettage de la première sont donc encore EN VOL.
        model.text = "alpha"
        model.execute(remember: false)
        XCTAssertTrue(model.isSearching, "la recherche vient de partir")
        XCTAssertTrue(model.isFaceting, "les facettes viennent de partir")

        model.text = ""
        model.execute(remember: false)

        XCTAssertFalse(model.isSearching,
                       "A2-01 : la ligne d'état reste bloquée sur « recherche… »")
        XCTAssertFalse(model.isFaceting,
                       "A2-01 : le modèle ne retombe jamais au repos")
        XCTAssertTrue(model.hits.isEmpty)
        XCTAssertEqual(model.executedText, "")

        // Et rien de ce qui revient des tâches annulées ne les rallume : elles
        // ont le temps de rendre la main avant ce second contrôle.
        try await Task.sleep(nanoseconds: 400_000_000)
        XCTAssertFalse(model.isSearching, "une tâche annulée a rallumé le fanion")
        XCTAssertFalse(model.isFaceting, "une tâche annulée a rallumé le fanion")
    }
}
