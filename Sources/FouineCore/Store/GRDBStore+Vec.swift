// GRDBStore+Vec.swift — vecteurs sémantiques par FENÊTRE de page (recherche
// hybride, §12, schéma v5). Propriété : A-Core.
//
// `page_vec.rowid` est le rowid structuré de page_fts (§4.1) prolongé d'un
// chiffre de fenêtre (`Schema.vecRowID`) ; `vec` est le vecteur unitaire
// quantifié int8 (round(v·127)), ou un blob VIDE quand la ligne est la
// sentinelle de complétude d'une page qui n'a pas autant de fenêtres.
// Production : `fouine embed` (FouineEmbed.EmbedRun). Lecture : l'index en
// mémoire (VectorIndex) charge tout le tampon en une passe.
//
// Les écritures passent par `writeLocked` comme toutes les écritures
// d'indexation ; les lectures ne prennent jamais le verrou (§5.1).

import Foundation
import GRDB

extension GRDBStore {

    // MARK: - Identité du modèle

    /// Contenu de `vec_meta` (model_id, dim, revision…).
    public func vecMeta() throws -> [String: String] {
        try read { db in
            var out: [String: String] = [:]
            for row in try Row.fetchAll(db, sql: "SELECT k, v FROM vec_meta") {
                out[row["k"] as String] = row["v"] as String
            }
            return out
        }
    }

    /// Pose l'identité du modèle. Si elle CHANGE (modèle ou révision différents),
    /// tous les vecteurs existants sont purgés : deux espaces d'embedding ne se
    /// comparent pas. Si elle est DÉJÀ posée à l'identique, aucune écriture —
    /// donc aucun verrou à prendre (l'agent peut le tenir pendant 10 min).
    public func setVecMeta(modelID: String, dim: Int, revision: Int) throws {
        let previous = try vecMeta()
        if previous["model_id"] == modelID, previous["dim"] == String(dim),
           previous["revision"] == String(revision) {
            return
        }
        // « Changé » = une IDENTITÉ DE MODÈLE était posée et diffère.
        // `vec_meta` n'est JAMAIS vide — la création y pose la géométrie des
        // fenêtres —, donc tester `previous.isEmpty` ferait passer la première
        // pose d'identité pour un changement de modèle.
        let changed = previous["model_id"] != nil
        try writeLocked { db in
            if changed {
                try db.execute(sql: "DELETE FROM page_vec")
            }
            try db.execute(sql: """
                INSERT OR REPLACE INTO vec_meta(k, v) VALUES
                  ('model_id', ?), ('dim', ?), ('revision', ?)
                """, arguments: [modelID, String(dim), String(revision)])
        }
    }

    // MARK: - Production (fouine embed)

