// QueryParser.swift — traduction saisie utilisateur -> FTS5 (SPEC §5.5.1).
// Propriété : A-Core.
//
// Table de traduction IMPOSÉE :
//   azote reduction        -> azote AND reduction
//   "gaz parfait"          -> "gaz parfait"
//   spectro*               -> spectro*        (< 4 caractères : REFUSÉ, D3)
//   -biologie              -> NOT biologie
//   pres:5 azote reduction -> NEAR(azote reduction, 5)
//   dossier:Cours enthalpie -> enthalpie + filtre top_folder = 'Cours'
//   ext:pdf …              -> filtre ext = 'pdf'
//   nom:rapport …          -> documents dont docs_fts répond à « rapport » (lot QP1)
//   texte:rapport          -> rapport, sans bonus ni bandeau des noms (lot QP1)
//   chemin:Offres …        -> filtre « le chemin complet contient Offres » (lot MC1)
//   -dossier:X -ext:X -nom:X -chemin:X -> les mêmes filtres, en NÉGATIF (lot MC1)
//
// EXCLUSIONS DE FILTRES (lot MC1, retour d'usage du 13/09/2026). `-nom:Pourvue`
// et `-ext:md` étaient ACCEPTÉS SANS EFFET : le `-` tombait dans la branche de
// l'exclusion de mot et produisait `NOT "nom:Pourvue"`, une chaîne qu'aucune
// page ne porte — le filtre ne retirait rien et le résultat avait l'air juste.
// Les quatre exclusions sont donc lues AVANT `-terme`, et deviennent des
// clauses de document (`top_folder NOT IN`, `ext NOT IN`, `docs_fts` en
// négatif, chemin ne contenant pas).
//
// FORME NFC (lot MC1). Un chemin copié depuis le Finder ou `ls` arrive en
// forme DÉCOMPOSÉE (macOS écrit « Polymères » e + ◌̀ ), la base est en NFC
// (`migration_v7_nfc`) : `chemin:Polymères` collé rendait 0 document, tapé 9.
// `tokenize` recompose donc l'entrée une fois pour toutes.
//
// ALIAS ANGLAIS (lot MP1, PR-03 et PR-04). `near:` et `folder:` valent
// `pres:` et `dossier:`, partout : l'aide, la CLI et le champ de recherche sont
// en anglais, et deux des trois préfixes étaient des mots français. Mesuré le
// 09/09/2026 sur la base de production : `near:5 azote reduction` rendait 0
// page contre 7 pour `pres:5 …`, `folder:Livres energie` 0 contre 28 658 — un
// préfixe inconnu devenait un mot ordinaire, et le zéro ne se distinguait pas
// d'un corpus muet. La forme CANONIQUE reste `dossier:`/`pres:` dans les
// structures : rien ne change pour les appelants.
//
// UN PRÉFIXE INCONNU SE DIT (lot MP1, PR-04). `type:pdf`, `dans:Livres` :
// `<lettres>:<valeur>` dont le préfixe n'est pas un filtre est REFUSÉ en
// nommant les trois filtres, au lieu d'être cherché comme un mot que personne
// n'écrit. Ni une URL (`https://…`, la valeur commence par `//`), ni une heure
// (`10:30`, des chiffres avant le deux-points), ni un mot entre guillemets ne
// sont concernés.
//
// L'insensibilité aux accents est acquise par le tokenizer
// (unicode61 remove_diacritics 2) : `polymere` trouve « polymère » (T3).

import Foundation

public enum QueryError: Error, LocalizedError, Equatable {
    case prefixTooShort(String)
    case emptyQuery
    case exclusionOnly
    /// Un mot-clé de la grammaire FTS5 tapé tel quel (`AND`, `OR`, `NOT`,
    /// `NEAR(`) : audit A1m-07.
    case ftsOperator(String)
    /// `dossier:Xyz` où aucune racine ne porte cette étiquette (idée 5 de
    /// l'audit A1). Les étiquettes existantes voyagent avec l'erreur : les
    /// nommer est tout l'intérêt, et l'analyseur ne connaît pas la base.
    case unknownFolder(String, known: [String])
    /// `type:pdf` : un préfixe qui ressemble à un filtre et n'en est pas (lot
    /// MP1, PR-04). Les filtres voyagent avec l'erreur, comme pour
    /// `unknownFolder` : les nommer est tout l'intérêt du refus.
    case unknownPrefix(String, known: [String])
    /// `-texte:azote`, `-pres:5` : un filtre qui EXISTE mais ne s'exclut pas
    /// (lot MN2, après MN1 qui réutilisait `unknownPrefix`). Le préfixe est
    /// cité sans son tiret — c'est lui qui ne se prête pas à l'exclusion —, et
    /// les filtres qui s'excluent voyagent avec l'erreur, comme pour
    /// `unknownPrefix`.
    case notExcludable(String, excludable: [String])

    public var errorDescription: String? {
        switch self {
        case .prefixTooShort:
            return "prefix too short, give at least 4 letters"
        case .emptyQuery:
            return "empty query: give at least one term to search for"
        case .exclusionOnly:
            return "exclusion alone (-term): add at least one term to search for"
        case .ftsOperator(let word):
            return "“\(word)” is a search operator, not a word: Fouine combines "
                + "words with AND by default; to exclude a word, write -word "
                + "(put it in quotes to search for the word itself)"
        case .unknownFolder(let asked, let known):
            return "unknown folder “\(asked)” — yours are: "
                + known.joined(separator: ", ")
        case .unknownPrefix(let asked, let known):
            return "“\(asked)” is not a filter — filters are "
                + known.joined(separator: ", ")
        case .notExcludable(let asked, let excludable):
            let list = excludable.joined(separator: ", ")
            return "“\(asked)” cannot be excluded. The filters that can are \(list). "
                + "To leave out a word, write -word."
        }
    }
}

public struct ParsedQuery: Sendable, Equatable {
    public enum Node: Sendable, Equatable {
        case term(String)            // mot nu
        case phrase(String)          // "…" exact
        case prefix(String)          // spectro*  (racine ≥ 4 caractères)
        case not(String)             // -biologie
        case near([String], Int)     // pres:N t1 t2 …
    }

