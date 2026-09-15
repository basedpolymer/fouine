// TextDegeneracy.swift — deux textes qu'il ne faut pas vectoriser, et la façon
// de les reconnaître SANS base ni modèle. Propriété : A-Embed.
//
// LE VECTEUR NUL EST DÉJÀ LA RÉPONSE DU PRODUIT à « cette fenêtre ne doit pas
// classer » : produit scalaire nul, jamais dans un top-k, zéro inférence
// dépensée, et la page reste trouvable au mot près par le canal lexical
// (`EmbedRun.Config.minChars` s'en sert depuis le schéma v3 pour les pages
// quasi vides). Ce fichier ajoute deux raisons de le poser.
//
//   1. LE TEXTE DÉGÉNÉRÉ (constat MO-01). Un `.docx` de 80 Kio dont le corps
//      est 80 Mio de « A » produisait 13 108 pages, donc ~26 000 fenêtres de
//      plus de cent caractères — assez pour passer `minChars` — dont les
//      vecteurs sont IDENTIQUES et proches de tout. Le plafond de pages borne
//      désormais le dégât ; il ne le supprime pas, et un scan raté, une
//      colonne de tirets, une bordure ASCII produisent le même vecteur pour
//      rien.
//
//   2. LE TEXTE PARTAGÉ (constat C2-16). Le préambule de licence du Projet
//      Gutenberg, recopié à l'identique dans huit livres, occupait quatre des
//      cinq premiers résultats d'une recherche par le sens. Le texte n'est pas
//      dégénéré — c'est de la prose anglaise correcte — il est simplement
//      PARTAGÉ, et c'est à la base, pas au texte, qu'il faut le demander.
//      D'où la séparation : ici on compose la question (deux phrases prises
//      dans la fenêtre), `GRDBStore.documentsSharing` y répond.
//
// Les deux règles sont PURES et se prouvent sans base.

import Foundation

enum TextDegeneracy {

    /// Au plus ce nombre de caractères DISTINCTS : « AAAA… », « ababab… »,
    /// « ------ », une colonne de points de conduite. Trois, et non deux, parce
    /// qu'un texte n'a jamais qu'un seul séparateur (« a b a b » en fait déjà
    /// deux avec l'espace, retiré ici).
    static let maxDistinctCharacters = 3

    /// Part du 4-gramme le plus fréquent au-delà de laquelle le texte se répète
    /// plus qu'il ne dit quelque chose. La moitié est un seuil FRANC : une
    /// prose ordinaire est à quelques pour cent, une table de nombres à moins
    /// de dix, et il faut vraiment une boucle pour l'atteindre.
    static let maxTopGramShare = 0.5

    /// En deçà, on ne juge pas : trois mots répétés ne sont pas une pathologie,
    /// et `minChars` a déjà écarté les fenêtres vraiment courtes.
    static let minimumJudgedCharacters = 40

    /// Le texte est-il trop pauvre pour mériter une inférence ?
    ///
    /// Les blancs sont retirés AVANT tout : « A A A A » et « AAAA » sont le même
    /// texte pour ce qui nous occupe, et un scan raté produit l'un comme
    /// l'autre. La casse aussi : « AbAbAb » n'est pas plus riche qu'« ababab ».
    static func isDegenerate(_ text: String) -> Bool {
        let compact = text.lowercased().filter { !$0.isWhitespace }
        guard compact.count >= minimumJudgedCharacters else { return false }
        if Set(compact).count <= maxDistinctCharacters { return true }
        return topGramShare(of: Array(compact)) >= maxTopGramShare
    }

    /// Caractères qui ne portent AUCUN sens à eux seuls dans un tableau :
    /// chiffres, séparateurs décimaux et de colonnes, signes d'opération, tuyau
    /// de bordure. Une lettre n'y est jamais — c'est elle, et elle seule, qui
    /// fait qu'un texte dit quelque chose.
    static let tabularCharacters = Set(".,;:/-+%|()[]<>=*€$£#'\"\\")

    /// Part de caractères non tabulaires en deçà de laquelle la fenêtre est un
    /// tableau de nombres. 80 % mesuré sur la production (constat PM-09) :
    /// 24 420 des 31 986 pages de `M2SU` ont plus de chiffres que de lettres,
    /// et 99,6 % d'entre elles sont des pages de tableur. Un relevé bancaire à
    /// libellés — « VIR SEPA LOYER 12/03 −750,00 » — reste sous le seuil : ses
    /// libellés font largement plus d'un cinquième du texte.
    static let maxTabularShare = 0.8

