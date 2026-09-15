// Highlighting.swift — termes à surligner, couleurs, découpage des extraits.
// Propriété : A-App. SPEC §5.6 : « une couleur distincte par terme de la requête,
// comme FoxTrot ».

import Foundation
import SwiftUI
import AppKit
import FouineCore

/// Un terme de la requête, avec la couleur qui lui est attachée pour toute la
/// session de recherche : la même dans l'extrait, dans le PDF natif et sur les
/// boîtes OCR.
struct HighlightTerm: Identifiable, Hashable {
    enum Kind: Hashable { case word, phrase, prefix }

    let text: String        // tel que saisi
    let folded: String      // minuscule, sans accents : c'est lui qui compare
    let kind: Kind
    let colorIndex: Int

    var id: String { "\(kind)-\(folded)" }

    var color: Color { TermPalette.color(colorIndex) }
    var nsColor: NSColor { TermPalette.nsColor(colorIndex) }
}

enum TermPalette {
    /// Huit teintes franches, lisibles en clair comme en sombre et distinctes
    /// pour un œil normal ; au-delà de huit termes on recycle.
    static let base: [NSColor] = [
        NSColor.systemYellow, NSColor.systemGreen, NSColor.systemPink,
        NSColor.systemTeal, NSColor.systemOrange, NSColor.systemPurple,
        NSColor.systemBlue, NSColor.systemRed,
    ]

    static func nsColor(_ index: Int) -> NSColor {
        base[((index % base.count) + base.count) % base.count]
    }

    static func color(_ index: Int) -> Color { Color(nsColor: nsColor(index)) }

    /// Teinte de fond d'un extrait : la couleur diluée, pour rester lisible
    /// derrière du texte.
    static func wash(_ index: Int) -> Color { color(index).opacity(0.28) }
}

/// LES FRONTIÈRES DE JETON (audit A2-17).
///
/// La recherche compte des JETONS — `unicode61 remove_diacritics 2` découpe le
/// texte sur tout ce qui n'est ni lettre ni chiffre —, alors que le surlignage
/// cherchait des SOUS-CHAÎNES (`text.range(of:)`). Un terme de trois lettres
/// surlignait donc l'intérieur des mots : « or » dans « sort », « pour »,
/// « corps », « d'abord ». L'utilisateur voyait des couleurs là où le moteur
/// n'avait rien trouvé — et c'est exactement ce que le plafond de 400
/// occurrences par terme essayait de contenir.
///
/// La règle est celle du tokenizer, pas celle de `\b` : est une frontière tout
/// caractère qui n'est ni une lettre ni un chiffre. L'apostrophe en fait partie,
/// et c'est juste — FTS5 coupe « l'enthalpie » en deux jetons, donc
/// « enthalpie » y est bien un mot entier.
enum TokenBoundary {

    static func isWordCharacter(_ c: Character) -> Bool { c.isLetter || c.isNumber }

    /// L'occurrence commence-t-elle un jeton ?
    static func startsToken(_ text: String, at index: String.Index) -> Bool {
        guard index > text.startIndex else { return true }
        return !isWordCharacter(text[text.index(before: index)])
    }

    /// L'occurrence finit-elle un jeton ? Un PRÉFIXE (`spectro*`) n'a pas à le
    /// vérifier : il est censé mordre sur la suite du mot.
    static func endsToken(_ text: String, at index: String.Index) -> Bool {
        guard index < text.endIndex else { return true }
        return !isWordCharacter(text[index])
    }

    /// `needle` apparaît-il dans `haystack` comme un jeton entier ? Les deux
    /// chaînes sont supposées déjà repliées (`StoreService.fold`).
    static func contains(_ haystack: String, token needle: String,
                         asPrefix: Bool = false) -> Bool {
        guard !needle.isEmpty else { return false }
        var from = haystack.startIndex
        while from < haystack.endIndex,
              let found = haystack.range(of: needle, range: from..<haystack.endIndex) {
            if startsToken(haystack, at: found.lowerBound),
               asPrefix || endsToken(haystack, at: found.upperBound) {
                return true
            }
            from = haystack.index(after: found.lowerBound)
        }
        return false
    }
}

