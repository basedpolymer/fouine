// SettingsSummaryTests.swift — les info-bulles des réglages parlent la langue
// du produit (audit AP-14, BU-11 ; lot UX3). Propriété : A-App.
// SPDX-License-Identifier: LicenseRef-Fouine-Source-Available
//
// Ce que l'utilisateur lisait en survolant les réglages, le 09/09/2026 :
// « Durée d'un lot d'OCR de l'agent, en minutes. Les conditions du §5.7 sont
// re-décidées à chaque lot. », « Identifiants des racines prioritaires pour
// l'OCR », « Fils d'extraction de l'agent d'arrière-plan », « codes BCP-47 ».
// C'étaient les résumés de `fouine config list` recopiés dans une fenêtre
// destinée à des gens qui n'ouvrent pas de terminal.
//
// Le test porte sur les DEUX langues : l'anglais rendu par
// `SettingsModel.summary` (en test, `String(localized:)` rend la clé) et la
// valeur française du catalogue, qui est ce que l'utilisateur voit vraiment.
// Les résumés de la CLI (`SettingSpec.summary`), eux, gardent leur vocabulaire
// de métier : le test vérifie aussi qu'ils n'ont pas été alignés par erreur.

import XCTest
import FouineCore
@testable import FouineApp

final class SettingsSummaryTests: XCTestCase {

    /// Les mots de métier, par MOT ENTIER : « file » et « profile » ne sont pas
    /// des « fil », et « rooted » n'existe pas dans nos phrases mais pourrait.
    private static let banned = [
        "agent", "agents", "ocr", "root", "roots", "bcp",
        "thread", "threads", "identifier", "identifiers",
        "racine", "racines", "fil", "fils", "identifiant", "identifiants",
    ]

    private func offendingWord(in sentence: String) -> String? {
        if sentence.contains("§") { return "§" }
        let words = sentence.lowercased()
            .split(whereSeparator: { !$0.isLetter && !$0.isNumber })
            .map(String.init)
        return words.first { Self.banned.contains($0) }
    }

    /// L'anglais rendu — celui que lit un utilisateur en anglais, et la clé du
    /// catalogue pour tous les autres.
    @MainActor
    func testNoSettingTooltipSpeaksLikeACommandLine() {
        for spec in SettingKeys.all {
            let sentence = SettingsModel.summary(spec)
            XCTAssertNil(offendingWord(in: sentence),
                         "« \(spec.key) » : l'info-bulle emploie encore un mot "
                         + "de métier — \(sentence)")
        }
    }

    /// Le français du catalogue, c'est-à-dire la phrase réellement affichée.
    @MainActor
    func testTheFrenchTooltipsSpeakTheSameLanguage() throws {
        let catalog = try Self.frenchValues()
        for spec in SettingKeys.all {
            let key = SettingsModel.summary(spec)
            guard let french = catalog[key] else {
                XCTFail("« \(spec.key) » : « \(key) » n'est pas au catalogue")
                continue
            }
            XCTAssertNil(offendingWord(in: french),
                         "« \(spec.key) » : la traduction emploie encore un mot "
                         + "de métier — \(french)")
        }
    }

    /// La CLI n'a pas bougé : ses résumés s'adressent à des dépanneurs, et
    /// c'est `fouine config list` qui les imprime.
    func testTheCommandLineKeepsItsOwnWords() {
        XCTAssertTrue(SettingKeys.pinnedRoots.summary.contains("Identifiers"))
        XCTAssertTrue(SettingKeys.agentOCRBudgetMinutes.summary.contains("OCR"))
    }

    // MARK: - Le catalogue

    private static func frenchValues() throws -> [String: String] {
        let root = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()   // Tests/FouineAppTests
            .deletingLastPathComponent()   // Tests
            .deletingLastPathComponent()
        let url = root.appendingPathComponent(
            "Sources/FouineApp/Resources/Localizable.xcstrings")
        let json = try JSONSerialization.jsonObject(
            with: Data(contentsOf: url)) as? [String: Any]
        let strings = json?["strings"] as? [String: Any] ?? [:]
        var values: [String: String] = [:]
        for (key, entry) in strings {
            guard let entry = entry as? [String: Any],
                  let localizations = entry["localizations"] as? [String: Any],
                  let fr = localizations["fr"] as? [String: Any],
                  let unit = fr["stringUnit"] as? [String: Any],
                  let value = unit["value"] as? String else { continue }
            values[key] = value
        }
        return values
    }
}
