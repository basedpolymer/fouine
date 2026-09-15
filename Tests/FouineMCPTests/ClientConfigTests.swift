// ClientConfigTests.swift — Tests de configuration des clients MCP (R-18).
// SPDX-License-Identifier: LicenseRef-Fouine-Source-Available

import Foundation
import XCTest
@testable import FouineMCP

final class ClientConfigTests: XCTestCase {

    private var tempDir: URL!

    override func setUpWithError() throws {
        tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("fouine-clientconfig-test-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        if let tempDir {
            try? FileManager.default.removeItem(at: tempDir)
        }
    }

    // MARK: - 1. Fusion JSON qui préserve les autres serveurs et autres clés

    func testJSONMergePreservesOtherServersAndKeys() throws {
        let claudeDir = tempDir.appendingPathComponent("Library/Application Support/Claude", isDirectory: true)
        try FileManager.default.createDirectory(at: claudeDir, withIntermediateDirectories: true)
        let configFile = claudeDir.appendingPathComponent("claude_desktop_config.json")

        let existingJSON: [String: Any] = [
            "theme": "dark",
            "mcpServers": [
                "other_server": [
                    "command": "node",
                    "args": ["server.js"]
                ]
            ]
        ]
        let data = try JSONSerialization.data(withJSONObject: existingJSON, options: [.prettyPrinted])
        try data.write(to: configFile)

        let (result, _) = MCPClientConfigurator.configureJSONClient(
            clientName: "claude-desktop",
            directoryURL: claudeDir,
            configFileURL: configFile,
            binaryPath: "/usr/local/bin/fouine",
            dryRun: false
        )

        XCTAssertEqual(result.status, .installed)

        // Relit le fichier JSON pour vérifier l'intégrité
        let updatedData = try Data(contentsOf: configFile)
        let updated = try XCTUnwrap(try JSONSerialization.jsonObject(with: updatedData) as? [String: Any])

        // Clé externe préservée
        XCTAssertEqual(updated["theme"] as? String, "dark")

        let servers = try XCTUnwrap(updated["mcpServers"] as? [String: Any])
        // Autre serveur préservé
        let other = try XCTUnwrap(servers["other_server"] as? [String: Any])
        XCTAssertEqual(other["command"] as? String, "node")
        XCTAssertEqual(other["args"] as? [String], ["server.js"])

        // Fouine configuré correctement
        let fouine = try XCTUnwrap(servers["fouine"] as? [String: Any])
        XCTAssertEqual(fouine["command"] as? String, "/usr/local/bin/fouine")
        XCTAssertEqual(fouine["args"] as? [String], ["mcp", "--stdio"])

        // Vérifie la création du fichier de sauvegarde .fouine-bak
        let backupFile = configFile.appendingPathExtension("fouine-bak")
        XCTAssertTrue(FileManager.default.fileExists(atPath: backupFile.path))
        let backupData = try Data(contentsOf: backupFile)
        let backupObj = try XCTUnwrap(try JSONSerialization.jsonObject(with: backupData) as? [String: Any])
        XCTAssertNil((backupObj["mcpServers"] as? [String: Any])?["fouine"], "le backup ne doit pas contenir fouine")
    }

    // MARK: - 2. JSON invalide refusé avec mention du fichier

    func testInvalidJSONRefusedAndNotWritten() throws {
        let claudeDir = tempDir.appendingPathComponent("Library/Application Support/Claude", isDirectory: true)
        try FileManager.default.createDirectory(at: claudeDir, withIntermediateDirectories: true)
        let configFile = claudeDir.appendingPathComponent("claude_desktop_config.json")

        let invalidContent = "{ not valid json: true, }"
        try invalidContent.write(to: configFile, atomically: true, encoding: .utf8)

        let (result, _) = MCPClientConfigurator.configureJSONClient(
            clientName: "claude-desktop",
            directoryURL: claudeDir,
            configFileURL: configFile,
            binaryPath: "/usr/local/bin/fouine",
            dryRun: false
        )

        XCTAssertEqual(result.status, .failed)
        XCTAssertTrue(result.reason.contains("claude_desktop_config.json"))
        XCTAssertTrue(result.reason.contains("invalid JSON"))

        // Le fichier ne doit pas avoir été modifié
        let contentAfter = try String(contentsOf: configFile, encoding: .utf8)
        XCTAssertEqual(contentAfter, invalidContent)

        // Aucun backup ne doit avoir été créé
        let backupFile = configFile.appendingPathExtension("fouine-bak")
        XCTAssertFalse(FileManager.default.fileExists(atPath: backupFile.path))
    }

