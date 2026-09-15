// SemanticModelTests.swift — le VRAI moteur, sur une base vectorisée pour de bon.
// SPDX-License-Identifier: LicenseRef-Fouine-Source-Available
//
// TOUT LE RESTE DE CETTE SUITE ÉPROUVE L'ABSENCE DU MODÈLE — le repli, la
// charge paresseuse, le silence réseau. Ce fichier-ci éprouve sa PRÉSENCE, et
// c'est le seul qui puisse répondre à la question qui compte vraiment : est-ce
// que `mode: "hybrid"` fait ce qu'il dit, de bout en bout ?
//
// SAUTÉ SANS LE MODÈLE, motif existant du dépôt (`EmbedTests.RealModelTests`) :
// 220 Mo ne sont pas un prérequis de CI. Ce que le saut coûte est écrit dans
// `docs/tests.md` avec les autres.
//
// TROIS PAGES, et pas trente : le point n'est pas la performance du moteur —
// `FouineEmbedTests` s'en charge — mais le CÂBLAGE. Un vecteur produit par
// `EmbedRun`, relu par `VectorIndex`, comparé à une requête encodée par
// `E5Encoder`, fusionné par RRF, et habillé par `SearchTool`. Cinq pièces, et
// c'est la seule chose qui les fasse toutes travailler ensemble.

import Foundation
import XCTest
import FouineCore
import FouineEmbed
import FouineMCP

final class SemanticModelTests: XCTestCase {

    /// Le répertoire du modèle réel, ou `nil` — même motif qu'`EmbedTests`.
    private func realModelDirectory() -> URL? {
        let dir = EmbedPaths.modelDirectory()
        return EmbedPaths.modelAvailable(at: dir) ? dir : nil
    }

    /// L'encodeur qui VECTORISE les fixtures, chargé UNE fois pour les trois
    /// tests (~2,5 s par chargement sur i5 ; lot I2). Ce n'est pas lui qu'on
    /// éprouve : le serveur charge le SIEN par `SemanticEngine`, et c'est ce
    /// chargement-là que `testTheModelIsLoadedOnceAndOnlyWhenNeeded` mesure —
    /// il n'a aucune vue sur celui-ci.
    private static let fixtureEncoder = LoadedEncoder {
        try E5Encoder(modelDir: EmbedPaths.modelDirectory())
    }

    private final class LoadedEncoder: @unchecked Sendable {
        let result: Result<E5Encoder, Error>
        init(_ make: () throws -> E5Encoder) { result = Result(catching: make) }
    }

    /// Une base jetable dont TROIS pages portent un vrai vecteur, produit par
    /// le vrai moteur. `EmbedRun` prend le verrou d'écriture et le rend ; le
    /// serveur MCP ouvre ensuite en lecture seule, comme en production.
    private func makeVectorisedIndex(_ modelDirectory: URL) throws -> TempIndex {
        let index = try TempIndex(documents: 1, pagesPerDocument: 3, pageChars: 400)
        let writer = GRDBStore()
        try writer.open(at: index.databaseURL)
        defer { writer.releaseWriteLock() }
        XCTAssertEqual(modelDirectory, EmbedPaths.modelDirectory(),
                       "l'encodeur partagé lit le répertoire par défaut")
        let engine = try Self.fixtureEncoder.result.get()
        try writer.setVecMeta(modelID: engine.modelID, dim: engine.dimension,
                              revision: engine.revision)
        var config = EmbedRun.Config()
        config.minChars = 1
        config.log = { _ in }
        let summary = try EmbedRun.run(store: writer, engine: engine, config: config)
        XCTAssertEqual(summary.embedded, 3, "trois pages à vectoriser")
        return index
    }

    private func structured(_ data: Data?, file: StaticString = #filePath,
                            line: UInt = #line) throws -> [String: Any] {
        let object = try JSONMatch.object(try XCTUnwrap(data, file: file, line: line))
        XCTAssertNil(object["error"], "erreur JSON-RPC : \(object)", file: file, line: line)
        let result = try XCTUnwrap(object["result"] as? [String: Any],
                                   file: file, line: line)
        XCTAssertNil(result["isError"], "isError posé : \(result)", file: file, line: line)
        return try XCTUnwrap(result["structuredContent"] as? [String: Any],
                             file: file, line: line)
    }

