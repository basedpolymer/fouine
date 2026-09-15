// SearchContractTests.swift — ce que `fouine search --json` publie depuis le
// lot CL2, et ce que `--hybrid` fait d'un périmètre sans vecteur.
// Propriété : A-Recette. Constats PM-16, PM-06, PM-19, PM-22.
//
// POURQUOI UNE SUITE À PART. Les clés vérifiées ici sont celles que le SERVEUR
// MCP publie déjà : `bm25`, `relevance_pct`, `time_seconds`, `slide`,
// `embedded_image`, `semantic_scope`. Deux surfaces qui répondent de la même
// base doivent en dire la même chose, et c'est ce rapprochement — pas la
// recherche elle-même, éprouvée ailleurs — qui est l'objet de ces tests.
//
// ═══ LE PÉRIMÈTRE DU SENS SE TESTE SANS LE MODÈLE ═══════════════════════════
//
// C'est tout l'intérêt de PM-06 : `--hybrid` sur un périmètre sans vecteur ne
// doit RIEN charger. La seconde classe pose donc des vecteurs à la main sur un
// document, en demande les voisins d'un autre, et vérifie que la réponse est
// lexicale et qu'elle le dit — sur une machine où le modèle e5 n'est pas
// installé comme sur une machine où il l'est.

import Foundation
import XCTest
import FouineCore

final class SearchContractTests: XCTestCase {

    // Un seul index pour toutes les assertions : aucune ne modifie la base.
    private static var shared: Recette.CorpusScratch?

    private var scratch: Recette.CorpusScratch!
    private var database: URL { scratch.database }

    override func setUpWithError() throws {
        if Self.shared == nil {
            Self.shared = try Recette.makeIndexedCorpus("contrat")
        }
        scratch = try XCTUnwrap(Self.shared)
    }

    override class func tearDown() {
        if let shared {
            try? FileManager.default.removeItem(at: shared.directory)
        }
        shared = nil
        super.tearDown()
    }

    private func hits(_ arguments: [String]) throws -> [[String: Any]] {
        let result = try Recette.run(arguments, database: database)
        XCTAssertEqual(result.status, 0, result.describe)
        let object = try JSONSerialization.jsonObject(with: Data(result.stdout.utf8))
        let payload = try XCTUnwrap(object as? [String: Any])
        return try XCTUnwrap(payload["hits"] as? [[String: Any]])
    }

    // MARK: - `--mark` : ce qui entoure les mots trouvés

    /// Les quatre valeurs de `marks` du serveur, dans la ligne de commande.
    /// Un corpus français écrit ses citations entre guillemets, et le
    /// surlignage par défaut est fait des mêmes caractères.
    func testMarkChoosesWhatSurroundsTheMatchedWords() throws {
        let byDefault = try hits(["search", "diffraction", "--json", "--limit", "3"])
        XCTAssertTrue(byDefault.contains {
            ($0["snippet"] as? String ?? "").contains("«")
        }, "le défaut reste les guillemets : \(byDefault)")

        let brackets = try hits(["search", "diffraction", "--json", "--limit", "3",
                                 "--mark", "brackets"])
        XCTAssertTrue(brackets.contains {
            let snippet = $0["snippet"] as? String ?? ""
            return snippet.contains("[diffraction]") || snippet.contains("[Diffraction]")
        }, "les crochets encadrent le mot trouvé : \(brackets)")

        let none = try hits(["search", "diffraction", "--json", "--limit", "3",
                             "--mark", "none"])
        XCTAssertFalse(none.contains { ($0["snippet"] as? String ?? "").contains("«") },
                       "« none » n'entoure rien : \(none)")

        // Une valeur qui n'existe pas est une erreur d'ARGUMENT, comme partout.
        let refused = try Recette.run(["search", "diffraction", "--mark", "quotes"],
                                      database: database)
        XCTAssertEqual(refused.status, 64, refused.describe)
    }

    // MARK: - Les clés de citation, les mêmes que celles de l'assistant

    /// `bm25` porte le même nombre que `score`, `relevance_pct` est celui de la
    /// sortie texte, et les trois clés qui disent ce qu'une page DÉSIGNE sont
    /// toujours présentes — `null` quand la question ne se pose pas.
    func testEveryHitCarriesTheCitationKeysOfTheAssistantServer() throws {
        let entries = try hits(["search", "chromatographie", "--json",
                                "--limit", "10"])
        XCTAssertFalse(entries.isEmpty)
        for entry in entries {
            for key in ["bm25", "relevance_pct", "time_seconds", "slide",
                        "embedded_image"] {
                XCTAssertNotNil(entry[key], "clé « \(key) » absente : \(entry.keys)")
            }
            let score = try XCTUnwrap((entry["score"] as? NSNumber)?.doubleValue)
            let bm25 = try XCTUnwrap((entry["bm25"] as? NSNumber)?.doubleValue)
            XCTAssertEqual(score, bm25, accuracy: 1e-9,
                           "`bm25` est le même nombre que `score`")
            let pct = try XCTUnwrap(entry["relevance_pct"] as? Int)
            XCTAssertTrue((0...100).contains(pct), "pertinence hors bornes : \(pct)")
            // Rien de tout cela n'est un enregistrement : le moment est nul.
            XCTAssertTrue(entry["time_seconds"] is NSNull, "\(entry)")
        }
        // Le premier de la liste est la référence du pourcentage.
        XCTAssertEqual(entries.first?["relevance_pct"] as? Int, 100)

        // Et le chiffre publié est CELUI QU'IMPRIME la sortie texte : le type
        // est partagé depuis ce lot, la formule n'est plus recopiée.
        let text = try Recette.run(["search", "chromatographie", "--limit", "10"],
                                   database: database)
        XCTAssertEqual(text.status, 0, text.describe)
        for entry in entries.prefix(3) {
            let page = try XCTUnwrap(entry["page"] as? Int)
            let pct = try XCTUnwrap(entry["relevance_pct"] as? Int)
            XCTAssertTrue(text.stdout.contains("p.\(page)"), text.stdout)
            XCTAssertTrue(text.stdout.contains("\(pct)%"),
                          "« \(pct)% » attendu dans la sortie texte : \(text.stdout)")
        }
    }

