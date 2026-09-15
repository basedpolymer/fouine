// GRDBStore+Maintenance.swift — Sauvegarde et maintenance de la base (SPEC §4.3, C2-06).
// SPDX-License-Identifier: LicenseRef-Fouine-Source-Available

import Foundation
import GRDB
import Darwin

/// Erreur spécifique aux opérations de maintenance et sauvegarde.
/// Conforme à LocalizedError pour rendre le message exact en CLI (code de sortie 1).
public struct MaintenanceError: LocalizedError, CustomStringConvertible, Sendable {
    public let message: String
    public init(_ message: String) { self.message = message }
    public var errorDescription: String? { message }
    public var description: String { message }
}

public struct BackupReport: Sendable {
    public let destination: String
    public let bytes: Int
    public let elapsedMS: Double
    public let quickCheck: String
    public let ftsIntegrity: String

    public init(destination: String, bytes: Int, elapsedMS: Double, quickCheck: String, ftsIntegrity: String) {
        self.destination = destination
        self.bytes = bytes
        self.elapsedMS = elapsedMS
        self.quickCheck = quickCheck
        self.ftsIntegrity = ftsIntegrity
    }

    public var json: [String: Any] {
        [
            "destination": destination,
            "bytes": bytes,
            "elapsed_ms": Int(round(elapsedMS)),
            "quick_check": quickCheck,
            "fts_integrity": ftsIntegrity,
        ]
    }
}

/// Écart entre `docs` et `docs_fts` (schéma v8, D-R3).
///
/// La table des noms est tenue dans la même transaction que `docs` : un écart
/// ne peut venir que d'une base migrée à la main ou d'un arrêt brutal d'une
/// version antérieure. `maintain --repair` la reconstruit.
public struct DocNameCheck: Sendable {
    public let docs: Int
    public let names: Int

    public init(docs: Int, names: Int) {
        self.docs = docs
        self.names = names
    }

    public var consistent: Bool { docs == names }

    public var json: [String: Any] {
        ["docs": docs, "names": names, "consistent": consistent]
    }
}

public struct DeepCheckReport: Sendable {
    public let quickCheck: String
    public let ftsIntegrity: String
    public let ftsDetails: [String: String]
    public let pageCount: Int
    public let pageSize: Int
    public let freelistCount: Int
    public let fragmentationPct: Double
    public let fragmentationBytes: Int
    public let walBytes: Int
    public let journalMode: String
    /// Cohérence de `page_vec` (audit A1m-05). `nil` seulement pour un
    /// appelant qui n'a pas pu la calculer — `deepCheck()` la remplit toujours.
    public let vectors: VectorConsistencyReport?
    /// Cohérence de `docs_fts` (schéma v8, D-R3). `nil` seulement pour un
    /// appelant qui n'a pas pu la calculer — `deepCheck()` la remplit toujours.
    public let docNames: DocNameCheck?
    /// Durée de chaque étape, dans l'ordre où elles ont tourné (MO-04). Une
    /// vérification de 86 s sur 2,2 Go sans rien d'affiché ne dit pas ce qui
    /// prend le temps — et la réponse n'était pas celle qu'on croyait. Mesuré
    /// le 10/09/2026 sur une copie de la base de production (2,15 Go, 177 s au
    /// total, une autre compilation en cours) : `quick_check` **79,6 s**,
    /// `page_vec` 5,5 s, `docs_fts` 9 ms, `fts5_integrity` **92,0 s**. Les
    /// deux gros postes sont donc à peu près à égalité, et le verrou
    /// d'écriture n'est tenu que pendant le second.
    public let steps: [MaintainStep]
    public let elapsedMS: Double

    public init(quickCheck: String, ftsIntegrity: String, ftsDetails: [String: String],
                pageCount: Int, pageSize: Int, freelistCount: Int,
                fragmentationPct: Double, fragmentationBytes: Int,
                walBytes: Int, journalMode: String,
                vectors: VectorConsistencyReport? = nil,
                docNames: DocNameCheck? = nil,
                steps: [MaintainStep] = [], elapsedMS: Double) {
        self.quickCheck = quickCheck
        self.ftsIntegrity = ftsIntegrity
        self.ftsDetails = ftsDetails
        self.pageCount = pageCount
        self.pageSize = pageSize
        self.freelistCount = freelistCount
        self.fragmentationPct = fragmentationPct
        self.fragmentationBytes = fragmentationBytes
        self.walBytes = walBytes
        self.journalMode = journalMode
        self.vectors = vectors
        self.docNames = docNames
        self.steps = steps
        self.elapsedMS = elapsedMS
    }

