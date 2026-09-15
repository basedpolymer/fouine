// HTMLText.swift — dépouillement HTML « à la main » (SPEC §5.3).
// Propriété : A-Ingest.
//
// « sérialiser sur le thread principal, ou parser à la main. […] l'import NSHTML
// a rendu 18 020 caractères en 2,74 s depuis un fil de fond sans blocage — mais
// ce comportement n'est pas documenté-supporté, et le pipeline --jobs N n'a pas
// de run loop. 1 seul fichier concerné dans le corpus : ne pas y consacrer une
// architecture. »
//
// Donc : pas de NSAttributedString NSHTML. Un dépouilleur simple et correct.
// Il sert aussi aux XHTML de l'spine epub (§5.3).

import Foundation

enum HTMLText {
    /// Balises dont l'ouverture ou la fermeture vaut un saut de ligne.
    static let blockTags: Set<String> = [
        "p", "div", "br", "hr", "li", "ul", "ol", "tr", "td", "th", "table",
        "h1", "h2", "h3", "h4", "h5", "h6", "section", "article", "header",
        "footer", "nav", "aside", "blockquote", "pre", "figure", "figcaption",
        "dt", "dd", "dl", "body", "title",
    ]

    /// Texte lisible d'un document HTML/XHTML : script et style retirés, balises
    /// dépouillées, entités de base décodées, blancs normalisés.
    static func plainText(from html: String) -> String {
        var out = String()
        out.reserveCapacity(html.count / 2)
        var i = html.startIndex
        /// Lien ouvert : sa cible, et où son texte commence dans `out` (en
        /// octets UTF-8 : un décalage, pas un index qu'un ajout invaliderait).
        var openLink: (target: String, textStart: Int)?

        while i < html.endIndex {
            let ch = html[i]
            guard ch == "<" else {
                out.append(ch)
                i = html.index(after: i)
                continue
            }
            if html[i...].hasPrefix("<!--") {
                if let end = html.range(of: "-->", range: i..<html.endIndex) {
                    i = end.upperBound
                } else {
                    i = html.endIndex
                }
                continue
            }
            if html[i...].hasPrefix(cdataOpen) {
                // Le contenu d'une section CDATA est du TEXTE (XHTML d'epub).
                let start = html.index(i, offsetBy: cdataOpen.count)
                if let end = html.range(of: "]]>", range: start..<html.endIndex) {
                    out += html[start..<end.lowerBound]
                    i = end.upperBound
                } else {
                    out += html[start...]
                    i = html.endIndex
                }
                continue
            }
            // Un « < » qui n'ouvre RIEN est un caractère du texte : « x < 10 » ou
            // « ΔG < 0 » ne doivent pas avaler la suite du document jusqu'au
            // prochain « > », voire jusqu'à la fin (A11.1).
            guard opensMarkup(html, at: i) else {
                out.append(ch)
                i = html.index(after: i)
                continue
            }
            var cursor = html.index(after: i)
            var isClosing = false
            if cursor < html.endIndex, html[cursor] == "/" {
                isClosing = true
                cursor = html.index(after: cursor)
            }
            var name = String()
            while cursor < html.endIndex,
                  html[cursor].isLetter || html[cursor].isNumber {
                name.append(html[cursor])
                cursor = html.index(after: cursor)
            }
            let tag = name.lowercased()

            // Fin de balise, en respectant les valeurs d'attribut entre guillemets.
            var scan = cursor
            var quote: Character?
            while scan < html.endIndex {
                let c = html[scan]
                if let q = quote {
                    if c == q { quote = nil }
                } else if c == "\"" || c == "'" {
                    quote = c
                } else if c == ">" {
                    break
                }
                scan = html.index(after: scan)
            }
            let afterTag = scan < html.endIndex ? html.index(after: scan) : html.endIndex

            if !isClosing, tag == "script" || tag == "style" {
                if let close = html.range(of: "</\(tag)", options: [.caseInsensitive],
                                          range: afterTag..<html.endIndex) {
                    var end = close.upperBound
                    while end < html.endIndex, html[end] != ">" {
                        end = html.index(after: end)
                    }
                    i = end < html.endIndex ? html.index(after: end) : html.endIndex
                } else {
                    i = html.endIndex
                }
                continue
            }
            if tag == "a" {
                // HTML n'imbrique pas les liens : un `<a>` ouvert ferme le
                // précédent resté sans `</a>`.
                if let pending = openLink { closeLink(pending, in: &out) }
                openLink = nil
                if !isClosing,
                   let href = attribute("href", in: html[cursor..<scan]),
                   let target = searchableTarget(href) {
                    openLink = (target, out.utf8.count)
                }
            }
            if blockTags.contains(tag) { out.append("\n") }
            i = afterTag
        }
        if let pending = openLink { closeLink(pending, in: &out) }
        return normalizeWhitespace(decodeEntities(out))
    }

