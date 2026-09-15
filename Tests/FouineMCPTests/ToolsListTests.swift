// ToolsListTests.swift — ce qu'un client lit AVANT d'appeler (CM-10).
// SPDX-License-Identifier: LicenseRef-Fouine-Source-Available
//
// Les `annotations` ne sont pas de la décoration : un client qui ne voit pas
// `readOnlyHint: true` doit supposer qu'un outil peut modifier quelque chose, et
// demande confirmation à chaque appel. Sur un serveur dont tout l'argument est
// qu'il ne peut rien casser — trois barrières indépendantes, `ReadOnlyTests` —,
// c'est une friction pour rien, et c'est aussi ce qui ferait rejeter le `.mcpb`
// à l'annuaire Claude (PR-11).
//
// La transcription `tools-list.jsonl` fige déjà la réponse entière. Ce test-ci
// dit la RÈGLE plutôt que la forme : les CINQ, tous, sans exception — un outil
// ajouté demain sans son annotation serait le seul du catalogue à faire
// demander une confirmation.

import Foundation
import XCTest
import FouineMCP
import FouineMCPKit

final class ToolsListTests: XCTestCase {

    private func tools() throws -> [[String: Any]] {
        let index = try TempIndex()
        let server = try index.makeServer()
        _ = server.handle(Data(
            #"{"jsonrpc":"2.0","id":1,"method":"initialize","params":{"protocolVersion":"2025-06-18","capabilities":{}}}"#.utf8))
        let raw = try XCTUnwrap(
            server.handle(Data(#"{"jsonrpc":"2.0","id":2,"method":"tools/list"}"#.utf8)))
        let result = try XCTUnwrap(try JSONMatch.object(raw)["result"] as? [String: Any])
        return try XCTUnwrap(result["tools"] as? [[String: Any]])
    }

    func testTheFiveToolsAllAnnounceThemselvesAsReadOnly() throws {
        let tools = try self.tools()
        XCTAssertEqual(tools.count, 5)
        for tool in tools {
            let name = tool["name"] as? String ?? "?"
            let annotations = try XCTUnwrap(tool["annotations"] as? [String: Any],
                                            "\(name) : aucune annotation")
            XCTAssertEqual(annotations["readOnlyHint"] as? Bool, true, name)
            XCTAssertEqual(annotations["destructiveHint"] as? Bool, false, name)
            XCTAssertEqual(annotations["idempotentHint"] as? Bool, true, name)
            // Le domaine est CLOS : l'index local, jamais le web. C'est ce qui
            // distingue Fouine d'un outil de recherche en ligne, et un client
            // peut s'en servir pour décider ce qu'il montre à l'utilisateur.
            XCTAssertEqual(annotations["openWorldHint"] as? Bool, false, name)
            XCTAssertEqual(annotations["title"] as? String, tool["title"] as? String,
                           "\(name) : le titre annoté doit être celui de l'outil")
        }
    }
}
