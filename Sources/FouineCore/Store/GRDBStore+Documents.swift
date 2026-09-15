// GRDBStore+Documents.swift — listage filtré des documents (palier 4, D2 § 5.5
// n° 4). Propriété : A-Core.
//
// POURQUOI UNE REQUÊTE, ET PAS `docs(underRoot:)` FILTRÉ EN MÉMOIRE.
// `docs(underRoot:)` rend TOUS les documents d'une racine — 1 329 aujourd'hui,
// et rien ne borne ce nombre. Un outil MCP qui rend cinquante lignes n'a aucune
// raison d'en matérialiser mille trois cents, et surtout : la PAGINATION doit
// être faite par SQLite (`LIMIT`/`OFFSET` sur un ordre total déterministe),
// sans quoi deux pages consécutives peuvent se recouvrir ou sauter des lignes
// dès qu'une passe d'indexation écrit entre les deux appels.
//
// LECTURE SEULE : tout ce fichier passe par `read`, jamais par `writeLocked`.
// C'est ce qui lui permet d'être atteint depuis une base ouverte en
// `SQLITE_OPEN_READONLY` (`openReadOnly`).

import Foundation
import GRDB

/// Ce que `fouine_list_documents` sait filtrer. Un champ nul = pas de filtre.
public struct DocumentFilter: Sendable {
    /// Étiquette de racine (`docs.top_folder`), telle que la facette l'expose.
    public var folder: String?
    /// Extension en minuscules, sans point.
    public var ext: String?
    /// Fragment cherché dans `rel_path`, insensible à la casse.
    ///
    /// NORMALISÉ EN NFC par `documentClause` (lot MC1) : macOS rend les noms
    /// de fichiers en forme DÉCOMPOSÉE, la base les écrit recomposés
    /// (`migration_v7_nfc`), et `fouine list --path-contains "Polymères"`
    /// rendait 9 documents quand l'accent était tapé et 0 quand il était collé
    /// depuis `ls` (mesuré le 13/09/2026).
    public var pathContains: String?
    /// États retenus ; `nil` = tous.
    public var states: [DocState]?

    public init(folder: String? = nil, ext: String? = nil,
                pathContains: String? = nil, states: [DocState]? = nil) {
        self.folder = folder
        self.ext = ext
        self.pathContains = pathContains
        self.states = states
    }
}

/// L'ordre du listage. Chacun est complété par `id` pour former un ordre TOTAL :
/// sans cela, deux documents de même chemin (impossible) ou de même nombre de
/// pages (courant) peuvent permuter d'une page de résultats à l'autre, et la
/// pagination perd ou double des lignes.
public enum DocumentOrder: String, Sendable {
    case path, pages, recent

    var sql: String {
        switch self {
        case .path:   return "ORDER BY rel_path ASC, id ASC"
        case .pages:  return "ORDER BY n_pages DESC, id ASC"
        case .recent: return "ORDER BY mtime DESC, id ASC"
        }
    }
}

/// Une ligne de listage : la ligne `docs` plus le compte de pages OCRisées.
/// Le nombre de pages VECTORISÉES n'y est pas — il se lit par
/// `vectorisedPageCounts(forDocIDs:)`, point unique du dépôt (voir son
/// commentaire : c'est là que le fenêtrage v5 interviendra).
public struct DocumentListing: Sendable {
    public let id: Int64
    public let volUUID: String
    public let relPath: String
    public let ext: String
    public let topFolder: String
    public let nPages: Int
    public let mtime: Double
    public let state: DocState
    public let err: String?
    /// Date INSCRITE DANS LE DOCUMENT (schéma v9, constat PR-07) ; `nil` quand
    /// le document n'en porte pas. Champ ADDITIF : `mtime` reste à sa place,
    /// les deux répondent à deux questions différentes.
    public let docDate: Double?

    public init(id: Int64, volUUID: String, relPath: String, ext: String,
                topFolder: String, nPages: Int, mtime: Double,
                state: DocState, err: String?, docDate: Double? = nil) {
        self.id = id
        self.volUUID = volUUID
        self.relPath = relPath
        self.ext = ext
        self.topFolder = topFolder
        self.nPages = nPages
        self.mtime = mtime
        self.state = state
        self.err = err
        self.docDate = docDate
    }
}

