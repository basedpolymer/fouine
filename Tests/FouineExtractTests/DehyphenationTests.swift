// DehyphenationTests.swift — les mots coupés en fin de ligne (constat C2-10).
// SPDX-License-Identifier: LicenseRef-Fouine-Source-Available
// Propriété : A-Ingest, cible de test uniquement.
//
// Ce que ces cas tiennent : la forme jointe est AJOUTÉE, la forme coupée
// RESTE, et rien de ce qui ressemble à une césure sans en être une n'est
// recollé — un intervalle de dates, un sigle, un tiret de dialogue.

import XCTest
import FouineCore
@testable import FouineExtract

final class DehyphenationTests: XCTestCase {

    func testAHyphenatedWordGivesBothForms() {
        let text = "Vous pouvez demander à être dispen-\nsé de cet acompte."
        let joined = Dehyphenation.rejoin(text)
        XCTAssertTrue(joined.contains("dispensé"), joined)
        XCTAssertTrue(joined.contains("dispen-"),
                      "la forme coupée reste : deux formes, deux chances")
        XCTAssertEqual(Dehyphenation.count(in: text), 1)
    }

    /// Un mot légitimement composé coupé en fin de ligne : on ne tranche pas,
    /// on garde les deux — « porte-manteau » et « portemanteau » se cherchent.
    func testACompoundWordKeepsBothForms() {
        let joined = Dehyphenation.rejoin("un porte-\nmanteau ancien")
        XCTAssertTrue(joined.contains("portemanteau"), joined)
        XCTAssertTrue(joined.contains("porte-\nmanteau"), joined)
        XCTAssertTrue(joined.contains("ancien"), "la suite du texte est intacte")
    }

    /// L'apostrophe borne le mot : « de l'en-\nsemble » rend « ensemble », pas
    /// « l'ensemble ».
    func testTheApostropheBoundsTheWord() {
        let joined = Dehyphenation.rejoin("le montant de l'en-\nsemble des revenus")
        XCTAssertTrue(joined.contains("ensemble"), joined)
        XCTAssertFalse(joined.contains("l'ensemble"), joined)
    }

    func testWhatIsNeverRejoined() {
        for text in ["la période 1990-\n1995 fut calme",
                     "la référence A-\nB du dossier",
                     "le mot -\n suite du dialogue",
                     "un tiret --\nvraiment double",
                     "rien à recoller ici"] {
            XCTAssertEqual(Dehyphenation.rejoin(text), text, text)
            XCTAssertEqual(Dehyphenation.count(in: text), 0, text)
        }
    }

    /// Les fins de ligne Windows comptent : un PDF exporté d'un traitement de
    /// texte porte souvent « -\r\n ».
    func testCarriageReturnsAreHandled() {
        let joined = Dehyphenation.rejoin("le prélève-\r\nment mensuel")
        XCTAssertTrue(joined.contains("prélèvement"), joined)
    }

    /// Plusieurs césures dans le même texte, et le texte reste lisible.
    func testSeveralHyphenationsInOneText() {
        let text = "le prélève-\nment de l'en-\nsemble des dispen-\nses"
        XCTAssertEqual(Dehyphenation.count(in: text), 3)
        let joined = Dehyphenation.rejoin(text)
        for word in ["prélèvement", "ensemble", "dispenses"] {
            XCTAssertTrue(joined.contains(word), "\(word) manque : \(joined)")
        }
    }

    /// LA MESURE, sur un vrai PDF du corpus de test. Le chiffre part au rapport
    /// du lot : il dit ce que le correctif rend cherchable sur un document mis
    /// en page par un professionnel.
    func testMeasureOnTheCorpusPDF() throws {
        let url = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()      // Tests/FouineExtractTests
            .deletingLastPathComponent()      // Tests
            .appendingPathComponent("Fixtures/corpus/chimie-organique.pdf")
        try XCTSkipUnless(FileManager.default.fileExists(atPath: url.path),
                          "fixture de corpus absente de ce worktree")
        let result = try PDFExtractor().extract(url: url, limits: ExtractLimits())
        let text = result.pages.map(\.text).joined(separator: "\n")
        // Le texte rendu par l'extracteur est DÉJÀ recollé : on compte les
        // formes coupées qui restent, chacune ayant produit une forme jointe.
        let rejoined = Dehyphenation.count(in: text)
        print("C2-10 : \(url.lastPathComponent) — \(text.count) caractères, "
              + "\(rejoined) recollage(s)")
        XCTAssertGreaterThanOrEqual(text.count, 0)
    }
}