    /// Une page de diaporama se cite par sa DIAPOSITIVE : les images
    /// incorporées d'un `.pptx` sont des pages elles aussi, et elles viennent
    /// après (PM-19).
    func testASlideshowPageSaysWhichSlideItIs() throws {
        let entries = try hits(["search", "diffraction", "--json", "--limit", "5"])
        let slide = try XCTUnwrap(entries.first { ($0["path"] as? String ?? "")
            .hasSuffix("diapositives.pptx") },
            "le corpus versionné porte un .pptx : \(entries)")
        XCTAssertEqual(slide["slide"] as? Int, slide["page"] as? Int,
                       "les trois pages du .pptx sont ses trois diapositives")
        XCTAssertTrue(slide["embedded_image"] is NSNull,
                      "ce .pptx ne porte aucune image incorporée")

        // Un PDF n'est pas un conteneur : ses pages sont ses pages.
        let pdf = try XCTUnwrap(try hits(["search", "markovnikov", "--json",
                                          "--limit", "5"]).first)
        XCTAssertTrue(pdf["slide"] is NSNull, "\(pdf)")
        XCTAssertTrue(pdf["embedded_image"] is NSNull, "\(pdf)")
    }

    /// `fouine read --json` cite la page comme `fouine_read_page` : les quatre
    /// clés qui disent ce qu'elle DÉSIGNE, sur la page lue ET sur ses voisines
    /// — c'est là que se lit la page qu'on va citer.
    func testReadJSONSaysWhatThePageAndItsNeighboursDesignate() throws {
        let raw = try Recette.sqlite(
            "SELECT id FROM docs WHERE rel_path LIKE '%diapositives.pptx'",
            on: database).trimmingCharacters(in: .whitespacesAndNewlines)
        let docID = try XCTUnwrap(Int64(raw), "le .pptx du corpus versionné")

        let result = try Recette.run(["read", "\(docID)", "2", "--context", "1",
                                      "--json"], database: database)
        XCTAssertEqual(result.status, 0, result.describe)
        let payload = try XCTUnwrap(try JSONSerialization.jsonObject(
            with: Data(result.stdout.utf8)) as? [String: Any])

        for key in ["page_label", "slide", "embedded_image", "time_seconds"] {
            XCTAssertNotNil(payload[key], "clé « \(key) » absente : \(payload.keys)")
        }
        XCTAssertEqual(payload["slide"] as? Int, 2,
                       "la deuxième page du diaporama est sa deuxième diapositive")
        XCTAssertTrue(payload["embedded_image"] is NSNull, "\(payload)")
        // Rien de transcrit ici : le moment est nul, et le lien n'a pas de `t=`.
        XCTAssertTrue(payload["time_seconds"] is NSNull, "\(payload)")
        XCTAssertFalse((payload["link"] as? String ?? "").contains("&t="), "\(payload)")

        let context = try XCTUnwrap(payload["context"] as? [[String: Any]])
        XCTAssertFalse(context.isEmpty, "une page voisine au moins")
        for neighbour in context {
            for key in ["page_label", "slide", "embedded_image", "time_seconds"] {
                XCTAssertNotNil(neighbour[key],
                                "clé « \(key) » absente d'une page de contexte")
            }
            XCTAssertEqual(neighbour["slide"] as? Int, neighbour["page"] as? Int)
        }
    }
}

// MARK: - Le périmètre du sens (PM-06)

final class SearchScopeTests: XCTestCase {

    private var scratch: Recette.Scratch!
    private var database: URL { scratch.database }

    override func setUpWithError() throws {
        scratch = try Recette.makeIndexedScratch("perimetre")
    }

    override func tearDownWithError() throws {
        if let scratch {
            try? FileManager.default.removeItem(at: scratch.directory)
        }
    }

