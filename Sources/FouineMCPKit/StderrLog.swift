// StderrLog.swift — une ligne par requête, sur stderr, et RIEN du contenu.
// SPDX-License-Identifier: MIT
//
// OÙ. Sur `stderr`, parce que `stdout` ne porte que du JSON-RPC (voir
// `StdoutGuard`) et parce que la spec recommande exactement cela depuis que
// `logging/setLevel` est retiré : « log to stderr (stdio) ». Claude Desktop
// archive ce flux dans `~/Library/Logs/Claude/mcp-server-fouine.log`.
//
// QUOI. `ts level method tool duration_ms result_bytes`, et pas un mot de plus.
// **Jamais la requête, jamais un extrait, jamais un chemin de document.** Ce
// journal est écrit dans un fichier que l'utilisateur ne relit pas, par un
// programme dont tout l'objet est de lire son corpus personnel : y déverser les
// requêtes reviendrait à tenir un historique de recherche à son insu. La taille
// de la réponse et sa durée suffisent à diagnostiquer une lenteur ou une
// troncature — ce sont les deux seules pannes qu'on cherche ici.
//
// COMBIEN. `FOUINE_MCP_LOG` = `quiet` | `info` | `debug`, défaut `info`.
//   · quiet : rien, pas même le démarrage ;
//   · info  : démarrage, arrêt, une ligne par requête, les erreurs ;
//   · debug : en plus, les méthodes des notifications ignorées et l'époque
//             retenue — des noms de méthode, toujours pas de contenu.

import Foundation

public enum LogLevel: String, CaseIterable {
    case quiet, info, debug

    var rank: Int {
        switch self {
        case .quiet: return 0
        case .info: return 1
        case .debug: return 2
        }
    }
}

public final class StderrLog {

    public static let environmentVariable = "FOUINE_MCP_LOG"

    public let level: LogLevel
    private let sink: FileHandle
    private let lock = NSLock()

    public init(level: LogLevel = .info, sink: FileHandle = .standardError) {
        self.level = level
        self.sink = sink
    }

    /// Une valeur inconnue ne fait pas échouer le démarrage : elle retombe sur
    /// `info`. Un serveur qui refuse de démarrer à cause d'une variable
    /// d'environnement mal orthographiée est un serveur qui « n'apparaît pas »
    /// dans le client, sans que rien ne dise pourquoi.
    public static func level(from environment: [String: String]) -> LogLevel {
        guard let raw = environment[environmentVariable]?
                .trimmingCharacters(in: .whitespaces).lowercased(),
              !raw.isEmpty
        else { return .info }
        return LogLevel(rawValue: raw) ?? .info
    }

    /// La ligne d'une requête traitée.
    public func request(method: String, tool: String?, durationMS: Double,
                        resultBytes: Int) {
        emit(.info, [method, tool ?? "-",
                     String(format: "%.1f", durationMS), String(resultBytes)])
    }

    /// Une note de service (démarrage, arrêt, refus). `fields` ne porte jamais
    /// de contenu utilisateur.
    public func note(_ level: LogLevel, _ fields: [String]) {
        emit(level, fields)
    }

    private func emit(_ required: LogLevel, _ fields: [String]) {
        guard level.rank >= required.rank, level != .quiet else { return }
        let line = ([Self.timestamp(), required.rawValue] + fields)
            .map(Self.sanitise)
            .joined(separator: " ") + "\n"
        lock.lock()
        sink.write(Data(line.utf8))
        lock.unlock()
    }

    /// Un champ ne peut couper ni la ligne ni la colonne : un nom de méthode
    /// venu d'un client reste une donnée, même dans un journal. Les sauts de
    /// ligne disparaissent ; un champ qui porte une espace est mis entre
    /// guillemets plutôt que déformé — le chemin de la base en contient une
    /// (`Application Support`), et un journal qui écrit
    /// `Application_Support` fait perdre dix minutes à qui le colle dans un
    /// terminal.
    private static func sanitise(_ field: String) -> String {
        var cleaned = field.map { character -> Character in
            character == "\n" || character == "\r" || character == "\t" ? " " : character
        }
        if cleaned.isEmpty { return "-" }
        if cleaned.count > 200 { cleaned = Array(cleaned.prefix(200)) }
        let text = String(cleaned)
        guard text.contains(" ") || text.contains("\"") else { return text }
        return "\"" + text.replacingOccurrences(of: "\"", with: "'") + "\""
    }

    private static let formatter: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime]
        f.timeZone = TimeZone(secondsFromGMT: 0)
        return f
    }()

    static func timestamp(_ date: Date = Date()) -> String {
        formatter.string(from: date)
    }
}
