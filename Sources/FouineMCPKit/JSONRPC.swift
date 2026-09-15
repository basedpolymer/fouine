// JSONRPC.swift — le cadre JSON-RPC 2.0, écrit à la main (D2 § 5.4).
// SPDX-License-Identifier: MIT
//
// POURQUOI À LA MAIN. Le SDK Swift officiel implémente la révision 2025-11-25,
// exige `swift-tools-version 6.1` et tire CINQ dépendances dont une épinglée
// sur `branch: "main"`. Fouine tient à trois dépendances (SPEC §2.2) et vise le
// bi-époque dès le premier jour. Le cadrage stdio, lui, est identique dans
// toutes les révisions : on écrit une fois le lecteur de lignes et on branche
// deux routeurs. Coût mesuré : ce fichier.
//
// TOUT PASSE PAR `JSONSerialization`. Pas de `Codable` : les charges utiles MCP
// sont des JSON Schema et des objets hétérogènes que `[String: Any]` décrit
// mieux qu'une grappe de types génériques — et le contrat de sortie est vérifié
// par des transcriptions, pas par le compilateur.

import Foundation

// MARK: - Codes d'erreur

/// Les codes que ce serveur peut rendre. Les cinq premiers sont ceux de
/// JSON-RPC 2.0 ; `-32022` est propre à MCP (`UNSUPPORTED_PROTOCOL_VERSION`,
/// `schema.ts` de la révision 2026-07-28).
public enum JSONRPCErrorCode {
    public static let parseError = -32700
    public static let invalidRequest = -32600
    public static let methodNotFound = -32601
    public static let invalidParams = -32602
    public static let internalError = -32603
    public static let unsupportedProtocolVersion = -32022
}

/// Une erreur JSON-RPC — celle qu'on met dans `response.error`.
///
/// À NE PAS CONFONDRE avec une erreur d'OUTIL. La spec distingue les deux, et
/// la distinction est fonctionnelle : une erreur JSON-RPC dit « ta requête est
/// malformée », un `CallToolResult{isError: true}` dit « ta requête était bien
/// formée, voici pourquoi elle n'a rien donné » — et c'est cette seconde forme
/// que le modèle sait exploiter pour corriger son appel (voir `ToolRegistry`).
public struct JSONRPCError: Error, Sendable {
    public let code: Int
    public let message: String
    public let data: [String: String]?

    public init(code: Int, message: String, data: [String: String]? = nil) {
        self.code = code
        self.message = message
        self.data = data
    }

    public static func parse(_ detail: String) -> JSONRPCError {
        JSONRPCError(code: JSONRPCErrorCode.parseError, message: "Parse error",
                     data: ["reason": detail])
    }

    public static func invalidRequest(_ reason: String) -> JSONRPCError {
        JSONRPCError(code: JSONRPCErrorCode.invalidRequest,
                     message: "Invalid Request", data: ["reason": reason])
    }

    /// `data.method` porte TOUJOURS le nom de la méthode, jamais une phrase :
    /// c'est ce qu'un client corrèle. L'explication va dans `data.reason`.
    public static func methodNotFound(_ method: String,
                                      reason: String? = nil) -> JSONRPCError {
        var data = ["method": method]
        if let reason { data["reason"] = reason }
        return JSONRPCError(code: JSONRPCErrorCode.methodNotFound,
                            message: "Method not found", data: data)
    }

    /// LA RAISON EST RECOPIÉE DANS `message` (constat PM-08). La phrase utile
    /// vivait dans `data.reason` seule, et beaucoup de clients MCP ne rendent
    /// au modèle que `message` : le propriétaire a vu « Invalid params » pour
    /// un `mode: "semantic"` dont le serveur savait parfaitement dire
    /// « must be one of auto, lexical, hybrid ». Le préfixe reste, parce que
    /// c'est le libellé standard du code -32602 que les clients corrèlent ;
    /// `data.reason` reste, parce que c'est là que les clients qui le lisent
    /// vont le chercher.
    public static func invalidParams(_ reason: String) -> JSONRPCError {
        JSONRPCError(code: JSONRPCErrorCode.invalidParams,
                     message: "Invalid params: " + reason,
                     data: ["reason": reason])
    }

