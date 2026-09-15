// SimilarPagesTool.swift — `fouine_similar_pages` (D2 § 5.5 n° 3, § 5.8).
// SPDX-License-Identifier: LicenseRef-Fouine-Source-Available
//
// LE MOINS CHER DES CINQ : les voisins d'une page se lisent sur son vecteur
// DÉJÀ en base. Aucun texte à encoder, donc AUCUN CHARGEMENT DE COREML —
// 571 Mo et 2,6 s qu'on ne paie pas. C'est explicite et c'est un contrat : un
// serveur qui n'a jamais fait de recherche hybride répond à cet outil en
// ~10 ms sans jamais dépasser ses ~16 Mio plus l'index (145 Mio à 377 k
// vecteurs).
//
// ═══ `encode_if_missing` : LA SEULE PORTE, ET ELLE EST FERMÉE (PM-07) ════════
//
// Le contrat ci-dessus vaut pour L'APPEL ORDINAIRE, et il reste le défaut. Mais
// une page sans vecteur rendait `neighbours: []`, ce qu'un modèle lit comme
// « rien ne ressemble à cette page » — alors que la cause est une campagne qui
// n'est pas passée par là : mesuré le 13/09/2026, la racine `M2SU` avait
// EXACTEMENT zéro vecteur sur 139 638 pages, et les sept pages essayées par le
// propriétaire en venaient toutes. Le paramètre `encode_if_missing` (défaut
// `false`) permet de payer l'encodage pour CETTE page : ~2,3 s la première fois
// dans la vie du serveur, ~0,3 s ensuite. Le vecteur produit est celui de la
// campagne — même découpe, mêmes règles de vecteur nul, même quantification
// (`PageEmbedding`) —, sans quoi les cosinus rendus ne seraient comparables à
// rien et personne ne s'en apercevrait.
//
// ═══ LE COSINUS N'EST PAS UNE PERTINENCE, ET LE SEUIL PAR DÉFAUT EST 0 ═══════
//
// D2 § 5.5 proposait `min_cosine: 0.80`. La mesure du 03/09/2026 (protocole
// C2-01 rejoué sur la production, 64 872 vecteurs, 12 requêtes témoins) a
// infirmé le raisonnement qui la fondait : la bande 0,78-0,88 d'e5-small ne
// sépare pas ce qui est pertinent de ce qui ne l'est pas, et la marge
// `z = (cos − μ) / σ` les sépare À L'ENVERS. Un plancher positif éteindrait
// donc en premier les voisinages les plus utiles. Le paramètre RESTE — un
// appelant qui sait ce qu'il fait doit pouvoir couper —, mais son défaut est 0,
// c'est-à-dire aucun plancher, comme `HybridSearch.defaultVectorFloor`.
//
// ═══ UN COSINUS PAR PAGE, JAMAIS PAR FENÊTRE (D2 § 5.8) ══════════════════════
//
// `VectorIndex.neighbours(of:k:excludingSameDoc:)` rend des rowids de PAGE, et
// c'est un engagement de son auteur qui tient à travers le fenêtrage v5 (où un
// rowid de `page_vec` désignera une fenêtre) : l'agrégation par page — max du
// cosinus sur les fenêtres de la page cible, déduplication — se fera DANS
// `neighbours`. Cet outil n'a donc rien à agréger lui-même, mais il DÉDUPLIQUE
// quand même par (doc_id, page) avant de tronquer : c'est une ligne, et elle
// rend la sortie juste quel que soit ce que l'index rendra demain.
//
// ═══ LES FILTRES SE FONT APRÈS COUP ══════════════════════════════════════════
//
// `neighbours` n'a pas de paramètre de documents autorisés, et lui en ajouter un
// changerait une signature qu'un autre lot tient stable. On demande donc
// `limit × 4` voisins (plafonné à 200), et on filtre ensuite par
// `docIDsMatchingFilters`. Le coût est celui d'un balayage de plus dans le même
// `topK`, soit quelques millisecondes ; le risque est de rendre moins de
// `limit` voisins quand le filtre est très sélectif, ce que `note` dit.

