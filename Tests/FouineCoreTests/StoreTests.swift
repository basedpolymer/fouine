// StoreTests.swift — rowid structuré, replacePages, upsertDoc, OCR, stats.
// SPEC §4.1, §4.2, §5.1, §6.2, §6.3. Propriété : A-Core.

import Foundation
import XCTest
@testable import FouineCore

final class StoreTests: XCTestCase {

    // MARK: - Droits des fichiers (audit A1-06, D2-09)

    /// Une base NEUVE : le `.db`, son `-wal`, son `-shm` et `fouine.lock`
    /// doivent être en 0600. Ils étaient en 0644 : le contenu indexé de tous
    /// les documents — 380 000 pages de texte en clair sur la machine de
    /// recette — n'était protégé que par le mode de `~/Library`, qui
    /// n'appartient pas à Fouine.
    ///
    /// TEST CONDITIONNÉ AU SYSTÈME DE FICHIERS (D2-09) : sur un volume monté
    /// `noowners`, un partage SMB ou une restauration sans modes, `chmod`
    /// réussit sans rien changer — et le durcissement, qui est best-effort par
    /// construction, n'a alors rien à prouver. On relit donc le mode après un
    /// `chmod` témoin, et on se saute s'il ne colle pas : une CI sur un runner
    /// à volume exotique ne doit pas devenir rouge pour ça.
    func testFreshDatabaseFilesAreOwnerOnly() throws {
        let db = try makeDB()
        // Une écriture, pour que `-wal` et `-shm` existent.
        let docID = try addDoc(db, relPath: "Users/essai/Livres/droits.pdf")
        try db.store.replacePages(docID: docID, pages: [page(1, "azote enthalpie")])
        // Et une prise de verrou, pour que `fouine.lock` existe.
        try db.store.acquireWriteLock(as: .cli)
        defer { db.store.releaseWriteLock() }

        let witness = db.directory.appendingPathComponent("temoin")
        try Data("x".utf8).write(to: witness)
        try XCTSkipUnless(FilePermissions.restrictFile(witness) == 0o600,
                          "ce système de fichiers ne porte pas les droits POSIX")

        let base = db.directory.appendingPathComponent("fouine.db")
        for name in ["fouine.db", "fouine.db-wal", "fouine.db-shm", "fouine.lock"] {
            let url = db.directory.appendingPathComponent(name)
            guard FileManager.default.fileExists(atPath: url.path) else {
                XCTFail("\(name) devrait exister")
                continue
            }
            let mode = (try FileManager.default
                .attributesOfItem(atPath: url.path)[.posixPermissions] as? NSNumber)?
                .uint16Value
            XCTAssertEqual(mode, 0o600, "\(name) : droits \(mode.map { String($0, radix: 8) } ?? "?")")
        }
        XCTAssertTrue(FileManager.default.fileExists(atPath: base.path))
    }

    /// Un répertoire qui n'est PAS l'emplacement par défaut n'est jamais
    /// refermé : `FOUINE_DB` peut désigner un dossier partagé, et ses droits
    /// sont la décision de l'utilisateur (règle 2 de D2-09).
    func testANonDefaultDirectoryIsLeftAlone() throws {
        let db = try makeDB()
        XCTAssertFalse(FilePermissions.isDefaultSupport(db.directory),
                       "un dossier temporaire n'est pas l'emplacement par défaut")
        let mode = (try FileManager.default
            .attributesOfItem(atPath: db.directory.path)[.posixPermissions]
            as? NSNumber)?.uint16Value
        XCTAssertNotEqual(mode, 0o700,
                          "le répertoire de test a été refermé alors qu'il "
                          + "n'est pas celui de Fouine")
    }

    // MARK: - Rowid structuré (§4.1, piège n°5)

    func testStructuredRowIDs() throws {
        let db = try makeDB()
        let docID = try addDoc(db, relPath: "Users/alice/Livres/a.pdf")
        try db.store.replacePages(docID: docID, pages: [
            page(1, "première page azote"), page(2, "deuxième page reduction"),
            page(7, "septième page enthalpie"),
        ])

        let rowids = try db.store.rawInt64s("SELECT rowid FROM page_fts ORDER BY rowid")
        XCTAssertEqual(rowids, [1, 2, 7].map { Schema.ftsRowID(docID: docID, page: $0) })
        XCTAssertEqual(Schema.ftsRowID(docID: docID, page: 7), docID * 100_000 + 7)

        // Suppression PAR PLAGE : la plage d'un autre document ne bouge pas.
        let other = try addDoc(db, relPath: "Users/alice/Livres/b.pdf")
        try db.store.replacePages(docID: other, pages: [page(1, "autre document")])
        try db.store.removeDoc(id: docID)
        let remaining = try db.store.rawInt64s("SELECT rowid FROM page_fts ORDER BY rowid")
        XCTAssertEqual(remaining, [Schema.ftsRowID(docID: other, page: 1)])
        XCTAssertEqual(try db.store.rawInt64s(
            "SELECT count(*) FROM page_src WHERE doc_id = \(docID)"), [0])
        XCTAssertEqual(try db.store.rawInt64s(
            "SELECT count(*) FROM docs WHERE id = \(docID)"), [0])
    }