    /// Pages indexées INCOMPLÈTES, avec leur texte, par rowid CROISSANT et
    /// STRICTEMENT au-delà de `after` — le curseur de reprise de la pompe.
    ///
    /// FENÊTRAGE (schéma v5, constat C2-05) — le point de conception qui décide
    /// de tout. Une page porte jusqu'à `Schema.vecWindowMax` vecteurs ; « cette
    /// page est-elle faite ? » ne peut donc plus se lire sur la présence d'UN
    /// rowid… sauf si l'on s'arrange pour qu'un créneau convenu existe toujours.
    /// C'est le rôle de la SENTINELLE DE COMPLÉTUDE : la pompe écrit toujours
    /// le créneau `vecWindowMax - 1`, avec le vrai vecteur quand la fenêtre
    /// existe et un blob VIDE sinon. L'anti-jointure retrouve alors la forme
    /// qu'elle avait au schéma v3 — une sonde de clé primaire par page — et le
    /// plan d'exécution est INCHANGÉ, vérifié sur une copie de la base de
    /// production (390 114 pages, 64 872 vecteurs, sqlite3 du système) :
    ///
    ///   v3   SCAN f VIRTUAL TABLE INDEX 64:>
    ///        SEARCH v USING INTEGER PRIMARY KEY (rowid=?) LEFT-JOIN
    ///   v5   SCAN f VIRTUAL TABLE INDEX 64:>            <- identique
    ///        SEARCH v USING INTEGER PRIMARY KEY (rowid=?) LEFT-JOIN
    ///
    /// Aucun `body` n'est lu pour une page non retenue : fts5 ne matérialise la
    /// colonne qu'après la jointure. La conception « telle qu'écrite » par C2
    /// joignait sur la fenêtre 0 (`v.rowid = f.rowid * 8`) : une page ayant
    /// déjà son vecteur v3 n'aurait plus JAMAIS été sélectionnée, et les
    /// fenêtres 1-2 n'auraient jamais été produites (contre-expertise D2).
    ///
    /// AUDIT V2 (01/09/2026) : sans le curseur, l'anti-jointure repartait de
    /// zéro à chaque lot et rebalayait toutes les pages DÉJÀ vectorisées avant
    /// d'en trouver 24 sans vecteur. Coût par lot ~0,05 s à 3 % de couverture,
    /// ~8 s en fin de campagne (≈ 2× l'inférence d'un lot) : la sélection
    /// coûtait à peu près autant que le modèle, et 10× plus à corpus 10×.
    /// Avec le curseur, la campagne entière ne balaie `page_fts` qu'une fois.
    ///
    /// `EXPLAIN QUERY PLAN` mesuré (base synthétique 200 000 pages, 93 % de
    /// couverture, sqlite3 système) :
    ///
    ///   AVANT  SCAN f VIRTUAL TABLE INDEX 0:            -> 0,144 s le lot
    ///          SEARCH v USING INTEGER PRIMARY KEY (rowid=?) LEFT-JOIN
    ///   APRÈS  SCAN f VIRTUAL TABLE INDEX 64:>          -> 0,000 s le lot
    ///          SEARCH v USING INTEGER PRIMARY KEY (rowid=?) LEFT-JOIN
    ///
    /// Le `>` du plan est la contrainte `rowid >` poussée dans fts5 (`xBestIndex`
    /// la prend en charge), `64` le drapeau d'ordre croissant : l'`ORDER BY`
    /// n'ajoute AUCUN tri temporaire (pas de « USE TEMP B-TREE ») et garantit
    /// que `batch.last` est bien le nouveau curseur.
    ///
    /// `excluding` : rowids déjà vectorisés mais PAS ENCORE écrits (tampon en
    /// attente d'une fenêtre de verrou), interpolés en littéraux entiers. En
    /// balayage avant le tampon est tout entier DERRIÈRE le curseur et la clause
    /// est vide ; elle ne sert qu'à la passe de rattrapage, qui repart de 0.
    ///
    /// `after: 0` couvre bien TOUTES les pages : le rowid structuré du §4.1
    /// vaut `doc_id * 100 000 + page` avec `doc_id ≥ 1` et `page ≥ 1`, donc
    /// 100 001 au minimum.
    ///
    /// `topFolders` : quand il est posé, la sélection ne rend que les pages des
    /// documents de ces racines (lot MC3, constat PM-05). Il n'y a AUCUN tri
    /// par priorité — le curseur suppose un balayage de rowid croissant, et un
    /// `ORDER BY (priorité) DESC, f.rowid` le rendrait faux dès le second lot.
    /// La priorité se joue donc en PHASES, côté pompe : une passe restreinte
    /// aux racines épinglées, puis une passe sans restriction, chacune avec son
    /// propre curseur reparti de zéro.
    public func pagesNeedingVector(limit: Int, after: Int64 = 0,
                                   excluding: [Int64] = [],
                                   topFolders: [String]? = nil) throws
        -> [(rowid: Int64, text: String)] {
        let sql = Self.pagesNeedingVectorSQL(excluding: excluding,
                                             topFolders: topFolders)
        // L'ORDRE DES `?` EST CELUI DU TEXTE : `after`, puis les étiquettes de
        // racine, puis `limit`. Les étiquettes sont LIÉES et non interpolées —
        // ce sont des noms de dossiers choisis par l'utilisateur.
        var args: [any DatabaseValueConvertible] = [after]
        args.append(contentsOf: (topFolders ?? []).map { $0 })
        args.append(limit)
        return try read { db in
            try Row.fetchAll(db, sql: sql, arguments: StatementArguments(args))
                .map { ($0["rid"] as Int64, $0["body"] as String) }
        }
    }

