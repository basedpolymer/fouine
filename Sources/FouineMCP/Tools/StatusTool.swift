// StatusTool.swift — `fouine_status` (D2 § 5.5 n° 5).
// SPDX-License-Identifier: LicenseRef-Fouine-Source-Available
//
// LE PREMIER OUTIL, et celui qu'un agent doit appeler avant les quatre autres :
// il répond à « qu'est-ce que Fouine sait, au juste ? ». Un modèle qui apprend
// qu'il n'y a que 16,6 % de pages vectorisées ne demandera pas une recherche
// sémantique et n'interprétera pas son silence comme une absence de documents.
//
// Il ne CHARGE toujours rien : ni le modèle (571 Mo), ni l'index vectoriel. Il
// se contente de DIRE ce que le serveur a chargé, par `semantic.model_loaded` et
// `index_freshness` — deux champs qui décrivent le serveur lui-même, et non la
// base, et qui sont donc lus hors du cache de soixante secondes.
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
//   · la couverture PAR RACINE (lot MC4, constat PM-05) coûte deux comptages
//     par document de la racine — c'est le calcul du périmètre d'une recherche
//     filtrée, `HybridSearch.scope`. C'est le poste le plus cher de
//     l'instantané ; il est dans le cache, et `include_roots: false` le coupe
//     entièrement ;
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
import FouineEmbed
import FouineMCPKit

public final class StatusTool: MCPTool {

    public let name = "fouine_status"
    public let title = "Fouine index status"
    public let description =
        "Health and coverage of the Fouine index: how many documents and pages, "
        + "OCR backlog, semantic coverage per root, disk budget, roots, and whether "
        + "another process is writing. Call this first: it tells you whether "
        + "semantic search is available and whether a folder is missing because its "
        + "volume is not mounted. Read disk_budget.level and "
        + "meaning_background.pages_left before advising `fouine embed`, and "
        + "roots[].coverage_pct before concluding that a folder has nothing to say."

    private let store: ReadOnlyStore
    private let semantic: SemanticEngine
    private let modelDirectory: URL
    private let launchdProbe: () -> LaunchdAgentResult
    private let cacheTTL: TimeInterval
    private let now: () -> Date

    private let mutex = NSLock()
    private var cached: (payload: [String: Any], at: Date)?
    private var cachedAgent: (json: [String: Any], at: Date)?
    private var cachedRoots: (json: [[String: Any]], at: Date)?

