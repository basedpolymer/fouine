// GRDBStore+Search.swift — recherche, flou et facettes (SPEC §4.1, §5.5.2, §5.5.3).
// Propriété : A-Core.
//
// UN SEUL PIPELINE DE CLASSEMENT (lot R1, 05/09/2026). Exact ou flou, la
// recherche construit une CTE de base (doc_id, page, r, fz) — `m` sur le
// chemin exact, `g` (dédupliquée) sur le chemin flou — puis empile les mêmes
// couches : les BONUS (`gb`, phrase / voisinage / nom du lot M1, forme tapée
// du lot P1), puis la
// DIVERSITÉ par document (`dv`, une fonction fenêtre qui numérote les pages de
// chaque document et rétrograde les suivantes), puis `ORDER BY … LIMIT`. Les
// extraits, les métadonnées et les chemins ne sont lus QUE pour la tranche
// rendue. Jusqu'au lot R1, le chemin exact triait dans la sous-requête FTS et
// y calculait `snippet()` pour TOUTES les pages appariées ; mesuré sur la base
// réelle (v7, 18 309 pages pour `free energy`) : 38 ms avant, 63 ms avec la
// fenêtre et l'extrait lu après, +3 ms sur `chimie` (3 148 pages).
//
// MORPHOLOGIE (lot R1, `Morphology`) : chaque mot nu de la chaîne FTS devient
// `(mot OR pluriel)` AVANT tout le reste — comptages, facettes, sondes,
// extraits lisent la même chaîne. Ce n'est pas un bonus : cela change ce qui
// est TROUVÉ, et les totaux le disent.
//
// FORME IMPOSÉE (§4.1) : sous-requête sur page_fts puis JOIN docs. Toute autre
// forme déclenche « ambiguous column name » (piège n°9).
//
// FORME IMPOSÉE DU FLOU (§5.5.3) : CTE ex + CTE fz (jointure page_src, src != 0
// pour la portée `ocr`), UNION ALL, GROUP BY doc_id, page avec min(fz)/min(r),
// ORDER BY r ASC, fz ASC (D-R1). Le GROUP BY n'est pas une optimisation : sans lui,
// une page trouvée exactement ET par variante sort DEUX FOIS (T14).
//
// GARDE-FOU DU PLAN FLOU (recette tranche A, bogue 1) : un plan sans AUCUNE
// branche fz dégénère en `u AS (SELECT * FROM ex)` ; SQLite aplatit alors la
// CTE dans l'agrégat extérieur, où `bm25()` est interdit -> erreur 1, sortie 3.
// C'était le cas de toute requête `pres:N` en auto/on (`substitute` ne touche
// jamais l'intérieur d'un NEAR). Le plan flou n'est donc emprunté QUE s'il
// porte au moins une vraie branche fz ; sinon, chemin exact.
//
// FILTRES DE CHEMIN ET EXCLUSIONS DE FILTRES (lot MC1). `chemin:Offres` et
// `-dossier:X` / `-ext:X` / `-nom:X` / `-chemin:X` sont des clauses de DOCUMENT
// de plus dans la même sous-requête FTS : `docs.rel_path` par la fonction SQL
// `fold` (casse et accents), `top_folder NOT IN`, `ext NOT IN`, `docs_fts` en
// négatif. Aucune n'est posée quand la requête n'en porte pas : à champs vides
// le SQL est celui d'avant, au caractère près (test dédié).
//
// EXCLUSION PAR DOCUMENT (arbitrage T5, post-recette) : `-terme` exclut le
// DOCUMENT entier (§8.1 T5, comportement FoxTrot), pas seulement la page. Les
// termes négatifs ne sont plus dans l'expression MATCH : ils arrivent par
// `excludingDocsMatching` et deviennent
// `AND doc_id NOT IN (SELECT doc_id FROM page_fts WHERE page_fts MATCH :neg)`.

import Foundation
import GRDB

extension GRDBStore {

    /// Seuil du mode `auto` : l'expansion n'est déclenchée que si la requête
    /// exacte ramène moins de 20 pages (§5.5.2).
    public static let autoFuzzyThreshold = 20
    /// Plafond de variantes retenues par terme.
    public static let fuzzyVariantCap = 12

    /// L'expression `snippet()` de FTS5, marqueurs de surlignage compris.
    ///
    /// LES MARQUEURS ÉTAIENT UN LITTÉRAL (constat PM-23), à ce seul endroit du
    /// dépôt. Ils viennent désormais de `SearchQuery.snippetMarkers`, dont le
    /// défaut est exactement `«` et `»` : à requête ordinaire, cette fonction
    /// rend la chaîne d'avant AU CARACTÈRE PRÈS (test dédié), et l'application,
    /// qui ne passe rien, ne change pas d'un signe.
    ///
    /// L'apostrophe est DOUBLÉE : un marqueur est une valeur d'énumération du
    /// serveur MCP, donc jamais arbitraire aujourd'hui, mais une chaîne
    /// interpolée dans du SQL se protège là où elle est écrite, pas là où on
    /// espère qu'elle vient.
    static func snippetExpr(_ q: SearchQuery) -> String {
        func quoted(_ text: String) -> String {
            "'" + text.replacingOccurrences(of: "'", with: "''") + "'"
        }
        return "snippet(page_fts, 0, \(quoted(q.snippetMarkers.open)), "
            + "\(quoted(q.snippetMarkers.close)), '…', 12)"
    }

    /// doc_id DÉRIVÉ DU ROWID structuré (§4.1 : rowid = doc_id·100000 + page,
    /// page ∈ [1, 99999]). Lire la COLONNE doc_id (UNINDEXED) force FTS5 à
    /// chercher la ligne dans sa table de contenu (~6-8 µs par page trouvée :
    /// 21 ms sur « chimie », 2 489 pages) ; le rowid, lui, sort de l'index.
    /// Mesuré : count(DISTINCT rowid/100000) = 1-2 ms sur la même requête.
    private static let ftsDocIDExpr = "(page_fts.rowid / \(Schema.pagesPerDocLimit))"
    /// page dérivée du même rowid, pour les mêmes raisons que `ftsDocIDExpr`.
    private static let ftsPageExpr = "(page_fts.rowid % \(Schema.pagesPerDocLimit))"

    // MARK: - Morphologie

    /// La chaîne FTS que le moteur voit : chaque mot nu élargi à ses formes
    /// (`Morphology`), ou la chaîne telle quelle quand `q.morphology` est faux.
    /// Une seule fonction pour la recherche, les facettes et le comptage par
    /// document : trois surfaces qui doivent compter la même chose.
    static func effectiveFTS(_ fts: String, morphology: Bool) -> String {
        guard morphology else { return fts }
        let table = Morphology.expansions(forBareWordsIn: fts)
        return table.isEmpty ? fts : substitute(fts, terms: [], expansions: table)
    }

    /// La morphologie s'applique-t-elle à cette requête ? Jamais à une chaîne
    /// FTS5 BRUTE (`--raw-fts`, `terms` vide) : elle « part telle quelle »
    /// (docs/cli.md), et réécrire `body:polymere` ou `^polymere` la rendait
    /// invalide — erreur FTS5, sortie 3 (AUDIT-R1 I1). Les mots nus d'une
    /// requête analysée sont exactement `q.terms` : sans terme, rien à décliner.
    static func morphologyApplies(_ q: SearchQuery) -> Bool {
        q.morphology && !q.terms.isEmpty
    }

    /// Les formes de chaque terme tapé, repliées, la forme tapée en tête —
    /// pour les sondes de bonus. Sans morphologie : la forme repliée seule.
    /// Les formes partagées entre deux termes ne vont à aucun (`Morphology`).
    static func termForms(_ q: SearchQuery) -> [[String]] {
        q.terms.map { term in
            morphologyApplies(q)
                ? Morphology.forms(of: term, among: q.terms) : [Morphology.fold(term)]
        }
    }

    // MARK: - Recherche

    /// Point d'entrée du protocole IndexStore (gelé) : sans exclusion de
    /// documents. La CLI passe par la surcharge ci-dessous.
    public func search(_ q: SearchQuery) throws -> SearchResults {
        try search(q, excludingDocsMatching: nil)
    }

    /// `negative` : expression MATCH des termes exclus (`-terme`, arbitrage T5) ;
    /// tout document dont UNE page y répond est exclu, `nil` = aucune exclusion.
    ///
    /// LE POINT UNIQUE DE LA RECHERCHE LEXICALE : la CLI, l'application, le
    /// serveur MCP et le canal lexical de l'hybride (`HybridSearch.run`)
    /// passent tous par ici. C'est donc ici que vivent les deux ajouts du lot
    /// MP1 — le repli en flou (C2-08) et le canal des noms (PR-02) —, et non
    /// dans trois surfaces qui auraient divergé.
    public func search(_ q: SearchQuery,
                       excludingDocsMatching negative: String?) throws -> SearchResults {
        // `nom:rapport` SANS terme de page (lot QP1) : il n'y a pas de page à
        // chercher, les résultats sont les documents eux-mêmes — ni quorum, ni
        // flou, ni bandeau des noms, qui répéterait la liste.
        if Self.searchesNamesOnly(q) {
            return try documentsByName(q, excludingDocsMatching: negative)
        }
        let exact = try searchOnce(q, excludingDocsMatching: negative)
        let names = try q.offset == 0
            ? documentsMatchingName(q) : []
        // LE QUORUM AVANT LE FLOU (RK-04). Les deux répondent à « la recherche
        // stricte ne rend presque rien », mais le quorum garde les mots de
        // l'utilisateur — il en demande simplement moins à la fois — là où le
        // flou en change l'orthographe. Le flou ne tourne donc que si le quorum
        // n'a rien rendu non plus : sur `comment mesurer la chaleur degagee par
        // une reaction`, proposer des « orthographes proches » serait absurde.
        if let relaxed = try quorumPass(q, strict: exact, negative: negative) {
            return relaxed.withNameMatches(names)
        }
        guard Self.deservesFuzzyFallback(q, results: exact) else {
            return exact.withNameMatches(names)
        }
        // REPLI EN FLOU (C2-08). Zéro résultat exact : on rejoue UNE fois, en
        // tolérant les fautes sur tout l'index — là où l'utilisateur se trompe,
        // c'est-à-dire dans SA requête, et non seulement sur les pages
        // scannées. Le chemin normal ne paie rien : aucun appel de plus dès
        // qu'il y a un résultat.
        var retry = q
        retry.fuzzy = .on
        retry.fuzzyScope = .all
        let fuzzy = try searchOnce(retry, excludingDocsMatching: negative)
        guard !fuzzy.hits.isEmpty else { return exact.withNameMatches(names) }
        return SearchResults(hits: fuzzy.hits, totalPages: fuzzy.totalPages,
                             totalDocs: fuzzy.totalDocs,
                             // LES DEUX PASSES : le temps annoncé est celui que
                             // la recherche a réellement coûté.
                             elapsedMS: exact.elapsedMS + fuzzy.elapsedMS,
                             totalsApproximate: fuzzy.totalsApproximate,
                             fuzzyFallback: true, nameMatches: names)
    }

    /// Le repli en flou a-t-il lieu ?
    ///
    /// QUATRE CONDITIONS, toutes nécessaires : la requête exacte n'apparie
    /// AUCUNE page ; au moins un mot analysé (`--raw-fts` n'en a aucun — sa
    /// chaîne part telle quelle à FTS5 et deviner ses termes serait inventer) ;
    /// les fautes ne sont pas refusées (« jamais ») ; et la requête n'était pas
    /// DÉJÀ le repli, sans quoi la seconde passe serait la copie de la première.
    ///
    /// LE TOTAL, ET NON LA TRANCHE. « Charger plus » demande un offset au-delà
    /// du dernier résultat : la tranche est vide alors que la requête, elle,
    /// apparie des pages. Sur `hits.isEmpty`, ce cas déclenchait un second
    /// passage flou dont les pages se seraient AJOUTÉES à un jeu exact.
    static func deservesFuzzyFallback(_ q: SearchQuery, results: SearchResults) -> Bool {
        guard results.totalPages == 0, !q.terms.isEmpty,
              q.fuzzy != .off else { return false }
        return !(q.fuzzy == .on && q.fuzzyScope == .all)
    }

    // MARK: - Le quorum des mots (lot RK2, RK-04)

