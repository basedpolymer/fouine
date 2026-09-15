// StatusContractTests.swift — contrat de sortie de `status` et `doctor` (SPEC §4.3,
// §7.1). Propriété : A-Recette.
//
// AUDIT S3 (01/09/2026) : ces tests lisaient la base de PRODUCTION. Ce qu'ils
// vérifient est un CONTRAT DE SORTIE — les clés du §4.3 sont là, les compteurs
// annoncés sont ceux de la base, `doctor` sort en 0 sur un index sain, un
// préfixe trop court est refusé. Rien de tout cela n'a besoin du corpus
// personnel : une base jetable indexée suffit, et rend le test reproductible
// sur n'importe quelle machine.

import Foundation
import XCTest

final class StatusContractTests: XCTestCase {

    private var scratch: Recette.Scratch!
    private var database: URL { scratch.database }

    override func setUpWithError() throws {
        scratch = try Recette.makeIndexedScratch("statut")
    }

    override func tearDownWithError() throws {
        if let scratch {
            try? FileManager.default.removeItem(at: scratch.directory)
        }
    }

    /// Un `count(*)` lu directement dans la base, en `mode=ro` (§8) :
    /// `Recette.sqlite` ne l'ouvre jamais autrement qu'en lecture seule.
    private func count(_ sql: String) throws -> Int {
        let raw = try Recette.sqlite(sql, on: database)
        return Int(raw.trimmingCharacters(in: .whitespacesAndNewlines)) ?? -1
    }

    func testStatusJSONExposesTheFrozenKeys() throws {
        let result = try Recette.run(["status", "--json"], database: database)
        XCTAssertEqual(result.status, 0, result.describe)
        let object = try JSONSerialization.jsonObject(with: Data(result.stdout.utf8))
        let payload = try XCTUnwrap(object as? [String: Any])

        for key in ["docs_total", "docs_extracted", "docs_failed", "docs_skipped",
                    "pages_indexed", "pages_native", "pages_ocr_accurate",
                    "pages_ocr_low_conf", "pages_ocr_no_lines",
                    "ocr_queue_len", "db_bytes", "bytes_per_page"] {
            XCTAssertNotNil(payload[key] as? Int, "clé « \(key) » absente du §4.3")
        }
        XCTAssertGreaterThan(payload["bytes_per_page"] as? Int ?? 0, 0)

        // `db_path` (audit A1m-14) : la sortie texte l'affichait, le JSON non —
        // un script qui enchaîne `status` devait appeler `doctor` pour savoir
        // sur quel index il travaille.
        XCTAssertEqual(payload["db_path"] as? String, database.path)

        // `docs_without_language` (lot U3, R-10) : combien de documents
        // attendent encore que leur langue soit déterminée. Sur une base
        // fraîchement indexée, la réponse est zéro — la passe l'a fait.
        XCTAssertEqual(payload["docs_without_language"] as? Int, 0)

        // `semantic_campaign` (constat C2-11) : `null` quand personne ne
        // vectorise. La clé est TOUJOURS présente — un script qui la lit ne
        // doit pas avoir à distinguer « absente » de « aucune campagne ».
        XCTAssertNotNil(payload["semantic_campaign"],
                        "clé « semantic_campaign » absente")
        XCTAssertTrue(payload["semantic_campaign"] is NSNull,
                      "aucune campagne ne tourne sur une base jetable : "
                      + "\(payload["semantic_campaign"] ?? "nil")")

        // Contre-épreuve : sur un index VIDE, la plupart des assertions qui
        // suivent seraient vraies sans rien dire.
        XCTAssertEqual(payload["docs_extracted"] as? Int, scratch.documents)
        XCTAssertGreaterThan(payload["pages_indexed"] as? Int ?? 0, 0)

        // RC2 : la reconnaissance « rapide » d'avant D1 n'existe plus, et sa
        // clé non plus — ni nulle, ni à 0 : ABSENTE. Le compte annoncé des
        // pages scannées reste celui de la base.
        XCTAssertNil(payload["pages_ocr_fast"],
                     "pages_ocr_fast a disparu du contrat de status --json (RC2)")
        XCTAssertEqual(payload["pages_ocr_accurate"] as? Int,
                       try count("SELECT count(*) FROM page_src WHERE src = 2"),
                       "pages_ocr_accurate ne reflète pas page_src")

        // Amendement du 01/09/2026 (audit A6) : DEUX populations disjointes, et
        // non plus un seul seuil qui ne remontait que des pages blanches.
        // `conf = 0` est la sentinelle « aucune ligne reconnue » de
        // VisionOCREngine, pas une confiance faible.
        let doubtful = try XCTUnwrap(payload["pages_ocr_low_conf"] as? Int)
        let noLines = try XCTUnwrap(payload["pages_ocr_no_lines"] as? Int)
        XCTAssertEqual(doubtful, try count(
            "SELECT count(*) FROM page_src "
            + "WHERE src != 0 AND conf > 0 AND conf < 0.60"),
                       "pages_ocr_low_conf : les douteuses sont 0 < conf < 0,60")
        XCTAssertEqual(noLines, try count(
            "SELECT count(*) FROM page_src "
            + "WHERE src != 0 AND (conf IS NULL OR conf <= 0)"),
                       "pages_ocr_no_lines : les pages sans ligne sont conf <= 0")
        // Disjointes, et toutes deux incluses dans les pages OCRisées.
        let ocrPages = try count("SELECT count(*) FROM page_src WHERE src != 0")
        XCTAssertLessThanOrEqual(doubtful + noLines, ocrPages,
                                 "les deux populations se recouvrent")

        let roots = try XCTUnwrap(payload["roots"] as? [[String: Any]])
        XCTAssertFalse(roots.isEmpty)
        for root in roots {
            for key in ["label", "path"] {
                XCTAssertNotNil(root[key] as? String, "racine sans « \(key) »")
            }
            for key in ["enabled", "mounted", "readable"] {
                XCTAssertNotNil(root[key] as? Bool, "racine sans « \(key) »")
            }
        }

        // B1-05 : contrat de l'agent dans status --json
        let agent = try XCTUnwrap(payload["agent"] as? [String: Any])
        XCTAssertEqual(agent["known"] as? Bool, false)
        XCTAssertEqual(agent["report_published"] as? Bool, false)

        // MO-03 : `disk_budget` remplace la règle de trois « 1 M / 4 M ». Clé
        // ADDITIVE et toujours présente ; un index de recette est très loin du
        // budget, donc `level` vaut « ok » et rien n'avertit.
        let budget = try XCTUnwrap(payload["disk_budget"] as? [String: Any])
        for key in ["bytes", "budget_bytes", "bytes_at_full_vectors"] {
            XCTAssertNotNil(budget[key] as? Int, "disk_budget sans « \(key) »")
        }
        XCTAssertEqual(budget["budget_bytes"] as? Int, 2_500_000_000,
                       "le budget est celui de la SPEC, 2,5 × 10⁹ octets")
        XCTAssertEqual(budget["bytes"] as? Int, payload["db_bytes"] as? Int)
        XCTAssertGreaterThanOrEqual(budget["bytes_at_full_vectors"] as? Int ?? 0,
                                    budget["bytes"] as? Int ?? .max,
                                    "la projection ne peut pas être sous la taille du jour")
        XCTAssertEqual(budget["level"] as? String, "ok")
        let ratioNow = try XCTUnwrap((budget["ratio_now"] as? NSNumber)?.doubleValue)
        XCTAssertLessThan(ratioNow, 0.01, "un index de recette pèse quelques Mo")
        // `pages_at_budget` : un nombre dès qu'il y a des pages, `null` sur un
        // index vide — jamais une clé absente.
        XCTAssertNotNil(budget["pages_at_budget"])
        XCTAssertGreaterThan(budget["pages_at_budget"] as? Int ?? 0, 0)
    }

