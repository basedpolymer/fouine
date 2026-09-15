// HitExplanation.swift — POURQUOI cette page est dans les résultats.
// Propriété : A-Core. Idée F2 de l'audit A2 du 04/09/2026, lot U1 (R-06).
//
// Tout était déjà calculé — `Hit.fuzzyDistance`, `HybridHit.lexRank` /
// `vecRank`, les termes de la requête — et rien ne le DISAIT : ces valeurs
// vivaient dans des infobulles que personne ne survole, et dans un JSON que
// seul un agent lit. Une page trouvée par le seul canal sémantique était même
// indiscernable d'une page contenant les mots, sinon par un insigne « ≈ ».
//
// CE FICHIER NE LIT PAS LA BASE, et c'est la condition pour qu'il soit
// testable : l'appelant apporte le texte (celui de la page pour l'application,
// l'extrait pour la CLI et le serveur MCP — voir `docs/cli.md`, et le paramètre
// `textIsWholePage`, qui interdit de conclure à un manque depuis un extrait).
// Il ne rend pas
// non plus de phrase : une phrase serait anglaise, et l'application doit dire
// la sienne, traduite et sans jargon. Il rend un CAS, que chaque surface habille
// (`HitExplanationText` côté app, l'objet `why` côté JSON).
//
// LA RÈGLE DES MOTS. Ce sont des JETONS qui sont confrontés au texte, aux mêmes
// frontières que le tokenizer de l'index (`unicode61 remove_diacritics 2` :
// tout ce qui n'est ni lettre ni chiffre coupe, l'apostrophe comprise), et
// repliés de la même façon — « énergie » trouve « energie », « Chimie » trouve
// « chimie ». Chercher des SOUS-CHAÎNES ferait dire « cette page contient
// “or” » pour une page qui ne porte que « sort » (le piège de l'audit A2-17,
// déjà payé une fois côté surlignage).

import Foundation

/// Un mot de la requête, tel qu'il a été TAPÉ (c'est celui qu'on cite à
/// l'utilisateur) et avec la façon dont il se confronte au texte.
public struct QueryWord: Sendable, Equatable, Hashable {
    public enum Kind: Sendable, Equatable, Hashable {
        /// Mot nu, ou membre d'un `pres:N` : un jeton entier.
        case word
        /// `"gaz parfait"` : une suite de jetons contigus.
        case phrase
        /// `spectro*` : un jeton qui COMMENCE par la racine.
        case prefix
    }

    public let text: String
    public let kind: Kind
    /// Les autres formes du mot que l'index a cherchées EN MÊME TEMPS (lot R1,
    /// `Morphology` : `polymere` → `polymeres`), repliées. Une page qui porte
    /// l'une d'elles porte le mot ; c'est toujours le mot TAPÉ qui est cité.
    /// Vides pour une phrase ou un préfixe, que l'index ne décline pas.
    public let variants: [String]

    public init(_ text: String, kind: Kind = .word, variants: [String]? = nil) {
        self.text = text
        self.kind = kind
        self.variants = variants ?? (kind == .word ? Morphology.variants(of: text) : [])
    }
}

/// Pourquoi une page est là. Une ÉNUMÉRATION, pas une chaîne : les phrases sont
/// l'affaire des surfaces, et une phrase anglaise dans le cœur finirait
/// affichée telle quelle quelque part (c'est ce que `LocalizedText` interdit).
public enum HitExplanation: Sendable, Equatable {
    /// Tous les mots de la requête sont sur la page.
    case exact(terms: [String])
    /// Une partie seulement. `missing` est ce qui manque, et le dire est le
    /// but : une liste plus courte que prévu reste sinon inexplicable.
    case partial(found: [String], missing: [String])
    /// Le mot tapé n'est pas sur la page, mais un mot très proche y est
    /// (§5.5.2). `distance` est le nombre de lettres qui les séparent.
    case fuzzy(typed: String, found: String, distance: Int)
    /// Aucun mot de la requête n'est sur la page : elle vient du seul canal
    /// sémantique (§12).
    case semanticOnly
    /// Les deux canaux ont trouvé cette page.
    case both(terms: [String])

    /// L'étiquette du cas dans le JSON de `fouine search` et de `fouine_search`.
    public var kindLabel: String {
        switch self {
        case .exact:        return "exact"
        case .partial:      return "partial"
        case .fuzzy:        return "fuzzy"
        case .semanticOnly: return "semantic"
        case .both:         return "both"
        }
    }
}

