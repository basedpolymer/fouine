// HybridSearch.swift — fusion RRF de la recherche lexicale (FTS5, §4.1/§5.5)
// et de la recherche vectorielle (page_vec, §12). Propriété : A-Embed.
//
// Le chemin lexical est INCHANGÉ (contrat IndexStore gelé) : l'hybride est une
// couche au-dessus. Les filtres de la requête (dossier:, ext:, --in, -exclus)
// s'appliquent aussi aux hits vectoriels, par ensemble de documents autorisés.
// Un hit sémantique pur (aucun terme ne matche) n'a pas de snippet() possible :
// il est présenté par le début du texte de sa page.

import Foundation
import FouineCore

public struct HybridHit: Sendable {
    public let docID: Int64
    public let page: Int
    public let path: String
    /// Score RRF fusionné (décroissant).
    public let rrf: Double
    /// Rangs d'origine (1-indexés), nil si absent de la liste.
    public let lexRank: Int?
    public let vecRank: Int?
    /// Cosinus approché requête·page quand la page vient du canal vectoriel.
    ///
    /// CE N'EST PAS UNE PERTINENCE. Sur ce corpus tous les cosinus d'e5-small
    /// vivent entre 0,78 et 0,88, et la position dans cette bande suit la forme
    /// de la requête plus que son sujet (audit C2-01). Il est conservé parce
    /// qu'un appelant peut vouloir la valeur brute ; ce qui se lit et
    /// s'affiche, c'est `z`.
    public let cosine: Float?
    /// Marge du hit dans la population balayée par cette requête,
    /// `(cos − μ) / σ`. Nil quand la page ne vient pas du canal vectoriel.
    public let z: Double?
    /// Hit lexical (snippet réel, source, distance floue) si la page a aussi
    /// été trouvée par FTS ; nil pour un hit sémantique pur.
    public let lexical: Hit?
    /// Début du texte de la page, pour les hits sémantiques purs.
    public let preview: String

    /// PUBLIC pour les doubles des autres modules (lot MN2) : l'application
    /// prouve `semanticPending` autour d'une fusion qui rend de vraies pages,
    /// et l'initialiseur implicite d'une structure publique reste interne.
    public init(docID: Int64, page: Int, path: String, rrf: Double,
                lexRank: Int?, vecRank: Int?, cosine: Float?, z: Double?,
                lexical: Hit?, preview: String) {
        self.docID = docID
        self.page = page
        self.path = path
        self.rrf = rrf
        self.lexRank = lexRank
        self.vecRank = vecRank
        self.cosine = cosine
        self.z = z
        self.lexical = lexical
        self.preview = preview
    }
}

/// Statistiques du canal vectoriel pour UNE recherche. Ce n'est pas un
/// échafaudage de mise au point : c'est l'outil de calibration du plancher, et
/// il est exposé tel quel dans le JSON de `fouine search --hybrid --json`
/// (objet `semantic_stats`).
///
/// Le cosinus brut d'e5-small ne dit rien tout seul (audit C2-01) ; ce qui a un
/// sens est sa position dans la population balayée par CETTE requête, d'où
/// `mu`, `sigma`, et les marges `z` à trois profondeurs.
public struct SemanticStats: Sendable {
    /// Cosinus moyen sur les vecteurs non nuls balayés.
    public let mu: Double
    /// Écart-type des mêmes cosinus.
    public let sigma: Double
    /// Meilleur cosinus rendu par le balayage (nil si l'index n'a rien rendu).
    public let cosMax: Float?
    /// Marge du meilleur hit, `(cos − μ) / σ`.
    public let zMax: Double?
    /// Marge du 10ᵉ hit vectoriel, nil s'il n'y en a pas dix.
    public let zAt10: Double?
    /// Marge du 200ᵉ hit vectoriel, nil s'il n'y en a pas deux cents.
    public let zAt200: Double?
    /// FENÊTRES non nulles comparées (schéma v5 : une page en porte jusqu'à
    /// trois — les moments portent sur la population réellement balayée).
    public let scanned: Int
    /// Fenêtres nulles rencontrées, exclues des moments (texte trop court).
    public let zeroVectors: Int

