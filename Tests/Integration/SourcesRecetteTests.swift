// SourcesRecetteTests.swift — `fouine sources` sur une base jetable (INT-F4).
// Propriété : A-Recette.
//
// Ce que la recette peut prouver ICI : la commande répond, son contrat `--json`
// tient, une source inconnue sort en 64, et rien n'écrit hors de la base
// jetable. Ce qu'elle NE PEUT PAS prouver sur cette machine : la lecture d'une
// vraie base d'Apple Notes (protégée par TCC, « Accès complet au disque » à
// accorder au binaire) ni celle de Bear (non installé). Ces deux lectures se
// prouvent en tests unitaires, sur des bases fabriquées au schéma réel.

import Foundation
import XCTest

final class SourcesRecetteTests: XCTestCase {

    private var scratch: Recette.Scratch!

    override func setUpWithError() throws {
        try XCTSkipIf(Recette.binary == nil,
                      "binaire absent : `make release-cli`")
        scratch = try Recette.makeIndexedScratch("sources")
    }

    override func tearDownWithError() throws {
        if let scratch {
            try? FileManager.default.removeItem(at: scratch.directory)
        }
    }

    /// `list` répond sur une base sans aucune source allumée : les trois
    /// applications sont citées, éteintes, avec zéro note recopiée.
    func testListOnAnUntouchedDatabase() throws {
        let result = try Recette.run(["sources", "list"], database: scratch.database)
        XCTAssertEqual(result.status, 0, result.describe)
        XCTAssertTrue(result.stdout.contains("notes"), result.stdout)
        XCTAssertTrue(result.stdout.contains("bear"), result.stdout)
        XCTAssertTrue(result.stdout.contains("anki"), result.stdout)
        XCTAssertTrue(result.stdout.contains("enabled=no"), result.stdout)
        XCTAssertTrue(result.stdout.contains("0 note(s) copied"), result.stdout)
    }

    /// Le contrat `--json` : trois entrées, les clés attendues, rien d'autre à
    /// deviner pour un script.
    func testListJSONContract() throws {
        let result = try Recette.run(["sources", "list", "--json"],
                                     database: scratch.database)
        XCTAssertEqual(result.status, 0, result.describe)
        let object = try JSONSerialization.jsonObject(
            with: Data(result.stdout.utf8)) as? [String: Any]
        let rows = try XCTUnwrap(object?["sources"] as? [[String: Any]])
        XCTAssertEqual(rows.count, 3)
        let ids = rows.compactMap { $0["id"] as? String }.sorted()
        XCTAssertEqual(ids, ["anki", "bear", "notes"])
        for row in rows {
            XCTAssertNotNil(row["name"] as? String)
            XCTAssertNotNil(row["enabled"] as? Bool)
            XCTAssertNotNil(row["present"] as? Bool)
            XCTAssertNotNil(row["access_denied"] as? Bool)
            XCTAssertNotNil(row["notes"] as? Int)
            XCTAssertNotNil(row["store"] as? String)
        }
    }

    /// Un nom inconnu est une erreur d'USAGE : code 64, et la liste des noms
    /// valides dans le message (§4.3, docs/cli.md).
    func testUnknownSourceIsAUsageError() throws {
        let result = try Recette.run(["sources", "enable", "evernote"],
                                     database: scratch.database)
        XCTAssertEqual(result.status, 64, result.describe)
        XCTAssertTrue(result.stderr.contains("notes"), result.stderr)
    }

    /// CM-19 : une commande qui rend un ÉCHEC ne doit pas avoir changé l'état.
    /// `sources enable bear` sortait en 1 — « not installed on this Mac » —
    /// après avoir écrit `sources.bear = true` : `sources list --json`
    /// annonçait ensuite `enabled: true` pour une source que rien ne lit.
    ///
    /// Se saute quand l'application EST installée : il n'y a alors pas d'échec
    /// à provoquer sans toucher aux notes de quelqu'un.
    func testEnablingAnAbsentSourceWritesNothing() throws {
        let listed = try Recette.run(["sources", "list", "--json"],
                                     database: scratch.database)
        let object = try JSONSerialization.jsonObject(
            with: Data(listed.stdout.utf8)) as? [String: Any]
        let rows = try XCTUnwrap(object?["sources"] as? [[String: Any]])
        let absent = rows.first { ($0["present"] as? Bool) == false }
        guard let id = absent?["id"] as? String else {
            throw XCTSkip("Apple Notes, Bear et Anki sont tous installés sur "
                          + "cette machine : aucun échec à provoquer sans "
                          + "toucher aux notes de quelqu'un")
        }

        let result = try Recette.run(["sources", "enable", id],
                                     database: scratch.database)
        XCTAssertEqual(result.status, 1, result.describe)
        XCTAssertTrue(result.stderr.contains("Setting left unchanged"),
                      result.stderr)
        XCTAssertFalse(result.stdout.contains("enabled"),
                       "rien n'a été allumé : " + result.stdout)

        let after = try Recette.run(["sources", "list", "--json"],
                                    database: scratch.database)
        let afterObject = try JSONSerialization.jsonObject(
            with: Data(after.stdout.utf8)) as? [String: Any]
        let afterRows = try XCTUnwrap(afterObject?["sources"] as? [[String: Any]])
        let row = try XCTUnwrap(afterRows.first { ($0["id"] as? String) == id })
        XCTAssertEqual(row["enabled"] as? Bool, false,
                       "la clé a été écrite malgré l'échec")
    }

    /// `sync` sans aucune source allumée ne fait rien et le dit — plutôt que de
    /// se taire, ce qui se lirait comme un échec silencieux.
    func testSyncWithoutAnyEnabledSourceSaysSo() throws {
        let result = try Recette.run(["sources", "sync"], database: scratch.database)
        XCTAssertEqual(result.status, 0, result.describe)
        XCTAssertTrue(result.stdout.contains("no application source enabled"),
                      result.stdout)
    }

    /// `--help` cite les quatre sous-commandes, et `docs/cli.md` les documente.
    func testHelpAndDocumentationAgree() throws {
        let help = try Recette.run(["sources", "--help"], database: scratch.database)
        XCTAssertEqual(help.status, 0)
        for sub in ["list", "enable", "disable", "sync"] {
            XCTAssertTrue(help.stdout.contains(sub), "`sources --help` doit citer \(sub)")
        }
        let doc = try String(
            contentsOf: Recette.packageRoot.appendingPathComponent("docs/cli.md"),
            encoding: .utf8)
        for sub in ["fouine sources list", "fouine sources enable",
                    "fouine sources disable", "fouine sources sync"] {
            XCTAssertTrue(doc.contains(sub), "docs/cli.md doit documenter `\(sub)`")
        }
    }
}
