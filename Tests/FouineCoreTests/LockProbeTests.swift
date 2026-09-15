// LockProbeTests.swift — tests de lecture de fouine.lock sans attendre.
// Propriété : A-Core. SPEC §5.1.
//
// Vérifie que `WriteLock.inspect` diagnostique immédiatement l'état du verrou
// sans attendre ni bloquer. Depuis l'audit A1m-03, c'est le `flock` qui
// tranche, PAS le contenu du fichier :
// - fichier absent ou vide                     -> .free
// - nom inscrit mais flock LIBRE               -> .free, et le nom est nettoyé
// - flock TENU, nom d'un processus vivant      -> .held
// - flock TENU, nom d'un processus mort        -> .stale

import Foundation
import XCTest
import FouineCore

final class LockProbeTests: XCTestCase {

    private func scratch() throws -> URL {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("fouine-lock-test-\(UUID().uuidString)")
        try FileManager.default.createDirectory(
            at: dir, withIntermediateDirectories: true)
        return dir
    }

    func testAbsentOrEmptyLockFileIsFree() throws {
        let tempDir = try scratch()
        defer { try? FileManager.default.removeItem(at: tempDir) }

        let lockPath = tempDir.appendingPathComponent("fouine.lock").path

        // Fichier absent : la sonde ne le CRÉE pas (pas d'`O_CREAT`) —
        // diagnostiquer ne doit rien laisser derrière soi.
        XCTAssertEqual(WriteLock.inspect(path: lockPath), .free)
        XCTAssertFalse(FileManager.default.fileExists(atPath: lockPath))

        // Fichier vide
        FileManager.default.createFile(atPath: lockPath, contents: Data())
        XCTAssertEqual(WriteLock.inspect(path: lockPath), .free)
    }

    /// LE constat A1m-03. Un nom de détenteur vivant, mais AUCUN `flock` : le
    /// verrou est libre, et la sonde doit le dire — sinon un `fouine.lock`
    /// abandonné (un `kill -9`, une campagne interrompue) fait annoncer « la
    /// base est en cours d'écriture » à vie, et le jour où macOS recycle ce pid,
    /// pour toujours.
    func testAStaleNameWithoutFlockIsFreeAndTheFileIsCleaned() throws {
        let tempDir = try scratch()
        defer { try? FileManager.default.removeItem(at: tempDir) }
        let lockPath = tempDir.appendingPathComponent("fouine.lock").path

        // Un détenteur PARFAITEMENT vivant — c'est nous — mais qui ne tient
        // aucun flock.
        let holder = LockHolder(pid: getpid(), role: .agent, since: Date())
        try holder.line.write(toFile: lockPath, atomically: true, encoding: .utf8)
        XCTAssertNotNil(WriteLock.readHolder(path: lockPath))

        XCTAssertEqual(WriteLock.inspect(path: lockPath), .free)

        // …et le nom périmé est parti, tronqué tant que la sonde tenait le
        // flock : plus personne ne peut le relire et accuser un mort.
        XCTAssertNil(WriteLock.readHolder(path: lockPath))
        XCTAssertTrue(FileManager.default.fileExists(atPath: lockPath),
                      "le fichier reste, seul son contenu part")
    }

    /// flock est associé au DESCRIPTEUR ouvert, pas au processus : un second
    /// descripteur du même processus se voit refuser le verrou. C'est ce qui
    /// permet d'éprouver `.held` sans lancer de sous-processus.
    func testLivingHolderThatActuallyHoldsTheFlockIsHeld() throws {
        let tempDir = try scratch()
        defer { try? FileManager.default.removeItem(at: tempDir) }
        let lockPath = tempDir.appendingPathComponent("fouine.lock").path

        let fd = open(lockPath, O_CREAT | O_RDWR, 0o600)
        XCTAssertGreaterThanOrEqual(fd, 0)
        defer { close(fd) }
        XCTAssertEqual(flock(fd, LOCK_EX | LOCK_NB), 0)

        let holder = LockHolder(pid: getpid(), role: .agent, since: Date())
        let line = holder.line
        _ = line.withCString { write(fd, $0, strlen($0)) }

        let status = WriteLock.inspect(path: lockPath)
        guard case .held(let readHolder) = status else {
            XCTFail("Attendu .held, obtenu \(status)")
            return
        }
        XCTAssertEqual(readHolder.pid, getpid())
        XCTAssertEqual(readHolder.role, .agent)
        // Le nom d'un verrou VRAIMENT tenu ne se tronque pas.
        XCTAssertNotNil(WriteLock.readHolder(path: lockPath))
    }

    /// La sonde vue depuis le produit : le verrou d'un `GRDBStore` qui écrit
    /// est `.held`, et il est `.free` dès qu'il est rendu — sans qu'aucune
    /// autre écriture ait eu à passer pour nettoyer le nom.
    func testTheStoreLockIsSeenHeldThenFree() throws {
        let db = try makeDB(lockTimeout: 0.3)
        let lockPath = FouinePaths.lockURL(
            for: db.directory.appendingPathComponent("fouine.db")).path

        let docID = try addDoc(db, relPath: "sonde.pdf")
        try db.store.acquireWriteLock(as: .cli)
        XCTAssertTrue(WriteLock.inspect(path: lockPath).isHeld)
        db.store.releaseWriteLock()
        XCTAssertTrue(WriteLock.inspect(path: lockPath).isFree)
        XCTAssertGreaterThan(docID, 0)
    }

