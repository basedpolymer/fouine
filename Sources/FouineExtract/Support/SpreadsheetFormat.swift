// SpreadsheetFormat.swift — la valeur AFFICHÉE d'une cellule (constat C2-07).
// SPDX-License-Identifier: LicenseRef-Fouine-Source-Available
// Propriété : A-Ingest.
//
// POURQUOI. Un `.xlsx` range une date et un montant comme des NOMBRES : la
// cellule qui affiche « 05/01/2026 » contient `46027`, celle qui affiche
// « 1 512,50 € » contient `1512.5`. Le format vit à côté, dans
// `xl/styles.xml`. Fouine indexait la valeur stockée, donc :
//
//     $ fouine search "05/03/2026"   -> 0 page
//     $ fouine search "1 512,50"     -> aucune du tableur
//
// Or un tableur est le deuxième document de la vie courante après la lettre —
// budget, échéancier, relevé bancaire exporté — et une date ou un montant est
// la SEULE chose qu'on y cherche.
//
// LES DEUX FORMES SONT INDEXÉES, séparées par une espace : « 05/01/2026 46027 »,
// « 1 512,50 1512.5 ». Celui qui tape ce qu'il voit trouve, celui qui tape la
// valeur brute aussi, et rien de ce qui marchait avant ne cesse de marcher.
//
// DEUX FAMILLES SEULEMENT, et c'est délibéré : les dates/heures et les
// décimaux. Les pourcentages, les fractions, la notation scientifique et les
// formats à conditions (`[Red]`, sections multiples) restent à leur valeur
// brute — un rendu approximatif y coûterait plus qu'il ne rapporterait.
//
// LE RENDU EST FRANÇAIS, en dur : `dd/MM/yyyy`, virgule décimale, espace de
// milliers. Ce n'est pas la locale du système, et c'est voulu — le texte part
// dans `page_fts`, une table qui survit à un changement de réglage régional,
// et une base dont les dates changeraient de forme selon la machine qui indexe
// serait incherchable.

import Foundation

/// Les formats de cellule d'un classeur, lus une fois par fichier.
public struct SpreadsheetFormat: Sendable {

    /// Famille d'un format, et ce qu'il faut en rendre.
    enum Kind: Equatable {
        case dateTime(date: Bool, hours: Bool)
        case decimal(places: Int, grouped: Bool)
    }

    /// Famille par index de style (`<c s="…">`), dans l'ordre de `cellXfs`.
    let kinds: [Kind?]
    /// Le classeur compte-t-il ses jours depuis 1904 (convention Mac) ?
    let date1904: Bool

    /// Un classeur sans `styles.xml` : rien n'est rendu, tout reste brut.
    public static let none = SpreadsheetFormat(kinds: [], date1904: false)

    public var isEmpty: Bool { kinds.allSatisfy { $0 == nil } }

    // MARK: - Lecture des styles

    /// Lit `xl/styles.xml` et `xl/workbook.xml`.
    ///
    /// L'analyse est faite à la main plutôt qu'avec `XMLParser` : on ne cherche
    /// que deux éléments, leurs attributs sont des littéraux, et un classeur
    /// piégé ne doit pas nous coûter un délégué de plus.
    public static func parse(styles: Data?, workbook: Data?) -> SpreadsheetFormat {
        guard let styles, let text = String(data: styles, encoding: .utf8) else {
            return .none
        }
        var custom: [Int: String] = [:]
        for element in elements(named: "numFmt", in: text) {
            guard let id = Int(attribute("numFmtId", of: element)) else { continue }
            custom[id] = attribute("formatCode", of: element)
        }
        var kinds: [Kind?] = []
        if let cellXfs = section(named: "cellXfs", in: text) {
            for element in elements(named: "xf", in: cellXfs) {
                let raw = attribute("numFmtId", of: element)
                guard let id = Int(raw) else { kinds.append(nil); continue }
                kinds.append(kind(numFmtId: id, custom: custom[id]))
            }
        }
        var date1904 = false
        if let workbook, let book = String(data: workbook, encoding: .utf8),
           let pr = elements(named: "workbookPr", in: book).first {
            let value = attribute("date1904", of: pr).lowercased()
            date1904 = (value == "1" || value == "true")
        }
        return SpreadsheetFormat(kinds: kinds, date1904: date1904)
    }