enum QueryTerms {

    /// Termes surlignables extraits de la requête : mots nus, membres de `pres:`,
    /// phrases exactes et racines de préfixe.
    ///
    /// Les négations ne sont pas seulement sautées, elles sont RETIRÉES du jeu :
    /// une requête peut porter le même mot des deux côtés (`alpha -alpha`, ou
    /// `pres:3 azote biologie -biologie`), et surligner un terme dont on a
    /// demandé l'exclusion désignerait à l'utilisateur exactement ce qu'il a
    /// écarté (audit F1). Le repli de `match` compare par `contains` : sans ce
    /// retrait, un préfixe positif pourrait en plus attraper un exclu.
    static func extract(from input: String) -> [HighlightTerm] {
        guard let parsed = try? QueryParser.parse(input) else { return [] }
        var out: [HighlightTerm] = []
        var seen = Set<String>()
        let banned = Set(Self.negatives(of: parsed).map(StoreService.fold))

        var nextColor = 0
        /// Ajoute un terme ; rend l'indice de couleur qu'il a reçu, ou nil s'il
        /// a été écarté (trop court, exclu, déjà vu).
        @discardableResult
        func add(_ text: String, _ kind: HighlightTerm.Kind,
                 colorIndex: Int? = nil) -> Int? {
            let folded = StoreService.fold(text)
            guard folded.count >= 2, !banned.contains(folded),
                  seen.insert("\(kind)-\(folded)").inserted else { return nil }
            let color = colorIndex ?? nextColor
            if colorIndex == nil { nextColor += 1 }
            out.append(HighlightTerm(text: text, folded: folded, kind: kind,
                                     colorIndex: color))
            return color
        }

        let bare = parsed.nodes.compactMap { node -> String? in
            if case .term(let t) = node { return t }
            return nil
        }
        for node in parsed.nodes {
            switch node {
            case .term(let t):
                // Les formes que le moteur cherche AVEC le mot (lot R1,
                // `Morphology` : « polymere » → « polymeres ») portent la
                // couleur du mot tapé : une page trouvée par le pluriel doit
                // montrer où, et de la même couleur. Parmi les autres mots
                // tapés : « polymere polymeres » fait deux termes, deux
                // couleurs, et non un mot absorbé par l'autre (AUDIT-R1 M8).
                // Un membre de `pres:`, lui, n'est pas décliné par le moteur
                // (FTS5 n'accepte pas de OR dans un NEAR) : pas ici non plus.
                if let color = add(t, .word) {
                    for form in Morphology.variants(of: t, among: bare) {
                        add(form, .word, colorIndex: color)
                    }
                }
            case .phrase(let p): add(p, .phrase)
            case .prefix(let p): add(p, .prefix)
            case .near(let members, _): for m in members { add(m, .word) }
            case .not: break
            }
        }
        return out
    }

    /// Termes exclus (`-terme`), tels que saisis. L'interface les affiche comme
    /// des pastilles de filtre : l'exclusion doit se VOIR, faute de quoi une
    /// liste plus courte que prévu reste inexplicable (audit F1).
    static func excluded(from input: String) -> [String] {
        guard let parsed = try? QueryParser.parse(input) else { return [] }
        return negatives(of: parsed)
    }

    private static func negatives(of parsed: ParsedQuery) -> [String] {
        parsed.nodes.compactMap { node in
            if case .not(let t) = node { return t }
            return nil
        }
    }