    public let nodes: [Node]
    public let folders: [String]
    public let exts: [String]
    /// Valeurs de `nom:`/`name:` (lot QP1) : cherchées dans `docs_fts` SEULEMENT
    /// (nom du fichier et de son dossier parent), jamais dans les pages.
    public let nameTerms: [String]
    /// Au moins un `texte:`/`body:` : la requête ne veut pas du nom du fichier
    /// (lot QP1) — ni bonus de classement, ni bandeau des noms.
    public let bodyOnly: Bool
    /// Valeurs de `chemin:`/`path:` (lot MC1) : le chemin COMPLET du document,
    /// répertoires compris, doit contenir chacune — casse et accents ignorés.
    public let pathContains: [String]
    /// Les quatre exclusions de filtres (lot MC1), vides par défaut.
    public let folderExcludes: [String], extExcludes: [String]
    public let nameExcludes: [String], pathExcludes: [String]

    public init(nodes: [Node], folders: [String], exts: [String],
                nameTerms: [String] = [], bodyOnly: Bool = false,
                pathContains: [String] = [],
                folderExcludes: [String] = [], extExcludes: [String] = [],
                nameExcludes: [String] = [], pathExcludes: [String] = []) {
        self.nodes = nodes
        self.folders = folders
        self.exts = exts
        self.nameTerms = nameTerms
        self.bodyOnly = bodyOnly
        self.pathContains = pathContains
        self.folderExcludes = folderExcludes
        self.extExcludes = extExcludes
        self.nameExcludes = nameExcludes
        self.pathExcludes = pathExcludes
    }

    /// Termes bruts conservés pour l'expansion floue (§5.5.2) : mots nus et
    /// membres de NEAR. Ni les phrases, ni les négations, ni les préfixes.
    public var terms: [String] {
        var out: [String] = []
        for node in nodes {
            switch node {
            case .term(let t): out.append(t)
            case .near(let ts, _): out.append(contentsOf: ts)
            case .phrase, .prefix, .not: break
            }
        }
        return out
    }

    /// La requête demande-t-elle une PHRASE entre guillemets ?
    ///
    /// Le canal sémantique n'a pas de guillemets : il compare des vecteurs, et
    /// une page qui « parle de la même chose » entre dans la fusion sans porter
    /// l'expression demandée (constat RK-01, jugé le 09/09/2026 : 4 résultats
    /// sur 10 sans la phrase). C'est ce champ qui le désarme, du côté de
    /// l'analyseur plutôt que par une relecture de la chaîne FTS — un montant
    /// (`1512,50`) et un mot à caractère spécial y sont aussi entre guillemets
    /// sans être des phrases.
    public var hasPhrase: Bool {
        nodes.contains { if case .phrase = $0 { return true } else { return false } }
    }

    /// Chaîne FTS5 des nœuds POSITIFS. `expansions` remplace un mot nu par un
    /// groupe OR de variantes (§5.5.3) ; vide = requête exacte.
    ///
    /// ARBITRAGE T5 (post-recette tranche A) : `-terme` exclut le DOCUMENT
    /// entier, pas la page. Les négations ne participent donc PLUS à cette
    /// expression MATCH : elles sortent par `negativeFTS` et deviennent un
    /// `doc_id NOT IN (SELECT doc_id FROM page_fts WHERE page_fts MATCH :neg)`
    /// côté Store. La table de traduction du §5.5.1 reste valable pour la
    /// SYNTAXE ; seule la portée change.
    public func fts(expansions: [String: [String]] = [:]) -> String {
        var positives: [String] = []
        for node in nodes {
            switch node {
            case .term(let t):
                positives.append(Self.group(t, expansions))
            case .phrase(let p):
                positives.append(QueryParser.quote(p))
            case .prefix(let p):
                positives.append(QueryParser.escapeBare(p) + "*")
            case .not:
                break   // portée document : voir `negativeFTS`
            case .near(let ts, let n):
                // NEAR n'accepte que des phrases : pas de groupe (a OR b) dedans.
                let inner = ts.map(QueryParser.escapeBare).joined(separator: " ")
                positives.append("NEAR(\(inner), \(n))")
            }
        }
        return positives.joined(separator: " AND ")
    }

    /// Expression MATCH des termes exclus (`-a -b` -> `a OR b`) : un document
    /// dont UNE page y répond est exclu en entier (arbitrage T5). `nil` si la
    /// requête ne porte aucune exclusion.
    public var negativeFTS: String? {
        let negatives = nodes.compactMap { node -> String? in
            if case .not(let t) = node { return QueryParser.escapeBare(t) }
            return nil
        }
        return negatives.isEmpty ? nil : negatives.joined(separator: " OR ")
    }

    private static func group(_ term: String, _ expansions: [String: [String]]) -> String {
        guard let variants = expansions[term], !variants.isEmpty else {
            // MONTANT (C2-12) : les deux écritures, la forme TAPÉE d'abord.
            // Les deux membres sont entre guillemets — `1512,50` nu est une
            // erreur de syntaxe FTS5 (« syntax error near "," », vérifié).
            if let amount = QueryParser.amountVariants(term) {
                let typed = term.contains(" ") ? amount.grouped : amount.compact
                let other = term.contains(" ") ? amount.compact : amount.grouped
                return "(" + QueryParser.quote(typed) + " OR "
                    + QueryParser.quote(other) + ")"
            }
            return QueryParser.escapeBare(term)
        }
        var seen = Set<String>()
        var parts: [String] = []
        for v in [term] + variants where seen.insert(v).inserted {
            parts.append(QueryParser.quote(v))
        }
        return parts.count == 1 ? parts[0] : "(" + parts.joined(separator: " OR ") + ")"
    }
}

public enum QueryParser {

    /// Caractères spéciaux de la grammaire FTS5 : présents dans un mot nu,
    /// ils imposent l'encadrement par des guillemets doubles (§5.5.1).
    static let ftsSpecials = Set<Character>("\"*():^-{}[]/+,;!?&|=<>~@#$%'`\\")

