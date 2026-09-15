// ListDocumentsTool.swift — `fouine_list_documents` (D2 § 5.5 n° 4).
// SPDX-License-Identifier: LicenseRef-Fouine-Source-Available
//
// L'OUTIL QUI RÉPOND À LA PREMIÈRE QUESTION D'UN UTILISATEUR : « pourquoi ce
// document n'apparaît pas ? ». `state: "failed"` avec le champ `error` la
// traite en un appel, et c'est ce qui rend cet outil utile bien au-delà d'un
// listage. Les autres états servent le même but sous un autre angle :
// `skipped` (trop gros, format inconnu), `pending` (vu par le crawler, pas
// encore extrait), `indexed` (le cas normal, et le défaut).
//
// `docs.err` EST EN ANGLAIS depuis B1-33, et c'était un prérequis du palier 4,
// pas une finition : une vingtaine de messages y étaient français, et un
// serveur MCP anglophone aurait exposé le mélange à un modèle qui n'a aucun
// moyen de savoir laquelle des deux langues est la bonne.
//
// PAGINATION PAR SQLITE. `LIMIT`/`OFFSET` sur un ordre TOTAL (le champ demandé,
// puis `id`) : une pagination faite en mémoire sur un listage complet
// recouvrirait ou sauterait des lignes dès qu'une passe d'indexation écrit
// entre deux appels, et il n'y aurait aucun moyen de s'en apercevoir.
//
// `vectorised_pages` PASSE PAR LE POINT UNIQUE. Voir
// `ReadOnlyStore.vectorisedPageCounts(forDocIDs:)` : c'est là, et nulle part
// ici, que le fenêtrage v5 interviendra.

import Foundation
import FouineCore
import FouineMCPKit

public final class ListDocumentsTool: MCPTool {

    public let name = "fouine_list_documents"
    public let title = "List indexed documents"
    public let description =
        "List the documents Fouine knows about, with filters. Use it to see what is "
        + "indexed before searching, or with state: \"failed\" to find out why a "
        + "document is missing (the error field says what went wrong)."

    static let maxLimit = 200
    static let defaultLimit = 50

    private let store: ReadOnlyStore

    public init(store: ReadOnlyStore) {
        self.store = store
    }

    // MARK: - Schémas

    public var inputSchema: [String: Any] {
        [
            "$schema": "https://json-schema.org/draft/2020-12/schema",
            "type": "object",
            "additionalProperties": false,
            "properties": [
                "folder": ["type": "string",
                           "description": "One root label (see fouine_status.roots)."]
                    as [String: Any],
                "ext": ["type": "string", "description": "Extension, without the dot."]
                    as [String: Any],
                "path_contains": [
                    "type": "string", "maxLength": 200,
                    "description": "Substring of the path, matched literally.",
                ] as [String: Any],
                "state": [
                    "type": "string",
                    "enum": ["indexed", "failed", "skipped", "pending", "any"],
                    "default": "indexed",
                    "description": "indexed = text is in the index; failed = extraction "
                        + "failed (read error); skipped = too large or unsupported; "
                        + "pending = seen but not extracted yet.",
                ] as [String: Any],
                "limit": [
                    "type": "integer", "minimum": 1, "maximum": Self.maxLimit,
                    "default": Self.defaultLimit,
                ] as [String: Any],
                "cursor": [
                    "type": "string",
                    "description": "Opaque cursor from a previous result's next_cursor.",
                ] as [String: Any],
                "order": [
                    "type": "string",
                    "enum": ["path", "pages", "recent"], "default": "path",
                    "description": "path = alphabetical; pages = longest first; "
                        + "recent = most recently modified first.",
                ] as [String: Any],
            ] as [String: Any],
        ]
    }

    public var outputSchema: [String: Any] {
        [
            "$schema": "https://json-schema.org/draft/2020-12/schema",
            "type": "object",
            "required": ["documents", "has_more", "total"],
            "properties": [
                "documents": [
                    "type": "array",
                    "items": [
                        "type": "object",
                        "properties": [
                            "doc_id": ["type": "integer"],
                            "path": ["type": "string",
                                     "description": "Path relative to the volume."],
                            "abs_path": ["type": ["string", "null"]],
                            "link": ["type": "string",
                                     "description": "fouine:// link that reopens "
                                         + "Fouine on this document."],
                            "folder": ["type": "string"],
                            "ext": ["type": "string"],
                            "pages": ["type": "integer"],
                            "modified": [
                                "type": "string",
                                "description": "When the FILE was last modified "
                                    + "(ISO 8601, UTC). This is what order: \"recent\" "
                                    + "sorts on. Not the date the document carries: "
                                    + "that is doc_date.",
                            ],
                            "state": ["type": "string",
                                      "enum": ["indexed", "failed", "skipped", "pending"]],
                            "error": ["type": ["string", "null"],
                                      "description": "Why extraction failed."],
                            "ocr_pages": ["type": "integer",
                                          "description": "Pages whose text came from OCR."],
                            "vectorised_pages": ["type": "integer",
                                                 "description": "Pages carrying a vector."],
                        ] as [String: Any],
                    ] as [String: Any],
                ] as [String: Any],
                "total": ["type": "integer",
                          "description": "Documents matching the filter, all pages."]
                    as [String: Any],
                "has_more": ["type": "boolean"] as [String: Any],
                "next_cursor": ["type": ["string", "null"]] as [String: Any],
                "truncated": ["type": "boolean"] as [String: Any],
                "elapsed_ms": ["type": "number"] as [String: Any],
            ] as [String: Any],
        ]
    }

    // MARK: - Appel

