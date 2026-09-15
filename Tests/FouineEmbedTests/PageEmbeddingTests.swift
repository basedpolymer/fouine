// PageEmbeddingTests.swift — encoder une page à la volée (lot MC4, PM-07).
// Propriété : A-Embed.
//
// CE QUE CES TESTS PROTÈGENT. `fouine_similar_pages` peut désormais encoder
// la page source à la demande (`encode_if_missing`). Le vecteur produit doit
// être celui que la CAMPAGNE aurait écrit — mêmes fenêtres, mêmes règles de
// vecteur nul, mêmes octets après quantification. Sinon les cosinus rendus ne
// sont comparables à rien, et personne ne s'en aperçoit : les deux chemins
// rendent des nombres plausibles.
//
// Les aides communes vivent dans EmbedTests.swift, même cible.

import Foundation
import XCTest
@testable import FouineEmbed
@testable import FouineCore

final class PageEmbeddingTests: XCTestCase {

    func testTheWindowsAreTheOnesTheCampaignUses() {
        for length in [0, 1_400, 1_401, 2_701, 10_000] {
            let page = text(ofLength: length)
            let mine = PageEmbedding.windows(for: page)
            let campaign = EmbedRun.windows(for: page)
            XCTAssertEqual(mine.map(\.chunk), campaign.map(\.chunk))
            XCTAssertEqual(mine.map(\.text), campaign.map(\.text),
                           "\(length) caractère(s)")
        }
    }

    /// Les deux règles qui se décident sur le seul texte d'une fenêtre. Une
    /// page que la campagne aurait annulée doit être refusée, pas comparée :
    /// un vecteur nul a un produit scalaire nul partout, donc un voisinage
    /// arbitraire.
    func testAWindowTheCampaignWouldNullIsRefused() {
        XCTAssertTrue(PageEmbedding.isNulled("trop court"))
        XCTAssertTrue(PageEmbedding.isNulled(String(repeating: "a", count: 800)))
        XCTAssertTrue(PageEmbedding.isNulled(
            String(repeating: "12 345 | 67,8 | 90 ", count: 40)))
        XCTAssertFalse(PageEmbedding.isNulled(
            String(repeating: "l'electrolyse de l'eau produit du dihydrogene. ",
                   count: 5)))
        // `nullDegenerate: false` est ce que les tests de fenêtrage arment :
        // la règle reste une décision d'appelant, ici comme dans `EmbedRun`.
        XCTAssertFalse(PageEmbedding.isNulled(String(repeating: "a", count: 800),
                                              nullDegenerate: false))
    }

    func testAPageWithNothingToSayGivesNoVectorAtAll() throws {
        guard let engine = try sharedRealEncoder() else {
            throw XCTSkip("modèle absent")
        }
        XCTAssertTrue(try PageEmbedding.vectors(forPageText: "page 3",
                                                engine: engine).isEmpty)
    }

    /// LE TEST QUI COMPTE : les octets de la volée sont ceux de la campagne.
    ///
    /// La comparaison passe par `page_vec` — on fait tourner une vraie
    /// campagne sur une base jetable, puis on relit les blobs écrits et on les
    /// confronte aux vecteurs produits à la volée sur le même texte.
    func testTheOnTheFlyVectorIsByteForByteTheCampaignOne() throws {
        guard let engine = try sharedRealEncoder() else {
            throw XCTSkip("modèle absent")
        }
        // Deux fenêtres : la seconde éprouve le recouvrement et l'ordre, que
        // la fenêtre 0 seule ne dirait pas.
        let body = String(repeating:
            "l'electrolyse de l'eau produit du dihydrogene et du dioxygene. ",
            count: 40)
        XCTAssertEqual(PageEmbedding.windows(for: body).count, 2)

        let db = try makeDB()
        let docID = try addDoc(db, relPath: "Users/essai/Livres/electro.pdf")
        try db.store.setPageCount(docID, 1)
        try db.store.replacePages(docID: docID, pages: [page(1, body)])
        var config = silentConfig()
        config.nullDegenerate = true
        try EmbedRun.run(store: db.store, engine: engine, config: config)

        // Relu par l'INDEX, c'est-à-dire par le chemin que la recherche
        // emprunte : ce sont ces octets-là qui sont comparés en production.
        let index = try VectorIndex(store: db.store, dim: engine.dimension)
        let stored = try (0..<2).map { chunk -> [Int8] in
            let rank = try XCTUnwrap(index.index(of: vecRow(docID, 1, chunk: chunk)),
                                     "fenêtre \(chunk) absente de page_vec")
            return index.withVector(at: rank) { Array($0) }
        }
        let live = try PageEmbedding.vectors(forPageText: body, engine: engine)

        XCTAssertEqual(live.count, stored.count)
        for (chunk, pair) in zip(live, stored).enumerated() {
            XCTAssertEqual(pair.0, pair.1,
                           "fenêtre \(chunk) : la volée diffère de la campagne")
        }
    }
}