    /// Les mots-clés de FTS5, et LA CASSE COMPTE (audit A1m-07).
    ///
    /// `ftsSpecials` ne connaît que de la ponctuation : un mot nu tout en
    /// lettres n'était jamais mis entre guillemets, et `polymere OR catalyse`
    /// partait tel quel à FTS5, qui répondait « syntax error near "OR" ».
    /// L'utilisateur lisait alors un vidage de SQL en anglais et la commande
    /// sortait en **3** — « base verrouillée ou corrompue » — pour une faute de
    /// frappe. On refuse donc en amont, avec la règle.
    ///
    /// En minuscules, ce sont trois mots ordinaires : « or » et « ou » sont du
    /// français courant, « and » de l'anglais, et FTS5 ne les lit comme
    /// opérateurs qu'en majuscules. Ils restent donc cherchables, et
    /// `"OR"` entre guillemets cherche le mot lui-même.
    static let ftsOperators: Set<String> = ["AND", "OR", "NOT"]

    public static func parse(_ input: String) throws -> ParsedQuery {
        var nodes: [ParsedQuery.Node] = []
        var folders: [String] = []
        var exts: [String] = []
        var nameTerms: [String] = []
        var bodyOnly = false
        var pathContains: [String] = []
        var folderExcludes: [String] = [], extExcludes: [String] = []
        var nameExcludes: [String] = [], pathExcludes: [String] = []

        let tokens = tokenize(input)
        var i = 0
        while i < tokens.count {
            let tok = tokens[i]
            i += 1
            switch tok {
            case .quoted(let phrase):
                let trimmed = phrase.trimmingCharacters(in: .whitespaces)
                if !trimmed.isEmpty { nodes.append(.phrase(trimmed)) }

            case .word(let raw):
                // `NEAR` n'est un opérateur QUE suivi d'une parenthèse : c'est
                // la règle de FTS5, et c'est pourquoi `azote NEAR carbone` n'est
                // pas refusé ici (il cherche le mot « near »).
                if raw == "NEAR", i < tokens.count,
                   case .word(let next) = tokens[i], next.hasPrefix("(") {
                    throw QueryError.ftsOperator("NEAR")
                }
                try checkOperator(raw)
                let lower = raw.lowercased()
                // L'EXCLUSION D'UN FILTRE D'ABORD (lot MC1) : sans cette
                // branche, `-ext:md` devient `.not("ext:md")`, c'est-à-dire un
                // filtre accepté qui n'exclut rien.
                if let excluded = Self.excludedFilter(raw) {
                    switch excluded.kind {
                    case .folder:
                        if !excluded.value.isEmpty { folderExcludes.append(excluded.value) }
                    case .ext:
                        let v = excluded.value.lowercased()
                            .trimmingCharacters(in: CharacterSet(charactersIn: "."))
                        if !v.isEmpty { extExcludes.append(v) }
                    case .name:
                        if !excluded.value.isEmpty { nameExcludes.append(excluded.value) }
                    case .path:
                        if !excluded.value.isEmpty { pathExcludes.append(excluded.value) }
                    }
                } else if let prefix = Self.matching(Self.folderPrefixes, lower) {
                    let v = String(raw.dropFirst(prefix.count))
                    if !v.isEmpty { folders.append(unquoted(v)) }
                } else if let prefix = Self.matching(Self.extPrefixes, lower) {
                    let v = String(raw.dropFirst(prefix.count))
                    if !v.isEmpty {
                        exts.append(unquoted(v).lowercased()
                            .trimmingCharacters(in: CharacterSet(charactersIn: ".")))
                    }
                } else if let prefix = Self.matching(Self.namePrefixes, lower) {
                    let v = unquoted(String(raw.dropFirst(prefix.count)))
                    if !v.isEmpty { nameTerms.append(v) }
                } else if let prefix = Self.matching(Self.pathPrefixes, lower) {
                    // Le CHEMIN COMPLET (lot MC1) : `docs_fts` n'indexe que le
                    // nom du fichier et celui de son dossier parent (lot QP1),
                    // et `nom:Offres` ne rendait donc que 6 des ~160 documents
                    // rangés sous `Stage/Offres/…` (mesuré le 13/09/2026).
                    let v = unquoted(String(raw.dropFirst(prefix.count)))
                    if !v.isEmpty { pathContains.append(v) }
                } else if let prefix = Self.matching(Self.bodyPrefixes, lower) {
                    // UN TERME DE PAGE ORDINAIRE, qui éteint en plus le nom du
                    // fichier pour toute la requête. La valeur entre guillemets
                    // (`texte:"gaz parfait"`) arrive sans ses guillemets mais
                    // avec son espace : c'est une phrase, pas un mot qui en
                    // contiendrait une (FTS5 le lirait comme deux mots en ET, et
                    // la morphologie comme un seul).
                    bodyOnly = true
                    let v = unquoted(String(raw.dropFirst(prefix.count)))
                    if v.contains(where: \.isWhitespace) {
                        nodes.append(.phrase(v))
                    } else if v.hasSuffix("*"), v.count > 1 {
                        let stem = String(v.dropLast())
                        guard stem.count >= 4 else { throw QueryError.prefixTooShort(stem) }
                        nodes.append(.prefix(stem))
                    } else if !v.isEmpty {
                        try checkOperator(v)
                        nodes.append(.term(v))
                    }
                } else if let prefix = Self.matching(Self.proximityPrefixes, lower) {
                    let n = Int(raw.dropFirst(prefix.count)) ?? 5
                    // NEAR absorbe les mots nus qui suivent (T2).
                    var members: [String] = []
                    while i < tokens.count, case .word(let w) = tokens[i],
                          !isOperator(w) {
                        // Un mot-clé FTS5 à l'intérieur d'un NEAR(…) est une
                        // erreur de syntaxe de plus, et le même geste la répare.
                        try checkOperator(w)
                        // `pres:5 azote type:pdf` : le faux filtre se dit ici
                        // aussi, sinon il entrerait dans le NEAR comme membre.
                        try checkPrefix(w)
                        members.append(w)
                        i += 1
                    }
                    if members.count >= 2 {
                        nodes.append(.near(members, max(n, 1)))
                    } else if let only = members.first {
                        nodes.append(.term(only))
                    }
                } else if raw.hasPrefix("-"), raw.count > 1 {
                    // `-type:pdf` et `-texte:azote` SONT REFUSÉS (lot MN1),
                    // avec la même règle que leurs formes positives : les
                    // quatre exclusions de filtres sont déjà parties plus haut
                    // (`excludedFilter`), et ce qui ressemble encore à un
                    // filtre ici n'en est pas un ou ne s'exclut pas.
                    try checkExclusion(raw)
                    nodes.append(.not(String(raw.dropFirst())))
                } else if raw.hasSuffix("*"), raw.count > 1 {
                    let stem = String(raw.dropLast())
                    guard stem.count >= 4 else { throw QueryError.prefixTooShort(stem) }
                    nodes.append(.prefix(stem))
                } else if !raw.isEmpty {
                    try checkPrefix(raw)
                    // MONTANTS (lot MP1, C2-12) : « 1 512,50 » tapé arrive en
                    // deux jetons (l'espace des milliers) et se recolle ici, en
                    // UN terme — que `fts()` rendra sous ses deux écritures.
                    if let amount = Self.joinedAmount(raw, tokens: tokens, index: &i) {
                        nodes.append(.term(amount))
                    } else {
                        nodes.append(.term(raw))
                    }
                }
            }
        }

        // `nom:rapport` seul est une requête entière : elle rend des documents
        // (lot QP1), et `chemin:Offres` seul aussi (lot MC1). Une exclusion à
        // côté garde donc quelque chose de positif à retrancher.
        //
        // UN NOT SEUL ne réduit rien : FTS5 n'a pas de « tout sauf », et
        // l'arbitrage T5 (exclusion par document) non plus. `-ext:md` seul
        // tombe sous la MÊME phrase que `-biologie` — c'est la même demande.
        let positive = !nameTerms.isEmpty || !pathContains.isEmpty
            || nodes.contains(where: { if case .not = $0 { return false }
                                       return true })
        if !positive {
            let excludes = !nodes.isEmpty || !folderExcludes.isEmpty
                || !extExcludes.isEmpty || !nameExcludes.isEmpty
                || !pathExcludes.isEmpty
            throw excludes ? QueryError.exclusionOnly : QueryError.emptyQuery
        }
        return ParsedQuery(nodes: nodes, folders: folders, exts: exts,
                           nameTerms: nameTerms, bodyOnly: bodyOnly,
                           pathContains: pathContains,
                           folderExcludes: folderExcludes, extExcludes: extExcludes,
                           nameExcludes: nameExcludes, pathExcludes: pathExcludes)
    }

