// OCRRecetteTests.swift — recette OCR (SPEC §8.1 T6, T7, T11, T13).
// Propriété : A-Recette.
//
// Ces tests exigent le CORPUS COMPLET : ils s'exécutent sur la copie de base
// désignée par `FOUINE_TEST_DB` (audit S3 — voir l'en-tête d'IntegrationSupport),
// sur des pages réellement OCRisées. Sans opt-in, ou si l'OCR n'a pas tourné
// (`page_src` sans aucune ligne `src = 2`), ils se sautent proprement.
//
// T6, T7 et T13 lisent ; T11 CONSOMME une minute de file OCR — c'est du travail
// utile et non destructif (§6.5 : Fouine n'écrit jamais dans un PDF), mais c'est
// une ÉCRITURE, et c'est précisément pourquoi elle ne peut plus toucher que la
// copie que le mainteneur a désignée, jamais la base où l'agent travaille.

import Foundation
import XCTest

final class OCRRecetteTests: XCTestCase {

    private var database: URL!

    override func setUpWithError() throws {
        _ = try Recette.requireBinary()
        database = try Recette.requireOCRPages()
    }

    // MARK: - T6 · page manuscrite scannée — le test décisif du projet

    func testT6HandwrittenPageIsSearchable() throws {
        let fixture = try Recette.requireFixture("T6")
        let docID = try Recette.docID(
            endingWith: "CamScanner 15-09-2024 17.51.pdf", on: database)
        try skipIfNotOCRed(docID: docID, page: 1, test: "T6")

        let payload = try Recette.search(fixture.query, database: database,
                                         extra: ["--fuzzy", "off",
                                                 "--in", "\(docID)"], limit: 200)
        XCTAssertEqual(Set(payload.hits.map(\.page)), Set(fixture.expectedPages ?? [1]),
                       "« \(fixture.query) » ne tombe pas sur la page attendue")
        for hit in payload.hits {
            XCTAssertEqual(hit.source, fixture.expectedSource ?? "ocr_accurate")
            XCTAssertEqual(hit.engine, "vision")
        }

        // Contrôles secondaires du §8.1 T6, restreints AU DOCUMENT : ces mots
        // sont courants dans le corpus, une requête globale les noierait.
        for term in fixture.secondaryTerms ?? ["taux", "conversion", "volume", "passage"] {
            let hits = try Recette.search(term, database: database,
                                          extra: ["--fuzzy", "off", "--in", "\(docID)"],
                                          limit: 200)
            XCTAssertTrue(hits.hits.contains { $0.page == 1 },
                          "contrôle secondaire « \(term) » absent de la page 1")
        }
    }

    // MARK: - T7 · scan dactylographié propre

    func testT7CleanScanIsSearchable() throws {
        let fixture = try Recette.requireFixture("T7")
        let docID = try Recette.docID(
            endingWith: "Practical Inorganic Chemistry - Spitsyn.pdf", on: database)
        let page = (fixture.expectedPages ?? [120]).first ?? 120
        try skipIfNotOCRed(docID: docID, page: page, test: "T7")

        let payload = try Recette.search(fixture.query, database: database,
                                         extra: ["--fuzzy", "off", "--in", "\(docID)"],
                                         limit: 500)
        XCTAssertTrue(payload.hits.contains { $0.page == page },
                      "« \(fixture.query) » absent de la page \(page) "
                      + "(pages trouvées : \(Set(payload.hits.map(\.page)).sorted()))")
        for hit in payload.hits {
            XCTAssertEqual(hit.source, fixture.expectedSource ?? "ocr_accurate")
        }

        // Transcriptions de référence du §8.1 T7. L'OCR n'étant pas reproductible
        // au caractère près d'une version de macOS à l'autre, on exige les mots
        // porteurs, pas la ponctuation.
        let body = try Recette.pageBody(docID: docID, page: page, on: database)
            .lowercased()
        for word in ["sulphur", "selenium", "tellurium"] {
            XCTAssertTrue(body.contains(word),
                          "en-tête de référence : « \(word) » absent de la page \(page)")
        }
        for word in ["apparatus", "chlorides"] {
            XCTAssertTrue(body.contains(word),
                          "légende de référence : « \(word) » absent de la page \(page)")
        }
    }