    /// Un document ré-extrait avec MOINS de pages ne laisse rien derrière lui —
    /// ni file d'OCR, ni boîtes de lignes (audit A1m-13).
    ///
    /// `replacePages` purgeait `page_fts`, `page_vec` et `page_src`, mais ni
    /// `ocr_queue` ni `ocr_layout` : les pages disparues restaient en file,
    /// étaient rendues, échouaient et étaient retentées trois fois, et leurs
    /// blobs de mise en page survivaient à ce qu'ils décrivaient.
    func testReplacePagesPurgesTheOCRQueueAndLayoutOfVanishedPages() throws {
        let db = try makeDB(lockTimeout: 0.3)
        let docID = try addDoc(db, relPath: "Users/alice/Livres/repagine.pdf")
        try db.store.replacePages(docID: docID, pages: (1...5).map {
            page($0, "page \($0) azote")
        })
        try db.store.enqueueOCR(docID: docID, pages: Array(1...5), priority: 2)
        for p in 1...5 {
            try db.store.completeOCR(docID: docID, page: p,
                                     result: ocrPage("page \(p) reconnue"))
        }
        // `completeOCR` vide la file au fur et à mesure : on la re-remplit pour
        // que les deux tables soient peuplées au moment de la re-pagination.
        try db.store.enqueueOCR(docID: docID, pages: Array(1...5), priority: 2)
        XCTAssertEqual(try db.store.rawInt64s(
            "SELECT count(*) FROM ocr_queue WHERE doc_id = \(docID)"), [5])
        XCTAssertEqual(try db.store.rawInt64s(
            "SELECT count(*) FROM ocr_layout WHERE rowid BETWEEN "
            + "\(Schema.ftsRowIDRange(docID: docID).lowerBound) AND "
            + "\(Schema.ftsRowIDRange(docID: docID).upperBound)"), [5])

        // Ré-extraction : le document n'a plus que deux pages.
        try db.store.replacePages(docID: docID, pages: (1...2).map {
            page($0, "page \($0) réécrite")
        })

        XCTAssertEqual(try db.store.rawInt64s(
            "SELECT page FROM ocr_queue WHERE doc_id = \(docID) ORDER BY page"),
            [1, 2], "les pages disparues quittent la file d'OCR")
        XCTAssertEqual(try db.store.rawInt64s(
            "SELECT rowid % 100000 FROM ocr_layout WHERE rowid BETWEEN "
            + "\(Schema.ftsRowIDRange(docID: docID).lowerBound) AND "
            + "\(Schema.ftsRowIDRange(docID: docID).upperBound) ORDER BY rowid"),
            [1, 2], "leurs boîtes de lignes partent avec elles")
        XCTAssertNil(try db.store.ocrLayout(docID: docID, page: 4))

        // Un document ré-extrait à ZÉRO page ne garde rien non plus.
        try db.store.replacePages(docID: docID, pages: [])
        XCTAssertEqual(try db.store.rawInt64s(
            "SELECT count(*) FROM ocr_queue WHERE doc_id = \(docID)"), [0])
        XCTAssertEqual(try db.store.rawInt64s(
            "SELECT count(*) FROM ocr_layout WHERE rowid BETWEEN "
            + "\(Schema.ftsRowIDRange(docID: docID).lowerBound) AND "
            + "\(Schema.ftsRowIDRange(docID: docID).upperBound)"), [0])
    }

    /// …et la purge ne déborde JAMAIS sur le document voisin : la plage de
    /// rowid est celle d'un seul document.
    func testReplacePagesLeavesTheNeighbourDocumentAlone() throws {
        let db = try makeDB(lockTimeout: 0.3)
        let first = try addDoc(db, relPath: "Users/alice/Livres/un.pdf")
        let second = try addDoc(db, relPath: "Users/alice/Livres/deux.pdf")
        for docID in [first, second] {
            try db.store.replacePages(docID: docID, pages: (1...3).map {
                page($0, "page \($0)")
            })
            try db.store.enqueueOCR(docID: docID, pages: [1, 2, 3], priority: 2)
            try db.store.completeOCR(docID: docID, page: 3,
                                     result: ocrPage("reconnue"))
            try db.store.enqueueOCR(docID: docID, pages: [3], priority: 2)
        }
        try db.store.replacePages(docID: first, pages: [page(1, "réécrite")])

        XCTAssertEqual(try db.store.rawInt64s(
            "SELECT count(*) FROM ocr_queue WHERE doc_id = \(second)"), [3])
        XCTAssertNotNil(try db.store.ocrLayout(docID: second, page: 3))
    }

    func testFTSRowIDRangeCoversAllPages() {
        let range = Schema.ftsRowIDRange(docID: 42)
        XCTAssertEqual(range.lowerBound, 4_200_000)
        XCTAssertEqual(range.upperBound, 4_299_999)
        XCTAssertTrue(range.contains(Schema.ftsRowID(docID: 42, page: 1_570)))
        XCTAssertFalse(range.contains(Schema.ftsRowID(docID: 43, page: 1)))
    }

    // MARK: - S2 · borne du rowid structuré

    /// La DERNIÈRE page représentable reste représentable, et son rowid ne
    /// déborde pas sur le document suivant.
    func testLastRepresentablePageStaysInsideItsOwnDocument() {
        XCTAssertEqual(Schema.maxPage, 99_999)
        let last = Schema.ftsRowID(docID: 42, page: Schema.maxPage)
        XCTAssertEqual(last, 4_299_999)
        XCTAssertTrue(Schema.ftsRowIDRange(docID: 42).contains(last))
        XCTAssertLessThan(last, Schema.ftsRowIDRange(docID: 43).lowerBound)
    }