    /// Construit une `SearchQuery` complète à partir de la saisie utilisateur.
    /// Les exclusions `-terme` n'y figurent PAS (le contrat SearchQuery est
    /// gelé) : les appelants qui doivent les honorer passent par `searchPlan`.
    public static func searchQuery(_ input: String, limit: Int = 50, offset: Int = 0,
                                   inDocIDs: [Int64] = [], groupByDoc: Bool = true,
                                   fuzzy: FuzzyMode = .auto,
                                   fuzzyScope: FuzzyScope = .ocrOnly) throws -> SearchQuery {
        try searchPlan(input, limit: limit, offset: offset, inDocIDs: inDocIDs,
                       groupByDoc: groupByDoc, fuzzy: fuzzy,
                       fuzzyScope: fuzzyScope).query
    }

    /// `searchQuery` + l'expression des exclusions par document (arbitrage T5),
    /// à passer à `GRDBStore.search(_:excludingDocsMatching:)`.
    public static func searchPlan(_ input: String, limit: Int = 50, offset: Int = 0,
                                  inDocIDs: [Int64] = [], groupByDoc: Bool = true,
                                  fuzzy: FuzzyMode = .auto,
                                  fuzzyScope: FuzzyScope = .ocrOnly)
        throws -> (query: SearchQuery, negative: String?) {
        let parsed = try parse(input)
        var query = SearchQuery(terms: parsed.terms, fts: parsed.fts(), limit: limit,
                                offset: offset, folders: parsed.folders,
                                exts: parsed.exts, inDocIDs: inDocIDs,
                                groupByDoc: groupByDoc, fuzzy: fuzzy,
                                fuzzyScope: fuzzyScope)
        query.nameTerms = parsed.nameTerms
        query.nameBoost = !parsed.bodyOnly
        query.pathContains = parsed.pathContains
        query.folderExcludes = parsed.folderExcludes
        query.extExcludes = parsed.extExcludes
        query.nameExcludes = parsed.nameExcludes
        query.pathExcludes = parsed.pathExcludes
        return (query, parsed.negativeFTS)
    }

    /// La requête TELLE QU'ELLE A ÉTÉ TAPÉE demande-t-elle une phrase exacte ?
    ///
    /// Point unique des quatre surfaces qui désarment le canal sémantique sur
    /// ces requêtes (RK-01) : la ligne de commande, l'application, le serveur
    /// MCP et `HybridSearch.run` lui-même. Une requête que l'analyseur REFUSE
    /// (préfixe inconnu, opérateur nu) rend `false` : elle ne cherchera rien du
    /// tout, et la surface la refuse avant d'arriver ici.
    public static func asksForExactPhrase(_ input: String) -> Bool {
        (try? parse(input))?.hasPhrase ?? false
    }

    /// Le texte envoyé au MODÈLE sémantique : la requête sans ses filtres, ses
    /// exclusions ni ses guillemets — le canal vectoriel n'a pas de syntaxe.
    ///
    /// UNE SEULE FONCTION pour les trois surfaces (CLI, application, serveur
    /// MCP), qui en portaient chacune une copie jusqu'au lot QP1. Sur les
    /// JETONS de l'analyseur et non sur la chaîne coupée aux espaces : la
    /// valeur entre guillemets d'un filtre (`dossier:"Mes cours"`) sort en
    /// entier, et les guillemets courbes sont ceux que `tokenize` normalise.
    ///
    /// `texte:rapport` garde « rapport » — c'est un mot de la page ; `nom:` et
    /// les filtres sortent. Une requête qui ne porte que `nom:` rend donc la
    /// chaîne vide, et les surfaces restent alors lexicales.
    public static func semanticText(_ input: String) -> String {
        var kept: [String] = []
        for token in tokenize(input) {
            switch token {
            case .quoted(let phrase):
                kept.append(phrase.trimmingCharacters(in: .whitespaces))
            case .word(let raw):
                let lower = raw.lowercased()
                if let prefix = matching(bodyPrefixes, lower) {
                    kept.append(unquoted(String(raw.dropFirst(prefix.count))))
                } else if matching(allPrefixes, lower) == nil, !raw.hasPrefix("-") {
                    kept.append(raw)
                }
            }
        }
        return kept.filter { !$0.isEmpty }.joined(separator: " ")
            .replacingOccurrences(of: "\"", with: "")
            .trimmingCharacters(in: .whitespaces)
    }

