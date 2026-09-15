// MarkdownHTML.swift — le guide de Fouine, rendu en HTML (BU-27).
// Propriété : A-App.
//
// Le guide affiché par ⌘? EST `docs/app.md`, copié tel quel dans le bundle par
// `Packaging/bundle.sh`. Il faut donc en faire une page lisible sans emporter
// de bibliothèque Markdown : ce fichier est un rendu de BLOCS, écrit pour le
// sous-ensemble que la documentation du dépôt utilise réellement — titres,
// paragraphes, listes, tableaux, blocs de code, citations, règles — et qui
// laisse passer en TEXTE tout ce qu'il ne connaît pas, plutôt que d'avaler la
// ligne.
//
// POURQUOI PAS `AttributedString(markdown:)`. Elle ne rend ni les titres, ni
// les tableaux, ni les blocs de code : le guide y perdrait sa structure, qui
// est justement ce qui le rend consultable. Et POURQUOI PAS un rendu
// paresseux qui recopierait le Markdown dans la page en laissant WebKit
// interpréter : tout `<` du texte source deviendrait une balise. Ici, le texte
// est ÉCHAPPÉ d'abord (`&`, `<`, `>`), le balisage posé ensuite ; la page ne
// peut donc pas contenir de balise venue du fichier.

import Foundation

enum MarkdownHTML {

    // MARK: - Page complète

    /// Une page HTML autonome : feuille de style intégrée, aucune ressource
    /// extérieure — la fenêtre du guide ne touche pas au réseau.
    ///
    /// - Parameter notice: une ligne posée AU-DESSUS du guide, quand il y a
    ///   quelque chose à dire sur le document lui-même (en interface anglaise :
    ///   le guide est en français).
    static func render(_ markdown: String, title: String, notice: String? = nil) -> String {
        var page = """
        <!DOCTYPE html>
        <meta charset="utf-8">
        <title>\(escape(title))</title>
        <style>\(stylesheet)</style>

        """
        if let notice, !notice.isEmpty {
            page += "<p class=\"notice\">\(escape(notice))</p>\n"
        }
        page += body(markdown)
        return page
    }

    /// Le corps seul, sans en-tête ni style : ce que les tests lisent.
    static func body(_ markdown: String) -> String {
        let lines = markdown
            .replacingOccurrences(of: "\r\n", with: "\n")
            .components(separatedBy: "\n")
        return blocks(lines)
    }

    // MARK: - Blocs

    private static func blocks(_ lines: [String]) -> String {
        var out: [String] = []
        var i = 0
        while i < lines.count {
            let line = lines[i]
            if line.trimmingCharacters(in: .whitespaces).isEmpty { i += 1; continue }

            if let fence = fenceMarker(line) {
                var code: [String] = []
                i += 1
                while i < lines.count, fenceMarker(lines[i]) == nil || !isClosingFence(lines[i], fence) {
                    code.append(lines[i]); i += 1
                }
                if i < lines.count { i += 1 }          // la clôture
                out.append("<pre><code>" + escape(code.joined(separator: "\n")) + "</code></pre>")
                continue
            }

            if let (level, text) = heading(line) {
                out.append("<h\(level) id=\"\(slug(text))\">\(inline(text))</h\(level)>")
                i += 1
                continue
            }

            if isThematicBreak(line) {
                out.append("<hr>")
                i += 1
                continue
            }

            if line.hasPrefix(">") {
                var quoted: [String] = []
                while i < lines.count, lines[i].hasPrefix(">") {
                    var rest = String(lines[i].dropFirst())
                    if rest.hasPrefix(" ") { rest.removeFirst() }
                    quoted.append(rest)
                    i += 1
                }
                out.append("<blockquote>\n" + blocks(quoted) + "\n</blockquote>")
                continue
            }

            if isTableStart(lines, at: i) {
                let (html, next) = table(lines, from: i)
                out.append(html)
                i = next
                continue
            }

            if marker(line) != nil {
                let (html, next) = list(lines, from: i)
                out.append(html)
                i = next
                continue
            }

            var paragraph: [String] = []
            while i < lines.count, !lines[i].trimmingCharacters(in: .whitespaces).isEmpty,
                  !startsBlock(lines, at: i) {
                paragraph.append(lines[i].trimmingCharacters(in: .whitespaces))
                i += 1
            }
            if paragraph.isEmpty {                     // sécurité : jamais de boucle infinie
                paragraph.append(lines[i].trimmingCharacters(in: .whitespaces))
                i += 1
            }
            out.append("<p>" + inline(paragraph.joined(separator: "\n")) + "</p>")
        }
        return out.joined(separator: "\n")
    }