    public var json: [String: Any] {
        var object: [String: Any] = [
            "quick_check": quickCheck,
            "fts_integrity": ftsIntegrity,
            "page_count": pageCount,
            "page_size": pageSize,
            "freelist_count": freelistCount,
            "fragmentation_pct": JSONNumber.rounded(fragmentationPct, places: 1),
            "fragmentation_bytes": fragmentationBytes,
            "wal_bytes": walBytes,
            "journal_mode": journalMode,
            "elapsed_ms": Int(round(elapsedMS)),
        ]
        if !steps.isEmpty {
            object["steps"] = steps.map {
                ["name": $0.name, "elapsed_ms": Int(round($0.elapsedMS))] as [String: Any]
            }
        }
        if let vectors { object["vectors"] = vectors.json }
        if let docNames { object["doc_names"] = docNames.json }
        return object
    }
}

public struct MaintainStep: Sendable {
    public let name: String
    public let elapsedMS: Double

    public init(name: String, elapsedMS: Double) {
        self.name = name
        self.elapsedMS = elapsedMS
    }
}

public struct MaintainReport: Sendable {
    public let steps: [MaintainStep]
    public let bytesBefore: Int
    public let bytesAfter: Int
    public let bytesReclaimed: Int
    public let freelistBefore: Int
    public let freelistAfter: Int
    public let vacuumExecuted: Bool
    /// Ce que `--repair` a retiré de `page_vec`. `nil` sans l'option : sans
    /// elle, `maintain` ne change RIEN au contenu de l'index (contrat C2-06).
    public let vectorRepair: VectorRepairReport?
    /// Documents dont `--repair` a effacé la marque d'échec d'OCR faute de
    /// page scannée (IX2). `nil` sans l'option, pour la même raison.
    public let ocrFailuresCleared: Int?
    public let totalElapsedMS: Double

    public init(steps: [MaintainStep], bytesBefore: Int, bytesAfter: Int, bytesReclaimed: Int,
                freelistBefore: Int, freelistAfter: Int, vacuumExecuted: Bool,
                vectorRepair: VectorRepairReport? = nil, ocrFailuresCleared: Int? = nil,
                totalElapsedMS: Double) {
        self.steps = steps
        self.bytesBefore = bytesBefore
        self.bytesAfter = bytesAfter
        self.bytesReclaimed = bytesReclaimed
        self.freelistBefore = freelistBefore
        self.freelistAfter = freelistAfter
        self.vacuumExecuted = vacuumExecuted
        self.vectorRepair = vectorRepair
        self.ocrFailuresCleared = ocrFailuresCleared
        self.totalElapsedMS = totalElapsedMS
    }

    public var json: [String: Any] {
        var object: [String: Any] = [
            "bytes_before": bytesBefore,
            "bytes_after": bytesAfter,
            "bytes_reclaimed": bytesReclaimed,
            "freelist_before": freelistBefore,
            "freelist_after": freelistAfter,
            "vacuum_executed": vacuumExecuted,
            "total_elapsed_ms": Int(round(totalElapsedMS)),
            "steps": steps.map { ["name": $0.name, "elapsed_ms": Int(round($0.elapsedMS))] },
        ]
        if let vectorRepair { object["vector_repair"] = vectorRepair.json }
        if let ocrFailuresCleared { object["ocr_failures_cleared"] = ocrFailuresCleared }
        return object
    }
}

extension GRDBStore {

    /// Espace disque disponible sur le volume du chemin donné, en octets.
    public static func availableDiskSpace(at url: URL) -> Int64? {
        let isDir = (try? url.resourceValues(forKeys: [.isDirectoryKey]))?.isDirectory ?? false
        let path = isDir ? url.path : url.deletingLastPathComponent().path
        var stat = statvfs()
        if statvfs(path, &stat) == 0 {
            return Int64(stat.f_bavail) * Int64(stat.f_frsize)
        }
        if let attrs = try? FileManager.default.attributesOfFileSystem(forPath: path),
           let free = attrs[.systemFreeSize] as? NSNumber {
            return free.int64Value
        }
        return nil
    }

    // MARK: - Sauvegarde en ligne (fouine backup)