    func testDoctorSucceedsOnAHealthyIndex() throws {
        let result = try Recette.run(["doctor", "--json"], database: database)
        XCTAssertEqual(result.status, 0, result.describe)
        let payload = try XCTUnwrap(
            try JSONSerialization.jsonObject(with: Data(result.stdout.utf8))
                as? [String: Any])
        XCTAssertEqual(payload["ok"] as? Bool, true)
        let roots = try XCTUnwrap(payload["roots"] as? [[String: Any]])
        for root in roots {
            XCTAssertEqual(root["readable"] as? Bool, true,
                           "racine illisible : \(root["path"] ?? "?")")
        }

        // B1-05 : contrat de l'agent dans doctor --json
        let bgAgent = try XCTUnwrap(payload["background_agent"] as? [String: Any])
        XCTAssertNotNil(bgAgent["registered"] as? Bool)
        XCTAssertNotNil(bgAgent["status"] as? String)
    }

    func testStatusAndDoctorHumanReadableOutputForAgent() throws {
        let statusResult = try Recette.run(["status"], database: database)
        XCTAssertEqual(statusResult.status, 0, statusResult.describe)
        XCTAssertTrue(statusResult.stdout.contains("no report published yet"),
                      "status doit dire 'no report published yet' sur une base sans rapport")
        XCTAssertFalse(statusResult.stdout.contains("has never run"),
                       "status ne doit plus affirmer 'has never run' (B1-05)")

        let doctorResult = try Recette.run(["doctor"], database: database)
        XCTAssertEqual(doctorResult.status, 0, doctorResult.describe)
        XCTAssertTrue(doctorResult.stdout.contains("background agent :"),
                      "doctor doit inclure la ligne background agent")
    }

