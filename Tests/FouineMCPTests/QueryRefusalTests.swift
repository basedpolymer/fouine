// QueryRefusalTests.swift — une requête que le modèle peut corriger est une
// erreur d'OUTIL. Propriété : A-MCP. Audit A1m-07, idée 5.
// SPDX-License-Identifier: LicenseRef-Fouine-Source-Available
//
// La règle de `docs/mcp.md` : les erreurs de REQUÊTE (outil inconnu, argument
// du mauvais type) sont des erreurs JSON-RPC ; les erreurs d'OUTIL sont des
// résultats `isError: true`, « c'est cette seconde forme que le modèle sait
// lire et corriger ». Une syntaxe de recherche refusée est du second genre :
// l'argument `query` est une chaîne parfaitement valide, c'est son CONTENU que
// le modèle doit réécrire.

import Foundation
import XCTest
import FouineCore
import FouineMCP
import FouineMCPKit

final class QueryRefusalTests: XCTestCase {

    private func search(_ query: String, on index: TempIndex,
                        server: MCPServer) throws -> [String: Any] {
        let arguments = try JSONSerialization.data(
            withJSONObject: ["name": "fouine_search",
                             "arguments": ["query": query]])
        let line = #"{"jsonrpc":"2.0","id":1,"method":"tools/call","params":"#
            + String(decoding: arguments, as: UTF8.self) + "}"
        let response = try JSONMatch.object(XCTUnwrap(server.handle(Data(line.utf8))))
        XCTAssertNil(response["error"],
                     "une requête refusée ne doit pas casser la session JSON-RPC")
        return try XCTUnwrap(response["result"] as? [String: Any])
    }

    private func text(_ result: [String: Any]) -> String {
        ((result["content"] as? [[String: Any]])?.first?["text"] as? String) ?? ""
    }

    /// `azote OR carbone` — la requête qu'un modèle de langage écrit sans y
    /// penser une fois sur deux. Elle rendait « SQLite error 1: fts5: syntax
    /// error near "OR" » : un diagnostic de BASE DE DONNÉES pour une faute de
    /// syntaxe, c'est-à-dire l'inverse de ce qu'il faut lire (audit A1m-07).
    func testUppercaseOperatorIsAToolErrorWithTheRule() throws {
        let index = try TempIndex()
        let server = try index.makeServer()
        for word in ["AND", "OR", "NOT"] {
            let result = try search("azote \(word) carbone", on: index, server: server)
            XCTAssertEqual(result["isError"] as? Bool, true, "\(word) : \(result)")
            let message = text(result)
            XCTAssertTrue(message.contains("“\(word)” is a search operator"), message)
            XCTAssertTrue(message.contains("-word"), message)
            XCTAssertFalse(message.contains("SQLite"), message)
        }
    }

    /// Les autres refus de syntaxe suivent la même règle : un `-32602` sort de
    /// la boucle de l'outil chez plusieurs clients, un `isError` porte la phrase
    /// là où le modèle la lit et réessaie.
    func testOtherQueryRefusalsAreToolErrorsToo() throws {
        let index = try TempIndex()
        let server = try index.makeServer()
        for (query, expected) in [("spe*", "prefix too short"),
                                  ("-azote", "exclusion alone")] {
            let result = try search(query, on: index, server: server)
            XCTAssertEqual(result["isError"] as? Bool, true, "\(query) : \(result)")
            XCTAssertTrue(text(result).contains(expected), text(result))
        }
    }

    // MARK: - Idée 5 : l'étiquette de dossier inconnue