    /// Sauvegarde en ligne par l'API SQLite backup (GRDB `DatabasePool.backup(to:)`).
    ///
    /// N'acquiert PAS le verrou nommé `fouine.lock` : c'est une lecture d'instantané
    /// cohérent en ligne, l'agent d'arrière-plan et l'application continuent d'écrire
    /// en parallèle (§5.1, C2-06).
    ///
    /// NOTE CONCURRENCE (sqlite3_backup) :
    /// `DatabasePool.backup(to:)` enveloppe `sqlite3_backup_step`. En mode WAL,
    /// si un autre processus ou fil modifie des pages de la base pendant la copie,
    /// SQLite détecte la modification de version de page et reprend automatiquement
    /// la copie des pages modifiées jusqu'à obtenir un état strictement cohérent
    /// (code de retour `SQLITE_DONE`). La destination est donc un instantané cohérent
    /// même sous forte charge d'écriture concurrente.
    public func backup(
        to destination: URL,
        force: Bool = false,
        freeSpaceChecker: ((URL) -> Int64?)? = nil
    ) throws -> BackupReport {
        guard let sourceURL = databaseURL else {
            throw MaintenanceError("cannot backup: database is not open")
        }

        let standardizedDest = destination.standardizedFileURL
        let standardizedSource = sourceURL.standardizedFileURL

        // 1. Refus si destination == source
        if standardizedDest.path == standardizedSource.path {
            throw MaintenanceError("destination cannot be the source database: \(destination.path)")
        }

        // 2. Refus si destination sous le répertoire de la base
        let dbDir = standardizedSource.deletingLastPathComponent().path
        let destPath = standardizedDest.path
        if destPath == dbDir || destPath.hasPrefix(dbDir + "/") {
            throw MaintenanceError("destination cannot be inside the database directory: \(destination.path)")
        }

        // 3. Refus si la destination existe déjà (sauf --force)
        if FileManager.default.fileExists(atPath: destPath) && !force {
            throw MaintenanceError("destination file already exists: \(destination.path) (use --force to overwrite)")
        }

        // 4. Refus si espace libre < 1,2 * taille_db
        let sourceBytes = databaseBytes()
        let requiredBytes = Int64(ceil(Double(max(sourceBytes, 4096)) * 1.2))
        let destParentDir = standardizedDest.deletingLastPathComponent()

        let available = (freeSpaceChecker?(destParentDir)
                         ?? Self.availableDiskSpace(at: destParentDir))
                         ?? Int64.max

        if available < requiredBytes {
            throw MaintenanceError(
                "insufficient disk space at destination: \(available) bytes available, "
                + "\(requiredBytes) bytes required (1.2x database size of \(sourceBytes) bytes)"
            )
        }

        // Préparation du dossier de destination
        try FileManager.default.createDirectory(at: destParentDir, withIntermediateDirectories: true)

        // Si destination existante et --force, suppression préalable
        if FileManager.default.fileExists(atPath: destPath) {
            try? FileManager.default.removeItem(atPath: destPath)
            try? FileManager.default.removeItem(atPath: destPath + "-wal")
            try? FileManager.default.removeItem(atPath: destPath + "-shm")
        }

        let start = Date()

        // Exécution de la sauvegarde sans verrou nommé
        do {
            let destQueue = try DatabaseQueue(path: destPath)
            try (try pool).backup(to: destQueue)
        } catch {
            try? FileManager.default.removeItem(atPath: destPath)
            try? FileManager.default.removeItem(atPath: destPath + "-wal")
            try? FileManager.default.removeItem(atPath: destPath + "-shm")
            throw MaintenanceError("backup failed: \(error.localizedDescription)")
        }

        // Contrôles post-copie : quick_check puis FTS5 integrity-check
        do {
            try Self.verifyBackupIntegrity(at: standardizedDest)
        } catch {
            // Suppression de la copie en cas d'échec
            try? FileManager.default.removeItem(atPath: destPath)
            try? FileManager.default.removeItem(atPath: destPath + "-wal")
            try? FileManager.default.removeItem(atPath: destPath + "-shm")
            throw error
        }

        // DROITS 0600 SUR LA COPIE **ET SUR SES DEUX COMPAGNONS** (audit
        // A1-06, D2-09, corrigé par A1m-06). Seul le `.db` était refermé ;
        // le `-wal` et le `-shm` que `verifyBackupIntegrity` vient de créer
        // restaient en 0644, parce que SQLite les crée avec le mode du fichier
        // principal — c'est-à-dire AVANT ce chmod. Ils sont vides à cet
        // instant, mais le `-wal` d'une copie qu'on rouvre pour écrire porte le
        // texte des documents, et une sauvegarde est justement ce qu'on
        // recopie ailleurs. `restrictDatabase` referme les trois, en
        // best-effort : un échec n'est jamais une raison de jeter la copie.
        FilePermissions.restrictDatabase(at: URL(fileURLWithPath: destPath))

        let elapsed = Date().timeIntervalSince(start) * 1000.0
        let copySize = (try? FileManager.default.attributesOfItem(atPath: destPath)[.size] as? NSNumber)?.intValue ?? sourceBytes

        return BackupReport(
            destination: destPath,
            bytes: copySize,
            elapsedMS: elapsed,
            quickCheck: "ok",
            ftsIntegrity: "ok"
        )
    }

