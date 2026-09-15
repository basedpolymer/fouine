// ClientConfig.swift — Configuration automatique des clients MCP (R-18).
// SPDX-License-Identifier: LicenseRef-Fouine-Source-Available

import Foundation

/// État de la configuration d'un client MCP.
public enum ClientConfigStatus: String, Sendable, Codable {
    case installed
    case already
    case skipped
    case dryRun = "dry_run"
    case failed
}

/// Identifiant du client cible.
public enum MCPClientTarget: String, CaseIterable, Sendable {
    case all
    case claudeDesktop = "claude-desktop"
    case claudeCode = "claude-code"
    case cursor
    case codex
    case antigravity

    public var displayName: String { rawValue }

    /// Les clients configurés par `--client all`, dans l'ordre d'impression.
    public static let concrete: [MCPClientTarget] = [
        .claudeDesktop, .claudeCode, .cursor, .codex, .antigravity,
    ]

    /// La liste telle que `--help` et le refus d'un nom inconnu l'énoncent.
    public static let helpList: String =
        ([MCPClientTarget.all] + concrete).map(\.rawValue).joined(separator: ", ")

    /// Le nom de l'application, pour « … is not installed ».
    public var productName: String {
        switch self {
        case .all: return "all clients"
        case .claudeDesktop: return "Claude Desktop"
        case .claudeCode: return "Claude Code"
        case .cursor: return "Cursor"
        case .codex: return "Codex"
        case .antigravity: return "Antigravity"
        }
    }
}

/// Résultat de configuration pour un client donné.
public struct ClientConfigResult: Sendable, Codable, Equatable {
    public let client: String
    public let status: ClientConfigStatus
    public let path: String?
    public let reason: String

    public init(client: String, status: ClientConfigStatus, path: String?, reason: String) {
        self.client = client
        self.status = status
        self.path = path
        self.reason = reason
    }

    public var json: [String: Any] {
        var dict: [String: Any] = [
            "client": client,
            "status": status.rawValue,
            "reason": reason,
        ]
        if let path {
            dict["path"] = path
        } else {
            dict["path"] = NSNull()
        }
        return dict
    }
}

/// Résolution du binaire à inscrire dans les configurations clientes.
public struct BinaryResolution: Sendable, Equatable {
    public let path: String
    public let isSymlink: Bool
    public let reason: String

    public init(path: String, isSymlink: Bool, reason: String) {
        self.path = path
        self.isSymlink = isSymlink
        self.reason = reason
    }
}

/// Logique pure d'inspection et de configuration des clients MCP.
public enum MCPClientConfigurator {

    public typealias CommandRunner = @Sendable (
        _ executable: String,
        _ arguments: [String]
    ) throws -> (status: Int32, stdout: String, stderr: String)

    public static let defaultCommandRunner: CommandRunner = { executable, arguments in
        let process = Process()
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = arguments
        let outPipe = Pipe()
        let errPipe = Pipe()
        process.standardOutput = outPipe
        process.standardError = errPipe
        try process.run()
        process.waitUntilExit()
        let outData = outPipe.fileHandleForReading.readDataToEndOfFile()
        let errData = errPipe.fileHandleForReading.readDataToEndOfFile()
        return (
            status: process.terminationStatus,
            stdout: String(decoding: outData, as: UTF8.self),
            stderr: String(decoding: errData, as: UTF8.self)
        )
    }

