// ReadRecetteTests.swift — recette de `fouine read`, des clés que
// `list --json` a gagnées et de la facette renommée (lot MC3, constats PM-18,
// PM-16a, PM-25).
// Propriété : A-Recette.
//
// Base JETABLE indexée : ce qui se vérifie ici est un CONTRAT DE SORTIE — les
// clés sont celles des outils MCP correspondants, et une demande impossible
// sort en 64 avec le renseignement qui évite le second essai. Rien n'a besoin
// du corpus personnel.

import Foundation
import XCTest
import FouineCore

final class ReadRecetteTests: XCTestCase {

    private var scratch: Recette.Scratch!
    private var database: URL { scratch.database }

    override func setUpWithError() throws {
        scratch = try Recette.makeIndexedScratch("lire")
    }

    override func tearDownWithError() throws {
        if let scratch {
            try? FileManager.default.removeItem(at: scratch.directory)
        }
    }

    private func json(_ arguments: [String]) throws -> [String: Any] {
        let result = try Recette.run(arguments, database: database)
        XCTAssertEqual(result.status, 0, result.describe)
        let object = try JSONSerialization.jsonObject(with: Data(result.stdout.utf8))
        return try XCTUnwrap(object as? [String: Any])
    }

    /// Un identifiant de document réel de la base jetable.
    private func aDocumentID() throws -> Int64 {
        let raw = try Recette.sqlite("SELECT id FROM docs ORDER BY id LIMIT 1",
                                     on: database)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return try XCTUnwrap(Int64(raw))
    }

    // MARK: - PM-18 : lire une page

    /// La sortie texte porte l'en-tête d'une ligne — de quel document, quelle
    /// page, d'où vient le texte — puis la page telle quelle.
    func testReadPrintsTheHeaderAndTheText() throws {
        let docID = try aDocumentID()
        let result = try Recette.run(["read", "\(docID)", "1"], database: database)
        XCTAssertEqual(result.status, 0, result.describe)
        XCTAssertTrue(result.stdout.contains("[\(docID)]"), result.stdout)
        XCTAssertTrue(result.stdout.contains("page 1"), result.stdout)
        XCTAssertTrue(result.stdout.contains("native"), result.stdout)
        XCTAssertTrue(result.stdout.contains("corpus jetable"), result.stdout)
    }

    /// EXACTEMENT les clés de `fouine_read_page` : un script écrit pour
    /// l'assistant lit la CLI sans traduction.
    func testReadJSONCarriesTheKeysOfTheMCPTool() throws {
        let docID = try aDocumentID()
        let payload = try json(["read", "\(docID)", "1", "--json"])
        for key in ["doc_id", "page", "path", "abs_path", "folder", "ext", "link",
                    "page_count", "text", "chars", "total_chars", "truncated",
                    "next_offset", "source", "engine", "ocr_confidence", "note"] {
            XCTAssertNotNil(payload[key], "clé « \(key) » absente : \(payload.keys)")
        }
        XCTAssertEqual(payload["doc_id"] as? Int, Int(docID))
        XCTAssertEqual(payload["page"] as? Int, 1)
        XCTAssertEqual(payload["source"] as? String, "native")
        XCTAssertFalse((payload["text"] as? String ?? "").isEmpty)
        XCTAssertEqual(payload["chars"] as? Int,
                       (payload["text"] as? String ?? "").count)
        XCTAssertTrue((payload["link"] as? String ?? "").hasPrefix("fouine://"))
        // Page entière rendue : rien à continuer.
        XCTAssertEqual(payload["truncated"] as? Bool, false)
        XCTAssertTrue(payload["next_offset"] is NSNull)
    }


    /// Une tranche courte annonce la suivante, et la suivante la reprend.
    func testReadSlicesALongPageAndAnnouncesTheNextOffset() throws {
        let docID = try aDocumentID()
        let head = try json(["read", "\(docID)", "1", "--max-chars", "200", "--json"])
        XCTAssertEqual(head["truncated"] as? Bool, true)
        let next = try XCTUnwrap(head["next_offset"] as? Int)
        XCTAssertEqual(next, 200)

        let rest = try json(["read", "\(docID)", "1", "--max-chars", "200",
                             "--offset", "\(next)", "--json"])
        let whole = try json(["read", "\(docID)", "1", "--json"])
        let joined = (head["text"] as? String ?? "") + (rest["text"] as? String ?? "")
        XCTAssertTrue((whole["text"] as? String ?? "").hasPrefix(joined),
                      "deux tranches consécutives se recollent")
    }

