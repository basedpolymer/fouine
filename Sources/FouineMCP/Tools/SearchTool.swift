// SearchTool.swift — `fouine_search` (D2 § 5.5 n° 1).
// SPDX-License-Identifier: LicenseRef-Fouine-Source-Available
//
// L'OUTIL CENTRAL, et celui dont le contrat est le plus délicat, pour une seule
// raison : il a DEUX moteurs et doit n'avoir QU'UNE forme de sortie. La CLI, en
// hybride, rend un autre JSON qu'en lexical (`rrf`, `lex_rank`, `cosine`…) ;
// un client peut se le permettre, un modèle non — il ne saura pas que les deux
// objets décrivent la même chose. Ici : une seule forme, champs sémantiques
// optionnels, et `mode_used` qui dit lequel des deux a répondu.
//
// ═══ LE REPLI EST ANNONCÉ, JAMAIS MUET ═══════════════════════════════════════
//
// C'est la règle la plus importante du fichier. Le pire mode de panne d'un
// serveur d'agent n'est pas l'erreur : c'est la réponse plausible et fausse.
// Un `mode: "hybrid"` demandé sans modèle installé rend donc un SUCCÈS —
// `mode_used: "lexical"`, `semantic_available: false`, et un `note` qui dit
// pourquoi — parce que la recherche, elle, a bel et bien marché. Une erreur
// ferait croire au modèle que l'index est cassé ; un repli silencieux lui
// ferait croire que le corpus ne contient rien.
//
// C'est la transposition exacte de `runHybrid` (`CommandsSearch.swift:157-176`),
// qui avertit sur stderr et pose `hybrid: false` dans son JSON.
//
// ═══ CE QUE `bm25` ET `cosine` NE SONT PAS ═══════════════════════════════════
//
// `bm25` est le score brut de FTS5 : NÉGATIF, non borné, et non comparable
// d'une requête à l'autre. Il n'est surtout pas rendu comme une « pertinence
// 0-1 » — c'est la faute que le nom `score` invitait à commettre.
//
// `cosine` N'EST PAS une pertinence non plus, et c'est une MESURE, pas une
// précaution de style : sur ce corpus tous les cosinus d'e5-small vivent entre
// 0,78 et 0,88, et la position dans cette bande suit la forme de la requête
// plus que son sujet (C2-01, revérifié le 03/09 sur 12 requêtes témoins). Ce
// qui se lit est la MARGE `z = (cos − μ) / σ`, rendue à côté, et `semantic_stats`
// donne μ et σ pour que l'appelant juge lui-même.
//
// ═══ PAGINATION ══════════════════════════════════════════════════════════════
//
// `has_more` est obtenu en demandant UN résultat de plus que la limite, jamais
// en comparant `offset + limit` à un total : les totaux sont approchés au-delà
// de 50 000 pages (C2-09b), et une pagination fondée dessus s'arrêterait trop
// tôt ou boucherait dans le vide. Le curseur porte une empreinte des arguments :
// celui d'une autre requête est refusé en `-32602` (voir `Cursor`).

import Foundation
import FouineCore
import FouineEmbed
import FouineMCPKit

public final class SearchTool: MCPTool {

    public let name = "fouine_search"
    public let title = "Search the Fouine index"
    // LA DESCRIPTION EST LA SEULE DOCUMENTATION QUE LE MODÈLE LIT (constats
    // PM-29 et PM-30). `nom:` et `texte:` étaient livrés, documentés dans
    // `docs/mcp.md`, et invisibles ici : aucun modèle ne pouvait les employer.
    // Et la phrase de citation promettait « page N » sur trois corpus où elle
    // est fausse — une diapositive, un livre à préliminaires, un enregistrement
    // — d'où la réserve, qui renvoie aux deux champs qui, eux, sont justes.
    public let description =
        "Full-text (and optionally semantic) search over the user's indexed "
        + "documents. Returns PAGES, not documents. "
        + "Query syntax: bare words = AND, \"phrase\" = exact, term* = prefix "
        + "(4 letters minimum), -term = exclude the whole document, pres:5 (or "
        + "near:5) = within 5 words. "
        + "Filters: dossier:X (or folder:X), ext:pdf, nom:X (or name:X) searches "
        + "file names only and on its own lists documents, texte:X (or body:X) "
        + "searches page text only, chemin:X (or path:X) matches the whole path, "
        + "folders included. Four of them also work in the negative, dropping "
        + "whole documents: -dossier:, -ext:, -nom:, -chemin: (quoted values "
        + "allowed: -dossier:\"My courses\"). Accents may be typed or pasted. "
        + "Never write AND, OR or NOT: words are already combined "
        + "with AND, and -term excludes. "
        + "Use fouine_read_page to read a hit in full. "
        + "Cite a page as \"<file name>, page N\" followed by its `link`, with "
        + "one reservation: for a slideshow cite `slide`, for a recording cite "
        + "`time_seconds`, and page N otherwise."