    /// Le terme dont `text` est une occurrence, s'il y en a un. Pour un fragment
    /// court (segment d'extrait, mot).
    static func match(_ text: String, in terms: [HighlightTerm]) -> HighlightTerm? {
        let folded = StoreService.fold(text)
        if let exact = terms.first(where: { $0.folded == folded }) { return exact }
        if let prefixed = terms.first(where: {
            $0.kind == .prefix && folded.hasPrefix($0.folded)
        }) { return prefixed }
        return terms.first(where: { folded.contains($0.folded) })
    }

    /// Le premier terme contenu dans une ligne entière (ligne OCR, §5.6),
    /// comme JETON et non comme sous-chaîne (audit A2-17) : sans quoi une ligne
    /// contenant « sort » se surlignait pour le terme « or ».
    static func matchInText(_ text: String, terms: [HighlightTerm]) -> HighlightTerm? {
        let folded = StoreService.fold(text)
        return terms.first(where: {
            TokenBoundary.contains(folded, token: $0.folded,
                                   asPrefix: $0.kind == .prefix)
        })
    }
}

/// Surlignage d'un texte COMPLET (page indexée, audit U4), par opposition au
/// snippet FTS5 qui arrive déjà marqué.
///
/// Le moteur ne marque pas ce texte : c'est le contenu brut de `page_fts.body`.
/// On y cherche donc les termes nous-mêmes, avec la même insensibilité que le
/// tokenizer (`unicode61 remove_diacritics 2`), et on rend une
/// `AttributedString` colorée par terme — la même couleur que dans l'extrait et
/// que dans le PDF, ce qui est tout l'intérêt (§5.6).
enum TextHighlighter {

    /// Au-delà, on cesse de chercher.
    ///
    /// Une page de PDF dense peut porter des dizaines de milliers de
    /// caractères ; le coût est linéaire par terme, mais il se paie sur le fil
    /// principal à chaque changement de sélection. Le plafond garde l'aperçu
    /// instantané, et la vue DIT quand il a mordu — jamais de troncature muette
    /// (c'est le reproche fait aux 400 surlignages du PDF, audit A12).
    static let maxCharacters = 120_000
    static let maxOccurrences = 2_000

    struct Result {
        let text: AttributedString
        /// Le texte a-t-il été coupé à `maxCharacters` ?
        let truncated: Bool
        /// Le plafond d'occurrences a-t-il été atteint ?
        let capped: Bool
        let occurrences: Int
    }

    static func attributed(_ raw: String, terms: [HighlightTerm],
                           monospaced: Bool) -> Result {
        let truncated = raw.count > maxCharacters
        let text = truncated ? String(raw.prefix(maxCharacters)) : raw
        let font: Font = monospaced ? .system(.body, design: .monospaced) : .body

        var marks = ranges(in: text, terms: terms)
        let capped = marks.count > maxOccurrences
        if capped { marks.removeSubrange(maxOccurrences...) }

        var out = AttributedString()
        var cursor = text.startIndex
        for mark in marks {
            // Les plages sont triées et disjointes (voir `ranges`), mais un
            // texte réécrit sous les pieds ne coûte qu'une garde.
            guard mark.range.lowerBound >= cursor else { continue }
            var before = AttributedString(text[cursor..<mark.range.lowerBound])
            before.font = font
            out += before
            var run = AttributedString(text[mark.range])
            run.font = font.bold()
            run.backgroundColor = TermPalette.wash(mark.colorIndex)
            out += run
            cursor = mark.range.upperBound
        }
        var tail = AttributedString(text[cursor...])
        tail.font = font
        out += tail
        return Result(text: out, truncated: truncated, capped: capped,
                      occurrences: marks.count)
    }

    private struct Mark {
        let range: Range<String.Index>
        let colorIndex: Int
    }

