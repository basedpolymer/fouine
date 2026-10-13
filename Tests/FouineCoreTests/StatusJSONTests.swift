// StatusJSONTests.swift — les objets d'état que trois surfaces publient.
// Propriété : A-Core. Lot MC4 (constat PM-32).
//
// Cet objet était dans l'exécutable de la ligne de commande, donc sans test
// unitaire possible : seule la recette d'intégration le voyait. Il est
// maintenant dans le cœur, et c'est cela qu'on fige — le serveur MCP publie
// le MÊME.

import Foundation
import XCTest
@testable import FouineCore

final class StatusJSONTests: XCTestCase {

    func testDiskBudgetIsTheSameObjectForEverySurface() {
        let stats = ["db_bytes": 2_608_754_688, "pages_indexed": 434_372]
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
            StatusJSON.diskForecast(stats: ["db_bytes": 0, "pages_indexed": 0]))
        XCTAssertTrue(json["pages_at_budget"] is NSNull)
        XCTAssertEqual(json["level"] as? String, "ok")
    }
}