    /// La requête de sélection, à un endroit et un seul : le test qui vérifie
    /// son PLAN d'exécution l'interroge ici plutôt que d'en recopier une
    /// version qui dériverait.
    static func pagesNeedingVectorSQL(excluding: [Int64] = [],
                                      topFolders: [String]? = nil) -> String {
        let exclusion = excluding.isEmpty ? ""
            : "AND f.rowid NOT IN (\(excluding.map(String.init).joined(separator: ",")))"
        // RESTRICTION PAR RACINE (lot MC3). Une sous-requête de LISTE, évaluée
        // UNE fois et gardée : `docs` fait 1 883 lignes là où `page_fts` en
        // fait 434 000, et une jointure supplémentaire sur `docs` à chaque page
        // candidate coûterait une sonde de plus par ligne examinée. Vérifié par
        // `EXPLAIN QUERY PLAN` : la sonde de clé primaire sur `page_vec` et la
        // poussée de `rowid >` dans fts5 sont INCHANGÉES (test dédié).
        var restriction = ""
        if let topFolders, !topFolders.isEmpty {
            let marks = Array(repeating: "?", count: topFolders.count)
                .joined(separator: ",")
            restriction = "AND f.rowid / \(Schema.pagesPerDocLimit) IN "
                + "(SELECT id FROM docs WHERE top_folder IN (\(marks)))"
        }
        // Créneau sentinelle, interpolé en littéraux entiers (constantes de
        // schéma, aucune injection possible) : le planificateur voit une
        // expression constante et garde sa sonde de clé primaire.
        let sentinel = "f.rowid * \(Schema.vecChunksPerPage) "
            + "+ \(Schema.vecWindowMax - 1)"
        return """
            SELECT f.rowid AS rid, f.body AS body
            FROM page_fts f LEFT JOIN page_vec v ON v.rowid = \(sentinel)
            WHERE f.rowid > ? AND v.rowid IS NULL \(restriction) \(exclusion)
            ORDER BY f.rowid
            LIMIT ?
            """
    }

    /// Créneaux DÉJÀ en base pour les pages d'un lot, en UNE requête.
    ///
    /// C'est ce qui rend la reprise d'une campagne gratuite : une page qui
    /// porte déjà certaines de ses fenêtres n'est ré-inférée QUE pour celles
    /// qui manquent. Les rowids sont
    /// énumérés un par un (`IN (…)`, au plus `batchSize × vecWindowMax`
    /// littéraux) et non demandés par plage : une plage `BETWEEN min AND max`
    /// balaierait tout ce qui se trouve entre deux pages éloignées, ce qui est
    /// précisément le cas d'une passe de rattrapage.
    public func existingVectorChunks(pageRowIDs: [Int64]) throws -> Set<Int64> {
        guard !pageRowIDs.isEmpty else { return [] }
        var wanted: [Int64] = []
        wanted.reserveCapacity(pageRowIDs.count * Schema.vecWindowMax)
        for page in pageRowIDs {
            for chunk in 0..<Schema.vecWindowMax {
                wanted.append(Schema.vecRowID(pageRowID: page, chunk: chunk))
            }
        }
        let list = wanted.map(String.init).joined(separator: ",")
        return try read { db in
            Set(try Int64.fetchAll(
                db, sql: "SELECT rowid FROM page_vec WHERE rowid IN (\(list))"))
        }
    }

    /// Écrit un lot de vecteurs en UNE transaction.
    public func upsertVectors(_ batch: [(rowid: Int64, vec: Data)]) throws {
        guard !batch.isEmpty else { return }
        try writeLocked { db in
            for (rowid, vec) in batch {
                try db.execute(sql: """
                    INSERT INTO page_vec(rowid, vec) VALUES (?,?)
                    ON CONFLICT(rowid) DO UPDATE SET vec = excluded.vec
                    """, arguments: [rowid, vec])
            }
        }
    }

    /// Nombre de lignes de `page_vec`, c'est-à-dire de FENÊTRES depuis le
    /// schéma v5 (sentinelles vides comprises). Ce n'est plus un nombre de
    /// pages : c'est la mesure de DÉRIVE que suit `SemanticService` pour savoir
    /// quand recharger son index, et le seul de ces comptes qui n'ait pas
    /// besoin d'un modulo. 13 ms sur 64 872 lignes (copie de la production).
    public func vectorCount() throws -> Int {
        try read { db in
            try Int.fetchOne(db, sql: "SELECT count(*) FROM page_vec") ?? 0
        }
    }

    /// Pages que le canal sémantique VOIT : celles qui portent une fenêtre 0.
    ///
    /// Balayage de `page_vec` avec modulo — mesuré 16 ms sur 64 872 lignes,
    /// ~0,2 s projeté sur les 1,1 M de fenêtres d'un corpus entièrement
    /// vectorisé. Sous ce prix, et pour trois appelants qui sont tous des
    /// commandes d'état (`fouine status`, `fouine embed --status`, la case
    /// « Sémantique » de l'app), un index partiel `WHERE rowid % 8 = 0` ne se
    /// justifie pas : il coûterait de l'espace et une écriture par vecteur
    /// produit, contre 0,2 s sur un chemin qui n'est jamais dans une recherche.
    public func vectorisedPageCount() throws -> Int {
        try read { db in
            try Int.fetchOne(db, sql: "SELECT count(*) FROM page_vec "
                             + "WHERE rowid % \(Schema.vecChunksPerPage) = 0") ?? 0
        }
    }