    /// Vérifie l'intégrité d'une copie sauvegardée.
    /// Exécute PRAGMA quick_check puis integrity-check sur les tables FTS5.
    public static func verifyBackupIntegrity(at destination: URL) throws {
        let queue = try DatabaseQueue(path: destination.path)
        let quickCheck = try queue.read { db -> String in
            try String.fetchOne(db, sql: "PRAGMA quick_check") ?? "unknown"
        }
        guard quickCheck.lowercased() == "ok" else {
            throw MaintenanceError("backup integrity verification failed: PRAGMA quick_check returned '\(quickCheck)'")
        }

        // FTS5 integrity-check utilise la syntaxe INSERT et nécessite une connexion autorisant l'écriture.
        do {
            try queue.writeWithoutTransaction { db in
                try db.execute(sql: "INSERT INTO page_fts(page_fts) VALUES('integrity-check')")
                try db.execute(sql: "INSERT INTO vocab_tri(vocab_tri) VALUES('integrity-check')")
            }
        } catch {
            throw MaintenanceError("backup FTS5 integrity-check failed: \(error.localizedDescription)")
        }
    }

    // MARK: - Cohérence de `docs_fts` (schéma v8, D-R3)

    /// Compte les documents et les noms indexés. Deux `count(*)` sur des tables
    /// de quelques milliers de lignes : une lecture, sans verrou.
    public func checkDocumentNames() throws -> DocNameCheck {
        try read { db in
            DocNameCheck(
                docs: try Int.fetchOne(db, sql: "SELECT count(*) FROM docs") ?? 0,
                names: try Int.fetchOne(db, sql: "SELECT count(*) FROM docs_fts") ?? 0)
        }
    }

    /// Reconstruit `docs_fts` depuis `docs`. Chemin de SECOURS de
    /// `maintain --repair` : la table est normalement tenue à jour dans la même
    /// transaction que `docs`, mais une base rattrapée à la main ou un arrêt
    /// brutal d'une version antérieure peut la laisser en écart.
    @discardableResult
    public func rebuildDocumentNames() throws -> DocNameCheck {
        try writeLocked { db in
            let filled = try Self.rebuildDocsFTS(db)
            return DocNameCheck(docs: filled, names: filled)
        }
    }

    // MARK: - Contrôle approfondi (fouine doctor --deep)