    /// Une ligne qui n'est PAS un paragraphe : elle ouvre un autre bloc.
    private static func startsBlock(_ lines: [String], at index: Int) -> Bool {
        let line = lines[index]
        return fenceMarker(line) != nil
            || heading(line) != nil
            || isThematicBreak(line)
            || line.hasPrefix(">")
            || marker(line) != nil
            || isTableStart(lines, at: index)
    }

    // MARK: - Titres, règles, clôtures

    private static func heading(_ line: String) -> (Int, String)? {
        var level = 0
        var rest = Substring(line)
        while rest.first == "#", level < 5 { level += 1; rest = rest.dropFirst() }
        guard (1...4).contains(level), rest.first == " " else { return nil }
        return (level, String(rest.dropFirst()).trimmingCharacters(in: .whitespaces))
    }

    private static func isThematicBreak(_ line: String) -> Bool {
        let trimmed = line.trimmingCharacters(in: .whitespaces)
        guard trimmed.count >= 3, let first = trimmed.first, "-*_".contains(first) else { return false }
        return trimmed.allSatisfy { $0 == first }
    }

    private static func fenceMarker(_ line: String) -> String? {
        let trimmed = line.trimmingCharacters(in: .whitespaces)
        guard trimmed.hasPrefix("```") else { return nil }
        return "```"
    }

    private static func isClosingFence(_ line: String, _ fence: String) -> Bool {
        line.trimmingCharacters(in: .whitespaces) == fence
    }

    /// Un identifiant d'ancre par titre : c'est ce qui fait marcher les liens
    /// internes `#…` sans quitter la page.
    private static func slug(_ text: String) -> String {
        var out = ""
        var previousWasDash = false
        for character in text.lowercased() {
            if character.isLetter || character.isNumber {
                out.append(character)
                previousWasDash = false
            } else if !previousWasDash, !out.isEmpty {
                out.append("-")
                previousWasDash = true
            }
        }
        while out.hasSuffix("-") { out.removeLast() }
        return out
    }

    // MARK: - Listes

    private struct Marker {
        var indent: Int
        var ordered: Bool
        var width: Int          // la largeur du marqueur, espace compris
        var text: String
    }

    private static func marker(_ line: String) -> Marker? {
        let indent = line.prefix(while: { $0 == " " }).count
        guard indent <= 6 else { return nil }
        let rest = line.dropFirst(indent)
        if let first = rest.first, "-*+".contains(first), rest.dropFirst().first == " " {
            return Marker(indent: indent, ordered: false, width: 2,
                          text: String(rest.dropFirst(2)))
        }
        let digits = rest.prefix(while: { $0.isNumber })
        if !digits.isEmpty, rest.dropFirst(digits.count).first == ".",
           rest.dropFirst(digits.count + 1).first == " " {
            return Marker(indent: indent, ordered: true, width: digits.count + 2,
                          text: String(rest.dropFirst(digits.count + 2)))
        }
        return nil
    }

    private static func list(_ lines: [String], from start: Int) -> (String, Int) {
        guard let first = marker(lines[start]) else { return ("", start + 1) }
        let base = first.indent
        var i = start
        var block: [String] = []
        while i < lines.count {
            let line = lines[i]
            if line.trimmingCharacters(in: .whitespaces).isEmpty {
                // Une ligne vide ne ferme la liste que si ce qui suit n'en est
                // plus (un paragraphe collé à gauche, un titre…).
                guard let next = lines[(i + 1)...].firstIndex(where: {
                    !$0.trimmingCharacters(in: .whitespaces).isEmpty
                }), belongs(lines[next], base: base) else { break }
                block.append("")
                i += 1
                continue
            }
            guard belongs(line, base: base) else { break }
            block.append(line)
            i += 1
        }

        var items: [[String]] = []
        for line in block {
            if let m = marker(line), m.indent == base {
                items.append([m.text])
            } else if !items.isEmpty {
                let dedent = min(line.prefix(while: { $0 == " " }).count, base + first.width)
                items[items.count - 1].append(String(line.dropFirst(dedent)))
            }
        }

        let tag = first.ordered ? "ol" : "ul"
        var html = "<\(tag)>\n"
        for item in items {
            html += "<li>" + itemBody(item) + "</li>\n"
        }
        html += "</\(tag)>"
        return (html, i)
    }