    /// Y a-t-il AU MOINS une page que le canal sémantique voit ?
    ///
    /// Le bandeau de santé ne teste qu'un booléen (`vectorCount > 0`) et il le
    /// refaisait toutes les 30 s en payant un `count(*)` complet (A2-08).
    /// `EXISTS` s'arrête à la première ligne trouvée : mesuré sur la base de
    /// production (91 943 vecteurs), 0,10 s → 0,03 s dont 0,03 s de lancement
    /// de `sqlite3` — c'est-à-dire de 0,07 s à rien du tout, et l'écart ne fera
    /// que grandir avec la campagne.
    public func hasAnyVector() throws -> Bool {
        try read { db in
            try Bool.fetchOne(db, sql: "SELECT EXISTS(SELECT 1 FROM page_vec "
                              + "WHERE rowid % \(Schema.vecChunksPerPage) = 0)") ?? false
        }
    }

    /// Pages COMPLÈTES : celles dont la sentinelle de complétude est posée,
    /// c'est-à-dire celles que `pagesNeedingVector` ne rendra plus. C'est le
    /// dénominateur du reste-à-faire d'une campagne.
    public func completeVectorPageCount() throws -> Int {
        try read { db in
            try Int.fetchOne(db, sql: "SELECT count(*) FROM page_vec "
                             + "WHERE rowid % \(Schema.vecChunksPerPage) "
                             + "= \(Schema.vecWindowMax - 1)") ?? 0
        }
    }

    /// Dimension des vecteurs telle que la BASE la porte, lue sur un blob.
    ///
    /// `vec_meta` est la source normale, et `EmbedRun` la pose toujours. Cette
    /// lecture-ci est le RECOURS : une base dont `vec_meta` a été perdue (une
    /// restauration partielle, un fixture de test) porte quand même des
    /// vecteurs parfaitement utilisables, et un lecteur qui refuserait de les
    /// charger faute de savoir leur taille rendrait « aucun vecteur » sur une
    /// base qui en a des dizaines de milliers — le mensonge le plus coûteux
    /// qu'un serveur de recherche puisse faire.
    ///
    /// Le blob est le vecteur d'UNE page (ou d'une fenêtre) : sa longueur reste
    /// la dimension quel que soit le nombre de vecteurs par page.
    public func vectorBlobDimension() throws -> Int? {
        try read { db in
            try Int.fetchOne(db, sql: "SELECT length(vec) FROM page_vec LIMIT 1")
        }
    }

    /// Pages indexées — le DÉNOMINATEUR de la couverture sémantique, affichée à
    /// chaque recherche hybride (C2-02 : la CLI disait « 24528 vectors » sans
    /// jamais dire que c'était 6 % du corpus).
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

    // MARK: - Lecture pour l'index en mémoire

    /// Tous les vecteurs en un tampon contigu (rowids de FENÊTRE parallèles au
    /// tampon, `data.count == rowids.count * dim`). Un blob de dimension
    /// inattendue est ignoré plutôt que de fausser l'alignement du tampon :
    /// vecteur d'un ancien modèle resté orphelin, et — depuis le schéma v5 —
    /// sentinelle de complétude, un blob VIDE que rien ne doit charger ni
    /// balayer. Ce filtre est ce qui rend la sentinelle gratuite à la lecture.
    ///
    /// CRÉNEAU HORS PLAGE = ROWID ÉTRANGER, ET IL EST ÉCARTÉ (audit A1m-05). Un
    /// rowid légitime porte un créneau `< vecWindowMax` : la pompe n'en écrit
    /// pas d'autre. Un rowid dont le créneau vaut 3 à 7 n'a donc PAS été écrit
    /// par ce schéma — c'est un rowid de PAGE du schéma v3, laissé par un
    /// binaire antérieur. Chargé tel quel, il se replie sur la page
    /// `rowid / 8`, qui n'est pas la sienne : sur la base de production du
    /// 04/09/2026, 12 336 lignes sont dans ce cas et 1 327 d'entre elles
    /// désignent une page RÉELLE — le canal sémantique présentait alors une
    /// page sans rapport, avec son extrait, comme un voisin sémantique. Un
    /// vecteur qu'on ne sait pas situer ne se charge pas.
    public func allVectors(dim: Int) throws -> (rowids: [Int64], data: [Int8]) {
        try read { db in
            var rowids: [Int64] = []
            var data: [Int8] = []
            let n = try Int.fetchOne(db, sql: "SELECT count(*) FROM page_vec") ?? 0
            rowids.reserveCapacity(n)
            data.reserveCapacity(n * dim)
            let rows = try Row.fetchCursor(
                db, sql: """
                    SELECT rowid, vec FROM page_vec
                    WHERE rowid % \(Schema.vecChunksPerPage) < \(Schema.vecWindowMax)
                    ORDER BY rowid
                    """)
            while let row = try rows.next() {
                let blob: Data = row["vec"]
                guard blob.count == dim else { continue }
                rowids.append(row["rowid"])
                blob.withUnsafeBytes { buf in
                    data.append(contentsOf: buf.bindMemory(to: Int8.self))
                }
            }
            return (rowids, data)
        }
    }

