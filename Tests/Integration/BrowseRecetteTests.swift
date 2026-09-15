// BrowseRecetteTests.swift — recette de `fouine list` et du refus de `fouine
// ocr` sous verrou (lot BR1, constats PR-06 et CM-26). Propriété : A-Recette.
//
// Base JETABLE indexée (régime par défaut de la recette, audit S3) : ce qui se
// vérifie ici est un CONTRAT DE SORTIE — les clés du JSON sont celles de l'outil
// MCP, la pagination ne recouvre rien, les valeurs refusées sortent en 64, et
// une passe d'OCR sous verrou sort en 3 avec UNE ligne. Rien de tout cela n'a
// besoin du corpus personnel.

import Foundation
import XCTest
import FouineCore

final class BrowseRecetteTests: XCTestCase {

    private var scratch: Recette.Scratch!
    private var database: URL { scratch.database }

    override func setUpWithError() throws {
        scratch = try Recette.makeIndexedScratch("parcourir")
    }

    override func tearDownWithError() throws {
        if let scratch {
            try? FileManager.default.removeItem(at: scratch.directory)
        }
    }

    private func listJSON(_ extra: [String] = []) throws -> [String: Any] {
        let result = try Recette.run(["list", "--json"] + extra, database: database)
        XCTAssertEqual(result.status, 0, result.describe)
        let object = try JSONSerialization.jsonObject(with: Data(result.stdout.utf8))
        return try XCTUnwrap(object as? [String: Any])
    }

    // MARK: - PR-06 : on peut enfin parcourir

    /// Les clés sont EXACTEMENT celles de `fouine_list_documents` : un script
    /// écrit sur le serveur MCP doit lire la CLI sans traduction.
    func testListJSONCarriesTheKeysOfTheMCPTool() throws {
        let payload = try listJSON()
        XCTAssertGreaterThan(payload["total"] as? Int ?? 0, 0)
        XCTAssertNotNil(payload["has_more"] as? Bool)
        XCTAssertNotNil(payload["truncated"] as? Bool)

        let documents = try XCTUnwrap(payload["documents"] as? [[String: Any]])
        XCTAssertFalse(documents.isEmpty)
        let first = documents[0]
        XCTAssertNotNil(first["doc_id"] as? Int, first.description)
        for key in ["path", "link", "folder", "ext", "state", "modified"] {
            XCTAssertFalse((first[key] as? String ?? "").isEmpty,
                           "clé « \(key) » absente ou vide de documents[0]")
        }
        XCTAssertNotNil(first["pages"] as? Int)
        XCTAssertEqual(first["folder"] as? String, scratch.label)
        // Le lien rouvre Fouine sur le DOCUMENT, sans page : un listage désigne
        // des documents (même règle que l'outil MCP).
        let link = try XCTUnwrap(first["link"] as? String)
        XCTAssertTrue(link.hasPrefix("fouine://"), link)
        XCTAssertFalse(link.contains("page="), link)
        // `modified` est comparable par un script : ISO 8601 complet.
        let modified = try XCTUnwrap(first["modified"] as? String)
        XCTAssertNotNil(ISO8601DateFormatter().date(from: modified), modified)
    }

    /// La table dit ce qu'elle montre et sur combien, et la pagination ne
    /// recouvre ni ne saute de ligne (l'ordre du cœur est total).
    func testListPagesWithoutOverlap() throws {
        let all = try listJSON(["--order", "path", "--limit", "500"])
        let total = try XCTUnwrap(all["total"] as? Int)
        XCTAssertGreaterThanOrEqual(total, scratch.documents)

        let first = try Recette.run(["list", "--order", "path", "--limit", "2"],
                                    database: database)
        XCTAssertEqual(first.status, 0, first.describe)
        XCTAssertTrue(first.stdout.contains("2 of \(total) documents"),
                      first.describe)
        // Le geste de la suite est DIT : sans lui, personne ne devine `--offset`.
        XCTAssertTrue(first.stdout.contains("--offset 2"), first.describe)

        let second = try listJSON(["--order", "path", "--limit", "2",
                                   "--offset", "2"])
        func ids(_ payload: [String: Any]) throws -> [Int] {
            try XCTUnwrap(payload["documents"] as? [[String: Any]])
                .compactMap { $0["doc_id"] as? Int }
        }
        let head = try ids(listJSON(["--order", "path", "--limit", "2"]))
        let next = try ids(second)
        XCTAssertEqual(head.count, 2)
        XCTAssertEqual(next.count, 2)
        XCTAssertTrue(Set(head).isDisjoint(with: Set(next)),
                      "deux tranches consécutives ne partagent aucun document")
        let expected = try ids(all).prefix(4)
        XCTAssertEqual(head + next, Array(expected),
                       "les deux tranches redonnent le début de la liste complète")
    }