    // MARK: - 3. Dossier absent = skipped sans écriture

    func testAbsentDirectorySkipped() throws {
        // Le dossier Library/Application Support/Claude n'est pas créé
        let claudeDir = tempDir.appendingPathComponent("Library/Application Support/Claude", isDirectory: true)
        let configFile = claudeDir.appendingPathComponent("claude_desktop_config.json")

        let (result, _) = MCPClientConfigurator.configureJSONClient(
            clientName: "claude-desktop",
            directoryURL: claudeDir,
            configFileURL: configFile,
            binaryPath: "/usr/local/bin/fouine",
            dryRun: false
        )

        XCTAssertEqual(result.status, .skipped)
        XCTAssertTrue(result.reason.contains("Claude Desktop is not installed"))
        XCTAssertFalse(FileManager.default.fileExists(atPath: claudeDir.path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: configFile.path))

        // Pareil pour Cursor
        let cursorDir = tempDir.appendingPathComponent(".cursor", isDirectory: true)
        let cursorFile = cursorDir.appendingPathComponent("mcp.json")

        let (resCursor, _) = MCPClientConfigurator.configureJSONClient(
            clientName: "cursor",
            directoryURL: cursorDir,
            configFileURL: cursorFile,
            binaryPath: "/usr/local/bin/fouine",
            dryRun: false
        )

        XCTAssertEqual(resCursor.status, .skipped)
        XCTAssertTrue(resCursor.reason.contains("Cursor is not installed"))
        XCTAssertFalse(FileManager.default.fileExists(atPath: cursorDir.path))
    }

    // MARK: - 4. Idempotence : already configured

    func testIdempotence() throws {
        let cursorDir = tempDir.appendingPathComponent(".cursor", isDirectory: true)
        try FileManager.default.createDirectory(at: cursorDir, withIntermediateDirectories: true)
        let configFile = cursorDir.appendingPathComponent("mcp.json")

        // Première exécution : installe
        let (res1, _) = MCPClientConfigurator.configureJSONClient(
            clientName: "cursor",
            directoryURL: cursorDir,
            configFileURL: configFile,
            binaryPath: "/usr/local/bin/fouine",
            dryRun: false
        )
        XCTAssertEqual(res1.status, .installed)

        let modDate1 = try FileManager.default.attributesOfItem(atPath: configFile.path)[.modificationDate] as? Date

        // Deuxième exécution : déjà configuré
        let (res2, _) = MCPClientConfigurator.configureJSONClient(
            clientName: "cursor",
            directoryURL: cursorDir,
            configFileURL: configFile,
            binaryPath: "/usr/local/bin/fouine",
            dryRun: false
        )
        XCTAssertEqual(res2.status, .already)
        XCTAssertEqual(res2.reason, "already configured")

        let modDate2 = try FileManager.default.attributesOfItem(atPath: configFile.path)[.modificationDate] as? Date
        XCTAssertEqual(modDate1, modDate2, "le fichier ne doit pas avoir été touché")
    }

    // MARK: - 5. Mode dry-run : n'écrit rien

    func testDryRunDoesNotWrite() throws {
        let claudeDir = tempDir.appendingPathComponent("Library/Application Support/Claude", isDirectory: true)
        try FileManager.default.createDirectory(at: claudeDir, withIntermediateDirectories: true)
        let configFile = claudeDir.appendingPathComponent("claude_desktop_config.json")

        let (result, preview) = MCPClientConfigurator.configureJSONClient(
            clientName: "claude-desktop",
            directoryURL: claudeDir,
            configFileURL: configFile,
            binaryPath: "/usr/local/bin/fouine",
            dryRun: true
        )

        XCTAssertEqual(result.status, .dryRun)
        XCTAssertNotNil(preview)
        XCTAssertTrue(preview?.contains("/usr/local/bin/fouine") == true)
        XCTAssertFalse(FileManager.default.fileExists(atPath: configFile.path), "aucun fichier ne doit être écrit en dry-run")
    }

