// ScopeTests.swift — `fouine mcp --folders` : ce que le serveur sert, et ce
// qu'il ne sait même pas nommer. Propriété : A-MCP. Lot IG1, constat PM-01.
// SPDX-License-Identifier: LicenseRef-Fouine-Source-Available
//
// Le périmètre s'applique dans `ReadOnlyStore`, point unique des lectures. Les
// tests l'éprouvent donc PAR LES OUTILS, à travers le serveur : c'est la seule
// façon de prouver qu'un outil qui ne sait rien du périmètre — aucun ne le
// sait — n'en laisse rien passer. Un document hors périmètre doit être INCONNU
// au même titre qu'un `doc_id` qui n'existe pas : « il existe mais vous n'y
// avez pas droit » apprendrait au modèle ce que l'utilisateur cache.

import Foundation
import XCTest
import GRDB
import FouineCore
import FouineMCP
import FouineMCPKit

final class ScopeTests: XCTestCase {

    /// Une base à TROIS racines — `Livres`, `M2SU`, `Personnel` —, comme celle
    /// du propriétaire. `TempIndex` n'en fabrique qu'une : ici il faut des
    /// documents DES DEUX CÔTÉS de la frontière.
    final class ScopedIndex {
        let directory: URL
        let databaseURL: URL
        /// Un document par racine, dans l'ordre des étiquettes.
        private(set) var docIDs: [String: Int64] = [:]

        init(folders: [String] = ["Livres", "M2SU", "Personnel"],
             documentsPerFolder: Int = 2) throws {
            directory = FileManager.default.temporaryDirectory
                .appendingPathComponent("fouine-scope-\(UUID().uuidString)",
                                        isDirectory: true)
            try FileManager.default.createDirectory(at: directory,
                                                    withIntermediateDirectories: true)
            databaseURL = directory.appendingPathComponent("fouine.db")
            let store = GRDBStore()
            try store.open(at: databaseURL)
            for label in folders {
                for index in 1...documentsPerFolder {
                    let id = try store.upsertDoc(DocRecord(
                        volUUID: "TEST-VOL",
                        relPath: "Users/essai/\(label)/document-\(index).pdf",
                        ext: "pdf", topFolder: label,
                        size: Int64(1_000 * index), mtime: 1_700_000_000))
                    try store.setPageCount(id, 2)
                    try store.replacePages(docID: id, pages: (1...2).map {
                        PageText(page: $0,
                                 text: "electrolyse enthalpie page \($0) de \(label)",
                                 source: .native)
                    })
                    try store.setDocState(id, .extracted, err: nil)
                    if index == 1 { docIDs[label] = id }
                }
            }
            store.releaseWriteLock()
            // Racines par SQL direct, comme `TempIndex` : `addRoot` sonde un
            // volume réel, qu'une suite unitaire n'a pas à fournir.
            let queue = try DatabaseQueue(path: databaseURL.path)
            try queue.write { db in
                try db.execute(sql: """
                    INSERT INTO volumes(uuid, label, last_seen, fsevent_id)
                    VALUES ('TEST-VOL', 'Test', 0, 0)
                    ON CONFLICT(uuid) DO NOTHING
                    """)
                for label in folders {
                    try db.execute(sql: """
                        INSERT INTO roots(vol_uuid, rel_path, label, enabled)
                        VALUES ('TEST-VOL', ?, ?, 1)
                        """, arguments: ["Users/essai/\(label)", label])
                }
            }
        }

        deinit { try? FileManager.default.removeItem(at: directory) }

        func makeServer(folders: [String]?) -> MCPServer {
            let model = directory.appendingPathComponent("no-model", isDirectory: true)
            return MCPServer(
                options: .init(databaseURL: databaseURL, logLevel: .quiet,
                               folders: folders),
                version: "1.0.0-test",
                makeSemanticEngine: { SemanticEngine(store: $0, modelDirectory: model) },
                makeStatusTool: { store, semantic in
                    StatusTool(store: store, semantic: semantic, modelDirectory: model,
                               launchdProbe: { .notRegistered })
                })
        }
    }

