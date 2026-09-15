// SourceParameterTests.swift — paramètre `source` de `fouine_search` (lot P3).
// SPDX-License-Identifier: LicenseRef-Fouine-Source-Available
//
// Le schéma est figé par `Transcripts/tools-list.jsonl` ; ce qu'une
// transcription ne montre pas, c'est que le paramètre AGIT — et qu'une valeur
// inconnue ne filtre rien plutôt que de rendre une erreur, comme les autres
// filtres d'argument du serveur.

import Foundation
import XCTest
import GRDB
import FouineCore
import FouineMCPKit
@testable import FouineMCP

final class SourceParameterTests: XCTestCase {

    /// La base jetable n'a que des pages natives : une page du document 1 est
    /// marquée « scannée » par SQL direct, comme les racines des autres tests.
    private func mixedIndex() throws -> TempIndex {
        let index = try TempIndex()
        let queue = try DatabaseQueue(path: index.databaseURL.path)
        try queue.write { db in
            try db.execute(sql: "UPDATE page_src SET src = 2 WHERE doc_id = 1 AND page = 2")
        }
        return index
    }

    private func hits(_ index: TempIndex, source: String?) throws -> [[String: Any]] {
        let server = try index.makeServer()
        let filter = source.map { #","source":"\#($0)""# } ?? ""
        let response = try XCTUnwrap(server.handle(Data(
            #"{"jsonrpc":"2.0","id":1,"method":"tools/call","params":{"name":"fouine_search","arguments":{"query":"electrolyse","limit":20\#(filter)}}}"#.utf8)))
        let object = try JSONMatch.object(response)
        XCTAssertNil(object["error"], "\(object)")
        let result = try XCTUnwrap(object["result"] as? [String: Any])
        let structured = try XCTUnwrap(result["structuredContent"] as? [String: Any])
        return try XCTUnwrap(structured["hits"] as? [[String: Any]])
    }

    private func keys(_ hits: [[String: Any]]) -> Set<String> {
        Set(hits.map { "\($0["doc_id"] ?? "?")/\($0["page"] ?? "?")" })
    }

    func testOCRNeRendQueLaPageScannee() throws {
        let index = try mixedIndex()
        XCTAssertEqual(keys(try hits(index, source: "ocr")), ["1/2"])
    }

    func testNativeEcarteLaPageScannee() throws {
        let index = try mixedIndex()
        let natives = keys(try hits(index, source: "native"))
        XCTAssertFalse(natives.contains("1/2"))
        XCTAssertEqual(natives.count, keys(try hits(index, source: nil)).count - 1,
                       "les deux provenances partitionnent le jeu")
    }

    /// Une valeur hors de l'énumération est refusée par le SCHÉMA, avant
    /// d'atteindre l'outil : un modèle qui écrit « scanned » l'apprend, au lieu
    /// d'obtenir en silence une recherche qu'il n'a pas demandée.
    func testUneValeurHorsEnumerationEstRefusee() throws {
        let index = try mixedIndex()
        let server = try index.makeServer()
        let response = try XCTUnwrap(server.handle(Data(
            #"{"jsonrpc":"2.0","id":1,"method":"tools/call","params":{"name":"fouine_search","arguments":{"query":"electrolyse","source":"scanned"}}}"#.utf8)))
        let object = try JSONMatch.object(response)
        XCTAssertNotNil(object["error"], "\(object)")
    }
}