import Foundation
import FouineCore
import FouineEmbed
import FouineMCPKit

public final class SimilarPagesTool: MCPTool {

    public let name = "fouine_similar_pages"
    public let title = "Pages close to a given page"
    public let description =
        "Find pages semantically close to a given page, using the vectors already "
        + "in the index. By default it never loads the model, so it costs "
        + "milliseconds. When the source page has no vector — a whole folder can be "
        + "at 0 %, see fouine_status.roots[].coverage_pct — encode_if_missing: true "
        + "encodes it on the spot, which does load the model (~2 s the first time)."

    static let maxLimit = 50
    static let defaultLimit = 10
    /// Facteur de sur-demande quand un filtre `folder`/`ext` s'applique.
    static let filterOverFetch = 4
    static let overFetchCap = 200

    private let store: ReadOnlyStore
    private let semantic: SemanticEngine

    public init(store: ReadOnlyStore, semantic: SemanticEngine) {
        self.store = store
        self.semantic = semantic
    }

    // MARK: - Schémas

    public var inputSchema: [String: Any] {
        [
            "$schema": "https://json-schema.org/draft/2020-12/schema",
            "type": "object",
            "additionalProperties": false,
            "required": ["doc_id", "page"],
            "properties": [
                "doc_id": ["type": "integer", "minimum": 1] as [String: Any],
                "page": ["type": "integer", "minimum": 1,
                         "maximum": Schema.maxPage] as [String: Any],
                "limit": [
                    "type": "integer", "minimum": 1, "maximum": Self.maxLimit,
                    "default": Self.defaultLimit,
                ] as [String: Any],
                "min_cosine": [
                    "type": "number", "minimum": 0, "maximum": 1, "default": 0,
                    "description": "Optional floor. The cosine is NOT a relevance: on "
                        + "this corpus every value sits between 0.78 and 0.88, and the "
                        + "position inside that band follows the shape of the text more "
                        + "than its subject. 0 (no floor) is the measured default.",
                ] as [String: Any],
                "exclude_same_document": ["type": "boolean", "default": true] as [String: Any],
                "folder": ["type": "string",
                           "description": "Restrict to one root label."] as [String: Any],
                "ext": ["type": "string",
                        "description": "Restrict to one extension, without the dot."]
                    as [String: Any],
                "preview_chars": [
                    "type": "integer", "minimum": 80, "maximum": 600, "default": 200,
                ] as [String: Any],
                "encode_if_missing": [
                    "type": "boolean", "default": false,
                    "description": "When the source page has no vector, encode it on "
                        + "the spot. This LOADS the model — about 2 s and 570 MB the "
                        + "first time in this server, then ~0.3 s per page — which the "
                        + "tool otherwise never does. Use it on a folder search by "
                        + "meaning has not reached yet (fouine_status.roots[]."
                        + "coverage_pct says which).",
                ] as [String: Any],
                "compact": [
                    "type": "boolean", "default": false,
                    "description": "Move the paths out of each neighbour into a "
                        + "documents object keyed by doc_id, written once per "
                        + "document. Shorter, and it shows when several neighbours "
                        + "come from the same file.",
                ] as [String: Any],
            ] as [String: Any],
        ]
    }