    // MARK: - Quorum des mots (lot RK2, RK-04)

    /// Longueur MINIMALE d'un mot pour être exigé par le quorum. « la », « par »,
    /// « une », « de » ne disent rien de ce qu'on cherche, et ce sont eux qui
    /// font échouer le ET strict : `comment mesurer la chaleur degagee par une
    /// reaction` rend 0 page, `la chaleur degagee par une reaction` en rend 10
    /// (AUDIT-RK, RK-04, 09/09/2026). Ils restent dans la requête STRICTE — une
    /// page qui les porte tous garde la tête — et ne sont jamais exigés ici.
    ///
    /// STRICTEMENT PLUS DE TROIS lettres : « gaz », « eau » et « pKa » sont
    /// écartés avec « par », et c'est le prix du seuil. Ils reviennent par la
    /// passe stricte, qui reste la tête de liste.
    public static let quorumMinimumWordLength = 4

    /// Nombre MAXIMAL de mots longs qu'un quorum accepte d'énumérer. À 6 mots
    /// et k = 4, l'expression compte C(6,4) = 15 groupes ; à 8 mots, C(8,5)
    /// en compterait 56, chacun étant une intersection FTS5 complète.
    public static let quorumMaximumWords = 6

    /// Les mots VIDES que le quorum n'exige jamais, quelle que soit leur
    /// longueur (lot MC1).
    ///
    /// POURQUOI QUATRE LETTRES NE SUFFISENT PAS. `quorumMinimumWordLength`
    /// écarte « la », « de », « par » ; il garde « dans », « avec », « pour »,
    /// « cette », « with », « that ». Mesuré le 13/09/2026 sur la base de
    /// production : `dossier:Livres distribution des temps de séjour dans un
    /// réacteur réel` rendait 0 page alors que « réacteur » est dans 22
    /// documents de `Livres` — le quorum exigeait « dans » comme il exigeait
    /// « réacteur ». Une question tapée en langage naturel est pleine de ces
    /// mots, et ce sont eux qui font échouer le ET.
    ///
    /// SANS ACCENT, et comparés sur la forme REPLIÉE (`Morphology.fold`) :
    /// c'est ce que fait le tokenizer (`remove_diacritics 2`), et « être »
    /// tapé ou « etre » doivent tomber pareil. Ils restent dans la passe
    /// STRICTE, qui garde la tête de liste : on ne les efface pas de la
    /// requête, on cesse seulement de les EXIGER.
    public static let quorumStopwords: Set<String> = [
        // Français
        "dans", "avec", "pour", "sans", "sous", "chez", "vers", "entre",
        "cette", "cettes", "celui", "celle", "ceux", "cela", "leur", "leurs",
        "mais", "donc", "alors", "comme", "quand", "aussi", "encore", "meme",
        "tout", "tous", "toute", "toutes", "autre", "autres", "plus", "moins",
        "tres", "bien", "peut", "peuvent", "faire", "fait", "etre", "etait",
        "sont", "soit", "avoir", "avait", "elle", "elles", "nous", "vous",
        "ils", "lui", "quel", "quels", "quelle", "quelles", "quoi", "dont",
        "comment", "pourquoi", "lequel", "laquelle", "ceci",
        // Anglais
        "with", "from", "that", "this", "these", "those", "what", "which",
        "about", "into", "does", "have", "been", "were", "where", "when",
        "there", "their", "them", "they", "than", "then", "such", "some",
        "each", "other", "would", "could", "should", "will", "shall", "also",
        "very", "more", "most", "between", "under", "over", "through",
    ]

    /// Proportion des mots longs qu'une page doit porter. 0,6 vient du remède
    /// de RK-04 (« tous les mots de plus de trois lettres, ou 60 % des mots ») :
    /// sur trois mots longs il en exige deux, sur cinq il en exige trois.
    public static let quorumFraction = 0.6

    /// L'expression FTS5 du QUORUM pour ces mots, ou `nil` si la requête n'y a
    /// pas droit.
    ///
    /// `(A AND B AND C) OR (A AND B AND D) OR …` : toutes les combinaisons de
    /// `k = ⌈0,6 × m⌉` mots parmi les `m` mots de plus de trois lettres. Une
    /// disjonction explicite plutôt qu'un comptage — FTS5 ne sait pas compter
    /// les termes appariés d'une page, et l'expression reste celle que le même
    /// moteur, le même index et les mêmes couches de classement savent lire.
    ///
    /// Les mots partent NUS (simplement échappés) : la morphologie est appliquée
    /// ensuite sur la chaîne entière, comme pour l'expression stricte
    /// (`GRDBStore.effectiveFTS`), et chaque mot y garde donc ses formes.
    ///
    /// `nil` quand il reste moins de trois mots longs (le quorum ne
    /// départagerait rien : à deux mots, en exiger un rend tout le corpus) ou
    /// plus de `quorumMaximumWords`.
    public static func quorumFTS(terms: [String]) -> String? {
        let long = terms.filter {
            $0.count >= quorumMinimumWordLength
                && !quorumStopwords.contains(Morphology.fold($0))
        }
        guard long.count >= 3 else { return nil }
        // AU-DELÀ DE SIX, LES SIX PLUS LONGS (lot MC1) — et non plus « pas de
        // quorum du tout ». Une question posée en langage naturel compte
        // souvent sept ou huit mots porteurs, et c'est précisément là que le ET
        // strict échoue : se désarmer laissait l'utilisateur avec zéro page. Le
        // mot le plus long est le plus discriminant du lot ; à longueur égale,
        // l'ordre tapé tranche, et les mots retenus restent dans cet ordre pour
        // que l'expression reste lisible.
        let kept = long.count <= quorumMaximumWords ? long
            : long.enumerated()
                .sorted { a, b in
                    a.element.count == b.element.count ? a.offset < b.offset
                                                       : a.element.count > b.element.count
                }
                .prefix(quorumMaximumWords)
                .sorted { $0.offset < $1.offset }
                .map(\.element)
        let k = Int((quorumFraction * Double(kept.count)).rounded(.up))
        guard k >= 1, k < kept.count else { return nil }
        let groups = combinations(of: kept, taking: k).map { words in
            "(" + words.map(escapeBare).joined(separator: " AND ") + ")"
        }
        guard groups.count > 1 else { return nil }
        return groups.joined(separator: " OR ")
    }