    /// Résout le chemin du binaire à inscrire :
    /// `/usr/local/bin/fouine` s'il existe et désigne (après résolution) le binaire courant,
    /// car c'est le lien symbolique qui survit aux mises à jour de l'application.
    /// Sinon, le chemin du binaire courant lui-même.
    ///
    /// `reason` DIT POURQUOI, IL NE REDIT PAS LE CHEMIN (constat CM-25) : il
    /// voyage à côté de `path`, que l'appelant imprime déjà — « binary: <path>
    /// (<reason>) » côté CLI, deux clés séparées côté `--json`. Le répéter
    /// produisait « binary: /Users/…/fouine (/Users/…/fouine (/usr/local/bin/
    /// fouine points to a different binary: …)) », parenthèses emboîtées
    /// comprises.
    public static func resolveBinary(
        currentExecutableURL: URL? = Bundle.main.executableURL ?? CommandLine.arguments.first.map { URL(fileURLWithPath: $0) },
        usrLocalBinURL: URL = URL(fileURLWithPath: "/usr/local/bin/fouine"),
        fileManager: FileManager = .default
    ) -> BinaryResolution {
        guard let currentExec = currentExecutableURL else {
            return BinaryResolution(
                path: usrLocalBinURL.path,
                isSymlink: false,
                reason: "could not determine current executable; defaulting to \(usrLocalBinURL.path)"
            )
        }
        let currentCanonical = currentExec.resolvingSymlinksInPath().path
        if fileManager.fileExists(atPath: usrLocalBinURL.path) {
            let symlinkCanonical = usrLocalBinURL.resolvingSymlinksInPath().path
            if symlinkCanonical == currentCanonical {
                return BinaryResolution(
                    path: usrLocalBinURL.path,
                    isSymlink: true,
                    reason: "/usr/local/bin/fouine (survives application updates)"
                )
            } else {
                return BinaryResolution(
                    path: currentExec.path,
                    isSymlink: false,
                    reason: "/usr/local/bin/fouine points to a different binary: \(symlinkCanonical)"
                )
            }
        } else {
            return BinaryResolution(
                path: currentExec.path,
                isSymlink: false,
                reason: "/usr/local/bin/fouine does not exist"
            )
        }
    }

    /// Recherche un exécutable dans le PATH.
    public static func findExecutableOnPath(
        _ name: String,
        pathEnv: String? = ProcessInfo.processInfo.environment["PATH"],
        fileManager: FileManager = .default
    ) -> String? {
        guard let pathEnv, !pathEnv.isEmpty else { return nil }
        for dir in pathEnv.split(separator: ":") {
            let candidate = URL(fileURLWithPath: String(dir)).appendingPathComponent(name).path
            if fileManager.isExecutableFile(atPath: candidate) {
                return candidate
            }
        }
        return nil
    }

    /// Les arguments écrits dans la configuration d'un client (lot IG1).
    /// `--folders` est ÉCRIT LÀ et nulle part ailleurs : c'est la seule façon
    /// qu'un périmètre survive au redémarrage du client, qui relance le
    /// serveur lui-même avec cette ligne.
    public static func serverArgs(folders: [String]) -> [String] {
        let kept = folders.filter { !$0.isEmpty }
        guard !kept.isEmpty else { return ["mcp", "--stdio"] }
        return ["mcp", "--stdio", "--folders", kept.joined(separator: ",")]
    }

    /// Le périmètre lu dans une configuration DÉJÀ écrite, `nil` s'il n'y en a
    /// pas. Un `fouine mcp install` sans `--folders` ne doit pas effacer le
    /// périmètre que l'utilisateur avait posé : il le relit et le réécrit.
    public static func folders(inArgs args: [String]) -> [String]? {
        guard let index = args.firstIndex(of: "--folders"),
              index + 1 < args.count else { return nil }
        let kept = args[index + 1].split(separator: ",")
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
        return kept.isEmpty ? nil : kept
    }