    /// Documents autorisés par les filtres d'une requête, pour appliquer les
    /// mêmes restrictions au canal vectoriel qu'au canal lexical (hybride).
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
    /// afficher un hit sémantique pur (aucun terme ne matche : `snippet()` est
    /// inapplicable) et pour lire une page entière (`fouine_read_page`, §12.4).
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
    /// Rowids de PAGE, pas de fenêtre : `VectorIndex.topK` replie ses hits par
    /// page avant de les rendre, et cette méthode est donc INCHANGÉE par le
    /// fenêtrage — comme `HybridSearch` et `RRF`.
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

    // MARK: - Pages vectorisées

    /// Nombre de PAGES portant un vecteur, par document.
    ///
    /// Fenêtrage v5 (fusionné le même jour) : `page_vec.rowid` est un rowid de
    /// FENÊTRE ; la plage est celle des fenêtres du document et seule la
    /// fenêtre 0 de chaque page est comptée. C'est, avec `vectorisedPageCount`,
    /// l'expression SQL qui traduit « vecteurs » en « pages » pour le serveur
    /// MCP.
    /// Les plages de rowid sont énumérées une par document plutôt qu'un
    /// `rowid / 100000 IN (…)` : une expression sur la clé primaire interdit
    /// l'index et balaie `page_vec` en entier (390 114 lignes à terme), là où
    /// N plages sont N sondes sur la clé — c'est la même règle que
    /// `ftsRowIDRange` (§4.1).
    public func vectorisedPageCounts(forDocIDs ids: [Int64]) throws -> [Int64: Int] {
        guard !ids.isEmpty else { return [:] }
        return try read { db in
            var out: [Int64: Int] = [:]
            for id in ids {
                // Schéma v5 : plage de FENÊTRES du document, et seules les
                // fenêtres 0 comptent — une page vue par le canal sémantique.
                let range = Schema.vecRowIDRange(docID: id)
                let n = try Int.fetchOne(db, sql: """
                    SELECT count(*) FROM page_vec WHERE rowid BETWEEN ? AND ?
                      AND rowid % \(Schema.vecChunksPerPage) = 0
                    """, arguments: [range.lowerBound, range.upperBound]) ?? 0
                if n > 0 { out[id] = n }
            }
            return out
        }
    }
}

// MARK: - Cohérence de page_vec (audit A1m-05)

/// Une ligne de `page_vec` qu'aucune version de la pompe n'a pu écrire.
///
/// Le fenêtrage (schéma v5) donne à `page_vec.rowid` une FORME : `page × 8 +
/// créneau`, créneau `< vecWindowMax`, page présente dans l'index. Toute ligne
/// qui sort de cette forme vient d'ailleurs — en pratique, d'un binaire d'un
/// autre schéma ayant écrit dans la base avant que `schemaMismatch` (lot J1) ne
/// le lui interdise. Ces lignes ne sont pas inertes : `foldByPage` les replie
/// sur `rowid / 8`, et quand cette page existe, le canal sémantique présente
/// une page sans rapport avec la requête, extrait à l'appui.
public struct VectorAnomaly: Sendable, Equatable {

    public enum Kind: String, Sendable, CaseIterable {
        /// Créneau `>= vecWindowMax` : la pompe n'en écrit jamais.
        case foreignSlot = "foreign_slot"
        /// `rowid / 8` ne désigne aucune page indexée.
        case orphanPage = "orphan_page"
        /// Sentinelle de complétude posée sur une page dont la fenêtre 0
        /// manque : la page se dit finie et ne sera plus jamais reprise.
        case brokenSentinel = "broken_sentinel"