    private static func belongs(_ line: String, base: Int) -> Bool {
        let indent = line.prefix(while: { $0 == " " }).count
        if indent > base { return true }
        if let m = marker(line), m.indent == base { return true }
        return false
    }

    /// Un élément d'une seule phrase reste `<li>texte</li>` : le `<p>` que le
    /// rendu de blocs y mettrait doublerait les interlignes de toute liste.
    private static func itemBody(_ lines: [String]) -> String {
        let rendered = blocks(lines)
        if rendered.hasPrefix("<p>"), rendered.hasSuffix("</p>"),
           !rendered.dropFirst(3).dropLast(4).contains("<p>") {
            return String(rendered.dropFirst(3).dropLast(4))
        }
        return rendered
    }

    // MARK: - Tableaux

    private static func isTableStart(_ lines: [String], at index: Int) -> Bool {
        guard lines[index].trimmingCharacters(in: .whitespaces).hasPrefix("|"),
              index + 1 < lines.count else { return false }
        let separator = lines[index + 1].trimmingCharacters(in: .whitespaces)
        guard separator.hasPrefix("|"), separator.contains("-") else { return false }
        return separator.allSatisfy { "|-: ".contains($0) }
    }

    private static func cells(_ line: String) -> [String] {
        var trimmed = line.trimmingCharacters(in: .whitespaces)
        if trimmed.hasPrefix("|") { trimmed.removeFirst() }
        if trimmed.hasSuffix("|") { trimmed.removeLast() }
        return trimmed.components(separatedBy: "|")
            .map { $0.trimmingCharacters(in: .whitespaces) }
    }

    private static func table(_ lines: [String], from start: Int) -> (String, Int) {
        let header = cells(lines[start])
        let alignments = cells(lines[start + 1]).map { rule -> String in
            switch (rule.hasPrefix(":"), rule.hasSuffix(":")) {
            case (true, true):   return " style=\"text-align:center\""
            case (false, true):  return " style=\"text-align:right\""
            default:             return ""
            }
        }
        func align(_ column: Int) -> String {
            column < alignments.count ? alignments[column] : ""
        }

        var html = "<table>\n<thead>\n<tr>"
        for (column, cell) in header.enumerated() {
            html += "<th\(align(column))>" + inline(cell) + "</th>"
        }
        html += "</tr>\n</thead>\n<tbody>\n"

        var i = start + 2
        while i < lines.count, lines[i].trimmingCharacters(in: .whitespaces).hasPrefix("|") {
            html += "<tr>"
            for (column, cell) in cells(lines[i]).enumerated() {
                html += "<td\(align(column))>" + inline(cell) + "</td>"
            }
            html += "</tr>\n"
            i += 1
        }
        html += "</tbody>\n</table>"
        return (html, i)
    }

    // MARK: - Ligne : échappement d'abord, balisage ensuite

    static func escape(_ text: String) -> String {
        var out = ""
        out.reserveCapacity(text.count)
        for character in text {
            switch character {
            case "&": out += "&amp;"
            case "<": out += "&lt;"
            case ">": out += "&gt;"
            default:  out.append(character)
            }
        }
        return out
    }

    /// Le texte d'une ligne : le code en ligne est MIS DE CÔTÉ d'abord — ce
    /// qu'il contient ne se relit plus —, puis liens, gras et italique sur ce
    /// qui reste, et le code revient à sa place.
    ///
    /// POURQUOI DE CÔTÉ ET NON PAR MORCEAUX. Rendre chaque morceau séparément
    /// coupait le gras qui ENCADRE un code en ligne : `**un lien `x`.**` sortait
    /// avec ses astérisques à l'écran, deux fois dans docs/app.md.
    static func inline(_ text: String) -> String {
        var codes: [String] = []
        var carrier = ""
        var rest = Substring(text)
        while let open = rest.firstIndex(of: "`") {
            carrier += String(rest[rest.startIndex..<open])
            let afterOpen = rest.index(after: open)
            if let close = rest[afterOpen...].firstIndex(of: "`") {
                codes.append(String(rest[afterOpen..<close]))
                carrier += placeholder(codes.count - 1)
                rest = rest[rest.index(after: close)...]
            } else {
                carrier += "`"                        // backtick esseulé : du texte
                rest = rest[afterOpen...]
            }
        }
        carrier += String(rest)

        var html = markup(escape(carrier))
        for (index, code) in codes.enumerated() {
            html = html.replacingOccurrences(
                of: placeholder(index),
                with: "<code>" + escape(code) + "</code>")
        }
        return html
    }