    public init(mu: Double, sigma: Double, cosMax: Float?, zMax: Double?,
                zAt10: Double?, zAt200: Double?, scanned: Int, zeroVectors: Int) {
        self.mu = mu
        self.sigma = sigma
        self.cosMax = cosMax
        self.zMax = zMax
        self.zAt10 = zAt10
        self.zAt200 = zAt200
        self.scanned = scanned
        self.zeroVectors = zeroVectors
    }
}

/// Pourquoi le canal sémantique n'a PAS été consulté alors qu'il était
/// disponible. Une énumération, et non un booléen : le jour où une seconde
/// raison apparaît (une requête sans mot encodable, par exemple), les trois
/// surfaces qui la publient n'ont qu'un cas à ajouter.
///
/// La valeur brute est celle publiée par la CLI (`hybrid_disarmed`) et le
/// serveur MCP : c'est un contrat, pas un libellé.
public enum SemanticDisarmReason: String, Sendable {
    /// La requête porte au moins une phrase entre guillemets (RK-01) : le
    /// canal sémantique n'a pas de guillemets et versait au RRF des pages qui
    /// ne portent pas l'expression demandée.
    case exactPhrase = "exact_phrase"

    /// AUCUNE page du périmètre demandé ne porte de vecteur (lot MC2, constat
    /// PM-06). Mesuré le 13/09/2026 : `dossier:M2SU` en mode hybride chargeait
    /// le modèle (2,3 s) et l'index vectoriel (1,9 s) pour comparer ZÉRO
    /// vecteur, puis annonçait la couverture GLOBALE (67,85 %) d'un dossier
    /// couvert à 0,00 % — six secondes de mur pour une réponse lexicale qui ne
    /// disait pas qu'elle l'était. On ne charge donc plus rien, et on le DIT.
    case noVectorsInScope = "no_vectors_in_scope"

    /// La phrase ANGLAISE que la ligne de commande met sur l'erreur standard et
    /// que le serveur MCP pose dans `note`. Elle vit ici, avec la raison, et non
    /// dans `SearchAdvice` : c'est un fait du canal sémantique, dont ce module
    /// est le propriétaire, et deux surfaces qui la recopieraient finiraient par
    /// dire deux choses différentes. L'application, elle, la traduit.
    public var advice: String {
        switch self {
        case .exactPhrase:
            return "meaning search not used: the query asks for an exact phrase"
        case .noVectorsInScope:
            return "meaning search not used: no page in this scope carries a vector"
        }
    }

    /// LE PÉRIMÈTRE N'A PAS UN VECTEUR : les deux nombres et le geste.
    ///
    /// `advice` dit le FAIT, celle-ci dit LEQUEL et QUOI FAIRE — d'où deux
    /// phrases, et une seule publiée à la fois (une même limite dite deux fois
    /// se lit comme deux limites). Elle vit ici, avec la raison, pour la même
    /// raison qu'`advice` : la ligne de commande et le serveur MCP en portaient
    /// chacun une copie au mot près depuis le lot CL2, et deux copies d'une
    /// phrase chiffrée finissent par donner deux chiffres.
    ///
    /// `folders` : les racines demandées. Une seule nommée, la phrase la nomme
    /// et propose la campagne qui préparerait CE dossier ; plusieurs (ou aucune
    /// — un filtre d'extension, de nom, de date), elle parle du « périmètre »,
    /// parce qu'aucun mot plus précis ne serait vrai.
    public static func noVectorsInScopeNote(_ scope: SemanticScope,
                                            folders: [String]) -> String {
        let what = folders.count == 1 ? "folder \(folders[0])" : "this scope"
        let command = folders.count == 1
            ? "`fouine embed --folder \(folders[0])`" : "`fouine embed`"
        return "no vectorised page in this scope (\(what): 0 of "
            + "\(scope.pagesIndexed)) — \(command) prepares it"
    }
}

/// Ce que le canal du sens VOIT de la recherche demandée (lot MC2, PM-06).
///
/// Deux nombres et un drapeau, parce que les trois se lisent ensemble : « 0 sur
/// 31 986, filtré » est une phrase, « 67,85 % » n'en est pas une quand la
/// recherche porte sur un dossier qui n'a pas un vecteur. Sans filtre de
/// document, ce sont exactement les chiffres globaux — le coût est alors nul,
/// puisqu'il n'y a rien à recompter.
public struct SemanticScope: Sendable {
    /// Pages du périmètre qui portent un vecteur.
    public let vectors: Int
    /// Pages indexées du périmètre.
    public let pagesIndexed: Int
    /// Un filtre de document restreint-il le périmètre ? Faux = tout l'index.
    public let filtered: Bool

