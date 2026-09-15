// IgnoreRecetteTests.swift — `.fouineignore` et `mcp --folders` sur le binaire
// release. Propriété : A-Recette. Lot IG1, constat PM-01.
//
// Ce que les suites unitaires ne peuvent pas prouver : que le GESTE marche.
// Poser un fichier dans un dossier, relancer `fouine index`, et voir le
// document sortir de l'index — c'est la seule chaîne complète, celle que
// l'utilisateur suit.

import Foundation
import XCTest

final class IgnoreRecetteTests: XCTestCase {

    private var scratch: Recette.Scratch!
    private var database: URL { scratch.database }

    override func setUpWithError() throws {
        _ = try Recette.requireBinary()
        scratch = try Recette.makeIndexedScratch("ignore")
    }

    override func tearDownWithError() throws {
        if let scratch { try? FileManager.default.removeItem(at: scratch.directory) }
    }

    private func documentCount() throws -> Int {
        Int(try Recette.sqlite("SELECT count(*) FROM docs", on: database)
            .trimmingCharacters(in: .whitespacesAndNewlines)) ?? -1
    }

    private func writeIgnoreFile(_ text: String) throws {
        try Data(text.utf8).write(
            to: scratch.root.appendingPathComponent(".fouineignore"))
    }

    /// LA chaîne complète : un fichier posé, une passe, des documents en moins
    /// — puis le fichier retiré, une passe, les documents revenus.
    func testExcludedDocumentsLeaveTheIndexAndComeBack() throws {
        let before = try documentCount()
        XCTAssertGreaterThan(before, 1, "le corpus jetable doit porter des .txt")

        try writeIgnoreFile("# la recette exclut tout le texte\n*.txt\n")
        let second = try Recette.run(["index"], database: database, timeout: 300)
        XCTAssertEqual(second.status, 0, second.describe)
        // Les `.txt` sont TOUT le corpus jetable : il ne doit plus rien rester
        // d'indexé de cette famille.
        let remaining = try Recette.sqlite(
            "SELECT count(*) FROM docs WHERE ext = 'txt'", on: database)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        XCTAssertEqual(remaining, "0")

        try FileManager.default.removeItem(
            at: scratch.root.appendingPathComponent(".fouineignore"))
        let third = try Recette.run(["index"], database: database, timeout: 300)
        XCTAssertEqual(third.status, 0, third.describe)
        XCTAssertEqual(try documentCount(), before,
                       "une exclusion retirée rend le corpus tel quel")
    }

    /// `root list` dit combien de règles porte chaque racine — sinon, un
    /// document manquant n'a aucune explication atteignable.
    func testRootListCountsTheIgnoreRules() throws {
        let none = try Recette.run(["root", "list", "--json"], database: database)
        XCTAssertEqual(none.status, 0, none.describe)
        struct Row: Decodable { let label: String; let ignore_rules: Int }
        var rows = try JSONDecoder().decode([Row].self, from: Data(none.stdout.utf8))
        XCTAssertEqual(rows.first?.ignore_rules, 0)

        try writeIgnoreFile("# deux règles\n*.txt\nArchives/\n")
        let listed = try Recette.run(["root", "list", "--json"], database: database)
        rows = try JSONDecoder().decode([Row].self, from: Data(listed.stdout.utf8))
        XCTAssertEqual(rows.first?.ignore_rules, 2)

        let plain = try Recette.run(["root", "list"], database: database)
        XCTAssertTrue(plain.stdout.contains("ignore_rules=2"), plain.stdout)
    }

    // MARK: - root ignore (lot IG2)

    private struct IgnoreListing: Decodable {
        struct Rule: Decodable { let rule: String; let source: String }
        let label: String
        let rules: [Rule]
        let documents_matching: Int
        let changed: Bool?
    }

    private var ignoreFileExists: Bool {
        FileManager.default.fileExists(
            atPath: scratch.root.appendingPathComponent(".fouineignore").path)
    }

