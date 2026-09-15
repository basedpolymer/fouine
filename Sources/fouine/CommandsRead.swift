// CommandsRead.swift — `fouine read` et `fouine similar` : LIRE ce qu'on a
// trouvé, et trouver ce qui lui ressemble (constats PM-18 et PM-16).
// Propriété : A-Core.
// SPDX-License-Identifier: LicenseRef-Fouine-Source-Available
//
// CE QUE ÇA RÉPARE. `fouine search` dit OÙ regarder ; rien ne disait CE QU'IL Y
// A. Le serveur MCP, lui, le sait depuis le palier 4 (`fouine_read_page`,
// `fouine_similar_pages`) : un assistant pouvait lire une page trouvée, un
// humain au terminal — ou un agent qui n'a que le shell — non. Ce que
// l'assistant peut faire, l'humain doit pouvoir le faire (même règle que
// `fouine list`, lot BR1).
//
// UNE SEULE IMPLÉMENTATION, PAS DEUX. `fouine read` passe par `PageReading`
// (FouineCore), que l'outil MCP reprendra : l'audit a montré où mène la
// duplication — le même nombre s'appelle `score` d'un côté et `bm25` de
// l'autre (PM-16b). Les clés de `--json` sont donc, au mot près, celles des
// outils correspondants.
//
// `similar` NE CHARGE PAS LE MODÈLE. Les voisins d'une page se lisent sur les
// vecteurs DÉJÀ en base : ~10 ms et quelques mégaoctets, contre 571 Mo et 2,6 s
// pour CoreML. Une page sans vecteur n'est donc pas une panne à réparer ici,
// c'est une campagne qui n'est pas passée : sortie 1, et le geste.
//
// LECTURE SEULE des deux côtés (`openStoreReadOnly`) : lire une page pendant
// une passe d'indexation doit marcher.

import Foundation
import ArgumentParser
import FouineCore
import FouineEmbed

// MARK: - fouine read