    // MARK: - T13 · flou sur page OCRisée (PROCÉDURE, pas variante figée)

    /// « Test formulé comme une procédure et non sur une variante figée : l'OCR
    /// n'est pas reproductible au caractère près » (§8.1 T13). On prend donc un
    /// terme RÉELLEMENT présent dans le texte reconnu, on lui applique UNE
    /// substitution, et on ne retient la variante que si elle est absente de tout
    /// le corpus — mesuré, `converslon` de la spec existe en clair dans un livre
    /// natif du corpus, ce qui la rend inutilisable ici.
    func testT13FuzzyRecoversOneSubstitution() throws {
        let docID = try Recette.docID(
            endingWith: "CamScanner 15-09-2024 17.51.pdf", on: database)
        try skipIfNotOCRed(docID: docID, page: 1, test: "T13")

        let body = try Recette.pageBody(docID: docID, page: 1, on: database)
        let candidates = Self.words(ofAtLeast: 6, in: body)
        try XCTSkipIf(candidates.isEmpty,
                      "aucun terme de ≥ 6 lettres dans le texte OCR de la page")

        guard let probe = try firstUsableVariant(from: candidates) else {
            throw XCTSkip("aucune variante à une substitution absente du corpus")
        }
        print("T13 — terme « \(probe.term) » -> variante « \(probe.variant) »")

        let off = try Recette.search(probe.variant, database: database,
                                     extra: ["--fuzzy", "off"], limit: 50)
        XCTAssertEqual(off.totalPages, 0,
                       "la variante doit être absente en --fuzzy off")

        let on = try Recette.search(probe.variant, database: database,
                                    extra: ["--fuzzy", "on",
                                            "--fuzzy-scope", "ocr"], limit: 50)
        let hit = try XCTUnwrap(
            on.hits.first { $0.docID == docID && $0.page == 1 },
            "le flou au scope ocr ne retrouve pas la page (\(on.totalPages) page(s))")
        XCTAssertEqual(hit.fuzzyDistance, 1)
        XCTAssertEqual(hit.source, "ocr_accurate")

        // Pénalité 1/(1+d) : le score rendu vaut la MOITIÉ du bm25 de la branche
        // étendue. bm25 est négatif, la division rapproche de zéro, donc classe
        // après les correspondances exactes (§5.5.2).
        let expanded = "(\"\(probe.variant)\" OR \"\(probe.term)\")"
        let rowid = docID * 100_000 + 1
        let raw = try Recette.sqlite("""
            SELECT bm25(page_fts) FROM page_fts
            WHERE page_fts MATCH '\(expanded)' AND rowid = \(rowid)
            """, on: database)
        if let bm25 = Double(raw.trimmingCharacters(in: .whitespacesAndNewlines)) {
            XCTAssertEqual(hit.score, bm25 / 2, accuracy: 1e-6,
                           "la pénalité 1/(1+d) n'est pas appliquée")
        }
    }

    // MARK: - T11 · budget épuisé

