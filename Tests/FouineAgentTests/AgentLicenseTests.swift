// AgentLicenseTests.swift — un essai fini fait taire l'agent (lot L1C).
// Propriété : A-Pack.
//
// `Agent.tick` est pure : ces cas se jouent en mémoire. Le seul qui touche le
// disque est le dernier, qui vérifie que le verdict lu dans un vrai fichier de
// licence est bien celui que `tick` reçoit.

import XCTest
import FouineCore
import FouineLicense
@testable import FouineAgent

final class AgentLicenseTests: XCTestCase {

    private let settings = SettingsSnapshot(rows: [:], environment: [:])
    private let ok = AgentConditions.Verdict(ok: true, blockers: [])

    private func tick(licence: Bool, state: AgentState = AgentState(),
                      clock: Date = Date(),
                      queue: Int = 120,
                      pending: Set<Int64> = [7])
        -> (action: AgentAction, nextState: AgentState) {
        Agent.tick(state: state, conditions: ok, clock: clock,
                   settings: settings, ocrQueueLength: queue,
                   pendingRoots: pending, embed: .none,
                   licenceAllowsIndexing: licence)
    }

    /// LE CAS QUI COMPTE : des racines à extraire, une file d'OCR pleine, les
    /// six conditions du §5.7 réunies — et l'essai fini. L'agent ne lance rien.
    func testATrialThatIsOverStopsEveryPieceOfWork() {
        let (action, _) = tick(licence: false)
        XCTAssertEqual(action, .noteLicenceBlocked)
    }

    /// Et il ne le redit pas à chaque tic : une ligne par jour au plus.
    func testTheJournalSaysItOnceADayAtMost() {
        let start = Date(timeIntervalSince1970: 1_800_000_000)
        let (first, afterFirst) = tick(licence: false, clock: start)
        XCTAssertEqual(first, .noteLicenceBlocked)
        XCTAssertEqual(afterFirst.lastLicenceNoticeAt, start)

        let (soon, _) = tick(licence: false, state: afterFirst,
                             clock: start.addingTimeInterval(3600))
        XCTAssertEqual(soon, .none, "une ligne par minute remplirait le journal")

        let (tomorrow, _) = tick(licence: false, state: afterFirst,
                                 clock: start.addingTimeInterval(86_401))
        XCTAssertEqual(tomorrow, .noteLicenceBlocked)
    }

    /// Une clé activée depuis l'application remet l'agent au travail au tic
    /// suivant, sans redémarrage de launchd.
    func testAValidLicenceLetsTheAgentWorkAgain() {
        let (action, _) = tick(licence: true)
        XCTAssertEqual(action, .runExtraction(rootIDs: [7]))
    }

    /// Le verdict vient bien du FICHIER, et un fichier absent laisse travailler
    /// (essai réputé neuf) : un agent qui se tairait faute de fichier
    /// couperait l'indexation de tout le monde à la première mise à jour.
    func testTheVerdictComesFromTheLicenceFileOnDisk() throws {
        let scratch = FileManager.default.temporaryDirectory
            .appendingPathComponent("fouine-agent-licence-\(UUID().uuidString)",
                                    isDirectory: true)
        try FileManager.default.createDirectory(at: scratch,
                                                withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: scratch) }
        let url = LicenseStore.fileURL(
            databaseURL: scratch.appendingPathComponent("copie.db"))

        XCTAssertTrue(
            LicenseState.compute(file: LicenseStore.load(at: url)).allowsIndexing,
            "sans fichier, l'agent travaille")

        try LicenseStore.save(
            LicenseFile(trialStarted: Date().addingTimeInterval(-60 * 86_400)),
            to: url)
        XCTAssertFalse(
            LicenseState.compute(file: LicenseStore.load(at: url)).allowsIndexing,
            "essai vieux de 60 jours : l'agent se tait")
    }
}
