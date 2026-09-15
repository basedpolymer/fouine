// IgnoreRulesStoreTests.swift — les règles d'exclusion gardées par racine,
// `roots.ignore_rules` (lot IG2). Propriété : A-Core.
//
// Ce que ces tests protègent :
//   · une base neuve naît avec la colonne, et sans règle ;
//   · les règles se gardent PAR RACINE, se relisent, s'effacent en NULL ;
//   · `removeRoot` les emporte, et un dossier ré-ajouté ne retrouve pas de
//     règles fantômes ; désactiver une racine les garde ;
//   · une base v9 créée AVANT ce lot s'ouvre sans rien écrire, se lit sans la
//     colonne, et ne la reçoit qu'à la première règle — `schema_version` ne
//     bouge pas ;
//   · les ouvertures en lecture seule lisent les deux formes, et n'écrivent
//     jamais ;
//   · écrire une règle ne prend pas `fouine.lock` (décision de l'en-tête de
//     `GRDBStore+IgnoreRules.swift`).

import Foundation
import XCTest
@testable import FouineCore

final class IgnoreRulesStoreTests: XCTestCase {

    private var scratch: URL!
    private var databaseURL: URL { scratch.appendingPathComponent("fouine.db") }

    override func setUpWithError() throws {
        scratch = FileManager.default.temporaryDirectory
            .appendingPathComponent("fouine-ignore-store-\(UUID().uuidString)",
                                    isDirectory: true)
        try FileManager.default.createDirectory(at: scratch,
                                                withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        if let scratch { try? FileManager.default.removeItem(at: scratch) }
    }

    private func makeFolder(_ name: String) throws -> URL {
        let url = scratch.appendingPathComponent(name, isDirectory: true)
        try FileManager.default.createDirectory(at: url,
                                                withIntermediateDirectories: true)
        try "contenu".write(to: url.appendingPathComponent("a.txt"),
                            atomically: true, encoding: .utf8)
        return url
    }

    private func sqlite(_ statement: String) throws -> String {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/sqlite3")
        process.arguments = [databaseURL.path, statement]
        let out = Pipe(), err = Pipe()
        process.standardOutput = out
        process.standardError = err
        try process.run()
        let data = out.fileHandleForReading.readDataToEndOfFile()
        let message = String(decoding: err.fileHandleForReading.readDataToEndOfFile(),
                             as: UTF8.self)
        process.waitUntilExit()
        guard process.terminationStatus == 0 else {
            throw NSError(domain: "IgnoreRulesStore", code: 1, userInfo: [
                NSLocalizedDescriptionKey: "sqlite3 a refusé : \(message)"])
        }
        return String(decoding: data, as: UTF8.self)
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private func hasColumn() throws -> Bool {
        try sqlite("SELECT count(*) FROM pragma_table_info('roots') "
                   + "WHERE name='ignore_rules'") == "1"
    }

    private func openStore() throws -> GRDBStore {
        let store = GRDBStore()
        try store.open(at: databaseURL)
        return store
    }

    // MARK: - Base neuve

    func testAFreshDatabaseCarriesTheColumnAndNoRule() throws {
        let store = try openStore()
        defer { store.releaseWriteLock() }
        let id = try store.addRoot(path: try makeFolder("Perso"), label: nil)
        XCTAssertTrue(try hasColumn())
        XCTAssertNil(try store.ignoreRulesJSON(rootID: id))
        XCTAssertEqual(try store.ignoreRulesJSONByRoot(), [:])
    }

    func testRulesAreKeptPerRootAndReadBack() throws {
        let store = try openStore()
        defer { store.releaseWriteLock() }
        let perso = try store.addRoot(path: try makeFolder("Perso"), label: nil)
        let livres = try store.addRoot(path: try makeFolder("Livres"), label: nil)

        try store.setIgnoreRulesJSON(rootID: perso, #"["Santé/","*.md"]"#)
        XCTAssertEqual(try store.ignoreRulesJSON(rootID: perso), #"["Santé/","*.md"]"#)
        XCTAssertNil(try store.ignoreRulesJSON(rootID: livres))
        XCTAssertEqual(try store.ignoreRulesJSONByRoot(), [perso: #"["Santé/","*.md"]"#])

        try store.setIgnoreRulesJSON(rootID: perso, nil)
        XCTAssertEqual(try sqlite("SELECT ignore_rules IS NULL FROM roots WHERE id=\(perso)"),
                       "1", "aucune règle : NULL, une seule forme")
        XCTAssertEqual(try store.ignoreRulesJSONByRoot(), [:])
    }

    func testAnUnknownRootIsRefused() throws {
        let store = try openStore()
        XCTAssertThrowsError(try store.setIgnoreRulesJSON(rootID: 999, #"["x/"]"#)) {
            XCTAssertTrue("\($0)".contains("unknown root 999"), "\($0)")
        }
    }

    // MARK: - Retrait et désactivation

    func testRemovingARootTakesItsRulesWithIt() throws {
        let store = try openStore()
        defer { store.releaseWriteLock() }
        let folder = try makeFolder("Perso")
        let id = try store.addRoot(path: folder, label: nil)
        try store.setIgnoreRulesJSON(rootID: id, #"["Santé/"]"#)

        // Désactiver n'est pas retirer : les règles restent.
        try store.setRootEnabled(id: id, false)
        XCTAssertEqual(try store.ignoreRulesJSON(rootID: id), #"["Santé/"]"#)
        // Ré-ajouter une racine désactivée la rallume, règles comprises.
        XCTAssertEqual(try store.addRoot(path: folder, label: nil), id)
        XCTAssertEqual(try store.ignoreRulesJSON(rootID: id), #"["Santé/"]"#)

        try store.removeRoot(id: id)
        XCTAssertEqual(try store.ignoreRulesJSONByRoot(), [:])
        let again = try store.addRoot(path: folder, label: nil)
        XCTAssertNil(try store.ignoreRulesJSON(rootID: again),
                     "un dossier ré-ajouté après retrait ne retrouve aucune règle fantôme")
    }

    // MARK: - Base v9 d'avant le lot

    /// La base d'un utilisateur qui a déjà un index : v9, sans la colonne.
    private func makeBaseFromBeforeIG2() throws -> Int64 {
        let id: Int64
        do {
            let store = try openStore()
            defer { store.releaseWriteLock() }
            id = try store.addRoot(path: try makeFolder("Perso"), label: nil)
        }
        _ = try sqlite("ALTER TABLE roots DROP COLUMN ignore_rules")
        XCTAssertFalse(try hasColumn())
        return id
    }

    func testABaseFromBeforeIG2OpensUntouchedAndGetsTheColumnOnFirstRule() throws {
        let id = try makeBaseFromBeforeIG2()

        let store = try openStore()
        defer { store.releaseWriteLock() }
        XCTAssertFalse(try hasColumn(), "l'ouverture n'écrit rien")
        XCTAssertNil(try store.ignoreRulesJSON(rootID: id))
        XCTAssertEqual(try store.ignoreRulesJSONByRoot(), [:])
        XCTAssertEqual(try store.roots().map(\.id), [id], "les racines se lisent")

        try store.setIgnoreRulesJSON(rootID: id, #"["Santé/"]"#)
        XCTAssertTrue(try hasColumn())
        XCTAssertEqual(try store.ignoreRulesJSON(rootID: id), #"["Santé/"]"#)
        XCTAssertEqual(try sqlite("SELECT v FROM meta WHERE k='schema_version'"),
                       String(Schema.version), "aucune migration : v9 reste v9")
        XCTAssertEqual(try sqlite("PRAGMA integrity_check"), "ok")

        // Et une réouverture ne s'en émeut pas.
        XCTAssertNoThrow(try GRDBStore().open(at: databaseURL))
    }

    // MARK: - Lecture seule

    func testReadOnlyOpeningsReadBothShapesAndNeverWrite() throws {
        let id = try makeBaseFromBeforeIG2()

        let before = GRDBStore()
        try before.openReadOnly(at: databaseURL)
        XCTAssertNil(try before.ignoreRulesJSON(rootID: id))
        XCTAssertThrowsError(try before.setIgnoreRulesJSON(rootID: id, #"["x/"]"#),
                             "une ouverture en lecture seule ne peut pas ajouter la colonne")
        XCTAssertFalse(try hasColumn())

        let writer = try openStore()
        defer { writer.releaseWriteLock() }
        try writer.setIgnoreRulesJSON(rootID: id, #"["Santé/"]"#)

        // Le lecteur ouvert AVANT l'ajout voit la colonne apparaître : c'est le
        // cas de l'agent et du serveur MCP, qui gardent leur connexion des
        // heures pendant que l'app enregistre une règle.
        XCTAssertEqual(try before.ignoreRulesJSON(rootID: id), #"["Santé/"]"#)
        let after = GRDBStore()
        try after.openReadOnly(at: databaseURL)
        XCTAssertEqual(try after.ignoreRulesJSONByRoot(), [id: #"["Santé/"]"#])
    }

    /// Même régime que les réglages : l'agent peut tenir `fouine.lock` dix
    /// minutes pendant un lot d'OCR, et la feuille doit enregistrer quand même.
    func testKeepingARuleTakesNoIndexingLock() throws {
        let setup = try openStore()
        let id = try setup.addRoot(path: try makeFolder("Perso"), label: nil)
        setup.releaseWriteLock()

        let holder = ExclusiveLock(path: FouinePaths.lockURL(for: databaseURL).path)
        try holder.acquire()
        defer { holder.release() }

        let store = GRDBStore(lockTimeout: 0.3)
        try store.open(at: databaseURL)
        XCTAssertNoThrow(try store.setIgnoreRulesJSON(rootID: id, #"["Santé/"]"#))
        XCTAssertEqual(try store.ignoreRulesJSON(rootID: id), #"["Santé/"]"#)
    }
}