    /// L'expression FTS5 du quorum pour cette requête, ou `nil` si elle n'y a
    /// pas droit.
    ///
    /// CE QUI RESTE STRICT, et pourquoi. Une PHRASE, un `NEAR`/`pres:`, un
    /// préfixe `*`, une exclusion `-mot` : l'utilisateur a dit lui-même ce
    /// qu'il voulait, et en relâcher une partie rendrait des pages qu'il a
    /// explicitement écartées. Ces garde-fous sont ceux des sondes de
    /// classement (`rankingProbes`), lus sur `q.fts` : un guillemet, une
    /// parenthèse (seul `NEAR(…)` en produit), une étoile ou un ` OR ` suffisent
    /// à sortir.
    ///
    /// UNE REQUÊTE FILTRÉE Y A DROIT DEPUIS LE LOT MC1 (constat PM-11).
    /// Jusque-là, `dossier:`, `ext:`, la langue, la date, `--in` désarmaient
    /// le quorum : « deux relâchements à la fois ne se lisent plus ». Mesuré le
    /// 13/09/2026 sur la base de production, c'est l'inverse : `distribution
    /// des temps de séjour dans un réacteur réel` rend 28 pages avec
    /// `quorum: true`, et la MÊME question sous `dossier:Livres` en rendait
    /// **zéro** — c'est-à-dire précisément la forme qu'un assistant emploie.
    /// Un filtre RESTREINT le corpus ; il ne dit rien de l'exigence sur les
    /// mots, et le quorum joue alors sur un jeu plus petit, ce qui est plus sûr.
    ///
    /// DEUX GARDES RESTENT. `nom:` est une question sur les documents, pas sur
    /// les mots d'une page ; et un filtre de PROVENANCE change le sens de la
    /// demande (« sur les pages scannées seulement »), où relâcher le ET
    /// mélangerait deux approximations.
    ///
    /// TROIS MOTS TAPÉS AU MOINS : à deux mots, la requête n'a rien à relâcher
    /// sans devenir un OR.
    static func quorumExpression(for q: SearchQuery, strictPages: Int,
                                 negative: String?) -> String? {
        guard q.quorum, negative == nil,
              strictPages < Schema.quorumTrigger,
              q.terms.count >= 3,
              q.nameTerms.isEmpty, q.keepsAllSources else { return nil }
        let fts = q.fts
        guard !fts.contains("\""), !fts.contains("*"),
              !fts.contains("("), !fts.contains(")"),
              !fts.contains(" OR ") else { return nil }
        guard q.terms.allSatisfy({ isSubstitutable($0, in: fts) }) else { return nil }
        return QueryParser.quorumFTS(terms: q.terms)
    }

    /// La passe de quorum, ou `nil` quand elle n'a pas lieu — ou n'apporte rien.
    ///
    /// DEUX REQUÊTES CONCATÉNÉES, et non une CTE de rang. Les pages STRICTES
    /// doivent garder la tête (elles portent tous les mots), et un rang calculé
    /// en SQL aurait demandé de faire voyager une colonne de plus à travers les
    /// couches de classement (`gb`, `dv`) — donc de changer le SQL du chemin
    /// ordinaire, que deux tests comparent au caractère près. Ici, le chemin
    /// désarmé n'est pas touché du tout : la passe stricte est celle d'avant,
    /// et la seconde est une recherche ordinaire sur une autre chaîne FTS.
    /// Le prix est une lecture de plus de la tête stricte quand la tranche
    /// demandée n'est pas la première — au plus dix pages, puisque c'est la
    /// condition même du quorum.
    ///
    /// Les sondes de classement (phrase, voisinage, nom, forme tapée) sont
    /// celles de la requête TAPÉE, pas de l'expression relâchée : une page qui
    /// porte les mots en phrase mérite son bonus, et l'expression du quorum —
    /// pleine de parenthèses et de `OR` — aurait désarmé les sondes.
    private func quorumPass(_ q: SearchQuery, strict: SearchResults,
                            negative: String?) throws -> SearchResults? {
        guard let expression = Self.quorumExpression(
            for: q, strictPages: strict.totalPages, negative: negative)
        else { return nil }

        // Toute la tête stricte, quelle que soit la tranche demandée : elle
        // compte moins de `quorumTrigger` pages par construction.
        let head: [Hit]
        if q.offset == 0, q.limit >= Schema.quorumTrigger {
            head = strict.hits
        } else {
            var top = q
            top.offset = 0
            top.limit = Schema.quorumTrigger
            head = try searchOnce(top, excludingDocsMatching: negative).hits
        }

        var wide = q
        wide.fts = expression
        wide.offset = 0
        wide.limit = q.offset + q.limit + head.count
        let relaxed = try searchOnce(wide, excludingDocsMatching: negative,
                                     probesFrom: q)
        // Le quorum apparie un SUR-ENSEMBLE du strict : à total égal, il n'a
        // rien relâché du tout, et l'annoncer serait mentir.
        guard relaxed.totalPages > strict.totalPages else { return nil }

        let strictKeys = Set(head.map { Schema.ftsRowID(docID: $0.docID, page: $0.page) })
        let tail = relaxed.hits.filter {
            !strictKeys.contains(Schema.ftsRowID(docID: $0.docID, page: $0.page))
        }
        let hits = Array((head + tail).dropFirst(q.offset).prefix(q.limit))
        return SearchResults(hits: hits, totalPages: relaxed.totalPages,
                             totalDocs: relaxed.totalDocs,
                             elapsedMS: strict.elapsedMS + relaxed.elapsedMS,
                             totalsApproximate: relaxed.totalsApproximate,
                             quorum: true)
    }

    /// Une passe de recherche, exacte ou floue selon `q`. Le corps historique
    /// du §4.1 : à option éteinte, son SQL est celui d'avant le lot MP1 au
    /// caractère près (test dédié).
    ///
    /// `probesFrom` : la requête dont on tire les sondes de classement, quand
    /// ce n'est pas `q` lui-même (passe de quorum, ci-dessus).
    private func searchOnce(_ q: SearchQuery,
                            excludingDocsMatching negative: String?,
                            probesFrom: SearchQuery? = nil) throws -> SearchResults {
        let start = DispatchTime.now().uptimeNanoseconds
        func elapsed() -> Double {
            Double(DispatchTime.now().uptimeNanoseconds - start) / 1_000_000
        }
        guard !q.fts.trimmingCharacters(in: .whitespaces).isEmpty else {
            return SearchResults(hits: [], totalPages: 0, totalDocs: 0,
                                 elapsedMS: elapsed())
        }

        // La morphologie s'applique aussi à l'exclusion : « -biologie » écarte
        // les documents qui parlent de « biologies », c'est le même mot.
        let fts = Self.effectiveFTS(q.fts, morphology: Self.morphologyApplies(q))
        let negativeFTS = negative.map { Self.effectiveFTS($0, morphology: Self.morphologyApplies(q)) }
        let filter = docFilter(q, column: Self.ftsDocIDExpr,
                               page: Self.ftsPageExpr, negative: negativeFTS)
        // Pages ET documents en UNE exécution FTS : compter deux fois coûtait
        // un troisième parcours complet du MATCH sur chaque recherche exacte.
        let exactTotal = try counts(match: fts, filter: filter, threshold: q.approximateThreshold)

        let variants = try fuzzyVariants(for: q, exactTotal: exactTotal.pages)
        let plan = variants.isEmpty
            ? nil : fuzzyPlan(q, variants: variants, negative: negativeFTS)
        let probes = Self.rankingProbes(for: probesFrom ?? q,
                                        matchedPages: exactTotal.pages)
        let diversity = Self.diversifies(q, matchedPages: exactTotal.pages)

        let rows: [Row]
        let totals: (pages: Int, docs: Int, approximate: Bool)
        let widestMatch: String
        if let plan, plan.hasFuzzyBranches {
            // Résultats ET totaux en UNE exécution du prélude (il coûte deux
            // requêtes FTS : le rejouer doublait le temps de la recherche
            // floue). MATERIALIZED est indispensable — sans lui SQLite
            // réévalue `g` à chacune de ses trois références.
            // `count(DISTINCT …) OVER ()` n'est pas une option : SQLite refuse
            // DISTINCT dans une fonction fenêtre. Les DEUX totaux continuent
            // de lire `g` : bonus et diversité ne changent que l'ORDRE.
            let layers = Self.rankingLayers(base: "g", probes: probes, diversity: diversity)
            // Les arguments sont SORTIS de l'appel et TYPÉS. Mesuré le
            // 14/09/2026 (lot BT1) : la même concaténation écrite dans
            // `StatementArguments(…)` demandait 5,4 s de type-checking à elle
            // seule — un `+` entre tableaux d'existentiels optionnels et un
            // littéral d'entiers laisse le vérificateur essayer toutes les
            // surcharges. Le SQL, lui, ne change pas d'un caractère.
            let args: [(any DatabaseValueConvertible)?] =
                plan.args + Self.probeArgs(probes)
                + [q.approximateThreshold + 1, q.approximateThreshold + 1,
                   q.limit, q.offset]
            rows = try read { db -> [Row] in
                try Row.fetchAll(db, sql: """
                    \(plan.prelude),
                    g AS MATERIALIZED (
                      SELECT doc_id, page, min(fz) AS fz, min(r) AS r
                      FROM u GROUP BY doc_id, page
                    )\(Self.probeCTEs(probes, leadingComma: true))\(layers.ctes)
                    SELECT doc_id, page, fz, \(layers.score) AS r,
                           (SELECT count(*) FROM (SELECT 1 FROM g LIMIT ?))               AS total_pages,
                           (SELECT count(DISTINCT doc_id) FROM (SELECT doc_id FROM g LIMIT ?)) AS total_docs
                    FROM \(layers.source)
                    ORDER BY r ASC, fz ASC, doc_id, page
                    LIMIT ? OFFSET ?
                    """,
                    arguments: StatementArguments(args))
            }
            // Un offset au-delà du dernier résultat ne rend aucune ligne, donc
            // aucun total : seul cas où le prélude est encore joué deux fois.
            if let first = rows.first {
                let p = first["total_pages"] as Int
                let d = first["total_docs"] as Int
                totals = p > q.approximateThreshold
                    ? (q.approximateThreshold, min(d, q.approximateThreshold), true)
                    : (p, d, false)
            } else if q.offset > 0 {
                totals = try fuzzyTotals(plan, threshold: q.approximateThreshold)
            } else {
                totals = (0, 0, false)
            }
            widestMatch = plan.widestMatch
        } else {
            // Chemin exact — aussi le repli du bogue 1 (voir l'en-tête).
            rows = try exactRows(fts: fts, filter: filter, q: q,
                                 probes: probes, diversity: diversity)
            totals = exactTotal
            widestMatch = fts
        }

        // LE MALUS DES SOMMAIRES (RK-07), ici et pas en SQL : le verdict se lit
        // sur le TEXTE de la page, que seule une lecture par rowid donne.
        let (ordered, tables) = try demotingTablesOfContents(rows, q: q)
        let keys = ordered.map { (docID: $0["doc_id"] as Int64, page: $0["page"] as Int) }
        let snippets = try snippetsFor(keys, match: widestMatch, filter: filter,
                                       markers: q)
        let meta = try pageMeta(for: keys)
        let paths = try relPaths(for: keys.map(\.docID))

        let hits = ordered.map { row -> Hit in
            let docID: Int64 = row["doc_id"]
            let page: Int = row["page"]
            let rowid = Schema.ftsRowID(docID: docID, page: page)
            return Hit(docID: docID, path: paths[docID] ?? "", page: page,
                       score: row["r"], snippet: snippets[rowid] ?? "",
                       source: meta[rowid]?.source ?? .native,
                       fuzzyDistance: row["fz"],
                       tableOfContents: tables.contains(rowid))
        }
        return SearchResults(hits: hits, totalPages: totals.pages,
                             totalDocs: totals.docs, elapsedMS: elapsed(),
                             totalsApproximate: totals.approximate)
    }

    // MARK: - Le malus des sommaires (lot RK2, RK-07)

    /// Les mêmes lignes, les tables des matières repoussées à la fin des
    /// `Schema.tocProbeDepth` premières — et les rowids jugés sommaires.
    ///
    /// APRÈS LES COUCHES SQL, AVANT LE GROUPEMENT PAR DOCUMENT : le malus se
    /// pose sur le classement fini, il ne se mêle ni aux bonus (qui multiplient
    /// un score) ni à la diversité (qui compte les pages d'un document). Il ne
    /// RETIRE rien : une page reculée reste dans la liste, dans le même
    /// document, et les totaux ne bougent pas.
    ///
    /// SEULEMENT LA PREMIÈRE TRANCHE (`offset == 0`). Reculer une page à
    /// l'intérieur d'une tranche suivante la ferait changer de place sans que
    /// rien ne la compare aux précédentes ; et « Charger plus » descend déjà
    /// sous le rang 50, où le malus ne déplace plus rien d'utile.
    ///
    /// ORDRE STABLE : `filter` conserve l'ordre d'origine dans chacun des deux
    /// paquets, les sommaires gardent donc leur classement entre eux.
    private func demotingTablesOfContents(_ rows: [Row], q: SearchQuery) throws
        -> ([Row], Set<Int64>) {
        guard q.demoteTableOfContents, q.offset == 0, !rows.isEmpty else {
            return (rows, [])
        }
        let depth = min(Schema.tocProbeDepth, rows.count)
        let head = Array(rows[0..<depth])
        func rowID(_ row: Row) -> Int64 {
            Schema.ftsRowID(docID: row["doc_id"] as Int64, page: row["page"] as Int)
        }
        let texts = try pageBodies(rowIDs: head.map(rowID))
        var tables: Set<Int64> = []
        for row in head {
            let id = rowID(row)
            if let text = texts[id], TableOfContentsProbe.isTableOfContents(text) {
                tables.insert(id)
            }
        }
        guard !tables.isEmpty else { return (rows, []) }
        let kept = head.filter { !tables.contains(rowID($0)) }
        let demoted = head.filter { tables.contains(rowID($0)) }
        return (kept + demoted + Array(rows[depth...]), tables)
    }

