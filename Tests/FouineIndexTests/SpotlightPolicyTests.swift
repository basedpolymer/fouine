// SpotlightPolicyTests.swift — la portée et le découpage du texte (INT-S1).
// Propriété : A-Core.
//
// Ce qui est éprouvé ici est ce qui peut être FAUX : quels documents partent
// vers Spotlight, et où le texte est coupé. Le reste — parler à
// `CSSearchableIndex` — exige un bundle et ne se teste pas ; c'est pourquoi il
// vit dans un adaptateur qui ne décide de rien.

import Foundation
import XCTest
import FouineCore
@testable import FouineIndex

final class SpotlightPolicyTests: XCTestCase {

    private func document(ext: String, state: DocState = .extracted,
                          ocr: OCRState = .notNeeded,
                          scannedPages: Int = 0,
                          transcribedPages: Int = 0) -> DocumentChange {
        DocumentChange(id: 7, volUUID: "TEST-VOL",
                       relPath: "Cours/chimie.\(ext)", ext: ext,
                       topFolder: "Cours", state: state, ocrState: ocr,
                       indexedAt: 1_700_000_000, scannedPages: scannedPages,
                       transcribedPages: transcribedPages)
    }

    // MARK: - 1 · La portée par défaut : ce que Spotlight ne lit pas

    func testDefaultScopeKeepsScannedAndBlindFormats() {
        let policy = SpotlightPolicy()

        // Un PDF ordinaire : macOS en tire déjà le texte (1 770 caractères
        // mesurés le 08/09/2026). Le donner ferait un doublon.
        XCTAssertFalse(policy.includes(document(ext: "pdf")))
        // Le MÊME PDF, scanné : Spotlight en tire zéro caractère.
        XCTAssertTrue(policy.includes(document(ext: "pdf", ocr: .done)))
        // La trace factuelle suffit même si `ocr_state` est retombé.
        XCTAssertTrue(policy.includes(document(ext: "pdf", scannedPages: 3)))
        // Les formats aveugles, quels que soient leur état OCR.
        for ext in ["djvu", "cbz", "cbr", "epub"] {
            XCTAssertTrue(policy.includes(document(ext: ext)),
                          "\(ext) devrait être donné : macOS n'en tire rien")
        }
        // Ceux que macOS lit sur de VRAIS fichiers (mesure du 08/09/2026).
        for ext in ["docx", "xlsx", "pptx", "ppt", "doc", "odt", "md", "html"] {
            XCTAssertFalse(policy.includes(document(ext: ext)),
                           "\(ext) est déjà lu par Spotlight : le donner ferait un doublon")
        }
    }

    /// Une vidéo mise par écrit part : Spotlight lit son titre, pas ce qui s'y
    /// dit. La même vidéo sans transcription ne part pas — macOS lit déjà ses
    /// métadonnées. Et une transcription n'est pas un scan (IX2).
    func testTranscribedRecordingsAreGivenButNotTheirMetadataAlone() {
        let policy = SpotlightPolicy()
        XCTAssertTrue(policy.includes(document(ext: "mp4", transcribedPages: 2)))
        XCTAssertFalse(policy.includes(document(ext: "mp4")))
        XCTAssertFalse(SpotlightPolicy.isScanned(document(ext: "mp4", transcribedPages: 2)))
        XCTAssertTrue(SpotlightPolicy.isTranscribed(document(ext: "m4a", transcribedPages: 1)))
    }

    func testEveryDocumentScopeKeepsEverythingExtracted() {
        let policy = SpotlightPolicy(allDocuments: true)
        XCTAssertTrue(policy.includes(document(ext: "pdf")))
        XCTAssertTrue(policy.includes(document(ext: "docx")))
        // Ce qui n'a pas été extrait n'a pas de texte : rien à donner, quelle
        // que soit la portée.
        XCTAssertFalse(policy.includes(document(ext: "pdf", state: .skipped)))
        XCTAssertFalse(policy.includes(document(ext: "djvu", state: .failed)))
    }

    func testDisabledPolicyKeepsNothing() {
        let policy = SpotlightPolicy(enabled: false, allDocuments: true)
        XCTAssertFalse(policy.includes(document(ext: "djvu", ocr: .done)))
    }

    // MARK: - 2 · Les réglages

    func testPolicyReadsTheSettings() {
        let snapshot = SettingsSnapshot(
            rows: [SettingKeys.spotlightAllDocuments.key: "true",
                   SettingKeys.spotlightTextKB.key: "64"],
            environment: [:])
        let policy = SpotlightPolicy(snapshot)
        XCTAssertTrue(policy.enabled)          // défaut : allumé
        XCTAssertTrue(policy.allDocuments)
        XCTAssertEqual(policy.textLimitBytes, 64 * 1_024)
    }

    // MARK: - 3 · Le texte, coupé sur une frontière de page

    func testTruncationKeepsWholePages() {
        // Trois pages de 100 octets ; un plafond de 250 en laisse passer deux
        // (100 + 2 de séparateur + 100 = 202 ; la troisième ferait 304).
        let pages = (1...3).map {
            IndexedPage(page: $0, text: String(repeating: "a", count: 100))
        }
        let kept = SpotlightItemBuilder.truncate(pages: pages, limitBytes: 250)
        XCTAssertEqual(kept.map(\.page), [1, 2])
        XCTAssertEqual(kept.map(\.text.count), [100, 100],
                       "une page donnée l'est ENTIÈRE, jamais coupée au milieu")
    }

    func testTruncationAlwaysKeepsOnePage() {
        // Une première page qui dépasse à elle seule le plafond : on la garde.
        // Un document donné sans un mot de texte serait introuvable, c'est-à-
        // dire pire que rien.
        let pages = [IndexedPage(page: 1, text: String(repeating: "b", count: 5_000)),
                     IndexedPage(page: 2, text: "suite")]
        let kept = SpotlightItemBuilder.truncate(pages: pages, limitBytes: 64)
        XCTAssertEqual(kept.map(\.page), [1])
    }

    func testTruncationCountsUTF8Bytes() {
        // « é » vaut deux octets : le plafond est une taille, pas un nombre de
        // caractères.
        let pages = [IndexedPage(page: 1, text: String(repeating: "é", count: 10)),
                     IndexedPage(page: 2, text: String(repeating: "é", count: 10))]
        XCTAssertEqual(SpotlightItemBuilder.truncate(pages: pages, limitBytes: 30)
                        .map(\.page), [1])
        XCTAssertEqual(SpotlightItemBuilder.truncate(pages: pages, limitBytes: 60)
                        .map(\.page), [1, 2])
    }
}