    /// CE QUE LA SONDE DOIT PERMETTRE DE DIRE (BU-31). L'application a
    /// affiché « Un autre programme écrit dans l'index » pendant sa PROPRE
    /// passe de lecture des pages scannées. La sonde, elle, dit la vérité : le
    /// verrou est tenu, et le détenteur porte le pid du processus courant —
    /// c'est à la lecture de ce pid, et non du rôle, qu'il revient de
    /// reconnaître sa propre écriture (`HealthBannerEvaluator`).
    ///
    /// Deux fois le même verrou, sous les deux rôles qu'une passe de
    /// l'application peut inscrire : dans les deux cas, le pid est le nôtre.
    func testTheOwnLockNamesTheCurrentProcess() throws {
        let tempDir = try scratch()
        defer { try? FileManager.default.removeItem(at: tempDir) }
        let lockPath = tempDir.appendingPathComponent("fouine.lock").path

        for role in [LockRole.app, .cli] {
            let fd = open(lockPath, O_CREAT | O_RDWR | O_TRUNC, 0o600)
            XCTAssertGreaterThanOrEqual(fd, 0)
            XCTAssertEqual(flock(fd, LOCK_EX | LOCK_NB), 0)
            let line = LockHolder.current(role: role).line
            _ = line.withCString { write(fd, $0, strlen($0)) }

            guard case .held(let holder) = WriteLock.inspect(path: lockPath) else {
                XCTFail("attendu .held pour le rôle \(role.rawValue)")
                close(fd)
                return
            }
            XCTAssertEqual(holder.pid, getpid())
            XCTAssertEqual(holder.role, role)
            close(fd)
        }
    }

    /// UN VERROU DONT LE PID EST MORT N'EST JAMAIS « TENU » (BU-31, seconde
    /// cause à écarter). flock() est rendu par le noyau à la mort du
    /// processus : le nom qui traîne dans le fichier ne peut plus faire
    /// annoncer une écriture en cours — la sonde rend `.free` et efface le
    /// nom. Sans quoi un `fouine index` interrompu aurait fait dire « un autre
    /// programme écrit dans l'index » pour toujours.
    func testADeadPIDNeverLooksLikeAWriteInProgress() throws {
        let tempDir = try scratch()
        defer { try? FileManager.default.removeItem(at: tempDir) }
        let lockPath = tempDir.appendingPathComponent("fouine.lock").path

        let proc = Process()
        proc.executableURL = URL(fileURLWithPath: "/bin/echo")
        proc.arguments = ["fini"]
        proc.standardOutput = Pipe()
        try proc.run()
        proc.waitUntilExit()
        let deadPid = proc.processIdentifier
        XCTAssertEqual(kill(deadPid, 0), -1)

        let line = LockHolder(pid: deadPid, role: .cli, since: Date()).line
        try line.write(toFile: lockPath, atomically: true, encoding: .utf8)

        XCTAssertEqual(WriteLock.inspect(path: lockPath), .free)
        XCTAssertNil(WriteLock.readHolder(path: lockPath))
    }

    /// Verrou TENU par un descripteur, mais nommé par un processus mort : le
    /// verrou bloque vraiment, et le nom ne vaut rien. C'est `.stale`.
    func testDeadProcessIsStale() throws {
        let tempDir = try scratch()
        defer { try? FileManager.default.removeItem(at: tempDir) }

        let lockPath = tempDir.appendingPathComponent("fouine.lock").path
        let fd = open(lockPath, O_CREAT | O_RDWR, 0o600)
        XCTAssertGreaterThanOrEqual(fd, 0)
        defer { close(fd) }
        XCTAssertEqual(flock(fd, LOCK_EX | LOCK_NB), 0)

        // Lance un processus éphémère qui termine immédiatement
        let proc = Process()
        proc.executableURL = URL(fileURLWithPath: "/bin/echo")
        proc.arguments = ["done"]
        proc.standardOutput = Pipe()
        proc.standardError = Pipe()
        try proc.run()
        proc.waitUntilExit()

        let deadPid = proc.processIdentifier
        XCTAssertTrue(deadPid > 0)
        // Vérifie qu'il est bien mort
        XCTAssertEqual(kill(deadPid, 0), -1)
        XCTAssertEqual(errno, ESRCH)

        let line = LockHolder(pid: deadPid, role: .cli, since: Date()).line
        _ = line.withCString { write(fd, $0, strlen($0)) }

        let status = WriteLock.inspect(path: lockPath)
        guard case .stale(let readHolder) = status else {
            XCTFail("Attendu .stale, obtenu \(status)")
            return
        }
        XCTAssertEqual(readHolder.pid, deadPid)
        XCTAssertEqual(readHolder.role, .cli)
    }
}