    /// Le texte indexé de plusieurs pages, par ROWID : accès direct à la table
    /// de contenu de `page_fts`, sans MATCH ni balayage. Mesuré le 11/09/2026
    /// sur une copie de la base de production, 50 pages (139 000 caractères) :
    /// 0,2 ms à chaud, 13 ms à la première lecture.
    private func pageBodies(rowIDs: [Int64]) throws -> [Int64: String] {
        guard !rowIDs.isEmpty else { return [:] }
        let list = rowIDs.map(String.init).joined(separator: ",")
        return try read { db in
            var out: [Int64: String] = [:]
            for row in try Row.fetchAll(
                db, sql: "SELECT rowid AS rid, body FROM page_fts WHERE rowid IN (\(list))") {
                out[row["rid"] as Int64] = row["body"] as String
            }
            return out
        }
    }

    // MARK: - Canal des noms de fichier (PR-02)

    /// Les documents dont le NOM porte tous les mots de la requête, au plus
    /// `limit`.
    ///
    /// POURQUOI UN CANAL, ALORS QUE `docs_fts` ÉTAIT DÉJÀ LUE. Elle ne servait
    /// que de BONUS de classement (la CTE `dn`, à partir de deux mots) : un
    /// document dont SEUL le nom répond ne pouvait pas entrer dans le jeu de
    /// résultats. Mesuré le 09/09/2026 sur la base de production : `fouine
    /// search IP2022` rendait sept pages sans rapport alors que trois fichiers
    /// s'appellent `IP2022__Analyse_JB_LIVRABLE_…` — le serveur MCP les
    /// trouvait par `path_contains`, l'utilisateur non (PR-02). C'est le
    /// premier réflexe de quiconque vient du Finder ou de Spotlight.
    ///
    /// UNE REQUÊTE À PART, et courte : `docs_fts` fait une ligne par document
    /// (1 527 en production), le MATCH sort de son index et la jointure sur
    /// `docs` est une sonde de clé primaire. Elle ne touche NI le classement
    /// des pages, ni les totaux.
    ///
    /// Les filtres de DOSSIER et d'EXTENSION s'appliquent — ce sont les deux que
    /// la syntaxe de requête sait poser, et un nom qui répond hors du dossier
    /// demandé serait un résultat que la requête a exclu. Les mots partent avec
    /// leurs formes morphologiques, comme la sonde `dn` : `docs_fts` est
    /// tokenisée `unicode61 remove_diacritics 2`, l'accent n'y compte donc pas.
    ///
    /// TROIS CARACTÈRES AU MOINS pour l'un des mots : sur deux lettres, le nom
    /// de fichier répond presque toujours, et le bandeau deviendrait du bruit.
    public func documentsMatchingName(_ q: SearchQuery,
                                      limit: Int = 5) throws -> [DocumentListing] {
        // `texte:` éteint le bandeau (lot QP1) : la requête a dit qu'elle ne
        // voulait pas du nom du fichier.
        guard q.nameBoost, !q.terms.isEmpty, limit > 0,
              q.terms.contains(where: { $0.count >= 3 }) else { return [] }
        let forms = Self.termForms(q)
        var match = forms.map { list in
            list.count == 1 ? QueryParser.quote(list[0])
                : "(" + list.map(QueryParser.quote).joined(separator: " OR ") + ")"
        }.joined(separator: " AND ")
        // `nom:` restreint le bandeau comme il restreint les pages.
        if let names = Self.nameMatchExpression(q) { match += " AND " + names }

        var clauses = ""
        var args: [(any DatabaseValueConvertible)?] = [match]
        if !q.folders.isEmpty {
            clauses += " AND d.top_folder IN (\(placeholders(q.folders.count)))"
            args.append(contentsOf: q.folders.map { $0 as (any DatabaseValueConvertible)? })
        }
        if !q.exts.isEmpty {
            clauses += " AND d.ext IN (\(placeholders(q.exts.count)))"
            args.append(contentsOf: q.exts.map {
                $0.lowercased() as (any DatabaseValueConvertible)? })
        }
        if !q.inDocIDs.isEmpty {
            clauses += " AND d.id IN (\(placeholders(q.inDocIDs.count)))"
            args.append(contentsOf: q.inDocIDs.map { $0 as (any DatabaseValueConvertible)? })
        }
        // LANGUE ET DATE (lot MC2, constat PM-26). Le bandeau les ignorait : un
        // `lang: "fr"` ou un `--since` rendait des documents que la requête
        // avait exclus, et rien ne le disait. Mêmes clauses que
        // `nameCandidates`, sur la même table.
        if !q.langs.isEmpty {
            clauses += " AND \(Self.languageSQL("d.lang")) IN (\(placeholders(q.langs.count)))"
            args.append(contentsOf: q.langs.map {
                $0.lowercased() as (any DatabaseValueConvertible)? })
        }
        if let after = q.modifiedAfter {
            clauses += " AND d.mtime >= ?"
            args.append(after)
        }
        // PROVENANCE (constat PM-26, le cas mesuré). `source: "transcript"`
        // rendait cinq `.pdf` dans une réponse dont l'appelant avait demandé
        // qu'elle ne porte que des transcriptions. Un nom de fichier ne
        // désigne aucune page — c'est vrai — mais un document qui n'a AUCUNE
        // page de la provenance demandée n'a rien à faire là : `EXISTS` sur
        // `page_src`, sonde sur la clé primaire `(doc_id, page)`.
        if !q.keepsAllSources, let sources = q.sources {
            let values = sources.map(\.rawValue).sorted()
                .map(String.init).joined(separator: ",")
            clauses += " AND EXISTS (SELECT 1 FROM page_src ps WHERE ps.doc_id = d.id"
                + " AND ps.src IN (\(values)))"
        }
        // Chemin et exclusions (lot MC1) : le bandeau obéit aux mêmes filtres
        // que les pages — un document que la requête écarte n'a pas à
        // reparaître sous prétexte que son nom répond.
        let added = Self.pathAndExcludeClauses(q, alias: "d")
        for clause in added.clauses { clauses += " AND " + clause }
        args.append(contentsOf: added.args)
        if let excluded = Self.nameExcludeExpression(q) {
            clauses += " AND d.id NOT IN (SELECT rowid FROM docs_fts WHERE docs_fts MATCH ?)"
            args.append(excluded)
        }
        // QUATRE FOIS la place demandée : le tamis ci-dessous écarte les lignes
        // que seul le dossier parent faisait répondre, et un `LIMIT 5` brut
        // aurait laissé un dossier bavard manger les cinq places.
        args.append(limit * 4)
        return try read { db in
            try Row.fetchAll(db, sql: """
                SELECT d.id, d.vol_uuid, d.rel_path, d.ext, d.top_folder,
                       d.n_pages, d.mtime, d.state, d.err
                FROM docs_fts f JOIN docs d ON d.id = f.rowid
                WHERE docs_fts MATCH ?\(clauses)
                ORDER BY d.mtime DESC, d.id ASC
                LIMIT ?
                """, arguments: StatementArguments(args))
                .map { row in
                    DocumentListing(
                        id: row["id"], volUUID: row["vol_uuid"],
                        relPath: row["rel_path"], ext: row["ext"],
                        topFolder: row["top_folder"], nPages: row["n_pages"],
                        mtime: row["mtime"],
                        state: DocState(rawValue: row["state"]) ?? .discovered,
                        err: row["err"])
                }
                .filter { Self.nameCarries(forms, in: $0.relPath) }
                .prefix(limit)
                .map { $0 }
        }
    }

    /// Le NOM DU FICHIER porte-t-il une forme de chaque mot ?
    ///
    /// POURQUOI CE SECOND TAMIS. `docs_fts` indexe le nom du fichier **et celui
    /// de son dossier parent** (`Schema.documentIndexName`) : c'est ce qui fait
    /// la valeur du bonus de classement `dn`, mais cela rendrait le bandeau
    /// FAUX — « 5 documents dont le nom contient “cours” » pour cinq fichiers
    /// rangés dans un dossier « Cours » et nommés autrement. Le MATCH reste le
    /// prélude rapide (il sort de l'index et ignore les accents) ; ce tamis
    /// garde ce que la phrase promet, sur le nom seul, extension retirée.
    static func nameCarries(_ forms: [[String]], in relPath: String) -> Bool {
        let base = Morphology.fold(
            ((relPath as NSString).lastPathComponent as NSString)
                .deletingPathExtension)
        return forms.allSatisfy { list in
            list.contains { base.contains(Morphology.fold($0)) }
        }
    }

    // MARK: - `nom:` : chercher dans les noms seulement (lot QP1)

    /// La requête ne porte-t-elle QUE des `nom:` ou des `chemin:` ? Alors il
    /// n'y a aucune page à chercher, et ce sont les documents qui sortent.
    ///
    /// `chemin:Offres` seul suit exactement le chemin de `nom:rapport` seul
    /// (lot MC1) : même liste de documents, même première page porteuse de
    /// texte, mêmes totaux. Seul l'ordre change faute de `bm25(docs_fts)` —
    /// un chemin ne se classe pas par pertinence, il se lit du plus récent.
    static func searchesNamesOnly(_ q: SearchQuery) -> Bool {
        (!q.nameTerms.isEmpty || !q.pathContains.isEmpty)
            && q.fts.trimmingCharacters(in: .whitespaces).isEmpty
    }

    /// Les clauses des filtres de DOCUMENT ajoutés par le lot MC1 — `chemin:`
    /// et les exclusions de dossier, d'extension et de chemin —, sur `docs`
    /// sous l'alias donné (`""` dans une sous-requête `SELECT id FROM docs`).
    ///
    /// VIDES quand la requête n'en porte aucun : c'est ce qui garantit que le
    /// SQL reste celui d'avant le lot, au caractère près.
    ///
    /// `instr(fold(rel_path), fold(?)) > 0` : la colonne n'est indexée nulle
    /// part, le balayage porte sur `docs` (1 883 lignes en production) et non
    /// sur les 434 372 pages. Mesuré sur une copie : +2 ms sur `energie`.
    static func pathAndExcludeClauses(_ q: SearchQuery, alias: String)
        -> (clauses: [String], args: [(any DatabaseValueConvertible)?]) {
        var clauses: [String] = []
        var args: [(any DatabaseValueConvertible)?] = []
        let column = alias.isEmpty ? "" : alias + "."
        for needle in q.pathContains {
            clauses.append("instr(fold(\(column)rel_path), fold(?)) > 0")
            args.append(needle)
        }
        for needle in q.pathExcludes {
            clauses.append("instr(fold(\(column)rel_path), fold(?)) = 0")
            args.append(needle)
        }
        if !q.folderExcludes.isEmpty {
            clauses.append("\(column)top_folder NOT IN (\(marks(q.folderExcludes.count)))")
            args.append(contentsOf: q.folderExcludes.map {
                $0 as (any DatabaseValueConvertible)? })
        }
        if !q.extExcludes.isEmpty {
            clauses.append("\(column)ext NOT IN (\(marks(q.extExcludes.count)))")
            args.append(contentsOf: q.extExcludes.map {
                $0.lowercased() as (any DatabaseValueConvertible)? })
        }
        return (clauses, args)
    }

    /// L'expression MATCH de `docs_fts` des `-nom:` de la requête, ou `nil`.
    /// Plusieurs exclusions se cumulent en OR : un document qui répond à l'une
    /// d'elles est écarté, comme `-a -b` écarte qui porte l'un des deux mots.
    static func nameExcludeExpression(_ q: SearchQuery) -> String? {
        guard !q.nameExcludes.isEmpty else { return nil }
        return q.nameExcludes.map(QueryParser.quote).joined(separator: " OR ")
    }

