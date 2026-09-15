// XMLDocumentExtractor.swift — xml xsd xsl xslt svg plist (lot INT-F1, SPEC §5.3).
// SPDX-License-Identifier: LicenseRef-Fouine-Source-Available
// Propriété : A-Ingest.
//
// Un fichier XML quelconque n'est pas un conteneur OOXML : on ne connaît ni son
// vocabulaire ni ses éléments de paragraphe. Trois règles seulement :
//
//   · le texte est celui des NŒUDS, jamais des attributs. Les attributs d'un
//     XML de configuration sont des identifiants, des chemins et des types —
//     du bruit qui gonflerait `fts5vocab` sans qu'on puisse le chercher ;
//   · la fin de CHAQUE élément fait un saut de ligne (`breakElements: nil`),
//     sans quoi un document écrit sur une seule ligne rendrait tout son texte
//     collé en un seul « mot » ;
//   · un document MAL FORMÉ n'est pas perdu : on retombe sur le texte brut. Un
//     XML tronqué ou à l'esperluette nue reste lisible pour un humain, et
//     l'index n'a pas à être plus regardant que lui.
//
// `plist` est le cas particulier : `PropertyListSerialization` lit les deux
// formes (XML et binaire `bplist00`) et rend une structure, qu'on écrit en
// « clé : valeur » par ligne. C'est la seule forme lisible : le SAX d'un plist
// XML rendrait la suite des clés et des valeurs sans dire laquelle va avec
// laquelle.
//
// Un document SANS TEXTE (un `.svg` de tracés purs, un `.xsd` de déclarations)
// n'est pas un échec : c'est un document qui n'a rien à indexer, donc `skipped`
// avec le motif `no text`.

import Foundation
import FouineCore

public struct XMLDocumentExtractor: TextExtractor {
    public static let supportedExtensions: Set<String> = [
        "xml", "xsd", "xsl", "xslt", "svg", "plist",
    ]

    /// Motif de refus d'un document XML sans une once de texte, classé
    /// `.skipped` par `ExtractOutcome` (un `.svg` de tracés purs).
    public static let noTextReason = "no text"

    public init() {}

    public func extract(url: URL, limits: ExtractLimits) throws -> ExtractionResult {
        try FileGuard.check(url, limits)
        let data: Data
        do {
            data = try Data(contentsOf: url, options: [.mappedIfSafe])
        } catch {
            throw FouineError.extraction(
                "cannot read (\(url.lastPathComponent)): "
                + (error as NSError).localizedDescription)
        }

        let ext = url.pathExtension.lowercased()
        var budget = TextBudget(maxBytes: limits.maxTextBytes)
        var raw: String?

        if ext == "plist" {
            raw = Self.propertyListText(data, limit: limits.maxTextBytes)
        }
        if raw == nil {
            let collector = XMLTextCollector(textElements: nil,
                                             breakElements: nil,
                                             limitBytes: budget.remaining)
            raw = try? collector.parse(data, what: url.lastPathComponent)
        }
        // Repli sur le texte brut : le document n'est pas bien formé, mais il
        // reste du texte. `decode` refuse le binaire, c'est lui le garde-fou.
        // L'URL est passée (lot MN1) : ces octets SONT ceux du fichier, donc
        // l'encodage inscrit dans `com.apple.TextEncoding` les décrit.
        if raw == nil { raw = PlainTextExtractor.decode(data, url: url) }

        guard let collected = raw else {
            throw FouineError.extraction(
                "unreadable XML (\(url.lastPathComponent)): neither well-formed "
                + "XML nor readable text")
        }

        let text = Self.tidy(collected)
        guard !text.isEmpty else { throw FouineError.extraction(Self.noTextReason) }
        try Plausibility.check(text, ext: ext)

        return Assembler.paginatedResult(text: budget.take(text), limits: limits,
                                         meta: [:])
    }

    /// Un saut de ligne par fin d'élément fabrique des rafales de lignes vides :
    /// on les ramène à une ligne vide au plus, et on retire les blancs de fin
    /// de ligne. Le texte indexé doit ressembler à ce que l'utilisateur verrait.
    static func tidy(_ text: String) -> String {
        var lines: [String] = []
        var blank = 0
        for line in text.split(separator: "\n", omittingEmptySubsequences: false) {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if trimmed.isEmpty {
                blank += 1
                if blank > 1 { continue }
                lines.append("")
            } else {
                blank = 0
                lines.append(trimmed)
            }
        }
        return lines.joined(separator: "\n")
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// « clé : valeur » par ligne, dictionnaires et tableaux compris. `nil` si
    /// ce ne sont pas des données de liste de propriétés.
    static func propertyListText(_ data: Data, limit: Int) -> String? {
        guard let object = try? PropertyListSerialization.propertyList(
                from: data, options: [], format: nil) else { return nil }
        var lines: [String] = []
        Self.render(object, key: nil, depth: 0, into: &lines, limit: limit)
        return lines.joined(separator: "\n")
    }

    private static func render(_ value: Any, key: String?, depth: Int,
                               into lines: inout [String], limit: Int) {
        // Plafond de PROFONDEUR et de VOLUME : un plist est un format de données,
        // rien n'y interdit dix mille niveaux ni cent mégaoctets.
        guard depth < 32, lines.count < limit / 8 else { return }
        let indent = String(repeating: "  ", count: depth)
        let label = key.map { "\($0) : " } ?? ""
        switch value {
        case let dictionary as [String: Any]:
            if let key { lines.append(indent + key + " :") } else if depth > 0 {
                lines.append(indent + ":")
            }
            for name in dictionary.keys.sorted() {
                render(dictionary[name] as Any, key: name, depth: depth + 1,
                       into: &lines, limit: limit)
            }
        case let array as [Any]:
            if let key { lines.append(indent + key + " :") }
            for item in array {
                render(item, key: nil, depth: depth + 1, into: &lines, limit: limit)
            }
        case let string as String:
            lines.append(indent + label + string)
        case let date as Date:
            lines.append(indent + label + ISO8601DateFormatter().string(from: date))
        case is Data:
            break                       // une donnée binaire ne s'indexe pas
        default:
            lines.append(indent + label + String(describing: value))
        }
    }
}