    /// Contrôle approfondi de la base (SPEC §4.3, C2-06).
    ///
    /// `PRAGMA quick_check` et les PRAGMA de mesure sont des lectures : sans
    /// verrou, comme tout `doctor`. L'`integrity-check` FTS5, lui, s'écrit
    /// `INSERT INTO t(t) VALUES('integrity-check')` : SQLite ouvre pour cette
    /// instruction une transaction d'ÉCRITURE — aucune page n'est modifiée, mais
    /// le verrou d'écriture du WAL est tenu pendant tout le parcours, ~3 min 30
    /// sur 1,8 Go (mesuré le 02/09/2026). Un agent ou une app qui écrirait
    /// pendant ce temps tomberait en `SQLITE_BUSY` après ses 5 s d'attente, sans
    /// savoir qui l'occupe. D'où le verrou NOMMÉ (rôle `cli`), pris pour cette
    /// seule phase et rendu au retour : l'autre écrivain lit « database locked by
    /// another process (cli, pid …) » et sort en 3, comme devant `fouine index`.
    /// `doctor` sans `--deep` ne prend toujours aucun verrou.
    ///
    /// `onStep` est appelé AU DÉBUT de chaque étape, avec son nom (MO-04) :
    /// 86 s de silence sur 2,2 Go ne disent pas si la commande travaille
    /// encore. L'appelant décide s'il l'affiche — `doctor --json` ne le fait
    /// pas, une ligne de progression au milieu d'un objet JSON le casserait.
    public func deepCheck(onStep: ((String) -> Void)? = nil) throws -> DeepCheckReport {
        let start = Date()
        let currentPool = try self.pool
        var steps: [MaintainStep] = []
        // Chronomètre par étape : `elapsedMS` seul disait 86 s sans dire de
        // quoi (MO-04). Le nom est un JETON stable (le JSON le publie), pas
        // une phrase.
        func timed<T>(_ name: String, _ body: () throws -> T) rethrows -> T {
            onStep?(name)
            let begin = Date()
            defer {
                steps.append(MaintainStep(
                    name: name, elapsedMS: Date().timeIntervalSince(begin) * 1000.0))
            }
            return try body()
        }

        let (pageCount, pageSize, freelistCount, journalMode, quickCheck) =
            try timed("quick_check") { try currentPool.read { db in
            let pc = try Int.fetchOne(db, sql: "PRAGMA page_count") ?? 0
            let ps = try Int.fetchOne(db, sql: "PRAGMA page_size") ?? 4096
            let fc = try Int.fetchOne(db, sql: "PRAGMA freelist_count") ?? 0
            let jm = try String.fetchOne(db, sql: "PRAGMA journal_mode") ?? "wal"

            // PRAGMA quick_check : vérifie les structures B-tree sans vérifier
            // la concordance exhaustive de chaque entrée d'index, bien plus rapide
            // qu'integrity_check sur une base de plusieurs Go.
            let qc = try String.fetchOne(db, sql: "PRAGMA quick_check") ?? "unknown"
            return (pc, ps, fc, jm, qc)
        } }

        // Cohérence de `page_vec` (audit A1m-05) : AVANT le verrou, parce que
        // c'est une lecture pure et que la tenir sous le verrou de
        // l'integrity-check FTS5 (3 min 30 sur 1,8 Go) allongerait pour rien
        // la fenêtre pendant laquelle l'agent voit la base occupée.
        let vectors = try timed("page_vec") { try checkVectors() }
        // `docs_fts` (schéma v8) : deux `count(*)` sur des tables de quelques
        // milliers de lignes — une lecture, comme la précédente, avant le
        // verrou de l'integrity-check FTS5.
        let docNames = try timed("docs_fts") { try checkDocumentNames() }

        // FTS5 integrity-check : syntaxe INSERT, donc transaction d'écriture SQLite
        // pendant toute la durée du parcours (voir l'en-tête). Verrou nommé pris
        // ici, pour cette phase seule ; le `defer` le rend au retour.
        try acquireWriteLock(as: .cli)
        defer { releaseWriteLock() }
        var ftsDetails: [String: String] = [:]
        timed("fts5_integrity") {
            currentPool.writeWithoutTransaction { db in
                do {
                    try db.execute(sql: "INSERT INTO page_fts(page_fts) VALUES('integrity-check')")
                    ftsDetails["page_fts"] = "ok"
                } catch {
                    ftsDetails["page_fts"] = error.localizedDescription
                }

                do {
                    try db.execute(sql: "INSERT INTO vocab_tri(vocab_tri) VALUES('integrity-check')")
                    ftsDetails["vocab_tri"] = "ok"
                } catch {
                    ftsDetails["vocab_tri"] = error.localizedDescription
                }
            }
        }

        let allFtsOk = ftsDetails.values.allSatisfy { $0 == "ok" }
        let ftsStatus = allFtsOk ? "ok" : "failed"

        let walBytes: Int
        if let dbURL = self.databaseURL {
            let walPath = dbURL.path + "-wal"
            walBytes = (try? FileManager.default.attributesOfItem(atPath: walPath)[.size] as? NSNumber)?.intValue ?? 0
        } else {
            walBytes = 0
        }

        let fragBytes = freelistCount * pageSize
        let fragPct = pageCount > 0 ? (Double(freelistCount) / Double(pageCount) * 100.0) : 0.0
        let elapsedMS = Date().timeIntervalSince(start) * 1000.0

        return DeepCheckReport(
            quickCheck: quickCheck,
            ftsIntegrity: ftsStatus,
            ftsDetails: ftsDetails,
            pageCount: pageCount,
            pageSize: pageSize,
            freelistCount: freelistCount,
            fragmentationPct: fragPct,
            fragmentationBytes: fragBytes,
            walBytes: walBytes,
            journalMode: journalMode,
            vectors: vectors,
            docNames: docNames,
            steps: steps,
            elapsedMS: elapsedMS
        )
    }

