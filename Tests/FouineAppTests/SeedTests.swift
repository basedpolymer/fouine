// SeedTests.swift — tests des parcours semés OCR et sémantique (SPEC §5.6, audit C2-11).
// Propriété : A-Recette.

import Foundation
import XCTest
import PDFKit
import FouineCore
import FouineOCR
import FouineEmbed
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

    // MARK: - 4. Nettoyage de requête sémantique

    func testSeededSemanticQueryFilterStripping() {
        let raw = SearchModel.semanticText(
            of: "dossier:Livres ext:pdf pres:5 chat -chien \"au chaud\""
        )
        XCTAssertEqual(raw, "chat au chaud")
    }

    // MARK: - 5. Disponibilité et fusion RRF (vecteurs synthétiques, modèle réel pour la requête)

    /// Les VECTEURS sont synthétiques, mais la requête doit être encodée : le
    /// test exige le modèle installé, comme le suivant. Sans lui,
    /// `availability()` rend `.modelMissing` et `search` jette `.model` — ce
    /// test échouait au lieu de se sauter là où le modèle manque (lot I2).
    func testSeededSemanticAvailabilityAndRRFFusion() async throws {
        guard let encoder = try SharedModel.encoder() else {
            throw XCTSkip("modèle e5-small absent — `fouine model download` "
                          + "l'installe (220 Mo)")
        }
        let store = GRDBStore()
        try store.open(at: dbURL)
        try store.registerVolume(uuid: "SEED-VOL", label: "seed")

        let docID = try store.upsertDoc(DocRecord(
            volUUID: "SEED-VOL", relPath: "corpus.pdf", ext: "pdf",
            topFolder: "Livres", size: 1_000, mtime: 1_700_000_000
        ))

        let pages = [
            PageText(page: 1, text: "Le chat dort sur le canapé du salon.", source: .native),
            PageText(page: 2, text: "Un félin domestique se repose tranquillement dans le séjour de la maison.", source: .native),
            PageText(page: 3, text: "Thermodynamique des gaz parfaits et enthalpie de réaction en phase condensée.", source: .native),
        ]
        try store.replacePages(docID: docID, pages: pages)

        // Générer 3 vecteurs unitaires de dimension 384
        let dim = 384
        var v1 = [Float](repeating: 0, count: dim)
        var v2 = [Float](repeating: 0, count: dim)
        var v3 = [Float](repeating: 0, count: dim)
        v1[0] = 1.0  // aligné avec la requête
        v2[0] = 0.8; v2[1] = 0.6  // proche (cos 0.8)
        v3[2] = 1.0  // orthogonal (cos 0.0)

        try store.setVecMeta(modelID: "mock-e5", dim: dim, revision: 1)
        try store.upsertVectors([
            (rowid: Schema.vecRowID(pageRowID: Schema.ftsRowID(docID: docID, page: 1), chunk: 0),
             vec: VecQuantizer.quantize(v1)),
            (rowid: Schema.vecRowID(pageRowID: Schema.ftsRowID(docID: docID, page: 2), chunk: 0),
             vec: VecQuantizer.quantize(v2)),
            (rowid: Schema.vecRowID(pageRowID: Schema.ftsRowID(docID: docID, page: 3), chunk: 0),
             vec: VecQuantizer.quantize(v3)),
        ])

        let service = SemanticService(store: store, encoder: encoder)
        let availability = await service.availability()
        XCTAssertEqual(availability, .ready(vectors: 3))
        XCTAssertFalse(service.isLoaded)

        // Requête lexicale "chat" : p.1 matche lexicalement, p.2 ne matche pas lexicalement
        let plan = try QueryParser.searchPlan("chat", limit: 50)
        let results = try await service.search(
            query: plan.query,
            excludingDocsMatching: plan.negative,
            rawQuery: "chat", typedQuery: "chat",
            limit: 20
        )

        XCTAssertTrue(service.isLoaded)
        // La page 1 a un hit lexical avec snippet
        XCTAssertTrue(results.hits.contains { $0.page == 1 && $0.lexical != nil })
        // Ordre RRF décroissant
        XCTAssertTrue(zip(results.hits, results.hits.dropFirst()).allSatisfy { $0.rrf >= $1.rrf })
    }

    // MARK: - 6. Modèle réel si présent sur la machine

    func testSeededSemanticWithRealModelIfAvailable() async throws {
        guard let encoder = try SharedModel.encoder() else {
            throw XCTSkip("modèle e5-small absent — `fouine model download` "
                          + "l'installe (220 Mo)")
        }

        let store = GRDBStore()
        try store.open(at: dbURL)
        try store.registerVolume(uuid: "SEED-VOL", label: "seed")

        let docID = try store.upsertDoc(DocRecord(
            volUUID: "SEED-VOL", relPath: "corpus.pdf", ext: "pdf",
            topFolder: "Livres", size: 1_000, mtime: 1_700_000_000
        ))

        let pages = [
            PageText(page: 1, text: "Le chat dort sur le canapé du salon.", source: .native),
            PageText(page: 2, text: "Un félin domestique se repose tranquillement dans le séjour de la maison.", source: .native),
            PageText(page: 3, text: "Thermodynamique des gaz parfaits et enthalpie de réaction en phase condensée.", source: .native),
        ]
        try store.replacePages(docID: docID, pages: pages)

        try store.setVecMeta(modelID: encoder.modelID, dim: encoder.dimension, revision: encoder.revision)
        let vectors = try encoder.embedPassages(pages.map(\.text))
        try store.upsertVectors(zip(pages, vectors).map { page, vector in
            (rowid: Schema.vecRowID(pageRowID: Schema.ftsRowID(docID: docID, page: page.page), chunk: 0),
             vec: VecQuantizer.quantize(vector))
        })

        let service = SemanticService(store: store, encoder: encoder)
        let availability = await service.availability()
        XCTAssertEqual(availability, .ready(vectors: pages.count))

        let plan = try QueryParser.searchPlan("chat", limit: 50)
        let results = try await service.search(
            query: plan.query, excludingDocsMatching: plan.negative,
            rawQuery: "chat", typedQuery: "chat", limit: 20
        )

        let semanticOnly = results.hits.filter { $0.lexical == nil }
        XCTAssertTrue(semanticOnly.contains { $0.page == 2 })
    }
}