/// Un document tel que la remise à Spotlight a besoin de le voir.
///
/// Ni `DocumentListing` ni `DocRow` ne conviennent : le premier ne porte
/// pas `indexed_at`, aucun des deux ne dit si le document a des pages
/// SCANNÉES — et c'est précisément ce qui décide s'il faut le donner
/// (`SpotlightPolicy`). Le type vit ici, dans le cœur, plutôt que dans
/// `FouineIndex` : c'est la forme d'une ligne lue, pas une décision.
public struct DocumentChange: Sendable, Equatable {
    public let id: Int64
    public let volUUID: String
    public let relPath: String
    public let ext: String
    public let topFolder: String
    public let state: DocState
    public let ocrState: OCRState
    /// Secondes epoch de la dernière indexation ; 0 pour une ligne écrite
    /// avant que la colonne existe.
    public let indexedAt: Double
    /// Pages dont le texte vient d'une reconnaissance de caractères
    /// (`PageSource.scanned`).
    public let scannedPages: Int
    /// Pages mises par écrit depuis un son (`PageSource.transcript`). Un
    /// compte À PART depuis IX2 : `scannedPages` comptait `src != 0` et
    /// rangeait donc les transcriptions parmi les scans.
    public let transcribedPages: Int

    public init(id: Int64, volUUID: String, relPath: String, ext: String,
                topFolder: String, state: DocState, ocrState: OCRState,
                indexedAt: Double, scannedPages: Int, transcribedPages: Int = 0) {
        self.id = id
        self.volUUID = volUUID
        self.relPath = relPath
        self.ext = ext
        self.topFolder = topFolder
        self.state = state
        self.ocrState = ocrState
        self.indexedAt = indexedAt
        self.scannedPages = scannedPages
        self.transcribedPages = transcribedPages
    }
}

/// Une page de texte indexé, telle qu'elle est en base.
public struct IndexedPage: Sendable, Equatable {
    public let page: Int
    public let text: String
    public init(page: Int, text: String) {
        self.page = page
        self.text = text
    }
}

extension GRDBStore {

    /// Documents répondant au filtre, ordonnés, paginés PAR SQLITE.
    public func listDocuments(_ filter: DocumentFilter,
                              order: DocumentOrder = .path,
                              limit: Int, offset: Int = 0) throws -> [DocumentListing] {
        let (clause, args) = Self.documentClause(filter)
        return try read { db in
            try Row.fetchAll(db, sql: """
                SELECT id, vol_uuid, rel_path, ext, top_folder, n_pages, mtime,
                       state, err, doc_date
                FROM docs\(clause)
                \(order.sql)
                LIMIT ? OFFSET ?
                """,
                arguments: StatementArguments(
                    args + [max(0, limit), max(0, offset)]))
                .map { row in
                    DocumentListing(
                        id: row["id"], volUUID: row["vol_uuid"],
                        relPath: row["rel_path"], ext: row["ext"],
                        topFolder: row["top_folder"], nPages: row["n_pages"],
                        mtime: row["mtime"],
                        state: DocState(rawValue: row["state"]) ?? .discovered,
                        err: row["err"], docDate: row["doc_date"])
                }
        }
    }

    /// Combien de documents répondent au filtre — le `total` que l'outil MCP
    /// rend à côté de sa page de résultats. Un `count(*)` sur `docs` (1 329
    /// lignes en production, index `idx_docs_state` et `idx_docs_folder`) : pas
    /// de seuil d'approximation à prévoir, contrairement aux pages.
    public func countDocuments(_ filter: DocumentFilter) throws -> Int {
        let (clause, args) = Self.documentClause(filter)
        return try read { db in
            try Int.fetchOne(db, sql: "SELECT count(*) FROM docs\(clause)",
                             arguments: StatementArguments(args)) ?? 0
        }
    }