    /// U+FFFC (« objet ») encadre le numéro : ce n'est ni un caractère de mot
    /// ni une marque d'emphase, les motifs ci-dessous ne le voient donc pas —
    /// et le second marqueur évite qu'un `1` se prenne pour un `11`.
    private static func placeholder(_ index: Int) -> String {
        "\u{FFFC}\(index)\u{FFFC}"
    }

    private static let patterns: [(NSRegularExpression, String)] = {
        func expression(_ pattern: String) -> NSRegularExpression {
            // Les motifs sont des constantes du fichier : une erreur ici serait
            // une faute de frappe visible au premier test.
            try! NSRegularExpression(pattern: pattern)
        }
        return [
            (expression(#"\[([^\]\n]+)\]\(([^)\s]+)\)"#), "<a href=\"$2\">$1</a>"),
            // Les emphases traversent les retours à la ligne : dans un
            // paragraphe replié à 80 colonnes, `*Ajouter au\npresse-papiers*`
            // est UNE emphase, et la refuser laisserait les astérisques à
            // l'écran. Elles ne traversent pas les blocs — `inline` est appelée
            // paragraphe par paragraphe.
            (expression(#"\*\*([^\*]+?)\*\*"#), "<strong>$1</strong>"),
            (expression(#"(?<![\*\w])\*([^\*]+)\*(?![\*\w])"#), "<em>$1</em>"),
            (expression(#"(?<![\w_])_([^_]+)_(?![\w_])"#), "<em>$1</em>"),
        ]
    }()

    private static func markup(_ escaped: String) -> String {
        var text = escaped
        for (expression, template) in patterns {
            text = expression.stringByReplacingMatches(
                in: text,
                range: NSRange(text.startIndex..., in: text),
                withTemplate: template)
        }
        return text
    }

    // MARK: - Feuille de style

    /// Police système, largeur de lecture, et les deux apparences. `color-scheme`
    /// n'est pas décoratif : sans lui, WebKit peint un fond blanc sous la page
    /// en apparence sombre, et les barres de défilement restent claires.
    static let stylesheet = """
    :root { color-scheme: light dark; --ink: #1c1b1a; --paper: #fdfcfa; \
    --muted: #6b6560; --rule: #e0dcd6; --slab: #f3f0eb; --link: #0a5ca8; }
    @media (prefers-color-scheme: dark) {
      :root { --ink: #eae7e2; --paper: #1e1d1c; --muted: #a29c95; \
    --rule: #3a3835; --slab: #2a2827; --link: #7db4f0; }
    }
    body { margin: 0 auto; padding: 28px 24px 64px; max-width: 46em; \
    background: var(--paper); color: var(--ink); \
    font: 15px/1.6 -apple-system, BlinkMacSystemFont, "Helvetica Neue", sans-serif; \
    -webkit-font-smoothing: antialiased; }
    h1 { font-size: 1.9em; margin: 0 0 .6em; }
    h2 { font-size: 1.4em; margin: 1.8em 0 .5em; padding-top: .4em; \
    border-top: 1px solid var(--rule); }
    h3 { font-size: 1.12em; margin: 1.5em 0 .4em; }
    h4 { font-size: 1em; margin: 1.3em 0 .3em; color: var(--muted); }
    p, ul, ol, table, pre, blockquote { margin: 0 0 1em; }
    li { margin: .25em 0; }
    a { color: var(--link); }
    code { font: .88em/1.4 ui-monospace, "SF Mono", Menlo, monospace; \
    background: var(--slab); border-radius: 4px; padding: .1em .35em; }
    pre { background: var(--slab); border-radius: 8px; padding: 12px 14px; \
    overflow-x: auto; }
    pre code { background: none; padding: 0; }
    blockquote { border-left: 3px solid var(--rule); padding-left: 14px; \
    color: var(--muted); }
    hr { border: 0; border-top: 1px solid var(--rule); margin: 2em 0; }
    table { border-collapse: collapse; width: 100%; }
    th, td { border: 1px solid var(--rule); padding: 6px 9px; \
    text-align: left; vertical-align: top; }
    th { background: var(--slab); }
    .notice { background: var(--slab); border-radius: 8px; padding: 10px 14px; \
    color: var(--muted); }
    """
}
