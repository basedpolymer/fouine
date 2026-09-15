// SnippetMarkerTests.swift — les marqueurs d'extrait (lot MC2, constat PM-23).
// Propriété : A-Core.
//
// La règle de tout ce lot : ce qu'on ne demande pas ne coûte rien et ne change
// rien. L'expression `snippet()` par défaut doit être la chaîne d'AVANT, au
// caractère près — l'application la relit avec son heuristique de surlignage
// (`Highlighting.segments`) et ne passe aucun marqueur.

import XCTest
@testable import FouineCore

final class SnippetMarkerTests: XCTestCase {

    func testParDefautLeSQLEstCeluiDAvant() throws {
        let q = try query("enthalpie")
        XCTAssertEqual(GRDBStore.snippetExpr(q),
                       "snippet(page_fts, 0, '«', '»', '…', 12)")
    }

    func testLesMarqueursDemandesEntrentDansLExpression() throws {
        var q = try query("enthalpie")
        q.snippetMarkers = ("[", "]")
        XCTAssertEqual(GRDBStore.snippetExpr(q),
                       "snippet(page_fts, 0, '[', ']', '…', 12)")
        q.snippetMarkers = ("", "")
        XCTAssertEqual(GRDBStore.snippetExpr(q),
                       "snippet(page_fts, 0, '', '', '…', 12)")
    }

    /// Une chaîne interpolée dans du SQL se protège là où elle est écrite.
    func testLApostropheEstDoublee() throws {
        var q = try query("enthalpie")
        q.snippetMarkers = ("l'", "'")
        XCTAssertEqual(GRDBStore.snippetExpr(q),
                       "snippet(page_fts, 0, 'l''', '''', '…', 12)")
    }

    func testLExtraitRenduPorteLesMarqueursDemandes() throws {
        let db = try makeDB()
        let doc = try addDoc(db, relPath: "Users/a/Livres/cours.pdf")
        try db.store.replacePages(docID: doc, pages: [
            page(1, "l enthalpie libre du systeme"),
        ])
        var q = try query("enthalpie")
        XCTAssertTrue(try db.store.search(q).hits[0].snippet.contains("«enthalpie»"))
        q.snippetMarkers = ("**", "**")
        XCTAssertTrue(try db.store.search(q).hits[0].snippet.contains("**enthalpie**"))
        q.snippetMarkers = ("", "")
        let nu = try db.store.search(q).hits[0].snippet
        XCTAssertFalse(nu.contains("«"), nu)
        XCTAssertTrue(nu.contains("enthalpie"), nu)
    }
}
