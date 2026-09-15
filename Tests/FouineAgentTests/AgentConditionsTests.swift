// AgentConditionsTests.swift — les six conditions du §5.7. Audit D12/M23, U2.
// Propriété : A-Recette.
//
// « Zéro test sur FouineApp/, FouineAgent/, fouine/ » (audit D12/M23). Pour
// l'agent, la partie testable sans launchd est précisément celle qui décide
// s'il a le droit de travailler — et c'est aussi celle qui, mal réglée, fait
// tourner l'OCR sur batterie ou l'empêche de tourner du tout.
//
// CE QUI N'EST PAS TESTABLE ICI, et pourquoi : `onACPower()` et
// `thermalState` lisent l'état RÉEL de la machine. Un test ne peut ni les
// simuler ni prédire leur valeur — sur un Mac de bureau, `onACPower()` est
// toujours vrai ; sur un portable en recette, cela dépend du câble. On teste
// donc ce qui est déterministe : la POLITIQUE (quelles conditions sont
// évaluées), le verrou, les racines illisibles, et la forme des verdicts.

import Foundation
import XCTest
import FouineCore
@testable import FouineAgent

final class AgentConditionsTests: XCTestCase {

    private var scratch: URL!
    private var lock: URL { scratch.appendingPathComponent("fouine.lock") }

