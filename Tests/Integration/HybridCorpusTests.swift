// HybridCorpusTests.swift — `fouine embed` puis `search --hybrid` sur le corpus
// VERSIONNÉ. Propriété : A-Recette. Audit E5, D12/M23, D6.
//
// La recherche hybride (§12) n'avait aucun test de bout en bout : FouineEmbedTests
// exerce le moteur avec un encodeur déterministe substitué, et ses trois tests
// de parité avec le VRAI modèle se sautent sans lui. Personne ne vérifiait donc
// que `fouine embed` puis `fouine search --hybrid` rendent quelque chose sur un
// index réel.
//
// ═══ LE MODÈLE EST FACULTATIF, ET LE RESTE ══════════════════════════════════
//
// Le modèle e5 pèse 220 Mo et s'installe par `fouine model download` (palier
// 3.1). Il n'est PAS dans le dépôt et ne le sera jamais. Cette suite se saute
// donc proprement quand il manque — sur la machine d'un contributeur comme sur
// un runner où l'asset n'est pas encore publié. Le portier est
// `fouine model status --json`, c'est-à-dire le produit lui-même : pas une
// heuristique de chemin réimplémentée ici.
//
// Le répertoire du modèle vient de `FOUINE_MODEL_DIR` si elle est posée, sinon
// de ~/Library/Application Support/Fouine/models/e5-small. Cette suite LIT le
// modèle, elle n'écrit jamais dedans.

import Foundation
import XCTest

// MARK: - Schéma JSON de `search --hybrid` (§12)

/// `--hybrid` ne rend PAS le schéma de `search --json` : ni `query`, ni
/// `total_pages`, ni `total_docs`, et chaque résultat porte en plus les rangs
/// des deux listes fusionnées.
private struct HybridHit: Decodable {
    let docID: Int64
    let path: String
    let page: Int
    let rrf: Double
    let semanticOnly: Bool
    let cosine: Double?
    let lexRank: Int?
    let vecRank: Int?
    let snippet: String?

    enum CodingKeys: String, CodingKey {
        case docID = "doc_id"
        case path, page, rrf, cosine, snippet
        case semanticOnly = "semantic_only"
        case lexRank = "lex_rank"
        case vecRank = "vec_rank"
    }
}

private struct HybridPayload: Decodable {
    let elapsedMS: Double
    let hits: [HybridHit]
    let offset: Int?
    let hasMore: Bool?
    let modelLoadMS: Double?
    let indexLoadMS: Double?
    let vectors: Int?
    let pagesIndexed: Int?
    let semanticCoveragePct: Double?
    let semanticRankScale: Double?

    enum CodingKeys: String, CodingKey {
        case hits, offset, vectors
        case hasMore = "has_more"
        case elapsedMS = "elapsed_ms"
        case modelLoadMS = "model_load_ms"
        case indexLoadMS = "index_load_ms"
        case pagesIndexed = "pages_indexed"
        case semanticCoveragePct = "semantic_coverage_pct"
        case semanticRankScale = "semantic_rank_scale"
    }
}

final class HybridCorpusTests: XCTestCase {

    // Un seul corpus indexé ET vectorisé pour toutes les interrogations : la
    // passe `embed` coûte cinq secondes sur ce corpus, et rien ne justifie de
    // la répéter à chaque test. Le test de COUVERTURE, lui, part d'un index
    // neuf — c'est tout son objet.
    private static var shared: Recette.CorpusScratch?

    private var scratch: Recette.CorpusScratch!
    private var database: URL { scratch.database }

