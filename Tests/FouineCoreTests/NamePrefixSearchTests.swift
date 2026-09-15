// NamePrefixSearchTests.swift — `nom:` et `texte:` dans le moteur (lot QP1).
// Propriété : A-Core.
//
// `nom:` cherche dans les noms SEULEMENT (`docs_fts`) : seul, il rend les
// documents ; avec des termes de page, il restreint les documents candidats.
// `texte:` cherche dans les pages sans que le nom du fichier compte : ni bonus
// `dn`, ni bandeau des noms.

import XCTest
@testable import FouineCore

final class NamePrefixSearchTests: XCTestCase {

    /// Deux « rapport » (dont un sans texte en page 1), un document sans nom qui
    /// réponde, et « azote » sur les trois.
    private func corpus() throws -> (TempDB, annuel: Int64, cours: Int64, chimie: Int64) {
        let db = try makeDB()
        let annuel = try addDoc(db, relPath: "Users/alice/Livres/rapport-annuel.pdf",
                                mtime: 1_600_000_000)
        let cours = try addDoc(db, relPath: "Users/alice/Cours/Rapports.docx", ext: "docx",
                               folder: "Cours", mtime: 1_700_000_000)
        let chimie = try addDoc(db, relPath: "Users/alice/Livres/chimie.pdf")
        try db.store.replacePages(docID: annuel, pages: [
            page(3, "Le bilan de l'azote dans le sol."),
            page(4, "Conclusion du rapport."),
        ])
        try db.store.replacePages(docID: cours, pages: [
            page(1, "Azote et reduction, rapport de travaux pratiques."),
        ])
        try db.store.replacePages(docID: chimie, pages: [
            page(1, "Le rapport stoechiometrique de l'azote."),
        ])
        return (db, annuel, cours, chimie)
    }

    /// `nom:` seul : une ligne par document, sa première page porteuse de
    /// texte, l'extrait est le nom, les totaux comptent des documents — et le
    /// bandeau des noms ne répète pas la liste.
    func testNameAloneReturnsOneRowPerDocument() throws {
        let (db, annuel, cours, _) = try corpus()
        let results = try db.store.search(try query("nom:rapport"))
        XCTAssertEqual(Set(results.hits.map(\.docID)), [annuel, cours],
                       "« chimie.pdf » porte le mot dans ses PAGES, pas dans son nom")
        XCTAssertEqual(results.hits.count, 2, "une ligne par document")
        XCTAssertEqual(results.totalPages, 2)
        XCTAssertEqual(results.totalDocs, 2)
        XCTAssertTrue(results.nameMatches.isEmpty)
        let first = try XCTUnwrap(results.hits.first { $0.docID == annuel })
        XCTAssertEqual(first.page, 3, "la première page qui porte du texte")
        XCTAssertEqual(first.snippet, "rapport-annuel.pdf")
        // Les filtres de document s'appliquent, et les facettes comptent les
        // documents rendus.
        XCTAssertEqual(try db.store.search(try query("nom:rapport ext:docx")).hits.map(\.docID),
                       [cours])
        let facets = try db.store.facets(try query("nom:rapport"), by: .folder)
        XCTAssertEqual(Dictionary(uniqueKeysWithValues: facets), ["Livres": 1, "Cours": 1])
        // Filtre de provenance : un document sans page scannée ne répond pas.
        var scanned = try query("nom:rapport")
        scanned.sources = PageSource.scanned
        XCTAssertEqual(try db.store.search(scanned).totalDocs, 0)
        XCTAssertTrue(try db.store.facets(scanned, by: .folder).isEmpty)
        scanned.sources = PageSource.typed
        XCTAssertEqual(try db.store.search(scanned).hits.first { $0.docID == annuel }?.page, 3)
    }

    /// `nom:` + un terme de page : les pages de « azote », dans les seuls
    /// documents dont le nom porte « rapport ».
    func testNameWithAPageTermIntersects() throws {
        let (db, annuel, cours, chimie) = try corpus()
        let all = try db.store.search(try query("azote"))
        XCTAssertTrue(all.hits.contains { $0.docID == chimie })
        let results = try db.store.search(try query("nom:rapport azote"))
        XCTAssertEqual(Set(results.hits.map(\.docID)), [annuel, cours])
        XCTAssertEqual(results.totalPages, 2)
        XCTAssertEqual(try db.store.docIDsMatchingName(try query("nom:rapport azote")),
                       [annuel, cours], "le même jeu pour le canal du sens")
        XCTAssertNil(try db.store.docIDsMatchingName(try query("azote")))
    }

    /// `texte:` : pas de CTE `dn` dans le SQL, pas de bandeau des noms.
    func testBodyPrefixTurnsTheNameBoostAndTheBannerOff() throws {
        let (db, _, cours, _) = try corpus()
        let plain = try query("rapport azote")
        XCTAssertTrue(GRDBStore.probeCTEs(GRDBStore.rankingProbes(for: plain)).contains("dn AS"))
        let body = try query("texte:rapport azote")
        let sql = GRDBStore.probeCTEs(GRDBStore.rankingProbes(for: body))
        XCTAssertFalse(sql.contains("dn"), sql)
        XCTAssertFalse(GRDBStore.boostedScore("r", probes: GRDBStore.rankingProbes(for: body),
                                              rowID: "rid", docID: "did").contains("dn"))
        XCTAssertEqual(try db.store.search(try query("rapport")).nameMatches.map(\.id).contains(cours),
                       true)
        let results = try db.store.search(try query("texte:rapport"))
        XCTAssertTrue(results.nameMatches.isEmpty)
        XCTAssertEqual(results.totalPages, 3, "les pages, elles, sont toutes là")
    }
}
