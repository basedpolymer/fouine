// OCRBenchTests.swift — P2 (rendu) et P3 (Vision) rejouables (SPEC §8.2).
// Propriété : A-Recette.
//
// Banc d'essai en mémoire : il rend et reconnaît des pages RÉELLES du corpus
// sans jamais écrire — ni dans le PDF (§6.5), ni dans l'index. Il attaque
// `FouinePageRenderer` et `VisionOCREngine` directement, parce que le résumé de
// `fouine ocr` ne donne qu'une médiane et que le §8.2 P3 impose aussi un p95.
//
// Le chargement du modèle (8,5 s au premier `.accurate` de chaque processus) est
// HORS budget par construction (§8.2 P3) : `prewarm()` est appelé avant la série
// et n'entre dans aucun échantillon.
//
// Ces mesures portent sur des pages RÉELLES : elles exigent le corpus complet,
// donc l'opt-in `FOUINE_TEST_DB` (audit S3). Sans lui, tout se saute.

import Foundation
import CoreGraphics
import XCTest
import FouineCore
import FouineOCR

final class OCRBenchTests: XCTestCase {

    /// Pages échantillonnées. Assez pour un p95 lisible, assez peu pour que la
    /// suite reste rejouable (≈ 20 × 3 s de Vision).
    private static let sampleSize = 20

    private var database: URL!

    override func setUpWithError() throws {
        _ = try Recette.requireBinary()
        database = try Recette.requireFullIndex()
    }

    // MARK: - Échantillon

    struct Target {
        let docID: Int64
        let page: Int
        let url: URL
        let name: String
    }

    /// Une page par document scanné, prise au MILIEU de ses pages en file —
    /// jamais les trois premières (§2.5 : la sonde du début ment de 30 points).
    /// Repli sur les pages déjà OCRisées quand la file est vide.
    private func sample() throws -> [Target] {
        var rows = try select(fromQueue: true)
        if rows.isEmpty { rows = try select(fromQueue: false) }
        return rows
    }

    private func select(fromQueue: Bool) throws -> [Target] {
        let table = fromQueue ? "ocr_queue" : "page_src"
        let filter = fromQueue ? "" : " AND s.src = 2"
        // Fonction de fenêtre plutôt que sous-requête corrélée imbriquée :
        // SQLite refuse une corrélation à deux niveaux dans un OFFSET
        // (« no such column: s.doc_id »), vérifié sur 3.43.2.
        let sql = """
            SELECT doc_id, vol_uuid, rel_path, page FROM (
              SELECT s.doc_id AS doc_id, s.page AS page,
                     d.vol_uuid AS vol_uuid, d.rel_path AS rel_path,
                     row_number() OVER (PARTITION BY s.doc_id ORDER BY s.page) AS rn,
                     count(*)     OVER (PARTITION BY s.doc_id) AS n
              FROM \(table) s JOIN docs d ON d.id = s.doc_id
              WHERE d.ext = 'pdf'\(filter)
            ) WHERE rn = (n + 1) / 2
            ORDER BY doc_id LIMIT \(Self.sampleSize)
            """
        var out: [Target] = []
        for line in try Recette.sqlite(sql, on: database).split(separator: "\n") {
            let parts = line.components(separatedBy: "|")
            guard parts.count >= 4, let docID = Int64(parts[0]),
                  let page = Int(parts[3]) else { continue }
            let relPath = parts[2...(parts.count - 2)].joined(separator: "|")
            guard let url = try? VolumeResolver.absolutePath(volUUID: parts[1],
                                                             relPath: relPath)
            else { continue }
            out.append(Target(docID: docID, page: page, url: url,
                              name: (relPath as NSString).lastPathComponent))
        }
        return out
    }

