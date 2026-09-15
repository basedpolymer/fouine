// WordsPresentTests.swift — la note « sens seul » dit ce que l'index porte
// vraiment (lot MC1). Propriété : A-Core.
//
// `lexTotalPages == 0` ne veut pas dire « aucun de vos mots n'existe » : il
// veut dire « aucune page ne les porte TOUS ». La phrase affirmait le premier
// et faisait conclure à un fonds muet — mesuré sur la base de production, où
// « réacteur » est dans 22 documents du dossier interrogé.

import XCTest
@testable import FouineCore

final class WordsPresentTests: XCTestCase {

    private func fixture() throws -> TempDB {
        let db = try makeDB()
        let livre = try addDoc(db, relPath: "Users/a/Livres/genie.pdf")
        try db.store.replacePages(docID: livre, pages: [
            page(1, "le sejour moyen dans un reacteur parfaitement agite"),
            page(2, "la distribution des ages internes"),
        ])
        return db
    }

    /// Les mots qui EXISTENT, dans l'ordre tapé ; ceux qui n'existent pas
    /// n'y sont pas, et les mots-outils non plus — ils sont partout et
    /// noieraient les deux qui apprennent quelque chose.
    func testOnlyTheWordsTheIndexCarries() throws {
        let db = try fixture()
        XCTAssertEqual(
            try db.store.wordsPresent(try query("reacteur sejour cryptobiose")),
            ["reacteur", "sejour"])
        XCTAssertEqual(
            try db.store.wordsPresent(
                try query("distribution des temps de sejour dans un reacteur")),
            ["distribution", "sejour", "reacteur"],
            "« temps » est un mot porteur, mais aucune page ne le contient")
        XCTAssertTrue(try db.store.wordsPresent(try query("cryptobiose xyzzy")).isEmpty)
        // Aucune page ne porte les deux premiers ensemble : c'est bien la
        // situation que la note décrit.
        XCTAssertEqual(try db.store.search(try query("reacteur distribution")).totalPages, 0)
    }

    /// Les filtres de la requête s'appliquent : un mot présent AILLEURS que
    /// dans le dossier interrogé n'est pas « présent » pour cette recherche.
    func testFiltersApply() throws {
        let db = try fixture()
        let ailleurs = try addDoc(db, relPath: "Users/a/Cours/notes.pdf", folder: "Cours")
        try db.store.replacePages(docID: ailleurs, pages: [page(1, "la cryptobiose")])
        XCTAssertEqual(try db.store.wordsPresent(try query("cryptobiose reacteur")),
                       ["cryptobiose", "reacteur"])
        XCTAssertEqual(try db.store.wordsPresent(try query("dossier:Livres cryptobiose reacteur")),
                       ["reacteur"])
    }

    /// Deux phrases, et une seule règle : la liste vide garde l'ancienne.
    func testTheSentenceSaysWhichCaseItIs() throws {
        XCTAssertEqual(SearchAdvice.noLexicalMatch(wordsPresent: []),
                       SearchAdvice.noLexicalMatch)
        XCTAssertEqual(
            SearchAdvice.noLexicalMatch(wordsPresent: ["reacteur", "sejour"]),
            "no page carries your words together — these results come from "
            + "meaning alone (words present: reacteur, sejour)")
    }
}
