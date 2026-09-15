// OCRDeadlineTests.swift — délai de garde sur Vision et sur le rendu (audit F6).
// Propriété : A-OCR (palier 3, 02/09/2026).
//
// Ce qui compte, et que ces tests tiennent :
//   · un dépassement Vision devient `FouineError.ocr` en disant « délai dépassé »
//     — un message qui atterrit dans le journal du run et permet de reconnaître
//     un blocage d'une page simplement illisible ;
//   · la page N'EST PAS PERDUE : elle repart en file avec `attempts + 1`, et
//     n'est abandonnée qu'à la troisième tentative, comme n'importe quel autre
//     échec de page (§6.3, piège n°13).

import XCTest
import CoreGraphics
import FouineCore
import FouineExtract
@testable import FouineOCR

final class OCRDeadlineTests: XCTestCase {

    // MARK: - Vision

    /// Échéance minuscule injectée par l'environnement : Vision met au minimum
    /// des dizaines de millisecondes (et 8,5 s au tout premier appel, le temps
    /// de charger son modèle), 1 ms ne peut donc pas suffire.
    func testVisionOverrunBecomesAnOCRErrorThatSaysSo() {
        setenv("FOUINE_OCR_TIMEOUT", "0.001", 1)
        defer { unsetenv("FOUINE_OCR_TIMEOUT") }

        let image = VisionOCREngine.prewarmImage()
        XCTAssertThrowsError(
            try VisionOCREngine().recognize(image, level: .accurate,
                                            languages: VisionOCREngine.defaultLanguages,
                                            customWords: [])) { error in
            guard case FouineError.ocr(let message)? = error as? FouineError else {
                return XCTFail("attendu .ocr, obtenu \(error)")
            }
            XCTAssertTrue(message.contains("deadline exceeded"), message)
            XCTAssertTrue(message.contains("Vision"), message)
        }
    }

    /// Le garde-fou ne doit pas se déclencher sur une page ordinaire : avec le
    /// budget par défaut, la même image passe.
    func testTheDefaultBudgetDoesNotFireOnAnOrdinaryImage() throws {
        let page = try VisionOCREngine().recognize(
            VisionOCREngine.prewarmImage(), level: .accurate,
            languages: VisionOCREngine.defaultLanguages, customWords: [])
        XCTAssertEqual(page.engineRev, "vision-rev3")
    }

    // MARK: - La page repart en file

    /// Un moteur qui ne fait que dépasser son délai, comme le ferait Vision
    /// bloqué sur une image pathologique.
    private struct TimingOutEngine: OCREngine {
        let id: OCREngineID = .vision
        let revision = "vision-rev3"
        func prewarm() throws {}
        func recognize(_ image: CGImage, level: OCRLevel, languages: [String],
                       customWords: [String]) throws -> OCRPage {
            throw FouineError.ocr(
                "Vision — délai dépassé (120 s) : reconnaissance Vision d'une page")
        }
    }

    /// Un rendu qui réussit : ce qui est testé ici est le comportement de la
    /// pompe FACE à un moteur qui dépasse, pas le rendu.
    private struct BlankRenderer: PageRenderer {
        func render(url: URL, page: Int, dpi: Double) throws -> CGImage {
            VisionOCREngine.prewarmImage()
        }
    }

    /// Trois tentatives, puis l'abandon — jamais une page qui disparaît sans
    /// laisser de trace au premier dépassement.
    func testATimedOutPageIsRequeuedWithOneMoreAttempt() throws {
        let temp = try TempStore()
        let store = temp.store
        let directory = try TempDirectory()
        let pdf = directory.file("page.pdf")
        try OCRTestSupport.writePDF(
            [OCRTestSupport.PageSpec(width: 595, height: 842, draw: { _ in })],
            to: pdf)

        let resolved = try VolumeResolver.resolve(path: pdf)
        try store.registerVolume(uuid: resolved.volUUID, label: resolved.volLabel)
        let docID = try store.upsertDoc(DocRecord(
            volUUID: resolved.volUUID, relPath: resolved.relPath, ext: "pdf",
            topFolder: "Tests", size: 1_000, mtime: 1_700_000_000,
            nPages: 1, state: .extracted))
        try store.enqueueOCR(docID: docID, pages: [1], priority: 0)
        XCTAssertEqual(try store.stats()["ocr_queue_len"], 1)

        let item = OCRRun.Item(docID: docID, page: 1, path: pdf.path)
        let counters = OCRRun.Counters()
        let harvest = OCRRun.VocabHarvest()

        // Deux dépassements : la page RESTE en file (attempts 1 puis 2).
        for attempt in 1...2 {
            OCRRun.handle(item, store: store, renderer: BlankRenderer(),
                          engine: TimingOutEngine(), languages: [], customWords: [],
                          counters: counters, harvest: harvest, log: { _ in })
            XCTAssertEqual(try store.stats()["ocr_queue_len"], 1,
                           "après \(attempt) dépassement(s), la page doit rester "
                           + "en file")
        }

        // Le troisième abandonne, et le document porte le motif dans `docs.err`.
        OCRRun.handle(item, store: store, renderer: BlankRenderer(),
                      engine: TimingOutEngine(), languages: [], customWords: [],
                      counters: counters, harvest: harvest, log: { _ in })
        XCTAssertEqual(try store.stats()["ocr_queue_len"], 0)
        XCTAssertEqual(counters.snapshot().failed, 3)
    }

    /// Le message du dépassement doit ARRIVER dans le journal du run : c'est lui
    /// qui distingue un blocage d'une page simplement illisible, et c'est la
    /// seule trace qu'un fil a fui (voir l'en-tête de Deadline.swift).
    func testTheOverrunIsLogged() throws {
        let temp = try TempStore()
        let store = temp.store
        let docID = try store.upsertDoc(DocRecord(
            volUUID: "TEST-VOL", relPath: "x/y.pdf", ext: "pdf", topFolder: "Tests",
            size: 10, mtime: 0, nPages: 1, state: .extracted))
        try store.enqueueOCR(docID: docID, pages: [1], priority: 0)

        let lines = LogBox()
        OCRRun.handle(OCRRun.Item(docID: docID, page: 1, path: "/x/y.pdf"),
                      store: store, renderer: BlankRenderer(),
                      engine: TimingOutEngine(), languages: [], customWords: [],
                      counters: OCRRun.Counters(), harvest: OCRRun.VocabHarvest(),
                      log: { lines.add($0) })
        XCTAssertTrue(lines.joined.contains("délai dépassé"), lines.joined)
    }

    private final class LogBox: @unchecked Sendable {
        private let mutex = NSLock()
        private var lines: [String] = []
        func add(_ line: String) { mutex.lock(); lines.append(line); mutex.unlock() }
        var joined: String {
            mutex.lock(); defer { mutex.unlock() }
            return lines.joined(separator: "\n")
        }
    }
}