    /// Pages réparties dans UN document déjà OCRisé. L'échantillon « un page par
    /// document de la file » est dominé par des couvertures d'ouvrages par ailleurs
    /// natifs, qui se reconnaissent en un clin d'œil ; un scan dense de bout en
    /// bout est le cas qui engage réellement le seuil P3.
    private func spread(inDocumentEndingWith suffix: String,
                        count: Int) throws -> [Target] {
        let docID = try? Recette.docID(endingWith: suffix, on: database)
        guard let docID else { return [] }
        let raw = try Recette.sqlite("""
            SELECT d.vol_uuid, d.rel_path, s.page FROM page_src s
            JOIN docs d ON d.id = s.doc_id
            WHERE s.doc_id = \(docID) AND s.src = 2 AND s.nchars > 0
            ORDER BY s.page
            """, on: database)
        let rows = raw.split(separator: "\n").map(String.init)
        guard !rows.isEmpty else { return [] }
        let stride = max(1, rows.count / count)
        var out: [Target] = []
        for index in Swift.stride(from: 0, to: rows.count, by: stride) {
            let parts = rows[index].components(separatedBy: "|")
            guard parts.count >= 3, let page = Int(parts[parts.count - 1]) else { continue }
            let relPath = parts[1...(parts.count - 2)].joined(separator: "|")
            guard let url = try? VolumeResolver.absolutePath(volUUID: parts[0],
                                                             relPath: relPath)
            else { continue }
            out.append(Target(docID: docID, page: page, url: url,
                              name: (relPath as NSString).lastPathComponent))
            if out.count >= count { break }
        }
        return out
    }

    // MARK: - P2 · rendu ≤ 0,6 s/page à 150 dpi

    func testP2PageRendering() throws {
        let targets = try sample()
        try XCTSkipIf(targets.isEmpty, "aucune page scannée à rendre")

        let renderer = FouinePageRenderer()
        var seconds: [Double] = []
        var pixels: [Double] = []
        for target in targets {
            let started = Date()
            let image = try renderer.render(url: target.url, page: target.page,
                                            dpi: FouinePageRenderer.defaultDPI)
            seconds.append(Date().timeIntervalSince(started))
            pixels.append(Double(image.width * image.height))
        }

        let median = Stats.median(seconds), p95 = Stats.percentile(seconds, 95)
        print(String(format: "P2 — %d pages · méd %.3f s · p95 %.3f s · max %.3f s "
                     + "· surface méd %.2f Mpx",
                     seconds.count, median, p95, seconds.max() ?? 0,
                     Stats.median(pixels) / 1e6))
        XCTAssertLessThanOrEqual(p95, 0.6, "P2 : rendu au-dessus de 0,6 s/page")
        // Plafond de surface du §6.3 : « 150 dpi » n'est pas une résolution.
        XCTAssertLessThanOrEqual(pixels.max() ?? 0, 4.6e6,
                                 "une page dépasse le plafond de ~4 Mpx (§6.3)")
    }

    // MARK: - P3 · Vision .accurate, médiane ≤ 3,0 s, p95 ≤ 5,0 s

    func testP3VisionAccurate() throws {
        let targets = try sample()
        try XCTSkipIf(targets.isEmpty, "aucune page scannée à reconnaître")

        let renderer = FouinePageRenderer()
        let engine = VisionOCREngine()

        // Hors budget (§8.2 P3) : le chargement du modèle.
        let warmStart = Date()
        try engine.prewarm()
        let warm = Date().timeIntervalSince(warmStart)

        var seconds: [Double] = []
        for target in targets {
            let image = try renderer.render(url: target.url, page: target.page,
                                            dpi: FouinePageRenderer.defaultDPI)
            let page = try engine.recognize(image, level: .accurate,
                                            languages: VisionOCREngine.defaultLanguages,
                                            customWords: [])
            seconds.append(page.seconds)
        }

        let median = Stats.median(seconds), p95 = Stats.percentile(seconds, 95)
        print(String(format: "P3 — %d pages · méd %.3f s · p95 %.3f s · max %.3f s "
                     + "(préchauffage %.2f s, hors budget)",
                     seconds.count, median, p95, seconds.max() ?? 0, warm))
        XCTAssertLessThanOrEqual(median, 3.0, "P3 : médiane Vision au-dessus de 3,0 s")
        XCTAssertLessThanOrEqual(p95, 5.0, "P3 : p95 Vision au-dessus de 5,0 s")
    }

