// ResultEnvelope.swift — la forme des résultats, dans les deux époques.
// SPDX-License-Identifier: MIT
//
// Deux enveloppes, un seul contenu.
//
//  · époque LEGACY (2025-06-18 et voisines, ce que Claude Code et Claude
//    Desktop parlent aujourd'hui à un serveur stdio) : `CallToolResult` porte
//    `content`, `structuredContent`, `isError`. Rien d'autre.
//  · époque MODERNE (2026-07-28) : tout résultat porte en plus `resultType`, et
//    les résultats CACHABLES (`tools/list`, `server/discover`) portent `ttlMs`
//    et `cacheScope`. `serverInfo` n'est PAS un champ de premier niveau : il
//    vit dans `_meta["io.modelcontextprotocol/serverInfo"]` (vérifié dans
//    `schema.ts` : `ResultMetaObject`).
//
// POURQUOI `content` **ET** `structuredContent`. La spec recommande de servir
// les deux : `structuredContent` est ce que valide `outputSchema`, `content`
// est ce que lisent les clients qui ne connaissent pas encore la sortie
// structurée. Le bloc texte porte donc le MÊME JSON, sérialisé — pas une
// reformulation en prose, qui divergerait au premier changement de champ.
//
// `cacheScope: "private"` et jamais `"public"` : ce que ce serveur rend dérive
// des documents personnels de l'utilisateur. Aucun intermédiaire partagé ne doit
// le mettre en cache.

import Foundation

/// Ce qu'un outil rend. `structured` est la charge utile ; `isError` dit qu'elle
/// décrit un échec MÉTIER (voir `ToolRegistry` pour la distinction avec une
/// erreur JSON-RPC).
public struct ToolResult {
    public let structured: [String: Any]
    public let isError: Bool
    /// Texte de remplacement du bloc `content`. `nil` = le JSON sérialisé.
    public let text: String?

    public init(_ structured: [String: Any], isError: Bool = false, text: String? = nil) {
        self.structured = structured
        self.isError = isError
        self.text = text
    }

    /// L'échec métier : un bloc texte, pas de `structuredContent` — celui-ci
    /// doit valider contre `outputSchema`, ce qu'un message d'erreur ne fait
    /// jamais.
    public static func failure(_ message: String) -> ToolResult {
        ToolResult([:], isError: true, text: message)
    }
}

/// Les deux régimes de réponse.
public enum ProtocolEra: Equatable {
    case legacy(version: String)
    case modern
}

public enum ResultEnvelope {

    /// Révision servie en époque moderne.
    public static let modernVersion = "2026-07-28"

    /// Révisions acceptées à l'`initialize` legacy. On rend celle que le client
    /// demande si elle est là — c'est ce que la spec appelle « répondre avec la
    /// même version » —, sinon `preferredLegacyVersion`.
    public static let legacyVersions: Set<String> =
        ["2024-11-05", "2025-03-26", "2025-06-18", "2025-11-25"]

    /// Le repli quand le client demande une révision qu'on ne connaît pas.
    /// 2025-06-18 et non la plus récente : c'est la révision que les deux
    /// clients cibles savent parler à coup sûr.
    public static let preferredLegacyVersion = "2025-06-18"

    /// Durée de vie annoncée des résultats cachables. Cinq minutes : la liste
    /// d'outils de ce serveur ne change qu'à la mise à jour du binaire.
    public static let listTTLMilliseconds = 300_000

    public static let serverInfoMetaKey = "io.modelcontextprotocol/serverInfo"
    public static let protocolVersionMetaKey = "io.modelcontextprotocol/protocolVersion"

    /// Identité du serveur (`Implementation` dans `schema.ts`).
    public struct ServerInfo {
        public let name: String
        public let title: String
        public let version: String

        public init(name: String, title: String, version: String) {
            self.name = name
            self.title = title
            self.version = version
        }

        public var json: [String: Any] {
            ["name": name, "title": title, "version": version]
        }
    }

    /// Le `CallToolResult`.
    public static func callTool(_ result: ToolResult, era: ProtocolEra,
                                serverInfo: ServerInfo) -> [String: Any] {
        let text: String
        if let explicit = result.text {
            text = explicit
        } else {
            text = serialise(result.structured)
        }
        var payload: [String: Any] = [
            "content": [["type": "text", "text": text]],
        ]
        if !result.isError { payload["structuredContent"] = result.structured }
        if result.isError { payload["isError"] = true }
        if case .modern = era {
            payload["resultType"] = "complete"
            payload["_meta"] = [serverInfoMetaKey: serverInfo.json]
        }
        return payload
    }

    /// Le `ListToolsResult`.
    public static func listTools(_ descriptors: [[String: Any]], era: ProtocolEra,
                                 serverInfo: ServerInfo) -> [String: Any] {
        var payload: [String: Any] = ["tools": descriptors]
        if case .modern = era {
            payload["resultType"] = "complete"
            payload["ttlMs"] = listTTLMilliseconds
            payload["cacheScope"] = "private"
            payload["_meta"] = [serverInfoMetaKey: serverInfo.json]
        }
        return payload
    }

    /// Le `ListResourcesResult` vide (Fouine n'expose pas de ressources).
    public static func listResources(era: ProtocolEra,
                                     serverInfo: ServerInfo) -> [String: Any] {
        var payload: [String: Any] = ["resources": [] as [Any]]
        if case .modern = era {
            payload["resultType"] = "complete"
            payload["ttlMs"] = listTTLMilliseconds
            payload["cacheScope"] = "private"
            payload["_meta"] = [serverInfoMetaKey: serverInfo.json]
        }
        return payload
    }

    /// Le `ListPromptsResult` vide (Fouine n'expose pas de prompts).
    public static func listPrompts(era: ProtocolEra,
                                   serverInfo: ServerInfo) -> [String: Any] {
        var payload: [String: Any] = ["prompts": [] as [Any]]
        if case .modern = era {
            payload["resultType"] = "complete"
            payload["ttlMs"] = listTTLMilliseconds
            payload["cacheScope"] = "private"
            payload["_meta"] = [serverInfoMetaKey: serverInfo.json]
        }
        return payload
    }

    /// Le `DiscoverResult` de la révision 2026-07-28.
    public static func discover(serverInfo: ServerInfo,
                                instructions: String?) -> [String: Any] {
        var payload: [String: Any] = [
            "supportedVersions": [modernVersion],
            "capabilities": ["tools": [String: Any]()],
            "resultType": "complete",
            "ttlMs": listTTLMilliseconds,
            "cacheScope": "private",
            "_meta": [serverInfoMetaKey: serverInfo.json],
        ]
        if let instructions { payload["instructions"] = instructions }
        return payload
    }

    /// Le `InitializeResult` de l'époque legacy.
    public static func initialize(version: String, serverInfo: ServerInfo,
                                  instructions: String?) -> [String: Any] {
        var payload: [String: Any] = [
            "protocolVersion": version,
            "capabilities": ["tools": [String: Any]()],
            "serverInfo": ["name": serverInfo.name, "title": serverInfo.title,
                           "version": serverInfo.version],
        ]
        if let instructions { payload["instructions"] = instructions }
        return payload
    }

    /// Le JSON d'un objet, tel qu'il part dans le bloc texte.
    public static func serialise(_ object: [String: Any]) -> String {
        guard let data = try? JSONSerialization.data(
                withJSONObject: object, options: JSONRPCResponse.writingOptions)
        else { return "{}" }
        return String(decoding: data, as: UTF8.self)
    }
}
