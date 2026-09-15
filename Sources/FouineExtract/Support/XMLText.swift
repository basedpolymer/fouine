// XMLText.swift — extraction de texte XML en mode SAX (SPEC §5.3).
// Propriété : A-Ingest.
//
// « bsdtar + XMLParser en mode SAX sur word/document.xml / content.xml. […] le
// SAX est sans surprise et sans thread principal » — c'est la raison pour
// laquelle NSAttributedString est INTERDIT sur docx/odt/xlsx/pptx.
//
// Le SAX ne borne rien à lui seul : le texte était accumulé INTÉGRALEMENT avant
// que `TextBudget.take` n'ait la moindre occasion de couper (A11.2). Chaque
// collecteur porte donc un plafond d'accumulation et ARRÊTE l'analyse dès qu'il
// est atteint. Le texte rendu ne change pas d'un octet : `take` ne garde qu'un
// PRÉFIXE, et ce préfixe est intégralement collecté avant l'arrêt.

import Foundation
import FouineCore

/// Plafond d'accumulation d'un collecteur SAX, en octets UTF-8. L'appelant passe
/// le reliquat de son `TextBudget` : au-delà, tout ce qui serait collecté finirait
/// de toute façon à la poubelle de `take`. Le morceau en cours est gardé ENTIER
/// plutôt que coupé au milieu — la troncature fine reste l'affaire de
/// `TextBudget`, qui seul sait couper sur une frontière de caractère.
struct XMLTextLimit {
    let bytes: Int
    private(set) var used = 0

    init(bytes: Int) { self.bytes = max(0, bytes) }

    var isReached: Bool { used >= bytes }

    /// Compte `text` et dit si le plafond vient d'être atteint.
    mutating func account(_ text: String) -> Bool {
        used += text.utf8.count
        return isReached
    }
}

/// Partie locale d'un nom qualifié : « w:t » -> « t ».
@inline(__always)
func xmlLocalName(_ name: String) -> String {
    guard let colon = name.lastIndex(of: ":") else { return name }
    return String(name[name.index(after: colon)...])
}

/// Collecteur générique : capture le texte de certains éléments, insère un saut
/// de ligne à la fin de certains autres.
final class XMLTextCollector: NSObject, XMLParserDelegate {
    /// Éléments dont on capture les données caractères ; `nil` = tout capturer.
    private let textElements: Set<String>?
    /// Éléments dont la FIN produit un saut de ligne (paragraphes) ; `nil` =
    /// TOUS. Le `nil` sert au XML quelconque (`XMLDocumentExtractor`), dont on
    /// ne connaît pas le vocabulaire : sans lui, un fichier écrit sur une seule
    /// ligne rendrait tout son texte collé en un seul mot.
    private let breakElements: Set<String>?
    /// Éléments vides produisant une insertion à leur ouverture (`w:br`, `w:tab`).
    private let inlineElements: [String: String]

    private var text = String()
    private var capturing = 0
    private var failure: Error?
    /// Plafond d'accumulation (A11.2) et arrêt volontaire de l'analyse.
    private var limit: XMLTextLimit
    private var aborted = false

    init(textElements: Set<String>?,
         breakElements: Set<String>?,
         inlineElements: [String: String] = [:],
         limitBytes: Int = Int.max) {
        self.textElements = textElements
        self.breakElements = breakElements
        self.inlineElements = inlineElements
        self.limit = XMLTextLimit(bytes: limitBytes)
    }

    private func matches(_ set: Set<String>?, _ name: String) -> Bool {
        guard let set else { return true }
        return set.contains(name) || set.contains(xmlLocalName(name))
    }

    private func inlineInsertion(_ name: String) -> String? {
        inlineElements[name] ?? inlineElements[xmlLocalName(name)]
    }

