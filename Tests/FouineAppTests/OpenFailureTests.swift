// OpenFailureTests.swift — diagnostic d'échec d'ouverture et gestes de récupération (audit H4, lot I1, B1-14).
// Propriété : A-App. SPEC §5.6.

import XCTest
import FouineCore
@testable import FouineApp

final class OpenFailureTests: XCTestCase {

    private func diagnose(_ error: String,
                          lock: WriteLock.LockStatus = .free) -> OpenErrorDiagnosis {
        OpenErrorDiagnosis.diagnose(error: error, lockStatus: lock)
    }

    // MARK: - Ordre et motifs

    /// « malformed database schema » est une CORRUPTION, pas un schéma plus
    /// récent : la corruption se teste en premier.
    func testCorruptionWinsOverSchemaWording() {
        XCTAssertEqual(diagnose("database disk image is malformed"), .corrupted)
        XCTAssertEqual(diagnose("malformed database schema (page_fts) - near \"(\": syntax error"), .corrupted)
        XCTAssertEqual(diagnose("file is not a database"), .corrupted)
        XCTAssertEqual(diagnose("opening /x/fouine.db: corrupt index page"), .corrupted)
    }

    func testHeldLockIsDiagnosedFromTheLockFileWithoutPid() {
        let holder = LockHolder(pid: 4321, role: .agent, since: Date())
        let diag = diagnose("opening /tmp/fouine.db: database is locked", lock: .held(holder))
        guard case .lockHeld(let who) = diag else {
            return XCTFail("Attendu .lockHeld, obtenu \(diag)")
        }
        XCTAssertTrue(who.contains(holder.clockText), who)
        XCTAssertFalse(who.contains("4321"), "le pid ne s'affiche pas : \(who)")
        XCTAssertFalse(diag.readableMessage.lowercased().contains("lock"), diag.readableMessage)
    }

    func testBusyMessageWithoutAHeldLockIsStillALock() {
        XCTAssertEqual(
            diagnose("opening /tmp/fouine.db: \(WriteLock.busyToken) 1 path=/tmp/fouine.lock"),
            .lockHeld(who: String(localized: "another program")))
        XCTAssertEqual(diagnose("SQLite error 5: database is locked"),
                       .lockHeld(who: String(localized: "another program")))
    }

    /// Le motif est la phrase RÉELLE du cœur (`GRDBStore.schemaMismatch`), pas
    /// un « schema » générique.
    func testNewerVersionUsesTheCoreMessage() {
        XCTAssertEqual(diagnose(GRDBStore.schemaMismatch(found: Schema.version + 1)), .newerVersion)
        // Un schéma plus ANCIEN est l'AUTRE cas, et le geste n'est pas le même :
        // mettre à jour d'un côté, refaire l'index de l'autre. Les confondre
        // ferait détruire un index qu'une mise à jour suffisait à ouvrir.
        XCTAssertEqual(diagnose(GRDBStore.schemaMismatch(found: Schema.version - 1)), .tooOld)
    }

    /// Un index d'un schéma plus ancien ne se rattrape pas : le diagnostic
    /// existe, et sa phrase parle à quelqu'un qui n'est pas informaticien —
    /// pas de « schéma », pas de « migration », pas de numéro de version.
    func testTooOldIsRecognisedForEveryOlderSchema() {
        for version in 1..<Schema.version {
            XCTAssertEqual(diagnose(GRDBStore.schemaMismatch(found: version)), .tooOld,
                           "schéma v\(version)")
        }
        let message = OpenErrorDiagnosis.tooOld.readableMessage
        XCTAssertFalse(message.isEmpty)
        for jargon in ["schema", "schéma", "migration", "v5", "rowid"] {
            XCTAssertFalse(message.lowercased().contains(jargon), message)
        }
    }

    /// « full-text » n'est pas un disque plein.
    func testFullTextIsNotDiskFull() {
        XCTAssertEqual(diagnose("database or disk is full"), .diskFull)
        XCTAssertEqual(diagnose("sqlite3: no space left on device"), .diskFull)
        XCTAssertEqual(diagnose("write failed: ENOSPC"), .diskFull)
        XCTAssertEqual(diagnose("FTS5 full-text index unavailable"),
                       .generic("FTS5 full-text index unavailable"))
    }

    func testMissingOrInaccessible() {
        XCTAssertEqual(diagnose("cannot create /Volumes/Sec/db: permission denied"), .missingOrInaccessible)
        XCTAssertEqual(diagnose("open: operation not permitted"), .missingOrInaccessible)
        XCTAssertEqual(diagnose("unable to open database file: read-only file system"), .missingOrInaccessible)
        XCTAssertEqual(diagnose("no such file or directory"), .missingOrInaccessible)
    }