    /// CM-08 : `--dry-run` imprimait le fichier de configuration ENTIER après
    /// fusion. `mcpServers` est précisément l'endroit où les autres serveurs
    /// rangent leurs jetons d'API — et `--dry-run` est ce qu'on colle dans un
    /// rapport de bogue.
    func testDryRunPreviewShowsOnlyTheFouineEntry() throws {
        let claudeDir = tempDir.appendingPathComponent("Library/Application Support/Claude", isDirectory: true)
        try FileManager.default.createDirectory(at: claudeDir, withIntermediateDirectories: true)
        let configFile = claudeDir.appendingPathComponent("claude_desktop_config.json")

        let existing: [String: Any] = [
            "bypassPermissionsOptInByAccount": ["3f2a-…": true],
            "mcpServers": [
                "autre_serveur": [
                    "command": "node",
                    "args": ["server.js"],
                    "env": ["TOKEN": "secret-xyz"],
                ],
            ],
        ]
        try JSONSerialization.data(withJSONObject: existing, options: [.prettyPrinted])
            .write(to: configFile)

        let (result, preview) = MCPClientConfigurator.configureJSONClient(
            clientName: "claude-desktop",
            directoryURL: claudeDir,
            configFileURL: configFile,
            binaryPath: "/usr/local/bin/fouine",
            dryRun: true
        )

        XCTAssertEqual(result.status, .dryRun)
        let shown = try XCTUnwrap(preview)
        XCTAssertFalse(shown.contains("secret-xyz"), shown)
        XCTAssertFalse(shown.contains("autre_serveur"), shown)
        XCTAssertFalse(shown.contains("bypassPermissions"), shown)
        XCTAssertTrue(shown.contains("\"fouine\""), shown)
        XCTAssertTrue(shown.contains("/usr/local/bin/fouine"), shown)
        // Et le fichier existant n'a pas bougé.
        let after = try XCTUnwrap(try JSONSerialization.jsonObject(
            with: try Data(contentsOf: configFile)) as? [String: Any])
        let servers = try XCTUnwrap(after["mcpServers"] as? [String: Any])
        XCTAssertNil(servers["fouine"])
    }

    /// La voie `--json` de `mcp install` ne porte que client, statut, chemin et
    /// motif : l'aperçu n'y entre pas, et rien du fichier d'un autre serveur.
    func testTheJSONPayloadCarriesNoConfigurationContent() throws {
        let result = ClientConfigResult(client: "claude-desktop", status: .dryRun,
                                        path: "/tmp/claude_desktop_config.json",
                                        reason: "would update configuration in /tmp/claude_desktop_config.json")
        XCTAssertEqual(Set(result.json.keys), ["client", "status", "path", "reason"])
    }

    // MARK: - 6. Choix du chemin du binaire

    func testBinaryResolutionPrefersSymlinkWhenMatching() throws {
        // Crée un faux binaire et un lien symbolique qui pointe dessus
        let binDir = tempDir.appendingPathComponent("bin", isDirectory: true)
        try FileManager.default.createDirectory(at: binDir, withIntermediateDirectories: true)
        let execURL = binDir.appendingPathComponent("fouine_real")
        try "#!/bin/sh\n".write(to: execURL, atomically: true, encoding: .utf8)

        let symlinkURL = binDir.appendingPathComponent("fouine_symlink")
        try FileManager.default.createSymbolicLink(at: symlinkURL, withDestinationURL: execURL)

        // Résolution quand le symlink pointe bien sur le binaire
        let resMatching = MCPClientConfigurator.resolveBinary(
            currentExecutableURL: execURL,
            usrLocalBinURL: symlinkURL
        )
        XCTAssertEqual(resMatching.path, symlinkURL.path)
        XCTAssertTrue(resMatching.isSymlink)

        // Résolution quand le symlink n'existe pas
        let missingSymlink = binDir.appendingPathComponent("non_existent")
        let resMissing = MCPClientConfigurator.resolveBinary(
            currentExecutableURL: execURL,
            usrLocalBinURL: missingSymlink
        )
        XCTAssertEqual(resMissing.path, execURL.path)
        XCTAssertFalse(resMissing.isSymlink)

        // Résolution quand le symlink pointe sur un autre binaire
        let otherExecURL = binDir.appendingPathComponent("other_binary")
        try "#!/bin/sh\n".write(to: otherExecURL, atomically: true, encoding: .utf8)
        let otherSymlink = binDir.appendingPathComponent("other_symlink")
        try FileManager.default.createSymbolicLink(at: otherSymlink, withDestinationURL: otherExecURL)

        let resDivergent = MCPClientConfigurator.resolveBinary(
            currentExecutableURL: execURL,
            usrLocalBinURL: otherSymlink
        )
        XCTAssertEqual(resDivergent.path, execURL.path)
        XCTAssertFalse(resDivergent.isSymlink)

        // CM-25 : `reason` ne redit pas le chemin. La CLI imprime
        // « binary: <path> (<reason>) » ; quand `reason` le portait aussi, la
        // ligne sortait avec deux chemins et des parenthèses emboîtées.
        for resolution in [resMatching, resMissing, resDivergent] {
            let line = "binary: \(resolution.path) (\(resolution.reason))"
            XCTAssertEqual(
                line.components(separatedBy: resolution.path).count - 1, 1,
                "le chemin apparaît plus d'une fois : \(line)")
        }
        XCTAssertEqual(resMissing.reason, "/usr/local/bin/fouine does not exist")
        XCTAssertEqual(
            resDivergent.reason,
            "/usr/local/bin/fouine points to a different binary: "
            + otherExecURL.resolvingSymlinksInPath().path)
    }

