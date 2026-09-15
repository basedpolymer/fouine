// CommandsMCP.swift — `fouine mcp --stdio` (palier 4, D2 § 5).
// SPDX-License-Identifier: LicenseRef-Fouine-Source-Available
//
// AJOUT au contrat gelé du §4.3, pas modification : on ajoute une sous-commande,
// on n'en renomme aucune, et aucune sortie existante ne change.
//
// CETTE COMMANDE N'OUVRE PAS LA BASE COMME LES AUTRES. `CLI.openStore()` ouvre
// en lecture-écriture, installe un `ExclusiveLock` et CRÉE la base si elle
// manque : c'est exactement ce qu'un serveur MCP ne doit jamais faire. On passe
// par `MCPServer`, qui ouvre en `query_only` et ne crée ni ne modifie rien
// (D2 § 5.2).
//
// `--stdio` EST OBLIGATOIRE, alors qu'il n'y a pas d'autre transport
// aujourd'hui. Le jour où il y en aura un — HTTP en flux, si jamais —, une
// invocation sans transport devrait déjà avoir été une erreur ; l'exiger
// maintenant coûte une ligne et évite d'avoir à choisir un défaut plus tard.
// Son absence est une erreur d'USAGE : code 64, comme tout le §4.3.

import Foundation
import ArgumentParser
import FouineCore
import FouineMCP
import FouineMCPKit

struct MCPCommand: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "mcp",
        abstract: "Serve the index to an MCP client (Claude, Cursor, Codex, Antigravity…).",
        discussion: """
            Read-only Model Context Protocol server, speaking JSON-RPC over \
            standard input and output. It never writes to the index, never \
            starts an indexing pass, and never returns the original files.

            To configure your clients in one go (see `fouine mcp install --help`):
              fouine mcp install
            Claude Code, by hand:
              claude mcp add --scope user fouine -- /usr/local/bin/fouine mcp --stdio

            --folders restricts the server to some of the indexed roots: \
            anything else is invisible to it, including by doc_id. To keep a \
            folder out of the index altogether, use `fouine root ignore add` \
            or a .fouineignore file at the top of the root (see docs/formats.md).

            The log goes to standard error only; FOUINE_MCP_LOG=quiet|info|debug \
            sets how much of it. See docs/mcp.md.
            """,
        subcommands: [MCPInstallCommand.self])

    @Flag(name: .long,
          help: "Speak MCP on standard input and output. Required (it is the only transport).")
    var stdio = false

    @Option(name: .long,
            help: "Index to serve. Defaults to FOUINE_DB, then the standard location.")
    var db: String?

    @Option(name: .long, parsing: .upToNextOption,
            help: ArgumentHelp(
                "Only serve these roots, by label, separated by commas "
                + "(for example: --folders Livres,M2SU). Repeatable. Everything "
                + "else is invisible to this server, including by doc_id.",
                valueName: "labels"))
    var folders: [String] = []

    /// Les étiquettes, virgules dépliées et espaces retirés. L'option est
    /// RÉPÉTABLE en plus d'accepter des virgules : les deux formes circulent
    /// dans les configurations de clients, et n'en accepter qu'une ne se
    /// remarquerait qu'au moment où le serveur sert plus qu'il ne devait.
    var wantedFolders: [String] {
        folders.flatMap { $0.split(separator: ",") }
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
    }

    func run() {
        guard stdio else {
            CLI.fail("Error: fouine mcp needs a transport: pass --stdio "
                + "(it is the transport every MCP client uses for a local server).")
            Foundation.exit(64)
        }
        signal(SIGPIPE, SIG_IGN)
        CLI.guarded {
            // ORDRE CRITIQUE. Le garde-fou de `stdout` s'installe AVANT tout le
            // reste : à partir d'ici, tout `print` du programme — le nôtre, ou
            // celui d'une bibliothèque — part dans /dev/null au lieu de casser
            // le flux MCP.
            let guarded = try StdoutGuard.install()

            let url = db.map { URL(fileURLWithPath: ($0 as NSString).expandingTildeInPath) }
                ?? CLI.databaseURL()
            let level = StderrLog.level(from: ProcessInfo.processInfo.environment)
            // AUCUNE SORTIE EN 3 AVANT `initialize` (CM-07). Ce constructeur
            // n'ouvre plus la base : un index absent, d'un schéma plus récent
            // ou dont le journal d'écriture attend un écrivain se dit
            // désormais par un `isError` d'outil, sur une connexion qui tient,
            // et non par un processus qui meurt sans que le client puisse
            // afficher autre chose que « serveur déconnecté ».
            let wanted = wantedFolders
            // UN REFUS AVANT DE PARLER (lot IG1), quand la base est lisible
            // MAINTENANT : une étiquette mal orthographiée est une erreur
            // d'USAGE (§4.3, sortie 64). Sans ce contrôle, `--folders Livre`
            // rendrait un serveur qui ne sert rien, et l'utilisateur ne le
            // découvrirait qu'à sa première recherche vide.
            //
            // Base ILLISIBLE au lancement : on ne refuse pas — l'ouverture est
            // paresseuse (CM-07), et c'est chaque outil qui dira la phrase, sur
            // une connexion qui tient.
            if !wanted.isEmpty,
               let refusal = MCPCommand.scopeRefusal(databaseURL: url, folders: wanted) {
                CLI.fail("Error: " + refusal)
                Foundation.exit(64)
            }

            let server = MCPServer(
                options: .init(databaseURL: url, logLevel: level,
                               folders: wanted.isEmpty ? nil : wanted),
                version: FouineVersion.string)
            server.logStartup(version: FouineVersion.string)

            server.run(transport: LineTransport(input: STDIN_FILENO,
                                                output: guarded.output.fileDescriptor))
        }
    }

    /// `nil` si le périmètre nomme des racines qui existent — ou si la base
    /// n'est pas lisible, auquel cas il n'y a rien à contredire (la règle de
    /// `FolderCheck` : on ne refuse que ce qu'on peut contredire).
    ///
    /// La base est ouverte en LECTURE SEULE, sans verrou et sans création : ce
    /// contrôle ne doit pas être la chose qui fabrique un index.
    static func scopeRefusal(databaseURL: URL, folders: [String]) -> String? {
        let probe = ReadOnlyStore(path: databaseURL, folders: folders)
        guard (try? probe.ensureOpen()) != nil else { return nil }
        return probe.scopeRefusal()
    }
}

