// MaintenanceRecetteTests.swift — Recette d'intégration pour backup, doctor --deep et maintain (C2-06).
// SPDX-License-Identifier: LicenseRef-Fouine-Source-Available

import Foundation
import XCTest
import FouineCore

final class MaintenanceRecetteTests: XCTestCase {

    private var scratch: Recette.Scratch!

    override func setUpWithError() throws {
        _ = try Recette.requireBinary()
        scratch = try Recette.makeIndexedScratch("maint-recette")
    }

    override func tearDownWithError() throws {
        if let scratch {
            try? FileManager.default.removeItem(at: scratch.directory)
        }
    }

    // MARK: - 1. fouine backup

    func testBackupJSONProducesValidSnapshotAndHonoursForce() throws {
        let backupDir = scratch.directory.deletingLastPathComponent()
            .appendingPathComponent("backup-dest-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: backupDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: backupDir) }

        let dest = backupDir.appendingPathComponent("copy.db")

        // 1. Sauvegarde nominale avec --json
        let res = try Recette.run(["backup", dest.path, "--json"], database: scratch.database)
        XCTAssertEqual(res.status, 0, res.describe)

        let obj = try JSONSerialization.jsonObject(with: Data(res.stdout.utf8)) as? [String: Any]
        let json = try XCTUnwrap(obj)
        XCTAssertEqual(json["destination"] as? String, dest.path)
        XCTAssertGreaterThan(json["bytes"] as? Int ?? 0, 0)
        XCTAssertEqual(json["quick_check"] as? String, "ok")
        XCTAssertEqual(json["fts_integrity"] as? String, "ok")
        XCTAssertNotNil(json["elapsed_ms"] as? Int)

        // Droits 0600
        let attrs = try FileManager.default.attributesOfItem(atPath: dest.path)
        let perms = (attrs[.posixPermissions] as? NSNumber)?.intValue ?? 0
        XCTAssertEqual(perms, 0o600)

        // 2. Refus si destination existe déjà sans --force (code 1)
        let resExists = try Recette.run(["backup", dest.path], database: scratch.database)
        XCTAssertEqual(resExists.status, 1, resExists.describe)
        XCTAssertTrue(resExists.stderr.contains("already exists"))

        // 3. Avec --force, écrase la copie existante avec succès (code 0)
        let resForce = try Recette.run(["backup", dest.path, "--force", "--json"], database: scratch.database)
        XCTAssertEqual(resForce.status, 0, resForce.describe)

        // 4. Refus si destination == source (code 1)
        let resSame = try Recette.run(["backup", scratch.database.path], database: scratch.database)
        XCTAssertEqual(resSame.status, 1, resSame.describe)
        XCTAssertTrue(resSame.stderr.contains("source database"))

        // 5. Refus si destination sous le répertoire de la base (code 1)
        let subDest = scratch.directory.appendingPathComponent("inner/copy.db")
        let resSub = try Recette.run(["backup", subDest.path], database: scratch.database)
        XCTAssertEqual(resSub.status, 1, resSub.describe)
        XCTAssertTrue(resSub.stderr.contains("inside the database directory"))

        // 6. Code 64 si argument manquant
        let resMissing = try Recette.run(["backup"], database: scratch.database)
        XCTAssertEqual(resMissing.status, 64, resMissing.describe)
    }

    // MARK: - 2. fouine doctor --deep

    func testDoctorDeepJSONExposesDatabaseIntegrityObject() throws {
        // Sans --deep : l'objet database est ABSENT (contrat gelé)
        let plainRes = try Recette.run(["doctor", "--json"], database: scratch.database)
        XCTAssertEqual(plainRes.status, 0, plainRes.describe)
        let plainObj = try JSONSerialization.jsonObject(with: Data(plainRes.stdout.utf8)) as? [String: Any]
        let plainJSON = try XCTUnwrap(plainObj)
        XCTAssertNil(plainJSON["database"], "sans --deep, doctor --json ne doit pas exposer 'database'")

        // Avec --deep : l'objet database est présent avec tous les champs requis
        let deepRes = try Recette.run(["doctor", "--deep", "--json"], database: scratch.database)
        XCTAssertEqual(deepRes.status, 0, deepRes.describe)
        let deepObj = try JSONSerialization.jsonObject(with: Data(deepRes.stdout.utf8)) as? [String: Any]
        let deepJSON = try XCTUnwrap(deepObj)
        let dbObj = try XCTUnwrap(deepJSON["database"] as? [String: Any])

        XCTAssertEqual(dbObj["quick_check"] as? String, "ok")
        XCTAssertEqual(dbObj["fts_integrity"] as? String, "ok")
        XCTAssertGreaterThan(dbObj["page_count"] as? Int ?? 0, 0)
        XCTAssertEqual(dbObj["page_size"] as? Int, 4096)
        XCTAssertNotNil(dbObj["freelist_count"] as? Int)
        XCTAssertNotNil(dbObj["wal_bytes"] as? Int)
        XCTAssertEqual(dbObj["journal_mode"] as? String, "wal")
        XCTAssertNotNil(dbObj["elapsed_ms"] as? Int)
    }

    // MARK: - 3. fouine maintain

    func testMaintainJSONExecutesAllSteps() throws {
        let res = try Recette.run(["maintain", "--json"], database: scratch.database)
        XCTAssertEqual(res.status, 0, res.describe)

        let obj = try JSONSerialization.jsonObject(with: Data(res.stdout.utf8)) as? [String: Any]
        let json = try XCTUnwrap(obj)
        XCTAssertGreaterThan(json["bytes_before"] as? Int ?? 0, 0)
        XCTAssertGreaterThan(json["bytes_after"] as? Int ?? 0, 0)
        XCTAssertNotNil(json["bytes_reclaimed"] as? Int)
        XCTAssertNotNil(json["freelist_before"] as? Int)
        XCTAssertNotNil(json["freelist_after"] as? Int)
        XCTAssertEqual(json["vacuum_executed"] as? Bool, false)
        XCTAssertNotNil(json["total_elapsed_ms"] as? Int)

        let steps = try XCTUnwrap(json["steps"] as? [[String: Any]])
        let stepNames = steps.compactMap { $0["name"] as? String }
        XCTAssertTrue(stepNames.contains("page_fts optimize"))
        XCTAssertTrue(stepNames.contains("vocab_tri optimize"))
        XCTAssertTrue(stepNames.contains("PRAGMA optimize"))
        XCTAssertTrue(stepNames.contains("wal_checkpoint(TRUNCATE)"))
    }

    func testMaintainVacuumWithForceRunsVacuum() throws {
        let res = try Recette.run(["maintain", "--vacuum", "--force", "--json"], database: scratch.database)
        XCTAssertEqual(res.status, 0, res.describe)

        let obj = try JSONSerialization.jsonObject(with: Data(res.stdout.utf8)) as? [String: Any]
        let json = try XCTUnwrap(obj)
        XCTAssertEqual(json["vacuum_executed"] as? Bool, true)
        let steps = try XCTUnwrap(json["steps"] as? [[String: Any]])
        let stepNames = steps.compactMap { $0["name"] as? String }
        XCTAssertTrue(stepNames.contains("VACUUM"))
    }

    /// `maintain --detect-languages` (lot U3, R-10) : le rattrapage de
    /// `docs.lang` depuis le texte DÉJÀ indexé, tout d'un coup.
    ///
    /// La recette part d'une base fraîchement indexée, donc de documents dont
    /// la langue a été écrite à l'extraction : on l'EFFACE d'abord, ce qui
    /// reproduit exactement l'état d'un fonds indexé avant que la détection
    /// existe (1 392 documents sur 1 499 dans la base réelle, mesure du 05/09).
    func testMaintainDetectLanguagesBackfillsTheColumn() throws {
        let store = GRDBStore()
        try store.open(at: scratch.database)
        let roots = try store.roots()
        var docIDs: [Int64] = []
        for root in roots {
            for row in try store.docs(underRoot: root.id) {
                try store.setDocLanguage(row.id, nil)
                docIDs.append(row.id)
            }
        }
        // La base de recette porte les fiches ET des documents d'appoint, dont
        // un que l'extraction écarte : les candidats au rattrapage sont les
        // documents EXTRAITS, on compte donc ce que la base dit.
        XCTAssertGreaterThanOrEqual(docIDs.count, scratch.documents)
        let candidates = try store.documentsWithoutLanguageCount()
        XCTAssertEqual(candidates, scratch.documents)
        // Le verrou est rendu : la commande qui suit doit pouvoir le prendre.
        store.releaseWriteLock()

        let res = try Recette.run(["maintain", "--detect-languages", "--json"],
                                  database: scratch.database)
        XCTAssertEqual(res.status, 0, res.describe)
        let obj = try JSONSerialization.jsonObject(with: Data(res.stdout.utf8)) as? [String: Any]
        let json = try XCTUnwrap(obj)
        let backfill = try XCTUnwrap(json["language_backfill"] as? [String: Any])
        XCTAssertEqual(backfill["scanned"] as? Int, candidates)
        XCTAssertEqual(backfill["remaining"] as? Int, 0)
        XCTAssertNotNil(backfill["elapsed_ms"] as? Int)
        let languages = try XCTUnwrap(backfill["languages"] as? [String: Int])
        XCTAssertEqual(languages.values.reduce(0, +), candidates)
        XCTAssertEqual(languages["fr"], scratch.documents,
                       "les fiches de la recette sont en français : \(languages)")

        // Sans l'option, la clé n'apparaît pas : `maintain` ne touche à aucune
        // donnée par défaut, c'est son contrat depuis C2-06.
        let plain = try Recette.run(["maintain", "--json"], database: scratch.database)
        XCTAssertEqual(plain.status, 0, plain.describe)
        let plainJSON = try XCTUnwrap(
            try JSONSerialization.jsonObject(with: Data(plain.stdout.utf8)) as? [String: Any])
        XCTAssertNil(plainJSON["language_backfill"])
    }

    /// `maintain --redetect-languages` (constat C2-01) : la détection ne lit
    /// plus la tête du document mais vote sur trois tranches — les documents
    /// qui portent DÉJÀ une langue sont donc ceux qu'il faut relire. Sur la
    /// base de production, 62 documents franco-anglais étaient rangés en
    /// hongrois, danois ou finnois à cause de leur page de garde.
    func testMaintainRedetectLanguagesRejudgesDocumentsThatAlreadyHaveOne() throws {
        // Un texte français précédé d'un préambule anglais, comme un Gutenberg.
        let preamble = String(repeating:
            "This ebook is for the use of anyone anywhere in the United States "
            + "and most other parts of the world at no cost and with almost no "
            + "restrictions whatsoever. ", count: 12)
        let body = String(repeating:
            "La chimie organique étudie les composés du carbone et les "
            + "réactions qui les transforment. Le catalyseur abaisse l'énergie "
            + "d'activation sans être consommé par la réaction. ", count: 60)
        try (preamble + body).write(
            to: scratch.root.appendingPathComponent("horla.txt"),
            atomically: true, encoding: .utf8)
        let indexed = try Recette.run(["index"], database: scratch.database,
                                      timeout: 300)
        XCTAssertEqual(indexed.status, 0, indexed.describe)

        // On lui colle une langue FAUSSE, celle qu'écrivait l'ancien
        // échantillon, et on vérifie que le rattrapage ordinaire ne la touche
        // pas — c'est bien pour cela que la nouvelle option existe.
        let store = GRDBStore()
        try store.open(at: scratch.database)
        let roots = try store.roots()
        var target: Int64 = 0
        for root in roots {
            for row in try store.docs(underRoot: root.id)
            where row.record.relPath.hasSuffix("horla.txt") {
                target = row.id
            }
        }
        XCTAssertNotEqual(target, 0, "le document témoin doit être indexé")
        try store.setDocLanguage(target, "hu")
        store.releaseWriteLock()

        let plain = try Recette.run(["maintain", "--detect-languages", "--json"],
                                    database: scratch.database)
        XCTAssertEqual(plain.status, 0, plain.describe)
        XCTAssertEqual(try language(of: target), "hu",
                       "`--detect-languages` ne prend que les documents SANS langue")

        let res = try Recette.run(["maintain", "--redetect-languages", "--json"],
                                  database: scratch.database, timeout: 300)
        XCTAssertEqual(res.status, 0, res.describe)
        let json = try XCTUnwrap(try JSONSerialization.jsonObject(
            with: Data(res.stdout.utf8)) as? [String: Any])
        let backfill = try XCTUnwrap(json["language_backfill"] as? [String: Any])
        XCTAssertGreaterThan(backfill["scanned"] as? Int ?? 0, scratch.documents,
                             "tous les documents extraits sont relus")
        XCTAssertEqual(backfill["remaining"] as? Int, 0)
        XCTAssertEqual(try language(of: target), "fr",
                       "le préambule anglais ne décide plus de la langue du livre")

        // La sortie TEXTE dit ce qui a été fait, en une ligne.
        let text = try Recette.run(["maintain", "--redetect-languages"],
                                   database: scratch.database, timeout: 300)
        XCTAssertEqual(text.status, 0, text.describe)
        XCTAssertTrue(text.stdout.contains("with a language"), text.stdout)
        XCTAssertTrue(text.stdout.contains("undetermined"), text.stdout)
    }

    /// La date qu'un document PORTE (constat PR-07) est écrite à
    /// l'extraction, et par là seulement : la facette « doc_year » range le
    /// courriel sous 2003 — l'année de son en-tête `Date:` — et non sous celle
    /// du fichier, et `fouine list --json` la rend.
    func testDocumentDatesAreWrittenAtExtractionAndFeedTheFacet() throws {
        try Data("""
        From: greffe@example.org
        To: moi@example.org
        Subject: Attestation catalyseur
        Date: Sat, 12 Apr 2003 10:30:00 +0200

        \(String(repeating: "attestation de situation, catalyseur et oxydation. ", count: 8))
        """.utf8).write(to: scratch.root.appendingPathComponent("attestation.eml"))
        let indexed = try Recette.run(["index"], database: scratch.database,
                                      timeout: 300)
        XCTAssertEqual(indexed.status, 0, indexed.describe)

        // La facette le voit, et `fouine list` porte la date en JSON.
        let facet = try Recette.run(
            ["search", "catalyseur", "--facet", "doc_year", "--json"],
            database: scratch.database)
        XCTAssertEqual(facet.status, 0, facet.describe)
        let facetJSON = try XCTUnwrap(try JSONSerialization.jsonObject(
            with: Data(facet.stdout.utf8)) as? [String: Any])
        let buckets = try XCTUnwrap(
            (facetJSON["facets"] as? [String: Any])?["doc_year"] as? [String: Any])
        XCTAssertNotNil(buckets["2003"], "\(buckets)")

        let list = try Recette.run(["list", "--json", "--limit", "50"],
                                   database: scratch.database)
        XCTAssertEqual(list.status, 0, list.describe)
        let documents = try XCTUnwrap((try JSONSerialization.jsonObject(
            with: Data(list.stdout.utf8)) as? [String: Any])?["documents"] as? [[String: Any]])
        let mail = try XCTUnwrap(documents.first {
            ($0["path"] as? String)?.hasSuffix("attestation.eml") == true
        })
        XCTAssertTrue((mail["doc_date"] as? String)?.hasPrefix("2003-04-12") == true,
                      "\(mail)")
        // Un document qui ne porte pas de date garde la cle, a `null`.
        let plain = try XCTUnwrap(documents.first {
            ($0["path"] as? String)?.hasSuffix(".txt") == true
        })
        XCTAssertTrue(plain["doc_date"] is NSNull, "\(plain)")
    }

    private func language(of docID: Int64) throws -> String? {
        let store = GRDBStore()
        try store.openReadOnly(at: scratch.database)
        for root in try store.roots() {
            for row in try store.docs(underRoot: root.id) where row.id == docID {
                return row.record.lang
            }
        }
        return nil
    }

    /// `maintain --vacuum` annonçait que l'index avait DOUBLÉ et que rien
    /// n'avait été récupéré, juste après avoir rendu 5,5 Mio (constat C2-21) :
    /// la taille était mesurée avant que le journal soit replié, donc la base
    /// réécrite comptait deux fois.
    func testMaintainVacuumReportsTheRealSize() throws {
        // De quoi libérer des pages : la moitié des fiches disparaissent.
        for index in 0..<(scratch.documents / 2) {
            try FileManager.default.removeItem(
                at: scratch.root.appendingPathComponent("fiche-\(index).txt"))
        }
        let reindexed = try Recette.run(["index"], database: scratch.database,
                                        timeout: 300)
        XCTAssertEqual(reindexed.status, 0, reindexed.describe)

        func fileBytes() throws -> Int {
            let attributes = try FileManager.default
                .attributesOfItem(atPath: scratch.database.path)
            return (attributes[.size] as? NSNumber)?.intValue ?? 0
        }
        let before = try fileBytes()

        let res = try Recette.run(["maintain", "--vacuum", "--force", "--json"],
                                  database: scratch.database, timeout: 300)
        XCTAssertEqual(res.status, 0, res.describe)
        let json = try XCTUnwrap(try JSONSerialization.jsonObject(
            with: Data(res.stdout.utf8)) as? [String: Any])
        let bytesBefore = json["bytes_before"] as? Int ?? 0
        let bytesAfter = json["bytes_after"] as? Int ?? 0
        let reclaimed = json["bytes_reclaimed"] as? Int ?? -1
        let after = try fileBytes()

        XCTAssertLessThanOrEqual(bytesAfter, bytesBefore,
                                 "un compactage ne fait pas GROSSIR l'index")
        XCTAssertEqual(Double(bytesAfter), Double(after), accuracy: 65_536,
                       "la taille annoncée est celle du fichier : "
                       + "\(bytesAfter) annoncés, \(after) sur le disque")
        if after < before {
            XCTAssertGreaterThan(reclaimed, 0,
                                 "le fichier a rétréci de \(before - after) o "
                                 + "et la commande annonce \(reclaimed)")
        }
    }

    /// CM-05 : la ligne `size` de `backup` est la taille RÉELLE du fichier.
    /// `%d` de `String(format:)` lit 32 bits ; au-delà de 2 Gio — la base de
    /// production les dépasse — la seule commande dont le métier est de dire
    /// « votre sauvegarde est faite » annonçait « -2143854592 bytes ».
    ///
    /// Une base de 2 Gio n'est pas fabricable en recette : ce qui se prouve
    /// ici, c'est que le nombre imprimé EST celui du fichier, et qu'il n'y a
    /// plus de `%d` sur le chemin.
    func testBackupPrintsTheRealSize() throws {
        // HORS du répertoire de la base : `backup` refuse une destination
        // posée à côté de la source, et ce refus-là est déjà éprouvé plus haut.
        let destDir = scratch.directory.deletingLastPathComponent()
            .appendingPathComponent("taille-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: destDir,
                                                withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: destDir) }
        let dest = destDir.appendingPathComponent("copie.db")

        let res = try Recette.run(["backup", dest.path], database: scratch.database)
        XCTAssertEqual(res.status, 0, res.describe)

        let line = try XCTUnwrap(
            res.stdout.split(separator: "\n").first { $0.contains("size ") },
            "ligne `size` absente :\n" + res.stdout)
        let printed = try XCTUnwrap(
            line.split(separator: ":").last?
                .trimmingCharacters(in: .whitespaces)
                .split(separator: " ").first.map(String.init)
                .flatMap(Int.init),
            "taille illisible : \(line)")
        let onDisk = (try FileManager.default
            .attributesOfItem(atPath: dest.path)[.size] as? NSNumber)?.intValue ?? -1

        XCTAssertGreaterThan(printed, 0, "une taille NÉGATIVE : \(line)")
        XCTAssertEqual(printed, onDisk,
                       "la ligne annonce \(printed) o, le fichier en fait \(onDisk)")
    }

