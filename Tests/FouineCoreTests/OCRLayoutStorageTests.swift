// OCRLayoutStorageTests.swift — la couche de stockage des dispositions OCR.
// Propriété : A-Core. Suites de l'audit du 01/09/2026 (A4, A6, A2).
//
// Trois sujets, tous vérifiables sans la base de production :
//   · forme d'`ocr_layout` : rowid structuré, écriture et purge par plage ;
//   · arrondi des flottants à l'encodage (le décodeur, lui, ne change pas) ;
//   · alimentation CIBLÉE de vocab_tri depuis le texte fraîchement reconnu.

import Foundation
import XCTest
@testable import FouineCore

final class OCRLayoutStorageTests: XCTestCase {

    // MARK: - Montage

    private var directory: URL!

    override func setUpWithError() throws {
        directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("fouine-layout-\(UUID().uuidString)",
                                    isDirectory: true)
        try FileManager.default.createDirectory(
            at: directory, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: directory)
    }

    private var databaseURL: URL { directory.appendingPathComponent("fouine.db") }

    private func openStore() throws -> GRDBStore {
        let store = GRDBStore()
        try store.open(at: databaseURL)
        return store
    }

    // MARK: - A4 · rowid structuré

    /// Une base naît directement à la forme du rowid structuré (audit A4) :
    /// c'est la SEULE forme qu'`ocr_layout` ait jamais en base, puisqu'une base
    /// d'un autre schéma est refusée au lieu d'être rattrapée.
    func testAFreshDatabaseIsBornWithTheRowIDForm() throws {
        let store = try openStore()
        let columns = try store.rawStrings(
            "SELECT name FROM pragma_table_info('ocr_layout')")
        XCTAssertEqual(columns, ["rowid", "blob"])
        XCTAssertEqual(try store.rawStrings("SELECT v FROM meta WHERE k = 'schema_version'"),
                       [String(Schema.version)])

        // Écriture puis relecture par le chemin normal.
        let docID = try store.upsertDoc(DocRecord(
            volUUID: "TEST-VOL", relPath: "Users/alice/Livres/a.pdf", ext: "pdf",
            topFolder: "Livres", size: 10, mtime: 1))
        let lines = [OCRLine(text: "une ligne de contrôle bien assez longue",
                             x: 0.1, y: 0.7, w: 0.6, h: 0.02, confidence: 0.9)]
        try store.enqueueOCR(docID: docID, pages: [3], priority: 0)
        try store.completeOCR(docID: docID, page: 3, result: OCRPage(
            text: lines[0].text, lines: lines, level: .accurate, seconds: 1,
            engine: .vision, engineRev: "vision-rev3", meanConfidence: 0.9))
        XCTAssertEqual(try store.rawInt64s("SELECT rowid FROM ocr_layout"),
                       [Schema.ftsRowID(docID: docID, page: 3)])
        XCTAssertEqual(try store.ocrLayout(docID: docID, page: 3)?.count, 1)

        // Purge du document : suppression PAR PLAGE de rowid, comme page_fts.
        try store.removeDoc(id: docID)
        XCTAssertEqual(try store.rawInt64s("SELECT count(*) FROM ocr_layout"), [0])
    }

    // MARK: - A4 · arrondi des flottants à l'encodage

