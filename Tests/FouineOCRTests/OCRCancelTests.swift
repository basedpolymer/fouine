// OCRCancelTests.swift — le rappel d'arrêt de la pompe (audit A10.2).
//
// L'app affichait un bouton « Annuler » que `OCRRun` ne consultait jamais :
// l'utilisateur restait devant une feuille non refermable pendant des heures.
// `shouldStop:` répare cela, et doit tenir les mêmes garanties que le budget du
// §6.3 : les pages en vol se terminent, aucune transaction n'est coupée, la file
// reste INTACTE et la reprise repart d'où elle s'était arrêtée.
//
// Base temporaire dans son propre dossier — celle de l'utilisateur n'est jamais
// touchée.

import XCTest
import CoreGraphics
import FouineCore
@testable import FouineOCR

final class OCRCancelTests: XCTestCase {

    /// Un PDF de `count` pages, chacune assez fournie pour dépasser le seuil
    /// d'indexation du §6.2, enregistré dans l'index avec ses pages en file.
    @discardableResult
    private func enroll(pages count: Int, in temp: TempStore,
                        directory: TempDirectory) throws -> Int64 {
        let url = directory.file("cancel.pdf")
        try OCRTestSupport.writePDF((1...count).map { index in
            OCRTestSupport.PageSpec(width: 595, height: 500) { context in
                OCRTestSupport.drawText("page numero \(index)", in: context,
                                        at: CGPoint(x: 40, y: 320), size: 44)
                OCRTestSupport.drawText("page de controle Fouine", in: context,
                                        at: CGPoint(x: 40, y: 220), size: 40)
            }
        }, to: url)

        let resolved = try VolumeResolver.resolve(path: url)
        try temp.store.registerVolume(uuid: resolved.volUUID, label: resolved.volLabel)
        let attributes = try FileManager.default.attributesOfItem(atPath: url.path)
        let docID = try temp.store.upsertDoc(DocRecord(
            volUUID: resolved.volUUID, relPath: resolved.relPath, ext: "pdf",
            topFolder: "Tests",
            size: (attributes[.size] as? NSNumber)?.int64Value ?? 0,
            mtime: (attributes[.modificationDate] as? Date)?.timeIntervalSince1970 ?? 0,
            nPages: count, state: .extracted))
        try temp.store.enqueueOCR(docID: docID, pages: Array(1...count), priority: 0)
        return docID
    }

    private func queueLength(_ store: GRDBStore) throws -> Int {
        try store.stats()["ocr_queue_len"] ?? -1
    }

    /// Arrêt demandé AVANT la première page : rien n'est consommé, la file est
    /// entière, et le run le dit (`.budgetExhausted`, même sortie que le budget).
    func testStopBeforeFirstPageLeavesQueueIntact() throws {
        let temp = try TempStore()
        let directory = try TempDirectory()
        let docID = try enroll(pages: 3, in: temp, directory: directory)

        let outcome = try OCRRun.run(store: temp.store, jobs: 1, budgetSeconds: nil,
                                     prioFolder: nil, only: nil, log: { _ in },
                                     shouldStop: { true })

        XCTAssertEqual(outcome, .budgetExhausted)
        XCTAssertEqual(try queueLength(temp.store), 3, "la file doit rester intacte")
        XCTAssertEqual(try temp.store.docRow(id: docID)?.record.ocrState, .queued)
        XCTAssertEqual(try temp.store.stats()["pages_ocr_accurate"], 0)
    }

    /// Arrêt demandé EN COURS de lot : la page commencée se termine et reste
    /// écrite, celles qui n'ont pas été prises restent en file. C'est exactement
    /// la garantie promise à l'utilisateur par la feuille d'indexation.
    func testStopMidBatchKeepsFinishedPagesAndTheRest() throws {
        let temp = try TempStore()
        let directory = try TempDirectory()
        let docID = try enroll(pages: 3, in: temp, directory: directory)

        // Un fil, donc un ordre déterministe : sonde de `drainQueue`, puis une
        // sonde par page prise. On laisse passer les deux premières.
        let calls = Counter()
        let outcome = try OCRRun.run(store: temp.store, jobs: 1, budgetSeconds: nil,
                                     prioFolder: nil, only: nil, log: { _ in },
                                     shouldStop: { calls.next() > 3 })

        XCTAssertEqual(outcome, .budgetExhausted)
        let remaining = try queueLength(temp.store)
        XCTAssertEqual(remaining, 1, "seule la page non distribuée reste en file")
        XCTAssertEqual(try temp.store.stats()["pages_ocr_accurate"], 2,
                       "les pages terminées sont écrites, pas perdues")
        XCTAssertEqual(try temp.store.docRow(id: docID)?.record.ocrState, .partial,
                       "reprise possible : le document est partiellement OCRisé")
    }

    // « Sans rappel, rien ne change » n'a pas de test ici : c'est ce que prouve
    // déjà `OCRRunTests.testRunProcessesQueue` (deux pages, `shouldStop` omis,
    // `.completed`, file vide). Le doublon coûtait 2,4 s d'OCR réel (lot I2).

    private final class Counter: @unchecked Sendable {
        private let mutex = NSLock()
        private var value = 0
        func next() -> Int {
            mutex.lock(); defer { mutex.unlock() }
            value += 1
            return value
        }
    }
}
