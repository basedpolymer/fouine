// MCPInstallRecetteTests.swift — Recette d'intégration pour `fouine mcp install` et `fouine ocr requeue` (R-18, R-16).
// SPDX-License-Identifier: LicenseRef-Fouine-Source-Available

import Foundation
import XCTest
import FouineCore

final class MCPInstallRecetteTests: XCTestCase {

    private var scratch: Recette.Scratch!

    override func setUpWithError() throws {
        _ = try Recette.requireBinary()
        scratch = try Recette.makeIndexedScratch("mcp-install-recette")
    }

    override func tearDownWithError() throws {
        if let scratch {
            try? FileManager.default.removeItem(at: scratch.directory)
        }
    }

    // MARK: - 1. fouine mcp install --dry-run --json avec faux HOME

    func testMCPInstallDryRunJSONWithFakeHome() throws {
        let fakeHome = scratch.directory.appendingPathComponent("fake-home-\(UUID().uuidString)")
        let claudeDir = fakeHome.appendingPathComponent("Library/Application Support/Claude", isDirectory: true)
        try FileManager.default.createDirectory(at: claudeDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: fakeHome) }

        let configFile = claudeDir.appendingPathComponent("claude_desktop_config.json")
        let initialJSON: [String: Any] = [
            "theme": "light",
            "mcpServers": [
                "node_srv": [
                    "command": "node",
                    "args": ["index.js"]
                ]
            ]
        ]
        let initData = try JSONSerialization.data(withJSONObject: initialJSON, options: [.prettyPrinted])
        try initData.write(to: configFile)

        // Exécute fouine mcp install --dry-run --json
        let res = try Recette.run(
            ["mcp", "install", "--dry-run", "--json"],
            database: scratch.database,
            extraEnvironment: ["HOME": fakeHome.path]
        )

        XCTAssertEqual(res.status, 0, res.describe)

        let obj = try JSONSerialization.jsonObject(with: Data(res.stdout.utf8)) as? [[String: Any]]
        let reports = try XCTUnwrap(obj)
        XCTAssertFalse(reports.isEmpty)

        // Trouve le rapport claude-desktop
        let claudeReport = try XCTUnwrap(reports.first { ($0["client"] as? String) == "claude-desktop" })
        XCTAssertEqual(claudeReport["status"] as? String, "dry_run")
        XCTAssertEqual(claudeReport["path"] as? String, configFile.path)

        // Cursor n'a pas de dossier -> skipped
        let cursorReport = try XCTUnwrap(reports.first { ($0["client"] as? String) == "cursor" })
        XCTAssertEqual(cursorReport["status"] as? String, "skipped")

        // Codex et Antigravity sont dans le tour, dans cet ordre, et sautés
        // au même titre quand leur dossier manque.
        XCTAssertEqual(reports.compactMap { $0["client"] as? String },
                       ["claude-desktop", "claude-code", "cursor", "codex", "antigravity"])
        for name in ["codex", "antigravity"] {
            let report = try XCTUnwrap(reports.first { ($0["client"] as? String) == name })
            XCTAssertEqual(report["status"] as? String, "skipped", name)
            XCTAssertEqual(report["reason"] as? String,
                           "\(name == "codex" ? "Codex" : "Antigravity") is not installed")
        }

        // En dry-run, le fichier d'origine ne doit pas avoir été modifié
        let afterData = try Data(contentsOf: configFile)
        let afterObj = try XCTUnwrap(try JSONSerialization.jsonObject(with: afterData) as? [String: Any])
        let servers = try XCTUnwrap(afterObj["mcpServers"] as? [String: Any])
        XCTAssertNil(servers["fouine"], "fouine ne doit pas être écrit en dry-run")
        XCTAssertNotNil(servers["node_srv"])