struct ReadCommand: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "read",
        abstract: "Read the indexed text of one page.",
        discussion: """
            Returns the text Fouine extracted or recognised, NOT the original \
            file: `abs_path` says where the file is, opening it is up to you. \
            Long pages come back in slices — pass the announced next offset \
            back to --offset. A page that exists but carries no indexed text \
            is a success with an empty text and a note, not an error.
            """)

    @Argument(help: "Document identifier (`fouine search --json` gives doc_id).")
    var docID: Int64

    @Argument(help: "Page number, 1-indexed.")
    var page: Int

    @Option(name: .customLong("max-chars"),
            help: "Characters to read from this page, and from each context page.")
    var maxChars: Int = 4_000

    @Option(name: .long, help: "Start reading this many characters in.")
    var offset: Int = 0

    @Option(name: .long, help: "Also read this many pages before and after (0-2).")
    var context: Int = 0

    @Flag(name: .long, help: "JSON output.")
    var json = false

    /// Bornes en 64, AVANT la base : une valeur hors plage est une faute de
    /// frappe, pas une panne (§4.3). Les bornes sont celles de l'outil MCP.
    func validate() throws {
        guard docID >= 1 else { throw ValidationError("doc_id must be 1 or more.") }
        guard page >= 1, page <= Schema.maxPage else {
            throw ValidationError("page must be between 1 and \(Schema.maxPage).")
        }
        guard maxChars >= 200, maxChars <= 40_000 else {
            throw ValidationError("--max-chars must be between 200 and 40000.")
        }
        guard offset >= 0 else { throw ValidationError("--offset must be 0 or more.") }
        guard context >= 0, context <= 2 else {
            throw ValidationError("--context must be between 0 and 2.")
        }
    }

    func run() {
        CLI.guarded {
            let store = try CLI.openStoreReadOnly()
            let reading: PageReading
            do {
                reading = try PageReading.load(
                    store: store, docID: docID, page: page, maxChars: maxChars,
                    offset: offset, contextPages: context,
                    missingTextNote: PageReading.commandMissingTextNote)
            } catch let failure as PageReading.Failure {
                // Une page qui n'existe pas est une erreur d'USAGE (64), avec
                // le nombre de pages que le document a vraiment : c'est le
                // renseignement qui évite le second essai à l'aveugle.
                throw UsageRefusal(message: failure.description
                                   + Self.hint(for: failure))
            }
            if json {
                // Ce que la page DÉSIGNE (lot CL2) : une requête pour la
                // frontière diapositives / images incorporées, rien pour un PDF.
                let ext = reading.page.ext.lowercased()
                let textPages = PageLayout.textThenMedia.contains(ext)
                    ? try store.textPageCounts(forDocIDs: [docID])[docID] : nil
                var body = reading.json()
                Self.decorate(&body, page: reading.page, textPages: textPages)
                if var context = body["context"] as? [[String: Any]] {
                    for index in context.indices where index < reading.context.count {
                        Self.decorate(&context[index], page: reading.context[index],
                                      textPages: textPages)
                    }
                    body["context"] = context
                }
                try CLI.printJSON(body)
                return
            }
            print(Self.header(reading.page, pageCount: reading.pageCount))
            print(reading.page.text)
            if let note = reading.page.note { print("(\(note))") }
            if reading.page.truncated, let next = reading.page.nextOffset {
                print("… \(reading.page.totalChars - next) character(s) left "
                      + "— `--offset \(next)` for the rest")
            }
            for neighbour in reading.context {
                print("")
                print(Self.header(neighbour, pageCount: reading.pageCount))
                print(neighbour.text)
            }
        }
    }

    /// L'en-tête d'une page : de quel document, où, quelle page, d'où vient le
    /// texte. Une ligne — le reste de la sortie est la page elle-même, et un
    /// cartouche de cinq lignes la noierait.
    static func header(_ page: PageReading.Page, pageCount: Int) -> String {
        let total = pageCount > 0 ? "/\(pageCount)" : ""
        return "[\(page.docID)] \(page.relPath) · page \(page.number)\(total) · "
            + GRDBStore.sourceLabel(page.source.rawValue)
    }

    /// `slide`, `embedded_image`, `time_seconds` — et le lien horodaté qui va
    /// avec (lot CL2). Les mêmes quatre champs que `fouine_read_page`, avec
    /// `page_label` que `PageReading` porte déjà : la page qu'on va citer doit
    /// se citer de la même façon des deux côtés. « Page 170 » d'un cours est
    /// souvent la 117ᵉ image incorporée, et « page 1 » d'une vidéo de deux
    /// heures ne renvoie personne nulle part.
    ///
    /// Le moment se lit sur le TEXTE RENDU, sans lecture de plus : une page de
    /// transcription commence par son marqueur (`[00:01] …`), et c'est celui-là
    /// qu'il faut — il n'y a pas ici d'extrait qui désignerait un paragraphe
    /// plus loin.
    static func decorate(_ body: inout [String: Any], page: PageReading.Page,
                         textPages: Int?) {
        let time = page.source == .transcript
            ? TranscriptTime.first(in: page.text) : nil
        body["time_seconds"] = time.map { $0 as Any } ?? NSNull()
        if let time {
            body["link"] = DeepLink.link(absolutePath: page.absPath,
                                         docID: page.docID, page: page.number,
                                         time: time).absoluteString
        }
        let label = PageLayout.page(page.number, ext: page.ext,
                                    textPages: textPages)
        body["slide"] = label.slide.map { $0 as Any } ?? NSNull()
        body["embedded_image"] = label.embeddedImage.map { $0 as Any } ?? NSNull()
    }

    /// Le geste, quand la demande est impossible.
    static func hint(for failure: PageReading.Failure) -> String {
        switch failure {
        case .unknownDocument: return " — `fouine list` shows what is indexed"
        default: return ""
        }
    }
}

// MARK: - fouine similar

