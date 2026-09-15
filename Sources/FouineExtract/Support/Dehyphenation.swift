// Dehyphenation.swift — recoller les mots coupés en fin de ligne (constat C2-10).
// SPDX-License-Identifier: LicenseRef-Fouine-Source-Available
// Propriété : A-Ingest.
//
// POURQUOI. Un document mis en page par un professionnel est justifié, donc
// césuré : la notice de la déclaration de revenus porte `dispen-\nser`,
// `prélève-\nment`, `de l'en-\nsemble`. Le trait d'union reste dans le texte
// indexé, donc le mot n'existe pas — `fouine search dispenser` ne trouve pas la
// page qui en parle. Mesuré sur le corpus 2 : 1,29 % des mots de la notice
// 2042 (565 coupures sur 43 831 mots), 1,06 % d'un article arXiv. Un mot sur
// quatre-vingts est introuvable dans le document que chaque foyer fiscal
// français reçoit une fois par an.
//
// DEUX FORMES, DEUX CHANCES. La forme coupée est CONSERVÉE et la forme jointe
// AJOUTÉE derrière : « porte-\nmanteau portemanteau ». C'est ce qui évite
// d'avoir à trancher entre un mot césuré et un mot légitimement composé —
// « porte-manteau » et « portemanteau » se cherchent tous les deux. Le coût est
// d'environ 1 % de texte en plus là où il y a des césures, et zéro ailleurs :
// un texte sans « -\n » ressort tel quel, sans une allocation.
//
// CE QUI N'EST JAMAIS RECOLLÉ, et chacun pour une raison :
//   · `1990-\n1995` — un intervalle de dates, pas un mot ;
//   · `A-\nB` — une référence, une cote, un sigle : recoller ferait « AB » ;
//   · `mot -\n suite` — le tiret est un tiret de dialogue ou une puce.
// La règle tient en une phrase : minuscule avant le tiret, minuscule après le
// retour.

import Foundation

public enum Dehyphenation {

    /// Ajoute la forme jointe derrière chaque mot coupé en fin de ligne.
    ///
    /// « Le dispen-\nser » devient « Le dispen-\nser dispenser » : la page
    /// porte alors les deux formes, et la recherche attrape les deux.
    public static func rejoin(_ text: String) -> String {
        // Sortie rapide : aucun corpus non césuré ne paie une allocation.
        // « \r\n » est UN SEUL `Character` en Swift : le motif Windows ne
        // contient donc pas « -\n », et l'oublier ici désarmait tout le
        // fichier sur les PDF exportés d'un traitement de texte.
        guard text.contains("-\n") || text.contains("-\r\n") else { return text }

        let chars = Array(text)
        var out = String()
        out.reserveCapacity(chars.count + chars.count / 64)
        var index = 0
        while index < chars.count {
            let current = chars[index]
            out.append(current)
            guard current == "-", index > 0, isJoinable(chars[index - 1]) else {
                index += 1
                continue
            }
            let newline = index + 1
            guard newline < chars.count, isNewline(chars[newline]),
                  newline + 1 < chars.count, isJoinable(chars[newline + 1])
            else {
                index += 1
                continue
            }
            // Le morceau AVANT le tiret, sans son éventuelle apostrophe :
            // « de l'en-\nsemble » rend « ensemble », pas « l'ensemble ».
            var start = index
            while start > 0, chars[start - 1].isLetter { start -= 1 }
            // Le morceau APRÈS le retour, jusqu'à la fin du mot.
            var end = newline + 1
            while end < chars.count, chars[end].isLetter { end += 1 }

            out.append(contentsOf: chars[(index + 1)..<end])   // le retour, puis la suite
            out.append(" ")
            out.append(contentsOf: chars[start..<index])
            out.append(contentsOf: chars[(newline + 1)..<end])
            index = end
        }
        return out
    }

    /// Combien de recollages `rejoin` ferait — la mesure, sans le texte.
    public static func count(in text: String) -> Int {
        guard text.contains("-\n") || text.contains("-\r\n") else { return 0 }
        let chars = Array(text)
        var total = 0
        var index = 0
        while index < chars.count {
            defer { index += 1 }
            guard chars[index] == "-", index > 0, isJoinable(chars[index - 1])
            else { continue }
            let newline = index + 1
            guard newline < chars.count, isNewline(chars[newline]),
                  newline + 1 < chars.count, isJoinable(chars[newline + 1])
            else { continue }
            total += 1
        }
        return total
    }

    /// Une lettre minuscule, accents compris. Ni chiffre, ni majuscule, ni
    /// ponctuation : voir l'en-tête.
    static func isJoinable(_ character: Character) -> Bool {
        character.isLetter && character.isLowercase
    }

    /// Un retour à la ligne, « \r\n » compris — un seul `Character` en Swift.
    static func isNewline(_ character: Character) -> Bool {
        character == "\n" || character == "\r\n" || character == "\r"
    }
}