    /// `--state failed --state skipped` rend EXACTEMENT ce que
    /// `status --unreadable` rend : deux surfaces, une population.
    func testUnreadableStatesMatchStatusUnreadable() throws {
        let status = try Recette.run(["status", "--unreadable", "--json"],
                                     database: database)
        XCTAssertEqual(status.status, 0, status.describe)
        let object = try JSONSerialization.jsonObject(with: Data(status.stdout.utf8))
        let payload = try XCTUnwrap(object as? [String: Any])
        let expected = Set(try XCTUnwrap(payload["unreadable"] as? [[String: Any]])
            .compactMap { $0["doc_id"] as? Int })

        let listed = try listJSON(["--state", "failed", "--state", "skipped",
                                   "--limit", "500"])
        let got = Set(try XCTUnwrap(listed["documents"] as? [[String: Any]])
            .compactMap { $0["doc_id"] as? Int })
        XCTAssertEqual(got, expected)
        XCTAssertEqual(listed["total"] as? Int,
                       (payload["docs_failed"] as? Int ?? 0)
                       + (payload["docs_skipped"] as? Int ?? 0))
    }

    /// Les filtres portent, et un état demandé seul ne rend que lui.
    func testFiltersNarrowTheList() throws {
        let byExtension = try listJSON(["--ext", "txt", "--limit", "500"])
        let documents = try XCTUnwrap(byExtension["documents"] as? [[String: Any]])
        XCTAssertFalse(documents.isEmpty)
        for document in documents {
            XCTAssertEqual(document["ext"] as? String, "txt")
        }

        let byName = try listJSON(["--path-contains", "fiche-0"])
        for document in try XCTUnwrap(byName["documents"] as? [[String: Any]]) {
            XCTAssertTrue((document["path"] as? String ?? "").contains("fiche-0"))
        }

        let indexed = try listJSON(["--state", "indexed", "--limit", "500"])
        for document in try XCTUnwrap(indexed["documents"] as? [[String: Any]]) {
            XCTAssertEqual(document["state"] as? String, "indexed")
        }
    }

    /// Une valeur que la commande ou l'index contredit sort en 64 (usage), avec
    /// les valeurs possibles — jamais en 1, et jamais « 0 of 0 documents », qui
    /// serait indiscernable d'un dossier réellement vide.
    func testUnknownValuesAreRefusedAsUsageErrors() throws {
        let state = try Recette.run(["list", "--state", "zzz"], database: database)
        XCTAssertEqual(state.status, 64, state.describe)
        for value in ["indexed", "failed", "skipped", "pending"] {
            XCTAssertTrue(state.stderr.contains(value), state.stderr)
        }

        let order = try Recette.run(["list", "--order", "zzz"], database: database)
        XCTAssertEqual(order.status, 64, order.describe)
        for value in ["path", "pages", "recent"] {
            XCTAssertTrue(order.stderr.contains(value), order.stderr)
        }

        let folder = try Recette.run(["list", "--folder", "Inconnu"],
                                     database: database)
        XCTAssertEqual(folder.status, 64, folder.describe)
        XCTAssertTrue(folder.stderr.contains(scratch.label),
                      "le refus nomme les dossiers réels : " + folder.stderr)

        let limit = try Recette.run(["list", "--limit", "5000"], database: database)
        XCTAssertEqual(limit.status, 64, limit.describe)
        XCTAssertTrue(limit.stderr.contains("500"), limit.stderr)
    }

