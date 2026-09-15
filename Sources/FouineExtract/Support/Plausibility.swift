// Plausibility.swift — contrôle de plausibilité, OBLIGATOIRE pour tout format
// riche (SPEC §5.3, piège §7.2 n°3). Propriété : A-Ingest.
//
// « Sans ce contrôle, le mojibake entre dans page_fts, donc dans fts5vocab, donc
// dans l'expansion floue — dont toute la précision dépend de la propreté du
// vocabulaire. »
//
// Deux critères, tous deux mesurés sur la machine :
//   1. documentType == NSPlainText alors que l'extension annonce un format riche
//      (un .ppt binaire passé à NSAttributedString rend NSPlainText et
//       316 411 caractères de mojibake SANS lever la moindre erreur) ;
//   2. proportion de caractères hors plages lisibles > ~30 %.
//      Étalon du §7.2 n°3 : « –œ‡°±· ˛ˇ ˛ˇˇˇ ^ _ a » -> ~69 % de suspects.

import Foundation
import FouineCore

enum Plausibility {
    /// Seuil du §5.3 : « la proportion de caractères hors plages latines /
    /// ponctuation / espaces / chiffres dépasse ~30 % ».
    static let maxSuspiciousRatio = 0.30

    /// Ponctuation typographique non ASCII couramment présente dans du texte réel.
    /// Volontairement COURTE : `° ± · ‡ ˛ ˇ` en sont absents, ce sont eux qui
    /// signent le mojibake OLE/macRoman du §7.2 n°3.
    private static let typography: Set<Character> = [
        "\u{00A0}", "’", "‘", "“", "”", "«", "»", "–", "—", "…", "€",
    ]

    /// Lettres modificatives avec chasse (U+02B0…U+02FF) : `ˇ ˛ ˆ ˘ ˙`. Absentes
    /// du texte réel, omniprésentes dans le mojibake macRoman du §7.2 n°3 — et
    /// `Character.isLetter` les déclare lettres, d'où ce filtre explicite.
    private static let modifierBlock: ClosedRange<UInt32> = 0x02B0...0x02FF

    static func isReadable(_ ch: Character) -> Bool {
        if ch == "\n" || ch == "\r" || ch == "\t" { return true }
        if let scalar = ch.unicodeScalars.first, ch.unicodeScalars.count == 1 {
            if scalar.value >= 0x20, scalar.value <= 0x7E {
                return true                   // ASCII imprimable : lettres, chiffres,
            }                                 // ponctuation et symboles usuels
            if modifierBlock.contains(scalar.value) { return false }
        }
        if ch.isLetter || ch.isNumber || ch.isWhitespace { return true }
        return typography.contains(ch)
    }

    /// Proportion de caractères suspects, 0…1. Texte vide -> 0.
    static func suspiciousRatio(_ text: String) -> Double {
        var total = 0, suspicious = 0
        for ch in text {
            total += 1
            if !isReadable(ch) { suspicious += 1 }
        }
        guard total > 0 else { return 0 }
        return Double(suspicious) / Double(total)
    }

    /// Assez de caractères pour trancher sans parcourir 50 Mio : le mojibake d'un
    /// binaire est uniforme, il se voit dès les premiers milliers de caractères.
    static let sampleCharacters = 64_000

    /// Vraie si le texte peut être du texte. Mesuré sur un ÉCHANTILLON de tête.
    static func isPlausible(_ text: String) -> Bool {
        suspiciousRatio(String(text.prefix(sampleCharacters))) <= maxSuspiciousRatio
    }

    /// Plus longue suite de caractères sans aucun blanc (espace, tabulation,
    /// fin de ligne, espaces Unicode), mesurée sur l'échantillon de tête (EX2).
    /// Un export de données l'est dès ses premiers kilo-octets ; un document
    /// dont la tête est lisible et la queue une colonne de base 64 passe, et
    /// c'est la pagination qui coupe cette queue en dur.
    ///
    /// LES IMAGES EMBARQUÉES NE COMPTENT PAS (lot MN1) : voir
    /// `withoutDataURIs`. C'est le seul écart, et il est fait ici pour que les
    /// deux appelants — le refus à l'extraction et les tests — mesurent la même
    /// chose.
    static func longestRunWithoutWhitespace(in text: String) -> Int {
        var longest = 0, current = 0
        for ch in withoutDataURIs(String(text.prefix(sampleCharacters))) {
            if ch.isWhitespace {
                current = 0
            } else {
                current += 1
                if current > longest { longest = current }
            }
        }
        return longest
    }

