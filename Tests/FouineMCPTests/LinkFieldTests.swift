// LinkFieldTests.swift — le champ `link` des quatre outils (lot INT-L1).
// SPDX-License-Identifier: LicenseRef-Fouine-Source-Available
//
// Les transcriptions golden figent le lien sur la base jetable, dont le volume
// « TEST-VOL » n'est pas monté : elles ne montrent donc QUE la forme de repli.
// Ce fichier éprouve ce qu'elles ne peuvent pas montrer — la forme CANONIQUE,
// par chemin absolu, celle qui survit à une réindexation — et le fait que ce
// que les quatre outils rendent se RELIT en un lien Fouine valide.

import XCTest
import FouineCore
@testable import FouineMCP

final class LinkFieldTests: XCTestCase {

    // MARK: - Les deux formes, au point unique qui les choisit

    private func row(_ id: Int64, volUUID: String) -> DocRow {
        DocRow(id: id, record: DocRecord(
            volUUID: volUUID, relPath: "Users/essai/Livres/document.pdf",
            ext: "pdf", topFolder: "Livres", size: 1_000, mtime: 1_700_000_000))
    }

    func testTheLinkUsesTheAbsolutePathWhenTheVolumeIsMounted() throws {
        // Le volume de la machine qui rejoue les tests : le seul moyen
        // d'obtenir un `abs_path` non nul sans monter quoi que ce soit.
        let volumes = VolumeResolver.mountedVolumes()
        guard let mounted = volumes.first(where: { $0.mountPoint.path == "/" })
                ?? volumes.first else {
            throw XCTSkip("aucun volume monté : rien à résoudre")
        }
        let fields = ToolSupport.pageFields(row(7, volUUID: mounted.uuid),
                                            docID: 7, page: 42)
        let link = try XCTUnwrap(fields["link"] as? String)
        XCTAssertTrue(link.hasPrefix("fouine://open?path="), link)
        XCTAssertTrue(link.hasSuffix("&page=42"), link)
        // Et il désigne le MÊME fichier que `abs_path` : deux champs de la même
        // ligne qui montreraient deux documents seraient pires qu'un seul.
        let absolute = try XCTUnwrap(fields["abs_path"] as? String)
        let read = try XCTUnwrap(DeepLink(url: try XCTUnwrap(URL(string: link))))
        XCTAssertEqual(read, .open(target: .path(absolute), page: 42, query: nil))
    }

    func testTheLinkFallsBackToTheDocumentWhenTheVolumeIsAway() throws {
        // Disque externe débranché : `abs_path` est nul, et taire le lien
        // serait pire que d'en donner un qui vaut sur cette machine.
        let fields = ToolSupport.pageFields(row(7, volUUID: "TEST-VOL"),
                                            docID: 7, page: 42)
        XCTAssertTrue(fields["abs_path"] is NSNull)
        XCTAssertEqual(fields["link"] as? String, "fouine://open?doc=7&page=42")
    }

    /// Le document a disparu de `docs` entre la recherche et l'habillage : il
    /// reste l'identifiant, et le lien le dit.
    func testAMissingDocumentRowStillProducesADocumentLink() {
        let fields = ToolSupport.pageFields(nil, docID: 9, page: 3)
        XCTAssertEqual(fields["link"] as? String, "fouine://open?doc=9&page=3")
    }

    /// `fouine_list_documents` cite un DOCUMENT, pas une page : un lien qui
    /// prétendrait à la page 1 mentirait sur ce qui a été trouvé.
    func testADocumentListingLinksWithoutAPage() {
        XCTAssertEqual(ToolSupport.link(absolutePath: nil, docID: 4, page: nil),
                       "fouine://open?doc=4")
    }

    // MARK: - Les quatre outils le portent

    func testEveryHitOfASearchCarriesAReadableLink() throws {
        let hits = try XCTUnwrap(
            call("fouine_search", ["query": "electrolyse", "limit": 3])["hits"]
                as? [[String: Any]])
        XCTAssertFalse(hits.isEmpty)
        for hit in hits {
            let page = try XCTUnwrap(hit["page"] as? Int)
            let docID = try XCTUnwrap(hit["doc_id"] as? Int)
            XCTAssertEqual(try readable(hit["link"]),
                           .open(target: .doc(Int64(docID)), page: page, query: nil))
        }
    }

    func testReadPageCarriesALinkForThePageAndItsContext() throws {
        let payload = call("fouine_read_page",
                           ["doc_id": 1, "page": 2, "context_pages": 1])
        XCTAssertEqual(payload["link"] as? String, "fouine://open?doc=1&page=2")
        let context = try XCTUnwrap(payload["context"] as? [[String: Any]])
        XCTAssertEqual(context.compactMap { $0["link"] as? String },
                       ["fouine://open?doc=1&page=1", "fouine://open?doc=1&page=3"])
    }

    func testSimilarPagesCarriesALinkOnEveryNeighbour() throws {
        let payload = call("fouine_similar_pages",
                           ["doc_id": 1, "page": 1,
                            "exclude_same_document": false],
                           index: try TempIndex(vectorisedPages: 2))
        let neighbours = try XCTUnwrap(payload["neighbours"] as? [[String: Any]])
        XCTAssertFalse(neighbours.isEmpty)
        for neighbour in neighbours {
            let page = try XCTUnwrap(neighbour["page"] as? Int)
            XCTAssertEqual(try readable(neighbour["link"]),
                           .open(target: .doc(1), page: page, query: nil))
        }
    }

    func testListDocumentsCarriesALinkWithoutAPage() throws {
        let payload = call("fouine_list_documents", [:])
        let documents = try XCTUnwrap(payload["documents"] as? [[String: Any]])
        XCTAssertEqual(documents.compactMap { $0["link"] as? String },
                       ["fouine://open?doc=1", "fouine://open?doc=2"])
    }

    // MARK: - Plomberie

    /// Un appel d'outil par le VRAI chemin (JSON-RPC), comme les transcriptions :
    /// c'est la seule façon de prouver que le champ sort de l'enveloppe.
    private func call(_ tool: String, _ arguments: [String: Any],
                      index: TempIndex? = nil,
                      file: StaticString = #filePath,
                      line: UInt = #line) -> [String: Any] {
        do {
            let index = try index ?? TempIndex()
            let server = try index.makeServer()
            _ = server.handle(Data("""
                {"jsonrpc":"2.0","id":1,"method":"initialize",\
                "params":{"protocolVersion":"2025-06-18","capabilities":{}}}
                """.utf8))
            let request: [String: Any] = [
                "jsonrpc": "2.0", "id": 2, "method": "tools/call",
                "params": ["name": tool, "arguments": arguments],
            ]
            let raw = try XCTUnwrap(
                server.handle(try JSONSerialization.data(withJSONObject: request)),
                file: file, line: line)
            let result = try XCTUnwrap(
                try JSONMatch.object(raw)["result"] as? [String: Any],
                file: file, line: line)
            return try XCTUnwrap(result["structuredContent"] as? [String: Any],
                                 file: file, line: line)
        } catch {
            XCTFail("\(tool) : \(error)", file: file, line: line)
            return [:]
        }
    }

    /// Le lien rendu, RELU. C'est ce qui compte : une chaîne bien formée que
    /// `DeepLink` refuserait n'ouvrirait rien du tout.
    private func readable(_ value: Any?) throws -> DeepLink {
        let text = try XCTUnwrap(value as? String)
        return try XCTUnwrap(DeepLink(url: try XCTUnwrap(URL(string: text))))
    }
}