    // MARK: - Appel d'outil

    private func call(_ tool: String, _ arguments: [String: Any],
                      on server: MCPServer) throws -> [String: Any] {
        let params = try JSONSerialization.data(
            withJSONObject: ["name": tool, "arguments": arguments])
        let line = #"{"jsonrpc":"2.0","id":1,"method":"tools/call","params":"#
            + String(decoding: params, as: UTF8.self) + "}"
        let response = try JSONMatch.object(XCTUnwrap(server.handle(Data(line.utf8))))
        XCTAssertNil(response["error"], "un refus ne casse pas la session JSON-RPC")
        return try XCTUnwrap(response["result"] as? [String: Any])
    }

    private func text(_ result: [String: Any]) -> String {
        ((result["content"] as? [[String: Any]])?.first?["text"] as? String) ?? ""
    }

    private func structured(_ result: [String: Any]) throws -> [String: Any] {
        try XCTUnwrap(result["structuredContent"] as? [String: Any]
                      ?? (try? JSONMatch.object(Data(text(result).utf8))))
    }

    // MARK: - Les racines

    func testStatusOnlyListsTheServedRoots() throws {
        let index = try ScopedIndex()
        let result = try call("fouine_status", [:],
                              on: index.makeServer(folders: ["Livres", "M2SU"]))
        let payload = try structured(result)
        let labels = (payload["roots"] as? [[String: Any]])?
            .compactMap { $0["label"] as? String }.sorted()
        XCTAssertEqual(labels, ["Livres", "M2SU"])
    }

    /// La clé est TOUJOURS là : `null` sans périmètre, l'objet sinon. Une clé
    /// absente n'apprend rien à un agent qui ne trouve pas un document.
    func testStatusPublishesTheScope() throws {
        let index = try ScopedIndex()
        let whole = try structured(try call("fouine_status", [:],
                                            on: index.makeServer(folders: nil)))
        XCTAssertTrue(whole["scope"] is NSNull, String(describing: whole["scope"]))
        XCTAssertEqual(whole["documents"] as? Int, 6)

        let scoped = try structured(try call("fouine_status", [:],
                                             on: index.makeServer(folders: ["Livres"])))
        let scope = try XCTUnwrap(scoped["scope"] as? [String: Any])
        XCTAssertEqual(scope["folders"] as? [String], ["Livres"])
        // `documents` compte DANS le périmètre — annoncer six documents quand
        // on n'en sert que deux ferait conclure au modèle qu'il a mal cherché.
        XCTAssertEqual(scoped["documents"] as? Int, 2)
        // `pages_indexed` reste celui de tout l'index, et la note le dit.
        XCTAssertEqual(scoped["pages_indexed"] as? Int, 12)
        XCTAssertTrue((scope["note"] as? String ?? "").contains("pages_indexed"),
                      String(describing: scope["note"]))
    }

    /// L'étiquette est canonisée comme partout ailleurs (`FolderCheck`) : une
    /// différence de casse dans une configuration de client ne doit pas rendre
    /// un serveur qui ne sert rien.
    func testScopeLabelsAreCaseInsensitive() throws {
        let index = try ScopedIndex()
        let payload = try structured(try call("fouine_status", [:],
                                              on: index.makeServer(folders: ["livres"])))
        let scope = try XCTUnwrap(payload["scope"] as? [String: Any])
        XCTAssertEqual(scope["folders"] as? [String], ["Livres"])
    }

    // MARK: - La recherche

    func testSearchNeverReturnsAPageFromOutsideTheScope() throws {
        let index = try ScopedIndex()
        let server = index.makeServer(folders: ["Livres"])
        let payload = try structured(try call("fouine_search",
                                              ["query": "electrolyse", "limit": 50],
                                              on: server))
        let folders = (payload["hits"] as? [[String: Any]])?
            .compactMap { $0["folder"] as? String }
        XCTAssertFalse(folders?.isEmpty ?? true, "la recherche doit rendre des pages")
        XCTAssertEqual(Set(folders ?? []), ["Livres"])
    }

