// IndexHygieneTests.swift — T8 (volet 1) et T10 (SPEC §8.1). Propriété : A-Recette.
//
// T8 volet 2 — révocation de l'accès « Dossier Documents » dans Réglages Système —
// n'est PAS automatisable : aucun processus ne peut retirer sa propre autorisation
// TCC. La procédure manuelle est décrite dans la recette du 31/08/2026 (rapport interne) et n'est pas simulée ici :
// un test qui simulerait la révocation ne testerait rien.
//
// AUDIT S3 (01/09/2026) : ces deux tests tournaient sur la BASE DE PRODUCTION,
// et T10 y relançait `fouine index` — chaque `make test` réindexait le corpus du
// mainteneur pendant que l'agent écrivait dans la même base. Ils tournent
// désormais sur une base et une racine JETABLES : ce qu'ils vérifient est du
// COMPORTEMENT (le crawl écarte les nuisances, un second `index` n'extrait
// rien), pas une propriété du corpus personnel — et sur une racine fabriquée,
// les nuisances sont RÉELLEMENT présentes, donc l'exclusion est réellement
// exercée au lieu d'être constatée par une absence.

import Foundation
import XCTest

final class IndexHygieneTests: XCTestCase {

    private var scratch: Recette.Scratch!
    private var database: URL { scratch.database }

    override func setUpWithError() throws {
        scratch = try Recette.makeIndexedScratch("hygiene")
    }

    override func tearDownWithError() throws {
        if let scratch {
            try? FileManager.default.removeItem(at: scratch.directory)
        }
    }

    // MARK: - T8 volet 1 · propreté des rel_path

    func testT8NoJunkPathsIndexed() throws {
        // La racine jetable PORTE ces nuisances (voir `makeIndexedScratch`) :
        // le test échoue vraiment si le crawl se met à les suivre.
        let raw = try Recette.sqlite("""
            SELECT rel_path FROM docs
            WHERE rel_path LIKE '%/._%'
               OR rel_path LIKE '%/.DS_Store%'
               OR rel_path LIKE '%/.Spotlight-V100/%'
               OR rel_path LIKE '%/.Trashes/%'
               OR rel_path LIKE '%/.fseventsd/%'
               OR rel_path LIKE '%/.git/%'
            """, on: database)
        let offenders = raw.split(separator: "\n").map(String.init)
        XCTAssertTrue(offenders.isEmpty,
                      "chemins parasites indexés : \(offenders.prefix(10))")

        // Contre-épreuve : les fiches, elles, sont bien là — sans quoi
        // « aucun chemin parasite » serait vrai d'un index vide.
        let indexed = try Recette.sqlite("SELECT count(*) FROM docs WHERE ext = 'txt'", on: database)
        XCTAssertEqual(indexed.trimmingCharacters(in: .whitespacesAndNewlines),
                       "\(scratch.documents)",
                       "l'index jetable ne contient pas les documents attendus")
    }

    func testT8PackagesAreNeverTraversed() throws {
        // Un paquet iWork (.pages, .key) est un document unique : aucun rel_path
        // ne doit en faire un COMPOSANT de dossier (SPEC §5.2, T8).
        let raw = try Recette.sqlite("""
            SELECT rel_path FROM docs
            WHERE rel_path LIKE '%.pages/%' OR rel_path LIKE '%.key/%'
            """, on: database)
        let offenders = raw.split(separator: "\n").map(String.init)
        XCTAssertTrue(offenders.isEmpty,
                      "paquet parcouru comme un dossier : \(offenders.prefix(10))")

        // Le paquet Notes.pages entre bien comme 1 document unique (audit E4, D2 § 5.12)
        // et son refus explicite est lisible dans docs.err sans aperçu.
        let asDoc = try Recette.sqlite(
            "SELECT count(*) FROM docs WHERE ext IN ('pages','key')", on: database)
        XCTAssertEqual(asDoc.trimmingCharacters(in: .whitespacesAndNewlines), "1")

        let docRow = try Recette.sqlite(
            "SELECT state, err FROM docs WHERE ext = 'pages'", on: database)
        XCTAssertTrue(docRow.contains("iWork document without a QuickLook preview"), docRow)
    }

    func testT8RootLabelsAreFacetLabels() throws {
        let raw = try Recette.sqlite(
            "SELECT DISTINCT top_folder FROM docs ORDER BY 1", on: database)
        let labels = Set(raw.split(separator: "\n").map(String.init))
        XCTAssertFalse(labels.contains("Users"),
                       "top_folder = « Users » : le 1er segment du chemin a été "
                       + "utilisé au lieu du label de racine (§5.2)")
        XCTAssertFalse(labels.contains("private"),
                       "top_folder = « private » : le 1er segment du chemin a été "
                       + "utilisé au lieu du label de racine (§5.2)")
        XCTAssertEqual(labels, [scratch.label],
                       "le label de racine n'est pas l'étiquette de facette")
    }

    // MARK: - T10 · idempotence

    func testT10SecondIndexExtractsNothing() throws {
        let started = Date()
        let result = try Recette.run(["index"], database: database, timeout: 300)
        let seconds = Date().timeIntervalSince(started)
        XCTAssertEqual(result.status, 0, result.describe)
        XCTAssertTrue(result.stdout.contains("no document to extract"),
                      "le second `index` a extrait des documents — delta non vide :\n"
                      + result.stdout)
        // Le delta ne redécouvre rien non plus : chaque ligne de crawl est à zéro.
        for line in result.stdout.split(separator: "\n") where line.hasPrefix("[") {
            XCTAssertTrue(line.contains("added 0"), "crawl non idempotent : \(line)")
            XCTAssertTrue(line.contains("updated 0"), "crawl non idempotent : \(line)")
            XCTAssertTrue(line.contains("removed 0"), "crawl non idempotent : \(line)")
        }
        print("T10 : second index en \(String(format: "%.1f", seconds)) s")
    }

    /// Corollaire de T10 sur base jetable, impossible à écrire sur le corpus de
    /// production : un document RETIRÉ de la racine sort de l'index, et un
    /// document AJOUTÉ y entre — le delta compte juste dans les deux sens.
    func testT10DeltaSeesAdditionsAndRemovals() throws {
        let victim = scratch.root.appendingPathComponent("fiche-0.txt")
        try FileManager.default.removeItem(at: victim)
        let newcomer = scratch.root.appendingPathComponent("fiche-neuve.txt")
        try "chromatographie sur couche mince et polymere réticulé, fiche neuve."
            .write(to: newcomer, atomically: true, encoding: .utf8)

        let result = try Recette.run(["index"], database: database, timeout: 300)
        XCTAssertEqual(result.status, 0, result.describe)
        let crawl = result.stdout.split(separator: "\n")
            .first { $0.hasPrefix("[\(scratch.label)]") }
        let line = try XCTUnwrap(crawl.map(String.init),
                                 "aucune ligne de crawl :\n" + result.stdout)
        XCTAssertTrue(line.contains("added 1"), line)
        XCTAssertTrue(line.contains("removed 1"), line)

        let total = try Recette.sqlite("SELECT count(*) FROM docs WHERE ext = 'txt'", on: database)
        XCTAssertEqual(total.trimmingCharacters(in: .whitespacesAndNewlines),
                       "\(scratch.documents)")
    }
}