    public var outputSchema: [String: Any] {
        [
            "$schema": "https://json-schema.org/draft/2020-12/schema",
            "type": "object",
            "required": ["neighbours", "vector_count", "coverage_pct",
                         "source_has_vector"],
            "properties": [
                "neighbours": [
                    "type": "array",
                    "items": [
                        "type": "object",
                        "required": ["doc_id", "page", "cosine", "preview", "link"],
                        "properties": [
                            "doc_id": ["type": "integer"],
                            "page": ["type": "integer"],
                            "path": ["type": "string"],
                            "abs_path": ["type": ["string", "null"]],
                            "folder": ["type": "string"],
                            "ext": ["type": "string"],
                            "link": ["type": "string",
                                     "description": "fouine:// link that reopens "
                                         + "Fouine on this page."],
                            "cosine": ["type": "number",
                                       "description": "One value PER PAGE. Not a relevance."],
                            "preview": ["type": "string"],
                            "time_seconds": [
                                "type": ["integer", "null"],
                                "description": "Moment in the recording, for a "
                                    + "transcript. Cite \"at 12 min 40\".",
                            ],
                        ] as [String: Any],
                    ] as [String: Any],
                ] as [String: Any],
                "documents": [
                    "type": "object",
                    "description": "compact only: one entry per document, keyed by "
                        + "doc_id, with the paths and how many neighbours it carries.",
                ] as [String: Any],
                "vector_count": ["type": "integer"] as [String: Any],
                "coverage_pct": [
                    "type": "number",
                    "description": "Share of indexed PAGES that carry a vector.",
                ] as [String: Any],
                "model_id": ["type": ["string", "null"]] as [String: Any],
                "revision": ["type": ["integer", "null"]] as [String: Any],
                "source_has_vector": [
                    "type": "boolean",
                    "description": "False when the source page has no vector IN THE "
                        + "INDEX: it has not been embedded yet, or it is too short to "
                        + "carry a direction. It stays false when encode_if_missing "
                        + "computed one for this call — see source_vector.",
                ] as [String: Any],
                "source_vector": [
                    "type": ["string", "null"],
                    "enum": ["stored", "computed", NSNull()],
                    "description": "Where the source vector came from: stored = read "
                        + "from the index; computed = encoded for this call "
                        + "(encode_if_missing); null = there is none.",
                ] as [String: Any],
                "note": ["type": ["string", "null"]] as [String: Any],
                "truncated": ["type": "boolean"] as [String: Any],
                "elapsed_ms": ["type": "number"] as [String: Any],
            ] as [String: Any],
        ]
    }

    // MARK: - Appel