    /// MO-03 : la ligne `database` annonce l'échéance du budget, et `doctor` ne
    /// dit RIEN quand l'index en est loin — un diagnostic qui parle de plafond
    /// à qui en est à 0,3 % n'apprend rien et inquiète.
    func testTheDatabaseLineAnnouncesTheBudgetAndDoctorStaysQuietBelowIt() throws {
        let statusResult = try Recette.run(["status"], database: database)
        XCTAssertEqual(statusResult.status, 0, statusResult.describe)
        let line = try XCTUnwrap(
            statusResult.stdout.split(separator: "\n")
                .first { $0.hasPrefix("database") }.map(String.init),
            "aucune ligne « database » dans status")
        XCTAssertTrue(line.contains("at full meaning coverage"), line)
        XCTAssertTrue(line.contains("of the 2.5 GB budget"), line)
        XCTAssertTrue(line.contains("budget reached near"), line)
        XCTAssertFalse(line.contains("at 1 M"),
                       "la règle de trois linéaire est remplacée (MO-03) : \(line)")

        let doctorResult = try Recette.run(["doctor"], database: database)
        XCTAssertEqual(doctorResult.status, 0, doctorResult.describe)
        XCTAssertFalse(doctorResult.stdout.contains("disk budget"),
                       "doctor ne parle du budget qu'au-delà de 80 %")
    }

    /// CM-26 : `status --json` publie `write_lock`, EXACTEMENT sous la forme de
    /// `doctor --json`. Deux contrats donnaient deux réponses à la même
    /// question — l'outil MCP `fouine_status`, lui, le publiait déjà.
    func testStatusPublishesTheWriteLockLikeDoctor() throws {
        func writeLock(of command: [String]) throws -> [String: Any] {
            let result = try Recette.run(command, database: database)
            XCTAssertEqual(result.status, 0, result.describe)
            let payload = try XCTUnwrap(
                try JSONSerialization.jsonObject(with: Data(result.stdout.utf8))
                    as? [String: Any])
            return try XCTUnwrap(payload["write_lock"] as? [String: Any],
                                 "clé « write_lock » absente de "
                                 + command.joined(separator: " "))
        }
        let fromStatus = try writeLock(of: ["status", "--json"])
        let fromDoctor = try writeLock(of: ["doctor", "--json"])

        XCTAssertEqual(fromStatus["held"] as? Bool, false,
                       "personne n'écrit dans une base jetable au repos")
        XCTAssertEqual(fromStatus["status"] as? String, "free")
        XCTAssertEqual(fromStatus["probe"] as? String, "free")
        XCTAssertEqual(Set(fromStatus.keys), Set(fromDoctor.keys),
                       "les deux commandes doivent décrire le verrou de la "
                       + "même façon : \(fromStatus) / \(fromDoctor)")
    }

    /// C2-14 : « quel fichier n'a pas été lu ? » n'avait aucune réponse en
    /// ligne de commande. Sans l'option, la sortie ne bouge pas.
    func testUnreadableListsTheDocumentsFouineCouldNotRead() throws {
        // La base jetable en porte DÉJÀ un : le paquet `Notes.pages` que
        // `makeIndexedScratch` pose entre ses nuisances est un document iWork
        // sans aperçu QuickLook, donc `docs_failed`. (Une extension inconnue,
        // elle, n'entre jamais dans `docs` : le crawl l'écarte avant.)
        let plain = try Recette.run(["status"], database: database)
        XCTAssertTrue(plain.stdout.contains("failed 1"),
                      "la base jetable doit porter un document en échec :\n"
                      + plain.stdout)
        XCTAssertFalse(plain.stdout.contains("documents not read"),
                       "sans l'option, `status` ne change pas")

        let listed = try Recette.run(["status", "--unreadable"], database: database)
        XCTAssertEqual(listed.status, 0, listed.describe)
        XCTAssertTrue(listed.stdout.contains("documents not read"), listed.stdout)
        XCTAssertTrue(listed.stdout.contains("Notes.pages"),
                      "le document non lu doit être nommé :\n" + listed.stdout)

        let json = try Recette.run(["status", "--unreadable", "--json"],
                                   database: database)
        XCTAssertEqual(json.status, 0, json.describe)
        let payload = try XCTUnwrap(
            try JSONSerialization.jsonObject(with: Data(json.stdout.utf8))
                as? [String: Any])
        let rows = try XCTUnwrap(payload["unreadable"] as? [[String: Any]])
        XCTAssertGreaterThan(try XCTUnwrap(payload["unreadable_total"] as? Int), 0)
        let row = try XCTUnwrap(rows.first { ($0["path"] as? String)?
            .hasSuffix("Notes.pages") == true })
        for key in ["doc_id", "path", "ext", "reason", "status"] {
            XCTAssertNotNil(row[key], "clé « \(key) » absente de `unreadable`")
        }
        XCTAssertEqual(row["ext"] as? String, "pages")
        XCTAssertEqual(row["status"] as? String, "failed")
        XCTAssertFalse((row["reason"] as? String ?? "").isEmpty,
                       "un document non lu sans motif n'apprend rien")

        // Contre-épreuve : sans l'option, les deux clés sont absentes.
        let bare = try Recette.run(["status", "--json"], database: database)
        let barePayload = try XCTUnwrap(
            try JSONSerialization.jsonObject(with: Data(bare.stdout.utf8))
                as? [String: Any])
        XCTAssertNil(barePayload["unreadable"])
        XCTAssertNil(barePayload["unreadable_total"])
    }

