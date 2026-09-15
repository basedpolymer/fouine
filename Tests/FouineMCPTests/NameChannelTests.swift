// NameChannelTests.swift — `name_matches` et `fuzzy_fallback` (lot MP1).
// SPDX-License-Identifier: LicenseRef-Fouine-Source-Available
//
// Les transcriptions golden figent la FORME des deux clés sur une base où
// aucune ne se remplit ; ce fichier éprouve ce qu'elles ne peuvent pas montrer :
// un document qui ne répond que par son NOM (PR-02 : l'assistant le trouvait
// par `path_contains`, l'humain pas du tout) et une requête mal orthographiée
// qui n'obtient de réponse que par le repli (C2-08). Les deux comptent pour un
// modèle : dans les deux cas, ce qu'il lit n'est PAS la réponse littérale à ce
// qu'il a demandé, et rien d'autre dans la réponse ne le dirait.

import Foundation
import XCTest
import FouineCore
import FouineMCP
import FouineMCPKit

final class NameChannelTests: XCTestCase {

    private func payload(_ server: MCPServer, query: String,
                         id: Int = 1) throws -> [String: Any] {
        let response = try XCTUnwrap(server.handle(Data(
            #"{"jsonrpc":"2.0","id":\#(id),"method":"tools/call","params":{"name":"fouine_search","arguments":{"query":"\#(query)"}}}"#.utf8)))
        let object = try JSONMatch.object(response)
        XCTAssertNil(object["error"], "\(query) refusée : \(object)")
        return try XCTUnwrap((object["result"] as? [String: Any])?["structuredContent"]
            as? [String: Any])
    }

    /// « document » est dans le NOM des deux fichiers de la base jetable ET dans
    /// leur texte : les deux canaux répondent, et les `hits` ne portent pas les
    /// documents nommés — ce sont des pages.
    func testTheNameChannelAnswersBesideThePages() throws {
        let index = try TempIndex(documents: 2, pagesPerDocument: 1)
        let payload = try payload(index.makeServer(), query: "document-1")
        let names = try XCTUnwrap(payload["name_matches"] as? [[String: Any]])
        XCTAssertEqual(names.count, 1)
        XCTAssertEqual(names[0]["doc_id"] as? Int64 ?? -1, 1)
        XCTAssertEqual(names[0]["path"] as? String,
                       "Users/essai/Livres/document-1.pdf")
        // Le lien mène à la PAGE 1 : un nom ne désigne aucune page, et c'est le
        // point d'entrée du document.
        XCTAssertEqual(names[0]["link"] as? String, "fouine://open?doc=1&page=1")
        XCTAssertEqual(payload["fuzzy_fallback"] as? Bool, false)
    }

    /// Aucun nom ne répond : la clé est là, vide. Un champ ABSENT n'apprend
    /// rien à un modèle — c'est la règle de tout le fichier `SearchTool`.
    func testTheKeyIsThereEvenWhenNoNameAnswers() throws {
        let index = try TempIndex()
        let payload = try payload(index.makeServer(), query: "electrolyse")
        XCTAssertEqual((payload["name_matches"] as? [[String: Any]])?.count, 0)
    }

    /// `electrolyze` n'existe nulle part ; `electrolyse` est sur toutes les
    /// pages. Le repli répond, et la réponse le DIT — dans `fuzzy_fallback` et
    /// dans `note`, où le modèle lit déjà les limites de son résultat.
    func testTheFuzzyFallbackIsAnnouncedInTheNote() throws {
        let index = try TempIndex(documents: 1, pagesPerDocument: 1)
        let store = GRDBStore()
        try store.open(at: index.databaseURL)
        try TrigramExpander(store: store).warm()

        let payload = try payload(index.makeServer(), query: "electrolyze")
        XCTAssertEqual(payload["fuzzy_fallback"] as? Bool, true)
        let hits = try XCTUnwrap(payload["hits"] as? [[String: Any]])
        XCTAssertEqual(hits.count, 1)
        XCTAssertEqual(hits[0]["fuzzy_distance"] as? Int, 1)
        let note = try XCTUnwrap(payload["note"] as? String)
        XCTAssertTrue(note.contains(SearchAdvice.fuzzyFallback), note)
    }
}
