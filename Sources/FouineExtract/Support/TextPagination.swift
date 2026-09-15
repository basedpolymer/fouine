// TextPagination.swift — pagination des formats non paginés (SPEC §5.3).
// Propriété : A-Ingest.
//
// « Découper à pageSplitChars (4 000) sur la frontière de paragraphe la plus
// proche. Sans cela, NEAR perd son sens sur un fichier de 2 Mo et les extraits
// ne sont pas navigables. »
//
// Le découpage est DÉTERMINISTE : c'est ce qui garantit que
// OOXMLMedia.mediaMap renumérote les médias exactement comme l'extraction (§5.3).
//
// DEUX CORRECTIONS DU 10/09/2026 (constat C2-06), et la première explique
// probablement la seconde :
//
//   · LE CRLF ÉTAIT INVISIBLE. `range(of: "\n\n")` cherchait DEUX caractères
//     `\n` ; or dans un fichier Windows — *Guerre et Paix* du Projet Gutenberg
//     en est un — une fin de ligne est `\r\n`, qui est UN SEUL `Character` en
//     Swift. Aucune frontière de paragraphe n'était donc jamais trouvée, aucune
//     frontière de ligne non plus, et les 806 coupes du livre tombaient toutes
//     en coupe dure. C'est ce qui a produit « Na | tásha » et fait disparaître
//     de l'index les mots coupés en deux.
//   · FAUTE DE LIGNE, ON COUPE AU DERNIER BLANC. La coupe dure ne reste que
//     pour un tronçon qui n'a pas un seul blanc (un `.min.js`, une colonne de
//     base 64) : là, il n'y a pas de mot à préserver.
//
// Ce qui NE change pas : la concaténation des pages redonne le texte d'origine,
// caractère pour caractère. Le CHEVAUCHEMENT des fenêtres (une expression à
// cheval sur deux pages reste introuvable) n'est PAS ici : il changerait le
// texte affiché de chaque page, et il est remis à la 1.1.

import Foundation

enum TextPagination {
    /// Pages d'au plus `limit` caractères, coupées sur une frontière de
    /// paragraphe, sinon de ligne, sinon de mot, sinon en coupe dure. Les pages
    /// sont rendues dans l'ordre, sans perte : leur concaténation redonne le
    /// texte d'origine.
    static func paginate(_ text: String, limit: Int) -> [String] {
        guard !text.isEmpty else { return [] }
        guard limit > 0 else { return [text] }

        var pages: [String] = []
        var start = text.startIndex
        while start < text.endIndex {
            guard let hardEnd = text.index(start, offsetBy: limit, limitedBy: text.endIndex),
                  hardEnd < text.endIndex
            else {
                pages.append(String(text[start...]))
                break
            }
            var cut = boundary(in: text, from: start, to: hardEnd) ?? hardEnd
            if cut <= start { cut = hardEnd }   // sécurité : on avance toujours
            pages.append(String(text[start..<cut]))
            start = cut
        }
        return pages
    }

    /// La meilleure coupe du tronçon `start..<end`, ou `nil` s'il n'y en a
    /// aucune (aucun blanc du tout).
    ///
    /// UN SEUL PARCOURS, en avant : `String` n'est pas indexable en O(1), et
    /// trois recherches arrière sur un tronçon de 4 000 caractères coûteraient
    /// trois fois le prix d'un seul balayage. Les trois candidats sont retenus
    /// au vol, et l'index rendu est celui d'APRÈS le séparateur — la page se
    /// termine donc par sa ponctuation, et la suivante commence par un mot
    /// entier.
    private static func boundary(in text: String,
                                 from start: String.Index,
                                 to end: String.Index) -> String.Index? {
        var paragraph: String.Index?
        var line: String.Index?
        var blank: String.Index?
        var previousWasNewline = false
        var index = start
        while index < end {
            let next = text.index(after: index)
            let character = text[index]
            // `isNewline` reconnaît `\n`, `\r`, `\r\n` (un seul Character) et
            // les séparateurs Unicode : c'est ce que la recherche de « \n\n »
            // ne savait pas voir.
            if character.isNewline {
                if previousWasNewline { paragraph = next }
                line = next
                blank = next
                previousWasNewline = true
            } else {
                if character.isWhitespace { blank = next }
                previousWasNewline = false
            }
            index = next
        }
        return paragraph ?? line ?? blank
    }

    /// Vraie si la page ne porte que des blancs : inutile de l'indexer, mais son
    /// emplacement reste compté dans `pageCount` (numérotation stable).
    static func isBlank(_ page: String) -> Bool {
        page.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }
}

/// Plafond `limits.maxTextBytes` sur le texte TOTAL d'un document (§4.2).
/// Tronque sur une frontière de caractère, jamais au milieu d'un scalaire UTF-8.
struct TextBudget {
    private(set) var remaining: Int
    /// Une TRONCATURE suffit à déclarer le budget épuisé : sans cela, un reliquat
    /// trop petit pour le prochain caractère (« é » sur 1 octet libre) laissait
    /// `remaining > 0` à jamais et les `break` des extracteurs paginés ne se
    /// déclenchaient plus (A11.9).
    private var truncated = false

    init(maxBytes: Int) { remaining = max(0, maxBytes) }

    var isExhausted: Bool { remaining <= 0 || truncated }

    mutating func take(_ text: String) -> String {
        guard !truncated, remaining > 0 else { return "" }
        let size = text.utf8.count
        if size <= remaining {
            remaining -= size
            return text
        }
        var out = String()
        out.reserveCapacity(remaining)
        var used = 0
        for ch in text {
            let n = String(ch).utf8.count
            if used + n > remaining { break }
            out.append(ch)
            used += n
        }
        remaining -= used
        truncated = true
        return out
    }
}