    /// La chaîne de l'app, par la CLI : une règle GARDÉE (aucun fichier), une
    /// passe, des documents en moins — puis la règle retirée, les documents
    /// revenus. Et jamais un octet écrit dans le dossier.
    func testAKeptRuleTakesDocumentsOutWithoutWritingIntoTheFolder() throws {
        let before = try documentCount()
        let added = try Recette.run(["root", "ignore", "add", scratch.label, "fiche-1*",
                                     "--json"], database: database)
        XCTAssertEqual(added.status, 0, added.describe)
        let listing = try JSONDecoder().decode(IgnoreListing.self,
                                               from: Data(added.stdout.utf8))
        XCTAssertEqual(listing.changed, true)
        XCTAssertEqual(listing.rules.map(\.source), ["settings"])
        // fiche-1, fiche-10, fiche-11 : la conséquence est dite AVANT la passe.
        XCTAssertEqual(listing.documents_matching, 3)
        XCTAssertFalse(ignoreFileExists, "rien n'est écrit dans le dossier")

        let again = try Recette.run(["root", "ignore", "add", scratch.label, "FICHE-1*"],
                                    database: database)
        XCTAssertEqual(again.status, 0, again.describe)
        XCTAssertTrue(again.stdout.contains("already skips"), again.stdout)

        let second = try Recette.run(["index"], database: database, timeout: 300)
        XCTAssertEqual(second.status, 0, second.describe)
        XCTAssertEqual(try documentCount(), before - 3)

        let removed = try Recette.run(["root", "ignore", "remove", scratch.label, "fiche-1*"],
                                      database: database)
        XCTAssertEqual(removed.status, 0, removed.describe)
        let third = try Recette.run(["index"], database: database, timeout: 300)
        XCTAssertEqual(third.status, 0, third.describe)
        XCTAssertEqual(try documentCount(), before, "la règle retirée rend le corpus tel quel")
        XCTAssertFalse(ignoreFileExists)
    }

    /// Une règle invalide est une erreur d'USAGE, en 64, et le refus la nomme ;
    /// retirer ce qui n'est pas gardé l'est aussi — y compris une ligne du
    /// fichier, que Fouine ne modifie pas.
    func testRefusalsExitSixtyFourAndNameTheRule() throws {
        let negation = try Recette.run(["root", "ignore", "add", scratch.label, "!fiche-1.txt"],
                                       database: database)
        XCTAssertEqual(negation.status, 64, negation.describe)
        XCTAssertTrue(negation.stderr.contains("!fiche-1.txt"), negation.stderr)

        let escape = try Recette.run(["root", "ignore", "add", scratch.label, "../Autre/"],
                                     database: database)
        XCTAssertEqual(escape.status, 64, escape.describe)

        let unknown = try Recette.run(["root", "ignore", "remove", scratch.label, "Absent/"],
                                      database: database)
        XCTAssertEqual(unknown.status, 64, unknown.describe)
        XCTAssertTrue(unknown.stderr.contains("Absent/"), unknown.stderr)

        try writeIgnoreFile("*.txt\n")
        let fromFile = try Recette.run(["root", "ignore", "remove", scratch.label, "*.txt"],
                                       database: database)
        XCTAssertEqual(fromFile.status, 64, fromFile.describe)
        XCTAssertTrue(fromFile.stderr.contains(".fouineignore"), fromFile.stderr)
        XCTAssertEqual(try String(contentsOf: scratch.root.appendingPathComponent(".fouineignore"),
                                  encoding: .utf8), "*.txt\n", "le fichier n'est pas touché")
    }

    /// `root list` et `root ignore list` montrent les deux sources.
    func testBothSourcesAreListed() throws {
        try writeIgnoreFile("Archives/\n")
        let added = try Recette.run(["root", "ignore", "add", scratch.label, "*.txt"],
                                    database: database)
        XCTAssertEqual(added.status, 0, added.describe)

        let listed = try Recette.run(["root", "list", "--json"], database: database)
        XCTAssertEqual(listed.status, 0, listed.describe)
        struct Row: Decodable {
            struct Rule: Decodable { let rule: String; let source: String }
            let ignore_rules: Int
            let ignore_rule_list: [Rule]
        }
        let row = try XCTUnwrap(try JSONDecoder()
            .decode([Row].self, from: Data(listed.stdout.utf8)).first)
        XCTAssertEqual(row.ignore_rules, 2)
        XCTAssertEqual(row.ignore_rule_list.map(\.rule), ["Archives/", "*.txt"])
        XCTAssertEqual(row.ignore_rule_list.map(\.source), ["file", "settings"])

        let plain = try Recette.run(["root", "list"], database: database)
        XCTAssertTrue(plain.stdout.contains("ignore_rules=2  (file 1, settings 1)"),
                      plain.stdout)

        let rules = try Recette.run(["root", "ignore", "list", scratch.label],
                                    database: database)
        XCTAssertEqual(rules.status, 0, rules.describe)
        XCTAssertTrue(rules.stdout.contains("Archives/"), rules.stdout)
        XCTAssertTrue(rules.stdout.contains("settings"), rules.stdout)
    }

    // MARK: - mcp --folders

