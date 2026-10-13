// StatusTool.swift — `fouine_status` (D2 § 5.5 n° 5).
// SPDX-License-Identifier: LicenseRef-Fouine-Source-Available
//
// LE PREMIER OUTIL, et celui qu'un agent doit appeler avant les trois autres :
// il répond à « qu'est-ce que Fouine sait, au juste ? ». Un modèle qui apprend
// qu'il reste 139 638 pages en file d'OCR n'interprétera pas le silence de
// l'index comme une absence de documents.
//
// CE QUI COÛTE CHER, ET COMMENT ON L'ÉVITE. Trois sources ont été mesurées
// avant d'écrire ce fichier :
//
//   · `SELECT count(*) FROM page_fts` : **16,50 s** à froid sur la base de
//     production (contre 0,130 s sur la table d'ombre `page_fts_docsize`,
//     ×127). `stats()` ne l'appelle plus depuis le correctif C2-03 — c'est
//     vérifié en lisant `GRDBStore.stats`, pas supposé ;
//   · `launchctl print` : jusqu'à **500 ms** de délai de garde. La sonde de
//     l'agent est donc mise en cache 60 s, et l'appelant peut la couper par
//     `include_agent: false` ;
//   · l'ensemble de la charge utile est mis en cache **60 s**. Un agent qui
//     appelle `fouine_status` trois fois dans la même minute — ce qu'il fait —
//     paie une seule fois.
//
// CE QU'ON NE MET PAS DANS LA SORTIE : aucun titre de document, aucun extrait,
// aucun chemin de fichier indexé. Les chemins de RACINES y sont, parce que
// c'est ce que l'utilisateur a explicitement déclaré à Fouine et ce qui
// explique un résultat manquant.

import Foundation
import FouineCore
import FouineMCPKit

public final class StatusTool: MCPTool {

    public let name = "fouine_status"
    public let title = "Fouine index status"
    public let description =
        "Health and coverage of the Fouine index: how many documents and pages, "
        + "OCR backlog, disk budget, roots, and whether another process is "
        + "writing. Call this first: it tells you whether a folder is missing "
        + "because its volume is not mounted, and read disk_budget.level and "
        + "ocr_queue before concluding that a folder has nothing to say."

    private let store: ReadOnlyStore
    private let launchdProbe: () -> LaunchdAgentResult
    private let cacheTTL: TimeInterval
    private let now: () -> Date

    private let mutex = NSLock()
    private var cached: (payload: [String: Any], at: Date)?
    private var cachedAgent: (json: [String: Any], at: Date)?

    /// - Parameters:
    ///   - launchdProbe: injectée pour les tests, qui ne doivent ni lancer
    ///     `launchctl` ni dépendre de l'agent installé sur la machine.
    public init(store: ReadOnlyStore,
                launchdProbe: @escaping () -> LaunchdAgentResult = { LaunchdAgentProbe.run(timeout: 0.5) },
                cacheTTL: TimeInterval = 60,
                now: @escaping () -> Date = Date.init) {
        self.store = store
        self.launchdProbe = launchdProbe
        self.cacheTTL = cacheTTL
        self.now = now
    }

    // MARK: - Schémas

    public var inputSchema: [String: Any] {
        [
            "$schema": "https://json-schema.org/draft/2020-12/schema",
            "type": "object",
            "additionalProperties": false,
            "properties": [
                "include_roots": [
                    "type": "boolean", "default": true,
                    "description": "Include the list of indexed roots and their state.",
                ] as [String: Any],
                "include_agent": [
                    "type": "boolean", "default": true,
                    "description": "Include the background agent report. Costs up to "
                        + "500 ms on a cold call (it queries launchd); set it to false "
                        + "if you only need counts.",
                ] as [String: Any],
            ] as [String: Any],
        ]
    }