    public func call(arguments: [String: Any]) throws -> ToolResult {
        let started = DispatchTime.now().uptimeNanoseconds
        let docID = Int64(ToolSupport.int(arguments, "doc_id", 0))
        let page = ToolSupport.int(arguments, "page", 1)
        let limit = min(Self.maxLimit, max(1, ToolSupport.int(arguments, "limit",
                                                              Self.defaultLimit)))
        let floor = Float(ToolSupport.double(arguments, "min_cosine", 0))
        let excludeSameDoc = ToolSupport.bool(arguments, "exclude_same_document", true)
        let previewChars = min(600, max(80, ToolSupport.int(arguments,
                                                            "preview_chars", 200)))
        let folder = ToolSupport.string(arguments, "folder")
        let ext = ToolSupport.string(arguments, "ext")?.lowercased()
            .trimmingCharacters(in: CharacterSet(charactersIn: "."))
        let encodeIfMissing = ToolSupport.bool(arguments, "encode_if_missing", false)
        let compact = ToolSupport.bool(arguments, "compact", false)

        do {
            guard let sourceRow = try store.docRow(id: docID) else {
                return .failure("no document \(docID) in this index — "
                                + "use fouine_list_documents to see what is indexed")
            }
            let pageCount = sourceRow.record.nPages
            guard page <= pageCount || pageCount == 0 else {
                return .failure("no page \(page) in document \(docID) "
                                + "(it has \(pageCount) pages)")
            }
            guard let sourceRowid = ToolSupport.rowid(docID: docID, page: page) else {
                return .failure("page \(page) is outside the range this index can "
                                + "address (1…\(Schema.maxPage))")
            }

            let identity = try semantic.storedIdentity()
            let vectorisedPages = try store.vectorisedPageCount()
            let indexedPages = try store.indexedPageCount()
            let coverage = ToolSupport.coveragePercentage(
                vectorisedPages: vectorisedPages, indexedPages: indexedPages)

            // L'index SEUL — pas de CoreML. `nil` = aucun vecteur en base.
            guard let index = try semantic.indexWithoutModel(), index.count > 0 else {
                return ToolResult(envelope(
                    neighbours: [], vectorCount: vectorisedPages, coverage: coverage,
                    identity: identity, sourceHasVector: false, sourceVector: nil,
                    note: "no vector in the index yet — run `fouine embed` to build them",
                    documents: nil, truncated: false, started: started))
            }
            let filtered = folder != nil || ext != nil
            let k = filtered
                ? min(Self.overFetchCap, limit * Self.filterOverFetch) : limit

            // Schéma v5 : l'index est indexé par rowid de FENÊTRE ; la page a un
            // vecteur si sa fenêtre 0 est chargée (les sentinelles vides ne le
            // sont jamais).
            let stored = index.index(
                of: Schema.vecRowID(pageRowID: sourceRowid, chunk: 0)) != nil
            var raw: [(rowid: Int64, cosine: Float)]
            var computedNote: String?
            var sourceVector: String?

            if stored {
                sourceVector = "stored"
                raw = index.neighbours(of: sourceRowid, k: k,
                                       excludingSameDoc: excludeSameDoc)
            } else if encodeIfMissing {
                // LA SEULE PORTE PAR LAQUELLE CET OUTIL CHARGE COREML (PM-07),
                // et elle est fermée par défaut : le contrat « never loads the
                // model » reste celui de l'appel ordinaire. Elle existe parce
                // qu'une racine entière peut être à 0 vecteur (`M2SU`, mesuré)
                // et que l'outil y répondait « aucun voisin », ce qu'un modèle
                // lit comme « rien ne ressemble à cette page ».
                switch try encodedSource(docID: docID, page: page,
                                         rowid: sourceRowid, index: index,
                                         excludeSameDoc: excludeSameDoc, k: k) {
                case .success(let neighbours):
                    raw = neighbours
                    sourceVector = "computed"
                    computedNote = "the model was loaded to encode this page "
                        + "(~2 s the first time in this server, ~0.3 s after)"
                case .refused(let why):
                    return ToolResult(envelope(
                        neighbours: [], vectorCount: vectorisedPages,
                        coverage: coverage, identity: identity,
                        sourceHasVector: false, sourceVector: nil, note: why,
                        documents: nil, truncated: false, started: started))
                }
            } else {
                return ToolResult(envelope(
                    neighbours: [], vectorCount: vectorisedPages, coverage: coverage,
                    identity: identity, sourceHasVector: false, sourceVector: nil,
                    note: "page \(page) of document \(docID) has no vector — it has not "
                        + "been embedded yet, or it is too short to carry one; "
                        + "pass encode_if_missing: true to encode it now "
                        + "(this loads the model)",
                    documents: nil, truncated: false, started: started))
            }

            // Filtre APRÈS coup, pour ne pas toucher à la signature de
            // `neighbours` (voir l'en-tête).
            let allowed = filtered
                ? try store.docIDsMatchingFilters(
                    folders: folder.map { [$0] } ?? [], exts: ext.map { [$0] } ?? [],
                    inDocIDs: [], excludingDocsMatching: nil)
                : nil

            var seen = Set<Int64>()
            var kept: [(rowid: Int64, cosine: Float)] = []
            for candidate in raw {
                guard candidate.cosine >= floor else { continue }
                let target = candidate.rowid / Schema.pagesPerDocLimit
                if let allowed, !allowed.contains(target) { continue }
                // Déduplication par PAGE : inutile aujourd'hui (un vecteur par
                // page), indispensable dès qu'il y en aura plusieurs.
                guard seen.insert(candidate.rowid).inserted else { continue }
                kept.append(candidate)
                if kept.count == limit { break }
            }

            let previews = try store.pagePreviews(for: kept.map(\.rowid),
                                                   maxChars: previewChars)
            var rows: [Int64: DocRow] = [:]
            for id in Set(kept.map { $0.rowid / Schema.pagesPerDocLimit }) {
                rows[id] = try store.docRow(id: id)
            }
            // Le moment d'un voisin transcrit (PM-22) : l'extrait est déjà lu, et
            // une page de transcription commence par son marqueur. Une requête
            // de plus pour savoir LESQUELS sont transcrits — sans elle, un
            // `[12:30]` en tête d'un texte ordinaire ferait citer une vidéo.
            let meta = try store.pageMeta(for: kept.map {
                (docID: $0.rowid / Schema.pagesPerDocLimit,
                 page: Int($0.rowid % Schema.pagesPerDocLimit))
            })

            var notes: [String] = []
            if let computedNote { notes.append(computedNote) }
            if coverage.doubleValue < 50 {
                notes.append(String(format: "only %.1f %% of pages are vectorised",
                                    coverage.doubleValue)
                             + " — neighbours are drawn from that subset")
            }
            if filtered, kept.count < limit, raw.count >= k {
                notes.append("the folder/ext filter left fewer than \(limit) neighbours "
                             + "among the \(k) nearest pages")
            }

            let (payload, truncated) = ToolBudget.fit(textChars: previewChars,
                                                      count: kept.count) { chars, count in
                let entries: [[String: Any]] = kept.prefix(count).map { candidate in
                    let targetDoc = candidate.rowid / Schema.pagesPerDocLimit
                    let targetPage = Int(candidate.rowid % Schema.pagesPerDocLimit)
                    let preview = String(
                        (previews[candidate.rowid]?.preview ?? "").prefix(chars))
                    let time = meta[candidate.rowid]?.source == .transcript
                        ? TranscriptTime.first(in: preview) : nil
                    var entry: [String: Any] = compact
                        ? [:]
                        : ToolSupport.pageFields(rows[targetDoc], docID: targetDoc,
                                                 page: targetPage, time: time)
                    entry["doc_id"] = targetDoc
                    entry["page"] = targetPage
                    entry["cosine"] = ToolSupport.decimal(Double(candidate.cosine),
                                                          places: 3)
                    entry["preview"] = preview
                    entry["time_seconds"] = time.map { $0 as Any } ?? NSNull()
                    return entry
                }
                // `source_has_vector` décrit LA BASE, pas l'appel : une page
                // encodée à la volée n'en a toujours pas, et le dire autrement
                // laisserait croire que la campagne y est passée.
                // `source_vector` dit d'où vient celui qui a servi.
                return self.envelope(
                    neighbours: entries, vectorCount: vectorisedPages,
                    coverage: coverage, identity: identity, sourceHasVector: stored,
                    sourceVector: sourceVector,
                    note: notes.isEmpty ? nil : notes.joined(separator: " ; "),
                    documents: compact ? self.documentMap(entries, rows: rows) : nil,
                    truncated: false, started: started)
            }
            var out = payload
            if truncated { out["truncated"] = true }
            return ToolResult(out)
        } catch {
            return .failure("cannot look for similar pages: " + MCPText.describe(error))
        }
    }