// MARK: - Construction

extension HitExplanation {

    /// Longueur minimale d'un mot pour qu'on lui cherche une variante
    /// orthographique. C'est le plafond du §5.5.2 : sous six lettres, l'index
    /// n'expanse RIEN, et prétendre le contraire ferait dire « trouvé par une
    /// orthographe proche : “or” → “ou” ».
    static let minFuzzyLength = 6

    /// Le cas de cette page, ou `nil` quand il n'y a rien d'honnête à dire —
    /// requête sans mot, ou texte où aucun terme ne se retrouve (une page
    /// appariée par un `pres:` dont l'extrait ne porte pas les deux mots, par
    /// exemple). Mieux vaut pas de phrase qu'une phrase fausse.
    ///
    /// - Parameters:
    ///   - words: les mots POSITIFS de la requête ; les `-terme` n'y sont pas
    ///     (voir `words(of:)`), et ne doivent jamais être cités : ce serait
    ///     désigner à l'utilisateur exactement ce qu'il a demandé d'écarter.
    ///   - text: le texte de la page, ou à défaut l'extrait.
    ///   - fuzzyDistance: `Hit.fuzzyDistance` (0 = correspondance exacte).
    ///   - lexRank, vecRank: les rangs de la fusion RRF (§12) ; tous deux `nil`
    ///     en recherche plein texte, où la question ne se pose pas.
    ///   - textIsWholePage: `text` est-il TOUTE la page, ou seulement un
    ///     extrait ? Sur un extrait, l'absence d'un mot ne prouve rien, et le
    ///     mesurer l'a montré tout de suite : `fouine search 'cinetique
    ///     reticulation' --json` sur la base de production annonçait
    ///     « “cinetique” n'est pas sur cette page » pour une page que FTS5
    ///     avait appariée sur les DEUX mots — l'extrait n'en montrait qu'un.
    ///     Or un hit lexical porte forcément tous les mots positifs : c'est ce
    ///     que `a AND b` veut dire. On ne conclut donc à un manque que quand
    ///     l'appelant a lu la page entière (l'application), et l'extrait sert
    ///     alors seulement à nommer une variante orthographique.
    ///   - quorum: ce résultat vient-il d'une passe de QUORUM
    ///     (`SearchResults.quorum`, lot RK2) ? Alors le raisonnement
    ///     « un hit lexical porte tous les mots » est FAUX par construction —
    ///     l'expression relâchée est un OR de sous-ensembles — et l'explication
    ///     ne peut plus être « exacte » (constat PM-14 : une page qui portait
    ///     trois mots sur neuf rendait `kind: "exact"` avec les neuf).
    public init?(words: [QueryWord], text: String, fuzzyDistance: Int = 0,
                 lexRank: Int? = nil, vecRank: Int? = nil,
                 textIsWholePage: Bool = true, quorum: Bool = false) {
        // Canal sémantique pur : le texte n'a par définition aucun des mots, il
        // est inutile de le parcourir pour le constater.
        if lexRank == nil, vecRank != nil {
            self = .semanticOnly
            return
        }
        let words = Self.deduplicated(words)
        guard !words.isEmpty else { return nil }

        let tokens = Self.tokens(of: text)
        var found: [String] = []
        var missing: [String] = []
        for word in words {
            if Self.contains(tokens, word) { found.append(word.text) }
            else { missing.append(word.text) }
        }

        // L'orthographe proche passe AVANT le reste : c'est la seule
        // explication qui apprend quelque chose à qui relit sa requête et n'y
        // voit pas sa faute de frappe.
        if fuzzyDistance > 0,
           let close = Self.closest(to: missing, among: tokens,
                                    maxDistance: fuzzyDistance) {
            self = .fuzzy(typed: close.typed, found: close.found,
                          distance: close.distance)
            return
        }
        if !textIsWholePage {
            // Le hit est lexical (le cas sémantique pur est sorti plus haut) :
            // FTS5 a apparié TOUS les nœuds positifs sur cette page. Ce que
            // l'extrait ne montre pas n'est donc pas absent.
            //
            // Sauf si la requête a été expansée : le mot a pu n'être apparié
            // que par une variante, et si l'extrait ne permet pas de nommer
            // laquelle (le cas `fuzzy` ci-dessus), on se tait plutôt que
            // d'affirmer que le mot tapé est là.
            if fuzzyDistance > 0 { return nil }
            // QUORUM (PM-14) : la page ne porte PAS forcément tous les mots.
            // On cite ceux que l'extrait montre, et on ne conclut à aucun
            // manque — un extrait ne prouve pas une absence.
            if quorum {
                self = .partial(found: found, missing: [])
                return
            }
            let all = words.map(\.text)
            self = vecRank != nil ? .both(terms: all) : .exact(terms: all)
            return
        }
        if lexRank != nil, vecRank != nil {
            self = .both(terms: found)
            return
        }
        guard !found.isEmpty else { return nil }
        self = missing.isEmpty ? .exact(terms: found)
                               : .partial(found: found, missing: missing)
    }