    /// L'expression MATCH de `docs_fts` pour les `nom:` de la requête, ou `nil`.
    ///
    /// Chaque valeur est exigée (ET) ; un mot part avec ses formes
    /// morphologiques, comme dans le canal des noms — `nom:rapport` trouve
    /// « Rapports 2024 ». Une valeur à espace (`nom:"analyse JB"`) est une
    /// PHRASE : le tokenizer coupe aussi aux `_` et aux `-`, elle trouve donc
    /// `IP2022__Analyse_JB_LIVRABLE`. Tout part entre guillemets : un nom de
    /// fichier est plein de ponctuation que FTS5 lirait comme de la syntaxe.
    static func nameMatchExpression(_ q: SearchQuery) -> String? {
        guard !q.nameTerms.isEmpty else { return nil }
        let words = q.nameTerms.filter { !$0.contains(where: \.isWhitespace) }
        return q.nameTerms.map { value -> String in
            guard !value.contains(where: \.isWhitespace) else {
                return QueryParser.quote(value)
            }
            let forms = q.morphology
                ? Morphology.forms(of: value, among: words) : [Morphology.fold(value)]
            guard forms.count > 1 else { return QueryParser.quote(forms.first ?? value) }
            return "(" + forms.map(QueryParser.quote).joined(separator: " OR ") + ")"
        }.joined(separator: " AND ")
    }

    /// Le ROWID de la première page du document `docID` qui porte du texte
    /// indexé — et qui passe le filtre de provenance, s'il y en a un. Une
    /// sonde de plage sur `page_fts` (§4.1 : rowid = doc_id·100000 + page),
    /// sans MATCH : c'est la page qu'ouvre un résultat trouvé par son nom.
    private static func firstTextRowIDSQL(_ q: SearchQuery, docID: String) -> String {
        let source = sourceFilter(q, docID: "(t.rowid / \(Schema.pagesPerDocLimit))",
                                  page: "(t.rowid % \(Schema.pagesPerDocLimit))")
        return """
            (SELECT t.rowid FROM page_fts t\(source.join) \
            WHERE t.rowid BETWEEN \(docID) * \(Schema.pagesPerDocLimit) + 1 \
            AND \(docID) * \(Schema.pagesPerDocLimit) + \(Schema.pagesPerDocLimit - 1)\
            \(source.sql) ORDER BY t.rowid LIMIT 1)
            """
    }

    /// `FROM … WHERE …` des documents dont le nom répond, filtres de document
    /// et exclusions compris (`d` = `docs`). Le même jeu pour les résultats,
    /// les totaux et les facettes.
    private func nameCandidates(_ q: SearchQuery, match: String?,
                                negative: String?)
        -> (sql: String, args: [(any DatabaseValueConvertible)?]) {
        // SANS `nom:` (lot MC1) : `chemin:Offres` seul n'a pas d'expression
        // MATCH, et la jointure sur `docs_fts` n'aurait rien à quoi s'appliquer
        // — on part de `docs` directement. `WHERE 1` plutôt qu'une gymnastique
        // de conjonction : les clauses qui suivent s'écrivent toutes « AND … ».
        var sql = match == nil
            ? "FROM docs d WHERE 1"
            : "FROM docs_fts JOIN docs d ON d.id = docs_fts.rowid WHERE docs_fts MATCH ?"
        var args: [(any DatabaseValueConvertible)?] = match.map { [$0] } ?? []
        if !q.folders.isEmpty {
            sql += " AND d.top_folder IN (\(placeholders(q.folders.count)))"
            args.append(contentsOf: q.folders.map { $0 as (any DatabaseValueConvertible)? })
        }
        if !q.exts.isEmpty {
            sql += " AND d.ext IN (\(placeholders(q.exts.count)))"
            args.append(contentsOf: q.exts.map {
                $0.lowercased() as (any DatabaseValueConvertible)? })
        }
        if !q.langs.isEmpty {
            sql += " AND \(Self.languageSQL("d.lang")) IN (\(placeholders(q.langs.count)))"
            args.append(contentsOf: q.langs.map {
                $0.lowercased() as (any DatabaseValueConvertible)? })
        }
        if let after = q.modifiedAfter {
            sql += " AND d.mtime >= ?"
            args.append(after)
        }
        if !q.inDocIDs.isEmpty {
            sql += " AND d.id IN (\(placeholders(q.inDocIDs.count)))"
            args.append(contentsOf: q.inDocIDs.map { $0 as (any DatabaseValueConvertible)? })
        }
        let added = Self.pathAndExcludeClauses(q, alias: "d")
        for clause in added.clauses { sql += " AND " + clause }
        args.append(contentsOf: added.args)
        if let excluded = Self.nameExcludeExpression(q) {
            sql += " AND d.id NOT IN (SELECT rowid FROM docs_fts WHERE docs_fts MATCH ?)"
            args.append(excluded)
        }
        if let negative, !negative.trimmingCharacters(in: .whitespaces).isEmpty {
            sql += " AND d.id NOT IN (SELECT \(Self.ftsDocIDExpr) FROM page_fts WHERE page_fts MATCH ?)"
            args.append(negative)
        }
        return (sql, args)
    }

    /// Les documents dont le nom répond à tous les `nom:`, une ligne par
    /// document : sa première page porteuse de texte (ou 1), l'extrait est le
    /// nom du fichier, les totaux comptent des DOCUMENTS (pages = documents).
    /// Ordre : pertinence `bm25` de `docs_fts`, puis le plus récent.
    ///
    /// La première page n'est lue que pour la TRANCHE rendue quand aucun filtre
    /// de provenance n'est posé ; avec un filtre, elle décide de qui entre —
    /// un document sans aucune page scannée ne répond pas à « pages scannées
    /// seulement » — et se lit pour chaque candidat (`docs_fts` fait une ligne
    /// par document, 1 527 en production).
    private func documentsByName(_ q: SearchQuery,
                                 excludingDocsMatching negative: String?) throws
        -> SearchResults {
        let start = DispatchTime.now().uptimeNanoseconds
        let match = Self.nameMatchExpression(q)
        guard match != nil || !q.pathContains.isEmpty else {
            return SearchResults(hits: [], totalPages: 0, totalDocs: 0, elapsedMS: 0)
        }
        let negativeFTS = negative.map { Self.effectiveFTS($0, morphology: q.morphology) }
        let candidates = nameCandidates(q, match: match, negative: negativeFTS)
        // QUALIFIÉ : `page_fts` porte elle aussi une colonne `doc_id`, et un
        // `doc_id` nu dans la sous-requête désignerait la sienne, sans erreur.
        let firstOfSlice = Self.firstTextRowIDSQL(q, docID: "s.doc_id")
        let firstOfAll = Self.firstTextRowIDSQL(q, docID: "n.doc_id")
        let order = "ORDER BY r ASC, mtime DESC, doc_id"
        let (total, rows) = try read { db -> (Int, [Row]) in
            // Sans `nom:`, il n'y a pas de pertinence à lire : `r` vaut 0 pour
            // tout le monde et l'ordre se joue sur `mtime` (lot MC1).
            let rank = match == nil ? "0.0" : "bm25(docs_fts)"
            let base = """
                WITH n AS MATERIALIZED (
                  SELECT d.id AS doc_id, d.mtime AS mtime, \(rank) AS r
                  \(candidates.sql)
                )
                """
            if q.keepsAllSources {
                let total = try Int.fetchOne(
                    db, sql: base + "\nSELECT count(*) FROM n",
                    arguments: StatementArguments(candidates.args)) ?? 0
                let rows = try Row.fetchAll(db, sql: base + """
                    ,
                    s AS MATERIALIZED (SELECT doc_id, mtime, r FROM n \(order) LIMIT ? OFFSET ?)
                    SELECT doc_id, r, \(firstOfSlice) AS rid FROM s \(order)
                    """, arguments: StatementArguments(candidates.args + [q.limit, q.offset]))
                return (total, rows)
            }
            let kept = base + """
                ,
                s AS MATERIALIZED (SELECT doc_id, mtime, r, \(firstOfAll) AS rid FROM n)
                """
            let total = try Int.fetchOne(
                db, sql: kept + "\nSELECT count(*) FROM s WHERE rid IS NOT NULL",
                arguments: StatementArguments(candidates.args)) ?? 0
            let rows = try Row.fetchAll(db, sql: kept + """

                SELECT doc_id, r, rid FROM s WHERE rid IS NOT NULL \(order) LIMIT ? OFFSET ?
                """, arguments: StatementArguments(candidates.args + [q.limit, q.offset]))
            return (total, rows)
        }
        let keys = rows.map { row -> (docID: Int64, page: Int) in
            let rid: Int64? = row["rid"]
            return (row["doc_id"] as Int64,
                    rid.map { Int($0 % Schema.pagesPerDocLimit) } ?? 1)
        }
        let meta = try pageMeta(for: keys)
        let paths = try relPaths(for: keys.map(\.docID))
        let hits = zip(rows, keys).map { row, key -> Hit in
            let path = paths[key.docID] ?? ""
            return Hit(docID: key.docID, path: path, page: key.page, score: row["r"],
                       snippet: (path as NSString).lastPathComponent,
                       source: meta[Schema.ftsRowID(docID: key.docID, page: key.page)]?.source
                           ?? .native,
                       fuzzyDistance: 0)
        }
        return SearchResults(
            hits: hits, totalPages: total, totalDocs: total,
            elapsedMS: Double(DispatchTime.now().uptimeNanoseconds - start) / 1_000_000)
    }

    /// Les documents que les `nom:` laissent passer, pour le canal VECTORIEL de
    /// l'hybride, qui ne connaît des filtres que l'ensemble de documents
    /// autorisés (même rôle que `docIDsMatching(langs:modifiedAfter:)`) ; `nil`
    /// quand la requête n'en porte aucun.
    /// (lot MC1) Le nom N'EST PLUS SEUL : `chemin:`, `-nom:`, `-chemin:`,
    /// `-dossier:` et `-ext:` restreignent eux aussi l'ensemble autorisé. Le
    /// canal vectoriel ne connaît des filtres que cet ensemble, et
    /// `HybridSearch` — qui appelle déjà cette fonction avec la requête
    /// entière — les applique donc sans changer de site d'appel. La fonction
    /// GARDE son nom : la renommer toucherait `FouineEmbed`, hors de ce lot.
    public func docIDsMatchingName(_ q: SearchQuery) throws -> Set<Int64>? {
        let match = Self.nameMatchExpression(q)
        let excluded = Self.nameExcludeExpression(q)
        let added = Self.pathAndExcludeClauses(q, alias: "")
        guard match != nil || excluded != nil || !added.clauses.isEmpty else {
            return nil
        }
        return try read { db in
            var allowed: Set<Int64>?
            if let match {
                allowed = Set(try Int64.fetchAll(
                    db, sql: "SELECT rowid FROM docs_fts WHERE docs_fts MATCH ?",
                    arguments: [match]))
            }
            if !added.clauses.isEmpty {
                let rows = Set(try Int64.fetchAll(
                    db, sql: "SELECT id FROM docs WHERE "
                        + added.clauses.joined(separator: " AND "),
                    arguments: StatementArguments(added.args)))
                allowed = allowed.map { $0.intersection(rows) } ?? rows
            }
            if let excluded {
                let out = try Int64.fetchAll(
                    db, sql: "SELECT rowid FROM docs_fts WHERE docs_fts MATCH ?",
                    arguments: [excluded])
                if allowed == nil {
                    allowed = Set(try Int64.fetchAll(db, sql: "SELECT id FROM docs"))
                }
                allowed?.subtract(out)
            }
            return allowed
        }
    }

    // MARK: - Les mots de la requête qui EXISTENT dans l'index (lot MC1)