    /// L'arrondi est une décision d'ÉCRITURE : le décodeur ne change pas, et un
    /// blob écrit avant l'arrondi reste relisible tel quel. Ce que le test
    /// vérifie : quatre décimales conservées, structure intacte, blob plus court.
    func testEncodingRoundsCoordinatesToFourDecimals() throws {
        // Coordonnées telles que Vision les rend : doubles bruts, 17 chiffres.
        let lines = [
            OCRLine(text: "Élément de chimie physique",
                    x: 0.10416666666666667, y: 0.8235294117647058,
                    w: 0.6234567901234568, h: 0.021333333333333333,
                    confidence: 0.30000001192092896),
            OCRLine(text: "ΔG < 0 à 298,15 K",
                    x: 0.19999999999999998, y: 0.049999999999999996,
                    w: 0.33333333333333331, h: 0.0166666666666666,
                    confidence: 1.0),
        ]

        let blob = try OCRLayoutCodec.encode(lines)
        let back = try OCRLayoutCodec.decode(blob)

        XCTAssertEqual(back.count, lines.count, "structure intacte")
        XCTAssertEqual(back.map(\.text), lines.map(\.text),
                       "le texte n'est jamais touché")

        for (read, written) in zip(back, lines) {
            for (got, want) in [(read.x, written.x), (read.y, written.y),
                                (read.w, written.w), (read.h, written.h),
                                (read.confidence, written.confidence)] {
                // La valeur relue est exactement l'arrondi à 4 décimales…
                XCTAssertEqual(got, (want * 10_000).rounded() / 10_000,
                               accuracy: 1e-12)
                // … donc au plus une demi-unité de la 4e décimale de l'original.
                XCTAssertEqual(got, want, accuracy: 5e-5)
            }
        }

        // Et le blob est plus court : c'est tout l'objet de la manœuvre.
        let unrounded = try ZlibBlob.compress(
            JSONEncoder().encode(lines.map { LayoutLine($0) }))
        XCTAssertLessThan(blob.count, unrounded.count,
                          "l'arrondi doit réduire le blob (mesuré : −40,4 %)")
    }

    /// Un blob écrit AVANT l'arrondi (17 chiffres) doit rester relisible sans
    /// perte : le format n'a pas changé, seule l'écriture s'est resserrée.
    func testDecoderStillReadsUnroundedBlobs() throws {
        let lines = [OCRLine(text: "ligne héritée", x: 0.10416666666666667,
                             y: 0.8235294117647058, w: 0.6234567901234568,
                             h: 0.021333333333333333, confidence: 0.5)]
        let legacy = try ZlibBlob.compress(
            JSONEncoder().encode(lines.map { LayoutLine($0) }))
        let back = try OCRLayoutCodec.decode(legacy)
        XCTAssertEqual(back.count, 1)
        XCTAssertEqual(back[0].x, 0.10416666666666667, accuracy: 1e-15)
    }

    // MARK: - A2 · alimentation ciblée de vocab_tri

    /// Le run OCR ne doit plus balayer `fts5vocab` en entier : il verse le texte
    /// qu'il vient de reconnaître, tokenisé PAR SQLITE avec le tokenizer de
    /// `page_fts`. Le test vérifie les trois propriétés qui comptent : mêmes
    /// termes que le balayage global, insertion incrémentale, et zéro insertion
    /// quand il n'y a rien de neuf.
    func testTargetedWarmFeedsTheSameTermsAsTheGlobalScan() throws {
        let store = try openStore()
        let expander = TrigramExpander(store: store)
        let docID = try store.upsertDoc(DocRecord(
            volUUID: "TEST-VOL", relPath: "Users/alice/Livres/b.pdf", ext: "pdf",
            topFolder: "Livres", size: 10, mtime: 1))

        let text = "Élément de Chimie Physique — l'énergie d'activation"
        try store.replacePages(docID: docID, pages: [
            PageText(page: 1, text: text, source: .ocrAccurate),
        ])

        let inserted = try expander.warm(texts: [text])
        XCTAssertGreaterThan(inserted, 0)

        // Ce que le balayage global aurait produit, mot pour mot.
        let global = try store.rawStrings("SELECT term FROM vocab ORDER BY term")
        let seen = try store.rawStrings("SELECT term FROM vocab_seen ORDER BY term")
        let tri = try store.rawStrings("SELECT term FROM vocab_tri ORDER BY term")
        XCTAssertEqual(seen, global, "même normalisation que fts5vocab(page_fts)")
        XCTAssertEqual(tri, global)
        XCTAssertTrue(seen.contains("energie"),
                      "les accents doivent tomber comme dans page_fts : \(seen)")

        // Rien de neuf : rien d'inséré, et le balayage global n'aurait rien
        // trouvé non plus.
        XCTAssertEqual(try expander.warm(texts: [text]), 0)
        try expander.warm()
        XCTAssertEqual(try store.rawStrings("SELECT term FROM vocab_seen ORDER BY term"),
                       global, "le balayage global ne doit rien avoir à rattraper")

        // Un terme nouveau, et lui seul, entre.
        let more = "spectroscopie infrarouge"
        try store.replacePages(docID: docID, pages: [
            PageText(page: 1, text: text, source: .ocrAccurate),
            PageText(page: 2, text: more, source: .ocrAccurate),
        ])
        XCTAssertEqual(try expander.warm(texts: [more]), 2)
        XCTAssertEqual(try store.rawStrings("SELECT term FROM vocab_seen ORDER BY term"),
                       try store.rawStrings("SELECT term FROM vocab ORDER BY term"))
    }

