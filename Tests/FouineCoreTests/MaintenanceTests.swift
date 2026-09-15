// MaintenanceTests.swift — Tests unitaires de sauvegarde et maintenance (C2-06).
// SPDX-License-Identifier: LicenseRef-Fouine-Source-Available

import Foundation
import XCTest
import GRDB
@testable import FouineCore

final class MaintenanceTests: XCTestCase {

    // MARK: - Sauvegarde (fouine backup)

    func testBackupCreatesConsistentAndVerifiedCopy() throws {
        let db = try makeDB()
        let docID = try addDoc(db, relPath: "Livres/test.pdf")
        try db.store.replacePages(docID: docID, pages: [page(1, "page de test pour la sauvegarde")])

        let backupDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("fouine-backup-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: backupDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: backupDir) }

        let dest = backupDir.appendingPathComponent("backup.db")
        let report = try db.store.backup(to: dest)

        XCTAssertEqual(report.destination, dest.path)
        XCTAssertGreaterThan(report.bytes, 0)
        XCTAssertEqual(report.quickCheck, "ok")
        XCTAssertEqual(report.ftsIntegrity, "ok")
        XCTAssertTrue(FileManager.default.fileExists(atPath: dest.path))

        // Permissions 0600 SUR LES TROIS FICHIERS (audit A1m-06) : seul le
        // `.db` était refermé, le `-wal` et le `-shm` créés par le contrôle
        // d'intégrité restaient en 0644 — mesuré sur cette machine avant
        // correction (`-rw-r--r--` sur `copie.db-shm` et `copie.db-wal`).
        for suffix in ["", "-wal", "-shm"] {
            let path = dest.path + suffix
            guard FileManager.default.fileExists(atPath: path) else { continue }
            let mode = (try FileManager.default
                .attributesOfItem(atPath: path)[.posixPermissions] as? NSNumber)?
                .intValue ?? 0
            XCTAssertEqual(mode, 0o600,
                           "\(dest.lastPathComponent)\(suffix) : "
                           + "droits \(String(mode, radix: 8))")
        }

        // Ouverture de la copie et vérification du contenu
        let copyStore = GRDBStore()
        try copyStore.open(at: dest)
        let stats = try copyStore.stats()
        XCTAssertEqual(stats["pages_indexed"], 1)
        XCTAssertEqual(stats["docs_total"], 1)
    }

    func testBackupRefusesExistingDestinationWithoutForce() throws {
        let db = try makeDB()
        let backupDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("fouine-backup-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: backupDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: backupDir) }

        let dest = backupDir.appendingPathComponent("backup.db")
        try Data("dummy".utf8).write(to: dest)

        XCTAssertThrowsError(try db.store.backup(to: dest, force: false)) { error in
            XCTAssertTrue(error.localizedDescription.contains("already exists"))
        }

        // Avec --force, la sauvegarde réussit et écrase le fichier existant
        let report = try db.store.backup(to: dest, force: true)
        XCTAssertEqual(report.destination, dest.path)
        XCTAssertGreaterThan(report.bytes, 0)
    }

    func testBackupRefusesWhenDestinationIsSource() throws {
        let db = try makeDB()
        guard let dbURL = db.store.databaseURL else { return XCTFail("db URL missing") }
        XCTAssertThrowsError(try db.store.backup(to: dbURL)) { error in
            XCTAssertTrue(error.localizedDescription.contains("source database"))
        }
    }

    func testBackupRefusesWhenDestinationIsUnderDatabaseDirectory() throws {
        let db = try makeDB()
        let dest = db.directory.appendingPathComponent("subfolder/backup.db")
        XCTAssertThrowsError(try db.store.backup(to: dest)) { error in
            XCTAssertTrue(error.localizedDescription.contains("inside the database directory"))
        }
    }

    // MARK: - La marque d'échec d'OCR sans page scannée (IX2)

    /// L'ancienne relecture en masse mettait en file des transcriptions ; l'OCR
    /// abandonnait et marquait le document en échec. `--repair` efface cette
    /// marque-là, et elle seule : un vrai scan illisible garde la sienne, un
    /// autre motif d'erreur n'est pas touché, et sans l'option rien ne bouge.
    func testRepairClearsOCRFailureMarksOnlyWhereNoPageIsScanned() throws {
        let db = try makeDB()
        let gaveUp = "OCR gave up after 3 attempts (page 2)"

        let video = try addDoc(db, relPath: "Cours/amphi.mp4", ext: "mp4")
        try db.store.replacePages(docID: video, pages: [
            page(1, "[00:00] bonjour", .transcript),
            page(2, "[10:00] suite", .transcript),
        ])
        let scan = try addDoc(db, relPath: "Cours/illisible.pdf")
        try db.store.completeOCR(docID: scan, page: 1,
                                 result: ocrPage("", lines: [], confidence: 0.0))
        let silent = try addDoc(db, relPath: "Cours/muet.mp4", ext: "mp4")
        try db.store.replacePages(docID: silent, pages: [page(1, "[00:00] …", .transcript)])

        try db.store.writeLocked { raw in
            try raw.execute(sql: "UPDATE docs SET ocr_state = ?, err = ? WHERE id IN (?, ?)",
                            arguments: [OCRState.failed.rawValue, gaveUp, video, scan])
            try raw.execute(sql: "UPDATE docs SET ocr_state = ?, err = ? WHERE id = ?",
                            arguments: [OCRState.failed.rawValue,
                                        "speech recognition returned nothing", silent])
        }
        func mark(_ id: Int64) throws -> (state: Int?, err: String?) {
            try db.store.read { raw in
                let row = try Row.fetchOne(raw, sql: "SELECT ocr_state, err FROM docs WHERE id = ?",
                                           arguments: [id])
                return (row?["ocr_state"], row?["err"])
            }
        }

        // Sans l'option : le contrat C2-06, rien ne change et aucune clé neuve.
        let plain = try db.store.maintain()
        XCTAssertNil(plain.ocrFailuresCleared)
        XCTAssertNil(plain.json["ocr_failures_cleared"])
        XCTAssertEqual(try mark(video).state, OCRState.failed.rawValue)

        let report = try db.store.maintain(repair: true)
        XCTAssertEqual(report.ocrFailuresCleared, 1)
        XCTAssertEqual(report.json["ocr_failures_cleared"] as? Int, 1)
        XCTAssertTrue(report.steps.contains { $0.name == "OCR failure marks" })

        XCTAssertEqual(try mark(video).state, OCRState.notNeeded.rawValue)
        XCTAssertNil(try mark(video).err)
        XCTAssertEqual(try mark(scan).state, OCRState.failed.rawValue, "un vrai scan garde sa marque")
        XCTAssertEqual(try mark(scan).err, gaveUp)
        XCTAssertEqual(try mark(silent).err, "speech recognition returned nothing")

        // Une seconde passe ne trouve plus rien.
        XCTAssertEqual(try db.store.maintain(repair: true).ocrFailuresCleared, 0)
    }

    func testBackupRefusesWhenDiskSpaceIsInsufficient() throws {
        let db = try makeDB()
        let backupDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("fouine-backup-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: backupDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: backupDir) }

        let dest = backupDir.appendingPathComponent("backup.db")
        // Simulation d'espace insuffisant via seuil injectable
        XCTAssertThrowsError(try db.store.backup(to: dest, freeSpaceChecker: { _ in 100 })) { error in
            XCTAssertTrue(error.localizedDescription.contains("insufficient disk space"))
        }
        XCTAssertFalse(FileManager.default.fileExists(atPath: dest.path))
    }

    func testBackupFailsAndCleansUpIfCopyIsCorrupted() throws {
        let db = try makeDB()
        let largeChunk = String(repeating: "contenu textuel pour la corruption de sauvegarde ", count: 100)
        for i in 1...20 {
            let docID = try addDoc(db, relPath: "Livres/corrupt\(i).pdf")
            try db.store.replacePages(docID: docID, pages: [page(1, largeChunk)])
        }

        let backupDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("fouine-backup-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: backupDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: backupDir) }

        let dest = backupDir.appendingPathComponent("corrupted.db")
        _ = try db.store.backup(to: dest)

        let fileSize = (try FileManager.default.attributesOfItem(atPath: dest.path)[.size] as? NSNumber)?.intValue ?? 4096
        // Écraser la MOITIÉ CENTRALE du fichier, et non un seul bloc de 2 Kio au
        // milieu : où tombe ce bloc dépend de la disposition des pages, donc du
        // schéma. Le lot K6 a ajouté un index à `docs` — le bloc atterrissait
        // alors dans de l'espace libre et `integrity_check` répondait « ok ».
        // Une bande large touche des pages B-tree quelle que soit la version.
        let handle = try FileHandle(forUpdating: dest)
        try handle.seek(toOffset: UInt64(fileSize / 4))
        handle.write(Data(repeating: 0xFF, count: fileSize / 2))
        try handle.close()

        // Le contrôle d'intégrité doit échouer proprement
        XCTAssertThrowsError(try GRDBStore.verifyBackupIntegrity(at: dest)) { error in
            XCTAssertTrue(error.localizedDescription.contains("verification failed") || error.localizedDescription.contains("malformed"))
        }
    }

    // MARK: - Contrôle approfondi (fouine doctor --deep)

    func testDeepCheckReportsAllFields() throws {
        let db = try makeDB()
        let docID = try addDoc(db, relPath: "Livres/deep.pdf")
        try db.store.replacePages(docID: docID, pages: [page(1, "contenu pour deep check")])

        let report = try db.store.deepCheck()
        XCTAssertEqual(report.quickCheck, "ok")
        XCTAssertEqual(report.ftsIntegrity, "ok")
        XCTAssertEqual(report.ftsDetails["page_fts"], "ok")
        XCTAssertEqual(report.ftsDetails["vocab_tri"], "ok")
        XCTAssertGreaterThan(report.pageCount, 0)
        XCTAssertEqual(report.pageSize, 4096)
        XCTAssertGreaterThanOrEqual(report.freelistCount, 0)
        XCTAssertEqual(report.journalMode, "wal")
        XCTAssertGreaterThanOrEqual(report.elapsedMS, 0)
    }

    // MARK: - Maintenance (fouine maintain)

    func testMaintainOptimizesAndReclaimsPagesWithVacuum() throws {
        let db = try makeDB()
        let largeChunk = String(repeating: "azote catalyse polymere enthalpie gibbs markovnikov reduction reaction cinetique ", count: 50)
        // Indexer suffisamment de documents et de texte pour allouer de nombreuses pages B-tree
        for i in 1...40 {
            let docID = try addDoc(db, relPath: "Doc\(i).txt")
            try db.store.replacePages(docID: docID, pages: [
                page(1, "Page 1: \(largeChunk)"),
                page(2, "Page 2: \(largeChunk)"),
                page(3, "Page 3: \(largeChunk)"),
            ])
        }

        // Supprimer une grande partie des documents pour vider entièrement plusieurs pages B-tree
        for i in 1...30 {
            try db.store.removeDoc(id: Int64(i))
        }

        // Vérifier qu'il y a des pages libres avant VACUUM
        let freelistBefore = try db.store.read { db in
            try Int.fetchOne(db, sql: "PRAGMA freelist_count") ?? 0
        }
        XCTAssertGreaterThan(freelistBefore, 0, "freelist_count doit être non nul après suppressions massives")

        // Exécuter maintain avec --vacuum
        let report = try db.store.maintain(vacuum: true)
        XCTAssertTrue(report.vacuumExecuted)
        XCTAssertGreaterThan(report.freelistBefore, 0)
        XCTAssertEqual(report.freelistAfter, 0, "freelist_count doit être nul après VACUUM")
        XCTAssertGreaterThan(report.bytesReclaimed, 0)

        // LA MESURE EST PRISE APRÈS LE WAL (constat C2-21). Elle l'était juste
        // après le VACUUM, quand le journal portait encore la copie complète de
        // la base réécrite : `maintain --vacuum` annonçait « 23 Mo -> 47 Mo,
        // 0 octet récupéré » à l'instant même où il venait d'en rendre 5,5. La
        // seule commande qui libère du disque affirmait le contraire.
        XCTAssertLessThanOrEqual(report.bytesAfter, report.bytesBefore,
                                 "l'index ne peut pas GROSSIR d'un compactage")
        let onDisk = try FileManager.default.attributesOfItem(
            atPath: db.directory.appendingPathComponent("fouine.db").path)
        XCTAssertEqual(report.bytesAfter,
                       (onDisk[.size] as? NSNumber)?.intValue ?? 0,
                       accuracy: 64 * 1024,
                       "la taille annoncée doit être celle du fichier")

        // Vérifier les étapes
        let stepNames = report.steps.map(\.name)
        XCTAssertTrue(stepNames.contains("page_fts optimize"))
        XCTAssertTrue(stepNames.contains("vocab_tri optimize"))
        XCTAssertTrue(stepNames.contains("PRAGMA optimize"))
        XCTAssertTrue(stepNames.contains("wal_checkpoint(TRUNCATE)"))
        XCTAssertTrue(stepNames.contains("VACUUM"))
        XCTAssertTrue(stepNames.contains("wal_checkpoint(TRUNCATE) after VACUUM"),
                      "le journal doit être replié AVANT la mesure : \(stepNames)")
    }

    func testMaintainFailsWithLockErrorWhenAnotherProcessHoldsLock() throws {
        // 0,3 s d'attente au lieu de 5 : le refus (verrou nommé, détenteur lu à
        // l'échéance) est le même, seule l'attente change.
        let db = try makeDB(lockTimeout: 0.3)
        guard let dbURL = db.store.databaseURL else { return XCTFail("db URL missing") }

        // Un second store ouvre la même base et prend explicitement le verrou
        let rivalStore = GRDBStore()
        try rivalStore.open(at: dbURL)
        try rivalStore.acquireWriteLock(as: .agent)
        defer { rivalStore.releaseWriteLock() }

        // maintain doit échouer sur une erreur de verrou occupé, et non sur SQLITE_BUSY
        XCTAssertThrowsError(try db.store.maintain()) { error in
            XCTAssertTrue(WriteLock.isBusy(error), "doit être une erreur WriteLock.isBusy, pas SQLITE_BUSY : \(error)")
            if let busy = WriteLock.busy(error) {
                XCTAssertEqual(busy.holder?.role, .agent)
            } else {
                XCTFail("le détenteur du verrou doit être identifié")
            }
        }
    }

    /// La phase FTS5 de `--deep` tient le verrou d'écriture SQLite ~3 min 30 sur
    /// 1,8 Go : sans verrou nommé, l'agent tomberait en SQLITE_BUSY sans savoir
    /// qui l'occupe. Le verrou nommé doit donc être pris — et refusé ici.
    func testDeepCheckFailsWithLockErrorWhenAnotherProcessHoldsLock() throws {
        let db = try makeDB(lockTimeout: 0.3)
        guard let dbURL = db.store.databaseURL else { return XCTFail("db URL missing") }
        let rivalStore = GRDBStore()
        try rivalStore.open(at: dbURL)
        try rivalStore.acquireWriteLock(as: .agent)
        defer { rivalStore.releaseWriteLock() }

        XCTAssertThrowsError(try db.store.deepCheck()) { error in
            XCTAssertTrue(WriteLock.isBusy(error), "doit être WriteLock.isBusy, pas SQLITE_BUSY : \(error)")
            XCTAssertEqual(WriteLock.busy(error)?.holder?.role, .agent)
        }
    }

    /// Et il doit être RENDU au retour : un `doctor --deep` fini ne doit pas
    /// laisser la base verrouillée derrière lui.
    func testDeepCheckReleasesTheWriteLock() throws {
        let db = try makeDB()
        guard let dbURL = db.store.databaseURL else { return XCTFail("db URL missing") }
        _ = try db.store.deepCheck()
        let rivalStore = GRDBStore()
        try rivalStore.open(at: dbURL)
        XCTAssertNoThrow(try rivalStore.acquireWriteLock(as: .agent))
        rivalStore.releaseWriteLock()
    }

    func testMaintainVacuumRefusesWhenDiskSpaceIsInsufficient() throws {
        let db = try makeDB()
        XCTAssertThrowsError(try db.store.maintain(vacuum: true, freeSpaceChecker: { _ in 100 })) { error in
            XCTAssertTrue(error.localizedDescription.contains("insufficient disk space for VACUUM"))
        }
    }
}
