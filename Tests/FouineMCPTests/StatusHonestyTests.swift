// StatusHonestyTests.swift — ce que `fouine_status` doit dire, et ne plus
// taire (lot MC4 : PM-17, PM-32, PM-05).
// SPDX-License-Identifier: LicenseRef-Fouine-Source-Available
//
// LA CONTRADICTION QU'ON FIGE ICI. Le 13/09/2026, sur la même machine et à la
// même seconde : launchd répondait « Could not find service », `fouine status
// --json` disait `alive: false, stale: true`, et `fouine_status` disait
// `healthy: true` en publiant dans le même souffle
// `report_detail: "SIGTERM received"`. Deux surfaces, une seule table.

import Foundation
import XCTest
import FouineCore
import FouineMCP
import FouineMCPKit

final class StatusHonestyTests: XCTestCase {

    private func statusTool(_ index: TempIndex,
                            probe: @escaping () -> LaunchdAgentResult
                                = { .notRegistered }) -> StatusTool {
        let store = ReadOnlyStore(path: index.databaseURL)
        return StatusTool(store: store,
                          semantic: SemanticEngine(store: store,
                                                   modelDirectory: index.directory),
                          modelDirectory: index.directory, launchdProbe: probe)
    }

    // MARK: - L'agent (PM-17)

    func testAnAgentThatFellOverIsNotHealthy() throws {
        let index = try TempIndex(agentStatus: AgentStatusRecord(
            phase: .stopped, detail: "signal-received(SIGTERM)",
            updatedAt: Date().addingTimeInterval(-93), pid: 72_830))
        let agent = try XCTUnwrap(
            statusTool(index).call(arguments: [:]).structured["agent"]
                as? [String: Any])

        XCTAssertEqual(agent["healthy"] as? Bool, false)
        // `alive` et `stale` sont CEUX de la ligne de commande : c'est la
        // contradiction qui disparaît, pas une seconde lecture de la table.
        XCTAssertEqual(agent["alive"] as? Bool, false)
        XCTAssertEqual(agent["stale"] as? Bool, true)
        XCTAssertEqual(agent["report_detail"] as? String, "SIGTERM received")
        XCTAssertEqual(agent["report_phase"] as? String, "stopped")
        // L'ÂGE, à la seconde près mais pas à la seconde figée : entre la
        // fabrication de la base et l'appel, une machine chargée passe la
        // seconde suivante, et le test rougissait sur « 94 ≠ 93 » (lot BT1).
        // Ce qui compte est que l'âge soit PUBLIÉ et CALCULÉ depuis
        // `updatedAt` — ni nul, ni absent, ni l'instant présent.
        let age = try XCTUnwrap(agent["last_report_seconds"] as? Int)
        XCTAssertGreaterThanOrEqual(age, 93, "âge publié : \(age) s")
        XCTAssertLessThan(age, 120, "âge publié : \(age) s")
    }

    /// Aucun rapport : personne n'a jamais armé la mise à jour automatique, ou
    /// l'utilisateur l'a éteinte. Ce n'est pas une panne, et le dire panne
    /// ferait alarmer sur un réglage assumé.
    func testAnAgentThatNeverRanIsNotAFault() throws {
        // La base doit rester VIVANTE le temps de l'appel : son `deinit` efface
        // le dossier, et `ReadOnlyStore` n'ouvre qu'à la première lecture.
        let index = try TempIndex()
        let agent = try XCTUnwrap(
            statusTool(index).call(arguments: [:]).structured["agent"]
                as? [String: Any])
        XCTAssertEqual(agent["healthy"] as? Bool, true)
        XCTAssertNil(agent["alive"])
        XCTAssertNil(agent["stale"])
    }

    // MARK: - Le budget et la campagne (PM-32)

    func testTheTwoObjectsAnAssistantNeedsBeforeAdvisingEmbed() throws {
        let index = try TempIndex()
        let structured = try statusTool(index).call(arguments: [:]).structured

        let budget = try XCTUnwrap(structured["disk_budget"] as? [String: Any])
        XCTAssertEqual(budget["budget_bytes"] as? Int, 2_500_000_000)
        XCTAssertEqual(budget["level"] as? String, "ok")

        let meaning = try XCTUnwrap(structured["meaning_background"] as? [String: Any])
        // Six pages indexées, aucune vectorisée : tout reste à faire.
        XCTAssertEqual(meaning["pages_left"] as? Int, 6)
        XCTAssertTrue(meaning.keys.contains("last_batch"))
    }

    // MARK: - La couverture par racine (PM-05)

    func testEachRootSaysWhatTheMeaningChannelSeesOfIt() throws {
        // Les deux documents de la base sont sous `Livres` ; `Archives` est
        // déclarée et vide, ce qui est le cas d'une racine dont le volume vient
        // d'être ajouté.
        let index = try TempIndex(vectorisedPages: 2,
                                  roots: ["Livres", "Archives"])
        let roots = try XCTUnwrap(
            statusTool(index).call(arguments: [:]).structured["roots"]
                as? [[String: Any]])
        let byLabel = Dictionary(uniqueKeysWithValues:
            roots.compactMap { root -> (String, [String: Any])? in
                (root["label"] as? String).map { ($0, root) }
            })

        let livres = try XCTUnwrap(byLabel["Livres"])
        XCTAssertEqual(livres["pages"] as? Int, 6)
        XCTAssertEqual(livres["vectorised_pages"] as? Int, 2)
        XCTAssertEqual((livres["coverage_pct"] as? NSNumber)?.doubleValue, 33.33)

        // C'est CE cas qui justifie la clé : une racine à 0 % que la couverture
        // globale (33 %) laisserait croire à demi couverte.
        let archives = try XCTUnwrap(byLabel["Archives"])
        XCTAssertEqual(archives["pages"] as? Int, 0)
        XCTAssertEqual((archives["coverage_pct"] as? NSNumber)?.doubleValue, 0)
    }

    /// `include_roots: false` coupe VRAIMENT la couverture par racine : c'est
    /// le poste le plus cher de l'outil, et le couper à l'habillage aurait
    /// laissé payer le prix sans rendre la réponse.
    func testIncludeRootsFalseCostsNothing() throws {
        let index = try TempIndex(roots: ["Livres"])
        let structured = try statusTool(index)
            .call(arguments: ["include_roots": false]).structured
        XCTAssertNil(structured["roots"])
    }
}
