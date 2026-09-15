// AppSourceSettingsTests.swift — les clés des sources applicatives et le
// dossier où Fouine recopie les notes (lots INT-F4, AN1). Propriété : A-Core.
//
// Ce que ces tests protègent : les sources sont ÉTEINTES par défaut (allumer
// copie des données personnelles d'une autre application), et le dossier des
// copies suit `FOUINE_DB` — c'est ce qui rend impossible, depuis un test ou la
// recette, une écriture dans le dossier réel de l'utilisateur.

import Foundation
import XCTest
@testable import FouineCore

final class AppSourceSettingsTests: XCTestCase {

    func testSourcesAreOffByDefaultAndListedLast() {
        let snapshot = SettingsSnapshot.environmentOnly([:])
        XCTAssertFalse(snapshot.sourceNotes)
        XCTAssertFalse(snapshot.sourceBear)
        XCTAssertFalse(snapshot.sourceAnki)
        XCTAssertFalse(snapshot.anySourceEnabled)

        let keys = SettingKeys.all.map(\.key)
        XCTAssertEqual(Array(keys.suffix(3)),
                       ["sources.notes", "sources.bear", "sources.anki"],
                       "les clés neuves vont à la FIN du catalogue")
        XCTAssertNotNil(SettingKeys.spec(for: "sources.notes"))
        XCTAssertNotNil(SettingKeys.spec(for: "sources.bear"))
        XCTAssertNotNil(SettingKeys.spec(for: "sources.anki"))
    }

    func testDatabaseAndEnvironmentTurnASourceOn() {
        let fromDatabase = SettingsSnapshot(rows: ["sources.notes": "true"],
                                            environment: [:])
        XCTAssertTrue(fromDatabase.sourceNotes)
        XCTAssertFalse(fromDatabase.sourceBear)
        XCTAssertTrue(fromDatabase.anySourceEnabled)

        let forced = SettingsSnapshot(rows: ["sources.bear": "false"],
                                      environment: ["FOUINE_SOURCE_BEAR": "1"])
        XCTAssertTrue(forced.sourceBear, "la variable l'emporte sur la base")
        XCTAssertEqual(forced.effective(SettingKeys.sourceBear).source, .environment)

        // Anki seul suffit à réveiller la synchronisation de la passe.
        let anki = SettingsSnapshot(rows: [:], environment: ["FOUINE_SOURCE_ANKI": "1"])
        XCTAssertTrue(anki.sourceAnki)
        XCTAssertTrue(anki.anySourceEnabled)
    }

    /// Le dossier des copies est TOUJOURS à côté de la base ouverte : avec
    /// `FOUINE_DB` sur une copie jetable, aucun code ne peut écrire dans le
    /// dossier réel de l'utilisateur.
    func testSourcesDirectoryFollowsTheDatabase() {
        let database = URL(fileURLWithPath: "/tmp/essai-f4/index.db")
        let directory = FouinePaths.sourcesDirectory(for: database)
        XCTAssertEqual(directory.lastPathComponent, "Sources")
        XCTAssertEqual(directory.deletingLastPathComponent().path, "/tmp/essai-f4")
    }
}