    /// Un `folder` hors périmètre est refusé avec la phrase de `FolderCheck`,
    /// qui ne nomme QUE les racines servies : pour le modèle, `Personnel`
    /// n'existe pas.
    func testAnOutOfScopeFolderIsRefusedNamingOnlyTheServedRoots() throws {
        let index = try ScopedIndex()
        let server = index.makeServer(folders: ["Livres"])
        let result = try call("fouine_search",
                              ["query": "electrolyse", "folder": "Personnel"],
                              on: server)
        XCTAssertEqual(result["isError"] as? Bool, true, "\(result)")
        let message = text(result)
        XCTAssertTrue(message.contains("Personnel"), message)
        XCTAssertTrue(message.contains("Livres"), message)
        XCTAssertFalse(message.contains("M2SU"), message)
    }

    /// Une LANGUE hors périmètre est refusée comme un dossier hors périmètre,
    /// et le refus ne nomme que les langues SERVIES (lot MN1, reste d'IG1).
    ///
    /// Avant : `knownLanguages()` lisait tout l'index, donc `lang: "de"` —
    /// présent dans le seul `Personnel` — passait la garde et rendait zéro
    /// page, sans un mot. Ça ne rendait aucun document, mais ça apprenait au
    /// modèle qu'il y a de l'allemand derrière le périmètre.
    func testAnOutOfScopeLanguageIsRefusedNamingOnlyTheServedOnes() throws {
        let index = try ScopedIndex()
        let store = GRDBStore()
        try store.open(at: index.databaseURL)
        try store.setDocLanguage(try XCTUnwrap(index.docIDs["Livres"]), "fr")
        try store.setDocLanguage(try XCTUnwrap(index.docIDs["Personnel"]), "de")
        store.releaseWriteLock()

        let result = try call("fouine_search",
                              ["query": "electrolyse", "lang": "de"],
                              on: index.makeServer(folders: ["Livres"]))
        XCTAssertEqual(result["isError"] as? Bool, true, "\(result)")
        let message = text(result)
        let announced = message.components(separatedBy: "languages in this index: ")
        XCTAssertEqual(announced.count, 2, message)
        XCTAssertEqual(announced.last, "fr",
                       "seules les langues du périmètre se nomment : " + message)
        // Et la langue servie, elle, passe.
        let served = try structured(try call("fouine_search",
                                             ["query": "electrolyse", "lang": "fr"],
                                             on: index.makeServer(folders: ["Livres"])))
        XCTAssertFalse((served["hits"] as? [[String: Any]] ?? []).isEmpty,
                       String(describing: served["hits"]))
    }

    // MARK: - Les documents

    func testReadingAnOutOfScopeDocumentIsTheSameRefusalAsAnUnknownOne() throws {
        let index = try ScopedIndex()
        let server = index.makeServer(folders: ["Livres"])
        let hidden = try XCTUnwrap(index.docIDs["Personnel"])
        let outOfScope = try call("fouine_read_page",
                                  ["doc_id": Int(hidden), "page": 1], on: server)
        let missing = try call("fouine_read_page",
                               ["doc_id": 9_999, "page": 1], on: server)
        XCTAssertEqual(outOfScope["isError"] as? Bool, true, "\(outOfScope)")
        // MOT POUR MOT le refus d'un identifiant inexistant, au numéro près :
        // le modèle ne doit pas pouvoir distinguer les deux cas.
        XCTAssertEqual(text(outOfScope).replacingOccurrences(of: "\(hidden)", with: "N"),
                       text(missing).replacingOccurrences(of: "9999", with: "N"))
    }