    /// Un document de `pagesPerDocLimit` pages est REFUSÉ, et rien de ce qu'il
    /// apportait n'atterrit sur le document suivant (audit S2).
    func testReplacePagesRefusesADocumentBeyondTheStructuredRowIDLimit() throws {
        let db = try makeDB()
        let docID = try addDoc(db, relPath: "Users/alice/Livres/interminable.pdf")
        let next = try addDoc(db, relPath: "Users/alice/Livres/suivant.pdf")
        XCTAssertEqual(next, docID + 1, "le test suppose deux id consécutifs")
        try db.store.replacePages(docID: next, pages: [page(1, "document suivant")])

        // La page 100 000 porterait EXACTEMENT le rowid de la page 0 du suivant.
        XCTAssertThrowsError(
            try db.store.replacePages(docID: docID, pages: [
                page(1, "première page"),
                page(Int(Schema.pagesPerDocLimit), "la page de trop"),
            ])
        ) { error in
            guard case let FouineError.extraction(message) = error else {
                return XCTFail("attendu extraction, obtenu \(error)")
            }
            XCTAssertTrue(message.contains("document too long"), message)
            XCTAssertTrue(message.contains("100000"), message)
        }

        // Le refus tombe AVANT la transaction : ni le document refusé ni son
        // voisin n'ont bougé.
        XCTAssertEqual(try db.store.rawInt64s(
            "SELECT count(*) FROM page_fts WHERE doc_id = \(docID)"), [0])
        let voisin = try db.store.rawInt64s(
            "SELECT rowid FROM page_fts WHERE doc_id = \(next)")
        XCTAssertEqual(voisin, [Schema.ftsRowID(docID: next, page: 1)])

        // La page 99 999, elle, passe.
        XCTAssertNoThrow(try db.store.replacePages(docID: docID, pages: [
            page(Schema.maxPage, "dernière page représentable"),
        ]))
        XCTAssertEqual(try db.store.rawInt64s(
            "SELECT rowid FROM page_fts WHERE doc_id = \(next)"), voisin)
    }

    /// Le canal externe (`fouine ocr import`, annexe B) n'a aucun privilège.
    func testCompleteOCRRefusesAPageBeyondTheLimit() throws {
        let db = try makeDB()
        let docID = try addDoc(db, relPath: "Users/alice/Livres/ocr.pdf")
        // 100 000 -> page 0 du document SUIVANT ; −1 -> dernière page du
        // PRÉCÉDENT. Les deux sortent du document, la borne les refuse.
        // (La page 0, elle, reste DANS `ftsRowIDRange(docID:)` : elle
        // n'écrase rien et n'est pas du ressort de S2.)
        for page in [Int(Schema.pagesPerDocLimit), -1] {
            XCTAssertThrowsError(
                try db.store.completeOCR(docID: docID, page: page,
                                         result: ocrPage("texte importé"))
            ) { error in
                guard case let FouineError.extraction(message) = error else {
                    return XCTFail("attendu extraction, obtenu \(error)")
                }
                XCTAssertTrue(message.contains("document too long"), message)
            }
        }
    }

    // MARK: - replacePages

    func testReplacePagesIsIdempotent() throws {
        let db = try makeDB()
        let docID = try addDoc(db, relPath: "Users/alice/Livres/c.pdf")
        let pages = [page(1, "alpha beta"), page(2, "gamma delta")]

        try db.store.replacePages(docID: docID, pages: pages)
        let first = try db.store.rawInt64s("SELECT count(*) FROM page_fts")[0]
        try db.store.replacePages(docID: docID, pages: pages)
        let second = try db.store.rawInt64s("SELECT count(*) FROM page_fts")[0]
        XCTAssertEqual(first, 2)
        XCTAssertEqual(second, 2)

        // Les pages non refournies disparaissent de page_src comme de page_fts.
        try db.store.replacePages(docID: docID, pages: [page(1, "alpha beta")])
        XCTAssertEqual(try db.store.rawInt64s("SELECT count(*) FROM page_fts"), [1])
        XCTAssertEqual(try db.store.rawInt64s(
            "SELECT page FROM page_src WHERE doc_id = \(docID) ORDER BY page"), [1])
        XCTAssertEqual(try db.store.rawInt64s(
            "SELECT src FROM page_src WHERE doc_id = \(docID)"), [0])
        XCTAssertEqual(try db.store.rawInt64s(
            "SELECT nchars FROM page_src WHERE doc_id = \(docID)"),
            [Int64("alpha beta".count)])
    }

    // MARK: - upsertDoc (delta no-op, T10)