    /// Deux documents, un seul vectorisé.
    private func seedVector(on docID: Int64) throws {
        let rowid = Schema.vecRowID(pageRowID: Schema.ftsRowID(docID: docID, page: 1),
                                    chunk: 0)
        _ = try Recette.sqliteWrite("""
            INSERT OR REPLACE INTO vec_meta(k, v) VALUES
              ('model_id', 'recette'), ('dim', '4'), ('revision', '1');
            INSERT OR REPLACE INTO page_vec(rowid, vec) VALUES
              (\(rowid), x'7F000000');
            """, on: database)
    }

    private func documentIDs() throws -> [Int64] {
        try Recette.sqlite("SELECT id FROM docs ORDER BY id LIMIT 2", on: database)
            .split(separator: "\n").compactMap { Int64($0) }
    }

    /// `--hybrid` sur un périmètre qui n'a pas un vecteur répond en PLEIN
    /// TEXTE, le dit avec les deux nombres et le geste, et ne charge rien :
    /// c'est le constat PM-06, où `dossier:M2SU` payait quatre secondes de
    /// modèle et d'index pour comparer zéro vecteur, puis annonçait la
    /// couverture GLOBALE — 67,85 % — comme si elle décrivait ce dossier.
    func testHybridOnAScopeWithoutVectorsStaysLexicalAndSaysSo() throws {
        let ids = try documentIDs()
        try XCTSkipUnless(ids.count == 2, "base jetable trop petite")
        try seedVector(on: ids[0])

        let result = try Recette.run(["search", "chromatographie", "--hybrid",
                                      "--json", "--in", "\(ids[1])"],
                                     database: database)
        XCTAssertEqual(result.status, 0, result.describe)
        let payload = try XCTUnwrap(try JSONSerialization.jsonObject(
            with: Data(result.stdout.utf8)) as? [String: Any])

        XCTAssertEqual(payload["hybrid"] as? Bool, false)
        XCTAssertEqual(payload["hybrid_disarmed"] as? String, "no_vectors_in_scope")
        let scope = try XCTUnwrap(payload["semantic_scope"] as? [String: Any])
        XCTAssertEqual(scope["vectorised"] as? Int, 0)
        XCTAssertEqual(scope["filtered"] as? Bool, true)
        XCTAssertGreaterThan(try XCTUnwrap(scope["pages"] as? Int), 0)
        XCTAssertEqual((payload["semantic_coverage_pct"] as? NSNumber)?.doubleValue, 0)
        XCTAssertFalse((payload["hits"] as? [[String: Any]] ?? []).isEmpty,
                       "la réponse lexicale est rendue ENTIÈRE")

        // La phrase chiffrée, celle qui porte le geste — et pas celle du modèle
        // manquant : le périmètre est lu AVANT tout chargement.
        XCTAssertTrue(result.stderr.contains("no vectorised page in this scope"),
                      result.stderr)
        XCTAssertTrue(result.stderr.contains("fouine embed"), result.stderr)
        XCTAssertFalse(result.stderr.contains("semantic model is missing"),
                       "le modèle n'a pas à être consulté : \(result.stderr)")

        // Et le périmètre QUI A des vecteurs n'est pas désarmé pour autant :
        // la réponse y est hybride, ou le modèle manque — jamais ce motif-là.
        let other = try Recette.run(["search", "chromatographie", "--hybrid",
                                     "--json", "--in", "\(ids[0])"],
                                    database: database)
        let inScope = (try? JSONSerialization.jsonObject(
            with: Data(other.stdout.utf8))) as? [String: Any]
        XCTAssertNotEqual(inScope?["hybrid_disarmed"] as? String,
                          "no_vectors_in_scope", other.describe)
    }

    /// `--hybrid-auto` ne tombe jamais : sans modèle ou sans vecteur, il rend
    /// le plein texte, sans avertissement et sans erreur — c'est ce qui a été
    /// demandé. `--hybrid`, lui, refuse une base sans vecteur (**3**) : le
    /// modèle est là, il n'y a qu'à lancer `fouine embed`, et taire ce cas
    /// cacherait le geste.
    func testHybridAutoFallsBackQuietlyWhereHybridWouldFail() throws {
        let auto = try Recette.run(["search", "chromatographie", "--hybrid-auto",
                                    "--json"], database: database)
        XCTAssertEqual(auto.status, 0, auto.describe)
        let payload = try XCTUnwrap(try JSONSerialization.jsonObject(
            with: Data(auto.stdout.utf8)) as? [String: Any])
        XCTAssertEqual(payload["hybrid"] as? Bool, false)
        XCTAssertFalse((payload["hits"] as? [[String: Any]] ?? []).isEmpty)
        XCTAssertFalse(auto.stderr.contains("--hybrid ignored"),
                       "aucun avertissement : \(auto.stderr)")

        // La base jetable n'a aucun vecteur. Avec le modèle installé, `--hybrid`
        // y sort en 3 ; sans lui, il retombe en le disant. Les deux réponses
        // sont acceptables — ce qui ne l'est pas, c'est `--hybrid-auto` qui
        // ferait l'une ou l'autre.
        let strict = try Recette.run(["search", "chromatographie", "--hybrid",
                                      "--json"], database: database)
        XCTAssertTrue(strict.status == 3 || strict.stderr.contains("--hybrid ignored"),
                      strict.describe)
    }
}