    func parse(_ data: Data, what: String) throws -> String {
        let parser = XMLParser(data: data)
        parser.shouldProcessNamespaces = false
        parser.shouldResolveExternalEntities = false
        parser.delegate = self
        // Un arrêt volontaire fait échouer `parse()` : ce n'est PAS une erreur.
        guard parser.parse() || aborted else {
            let reason = failure.map { ($0 as NSError).localizedDescription }
                ?? parser.parserError.map { ($0 as NSError).localizedDescription }
                ?? "unknown XML error"
            throw FouineError.extraction("unreadable XML (\(what)): \(reason)")
        }
        return text
    }

    /// Accumule puis arrête l'analyse au plafond : inutile de continuer à parcourir
    /// des centaines de mégaoctets dont pas un octet ne sera indexé (A11.2).
    private func append(_ chunk: String, _ parser: XMLParser) {
        guard !aborted else { return }
        text += chunk
        if limit.account(chunk) {
            aborted = true
            parser.abortParsing()
        }
    }

    func parser(_ parser: XMLParser, didStartElement elementName: String,
                namespaceURI: String?, qualifiedName qName: String?,
                attributes attributeDict: [String: String] = [:]) {
        if let insertion = inlineInsertion(elementName) { append(insertion, parser) }
        if let wanted = textElements, matches(wanted, elementName) { capturing += 1 }
    }

    func parser(_ parser: XMLParser, didEndElement elementName: String,
                namespaceURI: String?, qualifiedName qName: String?) {
        if let wanted = textElements, matches(wanted, elementName), capturing > 0 {
            capturing -= 1
        }
        if matches(breakElements, elementName) { append("\n", parser) }
    }

    func parser(_ parser: XMLParser, foundCharacters string: String) {
        if textElements == nil || capturing > 0 { append(string, parser) }
    }

    func parser(_ parser: XMLParser, parseErrorOccurred parseError: Error) {
        failure = parseError
    }
}

/// `xl/sharedStrings.xml` : une chaîne partagée par `<si>`, dans l'ordre du
/// fichier — c'est l'index utilisé par les cellules `t="s"`.
final class SharedStringsParser: NSObject, XMLParserDelegate {
    private(set) var strings: [String] = []
    private var current = String()
    private var inItem = false
    private var capturing = 0
    private var failure: Error?
    /// Même plafond d'accumulation (A11.2) : la table des chaînes partagées porte
    /// à elle seule tout le texte d'un classeur. Au-delà, les cellules qui
    /// pointent vers les chaînes suivantes ne se résolvent plus — mais le texte
    /// retenu aurait de toute façon dépassé `maxTextBytes`.
    private var limit: XMLTextLimit
    private var aborted = false

    init(limitBytes: Int = Int.max) { self.limit = XMLTextLimit(bytes: limitBytes) }

    func parse(_ data: Data) throws -> [String] {
        let parser = XMLParser(data: data)
        parser.shouldProcessNamespaces = false
        parser.shouldResolveExternalEntities = false
        parser.delegate = self
        guard parser.parse() || aborted else {
            let reason = failure.map { ($0 as NSError).localizedDescription }
                ?? "unknown XML error"
            throw FouineError.extraction("unreadable xl/sharedStrings.xml: \(reason)")
        }
        return strings
    }

    func parser(_ parser: XMLParser, didStartElement elementName: String,
                namespaceURI: String?, qualifiedName qName: String?,
                attributes attributeDict: [String: String] = [:]) {
        switch xmlLocalName(elementName) {
        case "si": inItem = true; current = ""
        case "t": if inItem { capturing += 1 }
        default: break
        }
    }

    func parser(_ parser: XMLParser, didEndElement elementName: String,
                namespaceURI: String?, qualifiedName qName: String?) {
        switch xmlLocalName(elementName) {
        case "si":
            strings.append(current)
            if !aborted, limit.account(current) {
                aborted = true
                parser.abortParsing()
            }
            current = ""
            inItem = false
        case "t": if capturing > 0 { capturing -= 1 }
        default: break
        }
    }

