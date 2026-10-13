// SeedTests.swift — tests des parcours semés OCR et sémantique (SPEC §5.6, audit C2-11).
// Propriété : A-Recette.

import Foundation
import XCTest
import PDFKit
import FouineCore
import FouineOCR
@testable import FouineApp

final class SeedTests: XCTestCase {

    private var scratch: URL!
    private var dbURL: URL { scratch.appendingPathComponent("seed-test.db") }

    override func setUpWithError() throws {
        scratch = FileManager.default.temporaryDirectory
            .appendingPathComponent("fouine-seed-tests-\(UUID().uuidString)",
                                    isDirectory: true)
        try FileManager.default.createDirectory(at: scratch,
                                                withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        if let scratch { try? FileManager.default.removeItem(at: scratch) }
    }

    // MARK: - 1. Aller-retour ocr_layout et recherche FTS5

    func testSeededOCRLayoutRoundTripAndSearch() throws {
        let store = GRDBStore()
        try store.open(at: dbURL)
        try store.registerVolume(uuid: "SEED-VOL", label: "seed")

        let record = DocRecord(
            volUUID: "SEED-VOL", relPath: "scan.pdf",
            ext: "pdf", topFolder: "Livres",
            size: 1_000, mtime: 0, nPages: 1,
            state: .extracted, ocrState: .queued,
            lang: nil, err: nil
        )
        let docID = try store.upsertDoc(record)
        try store.enqueueOCR(docID: docID, pages: [1], priority: 1)

        let lines = [
            OCRLine(text: "Cinétique de réticulation du polymère",
                    x: 0.10, y: 0.72, w: 0.62, h: 0.04, confidence: 0.93),
            OCRLine(text: "figure sans rapport",
                    x: 0.10, y: 0.30, w: 0.40, h: 0.04, confidence: 0.88),
        ]
        let page = OCRPage(
            text: lines.map(\.text).joined(separator: "\n"),
            lines: lines, level: .accurate, seconds: 1.0,
            engine: .vision, engineRev: "vision-rev3",
            meanConfidence: 0.9
        )
        try store.completeOCR(docID: docID, page: 1, result: page)

        // 1 · Aller-retour ocr_layout (zlib-JSON)
        let loaded = try store.ocrLayout(docID: docID, page: 1)
        XCTAssertNotNil(loaded)
        XCTAssertEqual(loaded?.count, lines.count)
        XCTAssertEqual(loaded?.first?.text, "Cinétique de réticulation du polymère")
        XCTAssertEqual(loaded?.first?.confidence, 0.93)

        // 2 · Recherche FTS5 retrouve la page en source .ocrAccurate
        let results = try store.search(QueryParser.searchQuery("reticulation"))
        let hit = results.hits.first
        XCTAssertNotNil(hit)
        XCTAssertEqual(hit?.source, .ocrAccurate)
        XCTAssertEqual(hit?.page, 1)
    }

    // MARK: - 2. Dénormalisation des boîtes aux 4 rotations

    func testSeededOCRDenormalizationAtAllFourRotations() {
        let line = OCRLine(
            text: "Cinétique de réticulation du polymère",
            x: 0.10, y: 0.72, w: 0.62, h: 0.04, confidence: 0.93
        )
        let mediaBox = CGRect(x: 0, y: 0, width: 595, height: 842)

        for rotation in [0, 90, 180, 270] {
            let rect = OCRGeometry.denormalize(line, mediaBox: mediaBox, rotation: rotation)
            let displayW = (rotation % 180 == 0) ? mediaBox.width : mediaBox.height
            let displayH = (rotation % 180 == 0) ? mediaBox.height : mediaBox.width
            let expectedArea = line.w * displayW * (line.h * displayH)

            XCTAssertTrue(mediaBox.insetBy(dx: -0.5, dy: -0.5).contains(rect),
                          "Rect \(rect) outside mediaBox for rotation \(rotation)°")
            XCTAssertLessThan(abs(rect.width * rect.height - expectedArea), 1.0,
                              "Area mismatch for rotation \(rotation)°")
        }
    }

    // MARK: - 3. Annotation mémoire sur PDFPage

    func testSeededOCRAnnotationInMemory() {
        let line = OCRLine(
            text: "Cinétique de réticulation du polymère",
            x: 0.10, y: 0.72, w: 0.62, h: 0.04, confidence: 0.93
        )
        let pdfPage = PDFPage()
        let bounds = OCRGeometry.denormalize(line, mediaBox: pdfPage.bounds(for: .mediaBox), rotation: 0)
        let annotation = PDFAnnotation(bounds: bounds, forType: .highlight, withProperties: nil)

        pdfPage.addAnnotation(annotation)
        XCTAssertEqual(pdfPage.annotations.count, 1)

        pdfPage.removeAnnotation(annotation)
        XCTAssertTrue(pdfPage.annotations.isEmpty)
    }
}
