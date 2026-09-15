// FramingTests.swift — le cadrage stdio, et rien d'autre. Propriété : A-MCP.
// SPDX-License-Identifier: LicenseRef-Fouine-Source-Available
//
// CE QUE CES TESTS EMPÊCHENT : le lecteur de lignes naïf. `readLine()` sur
// `stdin` passe les trois premiers cas et échoue sur le quatrième ; un lecteur
// qui découpe sur `\n` sans gérer l'EOF laisse un processus orphelin dans la
// liste de l'utilisateur.

import Foundation
import XCTest
import FouineMCPKit

final class FramingTests: XCTestCase {

    /// Un routeur sans base : le cadrage ne dépend d'aucun outil.
    private func makeRouter() -> Router {
        Router(registry: ToolRegistry([]),
               serverInfo: .init(name: "fouine", title: "Fouine", version: "test"))
    }

    /// Fait tourner la boucle sur `input` et rend les lignes écrites.
    ///
    /// DES FICHIERS, PAS DES TUBES, et c'est délibéré : un tube a un tampon de
    /// 64 Kio, et écrire 2 Mio dedans avant de démarrer la boucle bloquerait le
    /// test pour toujours. Deux fichiers temporaires donnent le même EOF, la
    /// même sémantique de `read()`, et aucun ordonnancement à surveiller.
    private func serve(_ input: Data, maxLineBytes: Int = 16 << 20) throws -> [Data] {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("fouine-framing-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }

        let inputURL = directory.appendingPathComponent("in.jsonl")
        let outputURL = directory.appendingPathComponent("out.jsonl")
        try input.write(to: inputURL)
        FileManager.default.createFile(atPath: outputURL.path, contents: nil)

        let reader = try FileHandle(forReadingFrom: inputURL)
        let writer = try FileHandle(forWritingTo: outputURL)
        makeRouter().serve(on: LineTransport(input: reader.fileDescriptor,
                                             output: writer.fileDescriptor,
                                             maxLineBytes: maxLineBytes))
        try writer.close()
        try reader.close()

        let out = try Data(contentsOf: outputURL)
        return out.split(whereSeparator: { $0 == 0x0A }).map { Data($0) }
    }

    /// Une ligne de 2 Mio doit PASSER. C'est la taille que D2 § 5.7 retient, et
    /// elle n'a rien de théorique : un `tools/call` qui repasse un extrait long
    /// en argument y arrive vite.
    func testATwoMebibyteLineIsAccepted() throws {
        let padding = String(repeating: "a", count: 2 * 1024 * 1024)
        let line = #"{"jsonrpc":"2.0","id":1,"method":"tools/call","params":"#
            + #"{"name":"absent","arguments":{"q":"\#(padding)"}}}"#
        XCTAssertGreaterThan(line.utf8.count, 2 * 1024 * 1024)

        let responses = try serve(Data((line + "\n").utf8))
        XCTAssertEqual(responses.count, 1, "une ligne, une réponse")
        let object = try JSONMatch.object(responses[0])
        // L'outil n'existe pas : -32602. Ce qui compte ici est que la ligne ait
        // été LUE ENTIÈRE et analysée, pas la nature de l'erreur.
        let error = object["error"] as? [String: Any]
        XCTAssertEqual(error?["code"] as? Int, -32602)
    }

    /// Une ligne vide est ignorée EN SILENCE. Un client qui envoie `\n\n` entre
    /// deux messages — cela arrive — ne doit pas recevoir d'erreur : elle
    /// porterait `id: null` et polluerait son journal sans rien signaler.
    func testBlankLinesAreIgnored() throws {
        let input = "\n   \n"
            + #"{"jsonrpc":"2.0","id":1,"method":"ping"}"# + "\n\n"
        let responses = try serve(Data(input.utf8))
        XCTAssertEqual(responses.count, 1, "seul le `ping` répond")
        XCTAssertEqual(try JSONMatch.object(responses[0])["id"] as? Int, 1)
    }

    /// Une ligne qui n'est pas du JSON rend `-32700` et **le serveur continue**.
    /// C'est le point : un client qui bafouille une fois ne doit pas tuer la
    /// session.
    func testNonJSONLineYieldsParseErrorWithoutStopping() throws {
        let input = "ceci n'est pas du JSON\n"
            + #"{"jsonrpc":"2.0","id":2,"method":"ping"}"# + "\n"
        let responses = try serve(Data(input.utf8))
        XCTAssertEqual(responses.count, 2)

        let first = try JSONMatch.object(responses[0])
        XCTAssertTrue(first["id"] is NSNull, "un id introuvable se rend null")
        XCTAssertEqual((first["error"] as? [String: Any])?["code"] as? Int, -32700)

        let second = try JSONMatch.object(responses[1])
        XCTAssertEqual(second["id"] as? Int, 2, "la session a survécu")
    }

    /// « Servers SHOULD exit promptly when their standard input is closed. »
    /// La boucle rend, sans délai et sans rien écrire de plus.
    func testEndOfInputStopsTheLoop() throws {
        let responses = try serve(Data())
        XCTAssertTrue(responses.isEmpty)
    }

    /// Un tableau JSON au premier niveau — le « batch » de JSON-RPC 2.0 — est
    /// refusé explicitement plutôt qu'à moitié traité.
    func testABatchIsRefused() throws {
        let responses = try serve(Data(#"[{"jsonrpc":"2.0","id":1,"method":"ping"}]"# .utf8))
        XCTAssertEqual(responses.count, 1)
        let error = try JSONMatch.object(responses[0])["error"] as? [String: Any]
        XCTAssertEqual(error?["code"] as? Int, -32600)
        XCTAssertTrue(((error?["data"] as? [String: String])?["reason"] ?? "")
            .contains("batches"))
    }

    /// Une ligne au-delà du plafond est REFUSÉE, pas avalée : le serveur répond
    /// une erreur d'analyse et reste debout.
    func testAnOversizedLineIsRefusedAndTheLoopSurvives() throws {
        let big = String(repeating: "b", count: 4096)
        let input = #"{"jsonrpc":"2.0","id":1,"method":"ping","params":{"x":"\#(big)"}}"# + "\n"
            + #"{"jsonrpc":"2.0","id":2,"method":"ping"}"# + "\n"
        let responses = try serve(Data(input.utf8), maxLineBytes: 1024)
        XCTAssertEqual(responses.count, 2)
        XCTAssertEqual((try JSONMatch.object(responses[0])["error"] as? [String: Any])?["code"] as? Int,
                       -32700)
        XCTAssertEqual(try JSONMatch.object(responses[1])["id"] as? Int, 2)
    }

    /// Une notification ne reçoit JAMAIS de réponse — pas même une erreur.
    func testNotificationsAreSilent() throws {
        let input = #"{"jsonrpc":"2.0","method":"notifications/initialized"}"# + "\n"
            + #"{"jsonrpc":"2.0","method":"notifications/cancelled","params":{"requestId":1}}"# + "\n"
            + #"{"jsonrpc":"2.0","method":"une/methode/inconnue"}"# + "\n"
        XCTAssertTrue(try serve(Data(input.utf8)).isEmpty)
    }

    /// L'écriture sur un tube dont l'extrémité de lecture est fermée ne doit
    /// pas tuer le processus par SIGPIPE quand le signal est ignoré : `write()`
    /// échoue avec EPIPE et retourne sans lever d'exception ni tuer le serveur.
    func testWritingToClosedPipeDoesNotCrashWithSIGPIPE() throws {
        signal(SIGPIPE, SIG_IGN)
        var fds: [Int32] = [0, 0]
        guard Darwin.pipe(&fds) == 0 else { return }
        Darwin.close(fds[0]) // fermeture de la lecture
        let transport = LineTransport(input: STDIN_FILENO, output: fds[1])
        transport.write(Data(#"{"jsonrpc":"2.0","id":1,"result":{}}"#.utf8))
        Darwin.close(fds[1])
    }
}
