// SharedTextTests.swift — la sonde « combien de documents portent ce
// passage ? » (constat C2-16, lot SI1). SPDX-License-Identifier: LicenseRef-Fouine-Source-Available
//
// C'est `fouine embed` qui l'interroge, avant d'inférer une fenêtre : au-delà
// du seuil, la fenêtre reçoit un vecteur nul. Ce qui se prouve ici est le
// COMPTE (des documents, pas des pages) et l'ARRÊT au seuil — sans lui, un pied
// de page présent dans dix mille documents ferait balayer dix mille lignes pour
// rendre un chiffre dont on n'avait besoin qu'à quatre près.

import Foundation
import XCTest
@testable import FouineCore

final class SharedTextTests: XCTestCase {

    /// Le même passage dans `copies` documents, chacun sur deux pages.
    private func fill(_ db: TempDB, copies: Int, passage: String) throws {
        for n in 1...copies {
            let id = try addDoc(db, relPath: "Livres/livre\(n).epub", ext: "epub")
            try db.store.replacePages(docID: id, pages: [
                page(1, passage),
                page(2, passage + " et la suite propre au livre \(n)"),
            ])
        }
    }

    func testItCountsDocumentsNotPages() throws {
        let db = try makeDB()
        try fill(db, copies: 3,
                 passage: "cette licence autorise la copie du texte sous "
                        + "reserve de mentionner sa provenance")
        // Six PAGES portent le passage, mais trois DOCUMENTS seulement : c'est
        // le second chiffre qui décide, et c'est tout l'objet du rowid
        // structuré (§4.1).
        XCTAssertEqual(try db.store.rawInt64s(
            "SELECT count(*) FROM page_fts WHERE page_fts MATCH "
            + "'\"cette licence autorise\"'"), [6])
        XCTAssertEqual(try db.store.documentsSharing(
            rawFTS: "\"cette licence autorise la copie\" AND \"mentionner sa provenance\"",
            atLeast: 10), 3)
    }

    func testItStopsAtTheThreshold() throws {
        let db = try makeDB()
        try fill(db, copies: 9, passage: "pied de page du cabinet reproduit "
                                       + "sur chacun des devis envoyes")
        // Neuf documents, mais on ne demandait à savoir qu'à quatre près.
        XCTAssertEqual(try db.store.documentsSharing(
            rawFTS: "\"pied de page du cabinet\" AND \"des devis envoyes\"",
            atLeast: 4), 4)
        XCTAssertEqual(try db.store.documentsSharing(
            rawFTS: "\"pied de page du cabinet\" AND \"des devis envoyes\"",
            atLeast: 20), 9)
    }

    func testAPassageOfASingleDocumentAndAnAbsentOneAreDistinguished() throws {
        let db = try makeDB()
        let id = try addDoc(db, relPath: "Livres/seul.epub", ext: "epub")
        try db.store.replacePages(docID: id, pages: [
            page(1, "la cristallisation lente des polymeres semi cristallins")])

        XCTAssertEqual(try db.store.documentsSharing(
            rawFTS: "\"cristallisation lente\" AND \"semi cristallins\"",
            atLeast: 4), 1)
        XCTAssertEqual(try db.store.documentsSharing(
            rawFTS: "\"chromatographie liquide\"", atLeast: 4), 0)
    }

    /// La sonde est une optimisation de QUALITÉ : une requête que FTS5 refuse
    /// ne doit jamais faire échouer une campagne de vingt heures.
    func testAMalformedQueryYieldsZeroRatherThanThrowing() throws {
        let db = try makeDB()
        try fill(db, copies: 2, passage: "un passage quelconque de deux livres")
        XCTAssertEqual(try db.store.documentsSharing(rawFTS: "\"", atLeast: 4), 0)
        XCTAssertEqual(try db.store.documentsSharing(rawFTS: "AND AND", atLeast: 4), 0)
        XCTAssertEqual(try db.store.documentsSharing(rawFTS: "", atLeast: 4), 0)
    }
}