    public init(vectors: Int, pagesIndexed: Int, filtered: Bool) {
        self.vectors = vectors
        self.pagesIndexed = pagesIndexed
        self.filtered = filtered
    }

    /// Part des pages du périmètre que le canal du sens voit, en pourcentage.
    public var coveragePct: Double {
        pagesIndexed > 0 ? Double(vectors) * 100 / Double(pagesIndexed) : 0
    }
}

public struct HybridResults: Sendable {
    public let hits: [HybridHit]
    /// Totaux du canal lexical (sémantique = top-k, pas de total exhaustif).
    public let lexTotalPages: Int
    public let lexTotalDocs: Int
    /// Pages remontées par le seul canal vectoriel dans le top rendu.
    public let semanticOnly: Int
    public let elapsedMS: Double
    public let offset: Int
    public let hasMore: Bool
    public let modelLoadMS: Double?
    public let indexLoadMS: Double?
    /// Moments et marges du canal vectoriel pour cette requête (C2-01).
    public let semantic: SemanticStats
    /// Plancher de marge appliqué (0 = aucun).
    public let semanticFloor: Double
    /// Hits vectoriels retenus au-dessus du plancher, AVANT fusion.
    public let semanticKept: Int
    /// Couverture du canal sémantique : vecteurs chargés / pages indexées.
    public let vectors: Int
    public let pagesIndexed: Int
    /// Les deux mêmes nombres, RESTREINTS AU PÉRIMÈTRE de la requête (lot MC2,
    /// PM-06). Égaux aux précédents quand aucun filtre de document ne porte.
    public let scope: SemanticScope
    /// Échelle appliquée aux rangs sémantiques dans la fusion (lot R1,
    /// `HybridSearch.semanticRankScale`) ; 1 = aucune correction.
    public let semanticRankScale: Double
    /// Le canal sémantique n'a pas été consulté, et pourquoi (RK-01) ; `nil`
    /// quand il l'a été. Les hits sont alors le seul canal lexical.
    public let semanticDisarmed: SemanticDisarmReason?
    /// Le canal lexical n'a apparié AUCUNE page et a rejoué la requête en
    /// tolérant les fautes sur tout l'index (lot MP1, C2-08). Recopié tel quel
    /// du `SearchResults` lexical : le repli a lieu dans `GRDBStore.search`,
    /// que la fusion appelle — et il était vrai sans que l'hybride le dise.
    public let fuzzyFallback: Bool
    /// Le canal lexical de la fusion a rendu au moins une page portant une
    /// orthographe PROCHE du mot tapé (lot MC2, PM-13). Recopié de
    /// `SearchResults.fuzzyExpanded`, comme `fuzzyFallback` : le drapeau était
    /// vrai en hybride sans qu'aucune surface puisse le dire.
    public let fuzzyExpanded: Bool
    /// Le canal lexical de la fusion a relâché le ET (lot MC2, MC1 § « Pour
    /// MC2 ») : les pages rendues ne portent pas forcément tous les mots. Sans
    /// lui, `why` annonçait `exact` avec neuf mots sur une page qui en porte
    /// trois, dans ce mode comme dans l'autre.
    public let quorum: Bool

    /// Part des pages que le canal sémantique voit, en pourcentage. Un
    /// utilisateur à qui l'on dit « 64872 vectors » ne peut pas deviner que
    /// c'est 16,6 % de son corpus (audit C2-02).
    public var coveragePct: Double {
        pagesIndexed > 0 ? Double(vectors) * 100 / Double(pagesIndexed) : 0
    }