    func parser(_ parser: XMLParser, foundCharacters string: String) {
        if capturing > 0 { current += string }
    }

    func parser(_ parser: XMLParser, parseErrorOccurred parseError: Error) {
        failure = parseError
    }
}

/// `xl/worksheets/sheetN.xml` : une ligne du texte par `<row>`, cellules séparées
/// par une tabulation. Les références partagées (`t="s"`) sont résolues.
final class WorksheetParser: NSObject, XMLParserDelegate {
    private let shared: [String]
    /// Les formats de cellule du classeur (constat C2-07). Sans eux — un
    /// classeur sans `styles.xml` —, le comportement est celui d'avant : la
    /// valeur brute, et rien d'autre.
    private let format: SpreadsheetFormat
    private var rows: [String] = []
    private var cells: [String] = []
    private var cellType: String?
    /// L'attribut `s` de la cellule : son index de style.
    private var cellStyle: Int?
    private var value = String()
    private var capturing = 0
    private var failure: Error?
    /// Même plafond d'accumulation que XMLTextCollector (A11.2) : une feuille de
    /// calcul peut peser des centaines de mégaoctets une fois décompressée.
    private var limit: XMLTextLimit
    private var aborted = false

    init(shared: [String], format: SpreadsheetFormat = .none,
         limitBytes: Int = Int.max) {
        self.shared = shared
        self.format = format
        self.limit = XMLTextLimit(bytes: limitBytes)
    }

    func parse(_ data: Data, what: String) throws -> String {
        let parser = XMLParser(data: data)
        parser.shouldProcessNamespaces = false
        parser.shouldResolveExternalEntities = false
        parser.delegate = self
        guard parser.parse() || aborted else {
            let reason = failure.map { ($0 as NSError).localizedDescription }
                ?? "unknown XML error"
            throw FouineError.extraction("unreadable \(what): \(reason)")
        }
        return rows.joined(separator: "\n")
    }

    func parser(_ parser: XMLParser, didStartElement elementName: String,
                namespaceURI: String?, qualifiedName qName: String?,
                attributes attributeDict: [String: String] = [:]) {
        switch xmlLocalName(elementName) {
        case "row": cells = []
        case "c":
            cellType = attributeDict["t"]
            cellStyle = attributeDict["s"].flatMap(Int.init)
            value = ""
        case "v", "t": capturing += 1        // `t` couvre les inlineStr
        default: break
        }
    }

    func parser(_ parser: XMLParser, didEndElement elementName: String,
                namespaceURI: String?, qualifiedName qName: String?) {
        switch xmlLocalName(elementName) {
        case "v", "t":
            if capturing > 0 { capturing -= 1 }
        case "c":
            let raw = value.trimmingCharacters(in: .whitespacesAndNewlines)
            if cellType == "s", let index = Int(raw), index >= 0, index < shared.count {
                cells.append(shared[index])
            } else if !raw.isEmpty {
                // LES DEUX FORMES, la rendue puis la brute (constat C2-07) :
                // « 05/01/2026 46027 ». Seules les cellules NUMÉRIQUES ont un
                // format à appliquer ; un texte, un booléen ou une chaîne de
                // formule restent tels quels.
                let numeric = (cellType == nil || cellType == "n")
                if numeric, let shown = format.rendered(raw, styleIndex: cellStyle) {
                    cells.append("\(shown) \(raw)")
                } else {
                    cells.append(raw)
                }
            }
            value = ""
            cellType = nil
            cellStyle = nil
        case "row":
            let line = cells.joined(separator: "\t")
            rows.append(line)
            cells = []
            if !aborted, limit.account(line + "\n") {
                aborted = true
                parser.abortParsing()
            }
        default: break
        }
    }

    func parser(_ parser: XMLParser, foundCharacters string: String) {
        if capturing > 0 { value += string }
    }

    func parser(_ parser: XMLParser, parseErrorOccurred parseError: Error) {
        failure = parseError
    }
}