    /// La fenêtre est-elle un tableau de nombres ?
    ///
    /// POURQUOI C'EST UNE RÈGLE DE QUALITÉ, PAS D'ESPACE DISQUE (PM-09). Le
    /// vecteur d'une colonne de nombres ne décrit rien : il est proche de tous
    /// les autres tableaux du corpus et de rien d'utile, et il occupe une place
    /// dans chaque top-k sémantique. L'économie de disque, elle, est dérisoire
    /// — 874 octets par page restante, ~21 Mo pour les 24 311 pages de tableur
    /// du corpus mesuré, contre un dépassement de budget de 110 Mo déjà acquis
    /// avant toute vectorisation. On retire ces pages du canal sémantique parce
    /// qu'elles le salissent, pas parce qu'elles pèsent.
    ///
    /// PURE, et sans base : les blancs sont retirés, le reste est compté.
    static func isMostlyNumeric(_ text: String) -> Bool {
        let compact = text.filter { !$0.isWhitespace }
        guard compact.count >= minimumJudgedCharacters else { return false }
        let tabular = compact.reduce(into: 0) { count, character in
            if character.isNumber || tabularCharacters.contains(character) {
                count += 1
            }
        }
        return Double(tabular) / Double(compact.count) >= maxTabularShare
    }

    /// Part du 4-gramme le plus fréquent, de 0 à 1.
    ///
    /// Quatre caractères plutôt qu'un seul : « abababab » a deux caractères
    /// distincts et serait pris par la première règle, mais « 123123123… » en a
    /// trois, « les CGV recopiées » aucune régularité de ce genre, et une
    /// bordure « -=-=-=- » quatre. Le 4-gramme attrape la PÉRIODICITÉ, qui est
    /// ce qui rend un vecteur inutile.
    static func topGramShare(of characters: [Character]) -> Double {
        guard characters.count >= 4 else { return 0 }
        var counts: [String: Int] = [:]
        counts.reserveCapacity(characters.count)
        for start in 0...(characters.count - 4) {
            counts[String(characters[start..<(start + 4)]), default: 0] += 1
        }
        let total = characters.count - 3
        return Double(counts.values.max() ?? 0) / Double(total)
    }
}

/// La question posée à l'index : « combien de documents portent CE passage ? »
enum SharedTextProbe {

    /// Longueur minimale d'une fenêtre interrogée. En deçà, deux phrases de
    /// huit mots ne tiennent pas, et le prix de la sonde ne se justifierait pas
    /// pour une queue de page.
    static let minimumCharacters = 400

    /// Mots d'une phrase témoin.
    static let wordsPerPhrase = 8

    /// Les deux phrases témoins d'une fenêtre, ou `nil` si le texte est trop
    /// court pour en fournir deux.
    ///
    /// DEUX phrases, et à 25 % et 75 % : une seule attraperait la ligne
    /// d'en-tête commune à deux documents par ailleurs différents (« Conditions
    /// générales de vente »), et un `AND` de deux phrases éloignées ne se
    /// satisfait que d'un texte réellement recopié. Un mot est une suite de
    /// lettres ou de chiffres : la ponctuation et les guillemets ne sont donc
    /// jamais dans la requête, et il n'y a rien à échapper — l'échappement de
    /// `"` est gardé par prudence, pour le jour où la définition changerait.
    static func phrases(of text: String) -> (String, String)? {
        guard text.count >= minimumCharacters else { return nil }
        let words = text.split(whereSeparator: { !$0.isLetter && !$0.isNumber })
            .map(String.init)
        guard words.count >= wordsPerPhrase * 2 else { return nil }
        let span = words.count - wordsPerPhrase
        let first = Int((Double(span) * 0.25).rounded())
        let second = Int((Double(span) * 0.75).rounded())
        // Deux phrases qui se chevaucheraient ne prouveraient rien de plus
        // qu'une seule : mieux vaut alors ne pas sonder.
        guard second >= first + wordsPerPhrase else { return nil }
        return (phrase(words, at: first), phrase(words, at: second))
    }

    private static func phrase(_ words: [String], at start: Int) -> String {
        words[start..<(start + wordsPerPhrase)].joined(separator: " ")
    }

    /// La requête FTS5 brute : les deux phrases exactes, toutes deux présentes.
    static func query(_ pair: (String, String)) -> String {
        "\"\(escaped(pair.0))\" AND \"\(escaped(pair.1))\""
    }

    /// Une requête complète depuis un texte, ou `nil` s'il n'y a pas de quoi
    /// interroger.
    static func query(for text: String) -> String? {
        phrases(of: text).map(query)
    }

    private static func escaped(_ phrase: String) -> String {
        phrase.replacingOccurrences(of: "\"", with: "\"\"")
    }
}
