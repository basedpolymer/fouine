// SpotlightStoreTests.swift — les deux lectures « qu'est-ce qui a changé »
// (lot INT-S1). Propriété : A-Core.
//
// La remise à Spotlight tient tout entière sur `docs.indexed_at` : ce fichier
// éprouve que la colonne dit la vérité — extraction ET reconnaissance de
// caractères comprises —, et que le texte se relit page par page.

import Foundation
import XCTest
import GRDB
@testable import FouineCore

final class SpotlightStoreTests: XCTestCase {

    private func indexedAt(_ db: TempDB, _ docID: Int64) throws -> Double {
        try db.store.read { raw in
            try Double.fetchOne(raw, sql: "SELECT indexed_at FROM docs WHERE id = ?",
                                arguments: [docID]) ?? 0
        }
    }

    // MARK: - 1 · Ce qui a changé depuis

    func testChangedDocumentsAreListedFromTheirIndexingDate() throws {
        let db = try makeDB()
        let old = try addDoc(db, relPath: "Livres/ancien.pdf")
        try db.store.setDocState(old, .extracted, err: nil)
        let oldStamp = try indexedAt(db, old)

        let fresh = try addDoc(db, relPath: "Livres/recent.djvu", ext: "djvu")
        try db.store.setDocState(fresh, .extracted, err: nil)

        // Depuis l'origine : les deux, du plus ancien au plus récent.
        let all = try db.store.documentsChanged(since: 0, limit: 100)
        XCTAssertEqual(all.map(\.id), [old, fresh])
        XCTAssertEqual(all.first?.ext, "pdf")
        XCTAssertEqual(all.first?.topFolder, "Livres")
        XCTAssertEqual(all.first?.state, .extracted)

        // Depuis l'instant du premier : le premier compris (`>=` : le marqueur
        // est en secondes entières, un `>` strict perdrait la seconde en cours).
        let since = try db.store.documentsChanged(since: oldStamp, limit: 100)
        XCTAssertEqual(since.map(\.id), [old, fresh])

        // Après les deux : plus rien.
        let after = try db.store.documentsChanged(
            since: Date().timeIntervalSince1970 + 60, limit: 100)
        XCTAssertTrue(after.isEmpty)
    }

    func testScannedPagesAreCounted() throws {
        let db = try makeDB()
        let docID = try addDoc(db, relPath: "Livres/scan.pdf")
        try db.store.replacePages(docID: docID, pages: [page(1, "page native")])
        try db.store.completeOCR(docID: docID, page: 2,
                                 result: ocrPage("page reconnue par l'OCR"))

        let row = try XCTUnwrap(try db.store.documentsChanged(since: 0, limit: 10).first)
        XCTAssertEqual(row.scannedPages, 1,
                       "seule la page OCRisée compte comme scannée")
    }

    // MARK: - 2 · L'OCR fait avancer la date d'indexation

    func testOCRMovesTheIndexingDate() throws {
        let db = try makeDB()
        let docID = try addDoc(db, relPath: "Livres/scan.pdf")
        try db.store.setDocState(docID, .extracted, err: nil)
        let before = try indexedAt(db, docID)
        XCTAssertGreaterThan(before, 0)

        // Une page reconnue : c'est le SEUL texte que ce document aura jamais,
        // et il doit rendre le document « changé » pour la remise à Spotlight.
        Thread.sleep(forTimeInterval: 0.01)
        try db.store.completeOCR(docID: docID, page: 1,
                                 result: ocrPage("électrolyse de l'eau"))

        XCTAssertGreaterThan(try indexedAt(db, docID), before)
    }

    // MARK: - 3 · Le texte, page par page

    func testPageTextsAreReadInOrderAndByChunks() throws {
        let db = try makeDB()
        let docID = try addDoc(db, relPath: "Livres/traite.pdf")
        try db.store.replacePages(docID: docID, pages: [
            page(1, "première page du traité"),
            page(2, "deuxième page du traité"),
            page(3, "troisième page du traité"),
        ])

        let first = try db.store.pageTexts(docID: docID, limit: 2)
        XCTAssertEqual(first.map(\.page), [1, 2])
        XCTAssertEqual(first.first?.text, "première page du traité")

        let next = try db.store.pageTexts(docID: docID, limit: 2, fromPage: 3)
        XCTAssertEqual(next.map(\.page), [3])

        // Reprise PAR PAGE et non par rang : une page absente (scan pas encore
        // reconnu) ne décale rien.
        XCTAssertTrue(try db.store.pageTexts(docID: docID, limit: 2,
                                             fromPage: 9).isEmpty)
    }
}