    /// CM-06 : un `.db` recopié SEUL ne s'ouvre pas, et le message doit dire
    /// pourquoi — une copie, pas un plantage — puis le geste qui répare.
    func testAPlainCopyIsRefusedThenRepairedByMaintain() throws {
        let copy = scratch.directory
            .appendingPathComponent("copie-\(UUID().uuidString).db")
        defer { try? FileManager.default.removeItem(at: copy) }
        // La copie du SEUL `.db`, comme `cp`, Time Machine ou un transfert.
        try FileManager.default.copyItem(at: scratch.database, to: copy)

        let refused = try Recette.run(["status"], database: copy)
        XCTAssertEqual(refused.status, 3, refused.describe)
        XCTAssertTrue(refused.stderr.contains("was made without its -wal and -shm"),
                      "le refus doit nommer la cause :\n" + refused.stderr)
        XCTAssertTrue(refused.stderr.contains("fouine maintain"),
                      "le refus doit donner le geste :\n" + refused.stderr)
        XCTAssertFalse(refused.stderr.contains("after a crash"),
                       "rien n'a planté :\n" + refused.stderr)

        let repaired = try Recette.run(["maintain"], database: copy, timeout: 300)
        XCTAssertEqual(repaired.status, 0, repaired.describe)

        let after = try Recette.run(["status"], database: copy)
        XCTAssertEqual(after.status, 0, after.describe)
    }