    /// `mode: "hybrid"` de bout en bout : le modèle est chargé, l'index est
    /// construit, la fusion RRF a lieu, et la sortie porte tout ce que le
    /// schéma promet.
    func testHybridSearchWithTheRealEngine() throws {
        guard let model = realModelDirectory() else {
            throw XCTSkip("modèle e5-small absent — `fouine model download` "
                          + "l'installe (220 Mo)")
        }
        let index = try makeVectorisedIndex(model)
        let server = try index.makeServer(modelDirectory: model)

        let payload = try structured(server.handle(Data(
            #"{"jsonrpc":"2.0","id":1,"method":"tools/call","params":{"name":"fouine_search","arguments":{"query":"enthalpie libre","mode":"hybrid","limit":3}}}"#.utf8)))

        XCTAssertEqual(payload["mode_used"] as? String, "hybrid")
        XCTAssertEqual(payload["semantic_available"] as? Bool, true)
        XCTAssertTrue(payload["note"] is NSNull || payload["note"] is String)

        let hits = try XCTUnwrap(payload["hits"] as? [[String: Any]])
        XCTAssertFalse(hits.isEmpty, "trois pages vectorisées, la requête doit mordre")

        // La FORME hybride : `rrf` toujours, `cosine`/`z` quand le canal
        // vectoriel a vu la page. Ce sont les champs qu'un client lit pour
        // savoir d'où vient un hit.
        let first = hits[0]
        XCTAssertNotNil(first["rrf"] as? NSNumber)
        XCTAssertNotNil(first["doc_id"] as? Int)
        XCTAssertNotNil(first["snippet"] as? String)
        XCTAssertTrue(first["lex_rank"] is NSNumber || first["vec_rank"] is NSNumber,
                      "un hit vient d'au moins un des deux canaux")

        // `semantic_stats` porte la population balayée POUR CETTE REQUÊTE.
        // C'est ce qui permet de juger un cosinus, que le cosinus seul ne dit
        // pas (C2-01).
        let stats = try XCTUnwrap(payload["semantic_stats"] as? [String: Any])
        XCTAssertEqual(stats["scanned"] as? Int, 3)
        XCTAssertNotNil(stats["mu"] as? NSNumber)
        XCTAssertNotNil(stats["sigma"] as? NSNumber)
        // L'échelle appliquée aux rangs sémantiques est PUBLIÉE (AUDIT-R1 I4) :
        // sans elle, `rrf` ne se relit pas. Ici toutes les pages portent un
        // vecteur : elle vaut 1.
        let scale = try XCTUnwrap(payload["semantic_rank_scale"] as? NSNumber)
        XCTAssertEqual(scale.doubleValue, 1, accuracy: 0.001)
    }

    /// RK-01 : une requête à PHRASE EXACTE ne consulte pas le sens, même en
    /// `mode: "hybrid"` sur un index vectorisé. Le modèle qui lit la réponse
    /// doit pouvoir distinguer ce refus d'une installation incomplète — d'où la
    /// raison dans `hybrid_disarmed` et la phrase dans `note`, à côté d'un
    /// `semantic_available: true`.
    func testAnExactPhraseDisarmsTheSemanticChannel() throws {
        guard let model = realModelDirectory() else {
            throw XCTSkip("modèle e5-small absent — `fouine model download` "
                          + "l'installe (220 Mo)")
        }
        let index = try makeVectorisedIndex(model)
        let server = try index.makeServer(modelDirectory: model)

        let payload = try structured(server.handle(Data(
            #"{"jsonrpc":"2.0","id":1,"method":"tools/call","params":{"name":"fouine_search","arguments":{"query":"\"enthalpie libre\"","mode":"hybrid","limit":3}}}"#.utf8)))

        XCTAssertEqual(payload["mode_used"] as? String, "lexical")
        XCTAssertEqual(payload["semantic_available"] as? Bool, true)
        XCTAssertEqual(payload["hybrid_disarmed"] as? String, "exact_phrase")
        let note = try XCTUnwrap(payload["note"] as? String)
        XCTAssertTrue(note.contains(SemanticDisarmReason.exactPhrase.advice), note)
        // La sortie est celle du canal lexical : ni statistiques du balayage,
        // ni échelle des rangs sémantiques.
        XCTAssertTrue(payload["semantic_stats"] is NSNull)
        XCTAssertTrue(payload["semantic_rank_scale"] is NSNull)
    }

    /// LE CONTRAT DE LA CHARGE PARESSEUSE, éprouvé avec le vrai modèle : il
    /// n'est PAS chargé avant le premier appel hybride, il l'est après, et le
    /// second appel ne le recharge pas — c'est tout l'argument du serveur
    /// résident, et c'est vérifiable par le temps.
    func testTheModelIsLoadedOnceAndOnlyWhenNeeded() throws {
        guard let model = realModelDirectory() else {
            throw XCTSkip("modèle e5-small absent — `fouine model download` "
                          + "l'installe (220 Mo)")
        }
        let index = try makeVectorisedIndex(model)
        let server = try index.makeServer(modelDirectory: model)

        func modelLoaded() throws -> Bool {
            let status = try structured(server.handle(Data(
                #"{"jsonrpc":"2.0","id":9,"method":"tools/call","params":{"name":"fouine_status","arguments":{"include_agent":false}}}"#.utf8)))
            return ((status["semantic"] as? [String: Any])?["model_loaded"]
                     as? Bool) ?? true
        }

        // Une recherche LEXICALE ne charge rien.
        _ = server.handle(Data(
            #"{"jsonrpc":"2.0","id":1,"method":"tools/call","params":{"name":"fouine_search","arguments":{"query":"electrolyse","mode":"lexical"}}}"#.utf8))
        XCTAssertFalse(try modelLoaded(), "le lexical ne doit jamais charger CoreML")

        let cold = Date()
        _ = server.handle(Data(
            #"{"jsonrpc":"2.0","id":2,"method":"tools/call","params":{"name":"fouine_search","arguments":{"query":"enthalpie","mode":"hybrid"}}}"#.utf8))
        let coldSeconds = Date().timeIntervalSince(cold)
        XCTAssertTrue(try modelLoaded(), "le premier hybride charge le modèle")

        let warm = Date()
        _ = server.handle(Data(
            #"{"jsonrpc":"2.0","id":3,"method":"tools/call","params":{"name":"fouine_search","arguments":{"query":"potentiel","mode":"hybrid"}}}"#.utf8))
        let warmSeconds = Date().timeIntervalSince(warm)

        // C'EST LA MESURE QUI JUSTIFIE LE PALIER 4. Le second appel n'a plus à
        // payer le `.mlmodelc` : le facteur est de plusieurs dizaines en
        // production. Le seuil est prudent (×3) pour que le test tienne sur une
        // machine chargée par quatre autres agents.
        XCTAssertLessThan(warmSeconds * 3, coldSeconds,
                          "à froid \(coldSeconds) s, à chaud \(warmSeconds) s : "
                          + "le modèle n'a pas l'air d'être resté résident")
    }

    /// `fouine_similar_pages` sur des vecteurs RÉELS : les voisins sortent, le
    /// cosinus est dans la bande mesurée du corpus, et le modèle n'est TOUJOURS
    /// pas chargé — les voisins n'encodent aucun texte.
    func testSimilarPagesOnRealVectorsWithoutLoadingTheModel() throws {
        guard let model = realModelDirectory() else {
            throw XCTSkip("modèle e5-small absent — `fouine model download` "
                          + "l'installe (220 Mo)")
        }
        let index = try makeVectorisedIndex(model)
        let server = try index.makeServer(modelDirectory: model)

        let payload = try structured(server.handle(Data(
            #"{"jsonrpc":"2.0","id":1,"method":"tools/call","params":{"name":"fouine_similar_pages","arguments":{"doc_id":1,"page":1,"exclude_same_document":false,"limit":5}}}"#.utf8)))

        XCTAssertEqual(payload["source_has_vector"] as? Bool, true)
        XCTAssertEqual(payload["vector_count"] as? Int, 3)
        XCTAssertEqual(payload["model_id"] as? String, "multilingual-e5-small")

        let neighbours = try XCTUnwrap(payload["neighbours"] as? [[String: Any]])
        XCTAssertEqual(neighbours.count, 2, "deux autres pages, la source exclue")
        for neighbour in neighbours {
            XCTAssertNotEqual(neighbour["page"] as? Int, 1,
                              "la page source n'est jamais son propre voisin")
            let cosine = try XCTUnwrap((neighbour["cosine"] as? NSNumber)?.doubleValue)
            XCTAssertGreaterThan(cosine, 0.5)
            XCTAssertLessThanOrEqual(cosine, 1.0)
        }
        // Les voisins sont TRIÉS par cosinus décroissant.
        let cosines = neighbours.compactMap { ($0["cosine"] as? NSNumber)?.doubleValue }
        XCTAssertEqual(cosines, cosines.sorted(by: >))

        let status = try structured(server.handle(Data(
            #"{"jsonrpc":"2.0","id":2,"method":"tools/call","params":{"name":"fouine_status","arguments":{"include_agent":false}}}"#.utf8)))
        XCTAssertEqual((status["semantic"] as? [String: Any])?["model_loaded"] as? Bool,
                       false, "les voisins ne demandent que l'index")
        XCTAssertEqual((status["semantic"] as? [String: Any])?["model_installed"] as? Bool,
                       true)
    }
}
