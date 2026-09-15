// MovedRootTests.swift — T9 : racine renommée (SPEC §8.1, §7.2 n°14).
// Propriété : A-Recette.
//
// Ce test construit sa PROPRE mini-base et sa PROPRE racine, dans un répertoire
// temporaire hors corpus : le corpus personnel est en lecture seule stricte et
// ce test renomme sa racine, ce qui serait destructeur sur une racine réelle.

import Foundation
import XCTest

final class MovedRootTests: XCTestCase {

    private var scratch: URL!

    override func setUpWithError() throws {
        _ = try Recette.requireBinary()
        scratch = try Recette.scratchDirectory("t9")
    }

    override func tearDownWithError() throws {
        if let scratch { try? FileManager.default.removeItem(at: scratch) }
    }

    func testT9RenamedRootIsReportedAndSearchStillAnswers() throws {
        let database = scratch.appendingPathComponent("t9.db")
        let root = scratch.appendingPathComponent("racine-t9", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)

        let corpus = [
            "alpha.txt": "La règle de Markovnikov gouverne l'addition électrophile.",
            "beta.txt":  "Enthalpie libre et énergie de Gibbs, thermodynamique.",
            "gamma.txt": "Chromatographie sur couche mince et polymère réticulé.",
        ]
        for (name, text) in corpus {
            try text.write(to: root.appendingPathComponent(name),
                           atomically: true, encoding: .utf8)
        }

        // La base jetable n'a aucune racine par défaut : `root add` d'abord.
        let added = try Recette.run(["root", "add", root.path, "--label", "T9"],
                                    database: database)
        XCTAssertEqual(added.status, 0, added.describe)

        // GARDE-FOU : `root add` ouvre la base SANS enregistrer les racines par
        // défaut (§4.3). On le vérifie avant d'indexer — un `index` qui partirait
        // sur ~/Livres prendrait une demi-heure et n'aurait rien à voir avec T9.
        let listed = try Recette.run(["root", "list", "--json"], database: database)
        XCTAssertEqual(listed.status, 0, listed.describe)
        struct Listed: Decodable { let label: String }
        let roots = try JSONDecoder().decode(
            [Listed].self, from: Data(listed.stdout.utf8))
        XCTAssertEqual(roots.map(\.label), ["T9"],
                       "la base jetable doit ne contenir QUE la racine de test")

        let indexed = try Recette.run(["index"], database: database, timeout: 300)
        XCTAssertEqual(indexed.status, 0, indexed.describe)

        let before = try Recette.search("Markovnikov", database: database,
                                        extra: ["--fuzzy", "off"])
        XCTAssertGreaterThan(before.totalPages, 0, "la mini-base n'a rien indexé")

        // Diagnostic sain AVANT le renommage.
        let healthy = try Recette.run(["doctor"], database: database)
        XCTAssertEqual(healthy.status, 0, healthy.describe)

        // --- la racine bouge ---
        let moved = scratch.appendingPathComponent("racine-t9-deplacee", isDirectory: true)
        try FileManager.default.moveItem(at: root, to: moved)

        let doctor = try Recette.run(["doctor"], database: database)
        XCTAssertEqual(doctor.status, 5,
                       "sortie 5 attendue pour une racine disparue (§4.3)\n"
                       + doctor.describe)
        let diagnosis = doctor.stdout + doctor.stderr
        XCTAssertTrue(diagnosis.contains("T9"),
                      "le diagnostic ne nomme pas la racine :\n" + diagnosis)
        XCTAssertTrue(diagnosis.contains(root.path),
                      "le diagnostic ne donne pas le chemin attendu :\n" + diagnosis)

        // …et la recherche répond TOUJOURS sur l'index existant (§8.1 T9).
        let after = try Recette.search("Markovnikov", database: database,
                                       extra: ["--fuzzy", "off"])
        XCTAssertEqual(after.totalPages, before.totalPages,
                       "la recherche ne répond plus après le déplacement de la racine")

        // Un crawl sur une racine disparue sort en 5 sans casser l'index.
        let crawl = try Recette.run(["crawl", "--root", "T9"], database: database)
        XCTAssertEqual(crawl.status, 5, crawl.describe)
        let still = try Recette.search("Markovnikov", database: database,
                                       extra: ["--fuzzy", "off"])
        XCTAssertEqual(still.totalPages, before.totalPages,
                       "l'index a été vidé par un crawl sur une racine disparue")
    }
}