    /// CM-20 : `FOUINE_DB` posé sur un DOSSIER. Le message envoyait lancer
    /// `fouine maintain` sur un répertoire.
    func testAFolderIsNotAnIndex() throws {
        let res = try Recette.run(["search", "azote"], database: scratch.directory)
        XCTAssertEqual(res.status, 3, res.describe)
        XCTAssertTrue(res.stderr.contains("is a folder, not a Fouine index"),
                      res.stderr)
        XCTAssertFalse(res.stderr.contains("maintain"),
                       "on n'envoie pas réparer un dossier :\n" + res.stderr)
    }

    func testMaintainFailsWithExitCode3WhenLocked() throws {
        // Simuler un autre processus qui tient le verrou fouine.lock
        let store = GRDBStore()
        try store.open(at: scratch.database)
        try store.acquireWriteLock(as: .agent)
        defer { store.releaseWriteLock() }

        let res = try Recette.run(["maintain"], database: scratch.database)
        XCTAssertEqual(res.status, 3, "maintain doit échouer avec le code 3 (verrou occupé) : \(res.describe)")
        XCTAssertTrue(res.stderr.contains("locked by another process") || res.stderr.contains("fouine-lock-busy"))
    }

    // MARK: - 4. Cohérence docs/cli.md ↔ --help