    /// Ceux des mots tapés qu'au moins une page porte, dans l'ordre de la
    /// requête — les filtres de la requête appliqués.
    ///
    /// POURQUOI. « none of your words is in your documents » (`SearchAdvice`)
    /// se déclenchait sur le seul `lexTotalPages == 0`, c'est-à-dire sur
    /// « aucune page ne les porte TOUS ». Mesuré le 13/09/2026 sur la base de
    /// production : `dossier:Livres distribution des temps de séjour dans un
    /// réacteur réel` rendait cette phrase alors que « réacteur » est dans 22
    /// documents de `Livres` — la surface affirmait le contraire de ce que
    /// l'index contient, et l'utilisateur en concluait que son corpus était
    /// muet. Un `EXISTS` par mot, borné à la première ligne appariée : quelques
    /// millisecondes, et seulement quand la phrase va être dite.
    ///
    /// LES MOTS PORTEURS SEULEMENT, ceux que le quorum compte : « de », « un »,
    /// « des », « dans » sont dans tous les documents, et les citer noyait les
    /// deux mots qui apprennent quelque chose (mesuré : la phrase énumérait les
    /// neuf mots de la question). Une requête qui n'en porte aucun rend une
    /// liste vide, et l'ancienne phrase — plus générale — reprend la main.
    public func wordsPresent(_ q: SearchQuery,
                             excludingDocsMatching negative: String? = nil) throws
        -> [String] {
        let terms = q.terms.filter {
            $0.count >= QueryParser.quorumMinimumWordLength
                && !QueryParser.quorumStopwords.contains(Morphology.fold($0))
        }
        guard !terms.isEmpty else { return [] }
        let morphology = Self.morphologyApplies(q)
        let negativeFTS = negative.map { Self.effectiveFTS($0, morphology: morphology) }
        let filter = docFilter(q, column: Self.ftsDocIDExpr,
                               page: Self.ftsPageExpr, negative: negativeFTS)
        var out: [String] = []
        var seen = Set<String>()
        try read { db in
            for term in terms where seen.insert(Morphology.fold(term)).inserted {
                let match = Self.effectiveFTS(QueryParser.escapeBare(term),
                                              morphology: morphology)
                let found = try Bool.fetchOne(db, sql: """
                    SELECT EXISTS(
                      SELECT 1 FROM page_fts\(filter.join)
                      WHERE page_fts MATCH ?\(filter.sql)
                    )
                    """, arguments: StatementArguments([match] + filter.args)) ?? false
                if found { out.append(term) }
            }
        }
        return out
    }

    /// Totaux seuls, pour la page vide (voir l'appelant).
    private func fuzzyTotals(_ plan: FuzzyPlan,
                             threshold: Int = Schema.approximateCountThreshold) throws -> (pages: Int, docs: Int, approximate: Bool) {
        try read { db in
            let row = try Row.fetchOne(db, sql: """
                \(plan.prelude)
                SELECT count(*) AS pages, count(DISTINCT doc_id) AS docs
                FROM (
                  SELECT doc_id, page FROM u GROUP BY doc_id, page
                  LIMIT ?
                )
                """, arguments: StatementArguments(plan.args + [threshold + 1]))
            let p = (row?["pages"] as Int?) ?? 0
            let d = (row?["docs"] as Int?) ?? 0
            if p > threshold {
                return (threshold, min(d, threshold), true)
            } else {
                return (p, d, false)
            }
        }
    }

    /// Chemin exact du §4.1 : la CTE de base `m` (doc_id, page, r, fz = 0) sur
    /// page_fts, puis les couches de classement, puis la tranche. L'extrait
    /// n'est PAS calculé ici : `snippet()` dans la sous-requête triée était
    /// évalué pour chaque page appariée, pas pour les cinquante rendues.
    private func exactRows(fts: String, filter: Filter, q: SearchQuery,
                           probes: RankingProbes?, diversity: Bool) throws -> [Row] {
        let layers = Self.rankingLayers(base: "m", probes: probes, diversity: diversity)
        let probeCTEs = Self.probeCTEs(probes)
        // `WITH` vient des sondes quand il y en a ; sinon il faut l'ouvrir ici.
        let opening = probeCTEs.isEmpty ? "WITH " : probeCTEs + ", "
        // Typés et sortis de l'appel, comme dans `searchOnce` : 1,9 s de
        // type-checking de moins (lot BT1).
        let args: [(any DatabaseValueConvertible)?] =
            Self.probeArgs(probes) + [fts] + filter.args + [q.limit, q.offset]
        return try read { db in
            try Row.fetchAll(db, sql: """
                \(opening)m AS (
                  SELECT \(Self.ftsDocIDExpr) AS doc_id, \(Self.ftsPageExpr) AS page,
                         bm25(page_fts) AS r, 0 AS fz
                  FROM page_fts\(filter.join)
                  WHERE page_fts MATCH ?\(filter.sql)
                )\(layers.ctes)
                SELECT doc_id, page, fz, \(layers.score) AS r
                FROM \(layers.source)
                ORDER BY r ASC, fz ASC, doc_id, page
                LIMIT ? OFFSET ?
                """,
                arguments: StatementArguments(args))
        }
    }

    // MARK: - Couches de classement (bonus M1, diversité R1)

    /// Les couches SQL posées sur une CTE `base` qui rend (doc_id, page, r, fz).
    ///
    /// - `gb` : les bonus (lots M1 et P1), un facteur sur `r` (voir
    ///   `boostedScore`).
    /// - `dv` : la DIVERSITÉ par document. `row_number()` numérote les pages de
    ///   chaque document dans l'ordre de leur score ; le score final rétrograde
    ///   celles qui dépassent `Schema.diversityFullStrengthPages`. C'est une
    ///   fonction fenêtre sur le jeu apparié tout entier — d'où le garde-fou de
    ///   `diversifies` au-delà du seuil de comptage approché.
    ///
    /// Rend les CTE à concaténer (chacune précédée d'une virgule), le nom de la
    /// source finale et l'expression du score final. `r` reste NÉGATIF de bout
    /// en bout : le tri est toujours `ORDER BY r ASC`.
    static func rankingLayers(base: String, probes: RankingProbes?, diversity: Bool)
        -> (ctes: String, source: String, score: String) {
        var ctes = ""
        var source = base
        if let probes {
            let boosted = boostedScore("r", probes: probes,
                                       rowID: "(doc_id * \(Schema.pagesPerDocLimit) + page)",
                                       docID: "doc_id")
            // MATERIALIZED : sans lui, la fenêtre de `dv` réévalue `r` — et
            // donc les sondes `IN (SELECT …)` — dans son ORDER BY, et SQLite
            // rebâtit les tables éphémères des sondes une seconde fois.
            // Mesuré sur la base réelle (`free energy`, 19 205 pages) : la
            // diversité coûtait +88 ms avec les bonus contre +39 ms sans ;
            // matérialisé, le bonus n'est plus payé qu'une fois par page.
            ctes += """
                ,
                gb AS MATERIALIZED (SELECT doc_id, page, fz, \(boosted) AS r FROM \(source))
                """
            source = "gb"
        }
        guard diversity else { return (ctes, source, "r") }
        ctes += """
            ,
            dv AS (SELECT doc_id, page, fz, r,
                          row_number() OVER (PARTITION BY doc_id ORDER BY r, fz, page) AS k
                   FROM \(source))
            """
        let score = "CASE WHEN k <= \(Schema.diversityFullStrengthPages) THEN r "
            + "ELSE r * \(Schema.diversityDemotion) END"
        return (ctes, "dv", score)
    }

    /// La diversité s'applique-t-elle à cette requête ?
    ///
    /// Non au-delà du seuil de comptage approché — même raison que les sondes :
    /// une fonction fenêtre sur 176 000 pages coûterait des centaines de
    /// millisecondes pour un ordre que personne ne saurait départager
    /// (mesuré sur `the`, 351 907 pages : 382 ms sans, 889 ms avec). Non plus
    /// quand la recherche est restreinte à UN document (« Rechercher dans ce
    /// document… ») : il n'y a rien à diversifier, et rétrograder ses pages
    /// n'aurait fait que brouiller leur pourcentage de pertinence.
    static func diversifies(_ q: SearchQuery, matchedPages: Int) -> Bool {
        q.diversifyDocuments
            && matchedPages < q.approximateThreshold
            && q.inDocIDs.count != 1
    }

    // MARK: - Bonus de classement (lot M1 : D-R2 proximité, D-R3 nom)

    /// Les sondes d'une requête. Toutes bâties sur les termes EXACTS et
    /// leurs formes morphologiques — jamais sur les variantes floues : une page
    /// trouvée par « thermodynamlque » ne doit pas toucher le bonus de
    /// « thermodynamique », elle est déjà pénalisée par le `1/(1+d)` de sa
    /// branche (T13).
    struct RankingProbes: Equatable {
        /// `"t1 t2 … tn"` (et ses formes) — nil quand la requête n'a qu'un mot nu.
        let phrase: String?
        /// `NEAR(t1 t2 … tn, 12)` (et ses formes) — nil pour la même raison.
        let near: String?
        /// `t1 OR t2 OR … tn` et leurs formes, sur `docs_fts` — nil pour la
        /// même raison (le bonus de nom n'agit qu'à partir de deux mots).
        let name: String?
        /// `"t1" AND … AND "tn"` : les mots TELS QU'ILS ONT ÉTÉ TAPÉS, repliés,
        /// sans aucune de leurs formes (lot P1). nil quand la morphologie n'a
        /// rien ajouté — la sonde serait alors l'ensemble des résultats.
        let typedForm: String?
    }

    /// Nombre maximal de combinaisons de formes qu'une sonde de phrase ou de
    /// voisinage accepte d'énumérer (`"polymere reticule" OR "polymeres
    /// reticule" OR …`). Au-delà, la sonde ne porte que les formes tapées :
    /// FTS5 n'accepte pas de `OR` à l'intérieur d'une phrase ni d'un NEAR.
    /// 27 = trois mots à trois formes chacun (`metal reseau` en a 3 × 3 = 9 :
    /// à 8, la sonde ne portait que les formes tapées, et le bonus « expression
    /// au pluriel » dépendait du nombre de règles qui avaient tiré, pas de la
    /// requête — AUDIT-R1 M3). Une phrase dont un mot n'existe pas a une liste
    /// de positions vide : les combinaisons fantômes ne coûtent rien.
    static let probeFormCombinationsCap = 27