    /// Les extensions PRÉSENTES dans l'index, la plus fréquente d'abord.
    ///
    /// POURQUOI ICI, ET PAS UNE FACETTE. `facets(_:by:.ext)` exige une requête :
    /// elle répond « les extensions des pages TROUVÉES ». La fenêtre « Tous vos
    /// documents » (lot BR1, constat PR-06) ne cherche rien — son menu « Type »
    /// doit proposer ce que l'index CONTIENT, requête ou pas.
    ///
    /// PAR FRÉQUENCE ET NON PAR ORDRE ALPHABÉTIQUE : un fonds réel porte une
    /// trentaine d'extensions dont trois pèsent 95 % des documents (`pdf`,
    /// `txt`, `epub` sur le corpus de production). Alphabétiquement, `pdf`
    /// arrive après une douzaine de formats que personne ne cherche.
    /// `LIMIT` borne le menu : au-delà, on ne choisit plus, on fouille.
    ///
    /// LECTURE SEULE, comme tout ce fichier.
    public func documentExtensions(limit: Int = 40) throws -> [String] {
        try read { db in
            try String.fetchAll(db, sql: """
                SELECT ext FROM docs WHERE ext <> ''
                GROUP BY ext ORDER BY count(*) DESC, ext ASC LIMIT ?
                """, arguments: [max(0, limit)])
        }
    }

    /// Les documents que Fouine N'A PAS PU LIRE : `state` vaut `failed`
    /// (accident propre à ce document) ou `skipped` (refus normal — format non
    /// pris en charge, fichier trop gros, outil absent). C'est la lecture qui
    /// alimente la fenêtre « Documents Fouine could not read » (UX-16).
    ///
    /// POURQUOI PAS `listDocuments(_:order:limit:)` AVEC UN FILTRE D'ÉTATS.
    /// Il faudrait deux appels — un par état — puis une fusion en mémoire dont
    /// l'ordre ne serait plus celui de SQLite, ou un seul appel dont l'ordre
    /// (`rel_path`) mélangerait les dossiers. La fenêtre, elle, se lit par
    /// DOSSIER : c'est le premier repère de quelqu'un qui cherche pourquoi ses
    /// documents manquent. D'où `ORDER BY top_folder, rel_path`, complété par
    /// `id` pour rester un ordre TOTAL (même raison que `DocumentOrder`).
    ///
    /// `state` est indexé (`idx_docs_state`) : le filtre ne balaie pas `docs`.
    /// La limite est un garde-fou d'affichage, pas une pagination — une liste
    /// de plusieurs milliers de lignes ne se parcourt pas à l'œil, et
    /// l'appelant annonce le total à part (`stats()`).
    public func unreadableDocuments(limit: Int) throws -> [DocumentListing] {
        try read { db in
            try Row.fetchAll(db, sql: """
                SELECT id, vol_uuid, rel_path, ext, top_folder, n_pages, mtime,
                       state, err, doc_date
                FROM docs WHERE state IN (?, ?)
                ORDER BY top_folder ASC, rel_path ASC, id ASC
                LIMIT ?
                """,
                arguments: [DocState.failed.rawValue, DocState.skipped.rawValue,
                            max(0, limit)])
                .map { row in
                    DocumentListing(
                        id: row["id"], volUUID: row["vol_uuid"],
                        relPath: row["rel_path"], ext: row["ext"],
                        topFolder: row["top_folder"], nPages: row["n_pages"],
                        mtime: row["mtime"],
                        state: DocState(rawValue: row["state"]) ?? .discovered,
                        err: row["err"], docDate: row["doc_date"])
                }
        }
    }

