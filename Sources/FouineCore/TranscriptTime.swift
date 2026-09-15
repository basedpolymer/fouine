// TranscriptTime.swift — le MOMENT d'un extrait de transcription.
// SPDX-License-Identifier: LicenseRef-Fouine-Source-Available
// Propriété : A-Core. Lot MC2 (constat PM-22).
//
// POURQUOI CE FICHIER EXISTE. Le moment d'une parole n'est nulle part ailleurs
// que dans le TEXTE de la page : `page_src` n'a pas de colonne de temps, il n'y
// a pas de table `media`, et `SpeechTranscriber.paragraphs` écrit un marqueur
// `[MM:SS]` (ou `[H:MM:SS]` au-delà d'une heure) en tête de chaque paragraphe.
// Une page de transcription couvre dix minutes d'enregistrement : citer
// « page 1 » d'une vidéo de deux heures ne renvoie personne nulle part, alors
// que `DeepLink` sait porter un `t=` depuis le lot PV1 et que personne ne lui
// en donnait.
//
// PUR, ET C'EST LA CONDITION POUR L'ÉPROUVER : ce fichier ne lit ni la base ni
// le disque. L'appelant apporte l'extrait (ou le texte de la page) ; il rend un
// nombre de secondes, jamais une phrase.
//
// LE MARQUEUR QUI COMPTE EST LE DERNIER AVANT L'EXTRAIT SURLIGNÉ, pas le
// premier de l'extrait : FTS5 rend un extrait qui commence où il veut, et le
// mot trouvé y est encadré par les marqueurs de surlignage (`«` … `»` par
// défaut). Le moment à citer est donc celui du paragraphe qui PORTE ce mot.

import Foundation

public enum TranscriptTime {

    /// Le moment, en secondes, à citer pour un extrait de transcription.
    ///
    /// - Parameters:
    ///   - snippet: l'extrait rendu par la recherche, marqueurs de surlignage
    ///     compris.
    ///   - opening: le marqueur OUVRANT de la recherche (`SearchQuery.snippetMarkers`).
    ///     Vide — `marks: "none"` — ou absent de l'extrait : on lit le dernier
    ///     marqueur de temps de tout l'extrait.
    /// - Returns: `nil` quand l'extrait ne porte aucun marqueur de temps avant
    ///   le mot trouvé ; l'appelant retombe alors sur `first(in:)`, le début de
    ///   la page.
    public static func seconds(inSnippet snippet: String, opening: String) -> Int? {
        let limit: String.Index
        if !opening.isEmpty, let found = snippet.range(of: opening) {
            limit = found.lowerBound
        } else {
            limit = snippet.endIndex
        }
        return markers(in: snippet, before: limit).last
    }

    /// Le PREMIER marqueur de temps d'un texte — le début de la page, quand
    /// l'extrait n'en porte aucun.
    public static func first(in text: String) -> Int? {
        markers(in: text, before: text.endIndex).first
    }

    // MARK: - Lecture des marqueurs

    /// Longueur maximale d'un marqueur, crochets exclus : `10:59:59` fait huit
    /// caractères. Au-delà, le crochet ouvrant appartient à autre chose (une
    /// note, une référence bibliographique) et on ne va pas le chercher plus
    /// loin — c'est ce qui garde la lecture linéaire.
    private static let maxTokenLength = 8

    /// Les moments, en secondes, des marqueurs qui précèdent `limit`, dans
    /// l'ordre du texte.
    static func markers(in text: String, before limit: String.Index) -> [Int] {
        var out: [Int] = []
        var index = text.startIndex
        while index < limit {
            guard text[index] == "[" else {
                index = text.index(after: index)
                continue
            }
            var cursor = text.index(after: index)
            var token = ""
            while cursor < limit, text[cursor] != "]", token.count <= maxTokenLength {
                token.append(text[cursor])
                cursor = text.index(after: cursor)
            }
            if cursor < limit, text[cursor] == "]", let seconds = parse(token) {
                out.append(seconds)
                index = text.index(after: cursor)
            } else {
                index = text.index(after: index)
            }
        }
        return out
    }

    /// `MM:SS` ou `H:MM:SS` en secondes. `nil` pour tout le reste — un
    /// `[voir p. 12]` n'est pas un moment, et le prendre pour tel ferait citer
    /// une vidéo à la douzième seconde.
    static func parse(_ token: String) -> Int? {
        let parts = token.split(separator: ":", omittingEmptySubsequences: false)
        guard parts.count == 2 || parts.count == 3 else { return nil }
        var values: [Int] = []
        for (offset, part) in parts.enumerated() {
            // Les deux derniers groupes font DEUX chiffres (`%02d`), le premier
            // en fait un ou deux : c'est la forme exacte de
            // `MediaMetadata.timestamp`, et s'en écarter accepterait `1:2:3`.
            let expected = offset == 0 ? 1...2 : 2...2
            guard expected.contains(part.count),
                  part.allSatisfy({ $0.isASCII && $0.isNumber }),
                  let value = Int(part) else { return nil }
            values.append(value)
        }
        // Minutes et secondes sont des restes : au-delà de 59 ce n'est pas un
        // horodatage mais une notation quelconque.
        guard values.suffix(2).allSatisfy({ $0 < 60 }) else { return nil }
        return values.reduce(0) { $0 * 60 + $1 }
    }
}