    /// Occurrences de tous les termes, triées et SANS chevauchement : deux
    /// termes qui se recouvrent (« poly » et « polymère ») produiraient sinon
    /// des plages imbriquées, qu'on ne peut pas concaténer en un seul flux.
    /// La première trouvée gagne, ce qui privilégie le début du texte.
    private static func ranges(in text: String,
                               terms: [HighlightTerm]) -> [Mark] {
        var marks: [Mark] = []
        for term in terms where term.text.count >= 2 {
            var from = text.startIndex
            while from < text.endIndex,
                  let found = text.range(of: term.text,
                                         options: [.caseInsensitive,
                                                   .diacriticInsensitive],
                                         range: from..<text.endIndex) {
                // FRONTIÈRES DE JETON (audit A2-17) : le moteur compte des
                // jetons, le surlignage cherchait des sous-chaînes, et « or »
                // se surlignait donc dans « sort » et « pour ».
                guard TokenBoundary.startsToken(text, at: found.lowerBound),
                      term.kind == .prefix
                        || TokenBoundary.endsToken(text, at: found.upperBound)
                else {
                    from = text.index(after: found.lowerBound)
                    continue
                }
                // Un préfixe (`spectro*`) surligne le MOT entier : couper au
                // milieu d'un mot se lit comme une erreur d'affichage.
                var upper = found.upperBound
                if term.kind == .prefix {
                    while upper < text.endIndex,
                          TokenBoundary.isWordCharacter(text[upper]) {
                        upper = text.index(after: upper)
                    }
                }
                marks.append(Mark(range: found.lowerBound..<upper,
                                  colorIndex: term.colorIndex))
                from = upper > found.lowerBound ? upper
                                                : text.index(after: found.lowerBound)
                if marks.count > maxOccurrences * 2 { break }
            }
        }
        marks.sort { $0.range.lowerBound < $1.range.lowerBound }
        var disjoint: [Mark] = []
        for mark in marks {
            if let last = disjoint.last, mark.range.lowerBound < last.range.upperBound {
                continue
            }
            disjoint.append(mark)
        }
        return disjoint
    }
}

/// Points de coupure invisibles dans les suites interminables sans blanc (EX2).
///
/// Une page de 4 000 caractères sans une espace — une colonne de base 64, une
/// URL de données, un JSON compacté indexé avant EX2 — fait chercher à
/// CoreText une césure qui n'existe pas, et l'aperçu se fige. Une espace sans
/// chasse (U+200B) tous les 120 caractères au plus lui donne où couper, sans
/// rien changer à ce qui se voit.
///
/// LE SURLIGNAGE N'EN SOUFFRE PAS. U+200B n'est ni lettre ni chiffre : posé au
/// milieu d'un mot, il y créerait une frontière de jeton (`TokenBoundary`) et
/// un terme à cheval ne se surlignerait plus. La coupure se pose donc, quand
/// il y en a une dans la seconde moitié de la fenêtre, juste APRÈS un
/// caractère qui est déjà une frontière (ponctuation, barre, virgule) : là,
/// aucun jeton ne change. Seule une suite de lettres et de chiffres d'un seul
/// tenant est coupée en dur tous les 120 — et dans un tel bloc il n'y a pas de
/// mot entier à trouver.
enum TextSoftBreaks {
    /// Suite sans blanc à partir de laquelle on intervient. Un mot, une URL
    /// ordinaire n'en approchent pas ; en deçà, le texte ressort intact.
    static let minimumRun = 500
    /// Écart maximal entre deux coupures.
    static let interval = 120
    static let breakCharacter: Character = "\u{200B}"

    /// Le texte avec ses coupures ; LE MÊME texte, sans copie, s'il ne porte
    /// aucune suite d'au moins `minimumRun` caractères sans blanc.
    static func insert(_ text: String) -> String {
        guard hasLongRun(text) else { return text }
        var out = String()
        out.reserveCapacity(text.utf8.count + text.utf8.count / interval * 3)
        var runStart = text.startIndex
        var runLength = 0
        var index = text.startIndex
        while index < text.endIndex {
            let ch = text[index]
            if ch.isWhitespace {
                emit(text[runStart..<index], length: runLength, into: &out)
                out.append(ch)
                runLength = 0
                index = text.index(after: index)
                runStart = index
            } else {
                runLength += 1
                index = text.index(after: index)
            }
        }
        emit(text[runStart...], length: runLength, into: &out)
        return out
    }