    /// Une page que le document n'a pas est une erreur d'USAGE, et le message
    /// dit combien il en a vraiment : c'est ce qui évite le second essai à
    /// l'aveugle. Un document inconnu, de même.
    func testReadRefusesAnImpossibleRequestInSixtyFour() throws {
        let docID = try aDocumentID()
        let outOfRange = try Recette.run(["read", "\(docID)", "9999"],
                                         database: database)
        XCTAssertEqual(outOfRange.status, 64, outOfRange.describe)
        XCTAssertTrue(outOfRange.stderr.contains("no page 9999"), outOfRange.stderr)
        XCTAssertTrue(outOfRange.stderr.contains("pages"), outOfRange.stderr)

        let unknown = try Recette.run(["read", "999999", "1"], database: database)
        XCTAssertEqual(unknown.status, 64, unknown.describe)
        XCTAssertTrue(unknown.stderr.contains("no document 999999"), unknown.stderr)
        XCTAssertTrue(unknown.stderr.contains("fouine list"), unknown.stderr)
    }

    // MARK: - PM-16a : ce que `list --json` a gagné

    func testListJSONCarriesTheErrorOfEachDocument() throws {
        let documents = try XCTUnwrap(
            json(["list", "--json", "--limit", "500"])["documents"]
                as? [[String: Any]])
        XCTAssertFalse(documents.isEmpty)
        for document in documents {
            XCTAssertNotNil(document["error"], "la clé est TOUJOURS présente")
        }
        // Un document INDEXÉ n'a rien à dire : `null`, et non une chaîne vide.
        let indexed = documents.filter { $0["state"] as? String == "indexed" }
        XCTAssertFalse(indexed.isEmpty)
        XCTAssertTrue(indexed.allSatisfy { $0["error"] is NSNull })
        // La base jetable porte un `.pages` sans aperçu : c'est le cas qui
        // justifie la clé, et sa cause doit être lisible sans seconde commande.
        let failed = documents.filter { $0["state"] as? String == "failed" }
        XCTAssertFalse(failed.isEmpty, "la base jetable doit porter un échec")
        for document in failed {
            XCTAssertFalse((document["error"] as? String ?? "").isEmpty,
                           "un document en échec DIT pourquoi : \(document)")
        }
        // Et la table la dit aussi, à la suite de l'état.
        let text = try Recette.run(["list", "--limit", "500"], database: database)
        XCTAssertEqual(text.status, 0, text.describe)
        let cause = try XCTUnwrap(failed.first?["error"] as? String)
        XCTAssertTrue(text.stdout.contains("failed · " + cause), text.stdout)
    }

    // MARK: - PM-25 : la facette renommée

    /// La clé rendue est `modified_year`, et `--facet year` reste accepté en
    /// entrée — un script écrit avant ce lot ne doit pas tomber en 64.
    func testModifiedYearFacetAndItsSilentAlias() throws {
        let renamed = try json(["search", "azote", "--facet", "modified_year",
                                "--json"])
        let facets = try XCTUnwrap(renamed["facets"] as? [String: [String: Int]])
        XCTAssertNotNil(facets["modified_year"], "\(facets.keys)")
        XCTAssertNil(facets["year"])

        let alias = try json(["search", "azote", "--facet", "year", "--json"])
        let aliased = try XCTUnwrap(alias["facets"] as? [String: [String: Int]])
        XCTAssertEqual(aliased["modified_year"], facets["modified_year"],
                       "l'alias rend exactement la même chose, sous le nouveau nom")

        // `doc_year` est intacte, et c'est une autre question.
        let unknown = try Recette.run(["search", "azote", "--facet", "zzz"],
                                      database: database)
        XCTAssertEqual(unknown.status, 64, unknown.describe)
    }
}
