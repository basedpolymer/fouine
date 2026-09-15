// VectorConsistencyTests.swift — détection et réparation des lignes de
// `page_vec` qu'aucune pompe n'a pu écrire (audit A1m-05). Propriété : A-Core.
//
// La base de production du 04/09/2026 en portait ~11 000 : un binaire d'un
// autre schéma avait écrit dedans avant que `schemaMismatch` (lot J1) ne le lui
// interdise. Rien ne les voyait — ni `doctor --deep`, ni `embed --status`, ni
// `VectorIndex` — et 1 327 d'entre elles se repliaient sur une page RÉELLE,
// c'est-à-dire présentaient un extrait sans rapport comme un voisin sémantique.

import Foundation
import XCTest
import GRDB
@testable import FouineCore

final class VectorConsistencyTests: XCTestCase {

    /// Une base à trois pages vectorisées proprement, puis semée.
    private func seeded() throws -> (db: TempDB, pages: [Int64]) {
        let db = try makeDB(lockTimeout: 0.3)
        let docID = try addDoc(db, relPath: "livre.pdf")
        try db.store.replacePages(docID: docID, pages: [
            page(1, "l'énergie libre de Gibbs"),
            page(2, "la cinétique fixe la vitesse"),
            page(3, "l'équilibre est atteint"),
        ])
        let pages = (1...3).map { Schema.ftsRowID(docID: docID, page: $0) }
        var rows: [(rowid: Int64, vec: Data)] = []
        for pageRowID in pages {
            rows.append((Schema.vecRowID(pageRowID: pageRowID, chunk: 0),
                         Data(repeating: 1, count: 384)))
            // Sentinelle de complétude : blob vide.
            rows.append((Schema.vecRowID(pageRowID: pageRowID,
                                         chunk: Schema.vecWindowMax - 1), Data()))
        }
        try db.store.upsertVectors(rows)
        return (db, pages)
    }

    private func count(_ db: TempDB, _ sql: String) throws -> Int {
        try db.store.read { try Int.fetchOne($0, sql: sql) ?? -1 }
    }

    // MARK: - Détection

    func testCheckVectorsCountsAndNamesTheThreeInconsistencies() throws {
        let (db, pages) = try seeded()

        // (a) créneau hors plage : la pompe n'écrit jamais 3…7.
        let foreign = Schema.vecRowID(pageRowID: pages[0],
                                      chunk: Schema.vecWindowMax + 1)
        // (b) page inexistante : le rowid v3 `doc × 100 000 + page` que le
        // binaire d'un autre schéma déposait tel quel. 300 008 tombe sur le
        // créneau 0 — il n'est donc PAS un `foreign_slot`, et le test sépare
        // bien les deux catégories.
        let orphan = Schema.ftsRowID(docID: 3, page: 8)
        try db.store.upsertVectors([
            (foreign, Data(repeating: 2, count: 384)),
            (orphan, Data(repeating: 3, count: 384)),
        ])
        // (c) sentinelle sans fenêtre 0 : la page se dit finie et
        // `pagesNeedingVector` ne la rendra plus jamais.
        try db.store.writeLocked { conn in
            try conn.execute(sql: "DELETE FROM page_vec WHERE rowid = ?",
                           arguments: [Schema.vecRowID(pageRowID: pages[2],
                                                       chunk: 0)])
        }

        let report = try db.store.checkVectors()
        XCTAssertEqual(report.count(.foreignSlot), 1)
        XCTAssertEqual(report.count(.orphanPage), 1)
        XCTAssertEqual(report.count(.brokenSentinel), 1)
        XCTAssertEqual(report.total, 3)
        XCTAssertFalse(report.isClean)
        // 6 saines + 2 semées, moins la fenêtre 0 ôtée juste au-dessus.
        XCTAssertEqual(report.rows, 7)

        // NOMMÉES, pas seulement comptées : un compte ne se vérifie pas à la
        // main, un rowid si.
        XCTAssertEqual(Set(report.samples.map(\.rowid)),
                       [foreign, orphan,
                        Schema.vecRowID(pageRowID: pages[2],
                                        chunk: Schema.vecWindowMax - 1)])
        let json = report.json
        XCTAssertEqual(json["inconsistent"] as? Int, 3)
        XCTAssertEqual(json["foreign_slot"] as? Int, 1)
        XCTAssertEqual(json["orphan_page"] as? Int, 1)
        XCTAssertEqual(json["broken_sentinel"] as? Int, 1)
    }

    func testAHealthyDatabaseIsReportedClean() throws {
        let (db, _) = try seeded()
        let report = try db.store.checkVectors()
        XCTAssertTrue(report.isClean, "aucune ligne saine ne doit être accusée")
        XCTAssertEqual(report.rows, 6)
        XCTAssertTrue(report.samples.isEmpty)
    }

