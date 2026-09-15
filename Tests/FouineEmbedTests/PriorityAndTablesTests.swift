// PriorityAndTablesTests.swift — l'ordre dans lequel la campagne travaille, et
// ce qu'elle refuse d'inférer (lot MC3, constats PM-05 et PM-09).
// Propriété : A-Embed.
//
// CE QUI EST ÉPROUVÉ ICI, et pourquoi c'est mesurable. La production avait
// `roots.pinned = M2SU, Personnel` et ces deux racines portaient EXACTEMENT
// zéro vecteur, pendant que `Livres`, non épinglée, en était aux deux tiers :
// la sélection balaie par rowid, c'est-à-dire par ordre de découverte des
// documents, et les documents de `Livres` portent les identifiants bas. La
// fixture reproduit exactement cette forme — le dossier prioritaire a les
// identifiants les PLUS HAUTS — et le test regarde l'ordre réel des textes
// passés au moteur.

import Foundation
import XCTest
@testable import FouineEmbed
@testable import FouineCore

final class PriorityAndTablesTests: XCTestCase {

    /// Deux racines, `Livres` d'abord (identifiants bas) puis `Cours`
    /// (identifiants hauts) : la forme de la production.
    private func makeTwoRoots(_ db: TempDB) throws -> (books: [Int64], courses: [Int64]) {
        var books: [Int64] = [], courses: [Int64] = []
        for index in 1...3 {
            let id = try addDoc(db, relPath: "Users/a/Livres/livre-\(index).pdf",
                                folder: "Livres")
            try db.store.replacePages(docID: id, pages: [
                page(1, "livre \(index) chromatographie enthalpie polymere "
                     + String(repeating: "reaction ", count: 20)),
            ])
            books.append(id)
        }
        for index in 1...3 {
            let id = try addDoc(db, relPath: "Users/a/Cours/cours-\(index).pdf",
                                folder: "Cours")
            try db.store.replacePages(docID: id, pages: [
                page(1, "cours \(index) catalyse reacteur transfert "
                     + String(repeating: "diffusion ", count: 20)),
            ])
            courses.append(id)
        }
        return (books, courses)
    }

    // MARK: - Priorité des racines (PM-05)

    /// Le dossier prioritaire passe DEVANT, alors que ses documents sont les
    /// derniers découverts.
    func testPinnedFolderIsEmbeddedFirst() throws {
        let db = try makeDB()
        _ = try makeTwoRoots(db)

        var config = silentConfig()
        config.batchSize = 2
        config.priorityFolders = ["Cours"]
        let engine = RecordingEngine()
        _ = try EmbedRun.run(store: db.store, engine: engine, config: config)

        let seen = engine.seen
        XCTAssertEqual(seen.count, 6, "les six pages sont inférées : \(seen)")
        XCTAssertTrue(seen.prefix(3).allSatisfy { $0.hasPrefix("cours ") },
                      "les trois premières inférences sont celles du dossier "
                      + "prioritaire : \(seen.map { String($0.prefix(8)) })")
        XCTAssertTrue(seen.suffix(3).allSatisfy { $0.hasPrefix("livre ") },
                      "le reste de l'index suit : \(seen.map { String($0.prefix(8)) })")
    }

    /// Sans racine prioritaire, l'ordre reste celui du rowid — c'est-à-dire
    /// celui d'avant ce lot, au caractère près.
    func testWithoutPinnedFoldersTheOrderIsUnchanged() throws {
        let db = try makeDB()
        _ = try makeTwoRoots(db)

        var config = silentConfig()
        config.batchSize = 2
        let engine = RecordingEngine()
        _ = try EmbedRun.run(store: db.store, engine: engine, config: config)

        XCTAssertTrue(engine.seen.prefix(3).allSatisfy { $0.hasPrefix("livre ") },
                      "\(engine.seen.map { String($0.prefix(8)) })")
    }

    /// `--folder` restreint TOUTE la campagne : le reste de l'index n'est pas
    /// touché, et reste donc à faire.
    func testOnlyFoldersLeavesTheRestOfTheIndexAlone() throws {
        let db = try makeDB()
        let roots = try makeTwoRoots(db)

        var config = silentConfig()
        config.onlyFolders = ["Cours"]
        let engine = RecordingEngine()
        let summary = try EmbedRun.run(store: db.store, engine: engine,
                                       config: config)

        XCTAssertEqual(engine.seen.count, 3)
        XCTAssertTrue(engine.seen.allSatisfy { $0.hasPrefix("cours ") })
        XCTAssertEqual(summary.embedded, 3)
        XCTAssertEqual(summary.remaining, 3, "les trois livres restent à faire")
        let counts = try db.store.vectorisedPageCounts(
            forDocIDs: roots.books + roots.courses)
        XCTAssertEqual(roots.books.compactMap { counts[$0] }, [],
                       "aucune page de `Livres` n'a de vecteur")
        XCTAssertEqual(roots.courses.map { counts[$0] ?? 0 }, [1, 1, 1])
    }