    func testUpsertDocDeltaNoOpKeepsState() throws {
        let db = try makeDB()
        let record = DocRecord(volUUID: "TEST-VOL", relPath: "Users/alice/Livres/d.pdf",
                               ext: "pdf", topFolder: "Livres", size: 4_096,
                               mtime: 1_700_000_000)
        let id = try db.store.upsertDoc(record)
        try db.store.setDocState(id, .extracted, err: nil)
        try db.store.setPageCount(id, 320)
        try db.store.enqueueOCR(docID: id, pages: [3], priority: 2)

        // (size, mtime) identiques -> no-op : state, ocr_state, n_pages conservés.
        let again = try db.store.upsertDoc(record)
        XCTAssertEqual(again, id)
        let row = try XCTUnwrap(db.store.docRow(id: id))
        XCTAssertEqual(row.record.state, .extracted)
        XCTAssertEqual(row.record.ocrState, .queued)
        XCTAssertEqual(row.record.nPages, 320)
        XCTAssertEqual(try db.store.rawInt64s("SELECT count(*) FROM ocr_queue"), [1])

        // mtime différent -> le contenu a changé : state repris, OCR invalidé.
        var changed = record
        changed.mtime += 1
        let third = try db.store.upsertDoc(changed)
        XCTAssertEqual(third, id)
        let after = try XCTUnwrap(db.store.docRow(id: id))
        XCTAssertEqual(after.record.state, .discovered)
        XCTAssertEqual(after.record.ocrState, .notNeeded)
        XCTAssertEqual(try db.store.rawInt64s("SELECT count(*) FROM ocr_queue"), [0])
    }

    // MARK: - OCR (§6.2)

    func testCompleteOCRShortTextIsMarkedProcessedButNotIndexed() throws {
        let db = try makeDB()
        let docID = try addDoc(db, relPath: "Users/alice/Cours/scan.pdf", folder: "Cours")
        try db.store.enqueueOCR(docID: docID, pages: [1, 2], priority: 0)

        // Moins de 20 caractères : page traitée, nchars = 0, aucune ligne FTS (§6.2).
        try db.store.completeOCR(docID: docID, page: 1, result: ocrPage("court"))
        XCTAssertEqual(try db.store.rawInt64s(
            "SELECT count(*) FROM page_fts WHERE rowid = "
            + "\(Schema.ftsRowID(docID: docID, page: 1))"), [0])
        XCTAssertEqual(try db.store.rawInt64s(
            "SELECT nchars FROM page_src WHERE doc_id = \(docID) AND page = 1"), [0])
        XCTAssertEqual(try db.store.rawInt64s(
            "SELECT src FROM page_src WHERE doc_id = \(docID) AND page = 1"),
            [Int64(PageSource.ocrAccurate.rawValue)])
        XCTAssertEqual(try XCTUnwrap(db.store.docRow(id: docID)).record.ocrState, .partial)

        // Page utile : ligne FTS présente et disposition relisible.
        let text = "Connaissant le taux de conversion et le temps de passage"
        try db.store.completeOCR(docID: docID, page: 2, result: ocrPage(text))
        XCTAssertEqual(try db.store.rawInt64s(
            "SELECT count(*) FROM page_fts WHERE rowid = "
            + "\(Schema.ftsRowID(docID: docID, page: 2))"), [1])
        XCTAssertEqual(try XCTUnwrap(db.store.docRow(id: docID)).record.ocrState, .done)
        XCTAssertEqual(try db.store.rawInt64s("SELECT count(*) FROM ocr_queue"), [0])

        let layout = try XCTUnwrap(db.store.ocrLayout(docID: docID, page: 2))
        XCTAssertEqual(layout.count, 1)
        XCTAssertEqual(layout[0].text, text)
        XCTAssertEqual(layout[0].y, 0.8, accuracy: 1e-9)
    }

    func testOCRLayoutKeepsEveryLineIncludingRejected() throws {
        let db = try makeDB()
        let docID = try addDoc(db, relPath: "Users/alice/Cours/manuscrit.pdf",
                               folder: "Cours")
        let lines = [
            OCRLine(text: "ligne sûre et parfaitement lisible", x: 0, y: 0.9,
                    w: 1, h: 0.03, confidence: 0.95),
            OCRLine(text: "brouillard", x: 0, y: 0.5, w: 1, h: 0.03, confidence: 0.11),
        ]
        let result = OCRPage(text: lines[0].text, lines: lines, level: .accurate,
                             seconds: 2, engine: .vision, engineRev: "vision-rev3",
                             meanConfidence: 0.95)
        try db.store.completeOCR(docID: docID, page: 1, result: result)

        let layout = try XCTUnwrap(db.store.ocrLayout(docID: docID, page: 1))
        XCTAssertEqual(layout.count, 2, "TOUTES les lignes vont dans ocr_layout (§6.2)")
        XCTAssertEqual(layout[1].confidence, 0.11, accuracy: 1e-9)
    }

    func testZlibRoundTripOnLargeLayout() throws {
        let lines = (0..<500).map {
            OCRLine(text: "ligne \($0) — texte accentué éèàç", x: 0.1, y: Double($0) / 500,
                    w: 0.8, h: 0.01, confidence: 0.8)
        }
        let blob = try OCRLayoutCodec.encode(lines)
        XCTAssertLessThan(blob.count, 500 * 40)
        let back = try OCRLayoutCodec.decode(blob)
        XCTAssertEqual(back.count, 500)
        XCTAssertEqual(back[499].text, lines[499].text)
    }

    func testFailOCRAbandonsAfterThreeAttempts() throws {
        let db = try makeDB()
        let docID = try addDoc(db, relPath: "Users/alice/Livres/e.pdf")
        try db.store.enqueueOCR(docID: docID, pages: [5], priority: 1)
        try db.store.failOCR(docID: docID, page: 5)
        XCTAssertEqual(try db.store.rawInt64s(
            "SELECT attempts FROM ocr_queue WHERE doc_id = \(docID)"), [1])
        try db.store.failOCR(docID: docID, page: 5)
        try db.store.failOCR(docID: docID, page: 5)
        XCTAssertEqual(try db.store.rawInt64s("SELECT count(*) FROM ocr_queue"), [0])
        let row = try XCTUnwrap(db.store.docRow(id: docID))
        XCTAssertEqual(row.record.ocrState, .failed)
        XCTAssertNotNil(row.record.err)
    }