    public init(hits: [HybridHit],
                lexTotalPages: Int,
                lexTotalDocs: Int,
                semanticOnly: Int,
                elapsedMS: Double,
                offset: Int = 0,
                hasMore: Bool = false,
                modelLoadMS: Double? = nil,
                indexLoadMS: Double? = nil,
                semantic: SemanticStats = SemanticStats(
                    mu: 0, sigma: 0, cosMax: nil, zMax: nil, zAt10: nil,
                    zAt200: nil, scanned: 0, zeroVectors: 0),
                semanticFloor: Double = 0,
                semanticKept: Int = 0,
                vectors: Int = 0,
                pagesIndexed: Int = 0,
                scope: SemanticScope? = nil,
                semanticRankScale: Double = 1,
                semanticDisarmed: SemanticDisarmReason? = nil,
                fuzzyFallback: Bool = false,
                fuzzyExpanded: Bool = false,
                quorum: Bool = false) {
        self.semanticDisarmed = semanticDisarmed
        self.fuzzyFallback = fuzzyFallback
        self.fuzzyExpanded = fuzzyExpanded
        self.quorum = quorum
        self.scope = scope ?? SemanticScope(vectors: vectors,
                                            pagesIndexed: pagesIndexed,
                                            filtered: false)
        self.semanticRankScale = semanticRankScale
        self.semantic = semantic
        self.semanticFloor = semanticFloor
        self.semanticKept = semanticKept
        self.vectors = vectors
        self.pagesIndexed = pagesIndexed
        self.hits = hits
        self.lexTotalPages = lexTotalPages
        self.lexTotalDocs = lexTotalDocs
        self.semanticOnly = semanticOnly
        self.elapsedMS = elapsedMS
        self.offset = offset
        self.hasMore = hasMore
        self.modelLoadMS = modelLoadMS
        self.indexLoadMS = indexLoadMS
    }
}

public enum HybridSearch {

    /// Profondeur des deux listes fusionnées. 200 couvre tout affichage
    /// raisonnable ; le RRF au-delà du rang ~140 pèse moins de 0,5 %.
    public static let defaultDepth = 200

    /// L'échelle de rang du canal sémantique pour une couverture donnée
    /// (lot R1) : `1 / couverture`, bornée à 1 quand tout est vectorisé.
    ///
    /// Le RRF suppose que les deux listes classent le MÊME univers. Or le
    /// canal vectoriel ne voit que les pages qui portent un vecteur — 15,9 %
    /// du corpus le 05/09/2026 — et une page première parmi un sixième des
    /// pages serait, en espérance, sixième ou septième parmi toutes. Sans
    /// correction, `energie libre` rendait cinq pages sémantiques sur les dix
    /// premières alors que 428 pages portent l'expression : le canal qui avait
    /// comparé une page sur six obtenait une place sur deux. Avec l'échelle,
    /// le premier hit sémantique vaut le septième lexical à 16 % de
    /// couverture, le cinquième vaut le trente-et-unième ; à couverture
    /// complète l'échelle vaut 1 et rien ne change. Ce n'est pas le
    /// `vecWeight = couverture` que C2-02 proposait et que D2 a écarté : un
    /// poids éteint la liste, l'échelle la replace.
    ///
    /// Une couverture nulle ou inconnue rend 1 : aucune correction plutôt
    /// qu'une division par zéro — et une base sans vecteur n'entre de toute
    /// façon pas ici.
    public static func semanticRankScale(vectors: Int, pagesIndexed: Int) -> Double {
        guard vectors > 0, pagesIndexed > 0, vectors < pagesIndexed else { return 1 }
        return Double(pagesIndexed) / Double(vectors)
    }

    /// Facteur appliqué au RANG des pages d'un document au-delà de la
    /// troisième dans la liste vectorielle : la quatrième page compte comme si
    /// elle était deux fois plus loin (4ᵉ → ~8ᵉ, 10ᵉ → ~20ᵉ).
    public static let diversityRankFactor = 2

    /// Un document ne prend pas non plus tout le canal sémantique (lot R1) :
    /// au-delà de `Schema.diversityFullStrengthPages` pages d'un même document,
    /// les suivantes sont RÉTROGRADÉES — leur rang est multiplié par
    /// `diversityRankFactor`, puis la liste est retriée sur ces rangs. C'est un
    /// palier doux, comme le ×0,5 du score lexical (`GRDBStore.rankingLayers`),
    /// pas une relégation en queue : la première version envoyait la quatrième
    /// page APRÈS toutes les autres — sur une paraphrase dont un seul cours est
    /// la source, l'utilisateur voyait trois pages du cours puis 197 autres
    /// documents (AUDIT-R1 I4). Le RRF ne connaît que des rangs, et un facteur
    /// de rang se comporte pareil quelle que soit l'échelle du canal
    /// (`semanticRankScale`). Mesuré le 03/09/2026 : 31 % des hits sémantiques
    /// purs venaient d'un seul document. Ne change que l'ordre.
    public static func diversified(_ rowids: [Int64],
                                   perDocument cap: Int = Schema.diversityFullStrengthPages,
                                   rankFactor: Int = diversityRankFactor) -> [Int64] {
        var seen: [Int64: Int] = [:]
        var ranked: [(rank: Int, index: Int, rowid: Int64)] = []
        for (index, rowid) in rowids.enumerated() {
            let docID = rowid / Schema.pagesPerDocLimit
            let n = (seen[docID] ?? 0) + 1
            seen[docID] = n
            let rank = n <= cap ? index + 1 : (index + 1) * rankFactor
            ranked.append((rank, index, rowid))
        }
        return ranked
            .sorted { $0.rank == $1.rank ? $0.index < $1.index : $0.rank < $1.rank }
            .map(\.rowid)
    }

