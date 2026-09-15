// OCRRequeueTests.swift — Tests de remise en file OCR (R-16).
// SPDX-License-Identifier: LicenseRef-Fouine-Source-Available

import Foundation
import XCTest
import GRDB
@testable import FouineCore

final class OCRRequeueTests: XCTestCase {

    // MARK: - 1. Pages douteuses remises en file, pages saines intactes

    func testRequeueDoubtfulPages() throws {
        let db = try makeDB()
        let docID = try addDoc(db, relPath: "scan.pdf")

        // Page 1 : douteuse (confiance 0.40 < 0.60)
        let page1 = ocrPage("texte flou et douteux", confidence: 0.40)
        try db.store.completeOCR(docID: docID, page: 1, result: page1)

        // Page 2 : saine (confiance 0.95 >= 0.60)
        let page2 = ocrPage("texte parfaitement net et lisible", confidence: 0.95)
        try db.store.completeOCR(docID: docID, page: 2, result: page2)

        // À cet instant, ocr_queue doit être vide (completeOCR dépile)
        let pendingBefore = try db.store.pendingOCRPages(limit: 10)
        XCTAssertTrue(pendingBefore.isEmpty)

        // Remise en file de la population douteuse
        let result = try db.store.requeueOCRPages(.doubtful)
        XCTAssertEqual(result.requeued, 1)
        XCTAssertEqual(result.alreadyQueued, 0)
        XCTAssertEqual(result.totalCandidates, 1)

        // Vérification de ocr_queue : seule la page 1 est présente, à prio 3, attempts 0
        let pendingAfter = try db.store.pendingOCRPages(limit: 10)
        XCTAssertEqual(pendingAfter.count, 1)
        XCTAssertEqual(pendingAfter.first?.docID, docID)
        XCTAssertEqual(pendingAfter.first?.page, 1)
        XCTAssertEqual(pendingAfter.first?.prio, GRDBStore.defaultOCRRequeuePriority)

        // Le texte existant dans page_fts n'a PAS été touché
        let body = try db.store.read { raw in
            try String.fetchOne(raw, sql: "SELECT body FROM page_fts WHERE doc_id = ? AND page = ?", arguments: [docID, 1])
        }
        XCTAssertEqual(body, "texte flou et douteux")

        // L'état du document est repassé à queued
        let state = try db.store.read { raw in
            try Int.fetchOne(raw, sql: "SELECT ocr_state FROM docs WHERE id = ?", arguments: [docID])
        }
        XCTAssertEqual(state, OCRState.queued.rawValue)
    }

    // MARK: - 2. Pages déjà en file ignorées et non dupliquées

    func testRequeuePagesAlreadyInQueueAreIgnored() throws {
        let db = try makeDB()
        let docID = try addDoc(db, relPath: "already_queued.pdf")

        // Complète l'OCR avec une faible confiance
        let page1 = ocrPage("texte douteux", confidence: 0.35)
        try db.store.completeOCR(docID: docID, page: 1, result: page1)

        // Insère manuellement la page dans ocr_queue avec prio = 1 et attempts = 2
        try db.store.writeLocked { raw in
            try raw.execute(sql: """
                INSERT INTO ocr_queue(doc_id, page, prio, attempts) VALUES (?, ?, 1, 2)
                """, arguments: [docID, 1])
        }

        // Remise en file
        let result = try db.store.requeueOCRPages(.doubtful)
        XCTAssertEqual(result.requeued, 0, "la page déjà en file ne doit pas être réinsérée")
        XCTAssertEqual(result.alreadyQueued, 1, "la page doit être comptabilisée comme déjà en file")
        XCTAssertEqual(result.totalCandidates, 1)

        // Vérifie que prio = 1 et attempts = 2 ont été préservés
        try db.store.read { raw in
            let row = try Row.fetchOne(raw, sql: "SELECT prio, attempts FROM ocr_queue WHERE doc_id = ? AND page = ?", arguments: [docID, 1])
            let prio: Int? = row?["prio"]
            let attempts: Int? = row?["attempts"]
            XCTAssertEqual(prio, 1, "la priorité existante ne doit pas être écrasée")
            XCTAssertEqual(attempts, 2, "les tentatives existantes ne doivent pas être remises à zéro")
        }
    }

    // MARK: - 3. Population noLines

    func testRequeueNoLinesPopulation() throws {
        let db = try makeDB()
        let docID = try addDoc(db, relPath: "no_lines.pdf")

        // Page 1 : aucune ligne reconnue (sentinelle conf = 0)
        let pageNoLines = ocrPage("", lines: [], confidence: 0.0)
        try db.store.completeOCR(docID: docID, page: 1, result: pageNoLines)

        // Page 2 : douteuse avec du texte (confiance 0.45)
        let pageDoubtful = ocrPage("du texte mais faible", confidence: 0.45)
        try db.store.completeOCR(docID: docID, page: 2, result: pageDoubtful)

        // Remise en file avec .noLines : seule la page 1 doit être retenue
        let result = try db.store.requeueOCRPages(.noLines)
        XCTAssertEqual(result.requeued, 1)
        XCTAssertEqual(result.totalCandidates, 1)

        let pending = try db.store.pendingOCRPages(limit: 10)
        XCTAssertEqual(pending.count, 1)
        XCTAssertEqual(pending.first?.page, 1)
    }