    /// CM-12 : sur un index dont l'agent n'a rien fait depuis trois jours,
    /// `doctor` disait « not registered » et `ok: true`. Il dit désormais
    /// depuis quand, et le geste — sans changer `ok` : un Mac éteint trois
    /// jours n'a rien de cassé.
    func testDoctorSaysHowLongTheAgentHasBeenSilent() throws {
        // Un `agent_status` arrêté il y a 3 j 10 h, écrit comme l'agent
        // l'écrit : sept lignes clé/valeur dans `agent_status`.
        let since = Date().addingTimeInterval(-295_070)
        let iso = ISO8601DateFormatter()
        iso.formatOptions = [.withInternetDateTime]
        let rows = [
            ("phase", "stopped"), ("detail", "signal-received(SIGTERM)"),
            ("done", "0"), ("total", "0"),
            ("started_at", iso.string(from: since)),
            ("updated_at", iso.string(from: since)), ("pid", "72784"),
        ]
        let sql = rows.map {
            "INSERT INTO agent_status(key,value) VALUES('\($0.0)','\($0.1)') "
            + "ON CONFLICT(key) DO UPDATE SET value=excluded.value;"
        }.joined()
        try Recette.sqliteWrite(sql, on: database)

        let text = try Recette.run(["doctor"], database: database)
        XCTAssertEqual(text.status, 0, text.describe)
        XCTAssertTrue(text.stdout.contains("has not run since"),
                      "doctor doit dire depuis quand :\n" + text.stdout)
        // 295 070 s = 3 j et 9,96 h : la durée est TRONQUÉE, pas arrondie —
        // « 3 d 10 h » ferait croire à une précision qui n'existe pas.
        XCTAssertTrue(text.stdout.contains("(3 d 9 h)"),
                      "la durée doit être lisible :\n" + text.stdout)
        XCTAssertTrue(text.stdout.contains("Keep the index up to date automatically"),
                      "doctor doit donner le geste :\n" + text.stdout)

        let json = try Recette.run(["doctor", "--json"], database: database)
        XCTAssertEqual(json.status, 0, json.describe)
        let payload = try XCTUnwrap(
            try JSONSerialization.jsonObject(with: Data(json.stdout.utf8))
                as? [String: Any])
        let agent = try XCTUnwrap(payload["background_agent"] as? [String: Any])
        XCTAssertNotNil(agent["last_run"] as? String)
        XCTAssertEqual(agent["idle_seconds"] as? Int ?? 0, 295_070, accuracy: 120)
        XCTAssertNotNil(agent["guidance"] as? String)
        // Toujours présente, `null` sans journal : un script n'a pas à
        // distinguer « absente » de « pas de journal ».
        XCTAssertNotNil(agent["log_last_line"], "clé « log_last_line » absente")
        XCTAssertEqual(payload["ok"] as? Bool, true,
                       "le silence est un défaut à dire, pas un verdict de panne")
    }

    func testShortPrefixesAreRefusedWithAClearMessage() throws {
        // §5.5.1 : contrepartie de la suppression de prefix='2 3' (D3).
        //
        // Code 64, celui des erreurs d'ARGUMENT (docs/cli.md § codes de
        // sortie) : une requête que l'analyseur refuse est une faute de
        // frappe, pas une panne. Elle sortait en 1, dans le fourre-tout des
        // pannes, alors que `root add` et `config get` refusaient déjà leurs
        // arguments en 64.
        let result = try Recette.run(["search", "ch*"], database: database)
        XCTAssertEqual(result.status, 64,
                       "un préfixe de 2 lettres doit être refusé en 64")
        let message = result.stdout + result.stderr
        XCTAssertTrue(message.lowercased().contains("prefix"),
                      "message peu clair pour un préfixe trop court :\n" + message)
    }
}
