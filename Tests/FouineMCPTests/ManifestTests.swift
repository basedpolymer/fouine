// ManifestTests.swift — le manifeste `.mcpb` contre le serveur réel.
// SPDX-License-Identifier: LicenseRef-Fouine-Source-Available
//
// POURQUOI CE TEST. `Packaging/mcpb/manifest.json` est ce que Claude Desktop
// lit AVANT de lancer quoi que ce soit : c'est lui qui décide de la commande,
// des arguments, de la variable d'environnement, et c'est lui qui affiche la
// liste des outils dans l'écran d'installation. Rien, au moment de
// l'empaquetage, ne le confronte au serveur — un outil renommé, une description
// réécrite, et l'extension annoncerait à l'utilisateur des capacités que le
// binaire n'a plus. Le manifeste étant un FICHIER JSON figé, cette dérive est
// silencieuse par construction. Ce test est la seule chose qui la fasse rougir.
//
// Il ne relit PAS le `.mcpb` : l'archive n'existe qu'après `make mcpb`, qui
// exige un bundle signé. Il relit la source, celle qui est versionnée.

import Foundation
import XCTest
import FouineCore
import FouineMCP
import FouineMCPKit

final class ManifestTests: XCTestCase {

    private var manifestURL: URL {
        RepoPaths.root
            .appendingPathComponent("Packaging/mcpb/manifest.json")
    }

    private func manifest() throws -> [String: Any] {
        try JSONMatch.object(Data(contentsOf: manifestURL))
    }

    // MARK: - La forme du manifeste

    /// Les champs dont dépend le DÉMARRAGE. Une faute de frappe ici ne se voit
    /// qu'à l'installation, chez l'utilisateur, sous la forme d'une extension
    /// qui ne répond pas.
    func testServerConfigurationIsWhatTheBinaryExpects() throws {
        let manifest = try manifest()
        XCTAssertEqual(manifest["manifest_version"] as? String, "0.3")
        XCTAssertEqual(manifest["name"] as? String, "fouine")
        XCTAssertEqual(manifest["display_name"] as? String, "Fouine")
        // LI1 : le schéma officiel du manifeste 0.3 déclare `license` comme une
        // chaîne libre, sans énumération SPDX — un `LicenseRef-` y passe.
        XCTAssertEqual(manifest["license"] as? String, "LicenseRef-Fouine-Source-Available")

        let server = try XCTUnwrap(manifest["server"] as? [String: Any])
        XCTAssertEqual(server["type"] as? String, "binary")
        XCTAssertEqual(server["entry_point"] as? String, "bin/fouine",
                       "Packaging/mcpb.sh empaquette le binaire sous bin/fouine")

        let config = try XCTUnwrap(server["mcp_config"] as? [String: Any])
        XCTAssertEqual(config["command"] as? String, "${__dirname}/bin/fouine")
        // `--stdio` est OBLIGATOIRE : `fouine mcp` sans transport échoue en
        // validation (Sources/fouine/CommandsMCP.swift).
        XCTAssertEqual(config["args"] as? [String], ["mcp", "--stdio"])

        let env = try XCTUnwrap(config["env"] as? [String: String])
        XCTAssertEqual(env["FOUINE_DB"], "${user_config.database}")
        XCTAssertEqual(env.count, 1, "aucune autre variable ne doit être posée")
    }

    /// Le réglage utilisateur est FACULTATIF, et il doit l'être : laissé vide,
    /// `FOUINE_DB` arrive vide, et `CLI.databaseURL()` retombe sur
    /// l'emplacement standard (`!override.isEmpty`). Rendre le champ requis
    /// obligerait chacun à aller chercher un chemin dans `~/Library`.
    func testDatabaseUserConfigIsOptional() throws {
        let manifest = try manifest()
        let userConfig = try XCTUnwrap(manifest["user_config"] as? [String: Any])
        let database = try XCTUnwrap(userConfig["database"] as? [String: Any])
        XCTAssertEqual(database["type"] as? String, "file")
        XCTAssertEqual(database["required"] as? Bool, false)
        XCTAssertNotNil(database["title"] as? String)
        XCTAssertNotNil(database["description"] as? String)
    }

    /// Une seule valeur de version dans le dépôt — comme `make check-version`
    /// pour `VERSION` et `Version.swift`. Un manifeste resté en arrière
    /// s'installerait sans un mot et n'annoncerait jamais sa mise à jour.
    func testVersionMatchesTheRepository() throws {
        let manifest = try manifest()
        let file = try String(contentsOf: RepoPaths.root.appendingPathComponent("VERSION"),
                              encoding: .utf8)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        XCTAssertEqual(manifest["version"] as? String, file)
        XCTAssertEqual(manifest["version"] as? String, FouineVersion.string)
    }

    // MARK: - Les outils annoncés contre les outils servis

    /// Le contrôle qui compte : la liste du manifeste est-elle CELLE que
    /// `tools/list` rend ? Noms, ordre et descriptions — l'ordre parce que
    /// c'est celui que l'écran d'installation affiche, et qu'il est le même
    /// parcours que celui figé par `Transcripts/tools-list.jsonl`.
    func testToolsMatchWhatTheServerAdvertises() throws {
        let index = try TempIndex()
        let server = try index.makeServer()

        _ = server.handle(Data("""
            {"jsonrpc":"2.0","id":1,"method":"initialize",\
            "params":{"protocolVersion":"2025-06-18","capabilities":{}}}
            """.utf8))
        let raw = try XCTUnwrap(
            server.handle(Data(#"{"jsonrpc":"2.0","id":2,"method":"tools/list"}"#.utf8)))
        let result = try XCTUnwrap(try JSONMatch.object(raw)["result"] as? [String: Any])
        let served = try XCTUnwrap(result["tools"] as? [[String: Any]])

        let manifest = try manifest()
        let declared = try XCTUnwrap(manifest["tools"] as? [[String: Any]])

        XCTAssertEqual(declared.map { $0["name"] as? String },
                       served.map { $0["name"] as? String },
                       "les outils du manifeste et ceux de tools/list diffèrent — "
                       + "mettez Packaging/mcpb/manifest.json à jour")

        for (declaredTool, servedTool) in zip(declared, served) {
            let name = servedTool["name"] as? String ?? "?"
            XCTAssertEqual(declaredTool["description"] as? String,
                           servedTool["description"] as? String,
                           "\(name) : description du manifeste ≠ description servie")
            XCTAssertEqual(Set(declaredTool.keys), ["name", "description"],
                           "\(name) : le manifeste ne porte que name et description ; "
                           + "les schémas restent la propriété du serveur")
        }
    }
}