        /// Ce qu'un dépanneur doit lire, en anglais comme tout le reste de la
        /// CLI (le geste, lui, est le même pour les trois : `--repair`).
        public var english: String {
            switch self {
            case .foreignSlot:
                return "window slot out of range (written by another schema)"
            case .orphanPage:
                return "no such indexed page"
            case .brokenSentinel:
                return "page marked complete but its first window is missing"
            }
        }
    }

    public let rowid: Int64
    public let kind: Kind

    public init(rowid: Int64, kind: Kind) {
        self.rowid = rowid
        self.kind = kind
    }

    public var json: [String: Any] {
        [
            "rowid": rowid,
            "kind": kind.rawValue,
            "page_rowid": rowid / Schema.vecChunksPerPage,
            "chunk": rowid % Schema.vecChunksPerPage,
            "reason": kind.english,
        ]
    }
}

/// Ce que `doctor --deep` a trouvé dans `page_vec`.
public struct VectorConsistencyReport: Sendable {
    public let rows: Int
    public let counts: [VectorAnomaly.Kind: Int]
    /// Quelques rowids par catégorie : un compte ne se vérifie pas à la main,
    /// un rowid si (`sqlite3 … "SELECT rowid FROM page_vec WHERE rowid = …"`).
    public let samples: [VectorAnomaly]
    public let elapsedMS: Double

    public init(rows: Int, counts: [VectorAnomaly.Kind: Int],
                samples: [VectorAnomaly], elapsedMS: Double) {
        self.rows = rows
        self.counts = counts
        self.samples = samples
        self.elapsedMS = elapsedMS
    }

    public func count(_ kind: VectorAnomaly.Kind) -> Int { counts[kind] ?? 0 }
    public var total: Int { counts.values.reduce(0, +) }
    public var isClean: Bool { total == 0 }

    public var json: [String: Any] {
        var object: [String: Any] = [
            "rows": rows,
            "inconsistent": total,
            "elapsed_ms": Int(round(elapsedMS)),
            "samples": samples.map(\.json),
        ]
        for kind in VectorAnomaly.Kind.allCases {
            object[kind.rawValue] = count(kind)
        }
        return object
    }
}

/// Ce que `maintain --repair` a retiré.
public struct VectorRepairReport: Sendable {
    public let deleted: [VectorAnomaly.Kind: Int]
    /// Pages remises « à vectoriser » : leur sentinelle de complétude est
    /// partie, donc `pagesNeedingVector` les rendra de nouveau.
    public let pagesRequeued: Int
    public let elapsedMS: Double

    public init(deleted: [VectorAnomaly.Kind: Int], pagesRequeued: Int,
                elapsedMS: Double) {
        self.deleted = deleted
        self.pagesRequeued = pagesRequeued
        self.elapsedMS = elapsedMS
    }

    public func count(_ kind: VectorAnomaly.Kind) -> Int { deleted[kind] ?? 0 }
    public var total: Int { deleted.values.reduce(0, +) }

    public var json: [String: Any] {
        var object: [String: Any] = [
            "deleted": total,
            "pages_requeued": pagesRequeued,
            "elapsed_ms": Int(round(elapsedMS)),
        ]
        for kind in VectorAnomaly.Kind.allCases {
            object[kind.rawValue] = count(kind)
        }
        return object
    }
}

extension GRDBStore {

    /// Les trois clauses SQL de l'incohérence, à un endroit et un seul : le
    /// contrôle (`checkVectors`) et la réparation (`repairVectors`) doivent
    /// désigner EXACTEMENT la même population, sans quoi `doctor` compterait
    /// des lignes que `maintain` ne retire pas.
    ///
    /// `broken_sentinel` ne se restreint PAS aux pages indexées : une
    /// sentinelle posée sur une page inexistante est déjà une `orphan_page`, et
    /// la réparation traite les trois dans l'ordre — orphelines d'abord.
    static func vectorAnomalyPredicate(_ kind: VectorAnomaly.Kind) -> String {
        switch kind {
        case .foreignSlot:
            return "v.rowid % \(Schema.vecChunksPerPage) >= \(Schema.vecWindowMax)"
        case .orphanPage:
            return "NOT EXISTS (SELECT 1 FROM page_fts_docsize f "
                + "WHERE f.id = v.rowid / \(Schema.vecChunksPerPage))"
        case .brokenSentinel:
            return "v.rowid % \(Schema.vecChunksPerPage) "
                + "= \(Schema.vecWindowMax - 1) "
                + "AND EXISTS (SELECT 1 FROM page_fts_docsize f "
                + "WHERE f.id = v.rowid / \(Schema.vecChunksPerPage)) "
                + "AND NOT EXISTS (SELECT 1 FROM page_vec w "
                + "WHERE w.rowid = v.rowid - \(Schema.vecWindowMax - 1))"
        }
    }

