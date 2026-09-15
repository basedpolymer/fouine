// OpenDiagnosisTests.swift — ce que dit une ouverture en lecture qui échoue
// (constats CM-06, CM-20). Propriété : A-Core.
//
// Un seul message générique couvrait trois causes distinctes : un répertoire
// désigné par `FOUINE_DB`, un `.db` recopié seul, un vrai journal à reprendre.
// Les deux premiers envoyaient l'utilisateur lancer `fouine maintain` en
// affirmant qu'un programme avait planté.

import XCTest
@testable import FouineCore

final class OpenDiagnosisTests: XCTestCase {

    private var scratch: URL!

    override func setUpWithError() throws {
        scratch = FileManager.default.temporaryDirectory
            .appendingPathComponent("fouine-open-\(UUID().uuidString)",
                                    isDirectory: true)
        try FileManager.default.createDirectory(at: scratch,
                                                withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: scratch)
    }

    private func failure(opening url: URL) -> String? {
        do {
            try GRDBStore().openReadOnly(at: url)
            return nil
        } catch let FouineError.databaseFailure(message) {
            return message
        } catch {
            XCTFail("attendu .databaseFailure, obtenu \(error)")
            return nil
        }
    }

    /// CM-20 : `FOUINE_DB` posé sur un DOSSIER. Le refus doit nommer la faute,
    /// pas proposer de reprendre un journal.
    func testAFolderIsNotAnIndex() throws {
        let message = try XCTUnwrap(failure(opening: scratch))
        XCTAssertTrue(message.contains("is a folder, not a Fouine index"), message)
        XCTAssertFalse(message.contains("maintain"),
                       "on n'envoie pas réparer un dossier : \(message)")
    }

    /// CM-06 : le `.db` recopié SEUL (`cp`, Time Machine, un autre Mac). Rien
    /// n'a planté, et le geste porte la variable — `fouine maintain` tout court
    /// réparerait l'autre base.
    func testAPlainCopyOfTheDatabaseSaysSo() throws {
        let source = scratch.appendingPathComponent("source.db")
        let store = GRDBStore()
        try store.open(at: source)
        try store.writeAgentStatus(AgentStatusRecord(phase: .idle))
        // Le `.db` doit se suffire à lui-même AVANT la copie, sinon on copierait
        // une base à qui il manque son contenu et non une base complète privée
        // de ses compagnons : `maintain` termine par un
        // `wal_checkpoint(TRUNCATE)`.
        _ = try store.maintain()
        store.releaseWriteLock()

        // La copie du SEUL `.db`, sans ses compagnons : c'est exactement ce que
        // fait `cp`, une restauration Time Machine ou un transfert.
        let copy = scratch.appendingPathComponent("copie.db")
        try FileManager.default.copyItem(at: source, to: copy)
        XCTAssertFalse(FileManager.default.fileExists(atPath: copy.path + "-wal"),
                       "la copie ne doit pas emporter de -wal")

        let message = try XCTUnwrap(failure(opening: copy))
        XCTAssertTrue(message.contains("was made without its -wal and -shm"), message)
        XCTAssertTrue(message.contains("FOUINE_DB=\(copy.path) fouine maintain"),
                      message)
        XCTAssertFalse(message.contains("after a crash"),
                       "rien n'a planté : \(message)")

        // Et le geste répare RÉELLEMENT : une ouverture en écriture reprend le
        // journal, la lecture passe ensuite.
        let repair = GRDBStore()
        try repair.open(at: copy)
        repair.releaseWriteLock()
        XCTAssertNil(failure(opening: copy),
                     "après une ouverture en écriture, la copie doit se lire")
    }

    /// Contre-épreuve : une base ABSENTE garde sa phrase à elle, celle qui
    /// donne le geste d'indexation.
    func testAMissingIndexKeepsItsOwnMessage() throws {
        let missing = scratch.appendingPathComponent("nulle-part.db")
        let message = try XCTUnwrap(failure(opening: missing))
        XCTAssertEqual(message, GRDBStore.noIndexMessage(at: missing.path))
    }
}