    private func envelope(neighbours: [[String: Any]], vectorCount: Int,
                          coverage: NSDecimalNumber,
                          identity: (modelID: String?, revision: Int?),
                          sourceHasVector: Bool, sourceVector: String?,
                          note: String?, documents: [String: Any]?,
                          truncated: Bool, started: UInt64) -> [String: Any] {
        let elapsed = Double(DispatchTime.now().uptimeNanoseconds - started) / 1_000_000
        var out: [String: Any] = [
            "neighbours": neighbours,
            "vector_count": vectorCount,
            "coverage_pct": coverage,
            "model_id": identity.modelID.map { $0 as Any } ?? NSNull(),
            "revision": identity.revision.map { $0 as Any } ?? NSNull(),
            "source_has_vector": sourceHasVector,
            "source_vector": sourceVector.map { $0 as Any } ?? NSNull(),
            "note": note.map { $0 as Any } ?? NSNull(),
            "truncated": truncated,
            "elapsed_ms": ToolSupport.decimal(elapsed),
        ]
        // `documents` n'apparaît QUE sous `compact` : une clé vide ferait croire
        // à un listage qui n'a rien rendu.
        if let documents { out["documents"] = documents }
        return out
    }

    /// Les documents de ces voisins, une fois chacun (`compact`). Même patron
    /// que `fouine_search` : le chemin s'écrit une fois, et `hits` dit combien
    /// de voisins viennent du même fichier — ce qui se lisait « quatre sources »
    /// quand c'était quatre pages d'un même cours.
    private func documentMap(_ entries: [[String: Any]],
                             rows: [Int64: DocRow]) -> [String: Any] {
        var counts: [Int64: Int] = [:]
        var order: [Int64] = []
        for entry in entries {
            guard let id = entry["doc_id"] as? Int64 else { continue }
            if counts[id] == nil { order.append(id) }
            counts[id, default: 0] += 1
        }
        var out: [String: Any] = [:]
        for id in order {
            var fields = ToolSupport.pageFields(rows[id], docID: id, page: 1)
            fields["n_pages"] = rows[id]?.record.nPages ?? 0
            fields["hits"] = counts[id] ?? 0
            out[String(id)] = fields
        }
        return out
    }

