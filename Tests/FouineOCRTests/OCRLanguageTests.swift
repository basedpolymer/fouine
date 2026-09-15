// OCRLanguageTests.swift — les langues de reconnaissance, réglables (audit X2).
// Propriété : A-OCR.
//
// « `OCRRun.swift:415` passe `["fr-FR","en-US"]` à toutes les pages, sans
//   réglage. » Le point délicat n'est pas de rendre la liste configurable, c'est
//   de la FILTRER : Vision fait échouer la requête ENTIÈRE sur une langue
//   inconnue de la révision. Sans filtre, un réglage `zh-Hans` sur une machine
//   qui ne l'a pas ne dégraderait pas la reconnaissance — il l'annulerait, page
//   par page, avec pour seul symptôme un compteur d'échecs.

import XCTest
import FouineCore
@testable import FouineOCR

final class OCRLanguageTests: XCTestCase {

    /// La machine doit savoir dire ce qu'elle sait faire. Vision rev3 annonce
    /// au minimum l'anglais ; le français est vérifié présent (§6.2).
    func testSupportedLanguagesAreReadFromTheMachine() {
        let supported = VisionOCREngine.supportedLanguages()
        XCTAssertFalse(supported.isEmpty,
                       "Vision n'a annoncé aucune langue : la liste à cocher de "
                       + "la fenêtre de réglages serait vide")
        XCTAssertEqual(supported, supported.sorted(),
                       "la liste doit être triée : l'ordre de la liste à cocher "
                       + "ne doit pas dépendre de l'humeur de Vision")
        XCTAssertTrue(supported.contains { $0.hasPrefix("en") },
                      "anglais attendu : \(supported)")
        XCTAssertTrue(supported.contains { $0.hasPrefix("fr") },
                      "français attendu (§6.2, vérifié en rev3) : \(supported)")
    }

    /// Le cas nominal : les deux langues historiques passent, rien n'est écarté.
    func testDefaultLanguagesSurviveTheFilter() {
        let (kept, rejected) =
            VisionOCREngine.filterLanguages(VisionOCREngine.defaultLanguages)
        XCTAssertEqual(kept, VisionOCREngine.defaultLanguages)
        XCTAssertTrue(rejected.isEmpty, "écartées : \(rejected)")
    }

    /// Une langue qui n'existe nulle part est ÉCARTÉE et NOMMÉE — pas
    /// silencieusement transmise à Vision.
    func testUnsupportedLanguageIsRejectedAndNamed() {
        let (kept, rejected) = VisionOCREngine.filterLanguages(["fr-FR", "xx-XX"])
        XCTAssertEqual(kept, ["fr-FR"])
        XCTAssertEqual(rejected, ["xx-XX"])
    }

    /// Une liste entièrement invalide retombe sur le couple par défaut : mieux
    /// vaut reconnaître en français et en anglais que ne rien reconnaître du
    /// tout parce qu'un réglage désigne une langue absente.
    func testAllUnsupportedFallsBackToTheDefaultPair() {
        let (kept, rejected) = VisionOCREngine.filterLanguages(["xx-XX", "yy-YY"])
        XCTAssertEqual(kept, VisionOCREngine.defaultLanguages)
        XCTAssertEqual(rejected, ["xx-XX", "yy-YY"])
    }

    /// La casse ne doit pas décider du sort d'un réglage : `fouine config set
    /// ocr.languages fr-fr` doit valoir `fr-FR`, et la forme CANONIQUE de la
    /// machine est celle qui part à Vision.
    func testMatchingIsCaseInsensitiveAndCanonicalises() {
        let supported = VisionOCREngine.supportedLanguages()
        guard let canonical = supported.first(where: { $0.hasPrefix("fr") }) else {
            return XCTFail("français absent de cette machine")
        }
        let (kept, rejected) = VisionOCREngine.filterLanguages([canonical.lowercased()])
        XCTAssertEqual(kept, [canonical])
        XCTAssertTrue(rejected.isEmpty)
    }

    /// L'ordre DEMANDÉ est conservé : `recognitionLanguages` est une liste de
    /// PRÉFÉRENCE pour Vision, pas un ensemble.
    func testRequestedOrderIsPreserved() {
        let (kept, _) = VisionOCREngine.filterLanguages(["en-US", "fr-FR"])
        XCTAssertEqual(kept, ["en-US", "fr-FR"])
    }

    // MARK: - Résolution depuis les réglages

    /// Sans rien en base : le couple historique, et une ligne de journal qui le
    /// dit. C'est la garantie de non-régression du palier — une base neuve
    /// OCRise exactement comme avant.
    func testResolutionFallsBackToTheHistoricPairOnAFreshDatabase() throws {
        let temp = try TempStore()
        var lines: [String] = []
        let languages = OCRRun.resolveLanguages(store: temp.store, requested: nil,
                                                log: { lines.append($0) })
        XCTAssertEqual(languages, VisionOCREngine.defaultLanguages)
        XCTAssertTrue(lines.contains { $0.contains("OCR languages:") }, "\(lines)")
    }

    /// Le réglage `ocr.languages` est LU, et une langue absente de la machine
    /// est écartée avec un avertissement nommant la clé à corriger.
    func testResolutionReadsTheSettingAndWarnsAboutUnsupportedOnes() throws {
        let temp = try TempStore()
        let settings = Settings(store: temp.store, ttl: 0, environment: [:])
        try settings.set(SettingKeys.ocrLanguages.key, "fr-FR,xx-XX")

        var lines: [String] = []
        let languages = OCRRun.resolveLanguages(store: temp.store, requested: nil,
                                                log: { lines.append($0) })
        XCTAssertEqual(languages, ["fr-FR"])
        let warning = lines.first { $0.contains("xx-XX") }
        XCTAssertNotNil(warning, "la langue écartée doit être nommée : \(lines)")
        XCTAssertTrue(warning?.contains("ocr.languages") ?? false,
                      "le message doit dire OÙ corriger : \(warning ?? "")")
    }

    /// Une liste explicite passée par l'appelant (l'agent, qui a déjà son
    /// instantané) l'emporte sur la base : une seule lecture par lot.
    func testExplicitRequestWinsOverTheSetting() throws {
        let temp = try TempStore()
        let settings = Settings(store: temp.store, ttl: 0, environment: [:])
        try settings.set(SettingKeys.ocrLanguages.key, "fr-FR")

        let languages = OCRRun.resolveLanguages(store: temp.store,
                                                requested: ["en-US"], log: { _ in })
        XCTAssertEqual(languages, ["en-US"])
    }
}
