// SpotlightSettingsTests.swift — la section Spotlight de la fenêtre de
// réglages (lot INT-S1). Propriété : A-App.
//
// La vue ne se teste pas ; ce qui se teste est le MODÈLE qu'elle affiche :
// les trois réglages existent, ont les défauts annoncés, s'écrivent dans la
// table `settings` (et non dans les préférences de l'application, que l'agent
// ne lit pas), et chacun a une phrase dans la langue de l'utilisateur.

import Foundation
import XCTest
import FouineCore
@testable import FouineApp

@MainActor
final class SpotlightSettingsTests: XCTestCase {

    private var keys: [SettingSpec] {
        [SettingKeys.spotlightEnabled, SettingKeys.spotlightAllDocuments,
         SettingKeys.spotlightTextKB]
    }

    /// Attend qu'une condition devienne vraie, par pas de 10 ms.
    ///
    /// Deux tests de ce fichier dormaient 300 et 400 ms « pour laisser le
    /// temps » : c'était 0,7 s payée à chaque passe, et la borne devenait
    /// FAUSSE sous charge — une machine occupée peut écrire plus tard que
    /// 300 ms (lot BT1). Une condition rend la main dès l'écriture et laisse
    /// une marge très large avant de conclure à l'échec.
    private func settle(upTo seconds: TimeInterval = 5,
                        _ what: String,
                        until condition: () throws -> Bool,
                        file: StaticString = #filePath,
                        line: UInt = #line) async throws {
        let deadline = Date().addingTimeInterval(seconds)
        while Date() < deadline {
            if try condition() { return }
            try await Task.sleep(nanoseconds: 10_000_000)
        }
        XCTFail("\(what) : rien en \(seconds) s", file: file, line: line)
    }

    func testTheThreeSettingsAreExposedWithTheirDefaults() async throws {
        let db = try TempAppDB()
        let model = SettingsModel(service: db.service)
        await model.load()

        XCTAssertTrue(model.bool(SettingKeys.spotlightEnabled),
                      "montrer les documents dans Spotlight est la promesse du "
                      + "produit : allumé par défaut")
        XCTAssertFalse(model.bool(SettingKeys.spotlightAllDocuments),
                       "par défaut, seulement ce que Spotlight ne lit pas")
        XCTAssertEqual(model.int(SettingKeys.spotlightTextKB), 1_024)
    }

    func testEachSettingHasASentenceForTheUser() {
        for spec in keys {
            let sentence = SettingsModel.summary(spec)
            XCTAssertFalse(sentence.isEmpty)
            XCTAssertNotEqual(sentence, spec.summary,
                              "\(spec.key) doit avoir sa phrase traduisible, et "
                              + "non celle que la CLI imprime")
        }
    }

    func testScopeIsWrittenToTheSettingsTable() async throws {
        let db = try TempAppDB()
        let model = SettingsModel(service: db.service)
        await model.load()

        model.setSpotlightAllDocuments(true)
        try await settle("le réglage n'est pas arrivé dans la table") {
            try db.store.settingsRows()[SettingKeys.spotlightAllDocuments.key] != nil
        }

        let rows = try db.store.settingsRows()
        XCTAssertEqual(rows[SettingKeys.spotlightAllDocuments.key], "true",
                       "l'agent doit lire le même réglage : la table `settings`, "
                       + "pas les préférences de l'application")
    }

    // MARK: - La preuve qu'un don a eu lieu (audit BU-26)

    /// Un don à Spotlight était invérifiable : `mdfind` n'interroge pas Core
    /// Spotlight, le journal ne dit rien des succès, et le dossier de
    /// Spotlight est protégé. La phrase sous les deux boutons est désormais la
    /// seule preuve visible — elle doit donc dire les trois états.
    func testTheHandoverLineSaysTheThreeStates() {
        XCTAssertEqual(SettingsModel.handoverSummary(at: 0, count: 0),
                       String(localized: "Not handed over yet"))

        // Une remise faite par une version antérieure à ce lot n'a pas de
        // compte : la date seule vaut mieux que rien.
        let dated = SettingsModel.handoverSummary(at: 1_757_000_000, count: 0)
        XCTAssertFalse(dated.contains("·"), dated)
        XCTAssertNotEqual(dated, String(localized: "Not handed over yet"))

        let full = SettingsModel.handoverSummary(at: 1_757_000_000, count: 1_527)
        XCTAssertTrue(full.hasPrefix(dated), full)
        XCTAssertTrue(full.contains("1"), full)
        XCTAssertTrue(full.contains("·"), full)
    }

    /// Les deux marqueurs sont hors du catalogue `all` : ils ne passent donc
    /// pas par `values`, et la fenêtre les lit dans les lignes brutes.
    func testTheWindowReadsBothMarkers() async throws {
        let db = try TempAppDB()
        try db.store.writeSetting(SettingKeys.spotlightSyncedAt.key, "1757000000")
        try db.store.writeSetting(SettingKeys.spotlightSyncedCount.key, "1527")
        let model = SettingsModel(service: db.service)
        await model.load()

        XCTAssertEqual(model.spotlightHandover.count, 1_527)
        XCTAssertEqual(model.spotlightHandoverSummary,
                       SettingsModel.handoverSummary(at: 1_757_000_000,
                                                     count: 1_527))
    }

    /// Le retrait dit le RETRAIT : il annonçait « Spotlight est à jour », le
    /// message du bouton voisin (audit BU-25).
    func testRemovalAnnouncesTheRemoval() async throws {
        let db = try TempAppDB()
        let model = SettingsModel(service: db.service)
        await model.load()

        model.removeFromSpotlight()
        try await settle("le retrait n'a rien annoncé") { model.notice != nil }

        XCTAssertEqual(model.notice,
                       String(localized: "Fouine's documents have been removed from Spotlight."))
        // Et l'alerte porte un titre qui dit de quoi elle parle.
        XCTAssertEqual(model.noticeTitle, String(localized: "Spotlight"))
    }

    func testSpotlightIsUnavailableOutsideTheInstalledApplication() async throws {
        let db = try TempAppDB()
        let model = SettingsModel(service: db.service)
        // `swift test` n'est pas Fouine.app : la section reste affichée, mais
        // figée, et son aide dit pourquoi.
        XCTAssertFalse(model.spotlightAvailable)
        XCTAssertTrue(model.spotlightHelp.contains("installed application"))
    }
}