    /// Chaque message lisible dit le geste, dans la langue de l'utilisateur, et
    /// ne recopie pas le message brut.
    func testReadableMessagesSayTheGesture() {
        let cases: [(String, OpenErrorDiagnosis)] = [
            ("database disk image is malformed", .corrupted),
            (GRDBStore.schemaMismatch(found: Schema.version + 1), .newerVersion),
            (GRDBStore.schemaMismatch(found: Schema.version - 1), .tooOld),
            ("database or disk is full", .diskFull),
            ("permission denied", .missingOrInaccessible),
        ]
        for (raw, expected) in cases {
            let diag = diagnose(raw)
            XCTAssertEqual(diag, expected)
            XCTAssertFalse(diag.readableMessage.isEmpty)
            XCTAssertNotEqual(diag.readableMessage, raw)
        }
        XCTAssertEqual(diagnose("something unexpected").readableMessage, "something unexpected")
    }

    // MARK: - Sauvegardes voisines

    private func makeTempDir() throws -> URL {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("fouine-open-failure-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    private func write(_ name: String, sqlite: Bool, in dir: URL,
                       modified: Date = Date()) throws -> URL {
        let url = dir.appendingPathComponent(name)
        var data = sqlite ? BackupCandidates.sqliteHeader : Data("not a database".utf8)
        data.append(Data(repeating: 0, count: 100))
        try data.write(to: url)
        try FileManager.default.setAttributes([.modificationDate: modified], ofItemAtPath: url.path)
        return url
    }

    /// Seuls les fichiers qui RESSEMBLENT à une base (nom ET en-tête SQLite)
    /// sont proposés ; le plus récent l'emporte.
    @MainActor
    func testAvailableBackupURLRequiresBackupNameAndSQLiteHeader() throws {
        let dir = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let dbURL = dir.appendingPathComponent("fouine.db")
        let app = AppModel(service: StoreService(databaseURL: dbURL))

        XCTAssertNil(app.availableBackupURL(), "dossier vide")

        _ = try write("fouine.db", sqlite: true, in: dir)
        XCTAssertNil(app.availableBackupURL(), "la base elle-même n'est pas une sauvegarde")

        _ = try write("fouine.db.bak", sqlite: false, in: dir)
        XCTAssertNil(app.availableBackupURL(), "un .bak sans en-tête SQLite n'est pas une base")

        _ = try write("notes.txt", sqlite: true, in: dir)
        _ = try write("fouine.db-wal", sqlite: true, in: dir)
        _ = try write("fouine.db.corrupt-ABCD", sqlite: true, in: dir)
        XCTAssertNil(app.availableBackupURL(), "journaux, bases écartées et noms quelconques sont ignorés")

        let old = Date().addingTimeInterval(-3_600)
        _ = try write("fouine-backup.db", sqlite: true, in: dir, modified: old)
        XCTAssertEqual(app.availableBackupURL()?.lastPathComponent, "fouine-backup.db")

        _ = try write("sauvegarde du 3 septembre.sqlite", sqlite: true, in: dir)
        XCTAssertEqual(app.availableBackupURL()?.lastPathComponent, "sauvegarde du 3 septembre.sqlite",
                       "la plus récente l'emporte")
    }

    /// Une copie qui échoue laisse l'index EN PLACE : sans cela, la
    /// réouverture créerait une base vide et l'échec passerait pour un succès.
    @MainActor
    func testRestoreBackupFailureLeavesTheIndexInPlace() async throws {
        let dir = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let dbURL = dir.appendingPathComponent("fouine.db")
        try Data("original".utf8).write(to: dbURL)
        let app = AppModel(service: StoreService(databaseURL: dbURL))

        let missing = dir.appendingPathComponent("absent.db")
        do {
            try await app.restoreBackup(from: missing)
            XCTFail("la copie d'un fichier absent doit échouer")
        } catch {
            // attendu
        }
        XCTAssertEqual(try Data(contentsOf: dbURL), Data("original".utf8))
        let leftovers = try FileManager.default.contentsOfDirectory(atPath: dir.path)
            .filter { $0.contains(".corrupt-") }
        XCTAssertTrue(leftovers.isEmpty, "\(leftovers)")
        XCTAssertNil(app.restoreNotice)
    }

    /// Une restauration réussie rouvre l'index, garde l'ancien à côté et le dit.
    @MainActor
    func testRestoreBackupKeepsThePreviousIndexAsideAndSaysSo() async throws {
        let good = try TempAppDB()
        let dir = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let dbURL = dir.appendingPathComponent("fouine.db")
        try Data("garbage".utf8).write(to: dbURL)
        let app = AppModel(service: StoreService(databaseURL: dbURL))

        try await app.restoreBackup(from: good.service.databaseURL)
        defer {
            app.stopHealthProbe()
            app.stopAgentStatusProbe()
        }

        XCTAssertNil(app.openError, app.openError ?? "")
        let notice = try XCTUnwrap(app.restoreNotice)
        let aside = try FileManager.default.contentsOfDirectory(atPath: dir.path)
            .filter { $0.contains(".corrupt-") }
        XCTAssertEqual(aside.count, 1, "\(aside)")
        XCTAssertTrue(notice.message.contains(aside[0]), notice.message)
        XCTAssertEqual(try Data(contentsOf: dir.appendingPathComponent(aside[0])), Data("garbage".utf8))
    }

    // MARK: - Refaire l'index (lot J1)

    /// Le seul chemin de l'application qui détruise l'index : il efface la
    /// base ET ses journaux — un `-wal` laissé en place ferait refuser la base
    /// suivante, qui ne lui appartient pas — puis rouvre sur une base neuve.
    @MainActor
    func testDiscardIndexDeletesTheDatabaseAndItsJournalsThenReopens() async throws {
        let dir = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let dbURL = dir.appendingPathComponent("fouine.db")
        try Data("un index périmé".utf8).write(to: dbURL)
        try Data("wal".utf8).write(to: URL(fileURLWithPath: dbURL.path + "-wal"))
        try Data("shm".utf8).write(to: URL(fileURLWithPath: dbURL.path + "-shm"))
        let app = AppModel(service: StoreService(databaseURL: dbURL))
        defer {
            app.stopHealthProbe()
            app.stopAgentStatusProbe()
        }

        await app.start()
        XCTAssertNotNil(app.openError, "une base illisible doit refuser l'ouverture")

        try await app.discardIndexAndStartOver()

        XCTAssertNil(app.openError, app.openError ?? "")
        // La base rouverte est NEUVE — plus un octet de l'ancienne — et au
        // schéma courant. (Ses propres `-wal`/`-shm` sont là : c'est le WAL de
        // la base neuve, pas les journaux orphelins de l'ancienne.)
        let bytes = try Data(contentsOf: dbURL)
        XCTAssertNotEqual(bytes, Data("un index périmé".utf8))
        XCTAssertTrue(bytes.starts(with: BackupCandidates.sqliteHeader))
        let store = GRDBStore()
        try store.openReadOnly(at: dbURL)
        XCTAssertEqual(try store.schemaVersion(), Schema.version)
        XCTAssertTrue(try store.roots().isEmpty, "l'index rouvert doit être vide")
    }

    // MARK: - Réessayer

    /// `retryOpen` remet l'état et rejoue `start()` ; les sondes ne se
    /// dédoublent pas quand `start()` est rappelé.
    @MainActor
    func testRetryOpenResetsStateAndProbesStayUnique() async throws {
        let dir = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let dbURL = dir.appendingPathComponent("fouine.db")
        try Data("garbage".utf8).write(to: dbURL)
        let app = AppModel(service: StoreService(databaseURL: dbURL))
        defer {
            app.stopHealthProbe()
            app.stopAgentStatusProbe()
        }

        await app.start()
        XCTAssertNotNil(app.openError, "une base illisible doit refuser l'ouverture")
        XCTAssertNil(app.healthProbeTask, "pas de sonde sans base ouverte")

        // Toujours illisible : l'erreur revient, l'état n'est pas resté figé.
        await app.retryOpen()
        XCTAssertNotNil(app.openError)

        // Réparée entre-temps : la réouverture réussit et arme les sondes UNE fois.
        let good = try TempAppDB()
        try FileManager.default.removeItem(at: dbURL)
        try FileManager.default.copyItem(at: good.service.databaseURL, to: dbURL)
        await app.retryOpen()
        XCTAssertNil(app.openError, app.openError ?? "")
        let health = try XCTUnwrap(app.healthProbeTask)
        let agent = try XCTUnwrap(app.agentStatusTask)
        app.startHealthProbe()
        app.startAgentStatusProbe()
        XCTAssertEqual(app.healthProbeTask, health, "startHealthProbe est idempotente")
        XCTAssertEqual(app.agentStatusTask, agent, "startAgentStatusProbe est idempotente")
    }
}