    /// Le document qui vit à ce chemin ABSOLU, ou `nil` s'il n'y en a pas
    /// (lien profond `fouine://open?path=…`, lot INT-L1).
    ///
    /// POURQUOI ON NE COMPARE PAS DEUX CHAÎNES. `docs` ne stocke aucun chemin
    /// absolu : il porte un volume et un chemin RELATIF à ce volume, et c'est
    /// ce qui permet à un disque externe de changer de point de montage sans
    /// invalider l'index. Un lien cité l'an dernier porte, lui, le chemin
    /// absolu d'alors. On refait donc exactement le trajet de l'indexation —
    /// `VolumeResolver.resolve` retrouve le volume par le plus long préfixe de
    /// point de montage et normalise le relatif en NFC — avant d'interroger la
    /// clé `(vol_uuid, rel_path)`. Comparer les chaînes brutes échouerait sur
    /// un `é` décomposé, sur un lien symbolique, et sur tout volume remonté
    /// ailleurs.
    ///
    /// `nil` — et non une erreur — quand aucun volume monté ne porte ce
    /// chemin : c'est l'état normal d'un disque débranché, et l'appelant en
    /// fait un « Fouine ne connaît pas ce document », pas une panne.
    ///
    /// LECTURE SEULE, comme tout ce fichier.
    public func docID(forAbsolutePath path: String) throws -> Int64? {
        guard let resolved = try? VolumeResolver.resolve(path: URL(fileURLWithPath: path))
        else { return nil }
        return try read { db in
            try Int64.fetchOne(db, sql: """
                SELECT id FROM docs WHERE vol_uuid = ? AND rel_path = ?
                """, arguments: [resolved.volUUID, resolved.relPath])
        }
    }

    /// Pages OCRisées par document (`PageSource.scanned`), pour les documents
    /// désignés. Sondes sur la clé primaire `(doc_id, page)`, une par document.
    /// Une transcription n'y compte pas (IX2) : `ocr_pages` de
    /// `fouine_list_documents` promet des pages « venues de l'OCR ».
    public func ocrPageCounts(forDocIDs ids: [Int64]) throws -> [Int64: Int] {
        guard !ids.isEmpty else { return [:] }
        let list = ids.map(String.init).joined(separator: ",")
        return try read { db in
            var out: [Int64: Int] = [:]
            let rows = try Row.fetchAll(db, sql: """
                SELECT doc_id, count(*) AS n FROM page_src
                WHERE doc_id IN (\(list)) AND src IN (\(Self.scannedSourceList))
                GROUP BY doc_id
                """)
            for r in rows { out[r["doc_id"] as Int64] = r["n"] as Int }
            return out
        }
    }

    /// Nombre de pages de TEXTE par document — `max(page)` des lignes de
    /// `page_src` marquées natives (lot MC2, constat PM-19).
    ///
    /// À QUOI CELA SERT. `OOXMLExtractor` numérote les diapositives (ou les
    /// feuilles, ou le flux) d'abord, puis ajoute UNE PAGE PAR IMAGE
    /// incorporée : sur un cours mesuré, 53 diapositives et 202 pages. Ce
    /// maximum est la frontière entre les deux, et il est déjà en base — pas de
    /// colonne à ajouter, pas de migration, pas de réindexation
    /// (`PageLayout.page(_:ext:textPages:)` en tire la citation juste).
    ///
    /// `max` ET NON `count` : une diapositive vide n'a pas de page (le texte
    /// blanc n'est pas inséré), et compter les lignes décalerait la frontière
    /// d'autant. Le seul cas qui reste faux est un conteneur dont les
    /// DERNIÈRES diapositives sont vides ; il déclare alors une image
    /// incorporée de trop, jamais une diapositive inventée.
    ///
    /// Une requête pour tous les documents demandés, groupée sur la clé
    /// primaire `(doc_id, page)`.
    public func textPageCounts(forDocIDs ids: [Int64]) throws -> [Int64: Int] {
        guard !ids.isEmpty else { return [:] }
        let list = Set(ids).map(String.init).joined(separator: ",")
        return try read { db in
            var out: [Int64: Int] = [:]
            let rows = try Row.fetchAll(db, sql: """
                SELECT doc_id, max(page) AS last FROM page_src
                WHERE doc_id IN (\(list)) AND src = \(PageSource.native.rawValue)
                GROUP BY doc_id
                """)
            for r in rows { out[r["doc_id"] as Int64] = r["last"] as Int }
            return out
        }
    }