    /// Une étiquette qui ne nomme aucune racine est une erreur d'USAGE : le
    /// serveur refuse AVANT de parler, en nommant les vraies (§4.3, sortie 64).
    /// Sans ce contrôle, il servirait un périmètre vide et l'utilisateur ne le
    /// découvrirait qu'à sa première recherche sans résultat.
    func testAnUnknownFolderRefusesTheServerInSixtyFour() throws {
        let res = try Recette.run(["mcp", "--stdio", "--folders", "Absent"],
                                  database: database, timeout: 60)
        XCTAssertEqual(res.status, 64, res.describe)
        XCTAssertTrue(res.stderr.contains("Absent"), res.stderr)
        XCTAssertTrue(res.stderr.contains(scratch.label),
                      "le refus doit nommer les racines qui existent : \(res.stderr)")
    }

    /// Et le périmètre juste passe : le serveur démarre, `fouine_status` ne
    /// nomme que la racine servie et publie son `scope`.
    func testAServedFolderIsAnnouncedInStatus() throws {
        let session = """
            {"jsonrpc":"2.0","id":1,"method":"initialize","params":{"protocolVersion":"2025-06-18","capabilities":{},"clientInfo":{"name":"recette","version":"1"}}}
            {"jsonrpc":"2.0","id":2,"method":"tools/call","params":{"name":"fouine_status","arguments":{}}}

            """
        let stdout = try serve(["mcp", "--stdio", "--folders", scratch.label],
                               input: session)
        let line = try XCTUnwrap(stdout.split(separator: "\n")
            .first { $0.contains("\"scope\"") }, stdout)
        XCTAssertTrue(line.contains("\"folders\":[\"\(scratch.label)\"]"), String(line))
        XCTAssertTrue(line.contains("\"label\":\"\(scratch.label)\""), String(line))
    }

    /// `docs/cli.md` doit rester conforme à `--help` : une option nouvelle se
    /// documente dans le même commit (règle de la recette CLI).
    func testDocsDocumentTheNewOptions() throws {
        let repoRoot = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()   // Tests/Integration
            .deletingLastPathComponent()   // Tests
            .deletingLastPathComponent()   // racine
        let doc = try String(contentsOf: repoRoot.appendingPathComponent("docs/cli.md"),
                             encoding: .utf8)
        for arguments in [["mcp", "--help"], ["mcp", "install", "--help"]] {
            let help = try Recette.run(arguments, database: database)
            XCTAssertEqual(help.status, 0, help.describe)
            XCTAssertTrue(help.stdout.contains("--folders"),
                          "`fouine \(arguments.joined(separator: " "))` doit "
                          + "annoncer --folders : \(help.stdout)")
        }
        XCTAssertTrue(doc.contains("--folders"), "docs/cli.md doit documenter --folders")
        XCTAssertTrue(doc.contains("ignore_rules"),
                      "docs/cli.md doit documenter `root list` et ses règles")
        XCTAssertTrue(doc.contains(".fouineignore"),
                      "docs/cli.md doit renvoyer au fichier d'exclusion")
        for arguments in [["root", "ignore", "add", "--help"],
                          ["root", "ignore", "remove", "--help"],
                          ["root", "ignore", "list", "--help"]] {
            let help = try Recette.run(arguments, database: database)
            XCTAssertEqual(help.status, 0, help.describe)
            XCTAssertTrue(doc.contains("fouine \(arguments.dropLast().joined(separator: " "))"),
                          "docs/cli.md doit documenter `fouine \(arguments.dropLast().joined(separator: " "))`")
        }
        XCTAssertTrue(doc.contains("ignore_rule_list"),
                      "docs/cli.md doit documenter les sources de `root list`")
    }

    /// `Recette.run` ne sait pas écrire sur l'entrée standard, et le serveur
    /// MCP ne parle que par là : une séance se pilote donc ici, en direct. Le
    /// tube fermé vaut EOF, et le serveur doit sortir de lui-même (promesse 1
    /// de `MCPServer`) — si ce n'est pas le cas, `waitUntilExit` le dira en
    /// bloquant jusqu'au délai du test.
    private func serve(_ arguments: [String], input: String) throws -> String {
        let process = Process()
        process.executableURL = try Recette.requireBinary()
        process.arguments = arguments
        var environment = ProcessInfo.processInfo.environment
        environment["FOUINE_DB"] = database.path
        process.environment = environment
        let stdin = Pipe(), stdout = Pipe(), stderr = Pipe()
        process.standardInput = stdin
        process.standardOutput = stdout
        process.standardError = stderr
        try process.run()
        stdin.fileHandleForWriting.write(Data(input.utf8))
        try stdin.fileHandleForWriting.close()
        let data = stdout.fileHandleForReading.readDataToEndOfFile()
        _ = stderr.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        XCTAssertEqual(process.terminationStatus, 0)
        return String(decoding: data, as: UTF8.self)
    }
}
