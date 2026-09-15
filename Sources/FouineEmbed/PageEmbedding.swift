// PageEmbedding.swift — encoder UNE page à la volée, exactement comme la
// campagne l'aurait encodée.
// SPDX-License-Identifier: LicenseRef-Fouine-Source-Available
// Propriété : A-Embed. Lot MC4 (constat PM-07).
//
// POURQUOI CE FICHIER EXISTE. `fouine_similar_pages` ne rend rien d'une page
// qui n'a pas de vecteur — et c'est le cas de racines entières tant que la
// campagne n'y est pas passée (`M2SU` : 0 vecteur sur 139 638 pages, mesuré le
// 13/09/2026). Le paramètre `encode_if_missing` permet de payer l'encodage
// pour CETTE page ; encore faut-il produire le MÊME vecteur que la campagne,
// sans quoi les cosinus comparés n'auraient aucun sens.
//
// LA RÈGLE EST « APPELER, PAS RECOPIER ». Le fenêtrage et les quatre raisons de
// poser un vecteur nul sont ici ; `EmbedRun` les appelle, et il est le seul
// endroit où s'ajoute la géométrie de la campagne. Deux découpes du même texte
// finiraient par ne plus coïncider — et l'écart serait invisible, puisque les
// deux rendraient des nombres plausibles.
//
// CE QUI RESTE DANS `EmbedRun` : le vecteur nul par EXTENSION (tableurs) et par
// TEXTE PARTAGÉ (un même bandeau sur mille pages), qui se décident par document
// et par index, pas par page isolée. À la volée, la question ne se pose pas :
// l'appelant demande les voisins d'une page précise.

import Foundation
import FouineCore

public enum PageEmbedding {

    /// Fenêtres d'une page : `(créneau, texte)`, dans l'ordre.
    ///
    /// La fenêtre k couvre les caractères `[k·stride, k·stride + chars)`. Le
    /// découpage se fait sur les CARACTÈRES de Swift, comme le `prefix(1400)`
    /// du schéma v3 : c'est ce qui garantit que la fenêtre 0 est octet pour
    /// octet celle que la campagne a déjà produite.
    public static func windows(for text: String) -> [(chunk: Int, text: String)] {
        let chars = Array(text)
        let count = Schema.vecWindowCount(forLength: chars.count)
        return (0..<count).map { k in
            let start = k * Schema.vecWindowStride
            guard start < chars.count else { return (k, "") }
            let end = min(chars.count, start + Schema.vecWindowChars)
            return (k, String(chars[start..<end]))
        }
    }

    /// Une fenêtre recevrait-elle un vecteur NUL de la campagne ?
    ///
    /// Les deux règles qui se décident sur le seul texte de la fenêtre, dans
    /// l'ordre du moins cher au plus cher, comme `EmbedRun` les applique : trop
    /// courte (`minChars`), puis dégénérée ou numérique.
    public static func isNulled(_ window: String,
                                minChars: Int = EmbedRun.Config().minChars,
                                nullDegenerate: Bool = true) -> Bool {
        if window.trimmingCharacters(in: .whitespacesAndNewlines)
            .count < minChars { return true }
        if nullDegenerate, TextDegeneracy.isDegenerate(window)
            || TextDegeneracy.isMostlyNumeric(window) { return true }
        return false
    }

    /// Le vecteur QUANTIFIÉ des fenêtres utiles d'une page, à la volée.
    ///
    /// Rend une liste vide quand aucune fenêtre ne porte assez de texte : c'est
    /// le même verdict que la campagne, et l'appelant doit le dire plutôt que
    /// de comparer des zéros (un vecteur nul a un produit scalaire nul, donc
    /// aucun voisin qui veuille dire quelque chose).
    ///
    /// CHARGE LE MODÈLE, forcément : c'est le seul chemin du serveur MCP qui le
    /// fasse hors d'une recherche hybride, et le seul que `encode_if_missing`
    /// ouvre.
    public static func vectors(forPageText text: String,
                               engine: EmbedEngine,
                               minChars: Int = EmbedRun.Config().minChars,
                               nullDegenerate: Bool = true) throws -> [[Int8]] {
        let useful = windows(for: text).map(\.text).filter {
            !isNulled($0, minChars: minChars, nullDegenerate: nullDegenerate)
        }
        guard !useful.isEmpty else { return [] }
        // `VecQuantizer.quantize`, celui de la campagne, et non
        // `quantizeQuery` : les deux font la même arithmétique aujourd'hui, et
        // c'est justement ce qu'il ne faut pas parier. On passe par les OCTETS
        // que la base aurait reçus, puis on les relit.
        return try engine.embedPassages(useful)
            .map(VecQuantizer.quantize)
            .map { blob in blob.map { Int8(bitPattern: $0) } }
    }
}
