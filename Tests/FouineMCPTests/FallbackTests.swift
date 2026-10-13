// FallbackTests.swift — ce que le serveur DIT quand ce qu'il rend n'est pas
// exactement ce qui a été demandé.
// SPDX-License-Identifier: LicenseRef-Fouine-Source-Available
//
// LE PIRE MODE DE PANNE D'UN SERVEUR D'AGENT N'EST PAS L'ERREUR : c'est la
// réponse plausible et fausse. Une recherche qui s'est repliée en flou, ou dont
// le quorum a relâché le ET, rend donc un succès qui le DIT dans `note` : le
// taire ferait croire au modèle que le corpus dit ce qu'il ne dit pas.

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
            SearchTool.notes(SearchTool.quorumNote(true),
                             SearchTool.veryCommonWordNote(true)),
            "Few pages carry every word — also showing pages that carry most "
            + "of them. · very common word — add a second word to narrow "
            + "the search")
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
        let payload = try search(server, #"{"query":"electrolyse"}"#)
        XCTAssertEqual(payload["totals_approximate"] as? Bool, false)
        XCTAssertTrue(payload["note"] is NSNull, "note : \(payload["note"] ?? "nil")")
    }
}
