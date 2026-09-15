// StatusJSONTests.swift — les objets d'état que trois surfaces publient.
// Propriété : A-Core. Lot MC4 (constat PM-32).
//
// Ces objets étaient dans l'exécutable de la ligne de commande, donc sans
// test unitaire possible : seule la recette d'intégration les voyait. Ils
// sont maintenant dans le cœur, et c'est cela qu'on fige — le serveur MCP
// publie les MÊMES.

import Foundation
import XCTest
@testable import FouineCore

final class StatusJSONTests: XCTestCase {

    func testPagesLeftIsWhatTheCampaignStillOwes() {
        XCTAssertEqual(StatusJSON.meaningPagesLeft(
            ["pages_indexed": 434_372, "pages_vec_complete": 294_734]), 139_638)
        // Jamais négatif : une base dont la complétude dépasse le compte de
        // pages (réindexation en cours) ne doit pas rendre « -3 pages ».
        XCTAssertEqual(StatusJSON.meaningPagesLeft(
            ["pages_indexed": 10, "pages_vec_complete": 13]), 0)
        XCTAssertEqual(StatusJSON.meaningPagesLeft([:]), 0)
    }

    func testMeaningBackgroundSaysWhatTheAgentPrepares() {
        // Des valeurs qui NE SONT PAS les défauts, sans quoi le test passerait
        // sans rien lire des réglages.
        let settings = SettingsSnapshot(rows: [
            "agent.prepareMeaning": "false",
            "agent.embedBudgetMinutes": "25",
            "agent.lastEmbedBatchAt": "1757000000",
        ])
        let json = StatusJSON.meaningJSON(
            settings: settings,
            stats: ["pages_indexed": 100, "pages_vec_complete": 40])
        XCTAssertEqual(json["enabled"] as? Bool, false)
        XCTAssertEqual(json["budget_minutes"] as? Int, 25)
        XCTAssertEqual(json["pages_left"] as? Int, 60)
        XCTAssertEqual(json["last_batch"] as? String, "2025-09-04T15:33:20Z")
    }

    /// `0` se lirait comme 1970 : tant qu'aucun lot n'a tourné, la clé est
    /// nulle — et elle est PRÉSENTE, comme partout ailleurs dans ce contrat.
    func testNoBatchYetIsNullRatherThanNineteenSeventy() {
        let json = StatusJSON.meaningJSON(settings: SettingsSnapshot(rows: [:]),
                                          stats: [:])
        XCTAssertTrue(json.keys.contains("last_batch"))
        XCTAssertTrue(json["last_batch"] is NSNull)
    }

    func testDiskBudgetIsTheSameObjectForEverySurface() {
        let stats = ["db_bytes": 2_608_754_688, "pages_indexed": 434_372,
                     "pages_vec_complete": 294_734]
        let json = StatusJSON.diskBudgetJSON(StatusJSON.diskForecast(stats: stats))
        XCTAssertEqual(json["bytes"] as? Int, 2_608_754_688)
        // Au-delà du budget : c'est l'état de la base du propriétaire le
        // 13/09/2026, et c'est ce que le serveur MCP taisait.
        XCTAssertEqual(json["level"] as? String, "over")
        // Les ratios passent par `JSONNumber.rounded`, jamais par un Double
        // arrondi à la main (artefacts `1.0435999999`).
        let ratio = try? XCTUnwrap(json["ratio_now"] as? NSNumber)
        XCTAssertEqual(ratio?.doubleValue ?? 0, 1.044, accuracy: 0.0005)
        XCTAssertFalse(String(describing: json["ratio_now"] ?? "").contains("9999"))
    }

    /// Un index vide n'a pas de coût par page à extrapoler, et `0` se lirait
    /// comme « budget déjà atteint ».
    func testAnEmptyIndexHasNoPageCountToExtrapolate() {
        let json = StatusJSON.diskBudgetJSON(
            StatusJSON.diskForecast(stats: ["db_bytes": 0, "pages_indexed": 0,
                                            "pages_vec_complete": 0]))
        XCTAssertTrue(json["pages_at_budget"] is NSNull)
        XCTAssertEqual(json["level"] as? String, "ok")
    }
}