    /// Lecture seule : parcourir n'installe pas de verrou et ne crée pas de base
    /// (même garantie que `search`, `status` et `doctor`).
    func testListNeverTakesTheWriteLock() throws {
        let lock = FouinePaths.lockURL(for: database)
        try? FileManager.default.removeItem(at: lock)
        let result = try Recette.run(["list"], database: database)
        XCTAssertEqual(result.status, 0, result.describe)
        XCTAssertFalse(FileManager.default.fileExists(atPath: lock.path),
                       "`fouine list` ne doit pas créer le verrou d'écriture")

        let missing = scratch.directory.appendingPathComponent("absente.db")
        let refused = try Recette.run(["list"], database: missing)
        XCTAssertEqual(refused.status, 3, refused.describe)
        XCTAssertFalse(FileManager.default.fileExists(atPath: missing.path),
                       "un index absent se refuse, il ne se fabrique pas")
    }

    // MARK: - CM-26 : `fouine ocr` sous verrou

    /// File non vide et verrou tenu par un autre programme : UNE ligne sur
    /// stderr, code 3, et rien n'est tenté page par page.
    ///
    /// AVANT (constat CM-26) : la file se tirant par une LECTURE, la passe
    /// partait, préchauffait Vision, échouait à l'écriture de CHAQUE page et
    /// sortait en 0 — un script qui enchaîne les passes ne voyait aucune erreur.
    func testOCRRefusesInThreeWhenTheIndexIsLocked() throws {
        // Une page en file, fabriquée directement : la recette n'a pas de scan à
        // OCRiser, et ce qui est éprouvé ici est le REFUS, pas la lecture.
        let docID = try Recette.sqlite("SELECT id FROM docs LIMIT 1", on: database)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        XCTAssertFalse(docID.isEmpty)
        try Recette.sqliteWrite("""
            INSERT OR REPLACE INTO ocr_queue(doc_id, page, prio, attempts)
            VALUES (\(docID), 1, 0, 0)
            """, on: database)

        // Un autre processus — l'agent — tient le verrou, comme le fait
        // `MaintenanceRecetteTests` pour `maintain`.
        let store = GRDBStore()
        try store.open(at: database)
        try store.acquireWriteLock(as: .agent)
        defer { store.releaseWriteLock() }

        let result = try Recette.run(["ocr"], database: database, timeout: 120)
        XCTAssertEqual(result.status, 3,
                       "le verrou occupé est un échec de base (§4.3) : "
                       + result.describe)
        XCTAssertTrue(result.stderr.contains("locked"), result.stderr)
        // UNE ligne, pas une par page.
        let lines = result.stderr.split(whereSeparator: \.isNewline)
            .filter { $0.contains("locked") }
        XCTAssertEqual(lines.count, 1, result.stderr)
        // Rien n'a été tenté : ni préchauffage du moteur, ni page.
        XCTAssertFalse(result.stdout.contains("warmed up"), result.stdout)
        XCTAssertFalse(result.stdout.contains("OCR:"), result.stdout)
        // La file est INTACTE : la page attend toujours.
        let queued = try Recette.sqlite("SELECT count(*) FROM ocr_queue",
                                        on: database)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        XCTAssertEqual(queued, "1")
    }

    /// File VIDE : `fouine ocr` reste un no-op à 0, verrou tenu ou pas — c'est
    /// ce que l'agent et l'application appellent en boucle, et refuser là
    /// transformerait une absence de travail en panne.
    func testOCRWithAnEmptyQueueStillSucceedsWhileLocked() throws {
        try Recette.sqliteWrite("DELETE FROM ocr_queue", on: database)
        let store = GRDBStore()
        try store.open(at: database)
        try store.acquireWriteLock(as: .agent)
        defer { store.releaseWriteLock() }

        let result = try Recette.run(["ocr"], database: database, timeout: 300)
        XCTAssertEqual(result.status, 0, result.describe)
    }
}
