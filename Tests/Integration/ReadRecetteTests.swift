// ReadRecetteTests.swift — recette de `fouine read`, `fouine similar`, des
// clés que `list --json` a gagnées, de `embed --folder` et de la facette
// renommée (lot MC3, constats PM-18, PM-16a, PM-05, PM-25).
// Propriété : A-Recette.
//
// Base JETABLE indexée : ce qui se vérifie ici est un CONTRAT DE SORTIE — les
// clés sont celles des outils MCP correspondants, une demande impossible sort
// en 64 avec le renseignement qui évite le second essai, et une page sans
// vecteur sort en 1 plutôt qu'en 0 avec une liste vide. Rien n'a besoin du
// corpus personnel.
//
// LES VECTEURS SONT POSÉS À LA MAIN (`sqlite3`), sur quatre dimensions : le
// modèle réel pèse 220 Mo et 2,6 s de chargement, et ce qui est éprouvé ici est
// la COMMANDE, pas l'encodeur — `fouine similar` ne charge d'ailleurs jamais le
// modèle, c'est tout son intérêt.

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

    // MARK: - PM-16 : les voisins d'une page

    /// Sans vecteur, `similar` sort en 1 en disant le geste : un script doit
    /// pouvoir distinguer « rien ne lui ressemble » de « le sens n'est pas
    /// préparé ».
    func testSimilarExitsOneWhenThePageHasNoVector() throws {
        let docID = try aDocumentID()
        let result = try Recette.run(["similar", "\(docID)", "1"], database: database)
        XCTAssertEqual(result.status, 1, result.describe)
        XCTAssertTrue(result.stderr.contains("fouine embed"), result.stderr)
    }

    /// `--encode` est la SEULE porte par laquelle cette commande charge le
    /// modèle, et elle est fermée par défaut (lot CL2, constat PM-07) : sans
    /// l'option, le refus NOMME l'option ; avec elle et sans modèle installé,
    /// il nomme l'installation. Une racine entière peut être à zéro vecteur —
    /// `M2SU`, 0 sur 139 638 pages — et « aucun voisin » se lit alors comme
    /// « rien ne ressemble à cette page ».
    func testSimilarEncodesOnDemandAndNamesTheGestureOtherwise() throws {
        let ids = try Recette.sqlite("SELECT id FROM docs ORDER BY id LIMIT 2",
                                     on: database)
            .split(separator: "\n").compactMap { Int64($0) }
        try XCTSkipUnless(ids.count == 2, "base jetable trop petite")
        _ = try Recette.sqliteWrite("""
            INSERT OR REPLACE INTO vec_meta(k, v) VALUES
              ('model_id', 'recette'), ('dim', '4'), ('revision', '1');
            INSERT OR REPLACE INTO page_vec(rowid, vec) VALUES
              (\(Schema.vecRowID(pageRowID: Schema.ftsRowID(docID: ids[0], page: 1),
                                 chunk: 0)), x'7F000000');
            """, on: database)

        let without = try Recette.run(["similar", "\(ids[1])", "1", "--json"],
                                      database: database)
        XCTAssertEqual(without.status, 1, without.describe)
        let payload = try XCTUnwrap(try JSONSerialization.jsonObject(
            with: Data(without.stdout.utf8)) as? [String: Any])
        XCTAssertEqual(payload["source_has_vector"] as? Bool, false)
        XCTAssertTrue(payload["source_vector"] is NSNull, "\(payload)")
        XCTAssertTrue((payload["note"] as? String ?? "").contains("--encode"),
                      "le refus nomme l'option : \(payload)")

        // Le modèle est pointé sur un dossier VIDE : la branche `--encode` est
        // exercée de bout en bout sans les 220 Mo du vrai modèle.
        let empty = scratch.directory.appendingPathComponent("sans-modele",
                                                             isDirectory: true)
        try FileManager.default.createDirectory(at: empty,
                                                withIntermediateDirectories: true)
        let asked = try Recette.run(["similar", "\(ids[1])", "1", "--encode"],
                                    database: database,
                                    extraEnvironment: ["FOUINE_MODEL_DIR": empty.path])
        XCTAssertEqual(asked.status, 1, asked.describe)
        XCTAssertTrue(asked.stderr.contains("model is not installed"), asked.stderr)
        XCTAssertTrue(asked.stderr.contains("fouine model download"), asked.stderr)
    }

    /// Avec des vecteurs en base, les clés sont celles de
    /// `fouine_similar_pages`, et le voisin est la page dont le vecteur est le
    /// plus proche.
    func testSimilarRendersTheKeysOfTheMCPTool() throws {
        let ids = try Recette.sqlite("SELECT id FROM docs ORDER BY id LIMIT 3",
                                     on: database)
            .split(separator: "\n").compactMap { Int64($0) }
        try XCTSkipUnless(ids.count == 3, "base jetable trop petite")

        // Quatre dimensions, vecteurs quantifiés int8 comme en production.
        // Les deux premiers documents pointent dans la même direction, le
        // troisième dans une autre.
        func rowid(_ docID: Int64) -> Int64 {
            Schema.vecRowID(pageRowID: Schema.ftsRowID(docID: docID, page: 1),
                            chunk: 0)
        }
        _ = try Recette.sqliteWrite("""
            INSERT OR REPLACE INTO vec_meta(k, v) VALUES
              ('model_id', 'recette'), ('dim', '4'), ('revision', '1');
            INSERT OR REPLACE INTO page_vec(rowid, vec) VALUES
              (\(rowid(ids[0])), x'7F000000'),
              (\(rowid(ids[1])), x'7F000000'),
              (\(rowid(ids[2])), x'0000007F');
            """, on: database)

        let payload = try json(["similar", "\(ids[0])", "1", "--json"])
        for key in ["neighbours", "vector_count", "coverage_pct", "model_id",
                    "revision", "source_has_vector", "source_vector", "note",
                    "elapsed_ms"] {
            XCTAssertNotNil(payload[key], "clé « \(key) » absente : \(payload.keys)")
        }
        XCTAssertEqual(payload["source_has_vector"] as? Bool, true)
        XCTAssertEqual(payload["source_vector"] as? String, "stored")
        XCTAssertEqual(payload["model_id"] as? String, "recette")
        let neighbours = try XCTUnwrap(payload["neighbours"] as? [[String: Any]])
        XCTAssertEqual(neighbours.first?["doc_id"] as? Int, Int(ids[1]),
                       "le plus proche est celui qui pointe dans la même "
                       + "direction : \(neighbours)")
        let cosine = try XCTUnwrap((neighbours.first?["cosine"] as? NSNumber)?
            .doubleValue)
        XCTAssertGreaterThan(cosine, 0.9)
        for key in ["page", "path", "abs_path", "folder", "ext", "link", "preview"] {
            XCTAssertNotNil(neighbours.first?[key], "clé « \(key) » absente")
        }
    }

    // MARK: - PM-16a : ce que `list --json` a gagné

    func testListJSONCarriesTheErrorAndTheVectorisedPages() throws {
        let documents = try XCTUnwrap(
            json(["list", "--json", "--limit", "500"])["documents"]
                as? [[String: Any]])
        XCTAssertFalse(documents.isEmpty)
        for document in documents {
            XCTAssertNotNil(document["error"], "la clé est TOUJOURS présente")
            XCTAssertNotNil(document["vectorised_pages"] as? Int)
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
        // Aucune campagne n'a tourné sur cette base : zéro partout, clé
        // présente (et non absente, ce qu'un script ne saurait pas distinguer).
        XCTAssertTrue(documents.allSatisfy { ($0["vectorised_pages"] as? Int) == 0 })
    }

    // MARK: - PM-05 : `embed --folder`

    /// Une étiquette de dossier inconnue est refusée en 64 en nommant les
    /// vraies : sans ce refus, la campagne n'aurait rien fait, en sortie 0.
    func testEmbedRefusesAnUnknownFolderInSixtyFour() throws {
        let result = try Recette.run(["embed", "--folder", "Inconnu",
                                      "--budget-minutes", "0.01"],
                                     database: database)
        XCTAssertEqual(result.status, 64, result.describe)
        XCTAssertTrue(result.stderr.contains(scratch.label),
                      "le refus nomme les dossiers réels : " + result.stderr)
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