    /// P3 sur un scan DENSE de bout en bout (fixture T7, 304 pages à 301 ppi) :
    /// c'est le cas de charge que le seuil du §8.2 vise réellement.
    func testP3VisionAccurateOnDenseScan() throws {
        _ = try Recette.requireOCRPages()
        let targets = try spread(
            inDocumentEndingWith: "Practical Inorganic Chemistry - Spitsyn.pdf",
            count: 20)
        try XCTSkipIf(targets.isEmpty, "fixture T7 non OCRisée")

        let renderer = FouinePageRenderer()
        let engine = VisionOCREngine()
        try engine.prewarm()

        // Les images sont rendues UNE fois et gardées : les deux séries de
        // reconnaissance portent alors sur exactement les mêmes pixels, et la
        // comparaison `customWords` n'est pas polluée par le rendu.
        var render: [Double] = []
        var images: [CGImage] = []
        for target in targets {
            let started = Date()
            let image = try renderer.render(url: target.url, page: target.page,
                                            dpi: FouinePageRenderer.defaultDPI)
            render.append(Date().timeIntervalSince(started))
            images.append(image)
        }

        // Configuration de PRODUCTION : `customWords` alimenté par l'index
        // (§6.2, durcissement n°2) — `OCRRun` passe topVocabulary(3000, ≥ 6).
        let vocabulary = try GRDBStore.opened(at: database)
            .topVocabulary(limit: OCRRun.vocabularyLimit,
                           minLength: OCRRun.vocabularyMinLength)
        var withWords: [Double] = [], withoutWords: [Double] = []
        var chars = (with: 0, without: 0)
        for image in images {
            let a = try engine.recognize(image, level: .accurate,
                                         languages: VisionOCREngine.defaultLanguages,
                                         customWords: vocabulary)
            withWords.append(a.seconds); chars.with += a.text.count
            let b = try engine.recognize(image, level: .accurate,
                                         languages: VisionOCREngine.defaultLanguages,
                                         customWords: [])
            withoutWords.append(b.seconds); chars.without += b.text.count
        }

        print(String(format: "P3 (scan dense) — %d pages · rendu méd %.3f s p95 %.3f s",
                     withWords.count, Stats.median(render),
                     Stats.percentile(render, 95)))
        print(String(format: "P3 (scan dense) — Vision AVEC customWords (%d termes) : "
                     + "méd %.3f s p95 %.3f s max %.3f s · %d caractères",
                     vocabulary.count, Stats.median(withWords),
                     Stats.percentile(withWords, 95), withWords.max() ?? 0, chars.with))
        print(String(format: "P3 (scan dense) — Vision SANS customWords : "
                     + "méd %.3f s p95 %.3f s max %.3f s · %d caractères",
                     Stats.median(withoutWords), Stats.percentile(withoutWords, 95),
                     withoutWords.max() ?? 0, chars.without))

        XCTAssertLessThanOrEqual(Stats.percentile(render, 95), 0.6,
                                 "P2 (scan dense) : rendu au-dessus de 0,6 s/page")
        XCTAssertLessThanOrEqual(Stats.median(withWords), 3.0,
                                 "P3 (scan dense) : médiane Vision au-dessus de 3,0 s")
        XCTAssertLessThanOrEqual(Stats.percentile(withWords, 95), 5.0,
                                 "P3 (scan dense) : p95 Vision au-dessus de 5,0 s")
    }
}

private extension GRDBStore {
    /// Ouverture en lecture pour le banc d'essai : `topVocabulary` n'existe que
    /// sur le store, et le banc doit passer à Vision EXACTEMENT le lexique que
    /// la pompe lui passe (§6.2).
    static func opened(at url: URL) throws -> GRDBStore {
        let store = GRDBStore()
        try store.open(at: url)
        return store
    }
}