    /// Configure un client basé sur un fichier JSON (`claude_desktop_config.json` ou `~/.cursor/mcp.json`).
    public static func configureJSONClient(
        clientName: String,
        directoryURL: URL,
        configFileURL: URL,
        backupExtension: String = "fouine-bak",
        binaryPath: String,
        folders: [String] = [],
        dryRun: Bool,
        fileManager: FileManager = .default
    ) -> (result: ClientConfigResult, previewJSON: String?) {
        var isDir: ObjCBool = false
        guard fileManager.fileExists(atPath: directoryURL.path, isDirectory: &isDir), isDir.boolValue else {
            return (
                ClientConfigResult(
                    client: clientName,
                    status: .skipped,
                    path: configFileURL.path,
                    reason: notInstalledReason(clientName)
                ),
                nil
            )
        }

        var root: [String: Any] = [:]
        if fileManager.fileExists(atPath: configFileURL.path) {
            guard let data = try? Data(contentsOf: configFileURL) else {
                return (
                    ClientConfigResult(
                        client: clientName,
                        status: .failed,
                        path: configFileURL.path,
                        reason: "cannot read \(configFileURL.path)"
                    ),
                    nil
                )
            }
            guard let parsed = try? JSONSerialization.jsonObject(with: data, options: []),
                  let parsedDict = parsed as? [String: Any] else {
                return (
                    ClientConfigResult(
                        client: clientName,
                        status: .failed,
                        path: configFileURL.path,
                        reason: "invalid JSON in \(configFileURL.path)"
                    ),
                    nil
                )
            }
            root = parsedDict
        }

        var mcpServers = (root["mcpServers"] as? [String: Any]) ?? [:]
        let existingArgs = (mcpServers["fouine"] as? [String: Any])?["args"] as? [String]
        // Périmètre demandé, ou CELUI QUI EST DÉJÀ ÉCRIT : une réinstallation
        // (mise à jour de l'application, changement de chemin du binaire) ne
        // doit pas rouvrir en grand un serveur que l'utilisateur avait
        // restreint.
        let wantedFolders = folders.filter { !$0.isEmpty }.isEmpty
            ? (existingArgs.flatMap { Self.folders(inArgs: $0) } ?? [])
            : folders
        let wantedArgs = serverArgs(folders: wantedFolders)
        if let existingFouine = mcpServers["fouine"] as? [String: Any],
           let existingCmd = existingFouine["command"] as? String, existingCmd == binaryPath,
           let existingArgs, existingArgs == wantedArgs {
            return (
                ClientConfigResult(
                    client: clientName,
                    status: .already,
                    path: configFileURL.path,
                    reason: wantedFolders.isEmpty
                        ? "already configured"
                        : "already configured (serving "
                            + wantedFolders.joined(separator: ", ") + ")"
                ),
                nil
            )
        }

        // Les AUTRES clés d'une entrée déjà là survivent : un `env` posé à la
        // main (`FOUINE_DB`), le `disabled: false` qu'Antigravity écrit
        // lui-même. On ne remplace que la commande et ses arguments.
        var fouineEntry = (mcpServers["fouine"] as? [String: Any]) ?? [:]
        fouineEntry["command"] = binaryPath
        fouineEntry["args"] = wantedArgs
        mcpServers["fouine"] = fouineEntry
        root["mcpServers"] = mcpServers

        guard let updatedData = try? JSONSerialization.data(
            withJSONObject: root,
            options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        ) else {
            return (
                ClientConfigResult(
                    client: clientName,
                    status: .failed,
                    path: configFileURL.path,
                    reason: "failed to serialize JSON"
                ),
                nil
            )
        }

        let resultingJSON = String(decoding: updatedData, as: UTF8.self)

        if dryRun {
            // L'APERÇU NE MONTRE QUE CE QU'ON ÉCRIT (constat CM-08). Il
            // imprimait le document FUSIONNÉ tout entier : `mcpServers` est
            // précisément l'endroit où les AUTRES serveurs MCP rangent leurs
            // jetons d'API (bloc `env`), et sur la machine du mainteneur la
            // sortie portait aussi deux UUID de compte, l'identifiant des
            // navigateurs appairés et les chemins de travail. Or `--dry-run`
            // est exactement ce qu'on colle dans un rapport de bogue — la CLI
            // et SECURITY.md y encouragent.
            return (
                ClientConfigResult(
                    client: clientName,
                    status: .dryRun,
                    path: configFileURL.path,
                    reason: "would update configuration in \(configFileURL.path)"
                ),
                preview(entry: fouineEntry)
            )
        }

        do {
            // Sauvegarde préalable si le fichier existait déjà
            if fileManager.fileExists(atPath: configFileURL.path) {
                let backupURL = configFileURL.appendingPathExtension(backupExtension)
                if fileManager.fileExists(atPath: backupURL.path) {
                    try fileManager.removeItem(at: backupURL)
                }
                try fileManager.copyItem(at: configFileURL, to: backupURL)
            }

            // Écriture atomique : fichier temporaire dans le même dossier + remplacement
            let tempURL = directoryURL.appendingPathComponent(".fouine-cfg-tmp-\(UUID().uuidString)")
            try updatedData.write(to: tempURL)

            if fileManager.fileExists(atPath: configFileURL.path) {
                _ = try fileManager.replaceItemAt(configFileURL, withItemAt: tempURL, backupItemName: nil, options: [])
            } else {
                try fileManager.moveItem(at: tempURL, to: configFileURL)
            }

            return (
                ClientConfigResult(
                    client: clientName,
                    status: .installed,
                    path: configFileURL.path,
                    reason: "installed in \(configFileURL.path)"
                ),
                // Même règle qu'en `--dry-run`, et pour la même raison : ce
                // second canal n'est imprimé par personne aujourd'hui, mais il
                // rendait le document fusionné à qui l'appellerait.
                preview(entry: fouineEntry)
            )
        } catch {
            return (
                ClientConfigResult(
                    client: clientName,
                    status: .failed,
                    path: configFileURL.path,
                    reason: "failed to write \(configFileURL.path): \(error.localizedDescription)"
                ),
                nil
            )
        }
    }

