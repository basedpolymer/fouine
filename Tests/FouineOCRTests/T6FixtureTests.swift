// T6FixtureTests.swift — LE test décisif du projet (SPEC §8.1, T6).
// Propriété : A-OCR.
//
// « Une page manuscrite scannée, illisible en lecture, parfaitement cherchable. »
// La fixture est un CamScanner réel du corpus local (désigné par paths.json ou
// FOUINE_T6_FIXTURES, jamais écrit en dur), ouvert en LECTURE SEULE
// STRICTE ; le test se saute proprement sur une machine qui ne l'a pas.
//
// Ce que le test vérifie, dans l'ordre :
//   1. la page se rend (droite au sens du mediaBox, en gris, sous 4 Mpx) ;
//   2. `.accurate` y lit « RCPA », plus les témoins secondaires du §8.1 ;
//   3. la page devient cherchable par la pompe complète, en `ocr_accurate`.
//
// Constat mesuré le 2026-08-31, à consigner : la page 1 de cette fixture a
// `PDFPage.rotation == 0` et un mediaBox A4 DEBOUT. Le « 90° » du piège n°8 est
// dans le CONTENU photographié, pas dans la page : aucun rendu ne peut le
// redresser à partir du PDF. C'est `.accurate` qui s'en charge — et qui y arrive.

import XCTest
import CoreGraphics
import FouineCore
@testable import FouineOCR

final class T6FixtureTests: XCTestCase {

    /// Témoins de la transcription de référence du §8.1.
    private static let secondaryTerms = ["taux", "conversion", "volume", "passage"]

    // MARK: - Rendu

    func testT6PageOneRendersUprightInGray() throws {
        let url = try requireT6()
        let image = try FouinePageRenderer().render(url: url, page: 1, dpi: 150)

        // mediaBox A4 debout -> 1240 × 1754 à 150 dpi, comme le cas nominal du §6.3.
        XCTAssertGreaterThan(image.height, image.width,
                             "la page doit sortir DEBOUT (A4 portrait)")
        XCTAssertEqual(image.width, 1240)
        XCTAssertEqual(image.height, 1754)
        XCTAssertEqual(image.colorSpace?.model, .monochrome)
        XCTAssertEqual(image.bitsPerComponent, 8)
        XCTAssertLessThanOrEqual(Double(image.width) * Double(image.height),
                                 GrayRaster.maxPixels)
    }

    // MARK: - Reconnaissance

    func testT6PageOneIsRecognized() throws {
        let url = try requireT6()
        let engine = VisionOCREngine()
        try engine.prewarm()

        let image = try FouinePageRenderer().render(url: url, page: 1, dpi: 150)
        let page = try engine.recognize(image, level: .accurate,
                                        languages: VisionOCREngine.defaultLanguages,
                                        customWords: [])
        let text = page.text.lowercased()

        // MÉTRIQUES SEULEMENT (audit B1-29 a). La transcription est celle d'une
        // copie manuscrite personnelle : l'imprimer la ferait partir dans les
        // journaux de l'intégration continue. Pour la relire à la main pendant
        // une mise au point, poser FOUINE_T6_DUMP=1 — jamais en CI.
        print("--- T6 page 1 : \(page.lines.count) lignes, \(page.text.count) "
              + "caractères, \(String(format: "%.2f", page.seconds)) s, "
              + "conf. moyenne \(String(format: "%.3f", page.meanConfidence))")
        if ProcessInfo.processInfo.environment["FOUINE_T6_DUMP"] == "1" {
            print(page.text)
        }

        XCTAssertTrue(text.contains("rcpa"),
                      "« RCPA » attendu ; \(page.lines.count) lignes et "
                      + "\(page.text.count) caractères reconnus, conf. moyenne "
                      + String(format: "%.3f", page.meanConfidence))
        for term in Self.secondaryTerms {
            XCTAssertTrue(text.contains(term),
                          "témoin « \(term) » absent ; \(page.lines.count) lignes "
                          + "et \(page.text.count) caractères reconnus")
        }
        // Le §2.8 mesure 584 caractères sur cette page : on reste large.
        XCTAssertGreaterThan(page.text.count, 300)
        XCTAssertGreaterThan(page.meanConfidence, 0.5)
    }

    // MARK: - Chaîne complète

    /// `fouine ocr --only <T6>` puis `fouine search 'RCPA'` (§8.1 T6), mais sur une
    /// base temporaire à nous : la page 1 seulement, pour ne pas monopoliser la
    /// machine (les 4 pages coûteraient ~12 s de plus).
    func testT6BecomesSearchableThroughThePump() throws {
        let url = try requireT6()
        let temp = try TempStore()
        let store = temp.store

        let resolved = try VolumeResolver.resolve(path: url)
        try store.registerVolume(uuid: resolved.volUUID, label: resolved.volLabel)
        let attributes = try FileManager.default.attributesOfItem(atPath: url.path)
        let docID = try store.upsertDoc(DocRecord(
            volUUID: resolved.volUUID, relPath: resolved.relPath, ext: "pdf",
            topFolder: "Cours",
            size: (attributes[.size] as? NSNumber)?.int64Value ?? 0,
            mtime: (attributes[.modificationDate] as? Date)?
                .timeIntervalSince1970 ?? 0,
            nPages: 4, state: .extracted))
        try store.enqueueOCR(docID: docID, pages: [1], priority: 0)

        let started = Date()
        let outcome = try OCRRun.run(store: store, jobs: 1, budgetSeconds: nil,
                                     prioFolder: nil, only: url.path,
                                     log: { print("[ocr] \($0)") })
        let elapsed = Date().timeIntervalSince(started)
        XCTAssertEqual(outcome, .completed)
        print("--- T6 pompe complète : \(String(format: "%.2f", elapsed)) s "
              + "(préchauffage compris)")

        XCTAssertEqual(try store.stats()["ocr_queue_len"], 0)
        XCTAssertEqual(try store.stats()["pages_ocr_accurate"], 1)

        // Le test du §8.1 lui-même : la page est cherchable.
        let hits = try store.search(SearchQuery(fts: "rcpa", fuzzy: .off))
        XCTAssertEqual(hits.hits.count, 1, "« RCPA » introuvable après OCR")
        XCTAssertEqual(hits.hits.first?.docID, docID)
        XCTAssertEqual(hits.hits.first?.page, 1)
        XCTAssertEqual(hits.hits.first?.source, .ocrAccurate)

        for term in Self.secondaryTerms {
            let secondary = try store.search(SearchQuery(fts: term, fuzzy: .off))
            XCTAssertEqual(secondary.hits.first?.page, 1,
                           "témoin « \(term) » non cherchable")
        }

        // Le surlignage doit être disponible, boîtes normalisées comprises.
        let layout = try store.ocrLayout(docID: docID, page: 1)
        XCTAssertNotNil(layout)
        XCTAssertFalse(layout?.isEmpty ?? true)
        for line in layout ?? [] {
            XCTAssertTrue((0...1).contains(line.x))
            XCTAssertTrue((0...1).contains(line.y))
        }
    }
}
