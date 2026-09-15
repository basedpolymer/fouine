// VocabJournalTests.swift — une ligne `vocab_tri` par LOT, pas par vidage (A2-12).
// Propriété : A-Recette.
//
// Sur le journal réel de la machine du propriétaire (01 au 03/09/2026,
// 219 182 octets, 1 781 lignes), 789 lignes — 44 % du total, 45 % des octets —
// étaient ce seul message. La récolte se vide tous les ~1 Mio de texte
// reconnu, c'est-à-dire toutes les seize pages en pratique. Le journal étant,
// de l'aveu de `docs/agent.md` § 4, « le seul endroit où un incident est
// visible », l'incident était une aiguille dans une meule.

import XCTest
import FouineCore
@testable import FouineOCR

final class VocabJournalTests: XCTestCase {

    /// Un document indexé : `warm(texts:)` ne verse dans `vocab_tri` que des
    /// termes que `page_fts` contient déjà.
    private func seed(_ temp: TempStore, texts: [String]) throws {
        let docID = try temp.store.upsertDoc(DocRecord(
            volUUID: "TEST-VOL", relPath: "livre.pdf", ext: "pdf",
            topFolder: "Livres", size: 1_000, mtime: 1_700_000_000,
            nPages: texts.count, state: .extracted))
        try temp.store.replacePages(docID: docID, pages: texts.enumerated().map {
            PageText(page: $0.offset + 1, text: $0.element, source: .ocrAccurate)
        })
    }

    func testIntermediateFlushesAreSilentAndTheBatchIsSummarised() throws {
        let temp = try TempStore()
        let pages = ["réticulation cinétique", "thermodynamique enthalpie",
                     "spectrophotométrie calorimétrie"]
        try seed(temp, texts: pages)

        var lines: [String] = []
        let log: (String) -> Void = { lines.append($0) }
        let harvest = OCRRun.VocabHarvest()
        let counters = OCRRun.Counters()

        // Trois vidages en cours de lot : aucune ligne.
        for text in pages {
            harvest.record(text)
            OCRRun.warmHarvest(store: temp.store, harvest: harvest,
                               counters: counters, log: log)
        }
        XCTAssertTrue(lines.isEmpty,
                      "A2-12 : une ligne tous les seize pages OCRisées\n"
                      + lines.joined(separator: "\n"))

        // Fin de lot : UNE ligne, et elle porte le total du lot.
        OCRRun.warmHarvest(store: temp.store, harvest: harvest,
                           counters: counters, log: log, force: true)
        XCTAssertEqual(lines.count, 1, lines.joined(separator: "\n"))
        XCTAssertTrue(lines[0].hasPrefix("vocab_tri: "), lines[0])
        XCTAssertTrue(lines[0].contains("from 3 OCR'd page(s)"),
                      "le bilan compte les TROIS pages du lot : " + lines[0])
    }

    /// Un lot qui n'a rien apporté ne dit rien : c'est le cas courant sur un
    /// corpus déjà largement reconnu.
    func testABatchWithoutANewTermStaysSilent() throws {
        let temp = try TempStore()
        try seed(temp, texts: ["réticulation cinétique"])

        var lines: [String] = []
        let harvest = OCRRun.VocabHarvest()
        let counters = OCRRun.Counters()

        harvest.record("réticulation cinétique")
        OCRRun.warmHarvest(store: temp.store, harvest: harvest,
                           counters: counters, log: { lines.append($0) },
                           force: true)
        lines.removeAll()

        // Deuxième lot, le même texte : plus rien à verser.
        harvest.record("réticulation cinétique")
        OCRRun.warmHarvest(store: temp.store, harvest: harvest,
                           counters: counters, log: { lines.append($0) },
                           force: true)
        XCTAssertTrue(lines.isEmpty, lines.joined(separator: "\n"))
    }

    /// Le bilan se remet à zéro : deux fins de lot ne font pas deux fois la
    /// même ligne.
    func testTallyIsConsumedOnce() throws {
        let temp = try TempStore()
        try seed(temp, texts: ["réticulation cinétique"])
        var lines: [String] = []
        let harvest = OCRRun.VocabHarvest()
        let counters = OCRRun.Counters()
        harvest.record("réticulation cinétique")
        OCRRun.warmHarvest(store: temp.store, harvest: harvest, counters: counters,
                           log: { lines.append($0) }, force: true)
        XCTAssertEqual(lines.count, 1)
        OCRRun.warmHarvest(store: temp.store, harvest: harvest, counters: counters,
                           log: { lines.append($0) }, force: true)
        XCTAssertEqual(lines.count, 1, "le bilan a déjà été dit")
    }
}