    /// Plafond du nombre de hits (D2 § 5.5 : 50 × 800 = 40 000 caractères).
    static let maxLimit = 50
    static let defaultLimit = 10
    static let maxSnippetChars = 800
    static let defaultSnippetChars = 240

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
            "required": ["query"],
            "properties": [
                "query": [
                    "type": "string", "minLength": 1, "maxLength": 500,
                    "description": "Search terms. See the tool description for the syntax.",
                ] as [String: Any],
                "limit": [
                    "type": "integer", "minimum": 1, "maximum": Self.maxLimit,
                    "default": Self.defaultLimit,
                    "description": "How many pages to return.",
                ] as [String: Any],
                "cursor": [
                    "type": "string",
                    "description": "Opaque cursor from a previous result's next_cursor. "
                        + "Pass the same arguments as the call that produced it.",
                ] as [String: Any],
                // `"type": "string"` À CÔTÉ DE CHAQUE `enum` (PM-08) : les
                // clients qui valident de leur côté n'avaient pas de quoi dire
                // « ce doit être une chaîne », et la spec JSON Schema n'impose
                // rien d'autre qu'un `enum` — c'est donc un manque de forme,
                // pas une erreur, et il coûtait un aller-retour au modèle.
                "mode": [
                    "type": "string",
                    "enum": ["auto", "lexical", "hybrid"], "default": "auto",
                    "description": "auto = semantic when the model and vectors are "
                        + "there, full-text otherwise. Never an error either way: "
                        + "read mode_used and note.",
                ] as [String: Any],
                "folder": [
                    "type": "string",
                    "description": "Restrict to one root label (see fouine_status.roots).",
                ] as [String: Any],
                "ext": [
                    "type": "string",
                    "description": "Restrict to one extension, without the dot.",
                ] as [String: Any],
                "lang": [
                    "type": "string",
                    "description": "Restrict to documents written in this language, "
                        + "ISO 639-1 (\"fr\", \"en\"); \"und\" = language not determined.",
                ] as [String: Any],
                "source": [
                    "type": "string",
                    "enum": ["native", "ocr", "transcript"],
                    "description": "Restrict to pages whose text has this origin: "
                        + "native (the document carried it), ocr (Fouine read it "
                        + "on the page image) or transcript (Fouine wrote down the "
                        + "speech of an audio or video file). Omit for all three.",
                ] as [String: Any],
                "since": [
                    "type": "string",
                    "description": "Only documents modified on or after this date, "
                        + "written YYYY-MM-DD (the file's own date, not the date "
                        + "printed inside it).",
                ] as [String: Any],
                "fuzzy": [
                    "type": "string",
                    "enum": ["off", "auto", "on"], "default": "auto",
                    "description": "Tolerate spelling differences: auto widens only "
                        + "when the exact search finds fewer than 20 pages, on "
                        + "always, off never. Widened hits carry fuzzy_distance > 0 "
                        + "and the response says fuzzy_expanded.",
                ] as [String: Any],
                "facet": [
                    "type": "string",
                    "enum": ["doc_year", "modified_year", "folder", "ext",
                             "source", "lang"],
                    "description": "Also count the results by this dimension, "
                        + "returned in facets. doc_year is the year the document "
                        + "CARRIES (its own date, present on most documents); "
                        + "modified_year is the year its FILE was last changed — "
                        + "they answer different questions. Computed on the first "
                        + "page of results only.",
                ] as [String: Any],
                "compact": [
                    "type": "boolean", "default": false,
                    "description": "Move the paths out of the hits: each hit keeps "
                        + "doc_id, page and snippet, and every document appears "
                        + "once in documents. Halves the size of a reply whose "
                        + "hits share a few documents.",
                ] as [String: Any],
                "marks": [
                    "type": "string",
                    "enum": ["guillemets", "brackets", "asterisks", "none"],
                    "default": "guillemets",
                    "description": "What surrounds the matched words in a snippet: "
                        + "«…» (default), [ … ], ** … ** or nothing. Pick another "
                        + "one when the text itself uses «…» and you cannot tell "
                        + "the highlight from a quotation.",
                ] as [String: Any],
                "doc_ids": [
                    "type": "array", "items": ["type": "integer"], "maxItems": 50,
                    "description": "Search within these documents only "
                        + "(\u{2018}search in results\u{2019}).",
                ] as [String: Any],
                // UN PLAFOND, ET LE SCHÉMA LE DIT (CM-18). L'extrait vient de
                // FTS5 à une longueur à peu près fixe (~240 caractères) ; ce
                // paramètre le COUPE et ne l'élargit pas. Le présenter comme
                // « la longueur de l'extrait » laissait croire qu'on pouvait
                // demander plus de contexte autour d'un mot, et un modèle qui
                // s'y fiait montait à 800 sans rien gagner qu'un appel de plus.
                "snippet_chars": [
                    "type": "integer", "minimum": 80, "maximum": Self.maxSnippetChars,
                    "default": Self.defaultSnippetChars,
                    "description": "Maximum length of each snippet (a cap on the "
                        + "snippet FTS5 produces — it does not widen the context; "
                        + "use fouine_read_page to read more).",
                ] as [String: Any],
            ] as [String: Any],
        ]
    }

    public var outputSchema: [String: Any] {
        [
            "$schema": "https://json-schema.org/draft/2020-12/schema",
            "type": "object",
            "required": ["hits", "total_pages", "total_docs", "mode_used",
                         "semantic_available", "has_more"],
            "properties": [
                "hits": [
                    "type": "array",
                    "items": [
                        "type": "object",
                        "required": ["doc_id", "page", "snippet"],
                        "properties": [
                            "doc_id": ["type": "integer"],
                            "page": ["type": "integer"],
                            "path": ["type": "string",
                                     "description": "Path relative to the volume. "
                                         + "Absent under compact: read documents."],
                            "abs_path": ["type": ["string", "null"],
                                         "description": "Absolute path, null if the "
                                             + "volume is not mounted."],
                            "folder": ["type": "string"],
                            "ext": ["type": "string"],
                            "link": ["type": "string",
                                     "description": "fouine:// link that reopens "
                                         + "Fouine on this page. Cite a page as "
                                         + "\"<file name>, page N\" followed by this "
                                         + "link."],
                            "snippet": ["type": "string"],
                            "bm25": ["type": ["number", "null"],
                                     "description": "FTS5 BM25, to four decimals. "
                                         + "NEGATIVE, unbounded, and NOT comparable "
                                         + "across queries — a ranking key, never a "
                                         + "relevance. Null for a hit found only by "
                                         + "the semantic channel."],
                            // Les valeurs ÉMISES (`GRDBStore.sourceLabel`), pas
                            // celles du filtre d'entrée : `ocr` à l'entrée,
                            // `ocr_accurate` à la sortie.
                            "source": ["enum": ["native", "ocr_accurate", "transcript"],
                                       "description": "Origin of the page text. Pass "
                                           + "source=ocr to keep only scanned pages."],
                            "engine": ["type": "string"],
                            "fuzzy_distance": ["type": "integer"],
                            "relevance_pct": [
                                "type": "integer",
                                "description": "This hit's score as a share of the "
                                    + "BEST-SCORING hit of this reply, 0 to 100. "
                                    + "Relative, not absolute: 100 means \"nothing "
                                    + "here scores higher\", never \"the answer\", "
                                    + "and it cannot be compared across queries. "
                                    + "The order of the list can differ from it "
                                    + "(under quorum the exact pages come first). "
                                    + "It is the number the command line prints.",
                            ] as [String: Any],
                            "time_seconds": [
                                "type": ["integer", "null"],
                                "description": "Where this excerpt is in the "
                                    + "recording, in seconds from the start — for a "
                                    + "transcribed page only, null everywhere else. "
                                    + "Cite it (\"at 12 min 40\") rather than the "
                                    + "page: a page covers ten minutes of speech. "
                                    + "The link carries it too.",
                            ] as [String: Any],
                            "slide": [
                                "type": ["integer", "null"],
                                "description": "Slide number, for a slideshow "
                                    + "(.pptx, .odp) — null for everything else. "
                                    + "Cite the slide, not the page: the pictures "
                                    + "embedded in the file are pages too, and they "
                                    + "come after the slides.",
                            ] as [String: Any],
                            "embedded_image": [
                                "type": ["integer", "null"],
                                "description": "This page is not a page of the "
                                    + "document but the Nth picture embedded in it, "
                                    + "read by text recognition. Null when the page "
                                    + "is a page.",
                            ] as [String: Any],
                            "cosine": ["type": ["number", "null"],
                                       "description": "Cosine to the query vector. NOT a "
                                           + "relevance: on this corpus every cosine sits "
                                           + "between 0.78 and 0.88. Read z instead."],
                            "z": ["type": ["number", "null"],
                                  "description": "Margin (cos − mu) / sigma of this hit in "
                                      + "the population scanned for THIS query."],
                            "lex_rank": ["type": ["integer", "null"]],
                            "vec_rank": ["type": ["integer", "null"]],
                            "rrf": ["type": ["number", "null"]],
                            "semantic_only": ["type": "boolean",
                                              "description": "The full-text channel did "
                                                  + "not find this page."],
                            "why": [
                                "type": ["object", "null"],
                                "description": "Why this page is here, computed on the "
                                    + "SNIPPET, so it never claims a word is "
                                    + "MISSING: a lexical hit carries every positive "
                                    + "word by construction. kind: exact = found by your "
                                    + "words (terms_found), fuzzy = a close spelling "
                                    + "(typed / found / distance), semantic = none of "
                                    + "the words, meaning only, both = found by both "
                                    + "channels. terms_missing only ever comes from the "
                                    + "app, which reads the whole page. Null when there "
                                    + "is nothing honest to say.",
                                "properties": [
                                    "kind": ["enum": ["exact", "partial", "fuzzy",
                                                      "semantic", "both"]],
                                    "terms_found": ["type": "array",
                                                    "items": ["type": "string"]],
                                    "terms_missing": ["type": "array",
                                                      "items": ["type": "string"]],
                                    "typed": ["type": "string"],
                                    "found": ["type": "string"],
                                    "distance": ["type": "integer"],
                                ] as [String: Any],
                            ] as [String: Any],
                        ] as [String: Any],
                    ] as [String: Any],
                ] as [String: Any],
                "total_pages": ["type": "integer"] as [String: Any],
                "total_docs": ["type": "integer"] as [String: Any],
                "totals_approximate": [
                    "type": "boolean",
                    "description": "True when the counts were capped: the real totals are "
                        + "at least these.",
                ] as [String: Any],
                "mode_used": ["enum": ["lexical", "hybrid"]] as [String: Any],
                "semantic_available": ["type": "boolean"] as [String: Any],
                "documents": [
                    "type": "object",
                    "description": "The documents of these hits, once each, keyed by "
                        + "doc_id: path, abs_path, folder, ext, n_pages, hits (how "
                        + "many hits of this reply come from it) and link (page 1 — "
                        + "for another page replace &page=N). Filled under "
                        + "compact: true, empty otherwise.",
                ] as [String: Any],
                "facets": [
                    "type": ["object", "null"],
                    "description": "Counts by the requested facet, value to count. "
                        + "Null when no facet was asked, and on every page after "
                        + "the first: a cursor does not recompute them.",
                ] as [String: Any],
                "semantic_coverage_pct": [
                    "type": ["number", "null"],
                    "description": "Share of the pages IN SCOPE that carry a vector "
                        + "— the whole index when no document filter applies. "
                        + "Semantic hits are drawn from that subset only.",
                ] as [String: Any],
                "semantic_scope": [
                    "type": "object",
                    "description": "What the meaning channel can see of this search: "
                        + "pages (indexed pages in scope), vectorised (how many of "
                        + "them carry a vector), filtered (true when a document "
                        + "filter narrowed the scope). Always present.",
                ] as [String: Any],
                "semantic_stats": ["type": ["object", "null"]] as [String: Any],
                "semantic_rank_scale": [
                    "type": ["number", "null"],
                    "description": "Factor applied to semantic ranks in the fusion "
                        + "(indexed pages / vectorised pages); 1 once every page "
                        + "carries a vector, null in lexical mode.",
                ] as [String: Any],
                "note": [
                    "type": ["string", "null"],
                    "description": "Why the mode differs from the one asked, or what "
                        + "limits these results.",
                ] as [String: Any],
                "name_matches": [
                    "type": "array",
                    "description": "Documents whose FILE NAME answers the query, at "
                        + "most five. A separate channel: they are not pages, they do "
                        + "not appear in hits and they do not change total_pages. "
                        + "Empty array when no file name matches.",
                    "items": [
                        "type": "object",
                        "required": ["doc_id", "path", "link"],
                        "properties": [
                            "doc_id": ["type": "integer"],
                            "path": ["type": "string"],
                            "abs_path": ["type": ["string", "null"]],
                            "folder": ["type": "string"],
                            "ext": ["type": "string"],
                            "n_pages": ["type": "integer"],
                            "link": ["type": "string",
                                     "description": "fouine:// link to page 1."],
                        ] as [String: Any],
                    ] as [String: Any],
                ] as [String: Any],
                "fuzzy_fallback": [
                    "type": "boolean",
                    "description": "True when the exact search found nothing and the "
                        + "query was replayed once tolerating typos over every "
                        + "document. That is the REPLAY only: for results widened "
                        + "in the ordinary pass, read fuzzy_expanded — it is the "
                        + "flag that covers both.",
                ] as [String: Any],
                "quorum": [
                    "type": "boolean",
                    "description": "Fewer than ten pages carried EVERY word, so the "
                        + "search also returned pages carrying most of them: the "
                        + "head of the list is complete, the tail is not.",
                ] as [String: Any],
                "fuzzy_expanded": [
                    "type": "boolean",
                    "description": "At least one hit carries a spelling CLOSE to a "
                        + "word you asked for, not the word itself. Read that hit's "
                        + "fuzzy_distance and why.found before quoting it. Always "
                        + "present, in both modes.",
                ] as [String: Any],
                "hybrid_disarmed": [
                    "type": ["string", "null"],
                    "description": "Why the semantic channel was not used although "
                        + "it is available: \"exact_phrase\" when the query asks for "
                        + "a phrase between quotes, which meaning search cannot "
                        + "honour; \"no_vectors_in_scope\" when not one page of the "
                        + "folder or documents searched carries a vector (see "
                        + "semantic_scope and note). Null when it was used or "
                        + "unavailable.",
                ] as [String: Any],
                "has_more": ["type": "boolean"] as [String: Any],
                "next_cursor": ["type": ["string", "null"]] as [String: Any],
                "truncated": [
                    "type": "boolean",
                    "description": "The response hit the size limit and was shortened.",
                ] as [String: Any],
                "elapsed_ms": ["type": "number"] as [String: Any],
            ] as [String: Any],
        ]
    }

    // MARK: - Appel

    public func call(arguments: [String: Any]) throws -> ToolResult {
        let started = DispatchTime.now().uptimeNanoseconds
        let text = (arguments["query"] as? String) ?? ""
        let limit = min(Self.maxLimit, max(1, ToolSupport.int(arguments, "limit",
                                                              Self.defaultLimit)))
        let snippetChars = min(Self.maxSnippetChars,
                               max(80, ToolSupport.int(arguments, "snippet_chars",
                                                       Self.defaultSnippetChars)))
        let offset = try ToolSupport.offset(from: arguments)
        let mode = (arguments["mode"] as? String) ?? "auto"

        // Une requête refusée est une erreur d'OUTIL (`isError`), pas une
        // erreur JSON-RPC (audit A1m-07). La règle du § « Deux régimes » de
        // docs/mcp.md : une erreur de REQUÊTE est ce que le client a mal
        // formé (outil inconnu, argument du mauvais type) ; ici l'argument est
        // une chaîne parfaitement valide, c'est son CONTENU que le modèle doit
        // corriger — `azote OR carbone`, `spec*`, `-biologie` tout seul. Un
        // `-32602` sort de la boucle de l'outil chez plusieurs clients ; un
        // `isError` porte la phrase là où le modèle la lit et réessaie.
        // La CLI fait le même arbitrage : sortie 64 (usage), jamais 1 (panne).
        var plan: (query: SearchQuery, negative: String?)
        do {
            plan = try QueryParser.searchPlan(text, limit: limit + 1, offset: offset)
        } catch let error as QueryError {
            return .failure(
                "fouine_search.query: " + (error.errorDescription ?? "invalid query"))
        }
        // Les filtres d'ARGUMENT s'ajoutent à ceux de la SYNTAXE (`dossier:`,
        // `ext:`) : un client qui écrit les deux obtient l'intersection, ce qui
        // est la seule lecture qui ne surprenne personne.
        if let folder = ToolSupport.string(arguments, "folder") {
            plan.query.folders.append(folder)
        }
        if let ext = ToolSupport.string(arguments, "ext") {
            plan.query.exts.append(ext.lowercased()
                .trimmingCharacters(in: CharacterSet(charactersIn: ".")))
        }
        // Langue du document (lot U2) : un VRAI filtre, appliqué aux deux
        // canaux comme `folder` et `ext`. Les valeurs sont celles que
        // `fouine_status` publierait pour la facette « lang ».
        if let lang = ToolSupport.string(arguments, "lang") {
            plan.query.langs.append(lang.lowercased())
        }
        // Provenance de la PAGE (lot P3) : le seul filtre qui ne porte pas sur
        // le document. « ocr » couvre l'ancienne reconnaissance des bases
        // d'avant D1. Le `default` ne voit que l'ABSENCE du paramètre : toute
        // autre valeur est refusée en amont par l'énumération du schéma.
        switch ToolSupport.string(arguments, "source")?.lowercased() {
        case "ocr": plan.query.sources = PageSource.scanned
        case "native": plan.query.sources = PageSource.typed
        case "transcript": plan.query.sources = PageSource.transcribed
        default: break
        }
        plan.query.inDocIDs = ToolSupport.int64s(arguments, "doc_ids")
        // `since` : même sémantique que `fouine search --since`, et le même
        // arbitrage qu'elle — une date illisible est une ERREUR, pas une
        // recherche sans borne. Filtrer sur rien en silence rendrait une
        // réponse à une question qui n'a pas été posée, et le modèle n'aurait
        // aucun moyen de s'en apercevoir.
        if let since = ToolSupport.string(arguments, "since") {
            guard let after = DateWindow.startOfDay(iso8601: since) else {
                return .failure("fouine_search.since: write the date as YYYY-MM-DD "
                                + "(for example 2025-01-31)")
            }
            plan.query.modifiedAfter = after
        }
        // Le réglage du flou, que la CLI a depuis toujours (`--fuzzy`) : le
        // serveur imposait `auto`, donc une expansion silencieuse sous vingt
        // pages et aucun moyen de la couper.
        if let fuzzy = ToolSupport.string(arguments, "fuzzy"),
           let mode = FuzzyMode(rawValue: fuzzy) {
            plan.query.fuzzy = mode
        }
        plan.query.snippetMarkers = Self.markers(arguments)

        do {
            // `dossier:Xyz` — ou `folder: "Xyz"` — qui ne nomme aucune racine
            // rendait ZÉRO RÉSULTAT, sans un mot : pour un modèle, un corpus
            // qui ne contient rien sur le sujet (idée 5 de l'audit A1). Le
            // message nomme les étiquettes qui existent ; une simple
            // différence de casse est canonisée au passage.
            if !plan.query.folders.isEmpty {
                do {
                    plan.query.folders = try FolderCheck.resolve(
                        plan.query.folders, known: store.roots().map(\.label))
                } catch let error as QueryError {
                    return .failure("fouine_search: "
                                    + (error.errorDescription ?? "unknown folder"))
                }
            }
            // MÊME RÈGLE POUR LES DEUX AUTRES FILTRES QUI SE TROMPENT EN
            // SILENCE (CM-11). `lang: "xx"` et un `doc_ids` inexistant rendaient
            // un SUCCÈS à zéro résultat — pour le modèle, un corpus qui ne
            // traite pas le sujet. Le refus nomme ce qui existe, parce que c'est
            // ce qui lui permet de réessayer tout seul.
            if let refusal = try languageRefusal(plan.query.langs) {
                return .failure(refusal)
            }
            if let refusal = try documentRefusal(plan.query.inDocIDs) {
                return .failure(refusal)
            }
            let wantsHybrid = mode != "lexical"
            let available = semantic.isAvailable()
            // RK-01 : le sens n'est pas consulté quand la requête demande une
            // PHRASE entre guillemets — il n'a pas de guillemets, et versait au
            // classement des pages qui ne portent pas l'expression (4 sur 10,
            // jugé le 09/09/2026). Décidé ici : le modèle reçoit alors la
            // réponse lexicale entière, avec `mode_used: "lexical"`, la raison
            // dans `hybrid_disarmed` et la phrase dans `note`.
            // `available` compte dans la condition : quand le modèle manque,
            // la raison du repli est le modèle, et deux raisons publiées pour
            // un seul fait laisseraient le modèle en choisir une au hasard.
            var disarmed: SemanticDisarmReason? =
                wantsHybrid && available && QueryParser.asksForExactPhrase(text)
                ? .exactPhrase : nil
            // LE PÉRIMÈTRE AVANT LE MODÈLE (PM-06). `dossier:M2SU` en hybride
            // chargeait CoreML (2,3 s) et l'index vectoriel (1,9 s) pour
            // comparer zéro vecteur — le dossier n'en a pas un seul — puis
            // annonçait la couverture GLOBALE, 67,85 %, comme si elle décrivait
            // le dossier demandé. On lit donc le périmètre d'abord, et un
            // périmètre sans vecteur répond en lexical, en le disant.
            let scope = try semanticScope(plan: plan)
            if wantsHybrid, available, disarmed == nil, scope.vectors == 0 {
                disarmed = .noVectorsInScope
            }
            let facets = try Self.facets(
                key: ToolSupport.string(arguments, "facet"), offset: offset,
                plan: plan, store: store)
            // Rien à encoder (`nom:rapport` seul, lot QP1) : lexical, sans raison
            // publiée — ce n'est pas un repli, il n'y avait pas de sens à chercher.
            if wantsHybrid, available, disarmed == nil,
               !Self.semanticText(text).isEmpty,
               let payload = try hybrid(plan: plan, rawQuery: text, limit: limit,
                                        offset: offset, snippetChars: snippetChars,
                                        arguments: arguments, started: started,
                                        asked: mode, scope: scope, facets: facets) {
                return ToolResult(payload)
            }
            return ToolResult(try lexical(
                plan: plan, rawQuery: text,
                limit: limit, offset: offset, snippetChars: snippetChars,
                arguments: arguments, started: started,
                // UNE SEULE PHRASE PAR FAIT : la raison générique du
                // désarmement et la phrase chiffrée du périmètre disent la même
                // chose, et deux formulations du même fait se lisent comme deux
                // limites différentes. La chiffrée gagne : elle porte le geste.
                note: Self.notes(disarmed == .noVectorsInScope ? nil : disarmed?.advice,
                                 Self.noVectorsInScopeNote(scope, disarmed: disarmed,
                                                           folders: plan.query.folders),
                                 fallbackNote(asked: mode, available: available)),
                disarmed: disarmed, scope: scope, facets: facets))
        } catch let error as JSONRPCError {
            throw error
        } catch {
            return .failure("cannot search the Fouine index: " + MCPText.describe(error))
        }
    }

    // MARK: - Filtres dont la valeur n'existe pas (CM-11)

    /// `nil` = les langues demandées existent, ou il n'y a rien à contredire.
    ///
    /// ON NE REFUSE QUE CE QU'ON PEUT CONTREDIRE, exactement comme
    /// `FolderCheck` : sur un index dont aucun document ne porte de langue, la
    /// liste est vide et le filtre part tel quel — un refus fondé sur une liste
    /// vide serait un faux positif.
    private func languageRefusal(_ asked: [String]) throws -> String? {
        guard !asked.isEmpty else { return nil }
        let known = try store.knownLanguages()
        guard !known.isEmpty else { return nil }
        let folded = Set(known.map { $0.lowercased() })
        guard let unknown = asked.first(where: { !folded.contains($0.lowercased()) })
        else { return nil }
        return Self.unknownLanguageMessage(unknown, known: known)
    }

    /// `nil` = tous les documents demandés existent.
    private func documentRefusal(_ asked: [Int64]) throws -> String? {
        guard !asked.isEmpty else { return nil }
        let unknown = try store.unknownDocIDs(asked)
        guard !unknown.isEmpty else { return nil }
        return Self.unknownDocumentsMessage(unknown)
    }

    /// La phrase du refus, à part pour être éprouvée sans base.
    ///
    /// Elle est calquée sur `QueryError.unknownFolder` — mêmes guillemets, même
    /// tiret, même « voici les vraies » : c'est le MODÈLE qui la lit, et trois
    /// formulations différentes pour la même faute lui coûteraient un essai de
    /// plus à chaque fois.
    static func unknownLanguageMessage(_ asked: String, known: [String]) -> String {
        "fouine_search: unknown language “\(asked)” — languages in this index: "
        + known.joined(separator: ", ")
    }

    static func unknownDocumentsMessage(_ unknown: [Int64]) -> String {
        "fouine_search: unknown document id(s): "
        + unknown.map(String.init).joined(separator: ", ")
        + " — use fouine_list_documents to find the right ones"
    }

    /// Pourquoi le mode rendu diffère de celui demandé. `nil` en lexical
    /// demandé explicitement : il n'y a rien à expliquer.
    private func fallbackNote(asked: String, available: Bool) -> String? {
        guard asked != "lexical", !available else { return nil }
        if !semantic.modelInstalled {
            return "semantic model not installed — lexical only "
                + "(`fouine model download` installs it)"
        }
        return "no vector in the index yet — lexical only (`fouine embed` builds them)"
    }

    // MARK: - Canal lexical

    private func lexical(plan: (query: SearchQuery, negative: String?),
                         rawQuery: String,
                         limit: Int, offset: Int, snippetChars: Int,
                         arguments: [String: Any], started: UInt64,
                         note: String?,
                         disarmed: SemanticDisarmReason? = nil,
                         scope: SemanticScope,
                         facets: [String: Any]?) throws -> [String: Any] {
        let results = try store.search(plan.query, excludingDocsMatching: plan.negative)
        let hasMore = results.hits.count > limit
        let hits = Array(results.hits.prefix(limit))

        let rows = try documentRows(for: hits.map(\.docID))
        let meta = try store.pageMeta(for: hits.map { (docID: $0.docID, page: $0.page) })
        let notes = Self.notes(note, Self.veryCommonWordNote(results.totalsApproximate),
                               Self.fuzzyFallbackNote(results.fuzzyFallback),
                               Self.fuzzyExpandedNote(results.fuzzyExpanded,
                                                      fallback: results.fuzzyFallback),
                               Self.quorumNote(results.quorum))
        let words = HitExplanation.words(ofQuery: rawQuery)
        let names = try Self.nameMatches(results.nameMatches, rows: nameRows(results))
        // Tout ce qui coûte une LECTURE est calculé ici, avant `ToolBudget.fit`
        // qui refabrique la charge utile jusqu'à une dizaine de fois pour la
        // faire tenir : une sonde par essai serait une sonde de trop.
        let extras = try decorations(
            for: hits.map { (docID: $0.docID, page: $0.page, source: $0.source,
                             snippet: $0.snippet) },
            rows: rows, arguments: arguments, query: plan.query)
        let relevance = HitRelevance.percentages(bm25: hits.map(\.score))

        let (payload, truncated) = ToolBudget.fit(textChars: snippetChars,
                                                  count: hits.count) { chars, count in
            var entries: [[String: Any]] = []
            for (rank, hit) in hits.prefix(count).enumerated() {
                let rowid = Schema.ftsRowID(docID: hit.docID, page: hit.page)
                var entry = self.pageEntry(docID: hit.docID, page: hit.page,
                                           rows: rows, extras: extras)
                entry["snippet"] = String(hit.snippet.prefix(chars))
                entry["bm25"] = ToolSupport.decimal(hit.score, places: 4)
                entry["relevance_pct"] = relevance[rank]
                entry["source"] = ToolSupport.source(hit.source)
                entry["engine"] = ToolSupport.engine(meta[rowid]?.engine ?? .none)
                entry["fuzzy_distance"] = hit.fuzzyDistance
                entry["semantic_only"] = false
                entry["why"] = Self.why(words, text: hit.snippet,
                                        fuzzyDistance: hit.fuzzyDistance,
                                        tableOfContents: hit.tableOfContents,
                                        quorum: results.quorum)
                entries.append(entry)
            }
            return self.envelope(
                hits: entries, totalPages: results.totalPages,
                totalDocs: results.totalDocs,
                totalsApproximate: results.totalsApproximate,
                modeUsed: "lexical", scope: scope, stats: nil, note: notes,
                nameMatches: names, fuzzyFallback: results.fuzzyFallback,
                fuzzyExpanded: results.fuzzyExpanded,
                quorum: results.quorum,
                disarmed: disarmed,
                documents: self.documentMap(entries, rows: rows, extras: extras),
                facets: facets,
                hasMore: hasMore || entries.count < hits.count,
                offset: offset, arguments: arguments, started: started)
        }
        return truncated ? payload.merging(["truncated": true]) { _, new in new } : payload
    }

    // MARK: - Canal hybride

    /// Rend `nil` quand le sémantique se dérobe au dernier moment (index vidé
    /// entre la sonde et l'appel) : l'appelant enchaîne alors sur le lexical.
    private func hybrid(plan: (query: SearchQuery, negative: String?),
                        rawQuery: String, limit: Int, offset: Int,
                        snippetChars: Int, arguments: [String: Any],
                        started: UInt64, asked: String,
                        scope: SemanticScope,
                        facets: [String: Any]?) throws -> [String: Any]? {
        let engine = try semantic.loadedEncoder()
        guard let index = try semantic.currentIndex(dimension: engine.dimension),
              index.count > 0 else { return nil }

        var query = plan.query
        query.limit = limit          // l'hybride pagine lui-même : pas de +1 ici
        query.offset = 0
        let results = try store.hybrid(
            engine: engine, index: index, query: query,
            excludingDocsMatching: plan.negative,
            rawQuery: Self.semanticText(rawQuery), typedQuery: rawQuery,
            limit: limit, offset: offset,
            // Le périmètre est déjà lu (il a décidé qu'on entrait ici) : la
            // fusion n'a pas à le recompter.
            scope: scope)

        let rows = try documentRows(for: results.hits.map(\.docID))
        let meta = try store.pageMeta(
            for: results.hits.map { (docID: $0.docID, page: $0.page) })
        // Les extraits sémantiques purs sont plafonnés à 220 caractères par
        // `HybridSearch` ; on les relit à la longueur DEMANDÉE, sans quoi
        // `snippet_chars: 800` ne s'appliquerait qu'aux hits lexicaux et deux
        // hits de la même liste n'auraient pas le même contrat.
        let semanticOnly = results.hits.filter { $0.lexical == nil }
            .compactMap { ToolSupport.rowid(docID: $0.docID, page: $0.page) }
        let previews = try store.pagePreviews(for: semanticOnly, maxChars: snippetChars)

        // `HybridResults` ne porte pas le drapeau de comptage borné : il se
        // retrouve exactement, le compte lexical étant BORNÉ au seuil quand il
        // est approché (`GRDBStore.counts`).
        let approximate = results.lexTotalPages >= Schema.approximateCountThreshold
        let note = Self.notes(coverageNote(results.scope.coveragePct,
                                           filtered: results.scope.filtered),
                              Self.nothingScannedNote(results.semantic.scanned,
                                                      scope: results.scope),
                              Self.veryCommonWordNote(approximate),
                              Self.noLexicalMatchNote(
                                  lexTotalPages: results.lexTotalPages,
                                  hits: results.hits.count),
                              // Le repli en flou du canal lexical, que la fusion
                              // transporte depuis le lot RK1 : le mot cité dans
                              // la réponse du modèle n'est pas celui qu'on lui a
                              // donné, dans ce mode comme dans l'autre.
                              Self.fuzzyFallbackNote(results.fuzzyFallback),
                              Self.fuzzyExpandedNote(results.fuzzyExpanded,
                                                     fallback: results.fuzzyFallback),
                              Self.quorumNote(results.quorum))
        let words = HitExplanation.words(ofQuery: rawQuery)
        // LE CANAL DES NOMS EN HYBRIDE : une requête à part. `HybridResults` ne
        // porte pas ce champ — c'est `HybridSearch.run` qui appelle le canal
        // lexical — et un assistant qui cherche un nom de fichier ne doit pas
        // dépendre du mode.
        let namedDocuments = offset == 0
            ? try store.documentsMatchingName(query) : []
        let names = try Self.nameMatches(namedDocuments,
                                         rows: documentRows(for: namedDocuments.map(\.id)))
        let extras = try decorations(
            for: results.hits.map { hit in
                let rowid = Schema.ftsRowID(docID: hit.docID, page: hit.page)
                return (docID: hit.docID, page: hit.page,
                        source: hit.lexical?.source ?? meta[rowid]?.source ?? .native,
                        snippet: hit.lexical?.snippet ?? previews[rowid]?.preview
                            ?? hit.preview)
            },
            rows: rows, arguments: arguments, query: plan.query)
        // EN HYBRIDE, LA PERTINENCE SE LIT SUR LE RRF et non sur le `bm25`
        // (`HitRelevance`) : une page trouvée par le seul canal du sens n'a pas
        // de `bm25`, et la moitié d'une liste hybride serait sans pourcentage.
        let relevance = HitRelevance.percentages(rrf: results.hits.map(\.rrf))

        let (payload, truncated) = ToolBudget.fit(
            textChars: snippetChars, count: results.hits.count) { chars, count in
            var entries: [[String: Any]] = []
            for (rank, hit) in results.hits.prefix(count).enumerated() {
                let rowid = Schema.ftsRowID(docID: hit.docID, page: hit.page)
                var entry = self.pageEntry(docID: hit.docID, page: hit.page,
                                           rows: rows, extras: extras)
                entry["snippet"] = String(
                    (hit.lexical?.snippet ?? previews[rowid]?.preview ?? hit.preview)
                        .prefix(chars))
                entry["bm25"] = hit.lexical
                    .map { ToolSupport.decimal($0.score, places: 4) as Any } ?? NSNull()
                entry["relevance_pct"] = relevance[rank]
                entry["source"] = ToolSupport.source(
                    hit.lexical?.source ?? meta[rowid]?.source ?? .native)
                entry["engine"] = ToolSupport.engine(meta[rowid]?.engine ?? .none)
                entry["fuzzy_distance"] = hit.lexical?.fuzzyDistance ?? 0
                entry["rrf"] = ToolSupport.decimal(hit.rrf, places: 6)
                entry["lex_rank"] = hit.lexRank.map { $0 as Any } ?? NSNull()
                entry["vec_rank"] = hit.vecRank.map { $0 as Any } ?? NSNull()
                entry["cosine"] = hit.cosine
                    .map { ToolSupport.decimal(Double($0), places: 3) as Any } ?? NSNull()
                entry["z"] = hit.z.map { ToolSupport.decimal($0) as Any } ?? NSNull()
                entry["semantic_only"] = hit.lexical == nil
                entry["why"] = Self.why(
                    words,
                    text: hit.lexical?.snippet ?? previews[rowid]?.preview
                        ?? hit.preview,
                    fuzzyDistance: hit.lexical?.fuzzyDistance ?? 0,
                    lexRank: hit.lexRank, vecRank: hit.vecRank,
                    quorum: results.quorum)
                entries.append(entry)
            }
            return self.envelope(
                hits: entries, totalPages: results.lexTotalPages,
                totalDocs: results.lexTotalDocs,
                totalsApproximate: approximate,
                modeUsed: "hybrid", scope: results.scope,
                stats: Self.semanticStats(results.semantic),
                rankScale: results.semanticRankScale, note: note,
                nameMatches: names, fuzzyFallback: results.fuzzyFallback,
                fuzzyExpanded: results.fuzzyExpanded,
                // LE QUORUM EXISTE AUSSI EN HYBRIDE, et le taire était le
                // constat PM-14 : le canal lexical de la fusion le joue (la
                // requête que le serveur lui passe l'a armé), et ce sont donc
                // bien des pages qui ne portent pas tous les mots qui entrent
                // au RRF. Depuis le lot MN1, la ligne de commande l'arme aussi
                // dans ce mode : une seule convention pour les deux surfaces,
                // celle-ci — d'où la valeur portée par les résultats plutôt
                // qu'une constante.
                quorum: results.quorum,
                documents: self.documentMap(entries, rows: rows, extras: extras),
                facets: facets,
                hasMore: results.hasMore || entries.count < results.hits.count,
                offset: offset, arguments: arguments, started: started)
        }
        return truncated ? payload.merging(["truncated": true]) { _, new in new } : payload
    }

    /// Les notes se CUMULENT : un repli sur le lexical et un mot très fréquent
    /// sont deux limites différentes du même résultat, et n'en publier qu'une
    /// cacherait l'autre. Séparateur « · », comme la ligne d'état de la CLI.
    static func notes(_ parts: String?...) -> String? {
        let kept = parts.compactMap { $0 }.filter { !$0.isEmpty }
        return kept.isEmpty ? nil : kept.joined(separator: " · ")
    }

    /// Le mot est partout : le dire au modèle, qui peut ajouter un second terme
    /// de lui-même — ce que l'utilisateur devant sa barre de recherche ne fera
    /// que s'il comprend pourquoi (audit A1m-08).
    static func veryCommonWordNote(_ totalsApproximate: Bool) -> String? {
        totalsApproximate ? SearchAdvice.veryCommonWord : nil
    }

    /// AUCUNE page ne porte les mots, et il y a pourtant des résultats : ils
    /// viennent du sens seul. Pour un modèle, c'est la différence entre « le
    /// corpus traite de ça » et « le corpus n'en parle pas, voici ce qui s'en
    /// rapproche le plus » — et rien d'autre dans la réponse ne la dit
    /// (R-04 ; ce n'est PAS un filtre, cf. `SearchAdvice.noLexicalMatch`).
    static func noLexicalMatchNote(lexTotalPages: Int, hits: Int) -> String? {
        lexTotalPages == 0 && hits > 0 ? SearchAdvice.noLexicalMatch : nil
    }

    /// La recherche exacte n'a rien rendu et la requête a été rejouée en
    /// tolérant les fautes (C2-08). Pour un modèle, c'est la différence entre
    /// « le corpus dit ceci » et « le corpus dit quelque chose de proche » : le
    /// mot cité dans sa réponse n'est PAS celui qu'on lui a donné, et chaque hit
    /// porte sa `fuzzy_distance`.
    static func fuzzyFallbackNote(_ fallback: Bool) -> String? {
        fallback ? SearchAdvice.fuzzyFallback : nil
    }

    /// L'expansion floue ORDINAIRE (lot MC2, PM-13) : des résultats portent une
    /// orthographe proche sans que la recherche ait eu à se replier. PAS EN
    /// MÊME TEMPS que le repli, qui dit déjà la même chose en plus fort — deux
    /// phrases sur le même fait feraient croire à deux limites.
    static func fuzzyExpandedNote(_ expanded: Bool, fallback: Bool) -> String? {
        expanded && !fallback ? SearchAdvice.fuzzyExpanded : nil
    }

    /// Moins de dix pages portaient TOUS les mots : la recherche a aussi rendu
    /// celles qui en portent la plupart (lot RK2, RK-04). Pour un modèle, la
    /// différence est celle entre « ces pages répondent à ma question » et
    /// « ces pages en traitent une partie » : la tête de liste porte tout, la
    /// suite non, et rien d'autre dans la réponse ne le dit.
    static func quorumNote(_ quorum: Bool) -> String? {
        quorum ? SearchAdvice.quorum : nil
    }

    // MARK: - Canal des noms de fichier (PR-02)

    /// Les documents dont le NOM répond, en clés du contrat. Une entrée par
    /// document, jamais mêlée aux `hits` : un nom ne désigne aucune page, et
    /// `page: 1` du lien est un point d'entrée, pas un résultat.
    static func nameMatches(_ documents: [DocumentListing],
                            rows: [Int64: DocRow]) throws -> [[String: Any]] {
        documents.map { doc in
            var entry = ToolSupport.pageFields(rows[doc.id], docID: doc.id, page: 1)
            entry["doc_id"] = doc.id
            entry["n_pages"] = doc.nPages
            return entry
        }
    }

    private func nameRows(_ results: SearchResults) throws -> [Int64: DocRow] {
        try documentRows(for: results.nameMatches.map(\.id))
    }

    /// L'objet `why` d'un hit (A1-08), ou `null`.
    ///
    /// Calculé sur l'EXTRAIT et non sur la page relue : le coût est nul, et
    /// c'est l'extrait que le modèle a sous les yeux. `null` — et non une clé
    /// absente — quand il n'y a rien d'honnête à dire : un champ absent
    /// n'apprend rien à un modèle, c'est la règle de tout ce fichier.
    ///
    /// `textIsWholePage: false` : sur un extrait, l'absence d'un mot ne prouve
    /// rien, et un hit lexical porte de toute façon TOUS les mots positifs
    /// (`a AND b`). `terms_missing` n'apparaît donc jamais ici — le prétendre
    /// ferait conclure au modèle que le corpus ne traite qu'à moitié du sujet.
    ///
    /// `quorum` (PM-14) : la passe de quorum a relâché le ET, et le
    /// raisonnement ci-dessus tombe — une page peut ne porter que trois des
    /// neuf mots. `HitExplanation` rend alors `partial` avec ce que l'extrait
    /// montre, et toujours aucun manque : un extrait ne prouve pas une absence.
    /// Sans ce drapeau, le serveur annonçait `exact` avec les neuf mots.
    static func why(_ words: [QueryWord], text: String, fuzzyDistance: Int,
                    lexRank: Int? = nil, vecRank: Int? = nil,
                    tableOfContents: Bool = false,
                    quorum: Bool = false) -> Any {
        HitExplanation(words: words, text: text, fuzzyDistance: fuzzyDistance,
                       lexRank: lexRank, vecRank: vecRank,
                       textIsWholePage: false, quorum: quorum)
            .map { HitExplanation.json($0, tableOfContents: tableOfContents) as Any }
            ?? NSNull()
    }

    /// Sous 50 % de couverture, le dire : un modèle qui ne trouve rien doit
    /// savoir que le canal sémantique ne voit qu'une part du corpus (C2-02).
    /// La couverture est celle du PÉRIMÈTRE depuis le lot MC2, et la phrase le
    /// dit quand un filtre porte — « 67,85 % » sur un dossier à 0 % était le
    /// constat PM-06.
    private func coverageNote(_ pct: Double, filtered: Bool) -> String? {
        guard pct < 50 else { return nil }
        return String(format: "only %.1f %% of the pages ", pct)
            + (filtered ? "searched here" : "in the index")
            + " are vectorised — semantic hits are drawn from that subset; "
            + "`fouine embed` extends it"
    }

    /// LE PÉRIMÈTRE N'A PAS UN VECTEUR : la phrase avec les deux nombres et le
    /// geste (PM-06). Elle accompagne `hybrid_disarmed: "no_vectors_in_scope"`,
    /// qui dit le fait ; elle, elle dit lequel et quoi faire.
    ///
    /// Ici, la seule GARDE : le texte vit auprès de la raison
    /// (`SemanticDisarmReason.noVectorsInScopeNote`, FouineEmbed) depuis le lot
    /// MN1 — la ligne de commande en portait la copie au mot près.
    static func noVectorsInScopeNote(_ scope: SemanticScope,
                                     disarmed: SemanticDisarmReason?,
                                     folders: [String]) -> String? {
        guard disarmed == .noVectorsInScope else { return nil }
        return SemanticDisarmReason.noVectorsInScopeNote(scope, folders: folders)
    }

    /// Le canal sémantique était armé et n'a comparé AUCUN vecteur, pour une
    /// autre raison que le périmètre vide (un index vectoriel qui vient d'être
    /// purgé, un filtre de provenance qui ne laisse rien passer). `scanned: 0`
    /// était le seul indice, noyé dans `semantic_stats`.
    static func nothingScannedNote(_ scanned: Int, scope: SemanticScope) -> String? {
        guard scanned == 0, scope.vectors > 0 else { return nil }
        return "the meaning channel compared nothing on this query — "
            + "these results are full-text only"
    }

    /// Texte envoyé au modèle : la requête débarrassée des filtres, des
    /// exclusions et des guillemets — le canal vectoriel n'a pas de syntaxe.
    /// Même transformation que `CommandsSearch.semanticText`.
    static func semanticText(_ query: String) -> String {
        QueryParser.semanticText(query)
    }

    /// `semantic_stats` — le MÊME objet que `fouine search --hybrid --json`
    /// (C2-01) : c'est ce qui permet de savoir si le canal sémantique avait
    /// quelque chose à dire, ce que le cosinus seul ne dit pas.
    static func semanticStats(_ s: SemanticStats) -> [String: Any] {
        var out: [String: Any] = [
            "mu": ToolSupport.decimal(s.mu, places: 4),
            "sigma": ToolSupport.decimal(s.sigma, places: 4),
            "scanned": s.scanned,
            "zero_vectors": s.zeroVectors,
        ]
        if let c = s.cosMax { out["cos_max"] = ToolSupport.decimal(Double(c), places: 4) }
        if let z = s.zMax { out["z_max"] = ToolSupport.decimal(z) }
        if let z = s.zAt10 { out["z_at_10"] = ToolSupport.decimal(z) }
        if let z = s.zAt200 { out["z_at_200"] = ToolSupport.decimal(z) }
        return out
    }

    // MARK: - Habillage commun

    private func envelope(hits: [[String: Any]], totalPages: Int, totalDocs: Int,
                          totalsApproximate: Bool, modeUsed: String,
                          scope: SemanticScope, stats: [String: Any]?,
                          rankScale: Double? = nil,
                          note: String?,
                          nameMatches: [[String: Any]] = [],
                          fuzzyFallback: Bool = false,
                          fuzzyExpanded: Bool = false,
                          quorum: Bool = false,
                          disarmed: SemanticDisarmReason? = nil,
                          documents: [String: Any] = [:],
                          facets: [String: Any]? = nil,
                          hasMore: Bool, offset: Int,
                          arguments: [String: Any], started: UInt64) -> [String: Any] {
        let elapsed = Double(DispatchTime.now().uptimeNanoseconds - started) / 1_000_000
        // LA COUVERTURE EST CELLE DU PÉRIMÈTRE (PM-06) : sans filtre c'est le
        // chiffre global d'avant, avec un filtre c'est enfin celui de ce qui a
        // été cherché. `null` sur un index vide, comme avant.
        let coverage: Any = scope.pagesIndexed > 0
            ? ToolSupport.coveragePercentage(vectorisedPages: scope.vectors,
                                             indexedPages: scope.pagesIndexed)
            : NSNull()
        var payload: [String: Any] = [
            "hits": hits,
            "total_pages": totalPages,
            "total_docs": totalDocs,
            "totals_approximate": totalsApproximate,
            "mode_used": modeUsed,
            "semantic_available": semantic.isAvailable(),
            "semantic_coverage_pct": coverage,
            // TOUJOURS PRÉSENTE : trois nombres disent ce que le sens VOIT de
            // cette recherche, là où un pourcentage seul laissait croire qu'il
            // décrivait le dossier demandé.
            "semantic_scope": ["pages": scope.pagesIndexed,
                               "vectorised": scope.vectors,
                               "filtered": scope.filtered] as [String: Any],
            "semantic_stats": stats.map { $0 as Any } ?? NSNull(),
            // L'échelle appliquée aux rangs sémantiques (lot R1) : le serveur
            // l'appliquait sans la dire, et `rrf` ne se relisait plus
            // (AUDIT-R1 I4). Même arrondi que `fouine search --hybrid --json`.
            "semantic_rank_scale": rankScale.map { ToolSupport.decimal($0) as Any } ?? NSNull(),
            "note": note.map { $0 as Any } ?? NSNull(),
            // LES DEUX CLÉS DU LOT MP1. Elles sont TOUJOURS présentes, comme
            // tout ce fichier : un champ absent n'apprend rien à un modèle —
            // `name_matches: []` dit « aucun nom ne répond », une clé manquante
            // laisserait croire que le canal n'existe pas.
            "name_matches": nameMatches,
            "fuzzy_fallback": fuzzyFallback,
            // Le drapeau qui MANQUAIT (PM-13) : `fuzzy_fallback` ne dit que le
            // repli, et onze pages d'orthographes approchées sortaient en mode
            // ordinaire sans que rien ne le signale.
            "fuzzy_expanded": fuzzyExpanded,
            // Un chemin par DOCUMENT plutôt qu'un par hit (PM-24, PM-28) :
            // rempli sous `compact`, vide sinon — et toujours présent, comme
            // tout ce fichier.
            "documents": documents,
            "facets": facets.map { $0 as Any } ?? NSNull(),
            // TOUJOURS PRÉSENTE elle aussi (lot RK2) : `quorum: false` dit que
            // chaque page rendue porte tous les mots, ce qu'un modèle doit
            // pouvoir lire sans avoir à le supposer.
            "quorum": quorum,
            // POURQUOI le sens n'a pas servi, quand ce n'est pas le modèle qui
            // manque (RK-01) : `mode_used: "lexical"` seul laisserait croire à
            // une installation incomplète. `null` le reste du temps, comme tout
            // ce fichier : une clé absente n'apprend rien à un modèle.
            "hybrid_disarmed": disarmed.map { $0.rawValue as Any } ?? NSNull(),
            "has_more": hasMore,
            "elapsed_ms": ToolSupport.decimal(elapsed),
        ]
        payload["next_cursor"] = hasMore
            ? Cursor.encode(offset: offset + hits.count, arguments: arguments) as Any
            : NSNull()
        return payload
    }

    /// Les lignes `docs` des hits, une sonde par document (clé primaire).
    private func documentRows(for ids: [Int64]) throws -> [Int64: DocRow] {
        var out: [Int64: DocRow] = [:]
        for id in Set(ids) { out[id] = try store.docRow(id: id) }
        return out
    }

    // MARK: - Périmètre du sens (PM-06)

    /// Ce que le canal du sens voit de CETTE recherche.
    ///
    /// LE CALCUL N'A LIEU QUE S'IL PEUT CHANGER QUELQUE CHOSE : sans filtre de
    /// document, ou sur un index sans le moindre vecteur, les chiffres globaux
    /// sont déjà la réponse — et ce sont deux lectures que payait chaque
    /// recherche sans rien apprendre.
    private func semanticScope(plan: (query: SearchQuery, negative: String?)) throws
        -> SemanticScope {
        let vectors = try store.vectorisedPageCount()
        let pages = try store.indexedPageCount()
        guard vectors > 0, plan.query.filtersDocuments else {
            return SemanticScope(vectors: vectors, pagesIndexed: pages,
                                 filtered: false)
        }
        return try store.semanticScope(query: plan.query,
                                       excludingDocsMatching: plan.negative,
                                       vectors: vectors, pagesIndexed: pages)
    }

    // La question « cette requête restreint-elle l'ensemble des DOCUMENTS ? »
    // est une propriété de `SearchQuery` depuis le lot MN1
    // (`query.filtersDocuments`, FouineCore) : la ligne de commande en portait
    // la copie, et onze conditions recopiées divergent au premier filtre
    // ajouté.

    // MARK: - Facettes (PM-16e)

    /// Les valeurs de la facette demandée et leur compte, ou `nil`.
    ///
    /// PREMIÈRE PAGE SEULEMENT : un curseur ne recalcule pas les facettes —
    /// elles portent sur toute la recherche, pas sur la tranche, et les
    /// recompter à chaque page coûterait un balayage complet pour rendre
    /// exactement les mêmes nombres.
    static func facets(key name: String?, offset: Int,
                       plan: (query: SearchQuery, negative: String?),
                       store: ReadOnlyStore) throws -> [String: Any]? {
        guard let name, offset == 0, let key = Self.facetKey(name) else { return nil }
        let counts = try store.facets(plan.query, by: key,
                                      excludingDocsMatching: plan.negative)
        var out: [String: Any] = [:]
        for (value, count) in counts where !value.isEmpty { out[value] = count }
        return [name: out]
    }

    /// `modified_year` PLUTÔT QUE `year` : les deux facettes d'année répondaient
    /// à des questions différentes sous des noms qui ne le disaient pas, et
    /// l'audit a montré qu'on posait l'une en lisant l'autre (`year` compte les
    /// dates du FICHIER — 193 documents « 2026 » pour un corpus de cours de
    /// 2024). Le cœur s'appelle encore `.year` ; le nom exposé au modèle est
    /// celui que la ligne de commande prendra (lot MC3).
    static func facetKey(_ name: String) -> FacetKey? {
        name == "modified_year" ? .year : FacetKey(rawValue: name)
    }

    // MARK: - Ce que chaque hit porte en plus (PM-19, PM-22, PM-24)

    /// Les marqueurs de surlignage demandés (`marks`).
    static func markers(_ arguments: [String: Any]) -> (open: String, close: String) {
        switch ToolSupport.string(arguments, "marks") {
        case "brackets":  return ("[", "]")
        case "asterisks": return ("**", "**")
        case "none":      return ("", "")
        default:          return ("«", "»")
        }
    }

    /// Ce qu'il a fallu LIRE pour habiller les hits — une fois, avant que
    /// `ToolBudget.fit` ne refabrique la charge utile.
    struct Decorations {
        /// Pages de texte des conteneurs qui rangent leurs images après
        /// (`PageLayout.textThenMedia`), par document.
        let textPages: [Int64: Int]
        /// Moment de la page transcrite, en secondes, par rowid.
        let times: [Int64: Int]
        /// `compact` : les chemins quittent les hits pour `documents`.
        let compact: Bool
    }

    private func decorations(
        for pages: [(docID: Int64, page: Int, source: PageSource, snippet: String)],
        rows: [Int64: DocRow], arguments: [String: Any],
        query: SearchQuery) throws -> Decorations {
        // 1. La frontière diapositives / images incorporées, pour les seuls
        //    documents concernés : une requête, rien pour un PDF.
        let containers = Set(pages.map(\.docID)).filter {
            PageLayout.textThenMedia.contains(
                (rows[$0]?.record.ext ?? "").lowercased())
        }
        let textPages = containers.isEmpty
            ? [:] : try store.textPageCounts(forDocIDs: Array(containers))

        // 2. Le moment d'une page transcrite. L'extrait suffit le plus souvent
        //    (le marqueur qui précède le mot trouvé) ; sinon, et seulement
        //    alors, on relit le DÉBUT de la page — soixante-quatre caractères,
        //    de quoi porter un `[00:01] `.
        var times: [Int64: Int] = [:]
        var unresolved: [Int64] = []
        for page in pages where page.source == .transcript {
            guard let rowid = ToolSupport.rowid(docID: page.docID, page: page.page)
            else { continue }
            if let seconds = TranscriptTime.seconds(
                inSnippet: page.snippet, opening: query.snippetMarkers.open) {
                times[rowid] = seconds
            } else {
                unresolved.append(rowid)
            }
        }
        if !unresolved.isEmpty {
            let heads = try store.pagePreviews(for: unresolved, maxChars: 64)
            for rowid in unresolved {
                if let text = heads[rowid]?.preview,
                   let seconds = TranscriptTime.first(in: text) {
                    times[rowid] = seconds
                }
            }
        }
        return Decorations(textPages: textPages, times: times,
                           compact: ToolSupport.bool(arguments, "compact", false))
    }

    /// Les champs d'identité d'un hit : `doc_id`, `page`, ce que la page
    /// DÉSIGNE, et — hors `compact` — les chemins et le lien.
    private func pageEntry(docID: Int64, page: Int,
                           rows: [Int64: DocRow],
                           extras: Decorations) -> [String: Any] {
        let rowid = ToolSupport.rowid(docID: docID, page: page)
        let time = rowid.flatMap { extras.times[$0] }
        var entry: [String: Any] = extras.compact
            ? [:]
            : ToolSupport.pageFields(rows[docID], docID: docID, page: page,
                                     time: time)
        entry["doc_id"] = docID
        entry["page"] = page
        entry["time_seconds"] = time.map { $0 as Any } ?? NSNull()
        let label = PageLayout.page(page, ext: rows[docID]?.record.ext ?? "",
                                    textPages: extras.textPages[docID])
        entry["slide"] = label.slide.map { $0 as Any } ?? NSNull()
        entry["embedded_image"] = label.embeddedImage.map { $0 as Any } ?? NSNull()
        return entry
    }

    /// Les documents de ces hits, une fois chacun (`compact`).
    ///
    /// LES DEUX CONSTATS EN UNE CLÉ : les trois chemins pesaient 56 % d'une
    /// réponse de dix hits (PM-24), et une liste plate faisait lire « trois
    /// sources » là où un même cours occupait trois places (PM-28). Un objet
    /// indexé par `doc_id` répond aux deux : le chemin est écrit une fois, et
    /// `hits` dit combien de fois ce document a répondu.
    private func documentMap(_ entries: [[String: Any]], rows: [Int64: DocRow],
                             extras: Decorations) -> [String: Any] {
        guard extras.compact else { return [:] }
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
}