    // MARK: - 3 ter. Une transcription n'a pas d'image à relire (IX2)

    /// Une page mise par écrit depuis un son porte `conf` NULL, comme une page
    /// OCR sans ligne. Le filtre `src != 0` la comptait « sans ligne » et la
    /// remettait en file, où l'OCR échouait trois fois avant de marquer le
    /// document en échec : deux vidéos de la production, le 12/09/2026.
    func testTranscriptPagesAreNeitherCountedNorRequeued() throws {
        let db = try makeDB()
        let video = try addDoc(db, relPath: "cours.mp4", ext: "mp4")
        try db.store.replacePages(docID: video, pages: [
            page(1, "[00:00] bonjour à tous", .transcript),
            page(2, "[10:00] reprenons", .transcript),
        ])
        let blank = try addDoc(db, relPath: "page-blanche.pdf")
        try db.store.completeOCR(docID: blank, page: 1,
                                 result: ocrPage("", lines: [], confidence: 0.0))

        let stats = try db.store.stats()
        XCTAssertEqual(stats["pages_ocr_no_lines"], 1, "la page blanche, pas les transcriptions")
        XCTAssertEqual(stats["pages_ocr_low_conf"], 0)

        let result = try db.store.requeueOCRPages(.noLines)
        XCTAssertEqual(result.totalCandidates, 1)
        XCTAssertEqual(try db.store.pendingOCRPages(limit: 10).map(\.docID), [blank])
        let videoState = try db.store.read { raw in
            try Int.fetchOne(raw, sql: "SELECT ocr_state FROM docs WHERE id = ?",
                             arguments: [video])
        }
        XCTAssertNotEqual(videoState, OCRState.queued.rawValue)
    }

    /// Les comptes PAR DOCUMENT suivent la même règle : `ocr_pages` de
    /// `fouine_list_documents` et `scannedPages` de la remise à Spotlight ne
    /// comptent plus une transcription comme une page OCR ; Spotlight la reçoit
    /// à part, par `transcribedPages`.
    func testPerDocumentCountsSeparateScansFromTranscripts() throws {
        let db = try makeDB()
        let video = try addDoc(db, relPath: "amphi.mp4", ext: "mp4")
        try db.store.replacePages(docID: video, pages: [
            page(1, "[00:00] bonjour", .transcript),
            page(2, "[10:00] suite", .transcript),
        ])
        let scan = try addDoc(db, relPath: "scan.pdf")
        try db.store.completeOCR(docID: scan, page: 1,
                                 result: ocrPage("texte reconnu", confidence: 0.9))

        let ocr = try db.store.ocrPageCounts(forDocIDs: [video, scan])
        XCTAssertEqual(ocr[video] ?? 0, 0)
        XCTAssertEqual(ocr[scan], 1)

        let changes = Dictionary(uniqueKeysWithValues:
            try db.store.documentsChanged(since: 0, limit: 10).map { ($0.id, $0) })
        XCTAssertEqual(changes[video]?.scannedPages, 0)
        XCTAssertEqual(changes[video]?.transcribedPages, 2)
        XCTAssertEqual(changes[scan]?.scannedPages, 1)
        XCTAssertEqual(changes[scan]?.transcribedPages, 0)
    }

    // MARK: - 3 bis. UNE page relue à la demande (lot BR1, constat PR-24)

    /// Le geste « Relire cette page » de l'aperçu : la page vient de l'OCR, elle
    /// repart en file à la priorité de fond, et le document repasse en attente.
    /// SANS condition de confiance — une page « sûre » aux yeux de Vision peut
    /// être illisible aux yeux du lecteur, et c'est lui qui demande.
    func testRereadingOneScannedPageQueuesIt() throws {
        let db = try makeDB()
        let docID = try addDoc(db, relPath: "scan-relu.pdf")
        // Confiance 0,95 : elle n'appartient à AUCUNE des deux populations de
        // `requeueOCRPages`, et c'est le point du geste à la page.
        try db.store.completeOCR(docID: docID, page: 4,
                                 result: ocrPage("texte net mais faux", confidence: 0.95))

        let result = try db.store.requeueOCRPage(docID: docID, page: 4)
        XCTAssertEqual(result, OCRRequeueResult(requeued: 1, alreadyQueued: 0,
                                                totalCandidates: 1))

        let pending = try db.store.pendingOCRPages(limit: 10)
        XCTAssertEqual(pending.count, 1)
        XCTAssertEqual(pending.first?.page, 4)
        XCTAssertEqual(pending.first?.prio, GRDBStore.defaultOCRRequeuePriority)

        let state = try db.store.read { raw in
            try Int.fetchOne(raw, sql: "SELECT ocr_state FROM docs WHERE id = ?",
                             arguments: [docID])
        }
        XCTAssertEqual(state, OCRState.queued.rawValue)
    }