    /// La clause EFFECTIVE d'une catégorie : son prédicat, moins celui des
    /// catégories qui la précèdent.
    ///
    /// Les prédicats se CHEVAUCHENT — le rowid v3 `300 007` a un créneau 7
    /// (`foreign_slot`) ET ne désigne aucune page (`orphan_page`). Comptés
    /// séparément, `doctor --deep` annoncerait plus de lignes que `maintain
    /// --repair` n'en retire, et un dépanneur conclurait que la réparation a
    /// échoué. Un ordre de priorité rend les trois populations DISJOINTES, et
    /// les deux commandes désignent alors exactement les mêmes lignes.
    static let vectorAnomalyOrder: [VectorAnomaly.Kind] =
        [.foreignSlot, .orphanPage, .brokenSentinel]

    static func vectorAnomalyClause(_ kind: VectorAnomaly.Kind) -> String {
        var clause = "(" + vectorAnomalyPredicate(kind) + ")"
        for earlier in vectorAnomalyOrder {
            if earlier == kind { break }
            clause += " AND NOT (" + vectorAnomalyPredicate(earlier) + ")"
        }
        return clause
    }

    /// Compte ET NOMME les lignes de `page_vec` qu'aucune pompe n'a pu écrire.
    ///
    /// Lecture pure : aucun verrou, `doctor --deep` l'appelle avant de prendre
    /// le sien pour l'`integrity-check` FTS5. Trois balayages de `page_vec`
    /// avec sonde de clé primaire sur `page_fts_docsize` — 0,4 s sur les 83 837
    /// lignes de la copie du 04/09/2026, contre 3 min 30 pour l'intégrité FTS5
    /// du même `--deep` : le prix est dans le bruit.
    public func checkVectors(sampleLimit: Int = 5) throws
        -> VectorConsistencyReport {
        let start = Date()
        var counts: [VectorAnomaly.Kind: Int] = [:]
        var samples: [VectorAnomaly] = []
        let rows = try read { db -> Int in
            for kind in Self.vectorAnomalyOrder {
                let clause = Self.vectorAnomalyClause(kind)
                counts[kind] = try Int.fetchOne(
                    db, sql: "SELECT count(*) FROM page_vec v WHERE \(clause)") ?? 0
                if sampleLimit > 0 {
                    for rowid in try Int64.fetchAll(
                        db, sql: "SELECT v.rowid FROM page_vec v WHERE \(clause) "
                            + "ORDER BY v.rowid LIMIT \(max(0, sampleLimit))") {
                        samples.append(VectorAnomaly(rowid: rowid, kind: kind))
                    }
                }
            }
            return try Int.fetchOne(db, sql: "SELECT count(*) FROM page_vec") ?? 0
        }
        return VectorConsistencyReport(
            rows: rows, counts: counts, samples: samples,
            elapsedMS: Date().timeIntervalSince(start) * 1000.0)
    }

    /// Retire les lignes que `checkVectors` désigne, et rend les pages
    /// concernées à `fouine embed`.
    ///
    /// ORDRE OBLIGATOIRE. Les orphelines et les créneaux étrangers partent
    /// d'abord : ils ne touchent aucune page réelle (un créneau `>= 3` n'est
    /// jamais une sentinelle, une orpheline ne désigne aucune page indexée),
    /// donc ils ne peuvent pas fabriquer de fausse sentinelle. Les sentinelles
    /// cassées sont recomptées ENSUITE, sur la base nettoyée : c'est le seul
    /// des trois cas qui remet du travail dans la file, et il faut qu'il voie
    /// l'état final. Une page dont la sentinelle part redevient « incomplète »
    /// pour `pagesNeedingVector` — aucune autre écriture n'est nécessaire, la
    /// campagne la reprendra d'elle-même.
    ///
    /// Tout en UNE transaction sous le verrou nommé : une réparation à moitié
    /// faite laisserait la base dans un état qu'aucun des deux comptes ne
    /// décrit.
    public func repairVectors() throws -> VectorRepairReport {
        let start = Date()
        var deleted: [VectorAnomaly.Kind: Int] = [:]
        try writeLocked { db in
            for kind in Self.vectorAnomalyOrder {
                let clause = Self.vectorAnomalyClause(kind)
                deleted[kind] = try Int.fetchOne(
                    db, sql: "SELECT count(*) FROM page_vec v WHERE \(clause)") ?? 0
                try db.execute(sql: "DELETE FROM page_vec AS v WHERE \(clause)")
            }
        }
        return VectorRepairReport(
            deleted: deleted, pagesRequeued: deleted[.brokenSentinel] ?? 0,
            elapsedMS: Date().timeIntervalSince(start) * 1000.0)
    }
}

