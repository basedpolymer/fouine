// LanguageBackfillPassTests.swift — le rattrapage de langue en fin de passe
// (lot U3, R-10). Propriété : A-Core.
//
// Ce que ces tests protègent : la passe est jouée par les TROIS pipelines, dont
// l'agent d'arrière-plan, à chaque salve FSEvents. Un rattrapage non borné y
// serait une régression de réactivité — 1 392 détections d'un coup sur la base
// réelle. Il doit donc (a) s'arrêter à `languageBackfillLimit`, (b) reprendre
// où il en était à la passe suivante, (c) ne rien faire quand l'utilisateur a
// annulé ou quand le budget est épuisé, (d) ne jamais faire échouer une passe.

import XCTest
import FouineCore
@testable import FouineIndex

final class LanguageBackfillPassTests: XCTestCase {

    /// Une base indexée dont on a EFFACÉ les langues : l'état exact d'un fonds
    /// indexé avant que la détection existe (audit X2), c'est-à-dire 1 392 des
    /// 1 499 documents de la base réelle le 05/09/2026.
    private func indexedWithoutLanguages(_ name: String, documents: Int)
        throws -> IndexScratch {
        let scratch = try IndexScratch(name, documents: documents)
        try IndexPass(store: scratch.store)
            .run(roots: [scratch.rootRecord],
                 options: IndexPassOptions(crawl: .full, warmVocabulary: false))
        for row in try scratch.documents() {
            try scratch.store.setDocLanguage(row.id, nil)
        }
        XCTAssertEqual(try scratch.store.documentsWithoutLanguageCount(), documents)
        return scratch
    }

    private func options(limit: Int, budget: Budget = .none) -> IndexPassOptions {
        IndexPassOptions(crawl: .delta, jobs: 4, budget: budget,
                         optimize: false, warmVocabulary: false,
                         languageBackfillLimit: limit)
    }

    private func langs(_ scratch: IndexScratch) throws -> [String] {
        try scratch.documents().compactMap(\.record.lang)
    }

    // MARK: - Borné, puis repris

    func testAuPlusLaLimiteParPasse() throws {
        let scratch = try indexedWithoutLanguages("borne", documents: 5)
        let observer = RecordingObserver()

        let summary = try IndexPass(store: scratch.store, observer: observer)
            .run(roots: [scratch.rootRecord], options: options(limit: 2))

        XCTAssertEqual(summary.counters.languagesDetected, 2)
        XCTAssertEqual(try langs(scratch).count, 2,
                       "une passe ne rattrape jamais plus que sa limite : "
                       + "l'agent joue cette passe à chaque salve FSEvents")
        XCTAssertEqual(try scratch.store.documentsWithoutLanguageCount(), 3)
        XCTAssertTrue(observer.notes.contains {
            $0.contains("language detected for 2 document(s), 3 left")
        }, "le journal dit ce qui a été fait et ce qui reste : \(observer.notes)")
    }

    func testLaPasseSuivanteReprendEtSArreteQuandTouteEstFaite() throws {
        let scratch = try indexedWithoutLanguages("reprise", documents: 5)
        let pass = IndexPass(store: scratch.store)

        _ = try pass.run(roots: [scratch.rootRecord], options: options(limit: 2))
        _ = try pass.run(roots: [scratch.rootRecord], options: options(limit: 2))
        let third = try pass.run(roots: [scratch.rootRecord], options: options(limit: 2))

        XCTAssertEqual(third.counters.languagesDetected, 1, "il n'en restait qu'un")
        XCTAssertEqual(try langs(scratch).count, 5)

        // Idempotence : une quatrième passe ne relit RIEN. Sans le jeton
        // « und », les documents indéterminés seraient recandidats à l'infini.
        let fourth = try pass.run(roots: [scratch.rootRecord], options: options(limit: 2))
        XCTAssertEqual(fourth.counters.languagesDetected, 0)
        XCTAssertEqual(try scratch.store.documentsWithoutLanguageCount(), 0)
    }