    /// Les combinaisons de `k` éléments parmi `items`, dans l'ordre des indices
    /// (donc dans l'ordre des mots tapés) : la première exige les `k` premiers
    /// mots, la dernière les `k` derniers.
    static func combinations(of items: [String], taking k: Int) -> [[String]] {
        guard k > 0, k <= items.count else { return k == 0 ? [[]] : [] }
        if k == items.count { return [items] }
        var out: [[String]] = []
        var current: [String] = []
        func walk(_ start: Int) {
            if current.count == k { out.append(current); return }
            // Il faut encore `k - current.count` éléments : inutile d'ouvrir une
            // branche qui ne pourra pas les fournir.
            let last = items.count - (k - current.count)
            guard start <= last else { return }
            for i in start...last {
                current.append(items[i])
                walk(i + 1)
                current.removeLast()
            }
        }
        walk(0)
        return out
    }

    // MARK: - Échappement

    /// Encadre de guillemets doubles (les guillemets internes sont doublés).
    static func quote(_ s: String) -> String {
        "\"" + s.replacingOccurrences(of: "\"", with: "\"\"") + "\""
    }

    /// Un mot nu qui contient un caractère spécial FTS5 est encadré de guillemets.
    static func escapeBare(_ s: String) -> String {
        s.contains(where: { ftsSpecials.contains($0) }) ? quote(s) : s
    }

    /// Refuse un mot-clé FTS5 tapé nu, exclusion comprise (`-OR` produirait la
    /// même erreur de syntaxe, par `negativeFTS`). Le mot est rendu tel qu'il a
    /// été tapé : c'est celui que l'utilisateur doit retrouver dans sa barre.
    private static func checkOperator(_ raw: String) throws {
        let bare = raw.hasPrefix("-") && raw.count > 1 ? String(raw.dropFirst()) : raw
        if ftsOperators.contains(bare) { throw QueryError.ftsOperator(bare) }
        if bare.hasPrefix("NEAR(") { throw QueryError.ftsOperator("NEAR") }
    }

    private static func isOperator(_ w: String) -> Bool {
        let l = w.lowercased()
        return matching(allPrefixes, l) != nil || (w.hasPrefix("-") && w.count > 1)
    }

    // MARK: - Préfixes (dont les alias anglais du lot MP1)

    /// Filtre de racine : `dossier:` et son alias anglais.
    static let folderPrefixes = ["dossier:", "folder:"]
    /// Filtre d'extension. Une seule forme : le mot est le même dans les deux
    /// langues.
    static let extPrefixes = ["ext:"]
    /// Proximité : `pres:` et son alias anglais — celui que l'aide en anglais
    /// annonçait alors que le moteur le refusait (PR-03).
    static let proximityPrefixes = ["pres:", "near:"]
    /// Le NOM du document seulement (lot QP1) : `docs_fts`, jamais les pages.
    static let namePrefixes = ["nom:", "name:"]
    /// Le TEXTE des pages seulement (lot QP1) : un mot ordinaire, sans le
    /// bonus ni le bandeau du nom de fichier.
    static let bodyPrefixes = ["texte:", "body:"]
    /// Le CHEMIN COMPLET du document (lot MC1), répertoires compris : il
    /// contient la valeur, casse et accents ignorés.
    static let pathPrefixes = ["chemin:", "path:"]

    /// Les quatre filtres qui s'excluent (lot MC1). Ni `pres:` — la proximité
    /// n'est pas un ensemble de documents —, ni `texte:`, dont le négatif
    /// s'écrit déjà `-mot`.
    ///
    /// TOUT FILTRE DE DOCUMENT DE LA GRAMMAIRE S'EXCLUT (décision du
    /// 14/09/2026, lot MN1) : ces quatre-là SONT les filtres de document du
    /// langage tapé, et les deux qui n'y sont pas ne désignent pas un ensemble
    /// de documents. La langue et la date se demandent par option
    /// (`--lang`, `--since`), pas par préfixe ; `type:` n'existe pas (c'est
    /// `ext:`, et `type:pdf` est refusé par `unknownPrefix`). Un préfixe de la
    /// liste ci-dessous qui n'est pas ici se refuse donc en nommant la règle,
    /// plutôt que d'exclure une phrase que personne n'a demandée.
    static let excludablePrefixes = folderPrefixes + extPrefixes + namePrefixes
        + pathPrefixes

    /// Ce que le refus d'une exclusion impossible énumère : les paires d'alias
    /// des quatre filtres qui s'excluent, dans l'ordre de `knownPrefixLabels`.
    static let excludablePrefixLabels = ["dossier:/folder:", "ext:",
                                         "nom:/name:", "chemin:/path:"]

    /// Ce qu'une exclusion de filtre désigne.
    enum ExcludedFilter { case folder, ext, name, path }

    /// `-ext:md` lu comme une exclusion de FILTRE, ou `nil` quand le mot n'en
    /// est pas une (`-biologie`, `-10:30`). La valeur peut être vide
    /// (`-ext:` en cours de frappe) : le jeton est alors consommé sans effet,
    /// comme `ext:` seul.
    static func excludedFilter(_ raw: String) -> (kind: ExcludedFilter, value: String)? {
        guard raw.hasPrefix("-"), raw.count > 1 else { return nil }
        let bare = String(raw.dropFirst())
        let lower = bare.lowercased()
        let table: [([String], ExcludedFilter)] = [
            (folderPrefixes, .folder), (extPrefixes, .ext),
            (namePrefixes, .name), (pathPrefixes, .path),
        ]
        for (list, kind) in table {
            guard let prefix = matching(list, lower) else { continue }
            return (kind, unquoted(String(bare.dropFirst(prefix.count))))
        }
        return nil
    }

    /// Tous les préfixes du langage de requête, alias compris. PUBLIC : les
    /// trois surfaces qui retirent les filtres d'une requête avant de
    /// l'envoyer au modèle sémantique (CLI, application, serveur MCP) lisaient
    /// chacune leur propre liste de trois jetons — l'alias `folder:` serait
    /// resté dans le texte encodé.
    public static let allPrefixes = folderPrefixes + extPrefixes + proximityPrefixes
        + namePrefixes + bodyPrefixes + pathPrefixes

