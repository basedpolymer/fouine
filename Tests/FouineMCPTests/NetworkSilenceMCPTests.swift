// NetworkSilenceMCPTests.swift — le serveur MCP n'ouvre AUCUNE connexion.
// SPDX-License-Identifier: LicenseRef-Fouine-Source-Available
//
// ═══ POURQUOI CE FICHIER, ET POURQUOI MAINTENANT ═══════════════════════════
//
// La PR 1 ne l'avait pas, et le disait : son seul outil ne chargeait rien et
// n'appelait rien. La PR 2 change cela — `SemanticEngine` charge un modèle
// CoreML, `EmbedPaths` regarde un répertoire que `ModelDownload` sait remplir
// depuis Hugging Face, et un outil de plus est un chemin de code de plus.
//
// La leçon de D2-03 vaut ici mot pour mot : une preuve STATIQUE
// (`grep 'URLSession\|https://' Sources/`) ne peut pas voir la faille qu'elle
// prétend exclure. La requête qui a été trouvée dans l'extraction `.doc` était
// émise par CFNetwork depuis AppKit, à partir d'une URL venue du DOCUMENT,
// jamais du code. Un serveur qui confie des chemins à CoreML et des textes à
// des importateurs système est dans la même position : il faut ÉCOUTER.
//
// ═══ CE QUE CE TEST FAIT ═══════════════════════════════════════════════════
//
// Un écouteur TCP sur 127.0.0.1 (le harnais de `FouineExtractTests`, recopié
// ici parce que les deux cibles de test ne partagent pas de code), une SÉANCE
// COMPLÈTE des cinq outils, une seconde laissée au réseau, et zéro acceptation
// affirmée.
//
// L'écouteur est vérifié par une contre-épreuve : sans elle, un écouteur cassé
// rendrait ce test vert pour de mauvaises raisons.
//
// RIEN NE SORT DE LA BOUCLE LOCALE : ce test ne contacte pas le réseau réel, et
// l'écouteur n'est joignable de nulle part ailleurs.

import Foundation
import XCTest
import FouineCore
import FouineMCP

// MARK: - L'écouteur

/// Écouteur TCP sur 127.0.0.1, port éphémère. Il ACCEPTE puis ferme, et note
/// chaque acceptation : c'est le seul fait qui compte — une balise a fonctionné
/// dès que la connexion a été établie, que la réponse arrive ou non.
private final class MCPLoopbackListener: @unchecked Sendable {
    private let socketFD: Int32
    private let mutex = NSLock()
    private var log: [String] = []
    private var closed = false

    let port: UInt16

    init() throws {
        let fd = socket(AF_INET, SOCK_STREAM, 0)
        guard fd >= 0 else {
            throw NSError(domain: "MCPLoopbackListener", code: Int(errno))
        }
        var yes: Int32 = 1
        setsockopt(fd, SOL_SOCKET, SO_REUSEADDR, &yes,
                   socklen_t(MemoryLayout<Int32>.size))

        var address = sockaddr_in()
        address.sin_family = sa_family_t(AF_INET)
        address.sin_port = 0                        // port éphémère
        address.sin_addr.s_addr = inet_addr("127.0.0.1")
        address.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)

        let bound = withUnsafePointer(to: &address) { pointer in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                Darwin.bind(fd, $0, socklen_t(MemoryLayout<sockaddr_in>.size))
            }
        }
        guard bound == 0, Darwin.listen(fd, 16) == 0 else {
            Darwin.close(fd)
            throw NSError(domain: "MCPLoopbackListener", code: Int(errno))
        }

        var actual = sockaddr_in()
        var length = socklen_t(MemoryLayout<sockaddr_in>.size)
        let named = withUnsafeMutablePointer(to: &actual) { pointer in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                getsockname(fd, $0, &length)
            }
        }
        guard named == 0 else {
            Darwin.close(fd)
            throw NSError(domain: "MCPLoopbackListener", code: Int(errno))
        }
        socketFD = fd
        port = UInt16(bigEndian: actual.sin_port)

        let sink: @Sendable (String) -> Void = { [weak self] line in
            self?.record(line)
        }
        Thread.detachNewThread {
            while true {
                let client = Darwin.accept(fd, nil, nil)
                if client < 0 { return }            // socket fermé : on sort
                sink("TCP-ACCEPT \(Date())")
                Darwin.close(client)
            }
        }
    }

    private func record(_ line: String) {
        mutex.lock(); log.append(line); mutex.unlock()
    }

    var connections: [String] {
        mutex.lock(); defer { mutex.unlock() }; return log
    }

    func stop() {
        mutex.lock()
        let already = closed
        closed = true
        mutex.unlock()
        if !already { Darwin.close(socketFD) }
    }

    deinit { stop() }
}

// MARK: - Le test

final class NetworkSilenceMCPTests: XCTestCase {

    /// La fenêtre de silence des deux tests ci-dessous. 0,3 s et non 1 s
    /// depuis le lot BT1 : `testTheListenerSeesRealTraffic` mesure ce que
    /// l'écouteur met à voir une connexion réelle et échoue si la marge fond.
    static let silenceWindow: TimeInterval = 0.3

    private var listener: MCPLoopbackListener!

    override func setUpWithError() throws {
        listener = try MCPLoopbackListener()
    }

    override func tearDownWithError() throws {
        listener?.stop()
        listener = nil
    }

