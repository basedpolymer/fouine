// MediaSettingsTests.swift — ce que l'app dit des sons, des vidéos et de la
// parole mise par écrit (lot INT-F3). Propriété : A-App.
// SPDX-License-Identifier: LicenseRef-Fouine-Source-Available

import XCTest
import FouineCore
@testable import FouineApp

final class MediaSettingsTests: XCTestCase {

    // MARK: - La provenance, en mots

    /// La troisième provenance a sa phrase, dans la langue de l'utilisateur.
    /// Ni « transcription » ni « reconnaissance vocale » : le public de Fouine
    /// ne les emploie pas.
    func testLaProvenanceTranscriteADesMots() {
        XCTAssertEqual(LanguageNames.sourceLabel("transcript"),
                       String(localized: "transcribed from the audio"))
        // Les étiquettes brutes viennent de `GRDBStore.sourceLabel` : les trois
        // provenances doivent toutes avoir leur phrase, sans quoi la facette
        // « Origine du texte » afficherait un mot de machine.
        for source in PageSource.allCases {
            let raw = GRDBStore.sourceLabel(source.rawValue)
            XCTAssertNotEqual(LanguageNames.sourceLabel(raw), raw,
                              "la provenance « \(raw) » n'a pas de phrase")
        }
    }

    /// Une page transcrite n'est PAS un scan : elle n'a pas d'image, donc pas
    /// de cadres de lignes à surligner. `isOCR` la classait avec les pages
    /// reconnues avant ce lot.
    func testUnePageTranscriteNEstPasUnScan() {
        let transcrite = Provenance(source: .transcript, engine: .none)
        XCTAssertFalse(transcrite.isOCR)
        XCTAssertEqual(transcrite.symbol, "waveform")
        XCTAssertEqual(transcrite.label,
                       String(localized: "transcribed from the audio"))
        XCTAssertTrue(Provenance(source: .ocrAccurate, engine: .vision).isOCR)
        XCTAssertFalse(Provenance(source: .native, engine: .none).isOCR)
    }

    // MARK: - La case « Images » (PR-05, C2-13)

    /// Le réglage des images existe depuis le lot INT-F2, mais aucune case ne
    /// l'exposait : cent cinquante-deux images des dossiers du propriétaire
    /// restaient invisibles, et le seul chemin pour les allumer passait par un
    /// terminal. La clé est éteinte par défaut — une passe d'OCR sur un
    /// dossier de photos occupe la machine des heures — et sa phrase est
    /// traduite, sans quoi l'onglet retomberait sur l'anglais du cœur.
    /// (La traduction de la phrase, elle, est tenue pour TOUS les réglages par
    /// `L10nTests.testEverySettingSummaryIsLocalized`.)
    @MainActor
    func testLaCaseDesImagesALaCleEtLaPhraseQuIlFaut() {
        XCTAssertEqual(SettingKeys.extractImages.key, "extract.images")
        XCTAssertEqual(SettingKeys.extractImages.fallback, "false")
        // La case vit dans `settings`, et pas dans une variable
        // d'environnement : c'est ce qui la rend visible de l'agent
        // d'arrière-plan et de la ligne de commande (volet 2 de C2-04).
        XCTAssertTrue(SettingKeys.all.contains { $0.key == SettingKeys.extractImages.key })
        XCTAssertFalse(SettingsModel.summary(SettingKeys.extractImages).isEmpty)
    }

    // MARK: - Les trois réglages

    /// Éteints par défaut, tous les trois lisibles depuis la fenêtre ⌘, — et
    /// `transcribe.max_minutes` borné, pour que le pas à pas ne puisse pas
    /// écrire une valeur que le cœur refuserait.
    @MainActor
    func testLesReglagesDesMediasSontEteintsEtBornes() {
        XCTAssertEqual(SettingKeys.extractMedia.fallback, "false")
        XCTAssertEqual(SettingKeys.extractTranscribe.fallback, "false")
        XCTAssertEqual(SettingKeys.transcribeMaxMinutes.fallback, "120")
        let bounds = SettingKeys.transcribeMaxMinutes.range
        XCTAssertEqual(bounds?.min, 1)
        XCTAssertEqual(bounds?.max, 600)

        // Chacun a sa phrase dans la langue de l'utilisateur : sans elle,
        // `SettingsModel.summary` retomberait sur l'anglais du cœur.
        for spec in [SettingKeys.extractMedia, SettingKeys.extractTranscribe,
                     SettingKeys.transcribeMaxMinutes] {
            XCTAssertNotEqual(SettingsModel.summary(spec), spec.summary,
                              "le réglage « \(spec.key) » retombe sur la phrase "
                              + "du cœur au lieu d'être traduit")
        }
    }
}
