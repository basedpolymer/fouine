// VectorPresenceTests.swift — « y a-t-il au moins un vecteur ? » (A2-08).
// Propriété : A-Core.
//
// Le bandeau de santé de l'application ne teste qu'un booléen, et il le
// refaisait toutes les 30 secondes en payant un `count(*)` complet sur
// `page_vec` — 0,10 s sur la base de production d'aujourd'hui (91 943
// vecteurs), une à deux secondes une fois la campagne finie, et la fenêtre
// pouvait être au fond de l'écran. `EXISTS` s'arrête à la première ligne.

import XCTest
@testable import FouineCore

final class VectorPresenceTests: XCTestCase {

    func testFollowsTheFirstVector() throws {
        let db = try makeDB()
        let docID = try addDoc(db, relPath: "livre.pdf")
        try db.store.replacePages(docID: docID, pages: [page(1, "cinétique")])

        XCTAssertFalse(try db.store.hasAnyVector(), "base neuve : aucun vecteur")
        XCTAssertEqual(try db.store.vectorisedPageCount(), 0)

        let pageRowID = Schema.ftsRowID(docID: docID, page: 1)
        try db.store.upsertVectors([
            (Schema.vecRowID(pageRowID: pageRowID, chunk: 0),
             Data(repeating: 1, count: 8)),
        ])

        XCTAssertTrue(try db.store.hasAnyVector())
        // Et il dit la MÊME chose que le comptage qu'il remplace.
        XCTAssertEqual(try db.store.hasAnyVector(),
                       try db.store.vectorisedPageCount() > 0)
    }

    /// Le compte PAR DOCUMENT, celui que `fouine list --json` et
    /// `fouine_list_documents` publient tous deux sous `vectorised_pages` (lot
    /// MC3, PM-16a). Il est la seule façon de voir qu'un dossier entier est à
    /// zéro pendant que la couverture globale annonce deux tiers.
    func testCountsVectorisedPagesPerDocument() throws {
        let db = try makeDB()
        let withVectors = try addDoc(db, relPath: "avec.pdf")
        let without = try addDoc(db, relPath: "sans.pdf")
        for id in [withVectors, without] {
            try db.store.replacePages(docID: id, pages: [
                page(1, "cinétique"), page(2, "diffusion"), page(3, "enthalpie"),
            ])
        }
        for number in [1, 3] {
            let rowid = Schema.ftsRowID(docID: withVectors, page: number)
            try db.store.upsertVectors([
                (Schema.vecRowID(pageRowID: rowid, chunk: 0),
                 Data(repeating: 1, count: 8)),
            ])
        }

        let counts = try db.store.vectorisedPageCounts(
            forDocIDs: [withVectors, without])
        XCTAssertEqual(counts[withVectors], 2)
        // ABSENT et non zéro : c'est l'appelant qui décide comment le dire
        // (`vectorised_pages: 0` des deux côtés).
        XCTAssertNil(counts[without])
    }

    /// Une page dont SEULES les fenêtres 1 et 2 existeraient n'est pas vue par
    /// le canal sémantique : `hasAnyVector` suit exactement `vectorisedPageCount`,
    /// qui ne compte que la fenêtre 0.
    func testIgnoresWindowsOtherThanTheFirst() throws {
        let db = try makeDB()
        let docID = try addDoc(db, relPath: "livre.pdf")
        try db.store.replacePages(docID: docID, pages: [page(1, "cinétique")])
        let pageRowID = Schema.ftsRowID(docID: docID, page: 1)
        try db.store.upsertVectors([
            (Schema.vecRowID(pageRowID: pageRowID, chunk: 1),
             Data(repeating: 2, count: 8)),
        ])
        XCTAssertFalse(try db.store.hasAnyVector())
        XCTAssertEqual(try db.store.vectorisedPageCount(), 0)
    }
}
