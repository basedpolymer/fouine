// StdoutHygieneTests.swift — le piège n°1 du transport stdio. Propriété : A-MCP.
// SPDX-License-Identifier: LicenseRef-Fouine-Source-Available
//
// « The server MUST NOT write anything to its stdout that is not a valid MCP
//   message. » En Swift, la faute est à un `print` de distance — dans
//   FouineCore, dans une dépendance, dans un reste de mise au point. Ce test
//   vérifie le remède, pas la discipline : un `print("bruit")` injecté ENTRE
//   deux requêtes ne doit pas apparaître dans le flux.
//
// MÉCANIQUE DU TEST. Le descripteur 1 du processus de test est temporairement
// dirigé vers un fichier, `StdoutGuard` s'installe par-dessus, on parle, on
// restaure. Pendant cette fenêtre, XCTest lui-même n'a plus de sortie standard :
// toutes les assertions sont donc faites APRÈS la restauration.

import Foundation
import XCTest
import FouineMCPKit

final class StdoutHygieneTests: XCTestCase {

    func testAStrayPrintNeverReachesTheMCPStream() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("fouine-hygiene-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }

        let streamURL = directory.appendingPathComponent("stream.jsonl")
        FileManager.default.createFile(atPath: streamURL.path, contents: nil)
        let stream = try FileHandle(forWritingTo: streamURL)

        let router = Router(registry: ToolRegistry([]),
                            serverInfo: .init(name: "fouine", title: "Fouine", version: "test"))

        // --- fenêtre où `stdout` du processus de test est détourné -----------
        let savedStdout = dup(STDOUT_FILENO)
        XCTAssertGreaterThanOrEqual(savedStdout, 0)
        dup2(stream.fileDescriptor, STDOUT_FILENO)

        // À partir d'ici, fd 1 → /dev/null, et `guarded.output` → le fichier.
        let guarded = try StdoutGuard.install()
        let transport = LineTransport(input: STDIN_FILENO,
                                      output: guarded.output.fileDescriptor)

        if let response = router.handle(Data(#"{"jsonrpc":"2.0","id":1,"method":"ping"}"#.utf8)) {
            transport.write(response)
        }
        print("bruit — un print oublié dans FouineCore")
        FileHandle.standardOutput.write(Data("bruit direct sur FileHandle.standardOutput\n".utf8))
        fputs("bruit par la libc\n", stdout)
        fflush(stdout)
        if let response = router.handle(Data(#"{"jsonrpc":"2.0","id":2,"method":"ping"}"#.utf8)) {
            transport.write(response)
        }

        guarded.restore()
        dup2(savedStdout, STDOUT_FILENO)
        close(savedStdout)
        try stream.close()
        // --- fin de la fenêtre -----------------------------------------------

        let text = try String(contentsOf: streamURL, encoding: .utf8)
        XCTAssertFalse(text.contains("bruit"),
                       "du bruit a atteint le flux MCP :\n\(text)")

        let lines = text.split(separator: "\n").map(String.init)
        XCTAssertEqual(lines.count, 2, "deux réponses, rien d'autre : \(lines)")
        for line in lines {
            XCTAssertNoThrow(try JSONSerialization.jsonObject(with: Data(line.utf8)),
                             "chaque ligne du flux doit être du JSON : \(line)")
        }
        XCTAssertEqual(try JSONMatch.object(Data(lines[0].utf8))["id"] as? Int, 1)
        XCTAssertEqual(try JSONMatch.object(Data(lines[1].utf8))["id"] as? Int, 2)
    }

    /// Le garde-fou rend un descripteur DISTINCT de 1 : sans quoi il ne
    /// protégerait rien.
    func testTheGuardHandsBackASeparateDescriptor() throws {
        let guarded = try StdoutGuard.install()
        let descriptor = guarded.output.fileDescriptor
        guarded.restore()
        XCTAssertNotEqual(descriptor, STDOUT_FILENO)
    }
}
