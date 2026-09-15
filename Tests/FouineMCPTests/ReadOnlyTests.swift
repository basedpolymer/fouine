// ReadOnlyTests.swift — la régression la plus grave possible. Propriété : A-MCP.
// SPDX-License-Identifier: LicenseRef-Fouine-Source-Available
//
// « Ce serveur n'écrit jamais » est la promesse centrale du palier 4 : c'est
// elle qui permet de le brancher sur la base d'un utilisateur pendant que
// l'agent y travaille. Une promesse de ce genre se TESTE, sinon ce n'est qu'une
// intention. Trois ceintures, trois tests.

import Foundation
import XCTest
import CryptoKit
import GRDB
import FouineCore
import FouineMCP
import FouineMCPKit

final class ReadOnlyTests: XCTestCase {

    /// Empreinte d'un fichier, ou `nil` s'il n'existe pas.
    private func digest(_ url: URL) -> String? {
        guard let data = try? Data(contentsOf: url) else { return nil }
        return SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }

    private func modificationDate(_ url: URL) -> Date? {
        (try? FileManager.default.attributesOfItem(atPath: url.path)[.modificationDate])
            as? Date
    }

    /// CEINTURE 1 — deux cents appels ne changent pas un octet.
    ///
    /// Le `.db` est comparé par empreinte SHA-256 ; le `-wal` par empreinte ET
    /// par date de modification. Seul `-shm` est exclu : c'est la mémoire
    /// partagée d'index du WAL, que SQLite fabrique à la première lecture et
    /// que le noyau efface à la fermeture de la dernière connexion — un
    /// lecteur, quel qu'il soit, la touche.
    func testTwoHundredCallsChangeNothingOnDisk() throws {
        let index = try TempIndex()
        let server = try index.makeServer()

        // Une première réponse AVANT l'instantané : elle inclut l'ouverture de
        // la connexion, la création éventuelle du `-shm`, et le premier remplissage
        // du cache. C'est APRÈS cela qu'on veut prouver l'immobilité.
        _ = server.handle(Data(
            #"{"jsonrpc":"2.0","id":0,"method":"tools/call","params":{"name":"fouine_status","arguments":{"include_agent":false}}}"#.utf8))

        let wal = URL(fileURLWithPath: index.databaseURL.path + "-wal")
        let dbBefore = digest(index.databaseURL)
        let walBefore = digest(wal)
        let walDateBefore = modificationDate(wal)
        XCTAssertNotNil(dbBefore)

        for id in 1...200 {
            let line = #"{"jsonrpc":"2.0","id":\#(id),"method":"tools/call","params":"#
                + #"{"name":"fouine_status","arguments":{"include_agent":false}}}"#
            let response = server.handle(Data(line.utf8))
            XCTAssertNotNil(response, "appel \(id) sans réponse")
            let object = try JSONMatch.object(response!)
            XCTAssertNil(object["error"], "appel \(id) en erreur : \(object)")
        }

        XCTAssertEqual(digest(index.databaseURL), dbBefore,
                       "le fichier .db a changé après 200 appels")
        XCTAssertEqual(digest(wal), walBefore, "le -wal a changé après 200 appels")
        XCTAssertEqual(modificationDate(wal), walDateBefore,
                       "le mtime du -wal a changé après 200 appels")
    }

    /// CEINTURE 1, ÉLARGIE — deux cents appels RÉPARTIS SUR LES CINQ OUTILS.
    ///
    /// Le test précédent ne parcourait qu'un seul chemin de code, celui de
    /// `fouine_status`. Depuis la PR 2 le serveur lit `page_fts`, `page_src`,
    /// `page_vec` et `docs`, il charge un index vectoriel en mémoire, il ouvre
    /// des curseurs de recherche — et FTS5 est une extension qui écrit dans ses
    /// propres tables d'ombre dès qu'on la laisse faire (`'optimize'`,
    /// `'merge'`, l'auto-merge). C'est cette classe-là qu'on écarte ici, et
    /// elle ne se voit d'aucune autre façon que par l'empreinte du fichier.
    func testTwoHundredCallsAcrossAllFiveToolsChangeNothingOnDisk() throws {
        let index = try TempIndex(documents: 5, pagesPerDocument: 8,
                                  vectorisedPages: 12, pageChars: 900,
                                  failedDocuments: 2, skippedDocuments: 1)
        let server = try index.makeServer()

        // Le répertoire de travail des outils : une première passe COMPLÈTE
        // avant l'instantané, pour que la création du `-shm`, le remplissage
        // des caches et la construction de l'index vectoriel soient derrière.
        let calls = [
            #"{"name":"fouine_status","arguments":{"include_agent":false}}"#,
            #"{"name":"fouine_search","arguments":{"query":"electrolyse","limit":5}}"#,
            #"{"name":"fouine_search","arguments":{"query":"enthalpie","mode":"hybrid"}}"#,
            #"{"name":"fouine_search","arguments":{"query":"chimique","folder":"Livres","snippet_chars":600}}"#,
            #"{"name":"fouine_read_page","arguments":{"doc_id":1,"page":3,"context_pages":2}}"#,
            #"{"name":"fouine_read_page","arguments":{"doc_id":2,"page":1,"max_chars":400,"offset":200}}"#,
            #"{"name":"fouine_similar_pages","arguments":{"doc_id":1,"page":1,"exclude_same_document":false}}"#,
            #"{"name":"fouine_similar_pages","arguments":{"doc_id":4,"page":2}}"#,
            #"{"name":"fouine_list_documents","arguments":{"state":"any","limit":100}}"#,
            #"{"name":"fouine_list_documents","arguments":{"state":"failed"}}"#,
        ]
        for (offset, call) in calls.enumerated() {
            _ = server.handle(Data(
                #"{"jsonrpc":"2.0","id":\#(offset),"method":"tools/call","params":\#(call)}"#.utf8))
        }

        let wal = URL(fileURLWithPath: index.databaseURL.path + "-wal")
        let dbBefore = digest(index.databaseURL)
        let walBefore = digest(wal)
        let walDateBefore = modificationDate(wal)
        XCTAssertNotNil(dbBefore)

        for id in 1...200 {
            let call = calls[id % calls.count]
            let response = server.handle(Data(
                #"{"jsonrpc":"2.0","id":\#(id),"method":"tools/call","params":\#(call)}"#.utf8))
            let object = try JSONMatch.object(try XCTUnwrap(response,
                                                            "appel \(id) sans réponse"))
            XCTAssertNil(object["error"], "appel \(id) en erreur : \(object)")
        }

        XCTAssertEqual(digest(index.databaseURL), dbBefore,
                       "le fichier .db a changé après 200 appels sur les cinq outils")
        XCTAssertEqual(digest(wal), walBefore, "le -wal a changé")
        XCTAssertEqual(modificationDate(wal), walDateBefore,
                       "le mtime du -wal a changé")
    }

    /// CEINTURE 1 bis — SQLite lui-même refuse, et c'est ce qui protège des
    /// écritures qu'on n'aurait pas vues.
    ///
    /// On passe DÉLIBÉRÉMENT sous `ReadOnlyStore` : le magasin du serveur
    /// n'expose aucune écriture (c'est la ceinture 2, vérifiée par le
    /// compilateur), il faut donc prendre le `GRDBStore` nu pour éprouver
    /// celle-ci.
    func testEveryWriteFailsWithSQLITEREADONLY() throws {
        let index = try TempIndex()
        let store = GRDBStore()
        try store.openReadOnly(at: index.databaseURL)

        // Écriture de réglage : ne prend même pas `fouine.lock`, donc rien ne
        // peut masquer le refus de SQLite.
        XCTAssertThrowsError(try store.writeSetting("mcp.test", "1")) { error in
            let message = String(describing: error).lowercased()
            XCTAssertTrue(message.contains("readonly") || message.contains("error 8"),
                          "attendu SQLITE_READONLY, obtenu : \(error)")
        }
        // Écriture d'indexation, qui passe par `writeLocked`.
        XCTAssertThrowsError(try store.setRootEnabled(id: 1, false))
        // Et rien n'est passé.
        XCTAssertNil(try store.settingsRows()["mcp.test"])
    }

    /// Ouvrir une base ABSENTE ne crée rien : `open(at:)` créerait le fichier et
    /// le migrerait, ce qui, pour un serveur MCP, reviendrait à fabriquer un
    /// index vide sur une faute de frappe de chemin.
    ///
    /// Depuis CM-07 le refus arrive à la première LECTURE et non plus à la
    /// construction — construire un `ReadOnlyStore` n'ouvre rien. Ce que le test
    /// vérifie ne change pas : la même phrase, et aucun fichier créé.
    func testOpeningAMissingDatabaseCreatesNothing() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("fouine-absent-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let missing = directory.appendingPathComponent("fouine.db")

        let store = ReadOnlyStore(path: missing)
        XCTAssertThrowsError(try store.stats()) { error in
            XCTAssertTrue(MCPText.describe(error).contains("no Fouine index"),
                          "message : \(MCPText.describe(error))")
        }
        XCTAssertFalse(FileManager.default.fileExists(atPath: missing.path),
                       "aucun fichier ne doit être créé")
    }

    /// Une base d'un AUTRE schéma est refusée à l'ouverture — jamais migrée.
    func testADifferentSchemaIsRefusedAtOpen() throws {
        let index = try TempIndex()
        try index.bumpSchemaVersion(to: Schema.version + 1)
        let store = ReadOnlyStore(path: index.databaseURL)
        XCTAssertThrowsError(try store.ensureOpen()) { error in
            XCTAssertTrue(
                MCPText.describe(error)
                    .contains("written by a newer version — update the fouine binary"),
                "message : \(MCPText.describe(error))")
        }
    }

    /// LE CAS QUI COMPTE VRAIMENT : la base change de version PENDANT que le
    /// serveur tourne (l'utilisateur met Fouine à jour, l'application migre).
    ///
    /// `tools/call` doit alors rendre `isError: true` avec le geste, et
    /// `initialize` / `tools/list` doivent CONTINUER de répondre : le client
    /// reste utilisable, et l'utilisateur lit pourquoi au lieu de voir un
    /// serveur muet.
    func testASchemaChangeUnderTheRunningServerFailsToolsButNotHandshake() throws {
        let index = try TempIndex()
        // TTL à zéro : la version est relue à chaque appel, au lieu d'attendre
        // les 60 s du régime normal.
        let server = try index.makeServer(schemaCacheTTL: 0)

        let before = server.handle(Data(
            #"{"jsonrpc":"2.0","id":1,"method":"tools/call","params":{"name":"fouine_status","arguments":{"include_agent":false}}}"#.utf8))
        XCTAssertNil(try JSONMatch.object(before!)["error"])

        try index.bumpSchemaVersion(to: Schema.version + 3)

        let after = try JSONMatch.object(server.handle(Data(
            #"{"jsonrpc":"2.0","id":2,"method":"tools/call","params":{"name":"fouine_status","arguments":{"include_agent":false}}}"#.utf8))!)
        XCTAssertNil(after["error"], "un désaccord de schéma est une erreur d'OUTIL")
        let result = after["result"] as? [String: Any]
        XCTAssertEqual(result?["isError"] as? Bool, true)
        XCTAssertNil(result?["structuredContent"],
                     "une erreur n'a pas de structuredContent : il doit valider outputSchema")
        let content = result?["content"] as? [[String: Any]]
        XCTAssertEqual(
            content?.first?["text"] as? String,
            "this Fouine index was written by a newer version — update the fouine binary")

        // La poignée de main et le catalogue répondent encore.
        let handshake = try JSONMatch.object(server.handle(Data(
            #"{"jsonrpc":"2.0","id":3,"method":"initialize","params":{"protocolVersion":"2025-06-18","capabilities":{}}}"#.utf8))!)
        XCTAssertNotNil(handshake["result"])
        let list = try JSONMatch.object(server.handle(Data(
            #"{"jsonrpc":"2.0","id":4,"method":"tools/list"}"#.utf8))!)
        XCTAssertNotNil((list["result"] as? [String: Any])?["tools"])
    }

    /// CEINTURE 3 — aucun outil d'écriture n'est déclaré. Le modèle ne peut donc
    /// pas en demander un. La liste est figée ici pour que l'ajout d'un
    /// `fouine_index` un jour de fatigue soit une décision, pas un accident.
    func testTheCatalogueExposesNoWritingTool() throws {
        let index = try TempIndex()
        let server = try index.makeServer()
        let response = try JSONMatch.object(server.handle(Data(
            #"{"jsonrpc":"2.0","id":1,"method":"tools/list"}"#.utf8))!)
        let tools = ((response["result"] as? [String: Any])?["tools"] as? [[String: Any]]) ?? []
        XCTAssertEqual(tools.compactMap { $0["name"] as? String },
                       ["fouine_status", "fouine_search", "fouine_read_page",
                        "fouine_similar_pages", "fouine_list_documents"])
    }

    /// Le serveur ne prend JAMAIS `fouine.lock` : la campagne d'embedding et
    /// l'agent continuent d'écrire pendant qu'il lit.
    func testTheServerNeverTakesTheWriteLock() throws {
        let index = try TempIndex()
        let server = try index.makeServer()
        for id in 1...5 {
            _ = server.handle(Data(
                #"{"jsonrpc":"2.0","id":\#(id),"method":"tools/call","params":{"name":"fouine_status","arguments":{"include_agent":false}}}"#.utf8))
        }
        // Un autre processus doit pouvoir prendre le verrou immédiatement.
        let writer = GRDBStore()
        try writer.open(at: index.databaseURL)
        defer { writer.releaseWriteLock() }
        XCTAssertNoThrow(try writer.acquireWriteLock(as: .cli))
    }

    /// Le cas réel du 03/09 : un `fouine ocr` d'un autre processus écrit dans la
    /// base pendant que le serveur la lit. Les lectures aboutissent — le WAL
    /// autorise les lecteurs concurrents — et `write_lock` NOMME le détenteur,
    /// ce qui est l'information dont un agent a besoin pour décider d'attendre.
    func testStatusReadsAndNamesTheHolderWhileAnotherProcessWrites() throws {
        let index = try TempIndex()
        let server = try index.makeServer()
        let writer = GRDBStore()
        try writer.open(at: index.databaseURL)
        try writer.acquireWriteLock(as: .agent)
        defer { writer.releaseWriteLock() }

        let response = try JSONMatch.object(server.handle(Data(
            #"{"jsonrpc":"2.0","id":1,"method":"tools/call","params":{"name":"fouine_status","arguments":{"include_agent":false}}}"#.utf8))!)
        XCTAssertNil(response["error"], "une lecture ne doit jamais buter sur le verrou")
        let payload = ((response["result"] as? [String: Any])?["structuredContent"]
                        as? [String: Any]) ?? [:]
        XCTAssertEqual(payload["pages_indexed"] as? Int, 6)
        let lock = payload["write_lock"] as? [String: Any]
        XCTAssertEqual(lock?["held"] as? Bool, true)
        XCTAssertEqual(lock?["role"] as? String, "agent")
        XCTAssertEqual(lock?["pid"] as? Int, Int(getpid()))
        XCTAssertNotNil(lock?["since"] as? String)

        // Et le verrou rendu se voit TOUT DE SUITE : `write_lock` est hors du
        // cache de 60 s, parce que c'est le champ sur lequel un agent décide
        // s'il doit réessayer.
        writer.releaseWriteLock()
        let after = try JSONMatch.object(server.handle(Data(
            #"{"jsonrpc":"2.0","id":2,"method":"tools/call","params":{"name":"fouine_status","arguments":{"include_agent":false}}}"#.utf8))!)
        let freed = (((after["result"] as? [String: Any])?["structuredContent"]
                       as? [String: Any])?["write_lock"] as? [String: Any])
        XCTAssertEqual(freed?["held"] as? Bool, false)
    }
}