    /// Les sondes applicables à cette requête, ou `nil` si elle n'y a pas droit.
    ///
    /// GARDE-FOUS (annexe D du 01/09/2026, confirmés par le code). Aucune sonde
    /// si la requête porte DÉJÀ une phrase `"…"`, un `NEAR`/`pres:`, un préfixe
    /// `*` ou un `OR` : l'utilisateur a dit lui-même ce qu'il cherchait, et une
    /// phrase fabriquée à partir d'une telle chaîne ne voudrait rien dire.
    /// Tous ces cas se lisent sur `q.fts`, qui est la chaîne FTS5 EXACTE (les
    /// variantes floues n'y sont pas encore) : un guillemet, une parenthèse
    /// (seul `NEAR(…)` en produit) ou une étoile suffisent à sortir.
    ///
    /// `isSubstitutable` est réutilisé tel quel : c'est déjà le juge de « ce mot
    /// est-il un mot NU dans cette chaîne », et une seconde implémentation de
    /// la grammaire finirait par diverger.
    ///
    /// `matchedPages` : ce que la requête EXACTE apparie, déjà compté par
    /// `counts()`. Au-delà du seuil de comptage approché, les sondes sont
    /// désarmées — voir le garde-fou de coût ci-dessous.
    ///
    /// La sonde « forme tapée » (lot P1) partage tous ces garde-fous mais pas
    /// la règle des deux mots : voir plus bas.
    static func rankingProbes(for q: SearchQuery,
                              matchedPages: Int = 0) -> RankingProbes? {
        guard q.rankingBoosts || q.typedFormBoost, !q.terms.isEmpty else { return nil }
        // GARDE-FOU DE COÛT (mesuré le 05/09/2026 sur la base réelle). Une
        // sonde de phrase sur deux mots-outils — `the of`, 176 000 pages —
        // parcourt des listes de positions gigantesques : 1,3 s de recherche
        // devenaient 2,9 s. Au-delà du seuil au-delà duquel les comptages
        // eux-mêmes cessent d'être exacts (`approximateThreshold`), on ne
        // paie donc plus les sondes : à ce nombre de pages appariées,
        // l'ordre des dix premières n'est de toute façon plus un choix
        // qu'un humain saurait départager. Sous le seuil, le surcoût mesuré
        // est de +0,8 ms en médiane et de +28 ms au pire (6 731 pages).
        // Strictement INFÉRIEUR : `counts()` borne son résultat au seuil, si
        // bien qu'une valeur ÉGALE au seuil signifie « au moins autant, on a
        // arrêté de compter » — c'est exactement le cas qu'on écarte.
        guard matchedPages < q.approximateThreshold else { return nil }
        let fts = q.fts
        guard !fts.contains("\""), !fts.contains("*"),
              !fts.contains("("), !fts.contains(")"),
              !fts.contains(" OR ") else { return nil }
        let terms = q.terms
        guard terms.allSatisfy({ isSubstitutable($0, in: fts) }) else { return nil }

        // Les formes de chaque mot (lot R1) : la forme TAPÉE en tête, puis
        // celles que la morphologie a ajoutées. Une seule et même table pour
        // les quatre sondes — elles doivent décliner de la même façon.
        let forms = termForms(q)

        // SONDE « FORME TAPÉE PRÉSENTE » (lot P1, PERSPECTIVES § 3 Q1). La
        // morphologie change ce qui est TROUVÉ : une page qui ne porte que
        // « entropies » répond à `entropie`, et rien ne la distinguait plus
        // d'une page qui porte le mot tel qu'il a été tapé. Mesuré par l'audit
        // AUDIT-R1 (I2) sur la base réelle : les dix premières pages portaient
        // bien le mot tapé, mais entre les rangs 11 et 50, 22 pages sur 50 de
        // `entropie` et 24 de `hypothese` ne portaient QUE l'autre forme.
        //
        // La sonde n'est émise QUE si la morphologie a effectivement ajouté une
        // forme à au moins un mot : sinon elle serait vraie pour tout le jeu de
        // résultats — un facteur constant, qui ne classe rien et coûte une
        // exécution FTS de plus.
        //
        // DÈS UN MOT, contrairement aux trois autres : c'est un bonus par PAGE,
        // et le débordement mesuré sur le bonus de NOM à un mot (tout l'écran
        // pris par le seul livre dont le titre portait le mot) vient de ce que
        // ce bonus-là vaut pour toutes les pages d'un document à la fois.
        //
        // Les mots partent REPLIÉS et entre guillemets : repliés parce que
        // c'est ce que le tokenizer indexe (`Morphology.fold`), entre
        // guillemets pour qu'un mot qui ressemble à un opérateur FTS5 reste un
        // mot. Le même ET que la requête ; les exclusions `-terme` n'y sont
        // pas (elles ne sont pas dans `q.fts`), les préfixes et les phrases non
        // plus (les garde-fous ci-dessus ont déjà écarté ces requêtes).
        var typedForm: String?
        if q.typedFormBoost, morphologyApplies(q), forms.contains(where: { $0.count > 1 }) {
            typedForm = forms.map { QueryParser.quote($0[0]) }.joined(separator: " AND ")
        }

        // DEUX MOTS AU MOINS, pour le nom aussi. La première version accordait
        // le bonus de nom dès un mot (« polymere » devait remonter
        // « Polymeres.pdf ») ; mesuré le 05/09/2026 sur la base réelle, du
        // point de vue de l'application (les documents présents dans les 50
        // premières pages) : `polymere` → 50 pages sur 50 venaient du SEUL
        // livre dont le titre portait le mot (6 documents sans bonus, dont un
        // second livre sur les polymères que « polymères » ≠ « polymere »
        // laissait de côté) ; `thermodynamique` → 42/50 au lieu de 16/50 ;
        // `catalyse` → 37/50, trois documents disparus. Un bonus par DOCUMENT
        // sur des scores bm25 presque plats (−12,19 à −11,8 pour dix pages)
        // fait monter toutes les pages d'un gros livre d'un bloc, et l'écran
        // ne montre plus que lui. À deux mots, l'intersection FTS resserre le
        // jeu et le banc (M1.md) ne montre que des déplacements modestes.
        // Décision du propriétaire le 05/09/2026. La diversité du lot R1 rend
        // ce débordement impossible ; la règle des deux mots est conservée
        // telle quelle, elle se rejuge sur le banc.
        guard q.rankingBoosts, terms.count >= 2 else {
            return typedForm.map {
                RankingProbes(phrase: nil, near: nil, name: nil, typedForm: $0)
            }
        }

        // « polymere reticule » doit aussi reconnaître la phrase « polymères
        // réticulés ». Le produit des formes est borné ; au-delà, seules les
        // formes tapées font la phrase.
        let combinations = forms.reduce(1) { $0 * $1.count }
        let sequences: [[String]] = combinations <= probeFormCombinationsCap
            ? Self.cartesian(forms) : [forms.map { $0[0] }]
        let phrase = sequences
            .map { QueryParser.quote($0.joined(separator: " ")) }
            .joined(separator: " OR ")
        let near = sequences
            .map { "NEAR(\($0.map(QueryParser.quote).joined(separator: " ")), \(Schema.proximityWindow))" }
            .joined(separator: " OR ")
        var nameForms: [String] = []
        for list in forms { for form in list where !nameForms.contains(form) { nameForms.append(form) } }
        let name = nameForms.map(QueryParser.quote).joined(separator: " OR ")
        // `texte:` (lot QP1) : pas de CTE `dn`, et le SQL est celui d'une
        // requête sans bonus de nom — ni clause, ni argument.
        return RankingProbes(phrase: phrase, near: near, name: q.nameBoost ? name : nil,
                             typedForm: typedForm)
    }

    /// Toutes les suites qui prennent une forme dans chaque liste, dans l'ordre.
    static func cartesian(_ lists: [[String]]) -> [[String]] {
        var out: [[String]] = [[]]
        for list in lists {
            out = out.flatMap { prefix in list.map { prefix + [$0] } }
        }
        return out
    }

    /// Les CTE de sonde : `ph`, `nr` et `tf` rendent un ROWID DE PAGE, `dn` un
    /// `doc_id`. Elles ne portent AUCUN filtre de portée : elles ne servent
    /// qu'à répondre « oui / non » sur des pages que le jeu de résultats a déjà
    /// retenues, et les filtrer coûterait une seconde exécution du même MATCH.
    static func probeCTEs(_ probes: RankingProbes?,
                          leadingComma: Bool = false) -> String {
        guard let probes else { return "" }
        var parts: [String] = []
        if probes.phrase != nil {
            parts.append("ph AS (SELECT rowid AS rid FROM page_fts WHERE page_fts MATCH ?)")
        }
        if probes.near != nil {
            parts.append("nr AS (SELECT rowid AS rid FROM page_fts WHERE page_fts MATCH ?)")
        }
        if probes.name != nil {
            parts.append("dn AS (SELECT rowid AS did FROM docs_fts WHERE docs_fts MATCH ?)")
        }
        if probes.typedForm != nil {
            parts.append("tf AS (SELECT rowid AS rid FROM page_fts WHERE page_fts MATCH ?)")
        }
        let body = parts.joined(separator: ",\n")
        return leadingComma ? ",\n" + body : "WITH " + body + "\n"
    }

    /// Les arguments des CTE ci-dessus, DANS LEUR ORDRE D'APPARITION.
    static func probeArgs(_ probes: RankingProbes?) -> [(any DatabaseValueConvertible)?] {
        guard let probes else { return [] }
        var args: [(any DatabaseValueConvertible)?] = []
        if let phrase = probes.phrase { args.append(phrase) }
        if let near = probes.near { args.append(near) }
        if let name = probes.name { args.append(name) }
        if let typedForm = probes.typedForm { args.append(typedForm) }
        return args
    }

    /// `base` multiplié par
    /// `(1 + 0,8·[phrase] + 0,4·[voisinage] + 0,3·[nom] + 0,5·[forme tapée])`.
    ///
    /// `x IN (SELECT …)` et non un `LEFT JOIN` : SQLite construit l'opérande
    /// UNE FOIS dans une table éphémère indexée, puis chaque page n'est plus
    /// qu'une sonde de B-tree — là où un `LEFT JOIN` sur une CTE laisse le
    /// planificateur libre de reparcourir la sonde pour chaque page.
    static func boostedScore(_ base: String, probes: RankingProbes?,
                             rowID: String, docID: String) -> String {
        guard let probes else { return base }
        var parts = ["1.0"]
        if probes.phrase != nil {
            parts.append("\(Schema.phraseBoost) * (\(rowID) IN (SELECT rid FROM ph))")
        }
        if probes.near != nil {
            parts.append("\(Schema.nearBoost) * (\(rowID) IN (SELECT rid FROM nr))")
        }
        if probes.name != nil {
            parts.append("\(Schema.documentNameBoost) * (\(docID) IN (SELECT did FROM dn))")
        }
        if probes.typedForm != nil {
            parts.append("\(Schema.typedFormBoost) * (\(rowID) IN (SELECT rid FROM tf))")
        }
        // Le score est NÉGATIF (bm25) : un facteur > 1 l'éloigne de zéro, donc
        // fait MONTER la page dans un `ORDER BY … ASC`. Voir `Schema`.
        return "\(base) * (" + parts.joined(separator: " + ") + ")"
    }

    // MARK: - Facettes

    public func facets(_ q: SearchQuery, by key: FacetKey) throws -> [(String, Int)] {
        try facets(q, by: key, excludingDocsMatching: nil)
    }

    public func facets(_ q: SearchQuery, by key: FacetKey,
                       excludingDocsMatching negative: String?) throws -> [(String, Int)] {
        guard !q.fts.trimmingCharacters(in: .whitespaces).isEmpty
                || Self.searchesNamesOnly(q) else { return [] }
        let (prelude, args) = try groupingPrelude(q, negative: negative)

        let expression: String
        var join = ""
        switch key {
        case .folder: expression = "d.top_folder"
        case .ext:    expression = "d.ext"
        case .year:   expression = "strftime('%Y', d.mtime, 'unixepoch', 'localtime')"
        // SANS `'localtime'`, contrairement à la facette des `mtime` : la date
        // d'un document est un JOUR civil, écrit en base à midi UTC
        // (`DocumentDate`). Le fuseau de la machine n'a pas à décider qu'un
        // ouvrage de 2003 est de 2002 à Honolulu. Les documents sans date
        // ressortent sous la clé vide, que l'interface écarte comme partout
        // ailleurs.
        case .docYear:
            expression = "coalesce(strftime('%Y', d.doc_date, 'unixepoch'), '')"
        case .lang: expression = Self.languageSQL("d.lang")
        case .source:
            expression = "coalesce(s.src, 0)"
            join = "LEFT JOIN page_src s ON s.doc_id = x.doc_id AND s.page = x.page"
        }

        let rows = try read { db in
            try Row.fetchAll(db, sql: """
                \(prelude)
                SELECT \(expression) AS k, count(*) AS n
                FROM (SELECT doc_id, page FROM u GROUP BY doc_id, page) AS x
                JOIN docs d ON d.id = x.doc_id
                \(join)
                GROUP BY k ORDER BY n DESC, k
                """, arguments: StatementArguments(args))
        }
        return rows.map { row in
            if key == .source {
                let src: Int = row["k"]
                return (Self.sourceLabel(src), row["n"] as Int)
            }
            let k: String? = row["k"]
            if key == .lang {
                return (Self.languageLabel(k ?? ""), row["n"] as Int)
            }
            return (k ?? "", row["n"] as Int)
        }
    }

    // MARK: - Comptage par document (audit A12)

    /// Nombre de pages touchées PAR DOCUMENT, sur tout le jeu de résultats —
    /// pas seulement sur la tranche chargée.
    ///
    /// `DocGroup.pageCount` compte les hits reçus (200 par tranche) et
    /// l'interface les annonçait comme « pages touchées » : un document de
    /// 400 pages toutes trouvées affichait « 200 p. » (audit A12). Le comptage
    /// est bon marché — un `GROUP BY` sur le MÊME prélude que les facettes, une
    /// exécution FTS de plus par recherche, en tâche différée — et il tombe
    /// juste quel que soit l'offset.
    public func matchedPageCounts(_ q: SearchQuery,
                                  excludingDocsMatching negative: String?) throws
        -> [Int64: Int] {
        guard !q.fts.trimmingCharacters(in: .whitespaces).isEmpty else { return [:] }
        let (prelude, args) = try groupingPrelude(q, negative: negative)
        let rows = try read { db in
            try Row.fetchAll(db, sql: """
                \(prelude)
                SELECT doc_id, count(*) AS n
                FROM (SELECT doc_id, page FROM u GROUP BY doc_id, page)
                GROUP BY doc_id
                """, arguments: StatementArguments(args))
        }
        var out: [Int64: Int] = [:]
        for row in rows { out[row["doc_id"] as Int64] = row["n"] as Int }
        return out
    }

    /// Prélude `WITH u AS (…)` commun aux facettes et au comptage par document :
    /// plan flou s'il porte une vraie branche fz, sinon prélude exact SANS
    /// `bm25()` (voir le garde-fou du bogue 1 en tête de fichier). La chaîne
    /// FTS est celle de la recherche — morphologie comprise — pour que les
    /// comptes soient ceux des résultats.
    private func groupingPrelude(_ q: SearchQuery, negative: String?) throws
        -> (String, [(any DatabaseValueConvertible)?]) {
        // `nom:` seul (lot QP1) : les facettes comptent les DOCUMENTS rendus,
        // chacun sur la page qu'ouvre son résultat.
        if Self.searchesNamesOnly(q) {
            let negativeFTS = negative.map { Self.effectiveFTS($0, morphology: q.morphology) }
            let candidates = nameCandidates(q, match: Self.nameMatchExpression(q),
                                            negative: negativeFTS)
            let kept = q.keepsAllSources ? "" : " WHERE rid IS NOT NULL"
            return ("""
                WITH n AS (
                  SELECT d.id AS doc_id, \(Self.firstTextRowIDSQL(q, docID: "d.id")) AS rid
                  \(candidates.sql)
                ),
                u AS (
                  SELECT doc_id, coalesce(rid % \(Schema.pagesPerDocLimit), 1) AS page
                  FROM n\(kept)
                )
                """, candidates.args)
        }
        let fts = Self.effectiveFTS(q.fts, morphology: Self.morphologyApplies(q))
        let negativeFTS = negative.map { Self.effectiveFTS($0, morphology: Self.morphologyApplies(q)) }
        let filter = docFilter(q, column: Self.ftsDocIDExpr,
                               page: Self.ftsPageExpr, negative: negativeFTS)
        let exactTotal = try countPages(match: fts, filter: filter)
        let variants = try fuzzyVariants(for: q, exactTotal: exactTotal)
        let plan = variants.isEmpty
            ? nil : fuzzyPlan(q, variants: variants, negative: negativeFTS)
        if let plan, plan.hasFuzzyBranches {
            return (plan.prelude, plan.args)
        }
        // Sans branche floue : prélude exact SANS bm25(). L'ancien code passait
        // par le prélude flou dégénéré et ne survivait que parce que SQLite
        // élimine un bm25() jamais sélectionné — de la chance, pas une garantie
        // (recette tranche A, bogue 1).
        return ("""
            WITH u AS (
              SELECT \(Self.ftsDocIDExpr) AS doc_id,
                     \(Self.ftsPageExpr) AS page
              FROM page_fts\(filter.join)
              WHERE page_fts MATCH ?\(filter.sql)
            )
            """, [fts] + filter.args)
    }