    func testListDocumentsOnlyShowsTheScopeAndCountsIt() throws {
        let index = try ScopedIndex()
        let server = index.makeServer(folders: ["Livres", "M2SU"])
        let payload = try structured(try call("fouine_list_documents",
                                              ["limit": 50], on: server))
        let folders = (payload["documents"] as? [[String: Any]])?
            .compactMap { $0["folder"] as? String }
        XCTAssertEqual(Set(folders ?? []), ["Livres", "M2SU"])
        XCTAssertEqual(payload["total"] as? Int, 4)
    }

    /// La fusion de plusieurs racines doit rendre l'ordre TOTAL de SQLite, et
    /// une pagination qui ne saute ni ne double de ligne. C'est ce que
    /// `ReadOnlyStore.before(_:)` recopie de `DocumentOrder.sql`.
    func testPaginationAcrossSeveralServedRootsLosesNoLine() throws {
        let index = try ScopedIndex(documentsPerFolder: 3)
        let server = index.makeServer(folders: ["Livres", "M2SU"])
        var seen: [String] = []
        var arguments: [String: Any] = ["limit": 2]
        for _ in 0..<3 {
            let payload = try structured(try call("fouine_list_documents",
                                                  arguments, on: server))
            seen += (payload["documents"] as? [[String: Any]])?
                .compactMap { $0["path"] as? String } ?? []
            guard let next = payload["next_cursor"] as? String else { break }
            arguments = ["limit": 2, "cursor": next]
        }
        XCTAssertEqual(seen.count, 6)
        XCTAssertEqual(Set(seen).count, 6, "aucune ligne doublée : \(seen)")
        XCTAssertEqual(seen, seen.sorted(), "l'ordre `path` doit être total")
        XCTAssertFalse(seen.contains { $0.contains("/Personnel/") }, "\(seen)")
    }

    // MARK: - Une étiquette qui ne nomme rien

    /// Le serveur DÉMARRE (ouverture paresseuse), et chaque outil répond une
    /// erreur d'outil qui nomme les racines existantes. Un processus qui meurt
    /// ne montre au client que « serveur déconnecté » (CM-07).
    func testAnUnknownScopeRefusesEveryToolWithoutKillingTheServer() throws {
        let index = try ScopedIndex()
        let server = index.makeServer(folders: ["Livre"])
        for tool in ["fouine_status", "fouine_list_documents"] {
            let result = try call(tool, [:], on: server)
            XCTAssertEqual(result["isError"] as? Bool, true, "\(tool) : \(result)")
            let message = text(result)
            XCTAssertTrue(message.contains("Livre"), message)
            XCTAssertTrue(message.contains("Livres"), message)
        }
        // `tools/list` continue de répondre : le client reste utilisable.
        let list = try JSONMatch.object(XCTUnwrap(server.handle(Data(
            #"{"jsonrpc":"2.0","id":2,"method":"tools/list"}"#.utf8))))
        XCTAssertNil(list["error"])
    }

    // MARK: - Ce qui est écrit dans les configurations de clients

    /// `--folders` doit survivre au redémarrage du client, qui relance le
    /// serveur avec la ligne qu'on lui a écrite.
    func testTheScopeIsWrittenIntoTheClientArguments() {
        XCTAssertEqual(MCPClientConfigurator.serverArgs(folders: []),
                       ["mcp", "--stdio"])
        XCTAssertEqual(MCPClientConfigurator.serverArgs(folders: ["Livres", "M2SU"]),
                       ["mcp", "--stdio", "--folders", "Livres,M2SU"])
    }

    /// Et une réinstallation SANS `--folders` — la mise à jour de
    /// l'application, le chemin du binaire qui change — ne doit pas rouvrir en
    /// grand un serveur que l'utilisateur avait restreint.
    func testAnExistingScopeIsReadBackAndKept() {
        XCTAssertEqual(
            MCPClientConfigurator.folders(
                inArgs: ["mcp", "--stdio", "--folders", "Livres, M2SU"]),
            ["Livres", "M2SU"])
        XCTAssertNil(MCPClientConfigurator.folders(inArgs: ["mcp", "--stdio"]))
        XCTAssertNil(MCPClientConfigurator.folders(inArgs: ["mcp", "--folders"]))
    }
}