    // MARK: - Cibles des liens (EX2)
    //
    // Retirer toutes les balises effaçait la cible : de
    // `<a href="https://doi.org/10.1000/xyz">Article</a>` ne restait que
    // « Article », et le DOI, le domaine ou le dépôt étaient introuvables.
    // La sortie devient « Article (https://doi.org/10.1000/xyz) ». Seules les
    // cibles qui désignent quelque chose HORS du document sont gardées : une
    // ancre, un chemin relatif (tous les liens internes d'un EPUB) ou un
    // `javascript:` n'apprennent rien à qui cherche.

    static let searchableSchemes = ["http://", "https://", "mailto:", "doi:"]

    /// La cible telle qu'elle sera écrite, ou nil si elle n'a rien à faire dans
    /// l'index. Les entités (`&amp;`) restent : elles sont décodées avec le
    /// reste du texte.
    static func searchableTarget(_ href: String) -> String? {
        let trimmed = href.trimmingCharacters(in: .whitespacesAndNewlines)
        let lower = trimmed.lowercased()
        guard let scheme = searchableSchemes.first(where: { lower.hasPrefix($0) }),
              trimmed.count > scheme.count else { return nil }
        return trimmed
    }

    /// Écrit « (cible) » après le texte du lien, ou la cible seule s'il n'y a
    /// pas de texte — et rien si le texte dit déjà la cible.
    private static func closeLink(_ link: (target: String, textStart: Int),
                                  in out: inout String) {
        let start = out.utf8.index(out.utf8.startIndex, offsetBy: link.textStart,
                                   limitedBy: out.utf8.endIndex) ?? out.utf8.endIndex
        let label = normalizeWhitespace(decodeEntities(String(out[start...])))
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let target = decodeEntities(link.target)
        if label.isEmpty {
            out += " " + link.target + " "
        } else if !sameTarget(label, target) {
            out += " (" + link.target + ")"
        }
    }

    /// Le texte du lien est-il la cible elle-même ? À la casse, au schéma et à
    /// la barre finale près : « exemple.org » pour `https://exemple.org/`,
    /// « a@b.fr » pour `mailto:a@b.fr` ne gagnent rien à être répétés.
    static func sameTarget(_ label: String, _ target: String) -> Bool {
        func bare(_ s: String) -> String {
            var lower = s.lowercased()
            if let scheme = searchableSchemes.first(where: { lower.hasPrefix($0) }) {
                lower.removeFirst(scheme.count)
            }
            while lower.hasSuffix("/") { lower.removeLast() }
            return lower
        }
        return bare(label) == bare(target)
    }

    /// Valeur de l'attribut `name` dans le corps d'une balise (ce qui suit son
    /// nom, jusqu'au « > » exclu), entre guillemets ou non. Le nom se compare
    /// en entier : `data-href` n'est pas `href`.
    static func attribute(_ name: String, in body: Substring) -> String? {
        var i = body.startIndex
        func skipSpaces() {
            while i < body.endIndex, body[i].isWhitespace || body[i] == "/" {
                i = body.index(after: i)
            }
        }
        while i < body.endIndex {
            skipSpaces()
            let nameStart = i
            while i < body.endIndex, !body[i].isWhitespace,
                  body[i] != "=", body[i] != "/" {
                i = body.index(after: i)
            }
            guard i > nameStart else { break }
            let attr = body[nameStart..<i].lowercased()
            while i < body.endIndex, body[i].isWhitespace { i = body.index(after: i) }
            guard i < body.endIndex, body[i] == "=" else { continue }
            i = body.index(after: i)
            while i < body.endIndex, body[i].isWhitespace { i = body.index(after: i) }
            var value: Substring
            if i < body.endIndex, body[i] == "\"" || body[i] == "'" {
                let quote = body[i]
                let valueStart = body.index(after: i)
                let valueEnd = body[valueStart...].firstIndex(of: quote) ?? body.endIndex
                value = body[valueStart..<valueEnd]
                i = valueEnd < body.endIndex ? body.index(after: valueEnd) : valueEnd
            } else {
                let valueStart = i
                while i < body.endIndex, !body[i].isWhitespace { i = body.index(after: i) }
                value = body[valueStart..<i]
            }
            if attr == name { return String(value) }
        }
        return nil
    }

    static let cdataOpen = "<![CDATA["