    /// Plancher de marge par défaut, en écarts-types de la population balayée.
    ///
    /// **0, c'est-à-dire AUCUN plancher — et c'est une mesure, pas un oubli.**
    /// Le protocole de vérification de C2-01 a été exécuté le 03/09/2026 sur la
    /// base de production (64 872 vecteurs, 12 requêtes témoins) : la marge
    /// `z = (cos − μ) / σ` ne sépare pas les requêtes absurdes des requêtes
    /// pertinentes — elle les sépare À L'ENVERS. Une requête hors domaine est
    /// loin de TOUT (μ bas), donc son meilleur voisin s'en détache de +4,5 à
    /// +7,7 σ ; une requête pertinente est proche de tout le corpus (μ haut),
    /// donc son meilleur voisin ne dépasse que de +3,9 à +4,7 σ.
    ///
    /// Le CENTRAGE (`--vec-center`) a été essayé ensuite : il fait ce qu'on
    /// attend de lui sur l'anisotropie (μ passe de 0,78 à 0,000, les cosinus
    /// s'étalent de 0,29 à 0,56 au lieu de 0,78-0,88) mais il ne renverse pas
    /// le classement — et il aggrave la CONCENTRATION : la part des hits
    /// sémantiques purs venant d'un seul document passe de 31 % à 65 % sur les
    /// mêmes douze requêtes. Il reste exposé pour la calibration, jamais par
    /// défaut.
    ///
    /// Poser un plancher positif éteindrait donc en premier les requêtes que le
    /// canal sémantique sert le mieux. Le mécanisme reste implémenté et exposé
    /// (`--vec-floor`) parce qu'il est juste dès qu'une statistique séparante
    /// sera trouvée — le jeu de requêtes jugées (`Tools/ranking/`) est là pour
    /// ça —, mais il est DÉSARMÉ par défaut, et le dire est le constat.
    public static let defaultVectorFloor: Double = 0

    /// Les documents que le canal VECTORIEL a le droit de rendre — tous les
    /// filtres de document de la requête réunis —, ou `nil` quand la requête
    /// n'en porte aucun (tout l'index).
    ///
    /// POINT UNIQUE (lot MC2). Trois filtres arrivent par trois chemins
    /// différents — `docIDsMatchingFilters` (dossier, extension, `--in`,
    /// exclusions `-terme`), `docIDsMatching(langs:modifiedAfter:)` et
    /// `docIDsMatchingName` (`nom:`, `chemin:` et leurs négatifs, lot MC1) —
    /// et le serveur MCP doit calculer le MÊME ensemble que la fusion pour
    /// décider, AVANT de charger le modèle, s'il y a un vecteur à comparer.
    /// Deux compositions de la même règle auraient divergé.
    public static func scopeDocIDs(store: GRDBStore, query q: SearchQuery,
                                   excludingDocsMatching negative: String?) throws
        -> Set<Int64>? {
        var allowed = try store.docIDsMatchingFilters(
            folders: q.folders, exts: q.exts, inDocIDs: q.inDocIDs,
            excludingDocsMatching: negative)
        if let byDocument = try store.docIDsMatching(langs: q.langs,
                                                     modifiedAfter: q.modifiedAfter) {
            allowed = allowed.map { $0.intersection(byDocument) } ?? byDocument
        }
        if let byName = try store.docIDsMatchingName(q) {
            allowed = allowed.map { $0.intersection(byName) } ?? byName
        }
        return allowed
    }