    // MARK: - Texte indexé d'une page (aperçu, audit U4)

    /// Le texte de la page tel qu'il est EN BASE.
    ///
    /// L'aperçu des formats sans rendu par page (txt, md, html, epub, docx,
    /// rtf, djvu, et les pages OCRisées) s'en sert au lieu de retomber sur
    /// « aperçu non disponible » alors que le texte est déjà indexé (audit U4).
    /// Lecture par ROWID structuré : accès direct, sans MATCH ni balayage.
    public func pageText(docID: Int64, page: Int) throws -> String? {
        let rowid = Schema.ftsRowID(docID: docID, page: page)
        return try read { db in
            try String.fetchOne(db, sql: "SELECT body FROM page_fts WHERE rowid = ?",
                                arguments: [rowid])
        }
    }

    /// Numéros des pages d'un document qui portent du texte indexé.
    ///
    /// `docs.n_pages` compte TOUTES les pages, y compris celles qui n'ont pas
    /// de texte (page scannée pas encore OCRisée) : naviguer dessus mènerait à
    /// des pages vides. La plage de rowid est celle du document (§4.1), donc
    /// un parcours d'index borné.
    public func textPages(docID: Int64) throws -> [Int] {
        let range = Schema.ftsRowIDRange(docID: docID)
        return try read { db in
            try Int.fetchAll(db, sql: """
                SELECT \(Self.ftsPageExpr) AS page
                FROM page_fts WHERE page_fts.rowid BETWEEN ? AND ?
                ORDER BY page_fts.rowid
                """, arguments: [range.lowerBound, range.upperBound])
        }
    }

    public static func sourceLabel(_ src: Int) -> String {
        switch src {
        case 3: return "transcript"
        case 2: return "ocr_accurate"
        default: return "native"
        }
    }

    /// Documents que les filtres de LANGUE et de DATE laissent passer ; `nil`
    /// quand aucun des deux n'est armé (aucune restriction).
    ///
    /// Le canal LEXICAL n'en a pas besoin — `docFilter` écrit ces deux clauses
    /// dans sa sous-requête. C'est le canal VECTORIEL qui la réclame : il
    /// balaye `page_vec` et ne connaît des filtres que l'ensemble de documents
    /// qu'on lui autorise (`HybridSearch`, `VectorIndex.topK(allowedDocs:)`).
    /// Sans elle, `--lang fr --hybrid` rendait des pages anglaises « proposées
    /// par le sens » sous un filtre qui promettait le français.
    ///
    /// Compagne de `docIDsMatchingFilters(folders:exts:inDocIDs:)`, qui vit
    /// dans `GRDBStore+Vec.swift` ; les deux s'intersectent chez l'appelant.
    public func docIDsMatching(langs: [String],
                               modifiedAfter: Double?) throws -> Set<Int64>? {
        guard !langs.isEmpty || modifiedAfter != nil else { return nil }
        var clauses: [String] = []
        var args: [(any DatabaseValueConvertible)?] = []
        if !langs.isEmpty {
            clauses.append("\(Self.languageSQL("lang")) IN (\(placeholders(langs.count)))")
            args.append(contentsOf: langs.map {
                $0.lowercased() as (any DatabaseValueConvertible)? })
        }
        if let modifiedAfter {
            clauses.append("mtime >= ?")
            args.append(modifiedAfter)
        }
        return try read { db in
            Set(try Int64.fetchAll(
                db, sql: "SELECT id FROM docs WHERE "
                    + clauses.joined(separator: " AND "),
                arguments: StatementArguments(args)))
        }
    }

    /// La langue d'un document telle que la facette et le filtre la voient :
    /// TROIS écritures en base pour une seule valeur d'interface.
    ///
    /// `docs.lang` vaut NULL sur un document jamais examiné, `''` sur une base
    /// ancienne, et « und » depuis le rattrapage du lot U3 — qui écrit un jeton
    /// plutôt que NULL pour ne pas relire le même document à chaque passe
    /// (`GRDBStore+Language.swift`). Sans cette normalisation, la facette
    /// aurait montré DEUX lignes « langue non déterminée » et `--lang und`
    /// n'aurait ramené que la moitié des documents concernés.
    ///
    /// L'expression n'est pas indexable — `coalesce(lang,'')` ne l'était pas
    /// davantage —, et `docs` fait quelques milliers de lignes.
    static func languageSQL(_ column: String) -> String {
        "CASE WHEN \(column) IS NULL OR \(column) = '' "
        + "THEN '\(FacetKey.undeterminedLanguage)' ELSE lower(\(column)) END"
    }

    /// Ce que la facette « Langue » rend pour une valeur déjà normalisée par
    /// `languageSQL` : « und » y arrive tel quel, la conversion est faite en
    /// SQL. Reste public pour les appelants qui lisent `docs.lang` en direct.
    public static func languageLabel(_ raw: String) -> String {
        raw.isEmpty ? FacetKey.undeterminedLanguage : raw.lowercased()
    }

    public static func engineLabel(_ engine: OCREngineID) -> String {
        switch engine {
        case .none: return "none"
        case .vision: return "vision"
        case .external: return "external"
        }
    }

    // MARK: - Filtres

    struct Filter {
        /// Ce qui s'ajoute au FROM (une jointure sur `page_src`), vide quand
        /// aucune provenance n'est demandée. COMMENCE PAR UNE ESPACE : sans
        /// filtre, la chaîne interpolée redonne le SQL au caractère près.
        let join: String
        let sql: String
        let args: [(any DatabaseValueConvertible)?]
    }

    /// La jointure et la clause du filtre de PROVENANCE (lot P3), ou deux
    /// chaînes vides quand la requête ne demande rien.
    ///
    /// UNE JOINTURE, PAS UNE SOUS-REQUÊTE. `page_src` a pour clé primaire
    /// `(doc_id, page)` et vit sans rowid : chaque page appariée coûte un saut
    /// de B-tree, et le filtre s'applique DANS la sous-requête FTS, donc avant
    /// le LIMIT — c'est déjà la forme que la branche floue emploie pour sa
    /// portée `ocr` (§5.5.3). Une sous-requête `IN (SELECT … FROM page_src)`
    /// aurait matérialisé les 390 000 lignes de la table à chaque exécution.
    ///
    /// Le cas NATIF passe par un LEFT JOIN : une page absente de `page_src`
    /// est du texte natif (même convention que `pageMeta` et que la facette
    /// « Origine du texte »), et un JOIN interne la ferait disparaître.
    ///
    /// `alias` : `pf`, jamais `s` — la branche floue en portée `ocr` joint
    /// déjà `page_src s` dans la même requête.
    static func sourceFilter(_ q: SearchQuery, docID: String, page: String,
                             alias: String = "pf") -> (join: String, sql: String) {
        guard !q.keepsAllSources, let sources = q.sources else { return ("", "") }
        let values = sources.map(\.rawValue).sorted()
            .map(String.init).joined(separator: ",")
        let on = "\(alias).doc_id = \(docID) AND \(alias).page = \(page)"
        if sources.contains(.native) {
            return (" LEFT JOIN page_src \(alias) ON \(on)",
                    " AND coalesce(\(alias).src, 0) IN (\(values))")
        }
        return (" JOIN page_src \(alias) ON \(on)",
                " AND \(alias).src IN (\(values))")
    }

    /// Les filtres s'appliquent À L'INTÉRIEUR de la sous-requête FTS, AVANT
    /// LIMIT/OFFSET : sinon la pagination ment. `negative` (arbitrage T5) :
    /// exclusion de tout document dont une page répond à cette expression.
    /// INTERNE et non privée : deux tests comparent son SQL au caractère près
    /// (patron du lot P3, repris par MC1 pour les filtres de chemin).
    func docFilter(_ q: SearchQuery, column: String, page: String,
                   negative: String?) -> Filter {
        // Provenance de la PAGE (lot P3) : la seule clause qui ne porte pas sur
        // `docs`. Aucune variable liée — les valeurs sont des entiers de
        // l'énumération —, donc rien à insérer dans `args`.
        let source = Self.sourceFilter(q, docID: column, page: page)
        var clauses: [String] = [source.sql]
        var args: [(any DatabaseValueConvertible)?] = []

        var docWhere: [String] = []
        if !q.folders.isEmpty {
            docWhere.append("top_folder IN (\(placeholders(q.folders.count)))")
            args.append(contentsOf: q.folders.map { $0 as (any DatabaseValueConvertible)? })
        }
        if !q.exts.isEmpty {
            docWhere.append("ext IN (\(placeholders(q.exts.count)))")
            args.append(contentsOf: q.exts.map {
                $0.lowercased() as (any DatabaseValueConvertible)? })
        }
        // Langue et date de modification (lot U2) : deux colonnes de `docs`,
        // donc deux clauses de PLUS dans la même sous-requête — pas une
        // jointure de plus, et pas un filtre d'affichage.
        if !q.langs.isEmpty {
            docWhere.append("\(Self.languageSQL("lang")) IN (\(placeholders(q.langs.count)))")
            args.append(contentsOf: q.langs.map {
                $0.lowercased() as (any DatabaseValueConvertible)? })
        }
        if let after = q.modifiedAfter {
            docWhere.append("mtime >= ?")
            args.append(after)
        }
        // `chemin:` et les exclusions de dossier, d'extension et de chemin (lot
        // MC1) : des colonnes de `docs`, donc des clauses de la MÊME
        // sous-requête — pas une jointure de plus.
        let added = Self.pathAndExcludeClauses(q, alias: "")
        docWhere += added.clauses
        args += added.args
        if !docWhere.isEmpty {
            clauses.append(
                " AND \(column) IN (SELECT id FROM docs WHERE "
                + docWhere.joined(separator: " AND ") + ")")
        }
        if !q.inDocIDs.isEmpty {
            clauses.append(" AND \(column) IN (\(placeholders(q.inDocIDs.count)))")
            args.append(contentsOf: q.inDocIDs.map { $0 as (any DatabaseValueConvertible)? })
        }
        // `nom:` avec des termes de page (lot QP1) : un filtre de document de
        // plus, dans la même sous-requête. `docs_fts` a pour rowid `docs.id` :
        // l'opérande `IN` est une table éphémère de quelques lignes.
        if let names = Self.nameMatchExpression(q) {
            clauses.append(" AND \(column) IN (SELECT rowid FROM docs_fts WHERE docs_fts MATCH ?)")
            args.append(names)
        }
        // `-nom:brouillon` (lot MC1) : la même table, en négatif.
        if let excluded = Self.nameExcludeExpression(q) {
            clauses.append(" AND \(column) NOT IN (SELECT rowid FROM docs_fts WHERE docs_fts MATCH ?)")
            args.append(excluded)
        }
        if let negative, !negative.trimmingCharacters(in: .whitespaces).isEmpty {
            // doc_id dérivé du rowid : pas de lecture de contenu par page
            // négative (voir ftsDocIDExpr).
            clauses.append("""
                 AND \(column) NOT IN \
                (SELECT \(Self.ftsDocIDExpr) FROM page_fts WHERE page_fts MATCH ?)
                """)
            args.append(negative)
        }
        return Filter(join: source.join, sql: clauses.joined(), args: args)
    }

    private func placeholders(_ n: Int) -> String { Self.marks(n) }

    /// La même chose, appelable depuis les fonctions statiques.
    static func marks(_ n: Int) -> String {
        Array(repeating: "?", count: n).joined(separator: ",")
    }

    // MARK: - Comptages et accessoires