    /// Vrai si ce « < » ouvre une balise (`<p`, `</p`), une déclaration
    /// (`<!DOCTYPE`) ou une instruction de traitement (`<?xml`, en tête des XHTML
    /// d'epub) — les seules formes que la boucle sait consommer jusqu'au « > ».
    /// Faux pour tout le reste : c'est alors du texte.
    static func opensMarkup(_ html: String, at index: String.Index) -> Bool {
        var cursor = html.index(after: index)
        guard cursor < html.endIndex else { return false }
        if html[cursor] == "!" || html[cursor] == "?" { return true }
        if html[cursor] == "/" {
            cursor = html.index(after: cursor)
            guard cursor < html.endIndex else { return false }
        }
        return html[cursor].isLetter
    }

    static let namedEntities: [String: String] = [
        "amp": "&", "lt": "<", "gt": ">", "quot": "\"", "apos": "'",
        "nbsp": "\u{00A0}", "eacute": "é", "egrave": "è", "ecirc": "ê",
        "agrave": "à", "acirc": "â", "ccedil": "ç", "ugrave": "ù", "ucirc": "û",
        "icirc": "î", "iuml": "ï", "ouml": "ö", "auml": "ä", "uuml": "ü",
        "ocirc": "ô", "oelig": "œ", "aelig": "æ", "deg": "°", "laquo": "«",
        "raquo": "»", "hellip": "…", "mdash": "—", "ndash": "–", "rsquo": "’",
        "lsquo": "‘", "ldquo": "“", "rdquo": "”", "euro": "€", "copy": "©",
        "reg": "®", "trade": "™", "middot": "·", "times": "×", "shy": "",
    ]

    /// Caractère de remplacement U+FFFD pour une commande C0 échappée par
    /// référence numérique ; le scalaire tel quel sinon.
    static func sanitizedScalar(_ scalar: Unicode.Scalar) -> Unicode.Scalar {
        let forbidden = scalar.value < 0x20
            && scalar != "\t" && scalar != "\n" && scalar != "\r"
        return forbidden ? "\u{FFFD}" : scalar
    }

    static func decodeEntities(_ text: String) -> String {
        guard text.contains("&") else { return text }
        var out = String()
        out.reserveCapacity(text.count)
        var i = text.startIndex
        while i < text.endIndex {
            guard text[i] == "&" else {
                out.append(text[i])
                i = text.index(after: i)
                continue
            }
            let limit = text.index(i, offsetBy: 12, limitedBy: text.endIndex)
                ?? text.endIndex
            guard let semi = text[i..<limit].firstIndex(of: ";") else {
                out.append("&")
                i = text.index(after: i)
                continue
            }
            let body = String(text[text.index(after: i)..<semi])
            if body.hasPrefix("#") {
                let digits = String(body.dropFirst())
                let value: UInt32?
                if digits.lowercased().hasPrefix("x") {
                    value = UInt32(digits.dropFirst(), radix: 16)
                } else {
                    value = UInt32(digits)
                }
                // `&#0;` produisait un NUL dans page_fts (A11.11) — précisément
                // l'octet sur lequel `PlainTextExtractor.decode` refuse un
                // binaire renommé (A11.4), et que `DjvuExtractor` retire à la
                // source. U+FFFD plutôt que rien : la référence était bien là
                // dans le source, le caractère de remplacement le dit sans
                // polluer l'index. Même traitement pour les autres commandes C0
                // (sauf tabulation, saut de ligne et retour chariot, qui sont du
                // blanc légitime) et pour les demi-codets isolés — que
                // `Unicode.Scalar` refuse déjà en rendant nil.
                if let v = value, let scalar = Unicode.Scalar(v) {
                    out.unicodeScalars.append(Self.sanitizedScalar(scalar))
                    i = text.index(after: semi)
                    continue
                }
            } else if let replacement = namedEntities[body.lowercased()] {
                out += replacement
                i = text.index(after: semi)
                continue
            }
            out.append("&")
            i = text.index(after: i)
        }
        return out
    }

    /// Espaces et tabulations compactés, au plus une ligne vide consécutive.
    static func normalizeWhitespace(_ text: String) -> String {
        var out = String()
        out.reserveCapacity(text.count)
        var pendingNewlines = 0
        var pendingSpace = false
        var started = false
        for ch in text {
            if ch == "\n" || ch == "\r" {
                pendingNewlines += 1
                pendingSpace = false
                continue
            }
            if ch == " " || ch == "\t" || ch == "\u{00A0}" {
                pendingSpace = true
                continue
            }
            if started {
                if pendingNewlines > 0 {
                    out += String(repeating: "\n", count: min(pendingNewlines, 2))
                } else if pendingSpace {
                    out += " "
                }
            }
            pendingNewlines = 0
            pendingSpace = false
            out.append(ch)
            started = true
        }
        return out
    }
}
