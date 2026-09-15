// OCRPassLanguageBackfillTests.swift — rattrapage de langue en fin de passe OCR (PERSP-5).
// Propriété : A-Core.

import XCTest
import FouineCore
import FouineOCR
@testable import FouineIndex

final class OCRPassLanguageBackfillTests: XCTestCase {

    final class LogBox: @unchecked Sendable {
        private let lock = NSLock()
        private var entries: [String] = []

        func append(_ entry: String) {
            lock.lock()
            defer { lock.unlock() }
            entries.append(entry)
        }

        func contains(_ predicate: (String) -> Bool) -> Bool {
            lock.lock()
            defer { lock.unlock() }
            return entries.contains(where: predicate)
        }
    }

    private func ocrResult(_ text: String, confidence: Double = 0.95) -> OCRPage {
        let lines = [OCRLine(text: text, x: 0.1, y: 0.8, w: 0.6, h: 0.02, confidence: confidence)]
        return OCRPage(text: text, lines: lines, level: .accurate, seconds: 0.1,
                       engine: .vision, engineRev: "vision-rev3", meanConfidence: confidence)
    }

    private func scratchWithDocument(_ name: String) throws -> (IndexScratch, DocRow) {
        let scratch = try IndexScratch(name, documents: 1)
        try IndexPass(store: scratch.store)
            .run(roots: [scratch.rootRecord],
                 options: IndexPassOptions(crawl: .full, warmVocabulary: false))
        let doc = try XCTUnwrap(scratch.documents().first)
        return (scratch, doc)
    }

    /// Un document « und » dont une page a été complétée par l'OCR voit sa
    /// langue rattrapée en fin de passe OCRPass.run.
    func testOCRPassRattrapeLangueEnFinDePasse() throws {
        let (scratch, doc) = try scratchWithDocument("ocr-pass-backfill")

        // Simule un document scanné : pas de texte natif, langue posée à « und »
        try scratch.store.setDocLanguage(doc.id, FacetKey.undeterminedLanguage)
        XCTAssertEqual(try scratch.store.documentsWithoutLanguageCount(), 0)

        // L'OCR écrit le texte de la page 1 : completeOCR remet lang à NULL
        let text = String(repeating: "Le soleil se lève sur la plaine et la journée commence. ", count: 5)
        try scratch.store.completeOCR(docID: doc.id, page: 1, result: ocrResult(text))

        XCTAssertNil(try scratch.store.docRow(id: doc.id)?.record.lang)
        XCTAssertEqual(try scratch.store.documentsWithoutLanguageCount(), 1)

        // Passe OCR : la file est vide, mais le rattrapage de fin de passe s'exécute
        let logged = LogBox()
        let outcome = try OCRPass.run(store: scratch.store, role: .app,
                                      budgetMinutes: nil,
                                      log: { logged.append($0) })

        XCTAssertEqual(outcome, .completed)
        XCTAssertEqual(try scratch.store.docRow(id: doc.id)?.record.lang, "fr")
        XCTAssertEqual(try scratch.store.documentsWithoutLanguageCount(), 0)
        XCTAssertTrue(logged.contains { $0.contains("language detected for 1 document(s), 0 left") })
    }

    /// Si shouldStop retourne true, le rattrapage de fin de passe OCR est ignoré.
    func testOCRPassNeRattrapePasSiShouldStop() throws {
        let (scratch, doc) = try scratchWithDocument("ocr-pass-stop")

        try scratch.store.setDocLanguage(doc.id, FacetKey.undeterminedLanguage)
        let text = String(repeating: "Le soleil se lève sur la plaine et la journée commence. ", count: 5)
        try scratch.store.completeOCR(docID: doc.id, page: 1, result: ocrResult(text))
        XCTAssertNil(try scratch.store.docRow(id: doc.id)?.record.lang)

        _ = try OCRPass.run(store: scratch.store, role: .app,
                            budgetMinutes: nil,
                            shouldStop: { true })

        XCTAssertNil(try scratch.store.docRow(id: doc.id)?.record.lang,
                     "le rattrapage ne doit pas tourner quand l'arrêt est demandé")
        XCTAssertEqual(try scratch.store.documentsWithoutLanguageCount(), 1)
    }

    /// Si languageBackfillLimit vaut 0, le rattrapage de fin de passe est désactivé.
    func testOCRPassNeRattrapePasSiLimiteZero() throws {
        let (scratch, doc) = try scratchWithDocument("ocr-pass-limit0")

        try scratch.store.setDocLanguage(doc.id, FacetKey.undeterminedLanguage)
        let text = String(repeating: "Le soleil se lève sur la plaine et la journée commence. ", count: 5)
        try scratch.store.completeOCR(docID: doc.id, page: 1, result: ocrResult(text))

        _ = try OCRPass.run(store: scratch.store, role: .app,
                            budgetMinutes: nil,
                            languageBackfillLimit: 0)

        XCTAssertNil(try scratch.store.docRow(id: doc.id)?.record.lang)
        XCTAssertEqual(try scratch.store.documentsWithoutLanguageCount(), 1)
    }

    /// Un document OCR dont le texte reste indéterminable redevient « und »
    /// et n'est plus relu.
    func testOCRPassTexteIndeterminableDevientUndEtNeBouclePas() throws {
        let (scratch, doc) = try scratchWithDocument("ocr-pass-und")

        try scratch.store.setDocLanguage(doc.id, FacetKey.undeterminedLanguage)
        // Bruit sans langue identifiable par NLLanguageRecognizer
        let noise = String(repeating: "12345 67890 !@#$% ", count: 6)
        try scratch.store.completeOCR(docID: doc.id, page: 1, result: ocrResult(noise))

        _ = try OCRPass.run(store: scratch.store, role: .app, budgetMinutes: nil)

        XCTAssertEqual(try scratch.store.docRow(id: doc.id)?.record.lang,
                       FacetKey.undeterminedLanguage)
        XCTAssertEqual(try scratch.store.documentsWithoutLanguageCount(), 0)

        // Seconde passe OCR : n'est pas relu
        let logged = LogBox()
        _ = try OCRPass.run(store: scratch.store, role: .app,
                            budgetMinutes: nil,
                            log: { logged.append($0) })
        XCTAssertFalse(logged.contains { $0.contains("language detected") })
    }
}