    private func countPages(match: String, filter: Filter,
                            threshold: Int = Schema.approximateCountThreshold) throws -> Int {
        let args: [(any DatabaseValueConvertible)?] =
            [match] + filter.args + [threshold + 1]
        return try read { db in
            try Int.fetchOne(db, sql: """
                SELECT count(*) FROM (
                  SELECT 1 FROM page_fts\(filter.join)
                  WHERE page_fts MATCH ?\(filter.sql) LIMIT ?
                )
                """, arguments: StatementArguments(args)) ?? 0
        }
    }

    /// Pages et documents distincts en une seule exécution du MATCH, doc_id
    /// dérivé du rowid (voir `ftsDocIDExpr`).
    /// C2-09 (b) : Si le nombre de pages appariées dépasse le seuil N (50 000 par défaut),
    /// le comptage s'arrête prématurément grâce à un LIMIT dans la sous-requête,
    /// évitant un balayage complet coûteux et un tri B-tree inutile.
    private func counts(match: String, filter: Filter,
                        threshold: Int = Schema.approximateCountThreshold) throws -> (pages: Int, docs: Int, approximate: Bool) {
        let args: [(any DatabaseValueConvertible)?] =
            [match] + filter.args + [threshold + 1]
        return try read { db in
            let row = try Row.fetchOne(db, sql: """
                SELECT count(*) AS pages,
                       count(DISTINCT doc_id) AS docs
                FROM (
                  SELECT \(Self.ftsDocIDExpr) AS doc_id
                  FROM page_fts\(filter.join) WHERE page_fts MATCH ?\(filter.sql)
                  LIMIT ?
                )
                """, arguments: StatementArguments(args))
            let p = (row?["pages"] as Int?) ?? 0
            let d = (row?["docs"] as Int?) ?? 0
            if p > threshold {
                return (threshold, min(d, threshold), true)
            } else {
                return (p, d, false)
            }
        }
    }

    private func snippetsFor(_ keys: [(docID: Int64, page: Int)],
                             match: String, filter: Filter,
                             markers: SearchQuery) throws -> [Int64: String] {
        guard !keys.isEmpty else { return [:] }
        let rowids = keys.map { Schema.ftsRowID(docID: $0.docID, page: $0.page) }
        let list = rowids.map(String.init).joined(separator: ",")
        return try read { db in
            var out: [Int64: String] = [:]
            let rows = try Row.fetchAll(db, sql: """
                SELECT rowid AS rid, \(Self.snippetExpr(markers)) AS snip
                FROM page_fts WHERE page_fts MATCH ? AND rowid IN (\(list))
                """, arguments: [match])
            for r in rows { out[r["rid"] as Int64] = r["snip"] as String }
            return out
        }
    }

    private func relPaths(for docIDs: [Int64]) throws -> [Int64: String] {
        guard !docIDs.isEmpty else { return [:] }
        let list = Set(docIDs).map(String.init).joined(separator: ",")
        return try read { db in
            var out: [Int64: String] = [:]
            for row in try Row.fetchAll(
                db, sql: "SELECT id, rel_path FROM docs WHERE id IN (\(list))") {
                out[row["id"] as Int64] = row["rel_path"] as String
            }
            return out
        }
    }

    // MARK: - Flou

    /// Variantes retenues par terme, avec leur distance. Vide = pas d'expansion.
    private func fuzzyVariants(for q: SearchQuery,
                               exactTotal: Int) throws -> [String: [(Int, String)]] {
        switch q.fuzzy {
        case .off: return [:]
        case .auto where exactTotal >= Self.autoFuzzyThreshold: return [:]
        default: break
        }
        guard !q.terms.isEmpty else { return [:] }

        // Portée `ocr` (défaut) sans AUCUNE page OCR dans l'index : la branche
        // fz joindrait un ensemble vide, le résultat est identique à l'exact.
        // Une sonde O(1) sur idx_page_src_conf évite toute l'expansion.
        // `src > 0` et non `src != 0` : l'inégalité stricte n'est pas
        // indexable et balayait les 363 058 lignes (~28 ms mesurés) ; la
        // plage `> 0` est un saut de B-tree (src ∈ {0, 1, 2}, jamais négatif).
        if q.fuzzyScope == .ocrOnly {
            let hasOCR = try read { db in
                try Bool.fetchOne(
                    db, sql: "SELECT EXISTS(SELECT 1 FROM page_src WHERE src > 0)")
                    ?? false
            }
            if !hasOCR { return [:] }
        }

        let expander = TrigramExpander(store: self)
        var out: [String: [(Int, String)]] = [:]
        for term in Set(q.terms) {
            // Sous 6 lettres : d = 0, aucune expansion (T15).
            guard TrigramExpander.normalize(term).count >= 6 else { continue }
            // LE PLAFOND DÉPEND DE LA PORTÉE (lot MC1) : deux lettres d'écart
            // sur six, c'est une faute de MACHINE (« rn » lu « m »), pas une
            // faute de frappe. `Kenvue` trouvait « Kenne » sur tout l'index.
            let maxDistance = TrigramExpander.maxDistance(for: term,
                                                          scope: q.fuzzyScope)
            // Un terme que `substitute` ne peut pas réécrire (membre d'un NEAR,
            // intérieur de phrase) ne produirait aucune branche : ne pas payer
            // ses sondes (bogue 1 — c'était le déclencheur de `pres:N` + flou).
            guard Self.isSubstitutable(term, in: q.fts) else { continue }
            let neighbours = try expander.expand(term, cap: Self.fuzzyVariantCap,
                                                 maxDistance: maxDistance)
                .filter { $0.distance > 0 }
            if !neighbours.isEmpty {
                out[term] = neighbours.map { ($0.distance, $0.term) }
            }
        }
        return out
    }

    /// Vrai si `substitute` réécrirait ce mot nu dans la chaîne FTS. Réutilise
    /// `substitute` lui-même (avec une variante sentinelle) : aucune seconde
    /// implémentation de la grammaire à faire diverger.
    static func isSubstitutable(_ term: String, in fts: String) -> Bool {
        substitute(fts, terms: [term], expansions: [term: ["\u{1}"]]) != fts
    }

    struct FuzzyPlan {
        let prelude: String
        let args: [(any DatabaseValueConvertible)?]
        let widestMatch: String
        /// Faux quand aucune branche fz n'a pu être construite : le plan est
        /// alors INUTILISABLE pour la recherche (bogue 1, voir l'en-tête).
        let hasFuzzyBranches: Bool
    }

    /// Construit `WITH ex …[, fz1 …][, fz2 …], u AS (…)`.
    /// Une branche par distance : sans cela une page trouvée par une variante à
    /// distance 1 serait étiquetée d = 2 et pénalisée de 1/3 au lieu de 1/2 (T13).
    ///
    /// Les formes morphologiques (lot R1) entrent dans TOUTES les branches : la
    /// branche exacte cherche `(polymere OR polymeres)`, une branche floue y
    /// ajoute ses voisins à distance ≤ d. Une forme morphologique n'est pas une
    /// variante floue : elle vaut d = 0 et n'est jamais pénalisée.
    private func fuzzyPlan(_ q: SearchQuery,
                           variants: [String: [(Int, String)]],
                           negative: String?) -> FuzzyPlan {
        let filter = docFilter(q, column: Self.ftsDocIDExpr,
                               page: Self.ftsPageExpr, negative: negative)
        let morph = Self.morphologyApplies(q) ? Morphology.expansions(forBareWordsIn: q.fts) : [:]
        let exact = Self.effectiveFTS(q.fts, morphology: Self.morphologyApplies(q))
        // doc_id/page DÉRIVÉS DU ROWID dans toutes les branches (voir
        // `ftsDocIDExpr`) : une branche floue apparie des dizaines de milliers
        // de pages dont le filtre de portée ne garde qu'une poignée, et lire
        // les colonnes UNINDEXED de chacune coûtait 7× le reste de la requête.
        var prelude = """
            WITH ex AS (
              SELECT \(Self.ftsDocIDExpr) AS doc_id, \(Self.ftsPageExpr) AS page,
                     bm25(page_fts) AS r, 0 AS fz
              FROM page_fts\(filter.join) WHERE page_fts MATCH ?\(filter.sql)
            )
            """
        var args: [(any DatabaseValueConvertible)?] = [exact] + filter.args
        var branches = ["ex"]
        var widest = exact

        if !variants.isEmpty {
            let fDocID = "(f.rowid / \(Schema.pagesPerDocLimit))"
            let fPage = "(f.rowid % \(Schema.pagesPerDocLimit))"
            let fFilter = docFilter(q, column: fDocID, page: fPage,
                                    negative: negative)
            for d in 1...2 {
                // Clés en MINUSCULES : `morph` est indexé par le mot tel qu'il
                // figure dans la chaîne, `variants` par le terme tapé ; deux
                // casses du même mot doivent fusionner, pas s'écraser.
                var atMost: [String: [String]] = morph
                for (term, list) in variants {
                    let kept = list.filter { $0.0 <= d }.map(\.1)
                    if !kept.isEmpty { atMost[term.lowercased(), default: []] += kept }
                }
                let expanded = Self.substitute(q.fts, terms: q.terms, expansions: atMost)
                if expanded == exact { continue }
                widest = expanded
                let name = "fz\(d)"
                branches.append(name)
                let join = q.fuzzyScope == .ocrOnly
                    ? "JOIN page_src s ON s.doc_id = \(fDocID) AND s.page = \(fPage)"
                    : ""
                let srcClause = q.fuzzyScope == .ocrOnly ? " AND s.src != 0" : ""
                prelude += """
                    ,
                    \(name) AS (
                      SELECT \(fDocID) AS doc_id, \(fPage) AS page,
                             bm25(page_fts) / (1.0 + \(d).0) AS r, \(d) AS fz
                      FROM page_fts f \(join)\(fFilter.join)
                      WHERE page_fts MATCH ?\(srcClause)\(fFilter.sql)
                    )
                    """
                args += [expanded] + fFilter.args
            }
        }

        prelude += """
            ,
            u AS (\(branches.map { "SELECT * FROM \($0)" }.joined(separator: " UNION ALL ")))
            """
        return FuzzyPlan(prelude: prelude, args: args, widestMatch: widest,
                         hasFuzzyBranches: branches.count > 1)
    }

    /// Remplace, dans une chaîne FTS5 déjà normalisée, chaque mot nu figurant
    /// dans `expansions` par son groupe `(exact OR variante …)`. Ne touche ni au
    /// contenu des phrases entre guillemets, ni à l'intérieur d'un `NEAR(…)`
    /// (qui n'accepte que des phrases). `terms` n'est pas lu : la table des
    /// expansions dit seule ce qui se réécrit (paramètre conservé pour les
    /// appelants).
    static func substitute(_ fts: String, terms: [String],
                           expansions: [String: [String]]) -> String {
        let table: [String: [String]] = expansions.reduce(into: [:]) { acc, kv in
            acc[kv.key.lowercased()] = kv.value
        }
        guard !table.isEmpty else { return fts }

        var out = ""
        var word = ""
        var inQuotes = false
        var nearDepth = 0
        var parenStack: [Bool] = []   // true = parenthèse ouverte par un NEAR

        func flushWord(next: Character? = nil) {
            guard !word.isEmpty else { return }
            // Une racine de préfixe (`spectro*`) et le mot-clé `NEAR(` ne se
            // réécrivent jamais : `(spectro OR spectros)*` n'est pas du FTS5.
            if !inQuotes, nearDepth == 0, next != "*", next != "(",
               let variants = table[word.lowercased()] {
                var seen = Set<String>()
                var parts: [String] = []
                for v in [word] + variants where seen.insert(v.lowercased()).inserted {
                    parts.append(QueryParser.quote(v))
                }
                out += parts.count == 1 ? parts[0]
                                        : "(" + parts.joined(separator: " OR ") + ")"
            } else {
                out += word
            }
            word = ""
        }

        var iterator = fts.startIndex
        while iterator < fts.endIndex {
            let ch = fts[iterator]
            if ch == "\"" {
                flushWord(next: ch)
                inQuotes.toggle()
                out.append(ch)
            } else if inQuotes {
                out.append(ch)
            } else if ch.isLetter || ch.isNumber || ch == "_" {
                word.append(ch)
            } else if ch == "(" {
                let isNear = word.uppercased() == "NEAR"
                flushWord(next: ch)
                parenStack.append(isNear)
                if isNear { nearDepth += 1 }
                out.append(ch)
            } else if ch == ")" {
                flushWord(next: ch)
                if let wasNear = parenStack.popLast(), wasNear { nearDepth -= 1 }
                out.append(ch)
            } else {
                flushWord(next: ch)
                out.append(ch)
            }
            iterator = fts.index(after: iterator)
        }
        flushWord(next: nil)
        return out
    }
}
