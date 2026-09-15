// AssistantRequestTests.swift — la demande copiée pour l'assistant IA porte
// tout ce qu'il faut pour réussir `mcp install` sans chercher.
// SPDX-License-Identifier: LicenseRef-Fouine-Source-Available

import AppKit
import XCTest
@testable import FouineApp

final class AssistantRequestTests: XCTestCase {

    /// Le chemin RÉEL du binaire embarqué, puis la commande : c'est ce que
    /// « installe le MCP de Fouine » ne dit pas, et ce qui manque à un
    /// assistant dont le PATH ignore `fouine`.
    func testTextCarriesTheBundledBinaryAndTheCommand() {
        let cli = URL(fileURLWithPath: "/Applications/Fouine.app/Contents/Helpers/fouine")
        let text = AssistantRequest.text(cli: cli)
        XCTAssertTrue(text.contains("\n\n/Applications/Fouine.app/Contents/Helpers/fouine mcp install\n\n"), text)
        for client in ["Claude Desktop", "Claude Code", "Cursor", "Codex", "Antigravity",
                       "--client", "--dry-run", "--folders", "--print", "--help", "read-only",
                       AssistantRequest.guideURL] {
            XCTAssertTrue(text.contains(client), "manque « \(client) » : \(text)")
        }
    }

    /// Hors bundle (`swift run`), le chemin d'une installation standard.
    func testTextFallsBackToTheStandardPath() {
        XCTAssertTrue(AssistantRequest.text(cli: nil)
            .contains(AssistantRequest.standardCLIPath + " mcp install"))
    }

    /// Un chemin avec une espace se cite, un chemin ordinaire non.
    func testShellQuoting() {
        XCTAssertEqual(AssistantRequest.shellQuoted("/Applications/Fouine.app/Contents/Helpers/fouine"),
                       "/Applications/Fouine.app/Contents/Helpers/fouine")
        XCTAssertEqual(AssistantRequest.shellQuoted("/Users/m/Mes applications/Fouine.app/Contents/Helpers/fouine"),
                       "'/Users/m/Mes applications/Fouine.app/Contents/Helpers/fouine'")
        XCTAssertEqual(AssistantRequest.shellQuoted("/tmp/l'app/fouine"), "'/tmp/l'\\''app/fouine'")
    }

    /// Le presse-papiers reçoit la demande, et rien d'autre.
    func testCopyPutsTheTextOnThePasteboard() {
        let pasteboard = NSPasteboard.withUniqueName()
        defer { pasteboard.releaseGlobally() }
        let cli = URL(fileURLWithPath: "/Applications/Fouine.app/Contents/Helpers/fouine")
        AssistantRequest.copy(cli: cli, to: pasteboard)
        XCTAssertEqual(pasteboard.string(forType: .string), AssistantRequest.text(cli: cli))
    }
}