    /// Ce que le refus d'un faux filtre énumère : les paires d'alias, pas dix
    /// jetons — l'utilisateur doit voir qu'il a le choix de la langue.
    static let knownPrefixLabels = ["dossier:/folder:", "ext:", "pres:/near:",
                                    "nom:/name:", "texte:/body:", "chemin:/path:"]

    /// Le préfixe de `list` que porte ce mot DÉJÀ EN MINUSCULES, ou nil.
    static func matching(_ list: [String], _ lowercased: String) -> String? {
        list.first { lowercased.hasPrefix($0) }
    }

    /// Refuse `type:pdf` — un mot de la forme `<lettres>:<valeur>` dont le
    /// préfixe n'est pas un filtre (PR-04).
    ///
    /// TROIS EXCLUSIONS, mesurées sur ce que les gens tapent : une URL
    /// (`https://…` — la valeur commence par `//`), une heure (`10:30` — des
    /// chiffres avant le deux-points, la règle exige des LETTRES), et une seule
    /// lettre (`t:` peut être une notation, pas une tentative de filtre). Une
    /// valeur vide ne dit rien non plus : `type:` seul est peut-être en cours de
    /// frappe. Le mot entre guillemets échappe à tout : `"Chapitre:3"` se
    /// cherche tel quel.
    public static func unknownPrefix(in word: String) -> String? {
        guard !word.hasPrefix("-"), let colon = word.firstIndex(of: ":") else { return nil }
        let head = word[word.startIndex..<colon]
        guard head.count >= 2, head.allSatisfy({ $0.isLetter }) else { return nil }
        let value = word[word.index(after: colon)...]
        guard !value.isEmpty, !value.hasPrefix("/") else { return nil }
        let prefix = String(head).lowercased() + ":"
        guard !allPrefixes.contains(prefix) else { return nil }
        return prefix
    }

    private static func checkPrefix(_ raw: String) throws {
        if let prefix = unknownPrefix(in: raw) {
            throw QueryError.unknownPrefix(prefix, known: knownPrefixLabels)
        }
    }

    /// Refuse une exclusion qui a la FORME d'un filtre sans en être une (lot
    /// MN1). Appelée au tout dernier moment, quand `-mot` va devenir une
    /// négation : les quatre exclusions de filtres sont déjà parties par
    /// `excludedFilter`.
    ///
    /// Deux refus, dans cet ordre :
    ///   · un préfixe CONNU qui ne s'exclut pas (`-texte:azote`, `-pres:5`) :
    ///     la proximité n'est pas un ensemble de documents, et le négatif de
    ///     `texte:mot` s'écrit `-mot` ;
    ///   · un préfixe INCONNU (`-type:pdf`), par la règle exacte de sa forme
    ///     positive — d'où la lecture sur le mot NU, `unknownPrefix` écartant
    ///     tout ce qui commence par un tiret.
    ///
    /// DEUX ERREURS DISTINCTES depuis le lot MN2. MN1 levait `unknownPrefix`
    /// pour les deux, faute de pouvoir traduire un cas neuf dans l'application
    /// (`LocalizedText.describe`, `switch` exhaustif) : « “-texte:” is not a
    /// filter » était vrai au mot près et trompeur sur le fond. Le premier
    /// refus porte maintenant `notExcludable`, qui nomme les préfixes qui
    /// S'EXCLUENT et le geste qui écarte un mot ; le second garde
    /// `unknownPrefix` et sa liste complète.
    ///
    /// Ce qui reste une exclusion de MOT n'est pas touché : `-biologie`,
    /// `-10:30` (des chiffres), `-https://exemple.org` (la valeur commence par
    /// une barre), `-t:x` (une seule lettre).
    private static func checkExclusion(_ raw: String) throws {
        let bare = String(raw.dropFirst())
        if let prefix = matching(allPrefixes, bare.lowercased()) {
            throw QueryError.notExcludable(prefix,
                                           excludable: excludablePrefixLabels)
        }
        try checkPrefix(bare)
    }

    // MARK: - Montants (C2-12)

    /// Les deux écritures d'un montant, ou nil quand le terme n'en est pas un.
    ///
    /// POURQUOI SEULEMENT LES MONTANTS À DÉCIMALE. Le document porte « 1 512,50 »
    /// (espace fine insécable des documents français) et le tokenizer en fait
    /// `1` et `512,50` ; qui tape le montant sans l'espace — ce que rend son
    /// application bancaire — n'avait rien (C2-12). Un nombre ENTIER, lui, ne se
    /// prête pas à ce rattrapage : `2003` deviendrait `"2 003"`, et une année
    /// est le nombre le plus tapé de tous. La décimale est donc la marque du
    /// montant, dans les deux sens de lecture.
    static func amountVariants(_ term: String) -> (compact: String, grouped: String)? {
        let parts = term.split(separator: " ", omittingEmptySubsequences: false)
            .map(String.init)
        // Partie décimale : le dernier morceau porte `,dd` ou `.dd`.
        guard let last = parts.last,
              let separator = last.first(where: { $0 == "," || $0 == "." }),
              last.filter({ $0 == "," || $0 == "." }).count == 1 else { return nil }
        let split = last.split(separator: separator, omittingEmptySubsequences: false)
        guard split.count == 2, !split[1].isEmpty,
              split[1].allSatisfy(\.isNumber) else { return nil }
        let decimals = String(split[1])
        var digitGroups = parts.dropLast().map { $0 } + [String(split[0])]
        guard digitGroups.allSatisfy({ !$0.isEmpty && $0.allSatisfy(\.isNumber) })
        else { return nil }
        if digitGroups.count > 1 {
            // Forme groupée tapée : 1-3 chiffres puis des tranches de 3.
            guard digitGroups[0].count <= 3,
                  digitGroups.dropFirst().allSatisfy({ $0.count == 3 }) else { return nil }
        } else {
            // Forme compacte : au moins quatre chiffres avant la décimale,
            // sinon il n'y a pas de tranche de milliers à écrire.
            guard digitGroups[0].count >= 4 else { return nil }
            digitGroups = thousandGroups(digitGroups[0])
        }
        let compact = digitGroups.joined() + String(separator) + decimals
        let grouped = digitGroups.joined(separator: " ") + String(separator) + decimals
        return (compact, grouped)
    }