    public static func internalError(_ reason: String) -> JSONRPCError {
        JSONRPCError(code: JSONRPCErrorCode.internalError,
                     message: "Internal error", data: ["reason": reason])
    }

    var json: [String: Any] {
        var object: [String: Any] = ["code": code, "message": message]
        if let data { object["data"] = data }
        return object
    }
}

/// Cas particulier : la version de protocole demandée n'est pas servie.
/// `data.supported` est ce que le client doit relire pour renégocier.
public func unsupportedProtocolVersion(_ asked: String,
                                       supported: [String]) -> [String: Any] {
    ["code": JSONRPCErrorCode.unsupportedProtocolVersion,
     "message": "Unsupported protocol version",
     "data": ["requested": asked, "supported": supported] as [String: Any]]
}

// MARK: - Identifiant de requête

/// `id` d'une requête JSON-RPC : chaîne, entier, ou `null`.
///
/// Il est RENDU TEL QU'IL EST ARRIVÉ. Un client qui envoie `"id": "7"` doit
/// relire `"id": "7"`, pas `7` : la corrélation des réponses en dépend, et
/// c'est le genre de dérive qu'une transcription attrape.
public enum RequestID: Hashable, Sendable {
    case number(Int)
    case string(String)
    case null

    var json: Any {
        switch self {
        case .number(let n): return n
        case .string(let s): return s
        case .null: return NSNull()
        }
    }
}

// MARK: - Requête

/// Une requête ou une notification. `id == nil` ⇒ notification : aucune réponse
/// ne doit partir, jamais — pas même une erreur (JSON-RPC 2.0 § 4.1).
public struct JSONRPCRequest {
    public let id: RequestID?
    public let method: String
    public let params: [String: Any]

    public init(id: RequestID?, method: String, params: [String: Any] = [:]) {
        self.id = id
        self.method = method
        self.params = params
    }

    public var isNotification: Bool { id == nil }

    /// `params._meta`, l'endroit où la révision 2026-07-28 range la version de
    /// protocole et les capacités du client (`RequestMetaObject`).
    public var meta: [String: Any] {
        params["_meta"] as? [String: Any] ?? [:]
    }
}

// MARK: - Analyse

/// Ce qu'une ligne du transport peut être.
public enum ParsedLine {
    /// Une requête ou une notification exploitable.
    case request(JSONRPCRequest)
    /// La ligne est du JSON valide mais pas une requête utilisable ; il faut
    /// répondre l'erreur portée, avec l'`id` s'il a pu être récupéré.
    case malformed(id: RequestID?, error: JSONRPCError)
    /// La ligne est vide ou blanche : on l'ignore en silence.
    case blank
}

public enum JSONRPCParser {

    /// Analyse TOLÉRANTE, dans l'ordre où les erreurs comptent.
    ///
    /// Trois choix explicites :
    ///  · un TABLEAU au premier niveau (le « batch » de JSON-RPC 2.0) est refusé
    ///    en `-32600` et non traité. MCP ne l'a jamais employé, la révision
    ///    2026-07-28 est sans état, et une implémentation partielle du batch
    ///    serait pire que son absence ;
    ///  · l'`id` est récupéré AVANT toute autre validation, pour que la réponse
    ///    d'erreur soit corrélable ;
    ///  · `params` absent vaut `{}` — beaucoup de clients omettent l'objet vide
    ///    sur `tools/list` et sur `ping`.
    public static func parse(_ data: Data) -> ParsedLine {
        guard data.contains(where: { !isBlank($0) }) else { return .blank }

        let object: Any
        do { object = try JSONSerialization.jsonObject(with: data, options: [.fragmentsAllowed]) }
        catch {
            // Message FIXE, et en anglais. `localizedDescription` de
            // `JSONSerialization` est TRADUIT par Foundation : sur une machine
            // en français, un client MCP lirait « Les données n'ont pas pu être
            // lues… » dans un protocole dont tout le reste est anglais, et une
            // transcription cesserait d'être reproductible d'une machine à
            // l'autre.
            return .malformed(id: nil, error: .parse("line is not valid JSON"))
        }

        if object is [Any] {
            return .malformed(
                id: nil,
                error: .invalidRequest(
                    "JSON-RPC batches are not supported — send one request per line"))
        }
        guard let message = object as? [String: Any] else {
            return .malformed(id: nil,
                              error: .invalidRequest("a JSON-RPC message must be an object"))
        }

        let hasID = message.index(forKey: "id") != nil
        let id: RequestID? = hasID ? requestID(message["id"]) : nil
        if hasID, id == nil {
            return .malformed(id: nil,
                              error: .invalidRequest("id must be a string, an integer or null"))
        }

        if let version = message["jsonrpc"] as? String, version != "2.0" {
            return .malformed(id: id,
                              error: .invalidRequest("jsonrpc must be \"2.0\", got \"\(version)\""))
        }
        guard let method = message["method"] as? String, !method.isEmpty else {
            return .malformed(id: id, error: .invalidRequest("missing method"))
        }

        let rawParams = message["params"]
        if rawParams != nil, !(rawParams is NSNull), !(rawParams is [String: Any]) {
            return .malformed(id: id,
                              error: .invalidParams("params must be an object"))
        }
        return .request(JSONRPCRequest(id: id, method: method,
                                       params: rawParams as? [String: Any] ?? [:]))
    }