    /// Une page en cours de vectorisation — fenêtre 0 écrite, sentinelle pas
    /// encore — est NORMALE : c'est l'état de toute page pendant la campagne.
    func testAnIncompletePageIsNotAnInconsistency() throws {
        let db = try makeDB(lockTimeout: 0.3)
        let docID = try addDoc(db, relPath: "encours.pdf")
        try db.store.replacePages(docID: docID, pages: [page(1, "en cours")])
        let rowid = Schema.ftsRowID(docID: docID, page: 1)
        try db.store.upsertVectors([
            (Schema.vecRowID(pageRowID: rowid, chunk: 0),
             Data(repeating: 1, count: 384)),
        ])
        XCTAssertTrue(try db.store.checkVectors().isClean)
    }

    // MARK: - Réparation

    func testRepairRemovesTheOrphansAndRequeuesThePage() throws {
        let (db, pages) = try seeded()
        let foreign = Schema.vecRowID(pageRowID: pages[0],
                                      chunk: Schema.vecWindowMax + 1)
        try db.store.upsertVectors([
            (foreign, Data(repeating: 2, count: 384)),
            (Schema.ftsRowID(docID: 3, page: 8), Data(repeating: 3, count: 384)),
            (Schema.vecRowID(pageRowID: Schema.ftsRowID(docID: 9, page: 4),
                             chunk: 1), Data(repeating: 4, count: 384)),
        ])
        try db.store.writeLocked { conn in
            try conn.execute(sql: "DELETE FROM page_vec WHERE rowid = ?",
                           arguments: [Schema.vecRowID(pageRowID: pages[2],
                                                       chunk: 0)])
        }
        // 6 lignes saines + 3 semées, moins la fenêtre 0 qu'on vient d'ôter.
        XCTAssertEqual(try count(db, "SELECT count(*) FROM page_vec"), 8)

        // La page 3 se dit COMPLÈTE avant la réparation : la pompe ne la
        // reprendrait jamais.
        XCTAssertEqual(try db.store.pagesNeedingVector(limit: 10).count, 0)

        let repair = try db.store.repairVectors()
        XCTAssertEqual(repair.count(.foreignSlot), 1)
        XCTAssertEqual(repair.count(.orphanPage), 2)
        XCTAssertEqual(repair.count(.brokenSentinel), 1)
        XCTAssertEqual(repair.total, 4)
        XCTAssertEqual(repair.pagesRequeued, 1)

        XCTAssertEqual(try count(db, "SELECT count(*) FROM page_vec"), 4)
        XCTAssertTrue(try db.store.checkVectors().isClean)

        // …et elle est de retour dans la file de `fouine embed`, la seule
        // écriture que la réparation ait à faire pour la remettre au travail.
        XCTAssertEqual(try db.store.pagesNeedingVector(limit: 10).map(\.rowid),
                       [pages[2]])
    }

    func testRepairOnACleanDatabaseChangesNothing() throws {
        let (db, _) = try seeded()
        let repair = try db.store.repairVectors()
        XCTAssertEqual(repair.total, 0)
        XCTAssertEqual(repair.pagesRequeued, 0)
        XCTAssertEqual(try count(db, "SELECT count(*) FROM page_vec"), 6)
    }

    /// `maintain` SANS `--repair` ne touche à rien : le contrat de la commande
    /// (C2-06) est « optimiser », pas « supprimer ».
    func testMaintainWithoutRepairLeavesTheInconsistenciesInPlace() throws {
        let (db, pages) = try seeded()
        try db.store.upsertVectors([
            (Schema.vecRowID(pageRowID: pages[0],
                             chunk: Schema.vecWindowMax + 1),
             Data(repeating: 2, count: 384)),
        ])
        let plain = try db.store.maintain()
        XCTAssertNil(plain.vectorRepair)
        XCTAssertEqual(try count(db, "SELECT count(*) FROM page_vec"), 7)

        let repaired = try db.store.maintain(repair: true)
        XCTAssertEqual(repaired.vectorRepair?.total, 1)
        XCTAssertEqual(try count(db, "SELECT count(*) FROM page_vec"), 6)
        XCTAssertEqual(repaired.json["vector_repair"] is [String: Any], true)
    }

    /// `doctor --deep` porte le rapport : c'est LUI qui devait voir A1m-05 le
    /// jour même, et qui ne le voyait pas.
    func testDeepCheckCarriesTheVectorReport() throws {
        let (db, pages) = try seeded()
        try db.store.upsertVectors([
            (Schema.vecRowID(pageRowID: pages[1],
                             chunk: Schema.vecWindowMax), Data(repeating: 5, count: 384)),
        ])
        let deep = try db.store.deepCheck()
        XCTAssertEqual(deep.vectors?.count(.foreignSlot), 1)
        let vectors = deep.json["vectors"] as? [String: Any]
        XCTAssertEqual(vectors?["inconsistent"] as? Int, 1)
    }
}