    func testNextOCRBatchOrdersByPriorityAndFailsOnUnmountedVolume() throws {
        let db = try makeDB()
        let a = try addDoc(db, relPath: "Users/alice/Cours/a.pdf", folder: "Cours")
        let b = try addDoc(db, relPath: "Users/alice/Livres/b.pdf")
        try db.store.enqueueOCR(docID: b, pages: [1], priority: 2)
        try db.store.enqueueOCR(docID: a, pages: [1], priority: 0)

        XCTAssertEqual(try db.store.rawInt64s(
            "SELECT doc_id FROM ocr_queue ORDER BY prio, attempts, doc_id, page"), [a, b])
        // Le volume « TEST-VOL » n'est pas monté : exit 2 (§4.3).
        XCTAssertThrowsError(try db.store.nextOCRBatch(limit: 10)) { error in
            guard case FouineError.volumeNotMounted = error else {
                return XCTFail("attendu volumeNotMounted, obtenu \(error)")
            }
        }
    }

    /// Famine de la file OCR évitée par « plus court reste d'abord » (a3-07, lot K3).
    /// Tri : `prio, attempts, remaining ASC, doc_id DESC, page`.
    func testOCRQueueOrdersByShortestRemainingJobFirst() throws {
        let db = try makeDB()
        let docShort = try addDoc(db, relPath: "short.pdf")
        let docMed = try addDoc(db, relPath: "med.pdf")
        let docBig = try addDoc(db, relPath: "big.pdf")

        try db.store.enqueueOCR(docID: docBig, pages: Array(1...1500), priority: 2)
        try db.store.enqueueOCR(docID: docMed, pages: Array(1...50), priority: 2)
        try db.store.enqueueOCR(docID: docShort, pages: Array(1...5), priority: 2)

        let batch = try db.store.pendingOCRPages(limit: 2000)
        XCTAssertEqual(batch.count, 1555)
        // 1. Les 5 pages du document court (5 pages restantes) sortent en premier :
        XCTAssertEqual(batch.prefix(5).map(\.docID), Array(repeating: docShort, count: 5))
        XCTAssertEqual(batch.prefix(5).map(\.page), Array(1...5))
        // 2. Puis les 50 pages du moyen (50 restantes) :
        XCTAssertEqual(batch[5..<55].map(\.docID), Array(repeating: docMed, count: 50))
        XCTAssertEqual(batch[5..<55].map(\.page), Array(1...50))
        // 3. Enfin les 1500 pages du grand (1500 restantes) :
        XCTAssertEqual(batch[55...].map(\.docID), Array(repeating: docBig, count: 1500))

        // La priorité 1 garde la main sur tout :
        let dbPrio = try makeDB()
        let pBig = try addDoc(dbPrio, relPath: "bigPrio.pdf")
        let pShort = try addDoc(dbPrio, relPath: "shortPrio.pdf")
        try dbPrio.store.enqueueOCR(docID: pBig, pages: Array(1...1500), priority: 1)
        try dbPrio.store.enqueueOCR(docID: pShort, pages: Array(1...5), priority: 2)
        let batchPrio = try dbPrio.store.pendingOCRPages(limit: 10)
        XCTAssertEqual(batchPrio.map(\.docID), Array(repeating: pBig, count: 10))

        // Attempts garde la main sur la taille :
        let dbAttempts = try makeDB()
        let aShort = try addDoc(dbAttempts, relPath: "shortAtt.pdf")
        let aMed = try addDoc(dbAttempts, relPath: "medAtt.pdf")
        try dbAttempts.store.enqueueOCR(docID: aShort, pages: [1, 2], priority: 2)
        try dbAttempts.store.failOCR(docID: aShort, page: 1)
        try dbAttempts.store.enqueueOCR(docID: aMed, pages: Array(1...50), priority: 2)
        let batchAttempts = try dbAttempts.store.pendingOCRPages(limit: 100)
        // Page 2 de aShort (prio 2, att 0, rem 2) sort avant aMed (prio 2, att 0, rem 50)
        XCTAssertEqual(batchAttempts[0].docID, aShort)
        XCTAssertEqual(batchAttempts[0].page, 2)
        // Toutes les pages de aMed (att 0) sortent avant la page 1 échouée (att 1) de aShort :
        XCTAssertEqual(batchAttempts[1...50].map(\.docID), Array(repeating: aMed, count: 50))
        XCTAssertEqual(batchAttempts.last?.docID, aShort)
        XCTAssertEqual(batchAttempts.last?.page, 1)
    }

    // MARK: - Racines et purge