    /// - Parameters:
    ///   - launchdProbe: injectée pour les tests, qui ne doivent ni lancer
    ///     `launchctl` ni dépendre de l'agent installé sur la machine.
    ///   - modelDirectory: idem — une transcription « golden » ne peut pas
    ///     dépendre de la présence d'un modèle de 220 Mo.
    public init(store: ReadOnlyStore,
                semantic: SemanticEngine,
                modelDirectory: URL = EmbedPaths.modelDirectory(),
                launchdProbe: @escaping () -> LaunchdAgentResult = { LaunchdAgentProbe.run(timeout: 0.5) },
                cacheTTL: TimeInterval = 60,
                now: @escaping () -> Date = Date.init) {
        self.store = store
        self.semantic = semantic
        self.modelDirectory = modelDirectory
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
                "vectors": ["type": "integer"] as [String: Any],
                "vector_coverage_pct": ["type": "number"] as [String: Any],
                "semantic": [
                    "type": "object",
                    "properties": [
                        "model_installed": ["type": "boolean"],
                        "model_loaded": ["type": "boolean",
                                         "description": "The CoreML model is resident in "
                                             + "this server (it is loaded lazily, on the "
                                             + "first hybrid search)."],
                        "model_id": ["type": ["string", "null"]],
                        "revision": ["type": ["integer", "null"]],
                        "dimension": ["type": ["integer", "null"]],
                    ] as [String: Any],
                ] as [String: Any],
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
                            "vectorised_pages": ["type": "integer"],
                            "coverage_pct": [
                                "type": "number",
                                "description": "Share of this root's pages carrying a "
                                    + "meaning vector. 0 means search by meaning sees "
                                    + "nothing of this folder, however large it is.",
                            ],
                        ] as [String: Any],
                    ] as [String: Any],
                ] as [String: Any],
                "disk_budget": [
                    "type": "object",
                    "description": "What the index weighs, what it will weigh at full "
                        + "meaning coverage, and where the budget stands. Nothing stops "
                        + "at 100 %: level is a warning, not a fault.",
                    "properties": [
                        "bytes": ["type": "integer"],
                        "budget_bytes": ["type": "integer"],
                        "bytes_at_full_vectors": ["type": "integer"],
                        "ratio_now": ["type": "number"],
                        "ratio_at_full_vectors": ["type": "number"],
                        "pages_at_budget": ["type": ["integer", "null"]],
                        "level": ["enum": ["ok", "near", "over"]],
                    ] as [String: Any],
                ] as [String: Any],
                "meaning_background": [
                    "type": "object",
                    "description": "The background preparation of search by meaning.",
                    "properties": [
                        "enabled": ["type": "boolean"],
                        "budget_minutes": ["type": "integer"],
                        "last_batch": ["type": ["string", "null"]],
                        "pages_left": [
                            "type": "integer",
                            "description": "Indexed pages still without their vectors.",
                        ],
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
                "index_freshness": [
                    "type": "object",
                    "properties": [
                        "vector_index_loaded_at": ["type": ["string", "null"]],
                        "vector_index_count": ["type": ["integer", "null"]],
                    ] as [String: Any],
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
        // La couverture par racine est le poste le plus cher de l'outil (voir
        // l'en-tête) : elle est calculée ICI, hors de l'instantané commun, pour
        // que `include_roots: false` la coupe VRAIMENT. Son propre cache de
        // soixante secondes, comme la sonde de l'agent.
        if includeRoots {
            payload["roots"] = rootsWithCoverage(payload["roots"] as? [[String: Any]] ?? [])
        } else {
            payload.removeValue(forKey: "roots")
        }
        payload["agent"] = includeAgent ? agentJSON() : ["queried": false]
        // HORS DU CACHE, délibérément. C'est le champ le plus volatil de la
        // sortie — et le seul dont un agent se serve pour décider s'il doit
        // réessayer. Le rendre vieux d'une minute lui ferait attendre un verrou
        // rendu depuis longtemps, ou croire libre une base qu'on vient de
        // prendre. Le coût est la lecture d'un fichier de soixante octets.
        payload["write_lock"] = writeLockJSON()
        // HORS DU CACHE, comme `write_lock` et pour la même raison : c'est
        // l'état du serveur LUI-MÊME, pas celui de la base. Un modèle chargé
        // depuis quinze secondes doit apparaître chargé, sans quoi un agent qui
        // mesure ses propres latences conclurait de travers.
        //
        // `model_loaded` doit donc RESSORTIR de l'instantané où le reste de
        // `semantic` (le disque) a toute sa place. Sans cette ligne, un
        // `fouine_status` appelé avant la première recherche hybride figerait
        // « pas chargé » pour une minute — et c'est exactement l'ordre dans
        // lequel un agent appelle.
        let freshness = semantic.freshness()
        if var block = payload["semantic"] as? [String: Any] {
            block["model_loaded"] = freshness.modelLoaded
            payload["semantic"] = block
        }
        payload["index_freshness"] = Self.freshnessJSON(freshness)
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
        let vectors = try store.vectorisedPageCount()
        let coverage = Self.percentage(
            pages > 0 ? Double(vectors) / Double(pages) * 100 : 0)

        // LE PÉRIMÈTRE (lot IG1). `documents` devient le compte DANS le
        // périmètre : c'est la seule surface où le serveur dit combien il sert,
        // et annoncer 1 883 documents quand on n'en sert que 412 ferait
        // conclure au modèle que sa recherche a manqué quelque chose.
        // `pages_indexed` et `vectors` restent ceux de tout l'index — aucune
        // lecture ne compte les pages d'un dossier sans les parcourir — et la
        // clé `scope` le DIT, plutôt que de laisser deviner.
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
            "vectors": vectors,
            "vector_coverage_pct": coverage,
            "semantic": semanticJSON(),
            "roots": try rootsJSON(),
            // PM-32 : les deux objets que la ligne de commande publiait depuis
            // le lot AG1 et que le serveur taisait. Ils ne coûtent AUCUNE
            // lecture de plus — `stats()` est déjà lu ci-dessus, `settingsRows`
            // est une table de quelques lignes — et ce sont eux qu'un
            // assistant doit voir avant de conseiller `fouine embed` : sur la
            // base du propriétaire, `level = "over"` et `pages_left = 139 638`.
            "disk_budget": StatusJSON.diskBudgetJSON(
                StatusJSON.diskForecast(stats: stats)),
            "meaning_background": StatusJSON.meaningJSON(
                settings: SettingsSnapshot(rows: (try? store.settingsRows()) ?? [:]),
                stats: stats),
            "read_only": true,
        ]
        payload["agent"] = [String: Any]()   // remplacé par `call`

        mutex.lock()
        cached = (payload, now())
        mutex.unlock()
        return payload
    }

    // MARK: - Morceaux

    /// Le modèle installé, tel que le voit `fouine doctor` — et rien d'autre :
    /// on ne le CHARGE pas (571 Mo résidents mesurés), on regarde le disque.
    ///
    /// `model_loaded` est posé ici à sa valeur de l'instant, puis RÉÉCRIT par
    /// `call` : ce champ décrit le serveur, pas le disque, et il n'a rien à
    /// faire dans un instantané valable une minute.
    private func semanticJSON() -> [String: Any] {
        let loaded = semantic.freshness().modelLoaded
        guard EmbedPaths.modelAvailable(at: modelDirectory),
              let meta = try? EmbedPaths.loadMeta(at: modelDirectory)
        else {
            return ["model_installed": false, "model_loaded": loaded,
                    "model_id": NSNull(),
                    "revision": NSNull(), "dimension": NSNull()]
        }
        return ["model_installed": true, "model_loaded": loaded,
                "model_id": meta.model_id,
                "revision": meta.revision, "dimension": meta.dim]
    }

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
                + "while pages_indexed, vectors and vector_coverage_pct still "
                + "describe the whole index.",
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

    /// LA COUVERTURE PAR RACINE, et c'est le chiffre qui explique « M2SU : 0 % »
    /// (PM-05). Un assistant qui ne voit que la couverture globale — 67,9 % le
    /// 13/09/2026 — en conclut que la recherche par le sens couvre les deux
    /// tiers du corpus, alors qu'elle ne voit RIEN d'une racine entière, et il
    /// interprète son silence comme une absence de documents.
    ///
    /// Même calcul que le périmètre d'une recherche filtrée
    /// (`HybridSearch.scope`), donc aucune façon de diverger. Cache propre de
    /// soixante secondes : c'est le poste le plus cher de l'outil.
    private func rootsWithCoverage(_ roots: [[String: Any]]) -> [[String: Any]] {
        mutex.lock()
        if let cachedRoots, now().timeIntervalSince(cachedRoots.at) < cacheTTL {
            let json = cachedRoots.json
            mutex.unlock()
            return json
        }
        mutex.unlock()

        let decorated = roots.map { root -> [String: Any] in
            var entry = root
            guard let label = root["label"] as? String,
                  let scope = try? rootScope(label: label) else { return entry }
            entry["pages"] = scope.pagesIndexed
            entry["vectorised_pages"] = scope.vectors
            entry["coverage_pct"] = Self.percentage(scope.coveragePct)
            return entry
        }

        mutex.lock()
        cachedRoots = (decorated, now())
        mutex.unlock()
        return decorated
    }

    /// Ce que le canal du sens voit d'UNE racine.
    private func rootScope(label: String) throws -> SemanticScope {
        var query = SearchQuery(fts: "")
        query.folders = [label]
        return try store.semanticScope(query: query, excludingDocsMatching: nil,
                                       vectors: 0, pagesIndexed: 0)
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

    /// L'index vectoriel RÉSIDENT : quand il a été chargé, et combien de
    /// lignes il porte. Les deux clés existaient depuis la PR 1 et valaient
    /// `null` ; elles sont désormais remplies dès qu'une recherche hybride ou
    /// un appel à `fouine_similar_pages` a construit l'index.
    ///
    /// `vector_index_count` est un nombre de LIGNES de `page_vec`, à comparer à
    /// `vectors` (le nombre de PAGES vectorisées) : les deux coïncident
    /// aujourd'hui, et cesseront de le faire sous le fenêtrage v5. C'est
    /// délibéré — l'écart, s'il apparaît, est exactement ce qu'un diagnostic a
    /// besoin de voir.
    private static func freshnessJSON(
        _ state: SemanticEngine.Freshness) -> [String: Any] {
        [
            "vector_index_loaded_at": state.indexLoadedAt
                .map { ISO8601DateFormatter().string(from: $0) as Any } ?? NSNull(),
            "vector_index_count": state.indexCount.map { $0 as Any } ?? NSNull(),
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
