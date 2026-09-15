// FallbackTests.swift — le repli sémantique, et la charge paresseuse.
// SPDX-License-Identifier: LicenseRef-Fouine-Source-Available
//
// LE PIRE MODE DE PANNE D'UN SERVEUR D'AGENT N'EST PAS L'ERREUR : c'est la
// réponse plausible et fausse. Trois formes de la même faute sont écartées ici.
//
//   · l'ERREUR à la place du repli. `mode: "hybrid"` sans modèle rendrait
//     `isError`, et le modèle en conclurait que l'index est cassé. Il ne
//     rappellerait plus l'outil.
//   · le REPLI MUET. La même chose sans `note` : le modèle croit avoir fait une
//     recherche sémantique, n'en tire rien, et en conclut que le corpus ne
//     contient pas ce qu'il cherche.
//   · le CHARGEMENT INUTILE. Un serveur qui charge 571 Mo de CoreML pour
//     répondre à un `fouine_status` ou à un `fouine_similar_pages` rendrait le
//     serveur résident plus coûteux que la CLI qu'il remplace.
//
// Aucun test de ce fichier ne demande le modèle : ils éprouvent son ABSENCE,
// et le fait qu'on ne le charge pas. Le test sous modèle vit dans
// `SemanticModelTests`, et se saute sans lui.

import Foundation
import XCTest
import FouineCore
@testable import FouineMCP
import FouineMCPKit

final class FallbackTests: XCTestCase {

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

