// GRDBStore+Pages.swift — ce qu'on lit d'une PAGE en dehors d'une recherche :
// une tranche de son texte, et l'ensemble des documents qu'un filtre laisse
// passer. Propriété : A-Core.
//
// Ce sont les trois lectures dont vivent `fouine read`, `fouine_read_page` et
// le repérage du moment d'une page transcrite : une page entière se lit par
// tranches, et un filtre de dossier ou d'extension doit pouvoir se traduire en
// ensemble de `doc_id` sans passer par un `page_fts MATCH`.
//
// Les lectures ne prennent jamais le verrou (§5.1).

import Foundation
import GRDB

extension GRDBStore {

    /// Pages indexées, c'est-à-dire le nombre de pages que `page_fts` porte.
    ///
    /// Compté sur la table d'ombre `page_fts_docsize`, comme `stats()` et pour
    /// la même raison mesurée : un `count(*)` sur `page_fts` est un balayage
    /// complet du contenu FTS5 (16-45 s sur 390 114 pages, audit C2-03),
    /// inacceptable sur le chemin d'une recherche. `stats()` conviendrait mais
    /// calcule huit comptes de plus, dont aucun ne sert ici.
    public func indexedPageCount() throws -> Int {
        try read { db in
            try Int.fetchOne(db, sql: "SELECT count(*) FROM page_fts_docsize") ?? 0
        }
    }

    /// Documents autorisés par les filtres d'une requête, pour appliquer les
    /// mêmes restrictions à un chemin qui ne passe pas par `page_fts MATCH`
    /// (les voisins de page, les filtres de `fouine read`).
    /// nil = aucun filtre (tous les documents). `negative` suit l'arbitrage T5 :
    /// tout document dont UNE page répond à l'expression est exclu.
    ///
    /// Les cinq derniers paramètres sont ceux du lot MC1 — `chemin:` et les
    /// quatre exclusions de filtres. VIDES PAR DÉFAUT : aucun appelant existant
    /// ne change, et la même SQL que le canal lexical est écrite une seule fois
    /// (`GRDBStore.pathAndExcludeClauses`).
    public func docIDsMatchingFilters(folders: [String], exts: [String],
                                      inDocIDs: [Int64],
                                      excludingDocsMatching negative: String?,
                                      pathContains: [String] = [],
                                      folderExcludes: [String] = [],
                                      extExcludes: [String] = [],
                                      nameExcludes: [String] = [],
                                      pathExcludes: [String] = [])
        throws -> Set<Int64>? {
        let negative = negative?.trimmingCharacters(in: .whitespaces)
        let hasNegative = !(negative?.isEmpty ?? true)
        // La requête sonde : elle ne sert qu'à composer les clauses du lot MC1
        // avec le MÊME code que la recherche lexicale.
        var probe = SearchQuery(fts: "")
        probe.pathContains = pathContains
        probe.folderExcludes = folderExcludes
        probe.extExcludes = extExcludes
        probe.pathExcludes = pathExcludes
        probe.nameExcludes = nameExcludes
        let added = Self.pathAndExcludeClauses(probe, alias: "")
        let excludedNames = Self.nameExcludeExpression(probe)
        guard !folders.isEmpty || !exts.isEmpty || !inDocIDs.isEmpty
              || hasNegative || !added.clauses.isEmpty
              || excludedNames != nil else { return nil }
        return try read { db in
            var clauses: [String] = []
            var args: [(any DatabaseValueConvertible)?] = []
            if !folders.isEmpty {
                let marks = Array(repeating: "?", count: folders.count)
                    .joined(separator: ",")
                clauses.append("top_folder IN (\(marks))")
                args.append(contentsOf: folders.map {
                    $0 as (any DatabaseValueConvertible)? })
            }
            if !exts.isEmpty {
                let marks = Array(repeating: "?", count: exts.count)
                    .joined(separator: ",")
                clauses.append("ext IN (\(marks))")
                args.append(contentsOf: exts.map {
                    $0.lowercased() as (any DatabaseValueConvertible)? })
            }
            clauses += added.clauses
            args += added.args
            let whereSQL = clauses.isEmpty ? "" : " WHERE "
                + clauses.joined(separator: " AND ")
            var out = Set(try Int64.fetchAll(
                db, sql: "SELECT id FROM docs" + whereSQL,
                arguments: StatementArguments(args)))
            if !inDocIDs.isEmpty { out.formIntersection(inDocIDs) }
            if let excludedNames {
                out.subtract(try Int64.fetchAll(
                    db, sql: "SELECT rowid FROM docs_fts WHERE docs_fts MATCH ?",
                    arguments: [excludedNames]))
            }
            if hasNegative, let negative {
                // doc_id dérivé du rowid, comme partout (§4.1).
                let excluded = try Int64.fetchAll(db, sql: """
                    SELECT DISTINCT rowid / \(Schema.pagesPerDocLimit)
                    FROM page_fts WHERE page_fts MATCH ?
                    """, arguments: [negative])
                out.subtract(excluded)
            }
            return out
        }
    }

    /// Chemin, tranche de texte et LONGUEUR TOTALE des pages désignées, pour
    /// lire une page entière (`fouine read`, `fouine_read_page`) et pour
    /// retrouver le moment d'une page transcrite quand l'extrait ne le porte
    /// pas.
    ///
    /// `offset` est un décalage en CARACTÈRES dans le texte de la page.
    /// `substr(body, 1 + offset, maxChars)` : SQLite indexe à partir de 1 et
    /// compte des points de code, pas des octets — la même convention que
    /// `underRootClause`. Au-delà de la fin du texte, `substr` rend une chaîne
    /// vide plutôt qu'une erreur.
    ///
    /// `totalChars` est la longueur ENTIÈRE de la page, indépendante de la
    /// tranche demandée : c'est ce qui permet à un appelant de savoir qu'il
    /// reste à lire, et donc de ne pas conclure à tort d'une page tronquée
    /// qu'il l'a lue en entier.
    ///
    public func pagePreviews(for rowids: [Int64], maxChars: Int,
                             offset: Int = 0) throws
        -> [Int64: (relPath: String, preview: String, totalChars: Int)] {
        guard !rowids.isEmpty else { return [:] }
        let skip = max(0, offset)
        let take = max(1, maxChars)
        // Rowids interpolés en littéraux entiers (aucune injection possible),
        // même convention que `snippetsFor` (§4.1).
        let list = rowids.map(String.init).joined(separator: ",")
        return try read { db in
            var out: [Int64: (String, String, Int)] = [:]
            let rows = try Row.fetchAll(db, sql: """
                SELECT f.rowid AS rid, substr(f.body, ?, ?) AS preview,
                       length(f.body) AS total_chars,
                       d.rel_path AS rel_path
                FROM page_fts f
                JOIN docs d ON d.id = f.rowid / \(Schema.pagesPerDocLimit)
                WHERE f.rowid IN (\(list))
                """, arguments: [skip + 1, take])
            for r in rows {
                out[r["rid"] as Int64] = (r["rel_path"] as String,
                                          r["preview"] as String,
                                          r["total_chars"] as Int)
            }
            return out
        }
    }

}