    /// Les mots POSITIFS d'une requête analysée : mots nus, membres de `pres:`,
    /// phrases et racines de préfixe. Les exclusions sont écartées.
    public static func words(of parsed: ParsedQuery) -> [QueryWord] {
        // Les formes d'un mot nu sont celles que le moteur a cherchées : parmi
        // les autres mots nus (`Morphology.variants(of:among:)`, AUDIT-R1 B1).
        // Un membre de `pres:` n'en a aucune — FTS5 n'accepte pas de OR dans
        // un NEAR, le moteur ne le décline pas, l'explication non plus
        // (AUDIT-R1 M1 ; c'est aussi le choix du surlignage).
        let bare = parsed.nodes.compactMap { node -> String? in
            if case .term(let t) = node { return t }
            return nil
        }
        var out: [QueryWord] = []
        for node in parsed.nodes {
            switch node {
            case .term(let t):
                out.append(QueryWord(t, variants: Morphology.variants(of: t, among: bare)))
            case .phrase(let p):          out.append(QueryWord(p, kind: .phrase))
            case .prefix(let p):          out.append(QueryWord(p, kind: .prefix))
            case .near(let members, _):
                out.append(contentsOf: members.map { QueryWord($0, variants: []) })
            case .not:                    break
            }
        }
        return out
    }

    /// Idem depuis la saisie brute. Une requête que l'analyseur refuse n'a pas
    /// de mots : elle n'a de toute façon pas de résultat à expliquer.
    public static func words(ofQuery input: String) -> [QueryWord] {
        guard let parsed = try? QueryParser.parse(input) else { return [] }
        return words(of: parsed)
    }

    /// L'objet `why` du JSON de `fouine search --json` et de `fouine_search`.
    /// UNE seule fabrique pour les deux surfaces : deux copies d'une même forme
    /// avaient déjà commencé à diverger ailleurs dans ce dépôt (§4.3).
    /// Les clés sans objet sont ABSENTES — un `terms_missing` vide sur un
    /// `exact` se lirait comme une information.
    ///
    /// `tableOfContents` (lot RK2, RK-07) : cette page est une table des
    /// matières ou un index, et le malus l'a reculée. Un CAS N'AURAIT PAS
    /// CONVENU — la page reste « exacte » ou « partielle », c'est la RAISON de
    /// son rang qui s'ajoute —, et une case de plus dans l'énumération aurait
    /// obligé chaque surface à réécrire son `switch` pour une note qui ne
    /// remplace rien. La clé est ABSENTE quand la page n'en est pas une, comme
    /// `terms_missing` sur un `exact`.
    public static func json(_ explanation: HitExplanation,
                            tableOfContents: Bool = false) -> [String: Any] {
        var out: [String: Any] = ["kind": explanation.kindLabel]
        if tableOfContents { out["table_of_contents"] = true }
        switch explanation {
        case .exact(let terms), .both(let terms):
            if !terms.isEmpty { out["terms_found"] = terms }
        case .partial(let found, let missing):
            out["terms_found"] = found
            // ABSENTE quand rien n'est prouvé manquant (quorum sur un extrait,
            // PM-14) : une liste vide se lirait comme « aucun mot ne manque ».
            if !missing.isEmpty { out["terms_missing"] = missing }
        case .fuzzy(let typed, let found, let distance):
            out["typed"] = typed
            out["found"] = found
            out["distance"] = distance
        case .semanticOnly:
            break
        }
        return out
    }

    // MARK: - Jetons