    private static func isBlank(_ byte: UInt8) -> Bool {
        byte == 0x20 || byte == 0x09 || byte == 0x0A || byte == 0x0D
    }

    private static func requestID(_ raw: Any?) -> RequestID? {
        switch raw {
        case is NSNull, nil: return .null
        case let s as String: return .string(s)
        case let n as NSNumber:
            // `true`/`false` arrivent en NSNumber : un booléen n'est pas un id.
            if CFGetTypeID(n) == CFBooleanGetTypeID() { return nil }
            guard n == NSNumber(value: n.intValue) else { return nil }
            return .number(n.intValue)
        default: return nil
        }
    }

}

// MARK: - Réponse

public enum JSONRPCResponse {

    /// Sérialisation DÉTERMINISTE : `.sortedKeys` pour que les transcriptions
    /// « golden » se comparent octet à octet quand on le veut,
    /// `.withoutEscapingSlashes` pour qu'un chemin `/Users/…` reste lisible
    /// dans un journal (et fasse la moitié de sa taille en `abs_path`).
    public static let writingOptions: JSONSerialization.WritingOptions =
        [.sortedKeys, .withoutEscapingSlashes]

    public static func success(id: RequestID?, result: [String: Any]) -> [String: Any] {
        ["jsonrpc": "2.0", "id": (id ?? .null).json, "result": result]
    }

    public static func failure(id: RequestID?, error: JSONRPCError) -> [String: Any] {
        ["jsonrpc": "2.0", "id": (id ?? .null).json, "error": error.json]
    }

    public static func failure(id: RequestID?, raw: [String: Any]) -> [String: Any] {
        ["jsonrpc": "2.0", "id": (id ?? .null).json, "error": raw]
    }

    /// Encode un message. Un objet non sérialisable est une FAUTE DE
    /// PROGRAMMATION (un `Double.nan` glissé dans une charge utile, par
    /// exemple) : plutôt que de casser le flux, on rend une erreur interne
    /// bien formée — un serveur stdio qui se tait est un serveur qu'aucun
    /// client ne sait diagnostiquer.
    public static func encode(_ message: [String: Any]) -> Data {
        if let data = try? JSONSerialization.data(withJSONObject: message,
                                                  options: writingOptions) {
            return data
        }
        let fallback = failure(id: message["id"].flatMap(RequestID.init(any:)),
                               error: .internalError("response could not be serialised"))
        return (try? JSONSerialization.data(withJSONObject: fallback,
                                            options: writingOptions))
            ?? Data(#"{"jsonrpc":"2.0","id":null,"error":{"code":-32603,"message":"Internal error"}}"#.utf8)
    }
}

extension RequestID {
    init?(any raw: Any) {
        switch raw {
        case let s as String: self = .string(s)
        case let n as NSNumber where CFGetTypeID(n) != CFBooleanGetTypeID():
            self = .number(n.intValue)
        case is NSNull: self = .null
        default: return nil
        }
    }
}