    private static func hasLongRun(_ text: String) -> Bool {
        var run = 0
        for ch in text {
            if ch.isWhitespace {
                run = 0
            } else {
                run += 1
                if run >= minimumRun { return true }
            }
        }
        return false
    }

    private static func emit(_ run: Substring, length: Int, into out: inout String) {
        guard length >= minimumRun else {
            out += run
            return
        }
        let chars = Array(run)
        var start = 0
        while chars.count - start > interval {
            var cut = start + interval
            // La dernière frontière de jeton dans la seconde moitié de la
            // fenêtre : les coupures restent espacées de 60 à 120 caractères.
            var probe = cut
            while probe > start + interval / 2 {
                if !TokenBoundary.isWordCharacter(chars[probe - 1]) {
                    cut = probe
                    break
                }
                probe -= 1
            }
            out.append(contentsOf: chars[start..<cut])
            out.append(breakCharacter)
            start = cut
        }
        out.append(contentsOf: chars[start...])
    }
}

/// Découpage d'un extrait FTS5 `snippet(page_fts, 0, '«', '»', '…', 12)` en
/// segments marqués / non marqués. Les guillemets ne sont PAS affichés : ils sont
/// remplacés par une mise en évidence typographique (§5.6).
///
/// LE PIÈGE, ET SA RÈGLE (A2-16). « et » sont aussi la ponctuation courante du
/// français : sur un corpus francophone, `Il dit « bonjour »` perdait ses
/// guillemets — à l'affichage, dans l'accessibilité et surtout à l'export, où
/// ils ne sont remplacés par aucune mise en évidence. Un marqueur de FTS5
/// encadre un JETON : jamais d'espace à l'intérieur, jamais vide. Un « suivi
/// d'un » sans espace ni autre « entre les deux est donc un marqueur ; tout le
/// reste est du texte, et survit. Un vrai guillemet français porte, par
/// convention typographique, une espace fine à l'intérieur (`« mot »`) : c'est
/// exactement ce qui le distingue. La convention non respectée (`«mot»`) reste
/// prise pour un marqueur — c'est le seul faux positif, et il ne coûte que la
/// paire de guillemets d'un mot isolé.
enum SnippetParser {
    struct Segment: Identifiable {
        let id: Int
        let text: String
        let marked: Bool
    }

    /// L'index du `»` qui ferme un marqueur ouvert en `open`, ou `nil` si ce
    /// `«` n'est pas un marqueur.
    private static func markerEnd(_ chars: [Character], open: Int) -> Int? {
        var i = open + 1
        while i < chars.count {
            let ch = chars[i]
            if ch == "»" { return i > open + 1 ? i : nil }
            if ch == "«" || ch.isWhitespace { return nil }
            i += 1
        }
        return nil
    }

    static func segments(_ snippet: String) -> [Segment] {
        let chars = Array(snippet)
        var out: [Segment] = []
        var current = ""
        var index = 0

        func flush(marked: Bool = false) {
            guard !current.isEmpty else { return }
            out.append(Segment(id: index, text: current, marked: marked))
            index += 1
            current = ""
        }

        var i = 0
        while i < chars.count {
            if chars[i] == "«", let close = markerEnd(chars, open: i) {
                flush()
                out.append(Segment(id: index,
                                   text: String(chars[(i + 1)..<close]),
                                   marked: true))
                index += 1
                i = close + 1
            } else {
                // Y compris un « ou un » qui n'encadre pas un jeton : c'est de
                // la ponctuation, elle reste.
                current.append(chars[i])
                i += 1
            }
        }
        flush()
        return out
    }
}