    /// Nombre de pages INDEXÉES par document, comptées sur la table d'ombre
    /// `page_fts_docsize` (lot MC2, constat PM-06).
    ///
    /// C'est le dénominateur de la couverture sémantique d'un PÉRIMÈTRE
    /// FILTRÉ : `vectorisedPageCounts(forDocIDs:)` en donne le numérateur, et
    /// annoncer 67,85 % pour un dossier qui n'a pas un seul vecteur était le
    /// constat. Même dénombrement que `indexedPageCount()` — donc le même
    /// chiffre sans filtre —, et une sonde de PLAGE par document, comme
    /// `vectorisedPageCounts` : une expression sur la clé primaire interdirait
    /// l'index et balaierait la table entière.
    public func indexedPageCounts(forDocIDs ids: [Int64]) throws -> [Int64: Int] {
        guard !ids.isEmpty else { return [:] }
        return try read { db in
            var out: [Int64: Int] = [:]
            for id in Set(ids) {
                let range = Schema.ftsRowIDRange(docID: id)
                let n = try Int.fetchOne(db, sql: """
                    SELECT count(*) FROM page_fts_docsize WHERE rowid BETWEEN ? AND ?
                    """, arguments: [range.lowerBound, range.upperBound]) ?? 0
                if n > 0 { out[id] = n }
            }
            return out
        }
    }

    // MARK: - Ce qui a bougé depuis (lot INT-S1)

    /// Les documents (ré)indexés DEPUIS un instant, du plus ancien au plus
    /// récent.
    ///
    /// `>=` et non `>` : le marqueur de la remise est en secondes entières
    /// quand `indexed_at` est un flottant, et un `>` strict laisserait tomber
    /// tout ce qui a été écrit dans la seconde du marqueur. Redonner un
    /// document déjà donné ne coûte qu'une écriture idempotente ; l'oublier le
    /// rendrait introuvable jusqu'à la remise complète suivante.
    ///
    /// L'ordre est celui de `indexed_at`, complété par `id` : c'est un ordre
    /// TOTAL, seul moyen de reprendre une remise interrompue sans recouvrement
    /// (même raison que `DocumentOrder`).
    ///
    /// LECTURE SEULE.
    public func documentsChanged(since: Double, limit: Int) throws -> [DocumentChange] {
        try read { db in
            try Row.fetchAll(db, sql: """
                SELECT d.id AS id, d.vol_uuid AS vol_uuid, d.rel_path AS rel_path,
                       d.ext AS ext, d.top_folder AS top_folder, d.state AS state,
                       d.ocr_state AS ocr_state,
                       COALESCE(d.indexed_at, 0) AS indexed_at,
                       (SELECT count(*) FROM page_src s
                         WHERE s.doc_id = d.id
                           AND s.src IN (\(Self.scannedSourceList))) AS scanned,
                       (SELECT count(*) FROM page_src s
                         WHERE s.doc_id = d.id
                           AND s.src = \(PageSource.transcript.rawValue)) AS transcribed
                FROM docs d
                WHERE COALESCE(d.indexed_at, 0) >= ?
                ORDER BY indexed_at ASC, d.id ASC
                LIMIT ?
                """, arguments: [since, max(0, limit)])
                .map { row in
                    DocumentChange(
                        id: row["id"], volUUID: row["vol_uuid"],
                        relPath: row["rel_path"], ext: row["ext"],
                        topFolder: row["top_folder"],
                        state: DocState(rawValue: row["state"]) ?? .discovered,
                        ocrState: OCRState(rawValue: row["ocr_state"]) ?? .notNeeded,
                        indexedAt: row["indexed_at"], scannedPages: row["scanned"],
                        transcribedPages: row["transcribed"])
                }
        }
    }