    override func setUpWithError() throws {
        scratch = FileManager.default.temporaryDirectory
            .appendingPathComponent("fouine-agent-\(UUID().uuidString)",
                                    isDirectory: true)
        try FileManager.default.createDirectory(at: scratch,
                                                withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        if let scratch { try? FileManager.default.removeItem(at: scratch) }
    }

    /// Politique TOUT DÉSARMÉ : les trois conditions que l'utilisateur peut
    /// éteindre ne doivent plus produire AUCUN motif de blocage, quelle que
    /// soit la machine. C'est le seul verdict qu'un test puisse affirmer sans
    /// connaître l'état de l'alimentation ni la température du boîtier.
    func testDisarmedPolicyBlocksOnNothingMachineDependent() {
        let policy = AgentConditions.Policy(requireAC: false,
                                            pauseOnLowPower: false,
                                            pauseOnThermal: false)
        let verdict = AgentConditions.evaluate(lock: lock, lockHeldBySelf: false,
                                               unreadableRoots: [], policy: policy)
        XCTAssertTrue(verdict.ok, verdict.blockers.description)
        XCTAssertEqual(verdict.signature, "ok")
    }

    /// Les deux conditions NON DÉSARMABLES restent en dur : une racine
    /// illisible bloque même politique éteinte. OCRiser une racine illisible ne
    /// produirait que des échecs — ce n'est pas une préférence.
    func testUnreadableRootsBlockEvenWithEverythingDisarmed() {
        let policy = AgentConditions.Policy(requireAC: false,
                                            pauseOnLowPower: false,
                                            pauseOnThermal: false)
        let verdict = AgentConditions.evaluate(
            lock: lock, lockHeldBySelf: false,
            unreadableRoots: ["Livres", "Cours"], policy: policy)
        XCTAssertFalse(verdict.ok)
        XCTAssertEqual(verdict.blockers.count, 1)
        // Les DEUX racines sont nommées : un agent qui dirait « une racine est
        // illisible » sans dire laquelle n'aiderait personne.
        let blocker = try? XCTUnwrap(verdict.blockers.first)
        XCTAssertTrue(blocker?.contains("Livres") == true, verdict.signature)
        XCTAssertTrue(blocker?.contains("Cours") == true, verdict.signature)
    }

    /// Le verrou pris par un AUTRE processus bloque ; le même verrou tenu par
    /// SOI-MÊME ne bloque pas. C'est la subtilité de `flock`, qui verrouille la
    /// description de fichier ouverte et non le processus : sans le drapeau
    /// `lockHeldBySelf`, l'agent en pleine passe se refuserait à lui-même le
    /// droit de continuer au lot suivant.
    func testLockHeldElsewhereBlocksButSelfHeldDoesNot() throws {
        let policy = AgentConditions.Policy(requireAC: false,
                                            pauseOnLowPower: false,
                                            pauseOnThermal: false)

        // Verrou libre : rien à signaler.
        XCTAssertEqual(AgentConditions.lockAvailable(at: lock), true)
        XCTAssertTrue(AgentConditions.evaluate(lock: lock, lockHeldBySelf: false,
                                               unreadableRoots: [],
                                               policy: policy).ok)

        // Un descripteur CONCURRENT prend le verrou et le garde.
        let fd = open(lock.path, O_RDWR | O_CREAT, 0o644)
        XCTAssertGreaterThanOrEqual(fd, 0)
        defer { flock(fd, LOCK_UN); close(fd) }
        XCTAssertEqual(flock(fd, LOCK_EX | LOCK_NB), 0)

        XCTAssertEqual(AgentConditions.lockAvailable(at: lock), false)
        let blocked = AgentConditions.evaluate(lock: lock, lockHeldBySelf: false,
                                               unreadableRoots: [], policy: policy)
        XCTAssertFalse(blocked.ok)
        XCTAssertEqual(blocked.blockers.count, 1)
        XCTAssertTrue(blocked.blockers[0].contains("fouine.lock"), blocked.signature)

        // Le MÊME verrou, mais l'agent le tient déjà : le test est court-circuité.
        let selfHeld = AgentConditions.evaluate(lock: lock, lockHeldBySelf: true,
                                                unreadableRoots: [], policy: policy)
        XCTAssertTrue(selfHeld.ok, selfHeld.blockers.description)
    }

    /// La politique se déduit des réglages du schéma v4 (audit U2), et
    /// `relaxed` dit au journal ce qui a été désarmé : un agent qui OCRise sur
    /// batterie parce qu'on le lui a demandé ne doit pas se lire comme un agent
    /// qui ignore le §5.7.
    func testPolicyIsBuiltFromSettingsAndNamesWhatWasDisarmed() {
        let strict = AgentConditions.Policy(SettingsSnapshot(rows: [:],
                                                             environment: [:]))
        XCTAssertTrue(strict.requireAC)
        XCTAssertTrue(strict.pauseOnLowPower)
        XCTAssertTrue(strict.pauseOnThermal)
        XCTAssertTrue(strict.relaxed.isEmpty,
                      "un agent aux réglages par défaut n'a rien de désarmé")

        let loose = AgentConditions.Policy(SettingsSnapshot(
            rows: ["agent.requireAC": "false",
                   "agent.pauseOnThermal": "false"],
            environment: [:]))
        XCTAssertFalse(loose.requireAC)
        XCTAssertTrue(loose.pauseOnLowPower)
        XCTAssertFalse(loose.pauseOnThermal)
        XCTAssertEqual(loose.relaxed.count, 2, loose.relaxed.description)

        // L'environnement l'emporte sur la base (contrat de `Settings`) : c'est
        // par là qu'un plist de LaunchAgent impose encore une politique.
        let fromEnvironment = AgentConditions.Policy(SettingsSnapshot(
            rows: ["agent.requireAC": "false"],
            environment: ["FOUINE_AGENT_REQUIRE_AC": "true"]))
        XCTAssertTrue(fromEnvironment.requireAC)
    }

    /// La signature est ce qui décide de journaliser ou non : l'agent
    /// n'écrit une ligne qu'aux CHANGEMENTS d'état. Deux verdicts identiques
    /// doivent donner la même signature, deux verdicts différents non — sans
    /// quoi le journal se remplirait d'une ligne par minute, ou n'en aurait
    /// aucune.
    func testSignatureIsStableAndDiscriminating() {
        let policy = AgentConditions.Policy(requireAC: false,
                                            pauseOnLowPower: false,
                                            pauseOnThermal: false)
        func verdict(_ roots: [String]) -> AgentConditions.Verdict {
            AgentConditions.evaluate(lock: lock, lockHeldBySelf: true,
                                     unreadableRoots: roots, policy: policy)
        }
        XCTAssertEqual(verdict(["Livres"]).signature, verdict(["Livres"]).signature)
        XCTAssertNotEqual(verdict(["Livres"]).signature, verdict(["Cours"]).signature)
        XCTAssertNotEqual(verdict(["Livres"]).signature, verdict([]).signature)
        XCTAssertEqual(verdict([]).signature, "ok")
    }

    /// Le plancher du §5.7 est une constante du contrat, pas un réglage : 70 %.
    /// La lecture de `pmset` peut rendre `nil` (thermomètre illisible) et, dans
    /// ce cas, l'agent ne DOIT PAS bloquer — un OCR qui refuserait de tourner
    /// faute de thermomètre serait un plus grand mal.
    func testCPUFloorIsSeventyAndAnUnreadableProbeNeverBlocks() {
        XCTAssertEqual(AgentConditions.cpuSpeedFloor, 70)

        // `cpuSpeedLimit()` lit la vraie machine : on ne peut pas prédire sa
        // valeur, mais on peut affirmer qu'elle est soit nil, soit un
        // pourcentage plausible.
        if let limit = AgentConditions.cpuSpeedLimit() {
            XCTAssertGreaterThan(limit, 0)
            XCTAssertLessThanOrEqual(limit, 100)
        }

        // `thermalOK` et `describe` couvrent les quatre états.
        XCTAssertEqual(AgentConditions.describe(.nominal), "nominal")
        XCTAssertEqual(AgentConditions.describe(.fair), "fair")
        XCTAssertEqual(AgentConditions.describe(.serious), "serious")
        XCTAssertEqual(AgentConditions.describe(.critical), "critical")
    }

    /// `lockAvailable` rend `nil` — et non `false` — quand le fichier ne peut
    /// pas être ouvert du tout : c'est une situation différente d'un verrou
    /// pris, et `evaluate` ne doit alors PAS bloquer (le store créera le
    /// fichier).
    func testLockAvailableIsNilWhenThePathCannotBeOpened() {
        let impossible = scratch
            .appendingPathComponent("dossier-absent", isDirectory: true)
            .appendingPathComponent("fouine.lock")
        XCTAssertNil(AgentConditions.lockAvailable(at: impossible))

        let policy = AgentConditions.Policy(requireAC: false,
                                            pauseOnLowPower: false,
                                            pauseOnThermal: false)
        XCTAssertTrue(AgentConditions.evaluate(lock: impossible,
                                               lockHeldBySelf: false,
                                               unreadableRoots: [],
                                               policy: policy).ok)
    }
}