    /// Repliement de casse et d'accents, celui du tokenizer de l'index.
    ///
    /// `en_US_POSIX` et non la locale de l'utilisateur : le repliement doit
    /// être celui de `page_fts`, qui ne connaît aucune locale, et donner le
    /// même résultat quel que soit le Mac (même arbitrage que
    /// `TrigramExpander.normalize` et `StoreService.fold`).
    static func fold(_ s: String) -> String {
        s.folding(options: [.diacriticInsensitive, .caseInsensitive],
                  locale: Locale(identifier: "en_US_POSIX"))
    }

    /// Découpage aux frontières du tokenizer : tout ce qui n'est ni lettre ni
    /// chiffre coupe. Les jetons rendus sont déjà repliés.
    static func tokens(of text: String) -> [String] {
        var out: [String] = []
        var current = ""
        for ch in text {
            if ch.isLetter || ch.isNumber {
                current.append(ch)
            } else if !current.isEmpty {
                out.append(fold(current))
                current = ""
            }
        }
        if !current.isEmpty { out.append(fold(current)) }
        return out
    }

    /// Deux fois le même mot dans une requête (« azote azote », ou un mot nu
    /// répété dans un `pres:`) ne se cite qu'une fois. La comparaison porte sur
    /// la forme repliée ET sur le genre : `spectro` et `spectro*` ne sont pas
    /// le même mot.
    private static func deduplicated(_ words: [QueryWord]) -> [QueryWord] {
        var seen = Set<String>()
        return words.filter { word in
            let trimmed = word.text.trimmingCharacters(in: .whitespaces)
            guard !trimmed.isEmpty else { return false }
            return seen.insert("\(word.kind)\u{1}\(fold(trimmed))").inserted
        }
    }

    /// Le mot est-il sur la page ?
    private static func contains(_ pageTokens: [String], _ word: QueryWord) -> Bool {
        let needle = fold(word.text)
        guard !needle.isEmpty else { return false }
        switch word.kind {
        case .word:
            // Le mot tapé, ou l'une des formes cherchées avec lui : la page
            // « polymères » porte bien le mot « polymere » de la requête.
            return pageTokens.contains(needle)
                || word.variants.contains { pageTokens.contains($0) }
        case .prefix:
            return pageTokens.contains { $0.hasPrefix(needle) }
        case .phrase:
            // Une phrase est une suite de jetons CONTIGUS : c'est ce que
            // `"gaz parfait"` demande à FTS5, et une recherche de sous-chaîne
            // dirait « présente » pour un texte qui porte les deux mots à dix
            // lignes d'écart.
            let members = tokens(of: word.text)
            guard !members.isEmpty, members.count <= pageTokens.count else {
                return false
            }
            for start in 0...(pageTokens.count - members.count) {
                if Array(pageTokens[start..<(start + members.count)]) == members {
                    return true
                }
            }
            return false
        }
    }

    /// Le couple (mot tapé, mot de la page) le plus proche parmi les mots
    /// absents, à `maxDistance` lettres au plus.
    ///
    /// On cherche la variante DANS LA PAGE plutôt que de rejouer l'expansion de
    /// `TrigramExpander` : celle-ci lit la base — ce fichier ne le fait pas —
    /// et rendrait de toute façon des voisins dont rien ne dit qu'ils sont sur
    /// CETTE page. Le mot cité doit être celui que l'utilisateur va voir dans
    /// l'extrait.
    private static func closest(to missing: [String], among tokens: [String],
                                maxDistance: Int)
        -> (typed: String, found: String, distance: Int)? {
        let cap = max(1, min(maxDistance, 2))   // plafond du §5.5.2
        var best: (typed: String, found: String, distance: Int)?
        var scratch = LevenshteinScratch(capacity: 64)
        for typed in missing {
            let folded = fold(typed)
            // Sous six lettres, l'index n'expanse pas : aucune variante à
            // annoncer, et une paire trouvée ici serait un mensonge.
            guard folded.unicodeScalars.count >= minFuzzyLength else { continue }
            let source = Array(folded.unicodeScalars.map(\.value))
            for token in tokens where token != folded {
                guard abs(token.unicodeScalars.count - source.count) <= cap else {
                    continue
                }
                let target = Array(token.unicodeScalars.map(\.value))
                guard let d = scratch.distance(source, target, maxDistance: cap),
                      d > 0 else { continue }
                if best == nil || d < best!.distance {
                    best = (typed: typed, found: token, distance: d)
                }
                if d == 1 { break }   // on ne fera pas mieux pour ce mot
            }
        }
        return best
    }
}