struct SimilarCommand: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "similar",
        abstract: "List the pages closest in meaning to a given page.",
        discussion: """
            Reads the vectors ALREADY in the index and never loads the model, \
            so it answers in milliseconds — but a page that has not been \
            vectorised yet has no neighbours to offer (exit 1, saying so). \
            `fouine embed --status` tells how far the campaign is.

            The cosine is NOT a relevance: on a real corpus every value sits \
            between 0.78 and 0.88, and the position inside that band follows \
            the shape of the text more than its subject. That is why \
            --min-cosine defaults to 0, no floor at all.
            """)

    @Argument(help: "Document identifier (`fouine search --json` gives doc_id).")
    var docID: Int64

    @Argument(help: "Page number, 1-indexed.")
    var page: Int

    @Option(name: .long, help: "Neighbours to return (max \(SimilarCommand.maxLimit)).")
    var limit: Int = 10

    @Option(name: .long, help: "Restrict to one root label (`fouine root list`).")
    var folder: String?

    @Option(name: .long, help: "Restrict to one extension, without the dot.")
    var ext: String?

    @Flag(name: .customLong("exclude-same-document"),
          inversion: .prefixedNo,
          help: "Drop the neighbours that come from the same document.")
    var excludeSameDocument = true

    @Option(name: .customLong("min-cosine"),
            help: "Optional floor, 0 to 1. The cosine is not a relevance: 0 by default.")
    var minCosine: Double = 0

    @Option(name: .customLong("preview-chars"),
            help: "Characters of preview per neighbour.")
    var previewChars: Int = 200

    /// LA SEULE PORTE PAR LAQUELLE CETTE COMMANDE CHARGE LE MODÈLE (lot CL2,
    /// constat PM-07), et elle est fermée par défaut : « ne charge jamais le
    /// modèle » reste le contrat de l'appel ordinaire. Elle existe parce qu'une
    /// racine entière peut être à zéro vecteur — `M2SU`, mesuré le 13/09/2026 :
    /// 0 sur 139 638 pages — et que la commande y répondait « aucun voisin »,
    /// ce qui se lit comme « rien ne ressemble à cette page ».
    @Flag(name: .customLong("encode"),
          help: "When this page has no vector, encode it now instead of giving up. This LOADS the model (about 2 s and 570 MB), which this command otherwise never does.")
    var encode = false

    @Flag(name: .long, help: "JSON output.")
    var json = false

    static let maxLimit = 50
    /// Sur-demande quand un filtre s'applique : `neighbours` ne sait pas
    /// filtrer, on trie donc après coup (même arbitrage que l'outil MCP).
    static let filterOverFetch = 4
    static let overFetchCap = 200

    func validate() throws {
        guard docID >= 1 else { throw ValidationError("doc_id must be 1 or more.") }
        guard page >= 1, page <= Schema.maxPage else {
            throw ValidationError("page must be between 1 and \(Schema.maxPage).")
        }
        guard limit >= 1, limit <= Self.maxLimit else {
            throw ValidationError("--limit must be between 1 and \(Self.maxLimit).")
        }
        guard minCosine >= 0, minCosine <= 1 else {
            throw ValidationError("--min-cosine must be between 0 and 1.")
        }
        guard previewChars >= 80, previewChars <= 600 else {
            throw ValidationError("--preview-chars must be between 80 and 600.")
        }
    }

    func run() {
        CLI.guarded {
            let started = Date()
            let store = try CLI.openStoreReadOnly()
            guard let row = try store.docRow(id: docID) else {
                throw UsageRefusal(
                    message: PageReading.Failure.unknownDocument(docID).description
                    + " — `fouine list` shows what is indexed")
            }
            let pageCount = row.record.nPages
            guard page <= pageCount || pageCount == 0 else {
                throw UsageRefusal(message: PageReading.Failure.pageOutOfRange(
                    page: page, docID: docID, pageCount: pageCount).description)
            }
            // Étiquette de dossier inconnue : refus en 64 en nommant les
            // vraies (règle de `FolderCheck`).
            var wantedFolders: [String] = []
            if let folder, !folder.isEmpty {
                wantedFolders = try FolderCheck.resolve(
                    [folder], known: try store.roots().map(\.label))
            }
            let wantedExt = ext?.lowercased()
                .trimmingCharacters(in: CharacterSet(charactersIn: "."))

            let vectorisedPages = try store.vectorisedPageCount()
            let indexedPages = try store.indexedPageCount()
            let coverage = indexedPages > 0
                ? Double(vectorisedPages) * 100 / Double(indexedPages) : 0
            let meta = try store.vecMeta()

            // La dimension vient de `vec_meta`, jamais du modèle : payer
            // 571 Mo pour lire un entier serait absurde (même chemin que
            // `SemanticEngine.storedDimension`).
            let dim = try Int(meta["dim"] ?? "") ?? (store.vectorBlobDimension() ?? 0)
            let sourceRowid = Schema.ftsRowID(docID: docID, page: page)
            var index: VectorIndex?
            if dim > 0 { index = try VectorIndex(store: store, dim: dim) }
            // Schéma v5 : l'index est indexé par rowid de FENÊTRE ; la page a un
            // vecteur si sa fenêtre 0 est chargée.
            let stored = index.map {
                $0.count > 0 && $0.index(of: Schema.vecRowID(pageRowID: sourceRowid,
                                                             chunk: 0)) != nil
            } ?? false
            let filtered = !wantedFolders.isEmpty || wantedExt != nil
            let k = filtered ? min(Self.overFetchCap, limit * Self.filterOverFetch)
                             : limit

            var raw: [(rowid: Int64, cosine: Float)] = []
            var sourceVector: String?
            var notes: [String] = []
            var refusal: String?

            if index == nil || (index?.count ?? 0) == 0 {
                refusal = "no vector in this index yet — run `fouine embed`"
            } else if let index, stored {
                sourceVector = "stored"
                raw = index.neighbours(of: sourceRowid, k: k,
                                       excludingSameDoc: excludeSameDocument)
            } else if let index, encode {
                switch try Self.encodedNeighbours(
                    store: store, index: index, docID: docID, page: page,
                    rowid: sourceRowid, excludeSameDoc: excludeSameDocument, k: k) {
                case .success(let neighbours):
                    raw = neighbours
                    sourceVector = "computed"
                    notes.append("the model was loaded to encode this page "
                                 + "(~2 s the first time, ~0.3 s after)")
                case .refused(let why):
                    refusal = why
                }
            } else {
                refusal = "page \(page) of document \(docID) has no vector — it has "
                    + "not been embedded yet, or it is too short to carry one; "
                    + "pass --encode to encode it now (this loads the model), "
                    + "or run `fouine embed`"
            }

            if let refusal {
                if json {
                    try CLI.printJSON(Self.envelope(
                        neighbours: [], vectorCount: vectorisedPages,
                        coverage: coverage, meta: meta, sourceHasVector: false,
                        sourceVector: nil, note: refusal, started: started))
                } else {
                    CLI.fail("fouine: " + refusal)
                }
                // SORTIE 1, et non 0 : un script qui demande des voisins et
                // n'en reçoit aucun doit pouvoir distinguer « la page n'a rien
                // qui lui ressemble » de « le sens n'est pas préparé ».
                Foundation.exit(1)
            }

            let allowed = filtered
                ? try store.docIDsMatchingFilters(
                    folders: wantedFolders, exts: wantedExt.map { [$0] } ?? [],
                    inDocIDs: [], excludingDocsMatching: nil)
                : nil

            var seen = Set<Int64>()
            var kept: [(rowid: Int64, cosine: Float)] = []
            for candidate in raw {
                guard Double(candidate.cosine) >= minCosine else { continue }
                let target = candidate.rowid / Schema.pagesPerDocLimit
                if let allowed, !allowed.contains(target) { continue }
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

            if coverage < 50 {
                notes.append(String(format: "only %.1f %% of pages are vectorised",
                                    coverage)
                             + " — neighbours are drawn from that subset")
            }
            if filtered, kept.count < limit, raw.count >= k {
                notes.append("the folder/ext filter left fewer than \(limit) "
                             + "neighbours among the \(k) nearest pages")
            }

            let entries: [[String: Any]] = kept.map { candidate in
                Self.neighbourJSON(candidate, row: rows[
                    candidate.rowid / Schema.pagesPerDocLimit],
                    preview: previews[candidate.rowid]?.preview ?? "")
            }
            if json {
                // `source_has_vector` décrit LA BASE, pas l'appel : une page
                // encodée à la volée n'en a toujours pas, et le dire autrement
                // laisserait croire que la campagne y est passée.
                // `source_vector` dit d'où vient celui qui a servi.
                try CLI.printJSON(Self.envelope(
                    neighbours: entries, vectorCount: vectorisedPages,
                    coverage: coverage, meta: meta, sourceHasVector: stored,
                    sourceVector: sourceVector,
                    note: notes.isEmpty ? nil : notes.joined(separator: " ; "),
                    started: started))
                return
            }
            if kept.isEmpty {
                print("no neighbour for page \(page) of document \(docID)")
            }
            for entry in entries {
                let cosine = (entry["cosine"] as? NSNumber)?.doubleValue ?? 0
                print(String(format: "  %.3f  ", cosine)
                      + "[\(entry["doc_id"] as? Int64 ?? 0)] "
                      + "\(entry["path"] as? String ?? "") · "
                      + "page \(entry["page"] as? Int ?? 0)")
                let preview = (entry["preview"] as? String ?? "")
                    .replacingOccurrences(of: "\n", with: " ")
                if !preview.isEmpty { print("         \(preview)") }
            }
            for note in notes { CLI.warn(note) }
        }
    }

    static func neighbourJSON(_ candidate: (rowid: Int64, cosine: Float),
                              row: DocRow?, preview: String) -> [String: Any] {
        let docID = candidate.rowid / Schema.pagesPerDocLimit
        let page = Int(candidate.rowid % Schema.pagesPerDocLimit)
        let absPath = row.flatMap {
            (try? VolumeResolver.absolutePath(volUUID: $0.record.volUUID,
                                              relPath: $0.record.relPath))?.path
        }
        return [
            "doc_id": docID,
            "page": page,
            "path": row?.record.relPath ?? "",
            "abs_path": absPath.map { $0 as Any } ?? NSNull(),
            "folder": row?.record.topFolder ?? "",
            "ext": row?.record.ext ?? "",
            "link": DeepLink.link(absolutePath: absPath, docID: docID,
                                  page: page).absoluteString,
            "cosine": JSONNumber.rounded(Double(candidate.cosine), places: 3),
            "preview": preview,
        ]
    }

    static func envelope(neighbours: [[String: Any]], vectorCount: Int,
                         coverage: Double, meta: [String: String],
                         sourceHasVector: Bool, sourceVector: String?,
                         note: String?,
                         started: Date) -> [String: Any] {
        [
            "neighbours": neighbours,
            "vector_count": vectorCount,
            "coverage_pct": JSONNumber.rounded(coverage),
            "model_id": meta["model_id"].map { $0 as Any } ?? NSNull(),
            "revision": meta["revision"].flatMap(Int.init).map { $0 as Any }
                ?? NSNull(),
            "source_has_vector": sourceHasVector,
            // `stored` = lu dans l'index ; `computed` = encodé pour cet appel
            // (`--encode`) ; `null` = il n'y en a pas. Même clé, mêmes valeurs
            // que `fouine_similar_pages`.
            "source_vector": sourceVector.map { $0 as Any } ?? NSNull(),
            "note": note.map { $0 as Any } ?? NSNull(),
            "elapsed_ms": JSONNumber.rounded(
                Date().timeIntervalSince(started) * 1_000),
        ]
    }

    // MARK: - `--encode` : le vecteur que la campagne aurait produit

    enum EncodedSource {
        case success([(rowid: Int64, cosine: Float)])
        case refused(String)
    }

    /// Les voisins d'une page SANS vecteur, encodée à la volée.
    ///
    /// Le vecteur est celui de la campagne — même découpe, mêmes règles de
    /// vecteur nul, même quantification (`PageEmbedding`, lot MC4) —, sans quoi
    /// les cosinus rendus ne seraient comparables à rien et personne ne s'en
    /// apercevrait. C'est le même chemin que `fouine_similar_pages`
    /// (`encode_if_missing`), et il ne doit pas y en avoir deux.
    static func encodedNeighbours(store: GRDBStore, index: VectorIndex,
                                  docID: Int64, page: Int, rowid: Int64,
                                  excludeSameDoc: Bool, k: Int) throws
        -> EncodedSource {
        let directory = EmbedPaths.modelDirectory()
        guard EmbedPaths.modelAvailable(at: directory) else {
            return .refused("page \(page) of document \(docID) has no vector, and "
                            + "the meaning model is not installed — "
                            + "`fouine model download` installs it")
        }
        // 4 000 caractères : au-delà, la campagne ne produit plus de fenêtre.
        // Lire toute la page coûterait sans rien changer au vecteur.
        let span = Schema.vecWindowStride * (Schema.vecWindowMax - 1)
            + Schema.vecWindowChars
        let text = try store.pagePreviews(for: [rowid], maxChars: span)[rowid]?.preview
        guard let text, !text.isEmpty else {
            return .refused("page \(page) of document \(docID) carries no indexed "
                            + "text — it may be an image waiting for OCR "
                            + "(see `fouine status`)")
        }
        let vectors = try PageEmbedding.vectors(
            forPageText: text, engine: try E5Encoder(modelDir: directory))
        guard !vectors.isEmpty else {
            return .refused("page \(page) of document \(docID) is too short to carry "
                            + "a direction — the campaign would give it a null "
                            + "vector too")
        }
        return .success(index.neighbours(ofVectors: vectors, k: k,
                                         excludingDoc: excludeSameDoc ? docID : nil))
    }
}