    private func search(_ server: MCPServer, _ arguments: String) throws
        -> [String: Any] {
        try structured(server.handle(Data(
            #"{"jsonrpc":"2.0","id":1,"method":"tools/call","params":{"name":"fouine_search","arguments":\#(arguments)}}"#.utf8)))
    }

    /// Sans modèle ET sans vecteur : le repli nomme la pièce qui manque en
    /// PREMIER — le modèle, parce que c'est celle qu'il faut installer avant de
    /// pouvoir en produire.
    func testHybridWithoutModelFallsBackAndSaysWhy() throws {
        let index = try TempIndex()
        let server = try index.makeServer()
        let payload = try search(server, #"{"query":"electrolyse","mode":"hybrid"}"#)

        XCTAssertEqual(payload["mode_used"] as? String, "lexical")
        XCTAssertEqual(payload["semantic_available"] as? Bool, false)
        XCTAssertEqual(payload["note"] as? String,
                       "semantic model not installed — lexical only "
                       + "(`fouine model download` installs it)")
        XCTAssertFalse(((payload["hits"] as? [Any]) ?? []).isEmpty,
                       "la recherche a MARCHÉ : c'est pourquoi ce n'est pas une erreur")
    }

    /// `mode: "auto"` — le défaut — prend la même décision et la dit de la même
    /// façon. Un client qui ne précise rien ne doit jamais avoir à deviner ce
    /// qu'il a obtenu.
    func testAutoIsAsExplicitAsHybrid() throws {
        let index = try TempIndex(vectorisedPages: 2)
        let server = try index.makeServer()
        let auto = try search(server, #"{"query":"electrolyse"}"#)
        let asked = try search(server, #"{"query":"electrolyse","mode":"hybrid"}"#)
        XCTAssertEqual(auto["mode_used"] as? String, "lexical")
        XCTAssertEqual(auto["note"] as? String, asked["note"] as? String)
    }

    /// `mode: "lexical"` DEMANDÉ ne porte aucune note : il n'y a rien à
    /// expliquer, le client a eu ce qu'il voulait. Une note systématique
    /// s'ignore.
    func testAskingForLexicalCarriesNoNote() throws {
        let index = try TempIndex()
        let server = try index.makeServer()
        let payload = try search(server, #"{"query":"electrolyse","mode":"lexical"}"#)
        XCTAssertTrue(payload["note"] is NSNull)
    }

    /// La couverture sémantique est rendue MÊME en lexical : c'est le chiffre
    /// qui explique pourquoi passer en hybride n'apporterait rien aujourd'hui.
    func testCoverageIsReportedEvenInLexicalMode() throws {
        let index = try TempIndex(vectorisedPages: 3)
        let server = try index.makeServer()
        let payload = try search(server, #"{"query":"electrolyse","mode":"lexical"}"#)
        let coverage = try XCTUnwrap(payload["semantic_coverage_pct"] as? NSNumber)
        XCTAssertEqual(coverage.doubleValue, 50, accuracy: 0.01,
                       "3 vecteurs sur 6 pages")
    }

    /// `fouine_similar_pages` sur une base SANS vecteur : succès, liste vide,
    /// `source_has_vector: false`, et la commande à lancer. Jamais une erreur —
    /// la question était bonne, c'est la donnée qui manque.
    func testSimilarPagesWithoutVectorsIsASuccess() throws {
        let index = try TempIndex()
        let server = try index.makeServer()
        let payload = try structured(server.handle(Data(
            #"{"jsonrpc":"2.0","id":1,"method":"tools/call","params":{"name":"fouine_similar_pages","arguments":{"doc_id":1,"page":1}}}"#.utf8)))

        XCTAssertEqual(payload["source_has_vector"] as? Bool, false)
        XCTAssertEqual(payload["vector_count"] as? Int, 0)
        XCTAssertEqual(payload["note"] as? String,
                       "no vector in the index yet — run `fouine embed` to build them")
        XCTAssertTrue(((payload["neighbours"] as? [Any]) ?? []).isEmpty)
    }

    /// LE CONTRAT DE LA CHARGE PARESSEUSE. Une séance complète de recherche
    /// lexicale, de lecture et de listage laisse `model_loaded` à faux ET
    /// `index_freshness` à nul : rien n'a été chargé, et le serveur est resté à
    /// son empreinte de départ.
    func testALexicalSessionLoadsNeitherModelNorIndex() throws {
        let index = try TempIndex(vectorisedPages: 2)
        let server = try index.makeServer()
        for call in [
            #"{"name":"fouine_search","arguments":{"query":"electrolyse"}}"#,
            #"{"name":"fouine_read_page","arguments":{"doc_id":1,"page":1}}"#,
            #"{"name":"fouine_list_documents","arguments":{}}"#,
        ] {
            _ = server.handle(Data(
                #"{"jsonrpc":"2.0","id":1,"method":"tools/call","params":\#(call)}"#.utf8))
        }
        let status = try structured(server.handle(Data(
            #"{"jsonrpc":"2.0","id":9,"method":"tools/call","params":{"name":"fouine_status","arguments":{"include_agent":false}}}"#.utf8)))
        let semantic = try XCTUnwrap(status["semantic"] as? [String: Any])
        XCTAssertEqual(semantic["model_loaded"] as? Bool, false)
        let freshness = try XCTUnwrap(status["index_freshness"] as? [String: Any])
        XCTAssertTrue(freshness["vector_index_count"] is NSNull,
                      "aucun index chargé : la clé doit rester nulle")
    }

    /// …et `fouine_similar_pages` charge l'INDEX sans charger le MODÈLE. C'est
    /// la distinction qui rend cet outil bon marché, et elle est vérifiée par
    /// les deux champs à la fois.
    func testSimilarPagesLoadsTheIndexButNotTheModel() throws {
        let index = try TempIndex(vectorisedPages: 2)
        let server = try index.makeServer()
        _ = server.handle(Data(
            #"{"jsonrpc":"2.0","id":1,"method":"tools/call","params":{"name":"fouine_similar_pages","arguments":{"doc_id":1,"page":1}}}"#.utf8))

        let status = try structured(server.handle(Data(
            #"{"jsonrpc":"2.0","id":2,"method":"tools/call","params":{"name":"fouine_status","arguments":{"include_agent":false}}}"#.utf8)))
        XCTAssertEqual((status["semantic"] as? [String: Any])?["model_loaded"] as? Bool,
                       false, "les voisins n'encodent aucun texte")
        let freshness = try XCTUnwrap(status["index_freshness"] as? [String: Any])
        XCTAssertEqual(freshness["vector_index_count"] as? Int, 2)
        XCTAssertNotNil(freshness["vector_index_loaded_at"] as? String)
    }

    // MARK: - A1m-08 : le mot très fréquent est DIT, pas accéléré

    /// Le total borné dit que le mot est partout — et c'est ce qui vient de
    /// coûter sept secondes de `ORDER BY bm25` sur la base de production. Le
    /// modèle le lit dans `note` et peut ajouter un second terme de lui-même.
    ///
    /// Le seuil vaut 50 000 pages : la condition est éprouvée sur le
    /// COMPOSITEUR de notes, pas en semant un corpus qu'aucune suite unitaire
    /// ne peut se payer. La condition elle-même (`totalsApproximate` au-delà du
    /// seuil) est éprouvée dans `FouineCoreTests.SearchTests`.
    func testVeryCommonWordNoteIsAddedAndNeverReplacesAnother() {
        XCTAssertNil(SearchTool.veryCommonWordNote(false))
        XCTAssertEqual(SearchTool.veryCommonWordNote(true),
                       "very common word — add a second word to narrow the search")
        // Deux limites du même résultat : les deux se disent.
        XCTAssertEqual(
            SearchTool.notes("only 16.6 % of pages are vectorised",
                             SearchTool.veryCommonWordNote(true)),
            "only 16.6 % of pages are vectorised · very common word — "
            + "add a second word to narrow the search")
        XCTAssertEqual(SearchTool.notes(nil, SearchTool.veryCommonWordNote(true)),
                       "very common word — add a second word to narrow the search")
        XCTAssertNil(SearchTool.notes(nil, nil))
        XCTAssertNil(SearchTool.notes("", nil), "une note vide n'est pas une note")
    }

    /// Une recherche ordinaire ne porte AUCUNE de ces notes : le conseil doit se
    /// voir quand il compte, et se taire le reste du temps.
    func testAnOrdinarySearchCarriesNoNote() throws {
        let index = try TempIndex()
        let server = try index.makeServer()
        let payload = try search(server, #"{"query":"electrolyse","mode":"lexical"}"#)
        XCTAssertEqual(payload["totals_approximate"] as? Bool, false)
        XCTAssertTrue(payload["note"] is NSNull, "note : \(payload["note"] ?? "nil")")
    }
}
