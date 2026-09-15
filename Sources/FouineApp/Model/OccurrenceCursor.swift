// OccurrenceCursor.swift — d'une occurrence à la suivante dans l'aperçu (PN1).
// Propriété : A-App.
//
// POURQUOI. Le PDF surligne jusqu'à 400 occurrences par terme sur la page, mais
// l'aperçu ne sautait qu'à la PREMIÈRE : pour les autres, on faisait défiler à
// l'aveugle, sans savoir combien il y en avait. Le curseur range les
// occurrences dans l'ordre où on les lit et passe de l'une à l'autre.
//
// Tout ici est PUR : pas de PDFKit. `PDFPreviewView.Coordinator` fournit les
// rectangles et garde, sous l'identifiant `id`, ce qu'il faut pour y aller
// (une sélection, une annotation) ; l'en-tête ne lit que la position et les
// comptes.

import Foundation
import CoreGraphics

struct OccurrenceCursor: Equatable {

    struct Occurrence: Equatable {
        /// Le terme tel que saisi.
        let term: String
        /// Sa place dans `SearchModel.terms` : c'est elle qui donne la couleur.
        let termIndex: Int
        /// En coordonnées de page PDF : l'origine est EN BAS, y croît vers le
        /// haut.
        let rect: CGRect
        /// Rendu tel quel à l'appelant, qui y retrouve sa cible.
        let id: Int
    }

    /// Dans l'ordre de lecture.
    let occurrences: [Occurrence]
    /// `nil` si et seulement si le curseur est vide.
    private(set) var currentIndex: Int?

    /// `rotation` : `PDFPage.rotation`, en degrés horaires (multiples de 90).
    /// Les rectangles restent en coordonnées de page NON tournée ; c'est l'ordre
    /// qui suit la page telle qu'on la lit.
    init(_ unordered: [Occurrence] = [], rotation: Int = 0) {
        occurrences = Self.readingOrder(unordered, rotation: rotation)
        currentIndex = occurrences.isEmpty ? nil : 0
    }

    var isEmpty: Bool { occurrences.isEmpty }
    var count: Int { occurrences.count }

    var current: Occurrence? { currentIndex.map { occurrences[$0] } }

    /// La position affichée, à partir de 1.
    var position: Int? { currentIndex.map { $0 + 1 } }

    /// LE CURSEUR BOUCLE DANS LA PAGE : après la dernière, la première. Passer
    /// à la page suivante est le rôle du navigateur de pages ; un curseur qui
    /// changerait de page sans qu'on le demande perdrait la page trouvée.
    @discardableResult
    mutating func next() -> Occurrence? {
        guard let i = currentIndex else { return nil }
        currentIndex = (i + 1) % occurrences.count
        return current
    }

    @discardableResult
    mutating func previous() -> Occurrence? {
        guard let i = currentIndex else { return nil }
        currentIndex = (i - 1 + occurrences.count) % occurrences.count
        return current
    }

    /// Occurrences par terme (clé : `termIndex`).
    var countsByTerm: [Int: Int] {
        occurrences.reduce(into: [:]) { $0[$1.termIndex, default: 0] += 1 }
    }

    /// Haut vers bas, puis gauche vers droite.
    ///
    /// UN TRI PAR y SEUL NE SUFFIT PAS : deux mots d'une même ligne n'ont pas
    /// le même rectangle — « Azote » monte plus haut que « azote », une
    /// sélection prend la hauteur de ses glyphes —, et « le plus haut d'abord »
    /// les rangerait au hasard des majuscules. On regroupe donc en lignes : un
    /// rectangle rejoint la ligne ouverte tant que son milieu reste au-dessus du
    /// bas du rectangle qui l'a ouverte.
    ///
    /// LA PAGE TOURNÉE (lot MN2). PDFKit rend les rectangles dans l'espace de
    /// la page NON tournée : sur un scan redressé de 90°, le haut de la page
    /// qu'on lit est son bord gauche, et le tri sur `maxY` faisait sauter
    /// « suivant » dans le désordre. Le tri se fait donc sur le rectangle tel
    /// que la page tournée le montre (`displayed`).
    static func readingOrder(_ items: [Occurrence], rotation: Int = 0) -> [Occurrence] {
        let turn = ((rotation % 360) + 360) % 360
        let placed = items.enumerated().map { entry in
            Placed(item: entry.element, offset: entry.offset,
                   rect: displayed(entry.element.rect, rotation: turn))
        }
        let byTop = placed.sorted { a, b in
            if a.rect.maxY != b.rect.maxY { return a.rect.maxY > b.rect.maxY }
            if a.rect.minX != b.rect.minX { return a.rect.minX < b.rect.minX }
            return a.offset < b.offset
        }

        var lines: [[Placed]] = []
        var floor = CGFloat.infinity
        for entry in byTop {
            if !lines.isEmpty, entry.rect.midY >= floor {
                lines[lines.count - 1].append(entry)
            } else {
                lines.append([entry])
                floor = entry.rect.minY
            }
        }
        return lines.flatMap { line in
            line.enumerated().sorted { a, b in
                a.element.rect.minX != b.element.rect.minX
                    ? a.element.rect.minX < b.element.rect.minX
                    : a.offset < b.offset
            }.map(\.element.item)
        }
    }