    func testLimiteNulleNeRattrapeRien() throws {
        let scratch = try indexedWithoutLanguages("desarme", documents: 3)
        let summary = try IndexPass(store: scratch.store)
            .run(roots: [scratch.rootRecord], options: options(limit: 0))
        XCTAssertEqual(summary.counters.languagesDetected, 0)
        XCTAssertEqual(try langs(scratch), [])
    }

    // MARK: - Annulation et budget

    func testUnePasseAnnuleeNeRattrapeRien() throws {
        let scratch = try indexedWithoutLanguages("annulee", documents: 3)
        let summary = try IndexPass(store: scratch.store, shouldStop: { true })
            .run(roots: [scratch.rootRecord], options: options(limit: 100))

        XCTAssertEqual(summary.stop, .cancelled)
        XCTAssertEqual(summary.counters.languagesDetected, 0,
                       "celui qui vient de cliquer « Annuler » n'attend pas un "
                       + "travail de confort")
        XCTAssertEqual(try langs(scratch), [])
    }

    func testUnePasseABoutDeBudgetNeRattrapeRien() throws {
        let scratch = try indexedWithoutLanguages("budget", documents: 3)
        // Un document neuf, donc une cible : sans cible, le budget n'a rien à
        // interrompre et la passe se termine normalement.
        try "Une fiche de plus, en français, avec assez de matière pour être lue."
            .write(to: scratch.root.appendingPathComponent("neuve.txt"),
                   atomically: true, encoding: .utf8)

        let summary = try IndexPass(store: scratch.store)
            .run(roots: [scratch.rootRecord],
                 options: options(limit: 100,
                                  budget: Budget(deadline: Date(timeIntervalSince1970: 1))))

        XCTAssertEqual(summary.stop, .budgetExhausted)
        XCTAssertEqual(summary.counters.languagesDetected, 0)
        XCTAssertEqual(try scratch.store.documentsWithoutLanguageCount(), 3)
    }

    // MARK: - Le contenu de ce qui est écrit

    func testLesLanguesEcritesSontCellesDuTexte() throws {
        let scratch = try IndexScratch("contenu", documents: 0)
        try String(repeating: "Le vent se lève, il faut tenter de vivre. ", count: 8)
            .write(to: scratch.root.appendingPathComponent("fr.txt"),
                   atomically: true, encoding: .utf8)
        try String(repeating: "The quick brown fox jumps over the lazy dog. ", count: 8)
            .write(to: scratch.root.appendingPathComponent("en.txt"),
                   atomically: true, encoding: .utf8)
        try "ok.".write(to: scratch.root.appendingPathComponent("court.txt"),
                        atomically: true, encoding: .utf8)

        // Première passe : la langue est écrite à l'extraction (audit X2). On
        // l'efface pour reproduire un fonds ancien, puis on laisse la passe
        // suivante la retrouver depuis `page_fts` — sans rien ré-extraire.
        let pass = IndexPass(store: scratch.store)
        _ = try pass.run(roots: [scratch.rootRecord],
                         options: IndexPassOptions(crawl: .full, warmVocabulary: false))
        for row in try scratch.documents() { try scratch.store.setDocLanguage(row.id, nil) }
        _ = try pass.run(roots: [scratch.rootRecord], options: options(limit: 100))

        var byName: [String: String?] = [:]
        for row in try scratch.documents() {
            byName[(row.record.relPath as NSString).lastPathComponent] = row.record.lang
        }
        XCTAssertEqual(byName["fr.txt"] ?? nil, "fr")
        XCTAssertEqual(byName["en.txt"] ?? nil, "en")
        XCTAssertEqual(byName["court.txt"] ?? nil, FacetKey.undeterminedLanguage,
                       "un texte trop court reçoit le jeton « und » : NULL le "
                       + "ferait relire à chaque passe, pour la même réponse")
    }
}