    /// Le texte des pages d'un document, dans l'ordre, PAR TRANCHES.
    ///
    /// `pageText(docID:page:)` lit une page ; celle-ci en lit un paquet, et
    /// c'est ce qu'il faut à la remise Spotlight — qui empile des pages
    /// entières jusqu'à son plafond puis s'arrête. Sans découpage, un livre de
    /// trois mille pages serait chargé en entier pour n'en donner qu'un
    /// mégaoctet.
    ///
    /// PAR CURSEUR DE PAGE, ET SURTOUT PAS PAR `OFFSET`. Mesuré le 08/09/2026
    /// sur une copie de la base de production : avec `LIMIT 32 OFFSET n`,
    /// SQLite doit LIRE — donc décompresser — les n lignes sautées, dont le
    /// corps fait un à trois kilo-octets. Le coût d'un document devient
    /// quadratique en son nombre de pages, et une remise complète du corpus
    /// tournait encore après quatorze minutes. Le rowid étant STRUCTURÉ
    /// (§4.1 : `docID × pagesPerDocLimit + page`), reprendre à une page se dit
    /// en déplaçant la borne basse de la plage : chaque tranche coûte alors sa
    /// propre taille, et rien d'autre.
    ///
    /// La page se relit du rowid par le même reste que la recherche
    /// (`ftsPageExpr`, privée à son fichier).
    /// LECTURE SEULE.
    public func pageTexts(docID: Int64, limit: Int, fromPage: Int = 0) throws
        -> [IndexedPage] {
        let range = Schema.ftsRowIDRange(docID: docID)
        let start = max(range.lowerBound,
                        Schema.ftsRowID(docID: docID, page: max(0, fromPage)))
        guard start <= range.upperBound else { return [] }
        return try read { db in
            try Row.fetchAll(db, sql: """
                SELECT (page_fts.rowid % \(Schema.pagesPerDocLimit)) AS page,
                       body AS body
                FROM page_fts WHERE page_fts.rowid BETWEEN ? AND ?
                ORDER BY page_fts.rowid
                LIMIT ?
                """, arguments: [start, range.upperBound, max(0, limit)])
                .map { IndexedPage(page: $0["page"], text: $0["body"] ?? "") }
        }
    }

    // MARK: - Clause commune

    /// La MÊME clause pour le listage et pour le total : les deux doivent
    /// compter la même population, sans quoi `has_more` ment.
    static func documentClause(_ filter: DocumentFilter)
        -> (String, [(any DatabaseValueConvertible)?]) {
        var clauses: [String] = []
        var args: [(any DatabaseValueConvertible)?] = []

        if let folder = filter.folder, !folder.isEmpty {
            clauses.append("top_folder = ?")
            args.append(folder)
        }
        if let ext = filter.ext, !ext.isEmpty {
            clauses.append("ext = ?")
            args.append(ext.lowercased()
                .trimmingCharacters(in: CharacterSet(charactersIn: ".")))
        }
        if let needle = filter.pathContains, !needle.isEmpty {
            // `%` et `_` d'une saisie utilisateur sont des JOKERS pour LIKE :
            // sans échappement, `path_contains: "%"` rend tout l'index et
            // `"a_b"` trouve « axb ». `ESCAPE '\'` les neutralise.
            clauses.append("rel_path LIKE ? ESCAPE '\\'")
            // NFC (lot MC1) : ICI, dans le store, et non chez l'appelant — la
            // ligne de commande et le serveur MCP en profitent tous les deux
            // sans y toucher. La base est en NFC, le Finder rend du NFD.
            args.append("%" + Self.escapeLike(
                needle.precomposedStringWithCanonicalMapping) + "%")
        }
        if let states = filter.states {
            guard !states.isEmpty else { return (" WHERE 0", []) }
            let marks = Array(repeating: "?", count: states.count)
                .joined(separator: ",")
            clauses.append("state IN (\(marks))")
            args.append(contentsOf: states.map {
                $0.rawValue as (any DatabaseValueConvertible)? })
        }
        return (clauses.isEmpty ? "" : " WHERE " + clauses.joined(separator: " AND "),
                args)
    }

    /// Neutralise les jokers de LIKE. L'antislash d'abord : le faire ensuite
    /// doublerait ceux qu'on vient d'introduire.
    static func escapeLike(_ text: String) -> String {
        text.replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "%", with: "\\%")
            .replacingOccurrences(of: "_", with: "\\_")
    }
}
