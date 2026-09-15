// PaginationTests.swift — parcourir tout, sans trou ni doublon.
// SPDX-License-Identifier: LicenseRef-Fouine-Source-Available
//
// `CursorTests` éprouve le JETON ; ce fichier éprouve le PARCOURS, et c'est un
// autre problème. Un curseur peut être parfaitement bien formé et la pagination
// être fausse : un `has_more` déduit d'un total approché s'arrête trop tôt, un
// décalage recalculé sur la limite DEMANDÉE plutôt que sur le nombre de hits
// RENDUS saute une ligne dès que le budget en retire une, et un ordre non total
// permute deux lignes entre deux appels.
//
// La panne est SILENCIEUSE dans les trois cas : le client obtient des résultats
// plausibles, en nombre plausible, et il manque des pages. D'où un test qui
// compte, et qui compare des ENSEMBLES.

import Foundation
import XCTest
import FouineCore
import FouineMCP
import FouineMCPKit

final class PaginationTests: XCTestCase {

    /// LE TEST DU MANDAT : 137 résultats parcourus par pages de 10 rendent
    /// 137 hits DISTINCTS. 137 est premier et n'est pas un multiple de 10 : la
    /// dernière page est partielle, ce qui est exactement là où une pagination
    /// se casse.
    func testWalkingOneHundredAndThirtySevenHitsTenByTen() throws {
        // 137 pages porteuses du terme. 137 est PREMIER : aucun découpage
        // régulier ne tombe juste, et la dernière page est forcément partielle.
        let index = try TempIndex(documents: 137, pagesPerDocument: 1)
        let server = try index.makeServer()

        var seen: [String] = []
        var cursor: String?
        var rounds = 0
        while rounds < 100 {
            rounds += 1
            var arguments = #""query":"electrolyse","limit":10"#
            if let cursor { arguments += #","cursor":"\#(cursor)""# }
            let response = try XCTUnwrap(server.handle(Data(
                #"{"jsonrpc":"2.0","id":\#(rounds),"method":"tools/call","params":{"name":"fouine_search","arguments":{\#(arguments)}}}"#.utf8)))
            let object = try JSONMatch.object(response)
            XCTAssertNil(object["error"], "page \(rounds) refusée : \(object)")
            let payload = try XCTUnwrap(
                (object["result"] as? [String: Any])?["structuredContent"]
                    as? [String: Any])

            let hits = (payload["hits"] as? [[String: Any]]) ?? []
            seen += hits.map { "\($0["doc_id"] ?? "?"):\($0["page"] ?? "?")" }
            guard (payload["has_more"] as? Bool) == true else {
                XCTAssertNil(payload["next_cursor"] as? String,
                             "pas de page suivante, donc pas de curseur")
                break
            }
            cursor = try XCTUnwrap(payload["next_cursor"] as? String,
                                   "has_more sans next_cursor : impasse")
        }

        XCTAssertEqual(seen.count, 137, "137 pages portent le terme")
        XCTAssertEqual(Set(seen).count, seen.count,
                       "un doublon veut dire un décalage qui recule")
        XCTAssertEqual(rounds, 14, "137 par pages de 10 = 14 appels, le dernier de 7")
    }

    /// Le même parcours sur `fouine_list_documents`, qui pagine par une autre
    /// mécanique (LIMIT/OFFSET sur `docs`, pas sur `page_fts`).
    func testWalkingTheDocumentList() throws {
        let index = try TempIndex(documents: 37, pagesPerDocument: 1)
        let server = try index.makeServer()

        var seen: [Int] = []
        var cursor: String?
        for round in 1...20 {
            var arguments = #""limit":5"#
            if let cursor { arguments += #","cursor":"\#(cursor)""# }
            let response = try XCTUnwrap(server.handle(Data(
                #"{"jsonrpc":"2.0","id":\#(round),"method":"tools/call","params":{"name":"fouine_list_documents","arguments":{\#(arguments)}}}"#.utf8)))
            let payload = try XCTUnwrap(
                ((try JSONMatch.object(response))["result"] as? [String: Any])?[
                    "structuredContent"] as? [String: Any])
            XCTAssertEqual(payload["total"] as? Int, 37,
                           "le total ne dépend pas de la page")
            seen += ((payload["documents"] as? [[String: Any]]) ?? [])
                .compactMap { $0["doc_id"] as? Int }
            guard (payload["has_more"] as? Bool) == true else { break }
            cursor = try XCTUnwrap(payload["next_cursor"] as? String)
        }
        XCTAssertEqual(seen.count, 37)
        XCTAssertEqual(Set(seen).count, 37, "aucun document rendu deux fois")
    }

    /// Un curseur de `fouine_search` présenté à `fouine_list_documents` — et
    /// l'inverse. Les deux outils produisent des jetons de la même FORME ; seule
    /// l'empreinte des arguments les distingue, et c'est elle qui doit tenir.
    func testACursorDoesNotCrossFromOneToolToAnother() throws {
        let index = try TempIndex(documents: 4, pagesPerDocument: 4)
        let server = try index.makeServer()

        let first = try XCTUnwrap(server.handle(Data(
            #"{"jsonrpc":"2.0","id":1,"method":"tools/call","params":{"name":"fouine_search","arguments":{"query":"electrolyse","limit":2}}}"#.utf8)))
        let payload = try XCTUnwrap(
            ((try JSONMatch.object(first))["result"] as? [String: Any])?[
                "structuredContent"] as? [String: Any])
        let cursor = try XCTUnwrap(payload["next_cursor"] as? String)

        let crossed = try XCTUnwrap(server.handle(Data(
            #"{"jsonrpc":"2.0","id":2,"method":"tools/call","params":{"name":"fouine_list_documents","arguments":{"limit":2,"cursor":"\#(cursor)"}}}"#.utf8)))
        let error = try XCTUnwrap(
            (try JSONMatch.object(crossed))["error"] as? [String: Any])
        XCTAssertEqual(error["code"] as? Int, -32602)
        XCTAssertEqual((error["data"] as? [String: Any])?["reason"] as? String,
                       "cursor does not match these arguments")
    }

    /// Changer un FILTRE en cours de parcours invalide le curseur. C'est le cas
    /// où la pagination donnerait des résultats faux sans jamais paraître
    /// fausse : la page 2 d'une recherche appliquée aux résultats d'une autre.
    func testChangingAFilterMidWalkIsRefused() throws {
        let index = try TempIndex(documents: 2, pagesPerDocument: 8)
        let server = try index.makeServer()

        let first = try XCTUnwrap(server.handle(Data(
            #"{"jsonrpc":"2.0","id":1,"method":"tools/call","params":{"name":"fouine_search","arguments":{"query":"electrolyse","limit":3}}}"#.utf8)))
        let cursor = try XCTUnwrap(
            (((try JSONMatch.object(first))["result"] as? [String: Any])?[
                "structuredContent"] as? [String: Any])?["next_cursor"] as? String)

        let changed = try XCTUnwrap(server.handle(Data(
            #"{"jsonrpc":"2.0","id":2,"method":"tools/call","params":{"name":"fouine_search","arguments":{"query":"electrolyse","limit":3,"folder":"Livres","cursor":"\#(cursor)"}}}"#.utf8)))
        XCTAssertEqual(
            ((try JSONMatch.object(changed))["error"] as? [String: Any])?["code"]
                as? Int, -32602)
    }

    /// Les DÉFAUTS du schéma entrent dans l'empreinte, et c'est ce qui permet à
    /// un client d'omettre `limit` sur la première page puis sur la suivante :
    /// les arguments validés sont complétés avant que l'outil ne les voie, donc
    /// les deux empreintes coïncident.
    func testOmittingAnArgumentWithADefaultStillPaginates() throws {
        let index = try TempIndex(documents: 2, pagesPerDocument: 8)
        let server = try index.makeServer()

        let first = try XCTUnwrap(server.handle(Data(
            #"{"jsonrpc":"2.0","id":1,"method":"tools/call","params":{"name":"fouine_search","arguments":{"query":"electrolyse"}}}"#.utf8)))
        let cursor = try XCTUnwrap(
            (((try JSONMatch.object(first))["result"] as? [String: Any])?[
                "structuredContent"] as? [String: Any])?["next_cursor"] as? String)

        let second = try XCTUnwrap(server.handle(Data(
            #"{"jsonrpc":"2.0","id":2,"method":"tools/call","params":{"name":"fouine_search","arguments":{"query":"electrolyse","cursor":"\#(cursor)"}}}"#.utf8)))
        let object = try JSONMatch.object(second)
        XCTAssertNil(object["error"],
                     "un curseur doit survivre à l'omission d'un argument par défaut")
        let hits = ((object["result"] as? [String: Any])?["structuredContent"]
                     as? [String: Any])?["hits"] as? [[String: Any]]
        XCTAssertEqual(hits?.count, 6, "16 pages, 10 rendues, 6 restantes")
    }
}