    /// `dossier:Cour` rendait ZÉRO RÉSULTAT, sans un mot : pour un modèle, un
    /// corpus qui ne contient rien sur le sujet. Le message nomme les
    /// étiquettes qui existent — celles de `fouine_status.roots`.
    func testUnknownFolderIsAToolErrorNamingTheRealOnes() throws {
        let index = try TempIndex(roots: ["Livres", "M2SU"])
        let server = try index.makeServer()

        let bySyntax = try search("dossier:Cour electrolyse", on: index, server: server)
        XCTAssertEqual(bySyntax["isError"] as? Bool, true, "\(bySyntax)")
        XCTAssertTrue(text(bySyntax).contains("unknown folder “Cour” — yours are: Livres, M2SU"),
                      text(bySyntax))

        // L'argument `folder` suit la même règle que la syntaxe.
        let arguments = #"{"name":"fouine_search","arguments":{"query":"electrolyse","folder":"Cour"}}"#
        let response = try JSONMatch.object(XCTUnwrap(server.handle(Data(
            (#"{"jsonrpc":"2.0","id":2,"method":"tools/call","params":"# + arguments + "}").utf8))))
        let result = try XCTUnwrap(response["result"] as? [String: Any])
        XCTAssertEqual(result["isError"] as? Bool, true, "\(result)")
    }

    /// Une simple différence de casse n'est pas une erreur : l'étiquette est
    /// canonisée, sans quoi le filtre SQL (comparaison exacte) ne rendrait rien.
    func testFolderLabelIsCanonicalisedByCase() throws {
        let index = try TempIndex(roots: ["Livres"])
        let server = try index.makeServer()
        let result = try search("dossier:livres electrolyse", on: index, server: server)
        XCTAssertNil(result["isError"], "\(result)")
        let structured = try XCTUnwrap(result["structuredContent"] as? [String: Any])
        XCTAssertFalse(((structured["hits"] as? [Any]) ?? []).isEmpty,
                       "le filtre doit porter sur « Livres » : \(structured)")
    }

    /// Sans racine enregistrée, il n'y a rien à contredire : le filtre part tel
    /// quel, comme avant. Un refus fondé sur une liste vide serait un faux
    /// positif.
    func testWithoutRootsNoFolderIsRefused() throws {
        let index = try TempIndex()
        let server = try index.makeServer()
        let result = try search("dossier:Cour electrolyse", on: index, server: server)
        XCTAssertNil(result["isError"], "\(result)")
    }

    /// En minuscules, ce sont trois mots ordinaires : la recherche aboutit.
    func testLowercaseOperatorsSearchNormally() throws {
        let index = try TempIndex()
        let server = try index.makeServer()
        let result = try search("or", on: index, server: server)
        XCTAssertNil(result["isError"], "\(result)")
    }

    // MARK: - CM-11 : les deux autres filtres qui se trompaient en silence

    /// Un appel d'outil avec des arguments arbitraires — c'est par là que
    /// passent `lang` et `doc_ids`, qui n'ont pas de syntaxe de requête.
    private func call(_ arguments: [String: Any], on server: MCPServer) throws
        -> [String: Any] {
        let params = try JSONSerialization.data(
            withJSONObject: ["name": "fouine_search", "arguments": arguments])
        let line = #"{"jsonrpc":"2.0","id":7,"method":"tools/call","params":"#
            + String(decoding: params, as: UTF8.self) + "}"
        let response = try JSONMatch.object(XCTUnwrap(server.handle(Data(line.utf8))))
        XCTAssertNil(response["error"],
                     "un filtre refusé ne doit pas casser la session JSON-RPC")
        return try XCTUnwrap(response["result"] as? [String: Any])
    }

    /// `lang: "xx"` rendait un SUCCÈS à zéro résultat, en deux secondes — et un
    /// assistant en concluait « votre corpus ne traite pas de ce sujet ». Le
    /// refus nomme les langues qui existent, `und` comprise.
    func testUnknownLanguageIsAToolErrorNamingTheRealOnes() throws {
        let index = try TempIndex(documents: 3, languages: ["fr", "en", "und"])
        let server = try index.makeServer()

        let result = try call(["query": "electrolyse", "lang": "xx"], on: server)
        XCTAssertEqual(result["isError"] as? Bool, true, "\(result)")
        XCTAssertTrue(
            text(result).contains(
                "unknown language “xx” — languages in this index: en, fr, und"),
            text(result))
    }

    /// Une langue CONNUE passe, et rend les pages du document qui la porte.
    /// Sans ce contrôle, un refus trop large ferait pire que le silence.
    func testAKnownLanguagePassesThrough() throws {
        let index = try TempIndex(documents: 3, languages: ["fr", "en", "und"])
        let server = try index.makeServer()

        let result = try call(["query": "electrolyse", "lang": "en"], on: server)
        XCTAssertNil(result["isError"], "\(result)")
        let structured = try XCTUnwrap(result["structuredContent"] as? [String: Any])
        XCTAssertEqual(structured["total_docs"] as? Int, 1, "\(structured)")
    }

    /// Sans aucune langue dans l'index, il n'y a rien à contredire : le filtre
    /// part tel quel, comme pour `dossier:` sans racine enregistrée.
    func testWithoutAnyLanguageNoFilterIsRefused() throws {
        let index = try TempIndex()
        let server = try index.makeServer()
        let result = try call(["query": "electrolyse", "lang": "xx"], on: server)
        XCTAssertNil(result["isError"], "\(result)")
    }

    /// `doc_ids` inconnu : même faute, même remède. Le message renvoie vers
    /// l'outil qui donne les bons identifiants.
    func testUnknownDocumentIDsAreAToolErrorPointingAtTheRightTool() throws {
        let index = try TempIndex()
        let server = try index.makeServer()

        let result = try call(["query": "electrolyse", "doc_ids": [1, 999_999]],
                              on: server)
        XCTAssertEqual(result["isError"] as? Bool, true, "\(result)")
        XCTAssertTrue(text(result).contains("unknown document id(s): 999999"),
                      text(result))
        XCTAssertTrue(text(result).contains("fouine_list_documents"), text(result))
    }

    /// Des identifiants qui existent tous ne déclenchent rien : la recherche
    /// « dans les résultats » reste ce qu'elle était.
    func testKnownDocumentIDsPassThrough() throws {
        let index = try TempIndex()
        let server = try index.makeServer()
        let result = try call(["query": "electrolyse", "doc_ids": [1]], on: server)
        XCTAssertNil(result["isError"], "\(result)")
    }
}