    public var outputSchema: [String: Any] {
        [
            "$schema": "https://json-schema.org/draft/2020-12/schema",
            "type": "object",
            "required": ["database", "documents", "pages_indexed", "read_only"],
            "properties": [
                "database": [
                    "type": "object",
                    "properties": [
                        "path": ["type": "string"],
                        "bytes": ["type": "integer"],
                        "schema_version": ["type": "integer"],
                    ] as [String: Any],
                ] as [String: Any],
                "documents": ["type": "integer"] as [String: Any],
                "scope": [
                    "type": ["object", "null"],
                    "description": "Null when the whole index is served. "
                        + "Otherwise the only roots this server serves "
                        + "(fouine mcp --folders): everything else is invisible "
                        + "to it, including by doc_id.",
                    "properties": [
                        "folders": ["type": "array",
                                    "items": ["type": "string"]] as [String: Any],
                        "note": ["type": "string"],
                    ] as [String: Any],
                ] as [String: Any],
                "pages_indexed": ["type": "integer"] as [String: Any],
                "ocr_queue": ["type": "integer"] as [String: Any],
                "roots": [
                    "type": "array",
                    "items": [
                        "type": "object",
                        "properties": [
                            "id": ["type": "integer"],
                            "label": ["type": "string"],
                            "path": ["type": ["string", "null"],
                                     "description": "Absolute path, null if the volume is not mounted."],
                            "enabled": ["type": "boolean"],
                            "volume_mounted": ["type": "boolean"],
                            "pages": ["type": "integer",
                                      "description": "Indexed pages under this root."],
                        ] as [String: Any],
                    ] as [String: Any],
                ] as [String: Any],
                "disk_budget": [
                    "type": "object",
                    "description": "What the index weighs and where the budget "
                        + "stands. Nothing stops at 100 %: level is a warning, "
                        + "not a fault.",
                    "properties": [
                        "bytes": ["type": "integer"],
                        "budget_bytes": ["type": "integer"],
                        "ratio_now": ["type": "number"],
                        "pages_at_budget": ["type": ["integer", "null"]],
                        "level": ["enum": ["ok", "near", "over"]],
                    ] as [String: Any],
                ] as [String: Any],
                "write_lock": [
                    "type": "object",
                    "description": "Another Fouine process writing to the index. Reads are "
                        + "never blocked by it.",
                    "properties": [
                        "held": ["type": "boolean"],
                        "role": ["type": ["string", "null"]],
                        "pid": ["type": ["integer", "null"]],
                        "since": ["type": ["string", "null"]],
                    ] as [String: Any],
                ] as [String: Any],
                "agent": ["type": "object"] as [String: Any],
                "read_only": [
                    "type": "boolean",
                    "description": "Always true: this server never writes to the index.",
                ] as [String: Any],
            ] as [String: Any],
        ]
    }

    // MARK: - Appel

    public func call(arguments: [String: Any]) throws -> ToolResult {
        let includeRoots = (arguments["include_roots"] as? NSNumber)?.boolValue ?? true
        let includeAgent = (arguments["include_agent"] as? NSNumber)?.boolValue ?? true

        var payload: [String: Any]
        do { payload = try snapshot() }
        catch {
            // Une panne de LECTURE est une erreur d'OUTIL, pas une erreur
            // JSON-RPC : le client garde sa session, et le message dit ce qui
            // se passe (base verrouillée, disque parti, fichier tronqué).
            return .failure("cannot read the Fouine index: " + MCPText.describe(error))
        }
        if !includeRoots { payload.removeValue(forKey: "roots") }
        payload["agent"] = includeAgent ? agentJSON() : ["queried": false]
        // HORS DU CACHE, délibérément. C'est le champ le plus volatil de la
        // sortie — et le seul dont un agent se serve pour décider s'il doit
        // réessayer. Le rendre vieux d'une minute lui ferait attendre un verrou
        // rendu depuis longtemps, ou croire libre une base qu'on vient de
        // prendre. Le coût est la lecture d'un fichier de soixante octets.
        payload["write_lock"] = writeLockJSON()
        return ToolResult(payload)
    }

    // MARK: - Instantané

    private func snapshot() throws -> [String: Any] {
        mutex.lock()
        if let cached, now().timeIntervalSince(cached.at) < cacheTTL {
            let payload = cached.payload
            mutex.unlock()
            return payload
        }
        mutex.unlock()

        let stats = try store.stats()
        let pages = stats["pages_indexed"] ?? 0

        // LE PÉRIMÈTRE (lot IG1). `documents` devient le compte DANS le
        // périmètre : c'est la seule surface où le serveur dit combien il sert,
        // et annoncer 1 883 documents quand on n'en sert que 412 ferait
        // conclure au modèle que sa recherche a manqué quelque chose.
        // `pages_indexed` reste celui de tout l'index — aucune lecture ne
        // compte les pages d'un dossier sans les parcourir — et la clé `scope`
        // le DIT, plutôt que de laisser deviner.
        let served = try store.servedFolders()
        var payload: [String: Any] = [
            "database": [
                "path": store.databaseURL.path,
                "bytes": store.databaseBytes(),
                "schema_version": (try? store.schemaVersion()) ?? Schema.version,
            ] as [String: Any],
            "scope": Self.scopeJSON(served),
            "documents": served == nil
                ? (stats["docs_total"] ?? 0)
                : try store.countDocuments(DocumentFilter()),
            "pages_indexed": pages,
            "ocr_queue": try store.ocrQueueLength(),
            "roots": try rootsJSON(),
            // PM-32 : l'objet que la ligne de commande publiait et que le
            // serveur taisait. Il ne coûte AUCUNE lecture de plus — `stats()`
            // est déjà lu ci-dessus — et c'est lui qu'un assistant doit voir
            // avant de conseiller d'indexer davantage : sur la base du
            // propriétaire, `level = "over"`.
            "disk_budget": StatusJSON.diskBudgetJSON(
                StatusJSON.diskForecast(stats: stats)),
            "read_only": true,
        ]
        payload["agent"] = [String: Any]()   // remplacé par `call`

        mutex.lock()
        cached = (payload, now())
        mutex.unlock()
        return payload
    }

    // MARK: - Morceaux