// MARK: - Débit de la campagne (idée 7 de l'audit A1m)

/// Ce que la dernière campagne `fouine embed` a mesuré, et ce qu'il reste.
public struct EmbedForecast: Sendable {
    /// Fenêtres par seconde de la dernière passe. `nil` : aucune passe n'a
    /// encore tourné sur cette base.
    public let windowsPerSecond: Double?
    public let measuredAt: Date?
    /// Fenêtres RÉELLES par page complète, mesurée sur CETTE base — 2,13 sur
    /// le corpus de production, mais un corpus de notes courtes est bien
    /// au-dessous.
    public let windowsPerPage: Double
    public let incompletePages: Int

    public var remainingWindows: Double { Double(incompletePages) * windowsPerPage }

    /// Heures restantes au débit de la dernière passe, ou `nil` faute de
    /// débit connu. On ne devine pas : « il reste 28 h » se comprend,
    /// « il reste 385 626 pages » non, et un chiffre inventé est pire que rien.
    public var remainingHours: Double? {
        guard let rate = windowsPerSecond, rate > 0, incompletePages > 0
        else { return nil }
        return remainingWindows / rate / 3600.0
    }
}

extension GRDBStore {

    static let embedRateKey = "rate_win_s"
    static let embedRateAtKey = "rate_at"

    /// Enregistre le débit d'une passe terminée, dans `vec_meta`.
    ///
    /// Pas dans `settings` : ce n'est pas un réglage de l'utilisateur mais une
    /// MESURE du sous-système vectoriel, et `SettingsSnapshot` accuserait une
    /// clé inconnue. Best-effort chez l'appelant : rater l'enregistrement du
    /// débit ne doit jamais faire échouer une campagne de vingt heures.
    public func recordEmbedRate(windowsPerSecond: Double,
                                at date: Date = Date()) throws {
        guard windowsPerSecond > 0 else { return }
        try writeLocked { db in
            try db.execute(sql: """
                INSERT OR REPLACE INTO vec_meta(k, v) VALUES (?,?), (?,?)
                """, arguments: [
                    Self.embedRateKey,
                    String(format: "%.4f", windowsPerSecond),
                    Self.embedRateAtKey,
                    String(Int(date.timeIntervalSince1970)),
                ])
        }
    }

    /// Ce qu'il reste à faire, en HEURES quand c'est possible.
    ///
    /// `windowsPerPage` est mesuré sur les pages DÉJÀ complètes de cette base
    /// plutôt que sur la constante 2,13 du corpus de production : un corpus de
    /// notes courtes tient en une fenêtre par page, et projeter 2,13 lui
    /// annoncerait le double du travail réel. Sans page complète (campagne qui
    /// n'a jamais tourné), on retombe sur la constante.
    public func embedForecast() throws -> EmbedForecast {
        let meta = try vecMeta()
        let rate = meta[Self.embedRateKey].flatMap(Double.init)
        let at = meta[Self.embedRateAtKey].flatMap(Double.init)
            .map { Date(timeIntervalSince1970: $0) }
        let indexed = try indexedPageCount()
        let complete = try completeVectorPageCount()

        let perPage = try read { db -> Double in
            guard complete > 0 else { return 2.13 }
            // Fenêtres RÉELLES (blob non vide) des pages complètes : la
            // sentinelle vide n'est pas une inférence, et la compter
            // sur-estimerait le travail restant d'un tiers.
            let real = try Int.fetchOne(db, sql: """
                SELECT count(*) FROM page_vec v
                WHERE length(v.vec) > 0
                  AND v.rowid % \(Schema.vecChunksPerPage) < \(Schema.vecWindowMax)
                  AND EXISTS (SELECT 1 FROM page_vec s
                              WHERE s.rowid = (v.rowid / \(Schema.vecChunksPerPage))
                                    * \(Schema.vecChunksPerPage)
                                    + \(Schema.vecWindowMax - 1))
                """) ?? 0
            return real > 0 ? Double(real) / Double(complete) : 2.13
        }

        return EmbedForecast(windowsPerSecond: rate, measuredAt: at,
                             windowsPerPage: perPage,
                             incompletePages: max(0, indexed - complete))
    }
}