    /// Le texte privé de ses adresses `data:` (lot MN1, faux refus signalé par
    /// EX2).
    ///
    /// Un `.md` exporté par Typora ou Obsidian embarque ses images en
    /// `![courbe](data:image/png;base64,iVBORw0…)` : une suite de dizaines de
    /// milliers de caractères sans blanc, qui faisait refuser TOUT le fichier —
    /// mesuré le 14/09/2026, un compte rendu de réunion de deux paragraphes et
    /// une image refusé sur une « suite de 12 033 caractères ». L'image n'est
    /// pas du texte à indexer, mais ce n'est pas un vidage de données : elle a
    /// une syntaxe, elle se reconnaît, et le texte autour est parfaitement
    /// lisible.
    ///
    /// La suite est consommée jusqu'au premier blanc — c'est ainsi que se
    /// termine une adresse `data:` dans du Markdown, du HTML ou du CSS. Une
    /// colonne de base 64 NUE, elle, n'a pas d'introducteur et reste un refus
    /// (c'est le cas que le garde-fou d'EX2 visait).
    static func withoutDataURIs(_ text: String) -> String {
        guard let first = text.range(of: "data:", options: .caseInsensitive)
        else { return text }
        var out = String(text[text.startIndex..<first.lowerBound])
        var index = first.lowerBound
        while index < text.endIndex {
            if dataPrefix(text, at: index) {
                // On saute l'introducteur ET sa valeur, d'un seul geste.
                while index < text.endIndex, !text[index].isWhitespace {
                    index = text.index(after: index)
                }
            } else {
                out.append(text[index])
                index = text.index(after: index)
            }
        }
        return out
    }

    /// `data:` à cette position, casse ignorée — sans fabriquer de sous-chaîne.
    private static func dataPrefix(_ text: String, at index: String.Index) -> Bool {
        var cursor = index
        for expected in "data:" {
            guard cursor < text.endIndex,
                  text[cursor].lowercased() == String(expected) else { return false }
            cursor = text.index(after: cursor)
        }
        return true
    }

    /// Octets à sonder pour le test binaire : un en-tête de format binaire tient
    /// toujours là-dedans, et un texte n'y porte jamais d'octet NUL.
    static let sniffBytes = 8 << 10

    /// Vraie si ces octets ne peuvent PAS être du texte.
    ///
    /// Le seul critère est l'octet NUL, mais il est décisif (A11.4) : aucun des
    /// encodages ÉTROITS du §5.3 amendé (EX2) n'en produit — UTF-8,
    /// Windows-1252, ISO-8859-1, MacRoman, et l'encodage déclaré par
    /// `com.apple.TextEncoding` quand il n'est pas large —, alors qu'il ouvre
    /// les en-têtes de PNG, de PDF compressé, de Mach-O, de zip — et qu'il
    /// sépare un octet sur deux d'un fichier UTF-16. Les encodages LARGES
    /// (UTF-16, UTF-32) échappent donc à ce test, par leur BOM ici et par la
    /// liste `wide` de `PlainTextExtractor.decode(_:as:)` pour l'encodage
    /// déclaré. Sans lui, `String(data:encoding:.isoLatin1)`
    /// réussit sur les 256 valeurs d'octet possibles et TOUT binaire renommé .txt
    /// entre en mojibake dans page_fts, donc dans fts5vocab, donc dans l'expansion
    /// floue. Le reste du mojibake est attrapé par `suspiciousRatio`.
    static func looksBinary(_ data: Data) -> Bool {
        if data.starts(with: [0xEF, 0xBB, 0xBF]) {
            return data.dropFirst(3).prefix(sniffBytes).contains(0)
        }
        if data.starts(with: [0xFF, 0xFE]) || data.starts(with: [0xFE, 0xFF]) {
            return false
        }
        return data.prefix(sniffBytes).contains(0)
    }

    /// Lève `FouineError.extraction("contenu implausible (mojibake)…")` si le texte
    /// ne peut pas être du texte. Ne rien laisser passer d'autre.
    static func check(_ text: String, ext: String) throws {
        let ratio = suspiciousRatio(text)
        if ratio > maxSuspiciousRatio {
            throw FouineError.extraction(
                String(format: "implausible content (mojibake): %.0f%% of the "
                       + "characters are outside the readable ranges for a .%@",
                       ratio * 100, ext))
        }
    }
}