    /// Familles des formats prédéfinis (§18.8.30 de la norme). Seuls ceux des
    /// deux familles retenues y figurent ; les autres rendent `nil`.
    static func kind(numFmtId id: Int, custom: String?) -> Kind? {
        if let custom, !custom.isEmpty { return kind(formatCode: custom) }
        switch id {
        case 14...17:      return .dateTime(date: true, hours: false)
        case 18...21, 45...47:
            return .dateTime(date: false, hours: true)
        case 22:           return .dateTime(date: true, hours: true)
        case 1:            return .decimal(places: 0, grouped: false)
        case 2:            return .decimal(places: 2, grouped: false)
        case 3, 37, 38:    return .decimal(places: 0, grouped: true)
        case 4, 39, 40, 43, 44:
            return .decimal(places: 2, grouped: true)
        default:           return nil
        }
    }

    /// Famille d'un format personnalisé, décidée sur son motif hors guillemets.
    static func kind(formatCode: String) -> Kind? {
        let pattern = stripLiterals(formatCode)
        let lower = pattern.lowercased()
        let hasDate = lower.contains("y") || lower.contains("d") || lower.contains("m")
        let hasHours = lower.contains("h")
        if hasDate || hasHours {
            return .dateTime(date: hasDate, hours: hasHours)
        }
        guard lower.contains("0") || lower.contains("#") else { return nil }
        // Hors périmètre, assumé : un pourcentage (`0.00%`), une fraction
        // (`# ?/?`) et la notation scientifique (`0.00E+00`) ne se rendent pas
        // en déplaçant une virgule. Ils restent à leur valeur brute.
        guard !lower.contains("%"), !lower.contains("e+"),
              !lower.contains("/"), !lower.contains("?") else { return nil }
        // Le nombre de décimales est celui de la PREMIÈRE section : un format à
        // sections (`positif;négatif`) rend les mêmes décimales des deux côtés
        // dans tout ce qu'on rencontre en vrai.
        let first = lower.split(separator: ";").first.map(String.init) ?? lower
        var places = 0
        if let dot = first.firstIndex(of: ".") {
            places = first[first.index(after: dot)...]
                .prefix { $0 == "0" || $0 == "#" }.count
        }
        return .decimal(places: places, grouped: first.contains(","))
    }

    /// Retire ce qui est entre guillemets, échappé par `\` ou entre crochets :
    /// le « m » de `0.00" m"` n'est pas un mois, et `[Red]` n'est pas une date.
    static func stripLiterals(_ code: String) -> String {
        var out = ""
        var inQuotes = false
        var inBracket = false
        var escaped = false
        for character in code {
            if escaped { escaped = false; continue }
            switch character {
            case "\\": escaped = true
            case "\"": inQuotes.toggle()
            case "[" where !inQuotes: inBracket = true
            case "]" where !inQuotes: inBracket = false
            default:
                if !inQuotes && !inBracket { out.append(character) }
            }
        }
        return out
    }

    // MARK: - Rendu d'une valeur

    /// La forme AFFICHÉE d'une valeur `<v>`, ou `nil` s'il n'y a rien à rendre
    /// (cellule sans style, format d'une autre famille, valeur non numérique).
    public func rendered(_ raw: String, styleIndex: Int?) -> String? {
        guard let styleIndex, styleIndex >= 0, styleIndex < kinds.count,
              let kind = kinds[styleIndex], let value = Double(raw) else {
            return nil
        }
        switch kind {
        case .dateTime(let date, let hours):
            return Self.dateText(serial: value, date: date, hours: hours,
                                 date1904: date1904)
        case .decimal(let places, let grouped):
            return Self.decimalText(value, places: places, grouped: grouped)
        }
    }

    /// « 05/01/2026 », « 05/01/2026 14:30 », « 14:30 ».
    static func dateText(serial: Double, date: Bool, hours: Bool,
                         date1904: Bool) -> String? {
        guard serial.isFinite, serial >= 0, serial < 3_000_000 else { return nil }
        let whole = Int(serial.rounded(.down))
        var parts: [String] = []
        if date {
            // 25 569 = le numéro de série du 1er janvier 1970 dans la
            // convention 1900 — qui compte un 29 février 1900 qui n'a jamais
            // existé, d'où le décalage sous le numéro 60.
            let epoch = date1904 ? whole - 24_107
                                 : whole - (whole < 60 ? 25_568 : 25_569)
            let civil = Self.civil(fromDays: epoch)
            parts.append(String(format: "%02d/%02d/%04d",
                                civil.day, civil.month, civil.year))
        }
        if hours {
            let fraction = serial - Double(whole)
            let minutes = Int((fraction * 24 * 60).rounded())
            parts.append(String(format: "%02d:%02d",
                                (minutes / 60) % 24, minutes % 60))
        }
        return parts.isEmpty ? nil : parts.joined(separator: " ")
    }