// MARK: - fouine mcp install

struct MCPInstallCommand: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "install",
        abstract: "Configure MCP clients (Claude Desktop, Claude Code, Cursor, Codex, Antigravity).",
        discussion: """
            Configures local MCP clients to use Fouine as an MCP server: \
            Claude Desktop (claude_desktop_config.json), Claude Code (claude \
            mcp add), Cursor (~/.cursor/mcp.json), Codex (~/.codex/config.toml) \
            and Antigravity (~/.gemini/config/mcp_config.json). A client that \
            is not installed is skipped; other servers and settings are kept.

            If `fouine` is not on your PATH, the command line ships inside the \
            application:
              /Applications/Fouine.app/Contents/Helpers/fouine mcp install

            By default, inspects and configures all supported clients. \
            Points to /usr/local/bin/fouine if it exists and resolves to the \
            current binary, preserving configuration across app updates. \
            No administrator password is needed.
            """)

    @Option(name: .long,
            help: "Target client: \(MCPClientTarget.helpList).")
    var client: String = "all"

    @Option(name: .long, parsing: .upToNextOption,
            help: ArgumentHelp(
                "Write --folders into each client configuration, so the server "
                + "only ever serves these roots. Without it, a scope already "
                + "written in a configuration is kept.",
                valueName: "labels"))
    var folders: [String] = []

    @Flag(name: .customLong("dry-run"),
          help: "Show what would be written without modifying any file.")
    var dryRun = false

    @Flag(name: .customLong("print"),
          help: ArgumentHelp(
            "Print the server entry (command and arguments) for a client "
            + "that is not listed, and write nothing. With --json, a single "
            + "object {\"command\", \"args\"}."))
    var printEntry = false

    @Flag(name: .long, help: "JSON output.")
    var json = false

    func validate() throws {
        guard MCPClientTarget(rawValue: client) != nil else {
            throw ValidationError("Unknown client '\(client)': must be one of \(MCPClientTarget.helpList).")
        }
    }

    /// `--folders` tel que la ligne de commande le porte APRÈS `install`.
    ///
    /// La commande parente `mcp` déclare la même option, et ArgumentParser la
    /// lui attribue quel que soit l'endroit où elle apparaît : `folders` ici
    /// restait VIDE, et depuis le lot IG1 `fouine mcp install --folders …`
    /// n'écrivait aucun périmètre — sans que rien ne le dise, puisque la
    /// recette ne passait que par `--help`. On relit donc la ligne, à partir
    /// du mot `install`, en acceptant `--folders A,B`, `--folders A B` et
    /// `--folders=A,B`. L'option reste déclarée : c'est elle que `--help`
    /// montre et qui valide la syntaxe.
    static func foldersOnCommandLine(_ arguments: [String] = CommandLine.arguments) -> [String] {
        guard let start = arguments.firstIndex(of: "install") else { return [] }
        var collected: [String] = []
        var index = start + 1
        while index < arguments.count {
            let arg = arguments[index]
            if arg == "--folders" {
                index += 1
                while index < arguments.count, !arguments[index].hasPrefix("-") {
                    collected.append(arguments[index])
                    index += 1
                }
                continue
            }
            if arg.hasPrefix("--folders=") {
                collected.append(String(arg.dropFirst("--folders=".count)))
            }
            index += 1
        }
        return collected.flatMap { $0.split(separator: ",") }
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
    }

    func run() {
        let target = MCPClientTarget(rawValue: client)!
        let parsed = folders.flatMap { $0.split(separator: ",") }
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
        let wantedFolders = parsed.isEmpty ? Self.foldersOnCommandLine() : parsed

        // `--print` : l'entrée générique, pour un client que la commande ne
        // connaît pas. Ni `--dry-run` ni `--client` ne rendent ce service : le
        // premier saute un client dont le dossier manque, et un assistant sur
        // un Mac sans Claude Desktop n'obtiendrait rien à recopier.
        if printEntry {
            let resolution = MCPClientConfigurator.resolveBinary()
            let args = MCPClientConfigurator.serverArgs(folders: wantedFolders)
            let entry: [String: Any] = ["command": resolution.path, "args": args]
            if json {
                do { try CLI.printJSON(entry) } catch {
                    CLI.fail("fouine: failed to encode JSON: \(error)")
                    Foundation.exit(1)
                }
            } else {
                Swift.print("binary: \(resolution.path) (\(resolution.reason))")
                Swift.print("command line: \(([resolution.path] + args).joined(separator: " "))")
                Swift.print("entry for an mcpServers-style configuration (Claude Desktop, Cursor, Antigravity, Gemini CLI, Windsurf…):")
                let wrapped: [String: Any] = ["mcpServers": ["fouine": entry]]
                if let data = try? JSONSerialization.data(
                    withJSONObject: wrapped,
                    options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]) {
                    Swift.print(String(decoding: data, as: UTF8.self))
                }
                Swift.print("table for a TOML configuration (Codex):")
                Swift.print(MCPClientConfigurator.codexBlock(binaryPath: resolution.path, args: args),
                            terminator: "")
            }
            return
        }

        let homeURL: URL = {
            if let homeEnv = ProcessInfo.processInfo.environment["HOME"], !homeEnv.isEmpty {
                return URL(fileURLWithPath: (homeEnv as NSString).expandingTildeInPath)
            }
            return FileManager.default.homeDirectoryForCurrentUser
        }()

        let (resolution, reports) = MCPClientConfigurator.install(
            target: target,
            homeURL: homeURL,
            folders: wantedFolders,
            dryRun: dryRun
        )

        if json {
            let jsonPayload = reports.map { $0.result.json }
            do {
                try CLI.printJSON(jsonPayload)
            } catch {
                CLI.fail("fouine: failed to encode JSON: \(error)")
                Foundation.exit(1)
            }
        } else {
            print("binary: \(resolution.path) (\(resolution.reason))")
            for (report, previewJSON) in reports {
                switch report.status {
                case .installed:
                    print("\(report.client): \(report.reason)")
                case .already:
                    print("\(report.client): \(report.reason)")
                case .skipped:
                    print("\(report.client): skipped (\(report.reason))")
                    if report.client == "claude-code" {
                        print("  To configure manually, run:")
                        print("  claude mcp add --scope user fouine -- \(resolution.path) mcp --stdio")
                    }
                case .dryRun:
                    print("\(report.client): \(report.reason)")
                    if let preview = previewJSON {
                        // Le chemin visé, puis la SEULE entrée écrite. Le
                        // document fusionné ne s'imprime plus : il portait les
                        // jetons d'API des autres serveurs MCP (CM-08).
                        if let path = report.path { print("would write: \(path)") }
                        print(preview)
                    }
                case .failed:
                    print("\(report.client): failed (\(report.reason))")
                }
            }
        }

        let successCount = reports.filter {
            $0.result.status == .installed || $0.result.status == .already || $0.result.status == .dryRun
        }.count

        if successCount == 0 {
            Foundation.exit(1)
        }
    }
}