    // MARK: - 7. Claude Code

    func testClaudeCodeSkippedWhenNotOnPath() {
        let result = MCPClientConfigurator.configureClaudeCode(
            binaryPath: "/usr/local/bin/fouine",
            dryRun: false,
            claudeExecutable: nil
        )
        XCTAssertEqual(result.status, .skipped)
        XCTAssertTrue(result.reason.contains("claude CLI not found on PATH"))
        XCTAssertTrue(result.reason.contains("claude mcp add --scope user fouine -- /usr/local/bin/fouine mcp --stdio"))
    }

    func testClaudeCodeAlreadyWhenGetResponds() {
        let runner: MCPClientConfigurator.CommandRunner = { exec, args in
            if args == ["mcp", "get", "fouine"] {
                return (status: 0, stdout: "fouine server info", stderr: "")
            }
            return (status: 1, stdout: "", stderr: "unknown command")
        }

        let result = MCPClientConfigurator.configureClaudeCode(
            binaryPath: "/usr/local/bin/fouine",
            dryRun: false,
            claudeExecutable: "/usr/local/bin/claude",
            commandRunner: runner
        )
        XCTAssertEqual(result.status, .already)
        XCTAssertEqual(result.reason, "already configured")
    }

    func testClaudeCodeInstallsWhenGetFailsAndAddSucceeds() {
        final class Box: @unchecked Sendable {
            var args: [String] = []
        }
        let box = Box()
        let runner: MCPClientConfigurator.CommandRunner = { exec, args in
            box.args = args
            if args == ["mcp", "get", "fouine"] {
                return (status: 1, stdout: "", stderr: "not found")
            }
            if args == ["mcp", "add", "--scope", "user", "fouine", "--", "/usr/local/bin/fouine", "mcp", "--stdio"] {
                return (status: 0, stdout: "added", stderr: "")
            }
            return (status: 2, stdout: "", stderr: "bad arguments")
        }

        let result = MCPClientConfigurator.configureClaudeCode(
            binaryPath: "/usr/local/bin/fouine",
            dryRun: false,
            claudeExecutable: "/usr/local/bin/claude",
            commandRunner: runner
        )
        XCTAssertEqual(result.status, .installed)
        XCTAssertEqual(result.reason, "configured via claude mcp add")
        XCTAssertTrue(box.args.contains("--"), "le flag -- est obligatoire")
    }

    func testClaudeCodeDryRun() {
        let runner: MCPClientConfigurator.CommandRunner = { exec, args in
            if args == ["mcp", "get", "fouine"] {
                return (status: 1, stdout: "", stderr: "not found")
            }
            XCTFail("ne doit pas exécuter mcp add en dry-run")
            return (status: 0, stdout: "", stderr: "")
        }

        let result = MCPClientConfigurator.configureClaudeCode(
            binaryPath: "/usr/local/bin/fouine",
            dryRun: true,
            claudeExecutable: "/usr/local/bin/claude",
            commandRunner: runner
        )
        XCTAssertEqual(result.status, .dryRun)
        XCTAssertTrue(result.reason.contains("would run: claude mcp add"))
    }

    // MARK: - Codex : ~/.codex/config.toml, une table remplacée ou ajoutée