    // MARK: - Encoder la page source à la volée (constat PM-07)

    private enum EncodedSource {
        case success([(rowid: Int64, cosine: Float)])
        case refused(String)
    }

    /// Le texte de la page, les fenêtres de la campagne, le modèle, la
    /// quantification de la campagne, puis le même balayage agrégé par page.
    ///
    /// LE VECTEUR DOIT ÊTRE CELUI DE LA CAMPAGNE, sans quoi les cosinus rendus
    /// ne seraient pas comparables à ceux d'une page déjà vectorisée — et rien
    /// ne le montrerait, les deux rendant des nombres plausibles. D'où
    /// `PageEmbedding`, qui porte la découpe ET les règles de vecteur nul, et
    /// que `EmbedRun` appelle aussi.
    private func encodedSource(docID: Int64, page: Int, rowid: Int64,
                               index: VectorIndex, excludeSameDoc: Bool,
                               k: Int) throws -> EncodedSource {
        guard semantic.modelInstalled else {
            return .refused("page \(page) of document \(docID) has no vector, and the "
                            + "meaning model is not installed — install it from "
                            + "Fouine.app ▸ Settings ▸ Search, or run `fouine embed`")
        }
        // 4 000 caractères : au-delà, la campagne ne produit plus de fenêtre
        // (`vecWindowMax` × le pas, plus la largeur d'une fenêtre). Lire toute
        // la page coûterait sans rien changer au vecteur.
        let span = Schema.vecWindowStride * (Schema.vecWindowMax - 1)
            + Schema.vecWindowChars
        let text = try store.pagePreviews(for: [rowid], maxChars: span)[rowid]?.preview
        guard let text, !text.isEmpty else {
            return .refused("page \(page) of document \(docID) carries no indexed text "
                            + "— it may be an image waiting for OCR "
                            + "(see fouine_status.ocr_queue)")
        }
        let vectors = try PageEmbedding.vectors(forPageText: text,
                                                engine: semantic.loadedEncoder())
        guard !vectors.isEmpty else {
            return .refused("page \(page) of document \(docID) is too short to carry a "
                            + "direction — the campaign would give it a null vector too")
        }
        return .success(index.neighbours(
            ofVectors: vectors, k: k,
            excludingDoc: excludeSameDoc ? docID : nil))
    }
}