    /// LA CONTRE-ÉPREUVE. Sans elle, un écouteur cassé rendrait le test suivant
    /// vert sans rien prouver du tout.
    func testTheListenerSeesRealTraffic() throws {
        let fd = socket(AF_INET, SOCK_STREAM, 0)
        defer { Darwin.close(fd) }
        var address = sockaddr_in()
        address.sin_family = sa_family_t(AF_INET)
        address.sin_port = listener.port.bigEndian
        address.sin_addr.s_addr = inet_addr("127.0.0.1")
        address.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
        let connected = withUnsafePointer(to: &address) { pointer in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                Darwin.connect(fd, $0, socklen_t(MemoryLayout<sockaddr_in>.size))
            }
        }
        XCTAssertEqual(connected, 0)
        // Preuve POSITIVE : on attend l'acceptation (quelques millisecondes sur
        // la boucle locale, 2 s de garde) au lieu de dormir une demi-seconde —
        // la fenêtre fixe n'a de sens que pour affirmer un SILENCE.
        let started = Date()
        let deadline = started.addingTimeInterval(2)
        while listener.connections.isEmpty, Date() < deadline {
            Thread.sleep(forTimeInterval: 0.005)
        }
        let latency = Date().timeIntervalSince(started)
        XCTAssertFalse(listener.connections.isEmpty,
                       "l'écouteur ne voit pas une connexion réelle : "
                       + "il ne prouve rien")
        // La garde de la fenêtre de silence (lot BT1) : les deux tests
        // suivants affirment un négatif au bout de `silenceWindow`, ce qui ne
        // vaut que si une connexion réelle se voit en un temps très inférieur.
        XCTAssertLessThan(latency, Self.silenceWindow / 6,
                          "l'écouteur a mis \(Int(latency * 1000)) ms à voir une "
                          + "connexion réelle : la fenêtre de silence n'a plus "
                          + "de marge, élargissez-la")
    }

    /// UNE SÉANCE COMPLÈTE DES CINQ OUTILS, sur une base qui porte des
    /// vecteurs — donc en passant par `SemanticEngine`, qui est le seul chemin
    /// de code du serveur qui touche au modèle.
    ///
    /// Les répertoires du modèle et du cache pointent sur des dossiers de test :
    /// aucun `fouine model download` n'est atteignable, et si un chemin de code
    /// décidait d'aller CHERCHER le modèle absent, il partirait vers le réseau —
    /// c'est précisément ce qu'on veut voir.
    func testAFullSessionOpensNoConnection() throws {
        let index = try TempIndex(documents: 3, pagesPerDocument: 4,
                                  vectorisedPages: 6, failedDocuments: 1)
        let server = try index.makeServer()

        let calls = [
            #"{"name":"fouine_status","arguments":{}}"#,
            #"{"name":"fouine_search","arguments":{"query":"electrolyse"}}"#,
            #"{"name":"fouine_search","arguments":{"query":"enthalpie","mode":"hybrid"}}"#,
            #"{"name":"fouine_read_page","arguments":{"doc_id":1,"page":2,"context_pages":2}}"#,
            #"{"name":"fouine_similar_pages","arguments":{"doc_id":1,"page":1,"exclude_same_document":false}}"#,
            #"{"name":"fouine_list_documents","arguments":{"state":"any"}}"#,
        ]
        _ = server.handle(Data(
            #"{"jsonrpc":"2.0","id":0,"method":"initialize","params":{"protocolVersion":"2025-06-18","capabilities":{}}}"#.utf8))
        for (offset, call) in calls.enumerated() {
            let response = server.handle(Data(
                #"{"jsonrpc":"2.0","id":\#(offset + 1),"method":"tools/call","params":\#(call)}"#.utf8))
            XCTAssertNotNil(response, "\(call) : aucune réponse")
        }

        // Une balise partie au moment de l'appel est acceptée en quelques
        // millisecondes sur la boucle locale ; la fenêtre garde un facteur
        // très large, et `testTheListenerSeesRealTraffic` le vérifie.
        Thread.sleep(forTimeInterval: Self.silenceWindow)
        let seen = listener.connections
        XCTAssertTrue(seen.isEmpty,
                      "séance complète des cinq outils : \(seen.count) connexion(s) "
                      + "acceptée(s) sur 127.0.0.1:\(listener.port) — \(seen)")
    }

    /// Et la même chose sur des ARGUMENTS HOSTILES : une requête qui ressemble à
    /// une URL, un fragment de chemin qui ressemble à un hôte. Le serveur ne
    /// résout rien, ne récupère rien, ne suit rien.
    func testHostileArgumentsOpenNoConnection() throws {
        let index = try TempIndex()
        let server = try index.makeServer()
        let hostile = "http://127.0.0.1:\(listener.port)/BALISE"
        let calls = [
            #"{"name":"fouine_search","arguments":{"query":"\#(hostile)"}}"#,
            #"{"name":"fouine_list_documents","arguments":{"path_contains":"\#(hostile)"}}"#,
            #"{"name":"fouine_search","arguments":{"query":"electrolyse","folder":"\#(hostile)"}}"#,
        ]
        for (offset, call) in calls.enumerated() {
            _ = server.handle(Data(
                #"{"jsonrpc":"2.0","id":\#(offset),"method":"tools/call","params":\#(call)}"#.utf8))
        }
        Thread.sleep(forTimeInterval: Self.silenceWindow)
        XCTAssertTrue(listener.connections.isEmpty,
                      "un argument qui ressemble à une URL ne doit rien déclencher : "
                      + "\(listener.connections)")
    }
}