    private func makeCodex(_ content: String?) throws -> (dir: URL, file: URL) {
        let dir = tempDir.appendingPathComponent(".codex", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let file = dir.appendingPathComponent("config.toml")
        if let content { try content.write(to: file, atomically: true, encoding: .utf8) }
        return (dir, file)
    }

    func testCodexSkippedWhenNotInstalled() {
        let dir = tempDir.appendingPathComponent(".codex", isDirectory: true)
        let (result, _) = MCPClientConfigurator.configureCodex(
            directoryURL: dir, configFileURL: dir.appendingPathComponent("config.toml"),
            binaryPath: "/usr/local/bin/fouine", dryRun: false)
        XCTAssertEqual(result.status, .skipped)
        XCTAssertEqual(result.reason, "Codex is not installed")
        XCTAssertFalse(FileManager.default.fileExists(atPath: dir.path))
    }

    func testCodexAppendsTheTableAndKeepsTheRest() throws {
        let original = """
            model = "gpt-5-codex"
            approval_policy = "on-request"

            [mcp_servers.context7]
            command = "npx"
            args = ["-y", "@upstash/context7-mcp"]

            [mcp_servers.context7.env]
            TOKEN = "secret"
            """
        let (dir, file) = try makeCodex(original)
        let (result, preview) = MCPClientConfigurator.configureCodex(
            directoryURL: dir, configFileURL: file,
            binaryPath: "/usr/local/bin/fouine", dryRun: false)
        XCTAssertEqual(result.status, .installed, result.reason)
        let after = try String(contentsOf: file, encoding: .utf8)
        XCTAssertTrue(after.hasPrefix(original), "le début du fichier doit rester au caractère près")
        XCTAssertTrue(after.hasSuffix("""

            [mcp_servers.fouine]
            command = "/usr/local/bin/fouine"
            args = ["mcp", "--stdio"]

            """), after)
        XCTAssertEqual(preview, "[mcp_servers.fouine]\ncommand = \"/usr/local/bin/fouine\"\nargs = [\"mcp\", \"--stdio\"]\n")
        XCTAssertTrue(FileManager.default.fileExists(atPath: file.appendingPathExtension("fouine-bak").path))
        XCTAssertEqual(try String(contentsOf: file.appendingPathExtension("fouine-bak"), encoding: .utf8), original)
    }

    func testCodexCreatesTheFileWhenAbsent() throws {
        let (dir, file) = try makeCodex(nil)
        let (result, _) = MCPClientConfigurator.configureCodex(
            directoryURL: dir, configFileURL: file,
            binaryPath: "/Applications/Fouine.app/Contents/Helpers/fouine",
            folders: ["Livres", "M2SU"], dryRun: false)
        XCTAssertEqual(result.status, .installed, result.reason)
        XCTAssertEqual(try String(contentsOf: file, encoding: .utf8), """
            [mcp_servers.fouine]
            command = "/Applications/Fouine.app/Contents/Helpers/fouine"
            args = ["mcp", "--stdio", "--folders", "Livres,M2SU"]

            """)
        XCTAssertFalse(FileManager.default.fileExists(atPath: file.appendingPathExtension("fouine-bak").path),
                       "pas de sauvegarde d'un fichier qui n'existait pas")
    }

    func testCodexReplacesTheTableAndKeepsItsSubTables() throws {
        let original = """
            model = "gpt-5-codex"

            [mcp_servers.fouine]
            command = "/old/fouine"
            args = ["mcp", "--stdio", "--folders", "Livres"]
            # un commentaire dans le bloc

            [mcp_servers.fouine.env]
            FOUINE_DB = "/tmp/autre.db"

            [mcp_servers.other]
            command = "node"
            args = ["server.js"]

            """
        let (dir, file) = try makeCodex(original)
        let (result, _) = MCPClientConfigurator.configureCodex(
            directoryURL: dir, configFileURL: file,
            binaryPath: "/usr/local/bin/fouine", dryRun: false)
        XCTAssertEqual(result.status, .installed, result.reason)
        // Le périmètre déjà écrit est CONSERVÉ (même règle qu'en JSON), la
        // sous-table `env` et la table `other` restent intactes.
        XCTAssertEqual(try String(contentsOf: file, encoding: .utf8), """
            model = "gpt-5-codex"

            [mcp_servers.fouine]
            command = "/usr/local/bin/fouine"
            args = ["mcp", "--stdio", "--folders", "Livres"]

            [mcp_servers.fouine.env]
            FOUINE_DB = "/tmp/autre.db"

            [mcp_servers.other]
            command = "node"
            args = ["server.js"]

            """)
    }

    func testCodexAlreadyConfiguredAndDryRunWriteNothing() throws {
        let original = """
            [mcp_servers."fouine"]
            command = "/usr/local/bin/fouine"
            args = ["mcp", "--stdio"]

            """
        let (dir, file) = try makeCodex(original)
        let (already, _) = MCPClientConfigurator.configureCodex(
            directoryURL: dir, configFileURL: file,
            binaryPath: "/usr/local/bin/fouine", dryRun: false)
        XCTAssertEqual(already.status, .already, already.reason)

        let (dry, preview) = MCPClientConfigurator.configureCodex(
            directoryURL: dir, configFileURL: file,
            binaryPath: "/elsewhere/fouine", dryRun: true)
        XCTAssertEqual(dry.status, .dryRun, dry.reason)
        XCTAssertEqual(preview, "[mcp_servers.fouine]\ncommand = \"/elsewhere/fouine\"\nargs = [\"mcp\", \"--stdio\"]\n")
        XCTAssertEqual(try String(contentsOf: file, encoding: .utf8), original)
        XCTAssertFalse(FileManager.default.fileExists(atPath: file.appendingPathExtension("fouine-bak").path))
    }

    func testCodexRefusesAnInlineMcpServersTable() throws {
        let original = "mcp_servers = { other = { command = \"node\" } }\n"
        let (dir, file) = try makeCodex(original)
        let (result, _) = MCPClientConfigurator.configureCodex(
            directoryURL: dir, configFileURL: file,
            binaryPath: "/usr/local/bin/fouine", dryRun: false)
        XCTAssertEqual(result.status, .failed)
        XCTAssertTrue(result.reason.contains("inline table"), result.reason)
        XCTAssertEqual(try String(contentsOf: file, encoding: .utf8), original)
    }

    func testTOMLBasicStringEscapes() {
        XCTAssertEqual(MCPClientConfigurator.tomlBasicString(#"/a "b" \c"#), #""/a \"b\" \\c""#)
    }

    // MARK: - Antigravity : ~/.gemini/config/mcp_config.json, mêmes règles qu'en JSON

    func testAntigravityDirectoryPrefersConfigThenLegacy() throws {
        XCTAssertNil(MCPClientConfigurator.antigravityDirectory(homeURL: tempDir))
        let legacy = tempDir.appendingPathComponent(".gemini/antigravity", isDirectory: true)
        try FileManager.default.createDirectory(at: legacy, withIntermediateDirectories: true)
        XCTAssertEqual(MCPClientConfigurator.antigravityDirectory(homeURL: tempDir)?.lastPathComponent, "antigravity")
        let config = tempDir.appendingPathComponent(".gemini/config", isDirectory: true)
        try FileManager.default.createDirectory(at: config, withIntermediateDirectories: true)
        XCTAssertEqual(MCPClientConfigurator.antigravityDirectory(homeURL: tempDir)?.lastPathComponent, "config")
    }

    func testInstallAllCoversFiveClientsAndKeepsAntigravityKeys() throws {
        let config = tempDir.appendingPathComponent(".gemini/config", isDirectory: true)
        try FileManager.default.createDirectory(at: config, withIntermediateDirectories: true)
        let file = config.appendingPathComponent("mcp_config.json")
        // L'entrée qu'Antigravity écrit lui-même quand on le configure à la
        // main : `disabled` doit survivre à la réécriture.
        let existing: [String: Any] = ["mcpServers": ["fouine": [
            "command": "/old/fouine", "args": ["mcp", "--stdio"], "disabled": false]]]
        try JSONSerialization.data(withJSONObject: existing).write(to: file)

        let (_, reports) = MCPClientConfigurator.install(
            target: .all, homeURL: tempDir, customBinaryPath: "/usr/local/bin/fouine",
            dryRun: false,
            // Un `claude` factice qui répond « déjà configuré » : le test ne
            // dépend pas de ce que le PATH de la machine contient.
            commandRunner: { _, _ in (status: 0, stdout: "", stderr: "") },
            claudePathOverride: "/nonexistent/claude")
        XCTAssertEqual(reports.map(\.result.client),
                       ["claude-desktop", "claude-code", "cursor", "codex", "antigravity"])
        XCTAssertEqual(reports.map(\.result.status),
                       [.skipped, .already, .skipped, .skipped, .installed],
                       reports.map(\.result.reason).joined(separator: " | "))
        XCTAssertEqual(reports[3].result.reason, "Codex is not installed")
        let after = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(contentsOf: file)) as? [String: Any])
        let entry = try XCTUnwrap((after["mcpServers"] as? [String: Any])?["fouine"] as? [String: Any])
        XCTAssertEqual(entry["command"] as? String, "/usr/local/bin/fouine")
        XCTAssertEqual(entry["disabled"] as? Bool, false)
    }
}
