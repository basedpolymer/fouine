// SearchHonestyTests.swift — trois faits que la réponse portait sans les dire
// (lot MC2) : le quorum dans `why`, `fuzzy_expanded`, et le canal des noms
// soumis aux filtres.
// SPDX-License-Identifier: LicenseRef-Fouine-Source-Available
//
// Le point commun des trois constats : la réponse était PLAUSIBLE et fausse.
// `why: {kind: "exact", terms_found: [neuf mots]}` sur une page qui en porte
// trois (PM-14) ; onze pages d'orthographes approchées sans un mot (PM-13) ;
// cinq PDF dans `name_matches` d'une requête qui ne voulait que des
// transcriptions (PM-26).

import Foundation
import XCTest
import GRDB
import FouineCore
import FouineMCPKit
@testable import FouineMCP

final class SearchHonestyTests: XCTestCase {

    private func payload(_ index: TempIndex, _ arguments: String) throws
        -> [String: Any] {
        let server = try index.makeServer()
        let response = try XCTUnwrap(server.handle(Data(
            #"{"jsonrpc":"2.0","id":1,"method":"tools/call","params":{"name":"fouine_search","arguments":\#(arguments)}}"#.utf8)))
        let object = try JSONMatch.object(response)
        XCTAssertNil(object["error"], "\(object)")
        return try XCTUnwrap((object["result"] as? [String: Any])?["structuredContent"]
            as? [String: Any])
    }

    // MARK: - Le quorum, et ce que `why` a le droit de dire (PM-14)

    /// Aucune page ne porte les quatre mots ; le quorum en rend qui en portent
    /// la plupart. `why` doit alors dire `partial` avec ce que l'extrait
    /// montre — et surtout pas `exact` avec les quatre.
    func testUnHitDeQuorumNAnnoncePlusExact() throws {
        let index = try TempIndex(pageChars: 200)
        let payload = try payload(index,
            #"{"query":"electrolyse enthalpie chimique introuvable","limit":5}"#)
        XCTAssertEqual(payload["quorum"] as? Bool, true,
                       "moins de dix pages portent tous les mots")
        let hits = try XCTUnwrap(payload["hits"] as? [[String: Any]])
        XCTAssertFalse(hits.isEmpty)
        for hit in hits {
            let why = try XCTUnwrap(hit["why"] as? [String: Any])
            XCTAssertEqual(why["kind"] as? String, "partial", "\(why)")
            XCTAssertNil(why["terms_missing"],
                         "un extrait ne prouve aucune absence")
            let found = try XCTUnwrap(why["terms_found"] as? [String])
            XCTAssertFalse(found.contains("introuvable"),
                           "le mot n'est nulle part : \(found)")
        }
        let note = try XCTUnwrap(payload["note"] as? String)
        XCTAssertTrue(note.contains(SearchAdvice.quorum), note)
    }

    // MARK: - `fuzzy_expanded` (PM-13)

    /// La clé est TOUJOURS là, comme `quorum` et `name_matches` : « aucune
    /// orthographe approchée » est une information, une clé absente n'en est
    /// pas une.
    func testLaCleEstLaMemeQuandRienNEstApproche() throws {
        let payload = try payload(try TempIndex(), #"{"query":"electrolyse"}"#)
        XCTAssertEqual(payload["fuzzy_expanded"] as? Bool, false)
    }

    func testUneOrthographeApprocheeEstAnnonceeEtExpliquee() throws {
        let index = try TempIndex(documents: 1, pagesPerDocument: 1)
        let store = GRDBStore()
        try store.open(at: index.databaseURL)
        try TrigramExpander(store: store).warm()
        store.releaseWriteLock()

        let payload = try payload(index, #"{"query":"electrolyze","limit":5}"#)
        XCTAssertEqual(payload["fuzzy_expanded"] as? Bool, true)
        let hits = try XCTUnwrap(payload["hits"] as? [[String: Any]])
        XCTAssertEqual(hits.first?["fuzzy_distance"] as? Int, 1)
        let why = try XCTUnwrap(hits.first?["why"] as? [String: Any])
        XCTAssertEqual(why["kind"] as? String, "fuzzy")
        XCTAssertEqual(why["found"] as? String, "electrolyse")
    }

    // MARK: - Le canal des noms sous filtre (PM-26)

    func testLeCanalDesNomsObeitAuFiltreDeProvenance() throws {
        let index = try TempIndex(documents: 1, pagesPerDocument: 1)
        let store = GRDBStore()
        try store.open(at: index.databaseURL)
        let video = try store.upsertDoc(DocRecord(
            volUUID: "TEST-VOL", relPath: "Users/essai/M2SU/document filme.mp4",
            ext: "mp4", topFolder: "M2SU", size: 500, mtime: 1_700_000_000))
        try store.setPageCount(video, 1)
        try store.replacePages(docID: video, pages: [
            PageText(page: 1, text: "[00:01] electrolyse expliquee en video",
                     source: .transcript),
        ])
        try store.setDocState(video, .extracted, err: nil)
        store.releaseWriteLock()

        let tout = try payload(index, #"{"query":"document","limit":5}"#)
        XCTAssertEqual(Set((tout["name_matches"] as? [[String: Any]] ?? [])
            .compactMap { $0["doc_id"] as? Int64 }), [1, video])

        let transcrit = try payload(index,
            #"{"query":"document","limit":5,"source":"transcript"}"#)
        XCTAssertEqual((transcrit["name_matches"] as? [[String: Any]] ?? [])
            .compactMap { $0["doc_id"] as? Int64 }, [video],
            "un PDF n'a pas une seule page de parole : il ne répond pas à une "
            + "requête qui n'en veut que")
    }

    func testLeCanalDesNomsObeitAussiALaDate() throws {
        let index = try TempIndex(documents: 1, pagesPerDocument: 1)
        let payload = try payload(index,
            #"{"query":"document","limit":5,"since":"2030-01-01"}"#)
        XCTAssertEqual((payload["name_matches"] as? [[String: Any]])?.count, 0)
    }
}