        // Aucun backup ne doit exister
        let backup = configFile.appendingPathExtension("fouine-bak")
        XCTAssertFalse(FileManager.default.fileExists(atPath: backup.path))
    }

    /// Codex (`~/.codex/config.toml`) et Antigravity
    /// (`~/.gemini/config/mcp_config.json`) par le binaire, en `--dry-run` :
    /// l'aperçu montre la table TOML ou l'entrée JSON, et rien n'est écrit.
    func testMCPInstallDryRunCodexAndAntigravity() throws {
        let fakeHome = scratch.directory.appendingPathComponent("fake-home-\(UUID().uuidString)")
        let codexDir = fakeHome.appendingPathComponent(".codex", isDirectory: true)
        let agDir = fakeHome.appendingPathComponent(".gemini/config", isDirectory: true)
        try FileManager.default.createDirectory(at: codexDir, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: agDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: fakeHome) }
        let toml = "model = \"gpt-5-codex\"\n"
        try toml.write(to: codexDir.appendingPathComponent("config.toml"), atomically: true, encoding: .utf8)

        let res = try Recette.run(
            ["mcp", "install", "--dry-run", "--client", "codex"],
            database: scratch.database,
            extraEnvironment: ["HOME": fakeHome.path])
        XCTAssertEqual(res.status, 0, res.describe)
        XCTAssertTrue(res.stdout.contains("codex: would update configuration in "), res.stdout)
        XCTAssertTrue(res.stdout.contains("[mcp_servers.fouine]\ncommand = \""), res.stdout)
        XCTAssertTrue(res.stdout.contains("args = [\"mcp\", \"--stdio\"]"), res.stdout)
        XCTAssertEqual(try String(contentsOf: codexDir.appendingPathComponent("config.toml"), encoding: .utf8), toml)

        let ag = try Recette.run(
            ["mcp", "install", "--dry-run", "--client", "antigravity", "--json"],
            database: scratch.database,
            extraEnvironment: ["HOME": fakeHome.path])
        XCTAssertEqual(ag.status, 0, ag.describe)
        let reports = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(ag.stdout.utf8)) as? [[String: Any]])
        XCTAssertEqual(reports.count, 1)
        XCTAssertEqual(reports[0]["client"] as? String, "antigravity")
        XCTAssertEqual(reports[0]["status"] as? String, "dry_run")
        XCTAssertEqual(reports[0]["path"] as? String, agDir.appendingPathComponent("mcp_config.json").path)
        XCTAssertFalse(FileManager.default.fileExists(atPath: agDir.appendingPathComponent("mcp_config.json").path))

        // Un client inconnu est une erreur d'usage qui énonce la liste.
        let bad = try Recette.run(
            ["mcp", "install", "--dry-run", "--client", "windsurf"],
            database: scratch.database,
            extraEnvironment: ["HOME": fakeHome.path])
        XCTAssertNotEqual(bad.status, 0)
        XCTAssertTrue(bad.stderr.contains("codex, antigravity"), bad.describe)
    }

    /// `--print` : l'entrée générique pour un client inconnu, sans rien
    /// écrire et sans qu'aucun client soit installé (HOME vide).
    func testMCPInstallPrintGivesTheGenericEntry() throws {
        let fakeHome = scratch.directory.appendingPathComponent("fake-home-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: fakeHome, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: fakeHome) }
        let binary = try Recette.requireBinary().path

        let text = try Recette.run(["mcp", "install", "--print", "--folders", "Livres,M2SU"],
                                   database: scratch.database,
                                   extraEnvironment: ["HOME": fakeHome.path])
        XCTAssertEqual(text.status, 0, text.describe)
        XCTAssertTrue(text.stdout.contains("command line: \(binary) mcp --stdio --folders Livres,M2SU"), text.stdout)
        XCTAssertTrue(text.stdout.contains("\"mcpServers\""), text.stdout)
        XCTAssertTrue(text.stdout.contains("[mcp_servers.fouine]\ncommand = \"\(binary)\"\nargs = [\"mcp\", \"--stdio\", \"--folders\", \"Livres,M2SU\"]\n"), text.stdout)
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: fakeHome.path), [],
                       "--print n'écrit rien")

        let json = try Recette.run(["mcp", "install", "--print", "--json"],
                                   database: scratch.database,
                                   extraEnvironment: ["HOME": fakeHome.path])
        XCTAssertEqual(json.status, 0, json.describe)
        let entry = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(json.stdout.utf8)) as? [String: Any])
        XCTAssertEqual(entry["command"] as? String, binary)
        XCTAssertEqual(entry["args"] as? [String], ["mcp", "--stdio"])
        XCTAssertEqual(entry.count, 2, "deux clés, command et args : \(entry)")
    }

    /// `--folders` ATTEINT la configuration écrite. La commande parente `mcp`
    /// déclare la même option et ArgumentParser la lui attribuait : depuis
    /// IG1, `mcp install --folders …` n'écrivait aucun périmètre, et rien ne
    /// le vérifiait par le binaire. Les trois syntaxes, en dry-run.
    func testMCPInstallFoldersReachTheWrittenEntry() throws {
        let fakeHome = scratch.directory.appendingPathComponent("fake-home-\(UUID().uuidString)")
        let cursorDir = fakeHome.appendingPathComponent(".cursor", isDirectory: true)
        try FileManager.default.createDirectory(at: cursorDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: fakeHome) }

        for arguments in [["--folders", "Livres,M2SU"],
                          ["--folders", "Livres", "M2SU"],
                          ["--folders=Livres,M2SU"]] {
            let res = try Recette.run(
                ["mcp", "install", "--dry-run", "--client", "cursor"] + arguments,
                database: scratch.database,
                extraEnvironment: ["HOME": fakeHome.path])
            XCTAssertEqual(res.status, 0, res.describe)
            let preview = res.stdout.drop(while: { $0 != "{" })
            let obj = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(String(preview).utf8)) as? [String: Any],
                                    res.stdout)
            let entry = try XCTUnwrap((obj["mcpServers"] as? [String: Any])?["fouine"] as? [String: Any])
            XCTAssertEqual(entry["args"] as? [String], ["mcp", "--stdio", "--folders", "Livres,M2SU"],
                           "\(arguments) : \(res.stdout)")
        }
    }

    /// CM-25 : la ligne `binary:` ne porte le chemin QU'UNE FOIS. `reason` le
    /// répétait, et la ligne sortait avec des parenthèses emboîtées :
    /// « binary: /…/fouine (/…/fouine (/usr/local/bin/fouine points to a
    /// different binary: …)) ».
    func testBinaryLineNamesThePathOnlyOnce() throws {
        let fakeHome = scratch.directory
            .appendingPathComponent("fake-home-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: fakeHome,
                                                withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: fakeHome) }

        let res = try Recette.run(["mcp", "install", "--dry-run"],
                                  database: scratch.database,
                                  extraEnvironment: ["HOME": fakeHome.path])
        let line = try XCTUnwrap(
            res.stdout.split(separator: "\n").first { $0.hasPrefix("binary:") },
            "ligne `binary:` absente :\n" + res.stdout)
        // La ligne se lit « binary: <chemin> (<motif>) » : le motif ne doit
        // plus contenir le chemin qui le précède.
        let body = line.dropFirst("binary:".count)
        let open = try XCTUnwrap(body.firstIndex(of: "("),
                                 "ligne sans motif : \(line)")
        let printed = body[..<open].trimmingCharacters(in: .whitespaces)
        let reason = body[body.index(after: open)...].dropLast()
        XCTAssertFalse(printed.isEmpty, "chemin absent : \(line)")
        XCTAssertFalse(reason.contains(printed),
                       "le motif redit le chemin : \(line)")
    }

    // MARK: - 2. fouine mcp install (exécution réelle et idempotence)

    func testMCPInstallExecutionAndIdempotence() throws {
        let fakeHome = scratch.directory.appendingPathComponent("fake-home-\(UUID().uuidString)")
        let claudeDir = fakeHome.appendingPathComponent("Library/Application Support/Claude", isDirectory: true)
        try FileManager.default.createDirectory(at: claudeDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: fakeHome) }

        let configFile = claudeDir.appendingPathComponent("claude_desktop_config.json")
        let initialJSON: [String: Any] = [
            "mcpServers": [
                "existing_srv": [
                    "command": "python3",
                    "args": ["server.py"]
                ]
            ]
        ]
        let initData = try JSONSerialization.data(withJSONObject: initialJSON, options: [.prettyPrinted])
        try initData.write(to: configFile)

        // 1. Première exécution réelle pour claude-desktop
        let res1 = try Recette.run(
            ["mcp", "install", "--client", "claude-desktop", "--json"],
            database: scratch.database,
            extraEnvironment: ["HOME": fakeHome.path]
        )
        XCTAssertEqual(res1.status, 0, res1.describe)

        let reports1 = try XCTUnwrap(try JSONSerialization.jsonObject(with: Data(res1.stdout.utf8)) as? [[String: Any]])
        let report1 = try XCTUnwrap(reports1.first)
        XCTAssertEqual(report1["client"] as? String, "claude-desktop")
        XCTAssertEqual(report1["status"] as? String, "installed")

        // Vérifie la présence du backup et du nouveau serveur
        let backup = configFile.appendingPathExtension("fouine-bak")
        XCTAssertTrue(FileManager.default.fileExists(atPath: backup.path))

        let updatedData = try Data(contentsOf: configFile)
        let updatedObj = try XCTUnwrap(try JSONSerialization.jsonObject(with: updatedData) as? [String: Any])
        let servers = try XCTUnwrap(updatedObj["mcpServers"] as? [String: Any])
        XCTAssertNotNil(servers["existing_srv"])
        let fouine = try XCTUnwrap(servers["fouine"] as? [String: Any])
        XCTAssertEqual(fouine["args"] as? [String], ["mcp", "--stdio"])

        // 2. Seconde exécution (idempotence) : status = already
        let res2 = try Recette.run(
            ["mcp", "install", "--client", "claude-desktop", "--json"],
            database: scratch.database,
            extraEnvironment: ["HOME": fakeHome.path]
        )
        XCTAssertEqual(res2.status, 0, res2.describe)

        let reports2 = try XCTUnwrap(try JSONSerialization.jsonObject(with: Data(res2.stdout.utf8)) as? [[String: Any]])
        let report2 = try XCTUnwrap(reports2.first)
        XCTAssertEqual(report2["status"] as? String, "already")
    }

    // MARK: - 3. fouine ocr requeue

    func testOCRRequeueCommand() throws {
        // Exécution de fouine ocr requeue --json sur la base de test
        let res = try Recette.run(
            ["ocr", "requeue", "--json"],
            database: scratch.database
        )
        XCTAssertEqual(res.status, 0, res.describe)

        let obj = try JSONSerialization.jsonObject(with: Data(res.stdout.utf8)) as? [String: Any]
        let json = try XCTUnwrap(obj)
        XCTAssertEqual(json["population"] as? String, "doubtful")
        XCTAssertNotNil(json["requeued"] as? Int)
        XCTAssertNotNil(json["already_queued"] as? Int)
        XCTAssertNotNil(json["total_candidates"] as? Int)

        // Option --no-lines
        let resNoLines = try Recette.run(
            ["ocr", "requeue", "--no-lines", "--json"],
            database: scratch.database
        )
        XCTAssertEqual(resNoLines.status, 0, resNoLines.describe)
        let jsonNoLines = try XCTUnwrap(try JSONSerialization.jsonObject(with: Data(resNoLines.stdout.utf8)) as? [String: Any])
        XCTAssertEqual(jsonNoLines["population"] as? String, "no_lines")

        // Refus de spécifier les deux
        let resBoth = try Recette.run(
            ["ocr", "requeue", "--doubtful", "--no-lines"],
            database: scratch.database
        )
        XCTAssertEqual(resBoth.status, 64, resBoth.describe)
    }
}