    /// Ce que le canal du sens voit du périmètre demandé (PM-06).
    ///
    /// Sans filtre de document, les chiffres GLOBAUX sont rendus tels quels :
    /// aucune requête de plus. Avec un filtre, deux lectures par document
    /// autorisé (~30 ms sur 1 883 documents) — le prix d'une phrase juste.
    public static func scope(store: GRDBStore, query q: SearchQuery,
                             excludingDocsMatching negative: String?,
                             vectors: Int, pagesIndexed: Int) throws -> SemanticScope {
        try scope(allowed: scopeDocIDs(store: store, query: q,
                                       excludingDocsMatching: negative),
                  store: store, vectors: vectors, pagesIndexed: pagesIndexed)
    }

    /// Idem, quand l'ensemble autorisé est déjà connu — la fusion l'a calculé
    /// pour son canal vectoriel, il n'y a pas à le refaire.
    public static func scope(allowed: Set<Int64>?, store: GRDBStore,
                             vectors: Int, pagesIndexed: Int) throws -> SemanticScope {
        guard let allowed else {
            return SemanticScope(vectors: vectors, pagesIndexed: pagesIndexed,
                                 filtered: false)
        }
        let ids = Array(allowed)
        let inScope = try store.vectorisedPageCounts(forDocIDs: ids)
            .values.reduce(0, +)
        let pages = try store.indexedPageCounts(forDocIDs: ids).values.reduce(0, +)
        return SemanticScope(vectors: inScope, pagesIndexed: pages, filtered: true)
    }