    /// Consomme une minute de la file de la COPIE désignée par `FOUINE_TEST_DB`
    /// (audit S3), jamais celle de production. Se saute si la file est vide.
    /// Tolérance §8.1 : le préchauffage Vision consomme 8,5 s du budget par
    /// processus.
    func testT11BudgetExhaustedLeavesTheQueueCoherent() throws {
        let before = try queueLength()
        try XCTSkipIf(before == 0, "file OCR vide : T11 n'a rien à interrompre")

        let started = Date()
        let result = try Recette.run(["ocr", "--budget-minutes", "1"],
                                     database: database, timeout: 1_800)
        let elapsed = Date().timeIntervalSince(started)
        let after = try queueLength()
        print("T11 — file \(before) -> \(after) en \(String(format: "%.0f", elapsed)) s, "
              + "sortie \(result.status)")

        XCTAssertEqual(result.status, 4,
                       "sortie 4 attendue quand le budget est épuisé (§4.3)\n"
                       + result.describe)
        XCTAssertLessThan(after, before, "aucune page n'a été traitée")
        XCTAssertGreaterThan(after, 0, "la file s'est vidée : T11 ne teste rien")

        // La file reste cohérente : rien n'est perdu ni dupliqué, et les pages
        // traitées ont bien quitté la file pour `page_src`.
        let orphans = try Recette.sqlite("""
            SELECT count(*) FROM ocr_queue q
            WHERE NOT EXISTS (SELECT 1 FROM docs d WHERE d.id = q.doc_id)
            """, on: database)
        XCTAssertEqual(orphans.trimmingCharacters(in: .whitespacesAndNewlines), "0",
                       "la file contient des pages orphelines")
        let both = try Recette.sqlite("""
            SELECT count(*) FROM ocr_queue q
            JOIN page_src s ON s.doc_id = q.doc_id AND s.page = q.page
            WHERE s.src = 2
            """, on: database)
        XCTAssertEqual(both.trimmingCharacters(in: .whitespacesAndNewlines), "0",
                       "des pages OCRisées sont restées en file")

        // Reprise : `ocr_state = partial` sur au moins un document entamé (§4.2).
        let partial = try Recette.sqlite(
            "SELECT count(*) FROM docs WHERE ocr_state = 2", on: database)
        XCTAssertNotEqual(partial.trimmingCharacters(in: .whitespacesAndNewlines), "0",
                          "aucun document en ocr_state = partial après interruption")
    }

    // MARK: - Outils

    private func queueLength() throws -> Int {
        let raw = try Recette.sqlite("SELECT count(*) FROM ocr_queue", on: database)
        return Int(raw.trimmingCharacters(in: .whitespacesAndNewlines)) ?? 0
    }

    private func skipIfNotOCRed(docID: Int64, page: Int, test: String) throws {
        let raw = try Recette.sqlite("""
            SELECT count(*) FROM page_src
            WHERE doc_id = \(docID) AND page = \(page) AND src = 2
            """, on: database)
        guard raw.trimmingCharacters(in: .whitespacesAndNewlines) == "1" else {
            throw XCTSkip("\(test) : la page \(page) du document \(docID) n'est pas "
                          + "OCRisée — lancer `fouine ocr --only <fixture>`")
        }
    }

    /// Mots de ≥ `minimum` lettres latines, dédupliqués, dans l'ordre du texte.
    static func words(ofAtLeast minimum: Int, in text: String) -> [String] {
        var seen = Set<String>()
        var out: [String] = []
        for raw in text.lowercased().split(whereSeparator: { !$0.isLetter }) {
            let word = String(raw)
            guard word.count >= minimum,
                  word.allSatisfy({ $0.isASCII && $0.isLetter }),
                  seen.insert(word).inserted else { continue }
            out.append(word)
        }
        return out
    }

    /// Première variante à UNE substitution absente de tout l'index — sans quoi
    /// la première moitié de T13 (« off -> 0 résultat ») est insatisfiable.
    private func firstUsableVariant(from candidates: [String])
        throws -> (term: String, variant: String)? {
        let substitutes = Array("rnlaeiotsc")
        for term in candidates.prefix(8) {
            let letters = Array(term)
            for index in letters.indices {
                for replacement in substitutes where replacement != letters[index] {
                    var mutated = letters
                    mutated[index] = replacement
                    let variant = String(mutated)
                    let probe = try Recette.search(variant, database: database,
                                                   extra: ["--fuzzy", "off"], limit: 1)
                    if probe.totalPages == 0 { return (term, variant) }
                }
            }
        }
        return nil
    }
}