    private struct Placed {
        let item: Occurrence
        let offset: Int
        let rect: CGRect
    }

    /// Le rectangle tel que la page tournée le montre, dans le même repère
    /// (origine en bas, y vers le haut), pour une rotation HORAIRE déjà ramenée
    /// à 0, 90, 180 ou 270 — la convention de `OCRGeometry.denormalize`. Seul
    /// l'ORDRE en sort : une translation ne le change pas, d'où l'absence du
    /// mediaBox.
    static func displayed(_ rect: CGRect, rotation: Int) -> CGRect {
        switch rotation {
        case 90:
            return CGRect(x: rect.minY, y: -rect.maxX,
                          width: rect.height, height: rect.width)
        case 180:
            return CGRect(x: -rect.maxX, y: -rect.maxY,
                          width: rect.width, height: rect.height)
        case 270:
            return CGRect(x: -rect.maxY, y: rect.minX,
                          width: rect.height, height: rect.width)
        default:
            return rect
        }
    }
}

/// Les comptes par terme de l'en-tête de l'aperçu : une pastille de la couleur
/// du terme, le mot, le nombre.
enum OccurrenceTally {

    /// Au-delà, les termes passent dans l'infobulle : l'en-tête partage sa
    /// ligne avec le numéro de page et l'origine du texte.
    static let visibleLimit = 5

    /// Comptes par terme (clé : place dans `terms`), et les termes dont le
    /// compte a buté sur son plafond.
    struct Counts: Equatable {
        var byTerm: [Int: Int] = [:]
        var capped: Set<Int> = []
    }

    struct Chip: Equatable, Identifiable {
        let label: String
        let colorIndex: Int
        let count: Int
        /// Le plafond de surlignage a mordu : il y en a PLUS que `count`.
        let atLeast: Bool
        var id: Int { colorIndex }
    }

    /// Une pastille par COULEUR, pas par terme : les formes que le moteur
    /// cherche avec un mot (« polymeres » pour « polymere », lot R1) partagent
    /// sa couleur et comptent avec lui, sous le mot TAPÉ. Deux pastilles de la
    /// même teinte liraient comme un doublon. Un terme absent de la page n'a
    /// pas de pastille : elles disent où regarder.
    static func chips(terms: [HighlightTerm], counts: Counts) -> [Chip] {
        var order: [Int] = []
        var label: [Int: String] = [:]
        var total: [Int: Int] = [:]
        var atLeast: Set<Int> = []
        for (index, term) in terms.enumerated() {
            let color = term.colorIndex
            if label[color] == nil {
                label[color] = term.text
                order.append(color)
            }
            total[color, default: 0] += counts.byTerm[index] ?? 0
            if counts.capped.contains(index) { atLeast.insert(color) }
        }
        return order.compactMap { color in
            guard let n = total[color], n > 0 else { return nil }
            return Chip(label: label[color] ?? "", colorIndex: color, count: n,
                        atLeast: atLeast.contains(color))
        }
    }

    /// Occurrences de chaque terme dans un texte (clé : place dans `terms`),
    /// avec LA RÈGLE DU SURLIGNAGE (`TextHighlighter`) : insensible à la casse
    /// et aux accents, frontières de jeton, un préfixe mord sur la suite du
    /// mot. `TextHighlighter.Result` ne connaît que le total, et après avoir
    /// retiré les chevauchements — d'où cette passe à part.
    ///
    /// `limit` borne le parcours par terme : un mot de deux lettres trouvé
    /// 30 000 fois ne doit pas figer l'aperçu pour un nombre.
    static func counts(in text: String, terms: [HighlightTerm],
                       limit: Int = TextHighlighter.maxOccurrences) -> Counts {
        var counts: [Int: Int] = [:]
        var capped: Set<Int> = []
        for (index, term) in terms.enumerated() where term.text.count >= 2 {
            var n = 0
            var from = text.startIndex
            while from < text.endIndex,
                  let found = text.range(of: term.text,
                                         options: [.caseInsensitive,
                                                   .diacriticInsensitive],
                                         range: from..<text.endIndex) {
                guard TokenBoundary.startsToken(text, at: found.lowerBound),
                      term.kind == .prefix
                        || TokenBoundary.endsToken(text, at: found.upperBound)
                else {
                    from = text.index(after: found.lowerBound)
                    continue
                }
                guard n < limit else {
                    capped.insert(index)
                    break
                }
                n += 1
                from = found.upperBound > found.lowerBound
                    ? found.upperBound : text.index(after: found.lowerBound)
            }
            if n > 0 { counts[index] = n }
        }
        return Counts(byTerm: counts, capped: capped)
    }
}