    /// `rawQuery` : le texte envoyé au MODÈLE, débarrassé des filtres, des
    /// exclusions et des guillemets par l'appelant — le canal vectoriel n'a pas
    /// de syntaxe. `typedQuery` : la requête TELLE QU'ELLE A ÉTÉ TAPÉE, avec
    /// ses guillemets ; elle ne sert qu'à décider du désarmement (RK-01), et
    /// c'est pour cela qu'elle est un paramètre à part et SANS valeur par
    /// défaut : `rawQuery` ne peut pas la remplacer (les trois surfaces en ont
    /// déjà retiré les guillemets), et un défaut aurait laissé une surface
    /// oublier la règle en silence.
    public static func run(store: GRDBStore,
                           engine: EmbedEngine,
                           index: VectorIndex,
                           query q: SearchQuery,
                           excludingDocsMatching negative: String?,
                           rawQuery: String,
                           typedQuery: String,
                           limit: Int,
                           offset: Int = 0,
                           depth: Int = defaultDepth,
                           lexWeight: Double = 1,
                           vecWeight: Double = 1,
                           vecFloor: Double = defaultVectorFloor,
                           coverageScaling: Bool = true,
                           modelLoadMS: Double? = nil,
                           indexLoadMS: Double? = nil,
                           scope precomputed: SemanticScope? = nil) throws -> HybridResults {
        let start = DispatchTime.now().uptimeNanoseconds
        let pagesIndexed = try store.indexedPageCount()

        // 1. Canal lexical : la recherche existante, à profondeur `depth`.
        var lexQuery = q
        lexQuery.limit = depth
        lexQuery.offset = 0
        let lexical = try store.search(lexQuery, excludingDocsMatching: negative)
        var lexByRowid: [Int64: Hit] = [:]
        var lexOrder: [Int64] = []
        for hit in lexical.hits {
            let rowid = Schema.ftsRowID(docID: hit.docID, page: hit.page)
            if lexByRowid[rowid] == nil {
                lexByRowid[rowid] = hit
                lexOrder.append(rowid)
            }
        }

        // 2. Canal vectoriel : mêmes filtres de documents que le lexical —
        // SAUF si la requête demande une phrase exacte.
        //
        // RK-01, jugé le 09/09/2026 sur 790 jugements : sur les quatre requêtes
        // à guillemets du banc, QUATRE résultats sur dix ne portaient pas
        // l'expression demandée (zéro en lexical), et le nDCG tombait de 0,946
        // à 0,713 sur `"energie libre"`, de 0,849 à 0,637 sur `"gaz parfait"`.
        // Le canal sémantique n'a pas de guillemets : il compare des vecteurs.
        // On ne tamise pas ses candidats sur la phrase (l'autre remède : plus
        // cher, et opaque — un résultat disparaîtrait sans qu'on sache
        // pourquoi), on ne le consulte pas, et on le DIT.
        //
        // Les trois surfaces court-circuitent en amont, pour rendre la sortie
        // LEXICALE complète (facettes, pagination, canal des noms) ; ce test
        // est le point unique qu'aucune surface, présente ou future, ne peut
        // oublier — d'où le `typedQuery` sans valeur par défaut.
        let disarmed: SemanticDisarmReason? =
            QueryParser.asksForExactPhrase(typedQuery) ? .exactPhrase : nil
        // Le désarmement ne prend AUCUN raccourci de sortie : la liste
        // vectorielle reste vide, et tout ce qui suit (fusion, tranche,
        // extraits, habillage) est le code d'un hybride ordinaire. Un RRF à une
        // seule liste rend exactement l'ordre lexical.
        var semantic = SemanticStats(mu: 0, sigma: 0, cosMax: nil, zMax: nil,
                                     zAt10: nil, zAt200: nil, scanned: 0,
                                     zeroVectors: 0)
        var stats = VectorIndex.ScanStats(mu: 0, sigma: 0, scanned: 0, zeros: 0)
        var vecOrder: [Int64] = []
        var cosineByRowid: [Int64: Float] = [:]
        var keptCount = 0
        var scale: Double = 1
        var scope = precomputed
        if disarmed == nil {
            // Langue, date, `nom:`, `chemin:` et les exclusions : tous les
            // filtres de DOCUMENT réunis, par le point unique que le serveur
            // MCP consulte lui aussi avant de charger le modèle (lot MC2).
            let allowed = try Self.scopeDocIDs(store: store, query: q,
                                               excludingDocsMatching: negative)
            if scope == nil {
                scope = try Self.scope(allowed: allowed, store: store,
                                       vectors: index.pageCount,
                                       pagesIndexed: pagesIndexed)
            }
            // Le centrage éventuel de l'index vaut aussi pour la requête, sans quoi
            // les deux espaces ne se comparent plus (VectorIndex.centered()).
            let rawVector = try engine.embedQuery(rawQuery)
            let queryVec = VecQuantizer.quantizeQuery(index.center(query: rawVector))
            let scan = index.topK(query: queryVec,
                                  k: allowed == nil && q.keepsAllSources ? depth : depth * 2,
                                  allowedDocs: allowed)
            stats = scan.stats
            // Provenance des pages (lot P3) : le seul filtre qui porte sur la PAGE.
            // `allowedDocs` ne sait pas l'exprimer — il ne connaît que des
            // documents —, et le canal vectoriel rendrait sinon des pages natives
            // « proposées par le sens » sous un filtre qui promet le scan. La
            // liste est donc tamisée APRÈS le balayage, sur au plus `depth * 2`
            // rowids : `pageMeta` les lit par clé primaire (row-values), là où une
            // clause SQL dans le balayage aurait supposé un index vectoriel que
            // `VectorIndex` n'a pas.
            let scanned: [(rowid: Int64, cosine: Float)]
            if q.keepsAllSources {
                scanned = scan.hits
            } else {
                let keys = scan.hits.map {
                    (docID: $0.rowid / Schema.pagesPerDocLimit,
                     page: Int($0.rowid % Schema.pagesPerDocLimit))
                }
                let meta = try store.pageMeta(for: keys)
                // Page absente de `page_src` = texte natif, comme partout ailleurs.
                scanned = scan.hits.filter { q.keeps(meta[$0.rowid]?.source ?? .native) }
            }
            let vecTop = Array(scanned.prefix(depth))
            semantic = SemanticStats(
                mu: scan.stats.mu,
                sigma: scan.stats.sigma,
                cosMax: vecTop.first?.cosine,
                zMax: vecTop.first.map { scan.stats.z($0.cosine) },
                zAt10: vecTop.count >= 10 ? scan.stats.z(vecTop[9].cosine) : nil,
                zAt200: vecTop.count >= 200 ? scan.stats.z(vecTop[199].cosine) : nil,
                scanned: scan.stats.scanned,
                zeroVectors: scan.stats.zeros)

            // Le PLANCHER tronque la liste vectorielle — elle peut devenir vide, et
            // c'est le but : à poids égaux le RRF donne une place sur deux au canal
            // sémantique, y compris quand il n'a rien à dire (C2-02). Un plancher
            // nul laisse passer toute la liste, ce qui est le comportement
            // historique et, à ce jour, le défaut mesuré (voir `defaultVectorFloor`).
            let kept = vecFloor > 0
                ? vecTop.filter { scan.stats.z($0.cosine) >= vecFloor }
                : vecTop
            keptCount = kept.count
            // Diversité par document (lot R1) : la liste lexicale arrive déjà
            // diversifiée du store ; la liste vectorielle l'est ici, en rangs.
            vecOrder = q.diversifyDocuments
                ? Self.diversified(kept.map(\.rowid)) : kept.map(\.rowid)
            for (rowid, cosine) in kept { cosineByRowid[rowid] = cosine }
            // Les rangs sémantiques replacés à l'échelle du corpus entier
            // (voir `semanticRankScale`).
            scale = coverageScaling
                ? Self.semanticRankScale(vectors: index.pageCount,
                                         pagesIndexed: pagesIndexed)
                : 1
        }

        // 3. Fusion RRF, puis décalage et habillage.
        let fused = RRF.fuse([lexOrder, vecOrder],
                             weights: [lexWeight, vecWeight],
                             rankScales: [1, scale])
        let slice = fused.dropFirst(offset)
        let hasMore = slice.count > limit
        let top = Array(slice.prefix(limit))

        let semanticOnlyRowids = top.filter { lexByRowid[$0.id] == nil }.map(\.id)
        let previews = try store.pagePreviews(for: semanticOnlyRowids, maxChars: 220)

        var hits: [HybridHit] = []
        hits.reserveCapacity(top.count)
        for entry in top {
            let rowid = entry.id
            let docID = rowid / Schema.pagesPerDocLimit
            let page = Int(rowid % Schema.pagesPerDocLimit)
            let lexHit = lexByRowid[rowid]
            let preview = previews[rowid]
            guard lexHit != nil || preview != nil else { continue }  // page disparue
            hits.append(HybridHit(
                docID: docID, page: page,
                path: lexHit?.path ?? preview?.relPath ?? "",
                rrf: entry.score,
                lexRank: entry.ranks[0], vecRank: entry.ranks[1],
                cosine: cosineByRowid[rowid],
                z: cosineByRowid[rowid].map { stats.z($0) },
                lexical: lexHit,
                preview: preview?.preview
                    ?? lexHit?.snippet ?? ""))
        }

        let elapsed = Double(DispatchTime.now().uptimeNanoseconds - start) / 1_000_000
        return HybridResults(hits: hits,
                             lexTotalPages: lexical.totalPages,
                             lexTotalDocs: lexical.totalDocs,
                             semanticOnly: hits.filter { $0.lexical == nil }.count,
                             elapsedMS: elapsed,
                             offset: offset,
                             hasMore: hasMore,
                             modelLoadMS: modelLoadMS,
                             indexLoadMS: indexLoadMS,
                             semantic: semantic,
                             semanticFloor: vecFloor,
                             semanticKept: keptCount,
                             // PAGES, pas fenêtres : la couverture se lit
                             // « 16,6 % des pages », et `index.count` compte
                             // des fenêtres depuis le schéma v5 (C2-05).
                             vectors: index.pageCount,
                             pagesIndexed: pagesIndexed,
                             // Le périmètre FILTRÉ (PM-06) : calculé une seule
                             // fois, avec l'ensemble autorisé du canal
                             // vectoriel quand il a servi.
                             scope: try scope ?? Self.scope(
                                store: store, query: q,
                                excludingDocsMatching: negative,
                                vectors: index.pageCount,
                                pagesIndexed: pagesIndexed),
                             semanticRankScale: scale,
                             semanticDisarmed: disarmed,
                             // Le repli en flou du canal lexical (lot MP1) :
                             // l'hybride le TRANSPORTE désormais, sans quoi les
                             // trois surfaces affichaient des orthographes
                             // proches sans le dire dans ce mode.
                             fuzzyFallback: lexical.fuzzyFallback,
                             // Les deux drapeaux du lot MC2, transportés pour
                             // la même raison : ils étaient VRAIS sans que le
                             // mode hybride puisse les dire.
                             fuzzyExpanded: lexical.fuzzyExpanded,
                             quorum: lexical.quorum)
    }
}