    // MARK: - Maintenance de la base (fouine maintain)

    /// Maintenance de la base (SPEC §4.3, C2-06).
    /// Prend le verrou nommé sous le rôle `cli` (sortie 3 si occupé).
    /// `repair` (audit A1m-05) : retire de `page_vec` les lignes qu'aucune
    /// pompe n'a pu écrire, AVANT les optimisations — l'`optimize` de FTS5 et
    /// le checkpoint n'ont aucune raison de recopier ce qui va partir. Sans
    /// l'option, `maintain` ne touche à AUCUNE donnée : c'est le contrat de la
    /// commande depuis C2-06, et il ne change pas.
    public func maintain(
        vacuum: Bool = false,
        force: Bool = false,
        repair: Bool = false,
        freeSpaceChecker: ((URL) -> Int64?)? = nil,
        progress: ((String) -> Void)? = nil
    ) throws -> MaintainReport {
        // Acquisition du verrou nommé flock(fouine.lock) en rôle .cli
        try acquireWriteLock(as: .cli)
        defer { releaseWriteLock() }

        let start = Date()
        let bytesBefore = databaseBytes()

        let currentPool = try self.pool
        var steps: [MaintainStep] = []

        // 0. Réparation de page_vec (--repair). Le verrou est déjà pris :
        // `repairVectors` passe par `writeLocked`, qui est idempotent.
        var vectorRepair: VectorRepairReport?
        var ocrFailuresCleared: Int?
        if repair {
            let t = Date()
            let report = try repairVectors()
            vectorRepair = report
            steps.append(MaintainStep(name: "page_vec repair",
                                      elapsedMS: Date().timeIntervalSince(t) * 1000.0))
            if report.total > 0 {
                progress?("removed \(report.total) inconsistent page_vec row(s); "
                          + "\(report.pagesRequeued) page(s) back in the `fouine embed` queue")
            } else {
                progress?("page_vec is consistent, nothing to repair")
            }

            // 0 bis. `docs_fts` (schéma v8) : reconstruite depuis `docs`, qui
            // en est la seule source. Quelques milliers de lignes, instantané —
            // on la refait sans se demander si elle est juste.
            let tNames = Date()
            let names = try rebuildDocumentNames()
            steps.append(MaintainStep(name: "docs_fts rebuild",
                                      elapsedMS: Date().timeIntervalSince(tNames) * 1000.0))
            progress?("rebuilt \(names.names) document name(s) in docs_fts")

            // 0 ter. La marque d'échec d'OCR des documents SANS page scannée
            // (IX2) : l'ancienne remise en masse la posait sur des
            // transcriptions. Une requête, sous le verrou déjà pris.
            let tOCR = Date()
            let cleared = try clearOCRFailuresWithoutScans()
            ocrFailuresCleared = cleared
            steps.append(MaintainStep(name: "OCR failure marks",
                                      elapsedMS: Date().timeIntervalSince(tOCR) * 1000.0))
            progress?(cleared > 0
                      ? "cleared the OCR failure mark of \(cleared) document(s) without any scanned page"
                      : "no OCR failure mark to clear")
        }

        // 1. page_fts optimize
        let t0 = Date()
        try currentPool.write { db in
            try db.execute(sql: "INSERT INTO page_fts(page_fts) VALUES('optimize')")
        }
        steps.append(MaintainStep(name: "page_fts optimize", elapsedMS: Date().timeIntervalSince(t0) * 1000.0))

        // 2. vocab_tri optimize
        let t1 = Date()
        try currentPool.write { db in
            try db.execute(sql: "INSERT INTO vocab_tri(vocab_tri) VALUES('optimize')")
        }
        steps.append(MaintainStep(name: "vocab_tri optimize", elapsedMS: Date().timeIntervalSince(t1) * 1000.0))

        // 3. PRAGMA optimize
        let t2 = Date()
        try currentPool.write { db in
            try db.execute(sql: "PRAGMA optimize")
        }
        steps.append(MaintainStep(name: "PRAGMA optimize", elapsedMS: Date().timeIntervalSince(t2) * 1000.0))

        // 4. PRAGMA wal_checkpoint(TRUNCATE)
        let t3 = Date()
        try currentPool.writeWithoutTransaction { db in
            try db.execute(sql: "PRAGMA wal_checkpoint(TRUNCATE)")
        }
        steps.append(MaintainStep(name: "wal_checkpoint(TRUNCATE)", elapsedMS: Date().timeIntervalSince(t3) * 1000.0))

        // 5. Option --vacuum
        var vacuumRan = false
        let stats = try currentPool.read { db -> (freelist: Int, pageSize: Int, pageCount: Int) in
            let fl = try Int.fetchOne(db, sql: "PRAGMA freelist_count") ?? 0
            let ps = try Int.fetchOne(db, sql: "PRAGMA page_size") ?? 4096
            let pc = try Int.fetchOne(db, sql: "PRAGMA page_count") ?? 0
            return (fl, ps, pc)
        }
        let freelistBefore = stats.freelist

        if vacuum {
            let dbDir = databaseURL?.deletingLastPathComponent() ?? URL(fileURLWithPath: ".")
            let required = Int64(bytesBefore) * 2
            let available = (freeSpaceChecker?(dbDir) ?? Self.availableDiskSpace(at: dbDir)) ?? Int64.max

            if available < required {
                throw MaintenanceError(
                    "insufficient disk space for VACUUM: \(available) bytes available, "
                    + "\(required) bytes required (2x database size of \(bytesBefore) bytes)"
                )
            }

            if freelistBefore == 0 && !force {
                progress?("freelist is 0 pages (0 bytes), VACUUM skipped (use --force to run anyway)")
            } else {
                let estimatedGain = freelistBefore * stats.pageSize
                let mb = max(1, Int(round(Double(bytesBefore) / (1024.0 * 1024.0))))
                let expectedSeconds = max(1, Int(ceil(Double(mb) / 800.0)))
                progress?("running VACUUM: estimated gain \(estimatedGain) bytes, reading \(mb) MB, this can take ~\(expectedSeconds) s...")
                let tv = Date()
                try currentPool.writeWithoutTransaction { db in
                    try db.execute(sql: "VACUUM")
                }
                steps.append(MaintainStep(name: "VACUUM", elapsedMS: Date().timeIntervalSince(tv) * 1000.0))
                vacuumRan = true
            }
        }

        // 6. Le WAL, une seconde fois — APRÈS le VACUUM (constat C2-21).
        //
        // `databaseBytes()` additionne `.db`, `-wal` et `-shm`. Mesurée juste
        // après le VACUUM, la somme comptait donc la base réécrite EN DOUBLE :
        // le WAL portait encore sa copie complète. `maintain --vacuum`
        // annonçait « 23 Mo -> 47 Mo, 0 octet récupéré » à l'instant même où il
        // venait d'en rendre 5,5 — et `bytesReclaimed = max(0, avant - après)`
        // écrasait le gain réel à zéro à tous les coups. Sur un fonds qui
        // approche le plafond, c'est le message le plus inquiétant possible, et
        // il était faux.
        if vacuumRan {
            let tw = Date()
            try currentPool.writeWithoutTransaction { db in
                try db.execute(sql: "PRAGMA wal_checkpoint(TRUNCATE)")
            }
            steps.append(MaintainStep(name: "wal_checkpoint(TRUNCATE) after VACUUM",
                                      elapsedMS: Date().timeIntervalSince(tw) * 1000.0))
        }

        let freelistAfter = try currentPool.read { db -> Int in
            try Int.fetchOne(db, sql: "PRAGMA freelist_count") ?? 0
        }

        let bytesAfter = databaseBytes()
        let bytesReclaimed = max(0, bytesBefore - bytesAfter)
        let totalElapsed = Date().timeIntervalSince(start) * 1000.0

        return MaintainReport(
            steps: steps,
            bytesBefore: bytesBefore,
            bytesAfter: bytesAfter,
            bytesReclaimed: bytesReclaimed,
            freelistBefore: freelistBefore,
            freelistAfter: freelistAfter,
            vacuumExecuted: vacuumRan,
            vectorRepair: vectorRepair,
            ocrFailuresCleared: ocrFailuresCleared,
            totalElapsedMS: totalElapsed
        )
    }
}