    override func setUpWithError() throws {
        _ = try Recette.requireBinary()
        try requireSemanticModel()
        if Self.shared == nil {
            let fresh = try Recette.makeIndexedCorpus("hybride")
            let embedded = try Recette.run(["embed"], database: fresh.database,
                                           timeout: 900)
            XCTAssertEqual(embedded.status, 0, embedded.describe)
            Self.shared = fresh
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

    /// Saut propre si le modèle n'est pas installé. Le portier est
    /// `fouine model status --json` : le produit sait où il range son modèle,
    /// la recette n'a pas à le deviner.
    ///
    /// La base passée ici est SANS IMPORTANCE (`model status` ne lit pas
    /// l'index) mais elle doit être jetable : `Recette.run` pose toujours
    /// `FOUINE_DB`, jamais de repli sur la base de production (audit S3).
    private func requireSemanticModel() throws {
        let probe = try Recette.scratchDirectory("modele")
        defer { try? FileManager.default.removeItem(at: probe) }
        let result = try Recette.run(
            ["model", "status", "--json"],
            database: probe.appendingPathComponent("sonde.db"))
        XCTAssertEqual(result.status, 0, result.describe)
        struct Status: Decodable {
            let installed: Bool
            let path: String
            let revision: Int?
        }
        let status = try JSONDecoder().decode(Status.self,
                                              from: Data(result.stdout.utf8))
        guard status.installed else {
            throw XCTSkip("""
                modèle sémantique absent de \(status.path) — recherche hybride \
                sautée. Installez-le par `fouine model download` (220 Mo), ou \
                pointez FOUINE_MODEL_DIR sur une copie existante.
                """)
        }
    }

    private func hybrid(_ query: String, extra: [String] = []) throws
        -> HybridPayload {
        let result = try Recette.run(
            ["search", query, "--hybrid", "--json", "--fuzzy", "off",
             "--limit", "20"] + extra,
            database: database, timeout: 300)
        XCTAssertEqual(result.status, 0, result.describe)
        return try JSONDecoder().decode(HybridPayload.self,
                                        from: Data(result.stdout.utf8))
    }

    // MARK: - `fouine embed`

    /// La passe vectorielle couvre TOUTES les pages indexées, et se dit
    /// terminée. `pages_vec` est une clé de `status --json` : on l'affirme là,
    /// pas sur la ligne de compte-rendu.
    func testEmbedCoversEveryIndexedPageAndIsIdempotent() throws {
        // Index NEUF, sans vecteur : c'est la couverture partant de zéro qu'on
        // veut mesurer, pas la ré-exécution sur un index déjà vectorisé.
        let own = try Recette.makeIndexedCorpus("hybride-couverture")
        defer { try? FileManager.default.removeItem(at: own.directory) }

        func pagesVec() throws -> (indexed: Int, vec: Int) {
            let result = try Recette.run(["status", "--json"],
                                         database: own.database)
            XCTAssertEqual(result.status, 0, result.describe)
            let payload = try XCTUnwrap(try JSONSerialization.jsonObject(
                with: Data(result.stdout.utf8)) as? [String: Any])
            return (try XCTUnwrap(payload["pages_indexed"] as? Int),
                    try XCTUnwrap(payload["pages_vec"] as? Int))
        }

        let before = try pagesVec()
        XCTAssertGreaterThan(before.indexed, 20,
                             "l'index du corpus versionné a maigri")
        XCTAssertEqual(before.vec, 0, "aucun vecteur avant `embed`")

        let embedded = try Recette.run(["embed"], database: own.database,
                                       timeout: 900)
        XCTAssertEqual(embedded.status, 0, embedded.describe)
        let after = try pagesVec()
        XCTAssertEqual(after.vec, after.indexed,
                       "toute page indexée doit porter un vecteur")

        // Seconde passe : incrémentale, donc sans rien à produire. Le contrat
        // est que `pages_vec` ne bouge pas — pas que le texte le dise.
        let again = try Recette.run(["embed"], database: own.database,
                                    timeout: 300)
        XCTAssertEqual(again.status, 0, again.describe)
        XCTAssertEqual(try pagesVec().vec, after.vec)
    }

    // MARK: - `search --hybrid`

    /// L'échelle des rangs sémantiques (lot R1) est PUBLIÉE, vaut 1 quand tout
    /// est vectorisé, et `--raw-semantic-ranks` la désarme sans rien casser
    /// (AUDIT-R1 I5 : aucune recette ne l'exerçait).
    func testSemanticRankScaleIsPublishedAndCanBeDisarmed() throws {
        let scaled = try hybrid("markovnikov")
        let scale = try XCTUnwrap(scaled.semanticRankScale)
        XCTAssertEqual(scale, 1, accuracy: 0.001,
                       "le corpus est entièrement vectorisé : l'échelle vaut 1")
        let raw = try hybrid("markovnikov", extra: ["--raw-semantic-ranks"])
        XCTAssertEqual(raw.semanticRankScale ?? -1, 1, accuracy: 0.001)
        XCTAssertEqual(raw.hits.map(\.page), scaled.hits.map(\.page),
                       "à couverture pleine, désarmer l'échelle ne change rien")
    }

    /// L'hybride ne PERD PAS le lexical : un terme exact reste en tête, avec
    /// son rang lexical, et n'est pas marqué « sémantique seulement ».
    func testHybridKeepsTheExactLexicalHitOnTop() throws {
        let payload = try hybrid("markovnikov")
        let top = try XCTUnwrap(payload.hits.first)
        XCTAssertTrue(top.path.hasSuffix("chimie-organique.pdf"), top.path)
        XCTAssertEqual(top.page, 2)
        XCTAssertEqual(top.lexRank, 1,
                       "le meilleur résultat lexical doit rester le meilleur")
        XCTAssertEqual(top.semanticOnly, false)
        XCTAssertNotNil(top.snippet)

        // Les deux pages lexicales sont toujours là : la fusion RRF ajoute des
        // résultats, elle n'en retire pas.
        let lexicalPages = payload.hits
            .filter { $0.path.hasSuffix("chimie-organique.pdf")
                && $0.semanticOnly == false }
            .map(\.page).sorted()
        XCTAssertEqual(lexicalPages, [2, 4])
    }

    /// `semantic_coverage_pct` est un POURCENTAGE, pas un rapport multiplié
    /// deux fois (audit A1m-01). Sur la base de production il annonçait
    /// « 1718.86 » là où le texte de la même commande disait « 17,2 % » ; un
    /// script — ou un modèle de langage à travers le serveur MCP — n'a aucun
    /// moyen de deviner lequel des deux nombres croire. Le corpus de recette
    /// est intégralement vectorisé, donc la couverture y vaut exactement 100.
    func testSemanticCoverageIsAPercentage() throws {
        let payload = try hybrid("markovnikov")
        let vectors = try XCTUnwrap(payload.vectors)
        let indexed = try XCTUnwrap(payload.pagesIndexed)
        let coverage = try XCTUnwrap(payload.semanticCoveragePct)
        XCTAssertGreaterThan(indexed, 0)
        XCTAssertEqual(coverage, Double(vectors) * 100 / Double(indexed),
                       accuracy: 0.01,
                       "semantic_coverage_pct doit valoir vectors × 100 / pages_indexed")
        XCTAssertLessThanOrEqual(coverage, 100,
                                 "un pourcentage ne dépasse pas 100 (obtenu \(coverage))")
    }

    /// LE test qui justifie l'hybride : une requête dont AUCUN mot n'est dans
    /// l'index ne rend rien en plein texte, et rend la bonne page en hybride.
    ///
    /// « energie libre de reaction spontanee » : le corpus ne contient ni
    /// « energie » ni « spontanee » sous cette forme conjointe, mais la page 3
    /// de chimie-organique.pdf dit « L'enthalpie libre de Gibbs decide du sens
    /// spontane d'une reaction ». C'est exactement le cas d'usage du §12.
    func testSemanticOnlyHitSurfacesWhereFullTextFindsNothing() throws {
        let question = "energie libre de reaction spontanee"

        // (a) contre-épreuve : le plein texte ne trouve rien.
        let lexical = try Recette.search(question, database: database,
                                         extra: ["--fuzzy", "off"])
        XCTAssertEqual(lexical.totalPages, 0,
                       "la contre-épreuve suppose une requête SANS résultat "
                       + "lexical : \(lexical.hits.map(\.path))")

        // (b) l'hybride, lui, remonte la page.
        let payload = try hybrid(question)
        XCTAssertFalse(payload.hits.isEmpty, "aucune page remontée")

        // Rang parmi les trois premiers, et non strictement premier : les
        // cosinus se tiennent en quelques centièmes et l'arithmétique CoreML
        // n'est pas identique d'une architecture à l'autre.
        let top = payload.hits.prefix(3)
        let match = top.first {
            $0.path.hasSuffix("chimie-organique.pdf") && $0.page == 3
        }
        let hit = try XCTUnwrap(
            match,
            "la page 3 de chimie-organique.pdf devrait être dans les trois "
            + "premiers : \(top.map { ($0.path, $0.page, $0.cosine ?? 0) })")
        XCTAssertEqual(hit.semanticOnly, true,
                       "cette page n'a AUCUN mot de la requête : elle ne peut "
                       + "venir que du canal vectoriel")
        XCTAssertNotNil(hit.vecRank)
        XCTAssertGreaterThan(try XCTUnwrap(hit.cosine), 0.7)
    }

    /// RK-01, de bout en bout : `--hybrid` sur une requête à PHRASE EXACTE ne
    /// consulte pas le canal du sens, le dit sur l'erreur standard, publie la
    /// raison, et rend EXACTEMENT ce que rend le plein texte.
    ///
    /// « enthalpie libre » est sur la page 3 de chimie-organique.pdf : la
    /// requête a donc une vraie réponse lexicale, et ce qui se mesure ici est
    /// bien le désarmement, pas une absence de résultat.
    func testAnExactPhraseDisarmsTheSemanticChannel() throws {
        let phrase = "\"enthalpie libre\""
        let result = try Recette.run(
            ["search", phrase, "--hybrid", "--json", "--fuzzy", "off",
             "--limit", "20"], database: database, timeout: 300)
        XCTAssertEqual(result.status, 0, result.describe)
        XCTAssertTrue(result.stderr.contains("meaning search not used"),
                      "le refus doit être annoncé : \(result.describe)")

        let payload = try XCTUnwrap(try JSONSerialization.jsonObject(
            with: Data(result.stdout.utf8)) as? [String: Any])
        XCTAssertEqual(payload["hybrid"] as? Bool, false)
        XCTAssertEqual(payload["hybrid_disarmed"] as? String, "exact_phrase")
        // La sortie est celle du plein texte : aucune clé de la fusion.
        for hybridOnly in ["vectors", "semantic_stats", "semantic_rank_scale"] {
            XCTAssertNil(payload[hybridOnly],
                         "\(hybridOnly) n'a rien à faire dans une réponse lexicale")
        }

        // Et c'est la MÊME réponse que sans `--hybrid`, page par page.
        let lexical = try Recette.search(phrase, database: database,
                                         extra: ["--fuzzy", "off"], limit: 20)
        let hits = try XCTUnwrap(payload["hits"] as? [[String: Any]])
        XCTAssertEqual(hits.compactMap { $0["page"] as? Int },
                       lexical.hits.map(\.page))
        XCTAssertEqual(payload["total_pages"] as? Int, lexical.totalPages)
        XCTAssertGreaterThan(lexical.totalPages, 0,
                             "la contre-épreuve suppose une phrase PRÉSENTE")
    }

    /// Le filtre par document s'applique AUSSI au canal vectoriel : sans quoi
    /// `--in` deviendrait une passoire dès qu'on active l'hybride.
    func testDocumentFilterAppliesToTheVectorChannelToo() throws {
        let documents = try Recette.indexedDocuments(under: scratch.root,
                                                     on: database)
        XCTAssertNotNil(documents["memo.rtf"])
        let raw = try Recette.sqlite(
            "SELECT id FROM docs WHERE rel_path LIKE '%memo.rtf'", on: database)
        let docID = try XCTUnwrap(
            Int64(raw.trimmingCharacters(in: .whitespacesAndNewlines)))

        let payload = try hybrid("energie libre de reaction spontanee",
                                 extra: ["--in", String(docID)])
        XCTAssertFalse(payload.hits.isEmpty)
        XCTAssertTrue(payload.hits.allSatisfy { $0.docID == docID },
                      "le filtre --in doit restreindre les DEUX canaux : "
                      + "\(payload.hits.map { ($0.docID, $0.path) })")
    }

    /// CM-22 : le mode hybride RETIRAIT quatre clés du « schéma stable » —
    /// `total_pages` et `total_docs` à la racine, `folder` et `engine` par
    /// résultat — alors que `docs/cli.md` annonce les clés hybrides « en
    /// plus ». Un script qui lit `hits[].folder` cassait dès que l'utilisateur
    /// ajoutait `--hybrid`.
    ///
    /// CM-21 : `score` est arrondi à quatre décimales, comme le `bm25` de
    /// l'outil MCP — c'est la même grandeur.
    func testHybridKeepsEveryKeyOfTheFrozenSchema() throws {
        let result = try Recette.run(
            ["search", "energie", "--hybrid", "--json", "--fuzzy", "off",
             "--limit", "10"],
            database: database, timeout: 300)
        XCTAssertEqual(result.status, 0, result.describe)
        let payload = try XCTUnwrap(try JSONSerialization.jsonObject(
            with: Data(result.stdout.utf8)) as? [String: Any])

        for key in ["query", "offset", "has_more", "elapsed_ms",
                    "total_pages", "total_docs", "hits"] {
            XCTAssertNotNil(payload[key], "clé « \(key) » du §4.3 absente en hybride")
        }
        // Les clés hybrides sont EN PLUS, jamais à la place.
        XCTAssertEqual(payload["total_pages"] as? Int,
                       payload["lex_total_pages"] as? Int)
        XCTAssertEqual(payload["total_docs"] as? Int,
                       payload["lex_total_docs"] as? Int)

        let hits = try XCTUnwrap(payload["hits"] as? [[String: Any]])
        XCTAssertFalse(hits.isEmpty, "aucun résultat : le test ne prouve rien")
        for hit in hits {
            for key in ["doc_id", "path", "folder", "page", "source", "engine",
                        "fuzzy_distance", "snippet", "link"] {
                XCTAssertNotNil(hit[key], "clé « \(key) » absente d'un hit hybride")
            }
            // `score` reste réservé aux résultats que le canal LEXICAL a
            // trouvés : inventer un bm25 pour une page rendue par le seul sens
            // serait un chiffre faux dans un contrat gelé.
            if (hit["semantic_only"] as? Bool) == false {
                let score = try XCTUnwrap(hit["score"] as? Double)
                XCTAssertEqual(score, (score * 10_000).rounded() / 10_000,
                               accuracy: 1e-9,
                               "score non arrondi à 4 décimales : \(score)")
            }
        }

        // Le mode LEXICAL arrondit le même champ de la même façon.
        let lexical = try Recette.search("energie", database: database)
        for hit in lexical.hits {
            XCTAssertEqual(hit.score, (hit.score * 10_000).rounded() / 10_000,
                           accuracy: 1e-9,
                           "score non arrondi en lexical : \(hit.score)")
        }
    }

    /// LE QUORUM EST ARMÉ EN HYBRIDE COMME EN LEXICAL (lot MN1, décision du
    /// 14/09/2026, réversible).
    ///
    /// POURQUOI CE TEST. `HybridResults.quorum` voyage depuis le lot MC2 et le
    /// serveur MCP l'arme dans ce mode ; la ligne de commande le désarmait
    /// (`q.quorum = !noQuorum && !wantsHybrid`). Les deux surfaces disaient
    /// donc deux choses des mêmes résultats : ici, la même requête rend le même
    /// drapeau dans les deux modes, le dit sur l'erreur standard, et
    /// `--no-quorum` le coupe des deux côtés.
    ///
    /// `enthalpie gibbs introuvable` : trois mots longs, aucune page ne les
    /// porte tous les trois (le troisième n'est nulle part), et les pages 1 et
    /// 3 de `chimie-organique.pdf` en portent deux — la forme exacte du
    /// constat RK-04.
    func testTheQuorumIsArmedInHybridLikeTheAssistantServer() throws {
        let query = "enthalpie gibbs introuvable"
        func payload(_ extra: [String]) throws -> (json: [String: Any], stderr: String) {
            let result = try Recette.run(["search", query, "--json",
                                          "--fuzzy", "off", "--limit", "20"] + extra,
                                         database: database, timeout: 300)
            XCTAssertEqual(result.status, 0, result.describe)
            let object = try XCTUnwrap(try JSONSerialization.jsonObject(
                with: Data(result.stdout.utf8)) as? [String: Any])
            return (object, result.stderr)
        }

        let lexical = try payload([])
        XCTAssertEqual(lexical.json["quorum"] as? Bool, true,
                       "moins de dix pages portent tous les mots : \(lexical.json)")
        XCTAssertTrue(lexical.stderr.contains(
            "Few pages carry every word"), lexical.stderr)

        let hybride = try payload(["--hybrid"])
        XCTAssertEqual(hybride.json["hybrid"] as? Bool, true, "\(hybride.json)")
        XCTAssertEqual(hybride.json["quorum"] as? Bool, true,
                       "le canal lexical de la fusion le relâche aussi, et le "
                       + "dit désormais : \(hybride.json)")
        XCTAssertTrue(hybride.stderr.contains(
            "Few pages carry every word"), hybride.stderr)
        // `why` ne peut plus annoncer `exact` sur une page qui ne porte pas
        // tous les mots — c'était le constat PM-14, côté hybride.
        let hits = try XCTUnwrap(hybride.json["hits"] as? [[String: Any]])
        XCTAssertFalse(hits.isEmpty)
        for hit in hits where hit["semantic_only"] as? Bool == false {
            let why = try XCTUnwrap(hit["why"] as? [String: Any])
            XCTAssertEqual(why["kind"] as? String, "partial", "\(why)")
        }

        // `--no-quorum` : le ET strict revient, dans les deux modes.
        for extra in [["--no-quorum"], ["--hybrid", "--no-quorum"]] {
            let strict = try payload(extra)
            XCTAssertNil(strict.json["quorum"], "\(extra) : \(strict.json)")
            XCTAssertFalse(strict.stderr.contains("Few pages carry every word"),
                           "\(extra) : \(strict.stderr)")
        }
    }

    /// `doctor --json` annonce le modèle quand il est là. C'est la seule
    /// manière, pour un utilisateur, d'apprendre que `embed` refusera de
    /// partir — l'absence ne se voyait nulle part ailleurs (audit D6).
    func testDoctorAnnouncesTheModel() throws {
        let result = try Recette.run(["doctor", "--json"], database: database)
        XCTAssertEqual(result.status, 0, result.describe)
        let payload = try XCTUnwrap(try JSONSerialization.jsonObject(
            with: Data(result.stdout.utf8)) as? [String: Any])
        XCTAssertEqual(payload["semantic_model"] as? Bool, true)
        XCTAssertNotNil(payload["semantic_model_path"] as? String)
        XCTAssertNotNil(payload["semantic_model_revision"] as? Int)
    }
}