    /// L'aperçu : `{"mcpServers": {"fouine": {…}}}`, la SEULE entrée que
    /// `mcp install` écrit — jamais le document fusionné (CM-08).
    static func preview(entry: [String: Any]) -> String {
        let wrapped: [String: Any] = ["mcpServers": ["fouine": entry]]
        guard let data = try? JSONSerialization.data(
            withJSONObject: wrapped,
            options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes])
        else { return "{\"mcpServers\": {\"fouine\": {}}}" }
        return String(decoding: data, as: UTF8.self)
    }

    static func notInstalledReason(_ clientName: String) -> String {
        let product = MCPClientTarget(rawValue: clientName)?.productName ?? clientName
        return "\(product) is not installed"
    }

    // MARK: - Codex (TOML)

    /// La table que `mcp install` écrit dans `~/.codex/config.toml`. Codex
    /// (CLI, application, extension VS Code) lit tous le même fichier ; la
    /// forme est celle de `codex mcp add <name> -- <command> <args>`.
    public static func codexBlock(binaryPath: String, args: [String]) -> String {
        let quotedArgs = args.map(tomlBasicString).joined(separator: ", ")
        return "[mcp_servers.fouine]\ncommand = \(tomlBasicString(binaryPath))\nargs = [\(quotedArgs)]\n"
    }

    /// Une chaîne TOML « basic » : entre guillemets, `\` et `"` échappés. Un
    /// chemin d'application n'en contient jamais, mais un chemin est ce que
    /// l'utilisateur choisit.
    static func tomlBasicString(_ s: String) -> String {
        var out = "\""
        for ch in s {
            switch ch {
            case "\\": out += "\\\\"
            case "\"": out += "\\\""
            case "\n": out += "\\n"
            case "\t": out += "\\t"
            default: out.append(ch)
            }
        }
        return out + "\""
    }

    /// Une ligne d'en-tête de table TOML, `[…]` ou `[[…]]`, commentaire à part.
    private static func tomlHeader(_ line: Substring) -> String? {
        let trimmed = line.trimmingCharacters(in: .whitespaces)
        guard trimmed.hasPrefix("[") else { return nil }
        let inner = trimmed.drop(while: { $0 == "[" })
        guard let close = inner.firstIndex(of: "]") else { return nil }
        // Les segments d'une clé pointée, guillemets et espaces retirés :
        // `[mcp_servers . "fouine"]` vaut `[mcp_servers.fouine]`.
        return inner[..<close].split(separator: ".").map {
            $0.trimmingCharacters(in: .whitespaces)
                .trimmingCharacters(in: CharacterSet(charactersIn: "\"'"))
        }.joined(separator: ".")
    }

    /// Les lignes de la table `[mcp_servers.fouine]` : de son en-tête à la
    /// ligne qui précède l'en-tête suivant, quel qu'il soit. Une sous-table
    /// (`[mcp_servers.fouine.env]`) est donc HORS du bloc et survit à la
    /// réécriture — c'est là qu'un utilisateur pose `FOUINE_DB`.
    static func codexBlockRange(in lines: [Substring]) -> Range<Int>? {
        guard let start = lines.firstIndex(where: { tomlHeader($0) == "mcp_servers.fouine" })
        else { return nil }
        var end = start + 1
        while end < lines.count, tomlHeader(lines[end]) == nil { end += 1 }
        return start..<end
    }

    /// `command` et `args` lus dans le bloc, sur leur forme d'une ligne — la
    /// seule que `mcp install` et `codex mcp add` écrivent. Une forme
    /// exotique (tableau sur plusieurs lignes, chaîne littérale) ne se lit
    /// pas : le bloc passe pour différent et se réécrit, sans dommage.
    static func codexEntry(in block: ArraySlice<Substring>) -> (command: String?, args: [String]?) {
        var command: String?
        var args: [String]?
        for raw in block {
            let line = raw.trimmingCharacters(in: .whitespaces)
            guard let eq = line.firstIndex(of: "=") else { continue }
            let key = line[..<eq].trimmingCharacters(in: .whitespaces)
            let value = line[line.index(after: eq)...].trimmingCharacters(in: .whitespaces)
            switch key {
            case "command": command = tomlUnquote(value)
            case "args":
                guard value.hasPrefix("["), let close = value.lastIndex(of: "]") else { continue }
                let inner = value[value.index(after: value.startIndex)..<close]
                let parts = inner.split(separator: ",").map {
                    $0.trimmingCharacters(in: .whitespaces)
                }.filter { !$0.isEmpty }
                let parsed = parts.compactMap(tomlUnquote)
                if parsed.count == parts.count { args = parsed }
            default: break
            }
        }
        return (command, args)
    }

    private static func tomlUnquote(_ value: String) -> String? {
        guard value.count >= 2, value.hasPrefix("\""), value.hasSuffix("\"") else { return nil }
        let inner = value.dropFirst().dropLast()
        var out = ""
        var escaped = false
        for ch in inner {
            if escaped {
                switch ch {
                case "n": out.append("\n")
                case "t": out.append("\t")
                default: out.append(ch)
                }
                escaped = false
            } else if ch == "\\" {
                escaped = true
            } else {
                out.append(ch)
            }
        }
        return escaped ? nil : out
    }

    /// Configure Codex, qui lit `~/.codex/config.toml`. Pas de bibliothèque
    /// TOML dans le paquet, et pas besoin : on n'écrit qu'UNE table, on la
    /// remplace ligne à ligne si elle existe, on l'ajoute à la fin sinon, et
    /// tout le reste du fichier — modèle, approbations, autres serveurs — reste
    /// au caractère près.
    public static func configureCodex(
        directoryURL: URL,
        configFileURL: URL,
        backupExtension: String = "fouine-bak",
        binaryPath: String,
        folders: [String] = [],
        dryRun: Bool,
        fileManager: FileManager = .default
    ) -> (result: ClientConfigResult, previewJSON: String?) {
        let client = MCPClientTarget.codex.rawValue
        var isDir: ObjCBool = false
        guard fileManager.fileExists(atPath: directoryURL.path, isDirectory: &isDir), isDir.boolValue else {
            return (
                ClientConfigResult(client: client, status: .skipped, path: configFileURL.path,
                                   reason: notInstalledReason(client)),
                nil
            )
        }

        var text = ""
        if fileManager.fileExists(atPath: configFileURL.path) {
            guard let data = try? Data(contentsOf: configFileURL),
                  let read = String(data: data, encoding: .utf8) else {
                return (
                    ClientConfigResult(client: client, status: .failed, path: configFileURL.path,
                                       reason: "cannot read \(configFileURL.path)"),
                    nil
                )
            }
            text = read
        }

        let lines = text.split(separator: "\n", omittingEmptySubsequences: false)
        let range = codexBlockRange(in: lines)
        let existing = range.map { codexEntry(in: lines[$0]) }
        let wantedFolders = folders.filter { !$0.isEmpty }.isEmpty
            ? (existing?.args.flatMap { Self.folders(inArgs: $0) } ?? [])
            : folders
        let wantedArgs = serverArgs(folders: wantedFolders)
        if let existing, existing.command == binaryPath, existing.args == wantedArgs {
            return (
                ClientConfigResult(
                    client: client, status: .already, path: configFileURL.path,
                    reason: wantedFolders.isEmpty
                        ? "already configured"
                        : "already configured (serving " + wantedFolders.joined(separator: ", ") + ")"),
                nil
            )
        }

        // `mcp_servers = { … }` en table en ligne : TOML interdit d'y ajouter
        // une table `[mcp_servers.fouine]` après coup. On ne devine pas : on
        // refuse en nommant le fichier.
        if range == nil, lines.contains(where: {
            let t = $0.trimmingCharacters(in: .whitespaces)
            return t.hasPrefix("mcp_servers") && t.dropFirst("mcp_servers".count)
                .trimmingCharacters(in: .whitespaces).hasPrefix("=")
        }) {
            return (
                ClientConfigResult(
                    client: client, status: .failed, path: configFileURL.path,
                    reason: "mcp_servers is an inline table in \(configFileURL.path); "
                        + "add the fouine server there by hand"),
                nil
            )
        }

        let block = codexBlock(binaryPath: binaryPath, args: wantedArgs)
        let updated: String
        if let range {
            var kept = lines.map(String.init)
            // Les trois lignes du bloc, puis une ligne vide : avant l'en-tête
            // suivant elle sépare les tables, en fin de fichier elle vaut le
            // saut de ligne final.
            let replacement = block.split(separator: "\n").map(String.init) + [""]
            kept.replaceSubrange(range, with: replacement)
            updated = kept.joined(separator: "\n")
        } else if text.isEmpty {
            updated = block
        } else {
            let separator = text.hasSuffix("\n\n") ? "" : (text.hasSuffix("\n") ? "\n" : "\n\n")
            updated = text + separator + block
        }

        if dryRun {
            return (
                ClientConfigResult(client: client, status: .dryRun, path: configFileURL.path,
                                   reason: "would update configuration in \(configFileURL.path)"),
                block
            )
        }

        do {
            if fileManager.fileExists(atPath: configFileURL.path) {
                let backupURL = configFileURL.appendingPathExtension(backupExtension)
                if fileManager.fileExists(atPath: backupURL.path) {
                    try fileManager.removeItem(at: backupURL)
                }
                try fileManager.copyItem(at: configFileURL, to: backupURL)
            }
            let tempURL = directoryURL.appendingPathComponent(".fouine-cfg-tmp-\(UUID().uuidString)")
            try Data(updated.utf8).write(to: tempURL)
            if fileManager.fileExists(atPath: configFileURL.path) {
                _ = try fileManager.replaceItemAt(configFileURL, withItemAt: tempURL, backupItemName: nil, options: [])
            } else {
                try fileManager.moveItem(at: tempURL, to: configFileURL)
            }
            return (
                ClientConfigResult(client: client, status: .installed, path: configFileURL.path,
                                   reason: "installed in \(configFileURL.path)"),
                block
            )
        } catch {
            return (
                ClientConfigResult(client: client, status: .failed, path: configFileURL.path,
                                   reason: "failed to write \(configFileURL.path): \(error.localizedDescription)"),
                nil
            )
        }
    }

    /// Le dossier de configuration d'Antigravity : `~/.gemini/config` depuis
    /// qu'Antigravity 2.0, l'IDE et la CLI partagent un seul
    /// `mcp_config.json` ; `~/.gemini/antigravity` chez qui n'a pas migré.
    /// `nil` quand ni l'un ni l'autre n'existe.
    public static func antigravityDirectory(homeURL: URL, fileManager: FileManager = .default) -> URL? {
        let gemini = homeURL.appendingPathComponent(".gemini", isDirectory: true)
        for name in ["config", "antigravity"] {
            let dir = gemini.appendingPathComponent(name, isDirectory: true)
            var isDir: ObjCBool = false
            if fileManager.fileExists(atPath: dir.path, isDirectory: &isDir), isDir.boolValue {
                return dir
            }
        }
        return nil
    }

    /// Configure Claude Code.
    public static func configureClaudeCode(
        binaryPath: String,
        folders: [String] = [],
        dryRun: Bool,
        claudeExecutable: String?,
        commandRunner: CommandRunner = defaultCommandRunner
    ) -> ClientConfigResult {
        guard let claudePath = claudeExecutable else {
            return ClientConfigResult(
                client: "claude-code",
                status: .skipped,
                path: nil,
                reason: "claude CLI not found on PATH — run manually: claude mcp add --scope user fouine -- \(binaryPath) "
                    + serverArgs(folders: folders).joined(separator: " ")
            )
        }

        // Vérifie si le serveur fouine est déjà configuré
        if let getRes = try? commandRunner(claudePath, ["mcp", "get", "fouine"]), getRes.status == 0 {
            return ClientConfigResult(
                client: "claude-code",
                status: .already,
                path: claudePath,
                reason: "already configured"
            )
        }

        if dryRun {
            return ClientConfigResult(
                client: "claude-code",
                status: .dryRun,
                path: claudePath,
                reason: "would run: claude mcp add --scope user fouine -- \(binaryPath) "
                    + serverArgs(folders: folders).joined(separator: " ")
            )
        }

        do {
            let addRes = try commandRunner(
                claudePath,
                ["mcp", "add", "--scope", "user", "fouine", "--", binaryPath]
                    + serverArgs(folders: folders)
            )
            if addRes.status == 0 {
                return ClientConfigResult(
                    client: "claude-code",
                    status: .installed,
                    path: claudePath,
                    reason: "configured via claude mcp add"
                )
            } else {
                let err = addRes.stderr.trimmingCharacters(in: .whitespacesAndNewlines)
                return ClientConfigResult(
                    client: "claude-code",
                    status: .failed,
                    path: claudePath,
                    reason: "claude mcp add failed (exit code \(addRes.status)): \(err)"
                )
            }
        } catch {
            return ClientConfigResult(
                client: "claude-code",
                status: .failed,
                path: claudePath,
                reason: "could not execute claude: \(error.localizedDescription)"
            )
        }
    }

    /// Exécute l'installation pour l'ensemble des clients demandés.
    public static func install(
        target: MCPClientTarget,
        homeURL: URL,
        customBinaryPath: String? = nil,
        folders: [String] = [],
        dryRun: Bool = false,
        fileManager: FileManager = .default,
        commandRunner: CommandRunner = defaultCommandRunner,
        claudePathOverride: String? = nil
    ) -> (resolution: BinaryResolution, reports: [(result: ClientConfigResult, previewJSON: String?)]) {
        let resolution: BinaryResolution
        if let custom = customBinaryPath {
            resolution = BinaryResolution(path: custom, isSymlink: false, reason: "custom binary path: \(custom)")
        } else {
            resolution = resolveBinary(fileManager: fileManager)
        }

        let clientsToRun: [MCPClientTarget] = target == .all ? MCPClientTarget.concrete : [target]

        var reports: [(result: ClientConfigResult, previewJSON: String?)] = []

        for client in clientsToRun {
            switch client {
            case .claudeDesktop:
                let claudeDir = homeURL
                    .appendingPathComponent("Library/Application Support/Claude", isDirectory: true)
                let configFile = claudeDir.appendingPathComponent("claude_desktop_config.json")
                let res = configureJSONClient(
                    clientName: "claude-desktop",
                    directoryURL: claudeDir,
                    configFileURL: configFile,
                    binaryPath: resolution.path,
                    folders: folders,
                    dryRun: dryRun,
                    fileManager: fileManager
                )
                reports.append(res)

            case .claudeCode:
                let claudeExec = claudePathOverride ?? findExecutableOnPath("claude", fileManager: fileManager)
                let res = configureClaudeCode(
                    binaryPath: resolution.path,
                    folders: folders,
                    dryRun: dryRun,
                    claudeExecutable: claudeExec,
                    commandRunner: commandRunner
                )
                reports.append((res, nil))

            case .cursor:
                let cursorDir = homeURL.appendingPathComponent(".cursor", isDirectory: true)
                let configFile = cursorDir.appendingPathComponent("mcp.json")
                let res = configureJSONClient(
                    clientName: "cursor",
                    directoryURL: cursorDir,
                    configFileURL: configFile,
                    binaryPath: resolution.path,
                    folders: folders,
                    dryRun: dryRun,
                    fileManager: fileManager
                )
                reports.append(res)

            case .codex:
                let codexDir = homeURL.appendingPathComponent(".codex", isDirectory: true)
                let res = configureCodex(
                    directoryURL: codexDir,
                    configFileURL: codexDir.appendingPathComponent("config.toml"),
                    binaryPath: resolution.path,
                    folders: folders,
                    dryRun: dryRun,
                    fileManager: fileManager
                )
                reports.append(res)

            case .antigravity:
                let dir = antigravityDirectory(homeURL: homeURL, fileManager: fileManager)
                    ?? homeURL.appendingPathComponent(".gemini/config", isDirectory: true)
                let res = configureJSONClient(
                    clientName: MCPClientTarget.antigravity.rawValue,
                    directoryURL: dir,
                    configFileURL: dir.appendingPathComponent("mcp_config.json"),
                    binaryPath: resolution.path,
                    folders: folders,
                    dryRun: dryRun,
                    fileManager: fileManager
                )
                reports.append(res)

            case .all:
                break
            }
        }

        return (resolution, reports)
    }
}
