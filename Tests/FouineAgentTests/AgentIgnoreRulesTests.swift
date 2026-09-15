// AgentIgnoreRulesTests.swift — l'agent reparcourt une racine dont les règles
// gardées ont changé (lot IG2). Propriété : A-Recette.
//
// Une règle saisie dans les réglages ne touche aucun fichier, donc ne remonte
// aucun événement FSEvents : sans cette décision, elle attendrait qu'un
// document de la racine change.

import XCTest
@testable import FouineAgent

final class AgentIgnoreRulesTests: XCTestCase {

    func testAtStartEveryRootCarryingRulesIsWalked() {
        // Des règles ont pu être saisies pendant que l'agent était arrêté.
        XCTAssertEqual(Agent.rootsWithChangedIgnoreRules(
            previous: nil, current: [1: #"["Santé/"]"#, 3: #"["*.md"]"#]), [1, 3])
        XCTAssertEqual(Agent.rootsWithChangedIgnoreRules(previous: nil, current: [:]), [])
    }

    func testOnlyTheRootsWhoseRulesChangedAreWalked() {
        let before: [Int64: String] = [1: #"["Santé/"]"#, 2: #"["*.md"]"#]
        XCTAssertEqual(Agent.rootsWithChangedIgnoreRules(previous: before, current: before),
                       [], "rien n'a changé : aucun parcours")
        XCTAssertEqual(Agent.rootsWithChangedIgnoreRules(
            previous: before,
            current: [1: #"["Santé/","INDEX.md"]"#, 2: #"["*.md"]"#, 4: #"["x/"]"#]),
            [1, 4], "une règle ajoutée, une racine qui en reçoit")
        XCTAssertEqual(Agent.rootsWithChangedIgnoreRules(
            previous: before, current: [2: #"["*.md"]"#]),
            [1], "toutes les règles retirées : les documents reviennent, il faut parcourir")
    }
}