    public func call(arguments: [String: Any]) throws -> ToolResult {
        let started = DispatchTime.now().uptimeNanoseconds
        let limit = min(Self.maxLimit, max(1, ToolSupport.int(arguments, "limit",
                                                              Self.defaultLimit)))
        let offset = try ToolSupport.offset(from: arguments)
        let order = DocumentOrder(rawValue: (arguments["order"] as? String) ?? "path")
            ?? .path
        let filter = DocumentFilter(
            folder: ToolSupport.string(arguments, "folder"),
            ext: ToolSupport.string(arguments, "ext"),
            pathContains: ToolSupport.string(arguments, "path_contains"),
            states: ToolSupport.states(for: (arguments["state"] as? String) ?? "indexed"))

        do {
            let total = try store.countDocuments(filter)
            // Un de plus que demandé : `has_more` est OBSERVÉ, pas déduit de
            // `offset + limit < total`. Le total et la page sont deux requêtes,
            // et une écriture concurrente peut les séparer.
            let rows = try store.listDocuments(filter, order: order,
                                               limit: limit + 1, offset: offset)
            let hasMore = rows.count > limit
            let page = Array(rows.prefix(limit))
            let ids = page.map(\.id)
            let ocr = try store.ocrPageCounts(forDocIDs: ids)
            let vectors = try store.vectorisedPageCounts(forDocIDs: ids)

            // Le budget ne raccourcit pas d'extrait ici — il n'y en a pas : un
            // listage trop gros perd des LIGNES, et le curseur les rend.
            let (payload, truncated) = ToolBudget.fit(textChars: 80,
                                                      count: page.count) { _, count in
                let documents: [[String: Any]] = page.prefix(count).map { row in
                    // Le chemin absolu sert DEUX champs : `abs_path` et le
                    // lien. Une seule résolution — `VolumeResolver` énumère
                    // les volumes montés à chaque appel.
                    let absolute = ToolSupport.absolutePath(volUUID: row.volUUID,
                                                            relPath: row.relPath)
                    return [
                        "doc_id": row.id,
                        "path": row.relPath,
                        "abs_path": absolute.map { $0 as Any } ?? NSNull(),
                        // SANS page : un listage désigne des documents, et un
                        // lien qui prétendrait à la page 1 mentirait sur ce
                        // qui a été trouvé.
                        "link": ToolSupport.link(absolutePath: absolute,
                                                 docID: row.id, page: nil),
                        "folder": row.topFolder,
                        "ext": row.ext,
                        "pages": row.nPages,
                        // PM-16a : `fouine list --json` la portait, le serveur
                        // non. Un agent qui demandait `order: "recent"` triait
                        // sur une date qu'il ne voyait jamais, donc sans
                        // pouvoir dire « ce cours date de mardi ».
                        "modified": ListDocumentsTool.instant(row.mtime),
                        "state": ToolSupport.state(row.state),
                        "error": row.err.map { $0 as Any } ?? NSNull(),
                        // La date INSCRITE DANS LE DOCUMENT (schéma v9,
                        // constat PR-07), en jour civil. Clé ADDITIVE et
                        // toujours présente : `null` dit « ce document n'en
                        // porte pas », ce qui est le cas le plus fréquent, et
                        // un modèle n'a pas à deviner ce qu'une clé absente
                        // voudrait dire. Rien à voir avec la date du fichier.
                        "doc_date": row.docDate.map {
                            ListDocumentsTool.day($0) as Any
                        } ?? NSNull(),
                        "ocr_pages": ocr[row.id] ?? 0,
                        "vectorised_pages": vectors[row.id] ?? 0,
                    ]
                }
                let more = hasMore || documents.count < page.count
                let elapsed = Double(DispatchTime.now().uptimeNanoseconds - started)
                    / 1_000_000
                var out: [String: Any] = [
                    "documents": documents,
                    "total": total,
                    "has_more": more,
                    "elapsed_ms": ToolSupport.decimal(elapsed),
                ]
                out["next_cursor"] = more
                    ? Cursor.encode(offset: offset + documents.count,
                                    arguments: arguments) as Any
                    : NSNull()
                return out
            }
            var out = payload
            if truncated { out["truncated"] = true }
            return ToolResult(out)
        } catch {
            return .failure("cannot list documents: " + MCPText.describe(error))
        }
    }

    /// `modified`, en UTC — et c'est le seul écart assumé avec `fouine list
    /// --json`, qui rend le même INSTANT dans le fuseau de la machine.
    ///
    /// Deux raisons. Un client MCP n'est pas forcément sur cette machine, et
    /// tout ce que ce serveur horodate déjà est en UTC (`write_lock.since`,
    /// `index_freshness`, `meaning_background.last_batch`) : une seule
    /// convention par surface, sans quoi un modèle compare des heures qui ne se
    /// comparent pas. Et un décalage local rendrait les transcriptions
    /// « golden » dépendantes du fuseau de la machine qui les rejoue.
    static func instant(_ epoch: Double) -> String {
        isoFormatter.string(from: Date(timeIntervalSince1970: epoch))
    }

    /// Partagé : `ISO8601DateFormatter()` est un objet cher, et un listage en
    /// rend jusqu'à deux cents.
    private static let isoFormatter: ISO8601DateFormatter = {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime]
        return formatter
    }()

    /// `AAAA-MM-JJ`, en UTC : `doc_date` porte un JOUR civil écrit à midi UTC
    /// (`DocumentDate`), et le rendre dans le fuseau de la machine le décalerait
    /// d'un jour pour la moitié du globe.
    static func day(_ epoch: Double) -> String {
        let civil = DocumentDate.civil(epoch)
        return String(format: "%04d-%02d-%02d", civil.year, civil.month, civil.day)
    }
}