    func testDocsUnderRootAndRemoveRoot() throws {
        let db = try makeDB()
        let url = db.directory.appendingPathComponent("racine", isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        try "contenu".write(to: url.appendingPathComponent("f.txt"),
                            atomically: true, encoding: .utf8)
        let rootID = try db.store.addRoot(path: url, label: nil)
        let root = try XCTUnwrap(db.store.roots().first)
        XCTAssertEqual(root.label, "racine", "étiquette par défaut = dernier segment")

        let inside = try db.store.upsertDoc(DocRecord(
            volUUID: root.volUUID, relPath: root.relPath + "/f.txt", ext: "txt",
            topFolder: root.label, size: 7, mtime: 1))
        _ = try db.store.upsertDoc(DocRecord(
            volUUID: root.volUUID, relPath: "ailleurs/g.txt", ext: "txt",
            topFolder: "Autre", size: 7, mtime: 1))
        try db.store.replacePages(docID: inside, pages: [page(1, "contenu")])

        let under = try db.store.docs(underRoot: rootID)
        XCTAssertEqual(under.map(\.id), [inside])

        try db.store.removeRoot(id: rootID)
        XCTAssertTrue(try db.store.roots().isEmpty)
        XCTAssertEqual(try db.store.rawInt64s("SELECT count(*) FROM page_fts"), [0])
        XCTAssertEqual(try db.store.rawInt64s("SELECT count(*) FROM docs"), [1])
    }

    func testAddRootRefusesUnreadableRoot() throws {
        let db = try makeDB()
        let missing = db.directory.appendingPathComponent("absent", isDirectory: true)
        XCTAssertThrowsError(try db.store.addRoot(path: missing, label: nil)) { error in
            guard case FouineError.rootUnreadable = error else {
                return XCTFail("attendu rootUnreadable, obtenu \(error)")
            }
        }
        XCTAssertTrue(try db.store.roots().isEmpty,
                      "une racine illisible ne doit PAS être enregistrée")
    }

    func testAddRootAcceptsEmptyDirectory() throws {
        let db = try makeDB()
        let empty = db.directory.appendingPathComponent("vide", isDirectory: true)
        try FileManager.default.createDirectory(at: empty, withIntermediateDirectories: true)
        XCTAssertNoThrow(try db.store.addRoot(path: empty, label: "Vide"))
    }

    // MARK: - Curseur FSEvents

    func testFSEventCursorRoundTrip() throws {
        let db = try makeDB()
        let url = db.directory.appendingPathComponent("r2", isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        try "x".write(to: url.appendingPathComponent("f"), atomically: true,
                      encoding: .utf8)
        _ = try db.store.addRoot(path: url, label: "R2")
        let uuid = try XCTUnwrap(db.store.roots().first).volUUID
        XCTAssertEqual(try db.store.fseventID(volUUID: uuid), 0)
        try db.store.setFSEventID(volUUID: uuid, 987_654_321)
        XCTAssertEqual(try db.store.fseventID(volUUID: uuid), 987_654_321)
    }

    // MARK: - Statistiques et vocabulaire

    /// `pages_indexed` compte désormais sur la table d'ombre
    /// `page_fts_docsize` et non par un balayage complet de `page_fts` — 16 à
    /// 45 s sur 1,1 Gio contre 0,28 s, et l'app faisait tourner ce balayage EN
    /// BOUCLE pendant toute une passe d'OCR (audit C2-03).
    ///
    /// L'équivalence des deux comptes est le seul risque du changement, et
    /// c'est ce que ce test tient : elle doit survivre à une suppression de
    /// document, à une RÉÉCRITURE de pages (`replacePages` supprime puis
    /// réinsère), à un `completeOCR`, et à un `optimize` de l'index.
    func testPagesIndexedMatchesTheFTSTableThroughDeletionsAndRewrites() throws {
        let db = try makeDB()

        func bothCounts() throws -> (docsize: Int, fts: Int) {
            let stats = try db.store.stats()
            let direct = try db.store.rawInt64s("SELECT count(*) FROM page_fts")
            return (stats["pages_indexed"] ?? -1, Int(direct.first ?? -1))
        }

        let a = try addDoc(db, relPath: "Users/essai/Livres/a.pdf")
        let b = try addDoc(db, relPath: "Users/essai/Livres/b.pdf")
        try db.store.replacePages(docID: a, pages: (1...5).map { page($0, "page \($0) azote") })
        try db.store.replacePages(docID: b, pages: (1...3).map { page($0, "page \($0) enthalpie") })
        var counts = try bothCounts()
        XCTAssertEqual(counts.docsize, 8)
        XCTAssertEqual(counts.docsize, counts.fts)

        // Réécriture : moins de pages qu'avant, sur les mêmes rowids.
        try db.store.replacePages(docID: a, pages: (1...2).map { page($0, "azote reecrit") })
        counts = try bothCounts()
        XCTAssertEqual(counts.docsize, 5)
        XCTAssertEqual(counts.docsize, counts.fts)

        // OCR d'une page : `completeOCR` réécrit la page en place.
        try db.store.enqueueOCR(docID: b, pages: [3], priority: 0)
        try db.store.completeOCR(docID: b, page: 3,
                                 result: ocrPage("page reconnue par Vision"))
        counts = try bothCounts()
        XCTAssertEqual(counts.docsize, counts.fts)

        // Suppression du document entier, par plage de rowids.
        try db.store.removeDoc(id: a)
        counts = try bothCounts()
        XCTAssertEqual(counts.docsize, 3)
        XCTAssertEqual(counts.docsize, counts.fts)

        // Et après une fusion des segments FTS5, qui réécrit l'index.
        try db.store.optimize()
        db.store.releaseWriteLock()
        counts = try bothCounts()
        XCTAssertEqual(counts.docsize, 3)
        XCTAssertEqual(counts.docsize, counts.fts)
    }

    // MARK: - Documents illisibles (UX-16)

    /// `unreadableDocuments` rend les deux états d'échec ET RIEN D'AUTRE,
    /// groupés par dossier. Les documents `discovered` (pas encore tentés) et
    /// `extracted` n'ont rien à y faire : la fenêtre dirait « Fouine n'a pas pu
    /// lire » d'un fichier qu'elle n'a même pas encore ouvert.
    /// Les extensions du menu « Type » de la fenêtre « Tous vos documents »
    /// (lot BR1, constat PR-06) : celles que l'index CONTIENT, la plus fréquente
    /// d'abord, et jamais une extension vide (les documents sans extension
    /// existent — un `Makefile`, une note exportée sans suffixe).
    func testDocumentExtensionsComeByFrequency() throws {
        let db = try makeDB()
        for name in ["a.pdf", "b.pdf", "c.pdf"] {
            try addDoc(db, relPath: "Users/alice/Livres/\(name)")
        }
        try addDoc(db, relPath: "Users/alice/Livres/notes.txt", ext: "txt")
        try addDoc(db, relPath: "Users/alice/Livres/roman.epub", ext: "epub")
        try addDoc(db, relPath: "Users/alice/Livres/LISEZMOI", ext: "")

        XCTAssertEqual(try db.store.documentExtensions(), ["pdf", "epub", "txt"],
                       "pdf d'abord (3 documents), puis les deux ex æquo dans "
                       + "l'ordre alphabétique ; jamais l'extension vide")
        XCTAssertEqual(try db.store.documentExtensions(limit: 1), ["pdf"])
    }

    func testUnreadableDocumentsListsFailedAndSkippedByFolder() throws {
        let db = try makeDB()
        let ok = try addDoc(db, relPath: "Users/alice/Livres/bon.pdf")
        try db.store.setDocState(ok, .extracted, err: nil)
        _ = try addDoc(db, relPath: "Users/alice/Livres/attente.pdf")   // discovered
        let failed = try addDoc(db, relPath: "Users/alice/Livres/casse.pdf")
        try db.store.setDocState(failed, .failed, err: "extraction: boom")
        let skipped = try addDoc(db, relPath: "Users/alice/Cours/vieux.ppt",
                                 ext: "ppt", folder: "Cours")
        try db.store.setDocState(skipped, .skipped,
                                 err: "unsupported binary OLE format")

        let rows = try db.store.unreadableDocuments(limit: 100)
        XCTAssertEqual(rows.map(\.id), [skipped, failed],
                       "ordre : dossier (Cours < Livres) puis chemin")
        XCTAssertEqual(rows[0].topFolder, "Cours")
        XCTAssertEqual(rows[0].ext, "ppt")
        XCTAssertEqual(rows[0].state, .skipped)
        XCTAssertEqual(rows[0].err, "unsupported binary OLE format")
        XCTAssertEqual(rows[0].volUUID, "TEST-VOL")
        XCTAssertEqual(rows[0].mtime, 1_700_000_000)
        XCTAssertEqual(rows[1].state, .failed)
        XCTAssertEqual(rows[1].relPath, "Users/alice/Livres/casse.pdf")
    }

    /// Deux documents du MÊME dossier restent triés par chemin, et la limite
    /// coupe la liste sans changer cet ordre.
    func testUnreadableDocumentsOrdersByPathAndHonoursLimit() throws {
        let db = try makeDB()
        for name in ["c.pdf", "a.pdf", "b.pdf"] {
            let id = try addDoc(db, relPath: "Users/alice/Livres/\(name)")
            try db.store.setDocState(id, .failed, err: "extraction: \(name)")
        }
        let all = try db.store.unreadableDocuments(limit: 100)
        XCTAssertEqual(all.map(\.relPath), [
            "Users/alice/Livres/a.pdf",
            "Users/alice/Livres/b.pdf",
            "Users/alice/Livres/c.pdf",
        ])
        XCTAssertEqual(try db.store.unreadableDocuments(limit: 2).map(\.relPath),
                       ["Users/alice/Livres/a.pdf", "Users/alice/Livres/b.pdf"])
        // Une limite absurde ne lève pas et ne rend rien : le `max(0, limit)`
        // protège le `LIMIT ?`, qui accepterait −1 comme « pas de limite ».
        XCTAssertEqual(try db.store.unreadableDocuments(limit: -1).count, 0)
    }

    /// Un index sans aucun échec rend une liste VIDE, pas une erreur : c'est le
    /// cas normal, et la fenêtre ne s'ouvre alors jamais.
    func testUnreadableDocumentsEmptyWhenEverythingWasRead() throws {
        let db = try makeDB()
        let id = try addDoc(db, relPath: "Users/alice/Livres/bon.pdf")
        try db.store.setDocState(id, .extracted, err: nil)
        XCTAssertEqual(try db.store.unreadableDocuments(limit: 100).count, 0)
    }

    func testStatsExposesEverySection43Key() throws {
        let db = try makeDB()
        let native = try addDoc(db, relPath: "Users/alice/Livres/n.pdf")
        let scanned = try addDoc(db, relPath: "Users/alice/Cours/s.pdf", folder: "Cours")
        try db.store.replacePages(docID: native, pages: [
            page(1, "texte natif propre"), page(2, "seconde page native"),
        ])
        try db.store.setDocState(native, .extracted, err: nil)
        try db.store.enqueueOCR(docID: scanned, pages: [1, 2], priority: 0)
        try db.store.completeOCR(docID: scanned, page: 1,
                                 result: ocrPage("une page reconnue par Vision",
                                                 confidence: 0.12))
        let failing = try addDoc(db, relPath: "Users/alice/Livres/f.pdf")
        try db.store.setDocState(failing, .failed, err: "PDFDocument nil")
        let skipped = try addDoc(db, relPath: "Users/alice/Livres/g.ppt", ext: "ppt")
        try db.store.setDocState(skipped, .skipped, err: "format binaire OLE")

        let s = try db.store.stats()
        for key in ["docs_total", "docs_extracted", "docs_failed", "docs_skipped",
                    "pages_indexed", "pages_native", "pages_ocr_accurate",
                    "pages_ocr_low_conf", "pages_ocr_no_lines",
                    "ocr_queue_len", "db_bytes"] {
            XCTAssertNotNil(s[key], "clé \(key) absente de status --json")
        }
        XCTAssertNil(s["pages_ocr_fast"], "la reconnaissance « rapide » n'existe plus (RC2)")
        XCTAssertEqual(s["docs_total"], 4)
        XCTAssertEqual(s["docs_extracted"], 1)
        XCTAssertEqual(s["docs_failed"], 1)
        XCTAssertEqual(s["docs_skipped"], 1)
        XCTAssertEqual(s["pages_indexed"], 3)
        XCTAssertEqual(s["pages_native"], 2)
        XCTAssertEqual(s["pages_ocr_accurate"], 1)
        // conf = 0,12 : du texte reconnu, mais douteux. Distinct d'une page sans
        // aucune ligne reconnue, que la sentinelle conf = 0 marque (audit A6).
        XCTAssertEqual(s["pages_ocr_low_conf"], 1)
        XCTAssertEqual(s["pages_ocr_no_lines"], 0)
        XCTAssertEqual(s["ocr_queue_len"], 1)
        XCTAssertGreaterThan(s["db_bytes"] ?? 0, 0)
    }

    func testTopVocabularyRespectsMinLengthAndFrequency() throws {
        let db = try makeDB()
        let docID = try addDoc(db, relPath: "Users/alice/Livres/v.pdf")
        try db.store.replacePages(docID: docID, pages: [
            page(1, "enthalpie enthalpie enthalpie gaz gaz polymere"),
            page(2, "enthalpie polymere gaz"),
        ])
        let top = try db.store.topVocabulary(limit: 5, minLength: 6)
        XCTAssertEqual(top.first, "enthalpie")
        XCTAssertFalse(top.contains("gaz"), "les termes de moins de 6 lettres sont exclus")
    }

    func testOptimizeIsSafeOnEmptyIndex() throws {
        let db = try makeDB()
        XCTAssertNoThrow(try db.store.optimize())
    }

    // MARK: - Verrou d'écriture (§5.1)

    /// `flock` verrouille la DESCRIPTION de fichier ouverte, pas le processus :
    /// deux `ExclusiveLock` sur le même chemin se disputent bien le verrou, même
    /// ici. `release()` doit le rendre, et être idempotent.
    func testExclusiveLockIsReleasableAndIdempotent() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("fouine-verrou-\(UUID().uuidString)",
                                    isDirectory: true)
        try FileManager.default.createDirectory(at: directory,
                                                withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let path = FouinePaths.lockURL(
            for: directory.appendingPathComponent("fouine.db")).path

        let mine = ExclusiveLock(path: path)
        let rival = ExclusiveLock(path: path)
        try mine.acquire(timeout: 1)
        XCTAssertThrowsError(try rival.acquire(timeout: 0.2),
                             "le verrou est tenu : le concurrent doit échouer")

        mine.release()
        mine.release()               // sans verrou détenu : no-op
        XCTAssertNoThrow(try rival.acquire(timeout: 1))

        // Repris paresseusement : rendre puis reprendre est possible des deux côtés.
        rival.release()
        XCTAssertNoThrow(try mine.acquire(timeout: 1))
        mine.release()
    }

    /// Le point de repos de l'agent : rendre `fouine.lock` sans fermer la base,
    /// et le reprendre paresseusement à l'écriture suivante. Sans cela l'agent le
    /// confisque à vie et ni la CLI ni l'app ne peuvent plus indexer.
    func testStoreReleasesTheWriteLockAndTakesItBackLazily() throws {
        let db = try makeDB()
        let path = FouinePaths.lockURL(
            for: db.directory.appendingPathComponent("fouine.db")).path
        try addDoc(db, relPath: "Users/alice/Livres/verrou.pdf")   // 1re écriture

        let rival = ExclusiveLock(path: path)
        XCTAssertThrowsError(try rival.acquire(timeout: 0.2),
                             "le store tient le verrou depuis sa première écriture")

        db.store.releaseWriteLock()
        db.store.releaseWriteLock()  // idempotent
        XCTAssertNoThrow(try rival.acquire(timeout: 1))
        rival.release()

        try addDoc(db, relPath: "Users/alice/Livres/verrou2.pdf")
        XCTAssertThrowsError(try rival.acquire(timeout: 0.2),
                             "le verrou est repris paresseusement au write suivant")
        XCTAssertEqual(try db.store.rawInt64s("SELECT count(*) FROM docs"), [2])
    }
}