    func testDocsCliMatchesHelpSubcommandsAndOptions() throws {
        // 1. fouine --help
        let helpRes = try Recette.run(["--help"], database: scratch.database)
        XCTAssertEqual(helpRes.status, 0)

        // Lire docs/cli.md
        let repoRoot = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent() // Tests/Integration
            .deletingLastPathComponent() // Tests
            .deletingLastPathComponent() // root
        let docURL = repoRoot.appendingPathComponent("docs/cli.md")
        let docContent = try String(contentsOf: docURL, encoding: .utf8)

        // Vérifier que chaque sous-commande de fouine --help est documentée dans docs/cli.md
        let subcommands = ["root", "volume", "crawl", "extract", "ocr", "index",
                           "embed", "model", "search", "config", "status", "doctor",
                           "backup", "maintain",
                           // Lot INT-F4 : les notes des applications.
                           "sources",
                           // Lot BR1 : parcourir l'index (constat PR-06).
                           "list",
                           // Lot MC3 : lire une page, et ses voisines (PM-18).
                           "read", "similar"]
        for sub in subcommands {
            XCTAssertTrue(helpRes.stdout.contains(sub), "fouine --help doit lister '\(sub)'")
            XCTAssertTrue(docContent.contains("fouine \(sub)"), "docs/cli.md doit documenter 'fouine \(sub)'")
        }

        // Vérifier les options des nouvelles commandes
        let backupHelp = try Recette.run(["backup", "--help"], database: scratch.database)
        XCTAssertEqual(backupHelp.status, 0)
        XCTAssertTrue(backupHelp.stdout.contains("--force"))
        XCTAssertTrue(backupHelp.stdout.contains("--json"))

        let maintainHelp = try Recette.run(["maintain", "--help"], database: scratch.database)
        XCTAssertEqual(maintainHelp.status, 0)
        XCTAssertTrue(maintainHelp.stdout.contains("--vacuum"))
        XCTAssertTrue(maintainHelp.stdout.contains("--detect-languages"))
        XCTAssertTrue(maintainHelp.stdout.contains("--redetect-languages"))
        XCTAssertTrue(maintainHelp.stdout.contains("--force"))
        XCTAssertTrue(maintainHelp.stdout.contains("--json"))

        let doctorHelp = try Recette.run(["doctor", "--help"], database: scratch.database)
        XCTAssertEqual(doctorHelp.status, 0)
        XCTAssertTrue(doctorHelp.stdout.contains("--deep"))

        // C2-14 : l'option qui liste les documents non lus.
        let statusHelp = try Recette.run(["status", "--help"], database: scratch.database)
        XCTAssertEqual(statusHelp.status, 0)
        XCTAssertTrue(statusHelp.stdout.contains("--unreadable"))
        XCTAssertTrue(docContent.contains("--unreadable"),
                      "docs/cli.md doit documenter `status --unreadable`")

        let mcpInstallHelp = try Recette.run(["mcp", "install", "--help"], database: scratch.database)
        XCTAssertEqual(mcpInstallHelp.status, 0)
        XCTAssertTrue(mcpInstallHelp.stdout.contains("--client"))
        XCTAssertTrue(mcpInstallHelp.stdout.contains("--dry-run"))
        XCTAssertTrue(mcpInstallHelp.stdout.contains("--json"))

        // PR-06 : les options de `fouine list`, documentées comme les autres.
        let listHelp = try Recette.run(["list", "--help"], database: scratch.database)
        XCTAssertEqual(listHelp.status, 0)
        for option in ["--folder", "--ext", "--path-contains", "--state",
                       "--order", "--limit", "--offset", "--json"] {
            XCTAssertTrue(listHelp.stdout.contains(option),
                          "`fouine list --help` doit annoncer \(option)")
            XCTAssertTrue(docContent.contains(option),
                          "docs/cli.md doit documenter \(option)")
        }

        // MC3 : les options des deux commandes de lecture, et celles que
        // `embed` a gagnées, documentées comme les autres.
        let readHelp = try Recette.run(["read", "--help"], database: scratch.database)
        XCTAssertEqual(readHelp.status, 0)
        for option in ["--max-chars", "--offset", "--context", "--json"] {
            XCTAssertTrue(readHelp.stdout.contains(option),
                          "`fouine read --help` doit annoncer \(option)")
            XCTAssertTrue(docContent.contains(option),
                          "docs/cli.md doit documenter \(option)")
        }
        let similarHelp = try Recette.run(["similar", "--help"],
                                          database: scratch.database)
        XCTAssertEqual(similarHelp.status, 0)
        for option in ["--limit", "--folder", "--ext", "--min-cosine",
                       "--preview-chars", "--no-exclude-same-document",
                       // CL2 : encoder la page à la volée (PM-07).
                       "--encode"] {
            XCTAssertTrue(similarHelp.stdout.contains(option),
                          "`fouine similar --help` doit annoncer \(option)")
            XCTAssertTrue(docContent.contains(option),
                          "docs/cli.md doit documenter \(option)")
        }
        // CL2 : les deux options que `search` a gagnées.
        let searchHelp = try Recette.run(["search", "--help"],
                                         database: scratch.database)
        XCTAssertEqual(searchHelp.status, 0)
        for option in ["--mark", "--hybrid-auto"] {
            XCTAssertTrue(searchHelp.stdout.contains(option),
                          "`fouine search --help` doit annoncer \(option)")
            XCTAssertTrue(docContent.contains(option),
                          "docs/cli.md doit documenter \(option)")
        }

        let embedHelp = try Recette.run(["embed", "--help"],
                                        database: scratch.database)
        XCTAssertEqual(embedHelp.status, 0)
        for option in ["--folder", "--include-tables"] {
            XCTAssertTrue(embedHelp.stdout.contains(option),
                          "`fouine embed --help` doit annoncer \(option)")
            XCTAssertTrue(docContent.contains(option),
                          "docs/cli.md doit documenter \(option)")
        }

        let ocrRequeueHelp = try Recette.run(["ocr", "requeue", "--help"], database: scratch.database)
        XCTAssertEqual(ocrRequeueHelp.status, 0)
        XCTAssertTrue(ocrRequeueHelp.stdout.contains("--doubtful"))
        XCTAssertTrue(ocrRequeueHelp.stdout.contains("--no-lines"))
        XCTAssertTrue(ocrRequeueHelp.stdout.contains("--limit"))
        XCTAssertTrue(ocrRequeueHelp.stdout.contains("--json"))
    }
}