    /// Jour calendaire depuis le nombre de jours écoulés depuis le 1/1/1970.
    /// Arithmétique pure : aucun `DateFormatter`, donc aucun fuseau, aucune
    /// locale, et le même résultat sur toutes les machines.
    static func civil(fromDays days: Int) -> (year: Int, month: Int, day: Int) {
        let z = days + 719_468
        let era = (z >= 0 ? z : z - 146_096) / 146_097
        let dayOfEra = z - era * 146_097
        let yearOfEra = (dayOfEra - dayOfEra / 1_460 + dayOfEra / 36_524
                         - dayOfEra / 146_096) / 365
        let year = yearOfEra + era * 400
        let dayOfYear = dayOfEra - (365 * yearOfEra + yearOfEra / 4
                                    - yearOfEra / 100)
        let mp = (5 * dayOfYear + 2) / 153
        let day = dayOfYear - (153 * mp + 2) / 5 + 1
        let month = mp < 10 ? mp + 3 : mp - 9
        return (month <= 2 ? year + 1 : year, month, day)
    }

    /// « 1 512,50 », « 775 ». Espace ORDINAIRE entre les milliers : c'est celle
    /// que l'utilisateur tape dans la barre de recherche.
    static func decimalText(_ value: Double, places: Int, grouped: Bool) -> String? {
        guard value.isFinite else { return nil }
        let text = String(format: "%.\(max(0, min(9, places)))f", abs(value))
        var integer = text
        var fraction = ""
        if let dot = text.firstIndex(of: ".") {
            integer = String(text[text.startIndex..<dot])
            fraction = String(text[text.index(after: dot)...])
        }
        if grouped, integer.count > 3 {
            var groups: [String] = []
            var rest = Substring(integer)
            while rest.count > 3 {
                groups.append(String(rest.suffix(3)))
                rest = rest.dropLast(3)
            }
            groups.append(String(rest))
            integer = groups.reversed().joined(separator: " ")
        }
        let sign = value < 0 ? "-" : ""
        return fraction.isEmpty ? sign + integer
                                : sign + integer + "," + fraction
    }

    // MARK: - Analyse XML minimale

    /// Les éléments `<name …>` d'un texte XML, attributs compris.
    static func elements(named name: String, in text: String) -> [String] {
        var out: [String] = []
        var search = Substring(text)
        while let start = search.range(of: "<\(name)") {
            let after = search[start.upperBound...]
            // « <numFmts> » ne doit pas répondre pour « <numFmt> ».
            guard let next = after.first,
                  next == " " || next == "/" || next == ">" else {
                search = after
                continue
            }
            guard let end = after.range(of: ">") else { break }
            out.append(String(after[after.startIndex..<end.lowerBound]))
            search = after[end.upperBound...]
        }
        return out
    }

    /// Le contenu de `<name>…</name>`.
    static func section(named name: String, in text: String) -> String? {
        guard let start = text.range(of: "<\(name)"),
              let open = text[start.lowerBound...].range(of: ">"),
              let close = text.range(of: "</\(name)>") else { return nil }
        guard open.upperBound <= close.lowerBound else { return nil }
        return String(text[open.upperBound..<close.lowerBound])
    }

    /// La valeur d'un attribut, entités XML rendues.
    static func attribute(_ name: String, of element: String) -> String {
        guard let key = element.range(of: "\(name)=\"") else { return "" }
        let rest = element[key.upperBound...]
        guard let end = rest.range(of: "\"") else { return "" }
        return String(rest[rest.startIndex..<end.lowerBound])
            .replacingOccurrences(of: "&quot;", with: "\"")
            .replacingOccurrences(of: "&amp;", with: "&")
            .replacingOccurrences(of: "&lt;", with: "<")
            .replacingOccurrences(of: "&gt;", with: ">")
    }
}