    /// Un texte vide n'ouvre même pas de transaction.
    func testTargetedWarmIgnoresEmptyText() throws {
        let store = try openStore()
        XCTAssertEqual(try TrigramExpander(store: store).warm(texts: []), 0)
        XCTAssertEqual(try TrigramExpander(store: store).warm(texts: ["", ""]), 0)
    }

    // MARK: - A6 · deux populations, deux prédicats

    /// `conf = 0` est la sentinelle « aucune ligne reconnue » posée par le
    /// moteur ; une page douteuse a une confiance strictement positive. Les
    /// mélanger, c'était ne remonter que des pages blanches.
    func testDoubtfulAndBlankPagesAreTwoPopulations() throws {
        let store = try openStore()
        let docID = try store.upsertDoc(DocRecord(
            volUUID: "TEST-VOL", relPath: "Users/alice/Cours/scan.pdf", ext: "pdf",
            topFolder: "Cours", size: 10, mtime: 1))
        try store.registerVolume(uuid: "TEST-VOL", label: "Test")
        try store.enqueueOCR(docID: docID, pages: [1, 2, 3], priority: 0)

        func complete(_ page: Int, text: String, conf: Double) throws {
            let line = OCRLine(text: text, x: 0, y: 0, w: 1, h: 0.02,
                               confidence: conf)
            try store.completeOCR(docID: docID, page: page, result: OCRPage(
                text: text, lines: text.isEmpty ? [] : [line], level: .accurate,
                seconds: 1, engine: .vision, engineRev: "vision-rev3",
                meanConfidence: conf))
        }
        // Aucune ligne reconnue : la sentinelle.
        try complete(1, text: "", conf: 0)
        // Douteuse : du texte, mal reconnu.
        try complete(2, text: "texte a peu pres lisible mais douteux", conf: 0.42)
        // Bonne page.
        try complete(3, text: "texte parfaitement lisible et bien reconnu", conf: 0.93)

        let stats = try store.stats()
        XCTAssertEqual(stats["pages_ocr_no_lines"], 1)
        XCTAssertEqual(stats["pages_ocr_low_conf"], 1,
                       "la page vide ne doit plus polluer les douteuses")

        let blank = try store.ocrPagesToRevisit(.noLines, limit: 10)
        XCTAssertEqual(blank.map(\.page), [1])
        let doubtful = try store.ocrPagesToRevisit(.doubtful, limit: 10)
        XCTAssertEqual(doubtful.map(\.page), [2])
        // Le seuil historique de 0,30 ne remonte plus rien : c'est le constat
        // de l'audit, et c'est désormais explicite.
        XCTAssertTrue(try store.lowConfidencePages(
            below: GRDBStore.lowConfidenceThreshold, limit: 10).isEmpty)
    }
}