    /// Une page dont le texte vient du DOCUMENT n'a pas d'image à relire : le
    /// refus est nommé, et rien n'entre en file.
    func testRereadingANativePageIsRefused() throws {
        let db = try makeDB()
        let docID = try addDoc(db, relPath: "texte-natif.pdf")
        try db.store.replacePages(docID: docID, pages: [page(1, "du texte tapé")])

        XCTAssertThrowsError(try db.store.requeueOCRPage(docID: docID, page: 1)) { error in
            guard case FouineError.ocr(let message)? = error as? FouineError else {
                return XCTFail("erreur inattendue : \(error)")
            }
            XCTAssertTrue(message.contains("does not come from OCR"), message)
        }
        XCTAssertTrue(try db.store.pendingOCRPages(limit: 10).isEmpty)

        // Une page qui n'existe pas du tout : même refus, pas un plantage.
        XCTAssertThrowsError(try db.store.requeueOCRPage(docID: docID, page: 99))
    }

    /// Deux clics de suite : la seconde remise ne double pas la ligne et ne
    /// touche ni la priorité ni les tentatives. « C'était déjà fait » n'est pas
    /// une erreur.
    func testRereadingTwiceReportsAlreadyQueued() throws {
        let db = try makeDB()
        let docID = try addDoc(db, relPath: "deja-en-file.pdf")
        try db.store.completeOCR(docID: docID, page: 2,
                                 result: ocrPage("flou", confidence: 0.30))

        XCTAssertEqual(try db.store.requeueOCRPage(docID: docID, page: 2).requeued, 1)
        let second = try db.store.requeueOCRPage(docID: docID, page: 2)
        XCTAssertEqual(second, OCRRequeueResult(requeued: 0, alreadyQueued: 1,
                                                totalCandidates: 1))
        XCTAssertEqual(try db.store.pendingOCRPages(limit: 10).count, 1)
    }

    /// Verrou tenu par un autre processus : le refus remonte tel quel, en 0,3 s
    /// (jamais les 5 s par défaut). C'est ce que l'app traduit par « L'index se
    /// met à jour — réessayez dans un instant. ».
    func testRereadingOnePageFailsWhenWriteLockHeld() throws {
        let db = try makeDB(lockTimeout: 0.3)
        let docID = try addDoc(db, relPath: "verrou.pdf")
        try db.store.completeOCR(docID: docID, page: 1,
                                 result: ocrPage("flou", confidence: 0.40))
        db.store.releaseWriteLock()

        let competitor = GRDBStore(lockTimeout: 0.3)
        try competitor.open(at: db.directory.appendingPathComponent("fouine.db"))
        try competitor.acquireWriteLock(as: .agent)
        defer { competitor.releaseWriteLock() }

        XCTAssertThrowsError(try db.store.requeueOCRPage(docID: docID, page: 1)) { error in
            XCTAssertTrue(WriteLock.isBusy(error), "\(error)")
        }
    }

    // MARK: - 4. Respect du paramètre limit

    func testRequeueHonoursLimit() throws {
        let db = try makeDB()
        let docID = try addDoc(db, relPath: "multi_pages.pdf")

        for p in 1...5 {
            let page = ocrPage("page douteuse \(p)", confidence: 0.30)
            try db.store.completeOCR(docID: docID, page: p, result: page)
        }

        // Limite à 2 pages
        let result = try db.store.requeueOCRPages(.doubtful, limit: 2)
        XCTAssertEqual(result.requeued, 2)
        XCTAssertEqual(result.totalCandidates, 2)

        let pending = try db.store.pendingOCRPages(limit: 10)
        XCTAssertEqual(pending.count, 2)
    }

    // MARK: - 5. Refus de verrou sous lockTimeout: 0.3

    func testRequeueFailsWhenWriteLockHeld() throws {
        let db = try makeDB(lockTimeout: 0.3)
        let docID = try addDoc(db, relPath: "locked.pdf")
        let page = ocrPage("page à requeue", confidence: 0.40)
        try db.store.completeOCR(docID: docID, page: 1, result: page)
        db.store.releaseWriteLock()

        // Simule un autre processus (l'agent) qui détient le verrou
        let competitor = GRDBStore(lockTimeout: 0.3)
        try competitor.open(at: db.directory.appendingPathComponent("fouine.db"))
        try competitor.acquireWriteLock(as: .agent)
        defer { competitor.releaseWriteLock() }

        XCTAssertThrowsError(try db.store.requeueOCRPages(.doubtful)) { error in
            XCTAssertTrue(WriteLock.isBusy(error), "doit être une erreur WriteLock.isBusy : \(error)")
            if let busy = WriteLock.busy(error) {
                XCTAssertEqual(busy.holder?.role, .agent)
            }
        }
    }
}