    /// La restriction garde la SONDE DE CLÉ PRIMAIRE sur `page_vec` et la
    /// poussée de `rowid >` dans fts5 : c'est tout ce qui fait la vitesse de la
    /// sélection (audit V2), et une restriction qui la casserait coûterait plus
    /// cher que la priorité ne rapporte.
    func testRestrictedSelectionKeepsThePrimaryKeyProbe() throws {
        let db = try makeDB()
        _ = try makeTwoRoots(db)

        let sql = GRDBStore.pagesNeedingVectorSQL(topFolders: ["Cours"])
        let plan = try db.store.rawPlanDetails(sql, arguments: [0, "Cours", 4])
        let joined = plan.joined(separator: " | ")
        XCTAssertTrue(joined.contains("SEARCH v USING INTEGER PRIMARY KEY"),
                      "la jointure doit rester une sonde de clé primaire : \(joined)")
        XCTAssertFalse(joined.contains("SCAN page_vec"),
                       "page_vec ne doit JAMAIS être balayée : \(joined)")
        XCTAssertFalse(joined.contains("TEMP B-TREE"),
                       "l'ORDER BY ne doit pas ajouter de tri : \(joined)")
        XCTAssertTrue(joined.contains("SCAN f VIRTUAL TABLE INDEX 64:"),
                      "la contrainte rowid > doit rester poussée dans fts5 : \(joined)")
    }

    // MARK: - Tableurs (PM-09)

    /// Un tableur reçoit des vecteurs NULS, sans une seule inférence, et sa
    /// page est comptée comme faite — sans quoi la pompe la resélectionnerait
    /// sans fin.
    func testSpreadsheetsGetNullVectorsWithoutInference() throws {
        let db = try makeDB()
        let table = try addDoc(db, relPath: "Users/a/Cours/mesures.xlsx",
                               ext: "xlsx", folder: "Cours")
        try db.store.replacePages(docID: table, pages: [
            page(1, (1...200).map { "\($0 * 7 % 991)" }.joined(separator: " ")),
        ])
        let prose = try addDoc(db, relPath: "Users/a/Cours/notes.pdf",
                               ext: "pdf", folder: "Cours")
        try db.store.replacePages(docID: prose, pages: [
            page(1, "catalyse heterogene et transfert de matiere "
                 + String(repeating: "reacteur ", count: 20)),
        ])

        let engine = RecordingEngine()
        let summary = try EmbedRun.run(store: db.store, engine: engine,
                                       config: silentConfig())

        XCTAssertEqual(engine.seen.count, 1,
                       "seule la page de prose est inférée : \(engine.seen)")
        XCTAssertGreaterThan(summary.tables, 0, "les fenêtres nulles sont comptées")
        XCTAssertEqual(summary.remaining, 0, "les deux pages sont FAITES")
        // Le vecteur nul est bien en base : la page est vue comme vectorisée,
        // et le canal lexical continue de la trouver au mot près.
        let counts = try db.store.vectorisedPageCounts(forDocIDs: [table])
        XCTAssertEqual(counts[table], 1)
    }

    /// `--include-tables` (et `embed.skip_spreadsheets false`) les rend à
    /// l'inférence : la liste vide est le seul interrupteur.
    func testIncludingTablesInfersThemAgain() throws {
        let db = try makeDB()
        let table = try addDoc(db, relPath: "Users/a/Cours/mesures.csv",
                               ext: "csv", folder: "Cours")
        try db.store.replacePages(docID: table, pages: [
            page(1, "produit;quantite;prix\npolymere;12;34,50\n"
                 + String(repeating: "resine;8;12,00\n", count: 20)),
        ])

        var config = silentConfig()
        config.skipExtensions = []
        let engine = RecordingEngine()
        _ = try EmbedRun.run(store: db.store, engine: engine, config: config)
        XCTAssertEqual(engine.seen.count, 1, "la page du tableur est inférée")
    }
}