    /// « 1512 » -> [« 1 », « 512 »]. L'espace des milliers du document peut être
    /// fine, insécable ou ordinaire : `unicode61` les traite toutes en
    /// séparateur (vérifié le 10/09/2026), une phrase FTS5 à espace ordinaire
    /// apparie donc les trois.
    private static func thousandGroups(_ digits: String) -> [String] {
        var groups: [String] = []
        var rest = Array(digits)
        while rest.count > 3 {
            groups.insert(String(rest.suffix(3)), at: 0)
            rest.removeLast(3)
        }
        groups.insert(String(rest), at: 0)
        return groups
    }

    /// Recolle `1` + `512,50` en « 1 512,50 » et avance l'index sur les jetons
    /// consommés ; nil quand la suite n'est pas un montant groupé.
    private static func joinedAmount(_ raw: String, tokens: [Token],
                                     index i: inout Int) -> String? {
        guard raw.count <= 3, !raw.isEmpty, raw.allSatisfy(\.isNumber) else { return nil }
        var parts = [raw]
        var j = i
        while j < tokens.count, case .word(let w) = tokens[j] {
            if w.count == 3, w.allSatisfy(\.isNumber) {
                parts.append(w)
                j += 1
                continue
            }
            // Dernière tranche : trois chiffres et la décimale.
            if w.count >= 5, let dot = w.firstIndex(where: { $0 == "," || $0 == "." }),
               w.distance(from: w.startIndex, to: dot) == 3,
               amountVariants(parts.joined(separator: " ") + " " + w) != nil {
                parts.append(w)
                j += 1
                i = j
                return parts.joined(separator: " ")
            }
            break
        }
        return nil
    }

    /// Les espaces du bord sont rognées, comme celles d'une phrase : la
    /// typographie française écrit `dossier:« Mes cours »`, espaces comprises
    /// à l'intérieur des guillemets (lot QP1).
    private static func unquoted(_ s: String) -> String {
        var v = s
        if v.hasPrefix("\"") { v.removeFirst() }
        if v.hasSuffix("\"") { v.removeLast() }
        return v.trimmingCharacters(in: .whitespaces)
    }

    /// Les guillemets TYPOGRAPHIQUES deviennent le guillemet droit, l'apostrophe
    /// courbe l'apostrophe droite (lot QP1).
    ///
    /// macOS remplace par défaut les guillemets tapés dans un champ de texte
    /// par des guillemets typographiques : `“gaz parfait”` et
    /// `« catalyse »` n'étaient pas des phrases, mais des mots flanqués de
    /// caractères que personne ne voit — et le canal sémantique, que la phrase
    /// éteint (RK-01), restait allumé. L'apostrophe n'a pas d'effet sur FTS5
    /// (le tokenizer coupe aux deux) ; c'est l'égalité de traitement qui compte,
    /// pour qu'un `l’azote` tapé soit la même requête qu'un `l'azote`.
    ///
    /// PUBLIC : le diagnostic de frappe de l'application compte les guillemets
    /// ouverts sur le même texte que celui que l'analyseur lira. Rien d'autre
    /// n'est normalisé.
    public static func normalizingQuotes(_ input: String) -> String {
        guard input.contains(where: { typographicQuotes.contains($0) || $0 == "’" })
        else { return input }
        return String(input.map { ch -> Character in
            if typographicQuotes.contains(ch) { return "\"" }
            return ch == "’" ? "'" : ch
        })
    }

    /// `“ ” „ ‟ « » ″` : ouvrants et fermants confondus, l'analyseur alterne.
    static let typographicQuotes: Set<Character> = [
        "\u{201C}", "\u{201D}", "\u{201E}", "\u{201F}", "\u{00AB}", "\u{00BB}", "\u{2033}",
    ]

    // MARK: - Découpage

    private enum Token {
        case word(String)
        case quoted(String)
    }

    /// Les préfixes dont la VALEUR peut être entre guillemets (audit A1m-04) —
    /// alias anglais compris : `folder:"Mes cours"` filtre comme
    /// `dossier:"Mes cours"`.
    static let valuePrefixes = allPrefixes + excludablePrefixes.map { "-" + $0 }

    private static func tokenize(_ input: String) -> [Token] {
        var tokens: [Token] = []
        var current = ""
        var inQuotes = false
        /// Vrai quand les guillemets qui s'ouvrent sont ceux de la VALEUR d'un
        /// filtre — `dossier:"Mes cours"` (audit A1m-04). Sans cette distinction,
        /// le guillemet coupait le mot : `dossier:` partait seul (valeur vide,
        /// donc AUCUN filtre) et l'étiquette devenait une phrase à chercher. Un
        /// dossier dont l'étiquette porte une espace — le cas de tout
        /// « Mes cours » ou « Travaux dirigés », et l'étiquette par défaut est
        /// le dernier segment du chemin — était donc INFILTRABLE, sans le
        /// moindre message : la facette « Dossiers » l'affichait et la requête
        /// rendait zéro résultat.
        var quotingValue = false
        // Une fois, ici : `parse`, `asksForExactPhrase`, `semanticText` et les
        // valeurs de filtres voient tous le même texte — GUILLEMETS normalisés
        // et forme NFC (lot MC1). La base est en NFC (`migration_v7_nfc`) et le
        // Finder rend du NFD : sans cette recomposition, `chemin:Polymères`
        // collé depuis `ls` ne trouvait rien, tapé au clavier il trouvait.
        for ch in normalizingQuotes(input).precomposedStringWithCanonicalMapping {
            if ch == "\"" {
                if inQuotes {
                    if quotingValue {
                        quotingValue = false          // la valeur continue
                    } else {
                        tokens.append(.quoted(current))
                        current = ""
                    }
                    inQuotes = false
                } else {
                    if Self.valuePrefixes.contains(current.lowercased()) {
                        quotingValue = true
                    } else if !current.isEmpty {
                        tokens.append(.word(current))
                        current = ""
                    }
                    inQuotes = true
                }
            } else if ch.isWhitespace && !inQuotes {
                if !current.isEmpty { tokens.append(.word(current)); current = "" }
            } else {
                current.append(ch)
            }
        }
        if !current.isEmpty {
            // Un guillemet jamais refermé APRÈS un préfixe reste une valeur de
            // filtre, pas une phrase : `dossier:"Mes cours` filtre quand même.
            tokens.append(inQuotes && !quotingValue ? .quoted(current)
                                                    : .word(current))
        }
        return tokens
    }
}
