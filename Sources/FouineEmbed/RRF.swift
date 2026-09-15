// RRF.swift — fusion de rangs réciproques (Reciprocal Rank Fusion).
// Propriété : A-Embed.
//
// Pourquoi RRF et pas une combinaison de scores : bm25 (négatif, non borné) et
// cosinus (borné [-1, 1]) ne sont PAS commensurables — toute somme pondérée des
// deux exige une calibration fragile qui se périme avec le corpus. Le RRF ne
// regarde que les RANGS : score(d) = Σ w_l / (k + rang_l(d)), insensible aux
// échelles, robuste (Cormack et al., 2009). k = 60, valeur canonique.

import Foundation

public enum RRF {

    public static let k: Double = 60

    public struct Fused: Sendable {
        public let id: Int64
        public let score: Double
        /// Rang (1-indexé) dans chaque liste d'origine, nil si absente.
        public let ranks: [Int?]
    }

    /// Fusionne des listes ordonnées (meilleur d'abord). `weights` pondère
    /// chaque liste (défaut 1). `rankScales` étire les RANGS d'une liste
    /// (défaut 1) : `score += w / (k + rang × échelle)`. Rend les identifiants
    /// par score décroissant.
    ///
    /// L'échelle sert au canal sémantique quand il ne voit qu'une PARTIE du
    /// corpus (lot R1, `HybridSearch.semanticRankScale`) : une page première
    /// parmi 16 % des pages n'est pas première parmi toutes, et la traiter
    /// ainsi donnait une place sur deux à un canal qui n'avait comparé qu'une
    /// page sur six. Ce n'est PAS le poids `w` : un poids atténue toute la
    /// liste uniformément — à 16 %, il l'éteint (C2-02, contre-expertise D2) ;
    /// l'échelle déplace chaque rang vers celui qu'il aurait eu sur le corpus
    /// entier, et vaut 1 dès que la couverture est complète.
    public static func fuse(_ lists: [[Int64]],
                            weights: [Double]? = nil,
                            rankScales: [Double]? = nil) -> [Fused] {
        let w = weights ?? Array(repeating: 1, count: lists.count)
        let scales = rankScales ?? Array(repeating: 1, count: lists.count)
        precondition(w.count == lists.count, "one weight per list")
        precondition(scales.count == lists.count, "one rank scale per list")
        var scores: [Int64: Double] = [:]
        var ranks: [Int64: [Int?]] = [:]
        for (l, list) in lists.enumerated() {
            for (i, id) in list.enumerated() {
                scores[id, default: 0] += w[l] / (Self.k + Double(i + 1) * scales[l])
                var r = ranks[id] ?? Array(repeating: nil, count: lists.count)
                r[l] = i + 1
                ranks[id] = r
            }
        }
        return scores
            .map { Fused(id: $0.key, score: $0.value,
                         ranks: ranks[$0.key] ?? Array(repeating: nil,
                                                       count: lists.count)) }
            .sorted { $0.score == $1.score ? $0.id < $1.id : $0.score > $1.score }
    }
}
