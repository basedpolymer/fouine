// HitRelevance.swift — la pertinence RELATIVE d'un résultat, en pourcentage.
// SPDX-License-Identifier: LicenseRef-Fouine-Source-Available
// Propriété : A-Core. Lot MC2 (constat PM-16d).
//
// POURQUOI L'EXTRAIRE. La sortie texte de `fouine search` pose depuis toujours
// un `100 %`, `86 %`, `81 %` par résultat : c'est le score rapporté au
// MEILLEUR de la liste rendue. Le serveur MCP, lui, ne donnait qu'un `bm25`
// négatif dont son propre schéma dit qu'il n'est « ni borné ni comparable » —
// un modèle n'avait donc AUCUN moyen de dire « le quatrième résultat est
// nettement moins pertinent que le premier », ce que l'utilisateur devant sa
// ligne de commande lit d'un coup d'œil.
//
// CE QUE CE N'EST PAS. Pas une probabilité, pas une note absolue, pas une
// valeur comparable d'une requête à l'autre : le dénominateur est le meilleur
// résultat DE CETTE RÉPONSE. 100 % veut dire « le mieux classé ici », pas
// « la réponse ». C'est exactement ce que la CLI affiche, et le nom du champ
// (`relevance_pct`) comme sa description le disent.
//
// DEUX ÉCHELLES, DEUX SIGNES. Le BM25 de FTS5 est NÉGATIF et décroît quand la
// page est meilleure (le meilleur est le minimum) ; le score RRF de la fusion
// est POSITIF et décroît quand la page est moins bonne (le meilleur est le
// maximum). Une seule formule — `score / meilleur` — les couvre tous les deux,
// à condition de choisir le bon extremum ; d'où deux points d'entrée plutôt
// qu'un `abs()` qui aurait caché le raisonnement.

import Foundation

public enum HitRelevance {

    /// Le pourcentage d'un score rapporté au meilleur, borné à 0-100.
    ///
    /// `best` nul, de signe contraire, ou score du mauvais côté de zéro : 100.
    /// C'est le comportement de la sortie texte de la CLI, et il est voulu —
    /// une liste d'un seul élément, ou un BM25 nul (le terme est sur TOUTES les
    /// pages, donc son IDF est nul), ne permet aucune comparaison, et afficher
    /// alors « 0 % » ferait lire « sans rapport » là où il n'y a rien à lire.
    public static func percentage(score: Double, best: Double) -> Int {
        guard best != 0, score / best > 0 || score == 0 else { return 100 }
        let ratio = score / best
        return max(0, min(100, Int((100 * ratio).rounded())))
    }

    /// Les pourcentages d'une liste de scores BM25 (négatifs, meilleur = le
    /// plus petit), dans l'ordre reçu.
    public static func percentages(bm25 scores: [Double]) -> [Int] {
        let best = scores.min() ?? 0
        return scores.map { percentage(score: $0, best: best) }
    }

    /// Les pourcentages d'une liste de scores RRF (positifs, meilleur = le plus
    /// grand), dans l'ordre reçu.
    ///
    /// TRANCHÉ ICI (lot MC2) : en hybride, la pertinence relative se lit sur le
    /// score de FUSION et non sur le `bm25`, qui est nul pour une page trouvée
    /// par le seul canal du sens — la moitié d'une liste hybride aurait sinon
    /// été sans pourcentage. Le RRF étant un score de RANG, l'écart entre deux
    /// résultats y est plus resserré qu'en lexical : `1/(60+1)` contre
    /// `1/(60+10)` fait déjà 87 %.
    public static func percentages(rrf scores: [Double]) -> [Int] {
        let best = scores.max() ?? 0
        return scores.map { percentage(score: $0, best: best) }
    }
}