    /// Ce que le serveur a le droit de servir, ou `null` quand c'est tout
    /// l'index (lot IG1). La clé est TOUJOURS présente : une clé absente
    /// n'apprend rien, et un agent qui ne trouve pas un document doit pouvoir
    /// distinguer « il n'existe pas » de « ce serveur ne sert que ces
    /// dossiers-là ».
    private static func scopeJSON(_ served: [String]?) -> Any {
        guard let served else { return NSNull() }
        return [
            "folders": served,
            "note": "This server only serves these roots; anything else is "
                + "invisible to it. documents is the count inside this scope, "
                + "while pages_indexed still describes the whole index.",
        ] as [String: Any]
    }

    /// Les racines, avec leur chemin ABSOLU — `docs.rel_path` est relatif au
    /// volume et ne veut rien dire pour un client. Volume démonté : `path` est
    /// nul et `volume_mounted` faux, ce qui explique un index qui paraît
    /// incomplet.
    private func rootsJSON() throws -> [[String: Any]] {
        try store.roots().map { root in
            let mounted = VolumeResolver.mountPoint(forVolumeUUID: root.volUUID) != nil
            let absolute = try? VolumeResolver.absolutePath(volUUID: root.volUUID,
                                                            relPath: root.relPath)
            return [
                "id": Int(root.id),
                "label": root.label,
                "path": absolute.map { $0.path as Any } ?? NSNull(),
                "enabled": root.enabled,
                "volume_mounted": mounted,
            ]
        }
    }

    /// Le détenteur de `fouine.lock`, lu dans le fichier.
    ///
    /// Le fichier est TRONQUÉ à la libération : vide veut dire libre. Un
    /// détenteur dont le processus a disparu (plantage, `kill -9`) est rendu
    /// `held: false` — on ne nomme jamais un détenteur incertain, c'est la même
    /// règle que `LockHolder.parse`.
    private func writeLockJSON() -> [String: Any] {
        let empty: [String: Any] = ["held": false, "role": NSNull(),
                                    "pid": NSNull(), "since": NSNull()]
        guard let data = FileManager.default.contents(atPath: store.lockFileURL.path),
              !data.isEmpty,
              let holder = LockHolder.parse(String(decoding: data, as: UTF8.self)),
              holder.isAlive
        else { return empty }
        return [
            "held": true,
            "role": holder.role.rawValue,
            "pid": Int(holder.pid),
            "since": ISO8601DateFormatter().string(from: holder.since),
        ]
    }

    /// L'agent d'arrière-plan : `launchctl` croisé avec `agent_status`, comme
    /// `fouine doctor`. Cache 60 s à lui seul, parce que la sonde coûte jusqu'à
    /// 5 s et que rien n'oblige à la payer au rythme de l'instantané.
    private func agentJSON() -> [String: Any] {
        mutex.lock()
        if let cachedAgent, now().timeIntervalSince(cachedAgent.at) < cacheTTL {
            let json = cachedAgent.json
            mutex.unlock()
            return json
        }
        mutex.unlock()

        let status = try? store.agentStatus()
        let report = LaunchdAgentProbe.evaluate(result: launchdProbe(),
                                                status: status ?? nil,
                                                now: now())
        var json = report.json
        json["healthy"] = report.isHealthy
        json["summary"] = report.displayText
        // Ce que l'agent DIT qu'il fait, en anglais : le `detail` stocké est un
        // jeton sans langue (`AgentStatusDetail`), et un modèle n'a rien à
        // faire de « pages-queued(20226) » (audit A1m-10).
        if let detail = status?.detail, !detail.isEmpty {
            json["report_detail"] = AgentStatusDetail.english(detail)
        }
        // `alive` et `stale`, LES MÊMES QUE `fouine status --json` (PM-17) : ce
        // sont les propriétés de `AgentStatusRecord` que la ligne de commande
        // publie, pas une seconde lecture de la table. C'est ce qui rendait la
        // contradiction visible — MCP `healthy: true` contre CLI
        // `alive: false, stale: true` sur la même seconde et la même base.
        if let status {
            json["alive"] = status.isAlive
            json["stale"] = status.isStale(at: now())
        }

        mutex.lock()
        cachedAgent = (json, now())
        mutex.unlock()
        return json
    }
}

extension StatusTool {
    /// Un pourcentage à deux décimales, LISIBLE.
    ///
    /// `JSONSerialization` sérialise un `Double` sur dix-sept chiffres
    /// significatifs dès que la valeur n'est pas représentable exactement en
    /// binaire : `16.63` y sort en `16.629999999999999`. Ce n'est pas un détail
    /// de présentation — c'est un serveur d'agent, et le modèle recopiera ce
    /// nombre tel quel dans sa phrase à l'utilisateur. Un `NSDecimalNumber`
    /// construit depuis le texte formaté sort par sa représentation décimale.
    static func percentage(_ value: Double) -> NSDecimalNumber {
        NSDecimalNumber(string: String(format: "%.2f", value))
    }
}
