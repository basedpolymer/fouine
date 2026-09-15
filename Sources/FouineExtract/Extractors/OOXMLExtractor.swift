// OOXMLExtractor.swift — docx odt ods odp xlsx pptx (SPEC §5.3).
// Propriété : A-Ingest.
//
// « bsdtar -xOf + parse XML. OBLIGATOIRE : NSAttributedString rend 0 caractère
// SANS ERREUR sur xlsx et pptx (mesuré). »
//
// MÉDIAS EMBARQUÉS (§5.3, 61 conteneurs / 722 images mesurés) : word/media/*,
// ppt/media/* et xl/media/* deviennent des pages SUPPLÉMENTAIRES, numérotées
// APRÈS les pages de texte, sans PageText, toutes en ocrCandidates. Ce sont les
// figures scannées et les schémas réactionnels des diapositives de cours,
// aujourd'hui invisibles à l'index.

import Foundation
import FouineCore

enum OOXMLKind {
    case docx, odt, ods, odp, xlsx, pptx

    static func from(ext: String) -> OOXMLKind? {
        switch ext.lowercased() {
        case "docx": return .docx
        case "odt": return .odt
        case "ods": return .ods
        case "odp": return .odp
        case "xlsx": return .xlsx
        case "pptx": return .pptx
        default: return nil
        }
    }
}

enum OOXMLCore {
    /// Les trois gisements du §5.3. Un .odt n'en a aucun : la liste rendue est
    /// simplement vide.
    static let mediaPrefixes = ["word/media/", "ppt/media/", "xl/media/"]

    /// Entrées média triées par nom (ordre = ordre des pages ajoutées).
    static func mediaEntries(_ entries: [String]) -> [String] {
        let candidates = entries.filter { entry in
            mediaPrefixes.contains(where: { entry.hasPrefix($0) })
        }
        return EntrySort.imageEntries(candidates, allowed: EntrySort.ooxmlImageExtensions)
    }

    /// Emplacements de texte, dans l'ordre. DÉTERMINISTE à limits identiques :
    /// c'est ce qui garantit que OOXMLMedia.mediaMap renumérote les médias
    /// exactement comme l'extraction (§5.3).
    static func textSlots(url: URL, kind: OOXMLKind, entries: [String],
                          limits: ExtractLimits) throws -> [String] {
        var budget = TextBudget(maxBytes: limits.maxTextBytes)
        switch kind {
        case .docx:
            let docEntry = "word/document.xml"
            guard entries.contains(docEntry) else {
                throw FouineError.extraction(
                    "container without \(docEntry) (\(url.lastPathComponent))")
            }
            let footnoteEntry = "word/footnotes.xml"
            let endnoteEntry = "word/endnotes.xml"
            var wanted = [docEntry]
            if entries.contains(footnoteEntry) { wanted.append(footnoteEntry) }
            if entries.contains(endnoteEntry) { wanted.append(endnoteEntry) }

            let bodies = try Bsdtar.extract(archive: url, entries: wanted)
            guard let docData = bodies[docEntry] else {
                throw FouineError.extraction(
                    "container without \(docEntry) (\(url.lastPathComponent))")
            }

            func makeCollector() -> XMLTextCollector {
                XMLTextCollector(textElements: ["w:t"],
                                 breakElements: ["w:p"],
                                 inlineElements: ["w:br": "\n",
                                                  "w:cr": "\n",
                                                  "w:tab": "\t"],
                                 limitBytes: budget.remaining)
            }

            let docRaw = try makeCollector().parse(docData, what: docEntry)
            var text = budget.take(docRaw)

            // R-13 : notes de bas de page et de fin, tirées en une seule invocation
            // de bsdtar (A11.6). Les séparateurs w:separator ne portent pas de w:t donc
            // ne produisent aucun texte. Les notes sont ajoutées après le corps,
            // séparées par une ligne vide, sous TextBudget (qui coupera les notes
            // avant le corps en cas de budget réduit).
            for entry in [footnoteEntry, endnoteEntry] {
                guard !budget.isExhausted, let noteData = bodies[entry] else { continue }
                let noteRaw = try makeCollector().parse(noteData, what: entry)
                let trimmed = noteRaw.trimmingCharacters(in: .whitespacesAndNewlines)
                guard !trimmed.isEmpty else { continue }
                let separator = text.isEmpty ? "" : (text.hasSuffix("\n\n") ? "" : (text.hasSuffix("\n") ? "\n" : "\n\n"))
                text += budget.take(separator + trimmed)
            }

            return TextPagination.paginate(text, limit: limits.pageSplitChars)

        case .odt, .ods, .odp:
            let text = try wholeDocumentText(url: url, entries: entries,
                                             entry: "content.xml",
                                             collector: XMLTextCollector(
                                                textElements: nil,
                                                breakElements: ["text:p", "text:h"],
                                                inlineElements: ["text:tab": "\t",
                                                                 "text:line-break": "\n"],
                                                limitBytes: budget.remaining))
            return TextPagination.paginate(budget.take(text), limit: limits.pageSplitChars)

        case .pptx:
            // Une diapositive = une page (§5.3), triées par numéro.
            // Toutes les diapositives sont tirées en UNE invocation (A11.6).
            let slides = slideEntries(entries)
            let bodies = try Bsdtar.extract(archive: url, entries: slides)
            var slots: [String] = []
            for entry in slides {
                guard let data = bodies[entry] else { continue }
                let collector = XMLTextCollector(textElements: ["a:t"],
                                                 breakElements: ["a:p"],
                                                 inlineElements: ["a:br": "\n"],
                                                 limitBytes: budget.remaining)
                let text = budget.take(try collector.parse(data, what: entry))
                let split = TextPagination.paginate(text, limit: limits.pageSplitChars)
                slots += split.isEmpty ? [""] : split
                if budget.isExhausted { break }
            }
            return slots

        case .xlsx:
            // Une feuille = une page (§5.3), re-découpée à pageSplitChars.
            // Table des chaînes partagées et feuilles en UNE invocation (A11.6).
            let sheets = sheetEntries(entries)
            var wanted = sheets
            let sharedEntry = "xl/sharedStrings.xml"
            let stylesEntry = "xl/styles.xml"
            let workbookEntry = "xl/workbook.xml"
            if entries.contains(sharedEntry) { wanted.insert(sharedEntry, at: 0) }
            // Les formats de cellule (constat C2-07), tirés dans la MÊME
            // invocation de bsdtar que les feuilles (A11.6).
            for entry in [stylesEntry, workbookEntry] where entries.contains(entry) {
                wanted.insert(entry, at: 0)
            }
            let bodies = try Bsdtar.extract(archive: url, entries: wanted)

            var shared: [String] = []
            if let data = bodies[sharedEntry] {
                shared = try SharedStringsParser(limitBytes: limits.maxTextBytes)
                    .parse(data)
            }
            let format = SpreadsheetFormat.parse(styles: bodies[stylesEntry],
                                                 workbook: bodies[workbookEntry])
            var slots: [String] = []
            for entry in sheets {
                guard let data = bodies[entry] else { continue }
                let text = budget.take(
                    try WorksheetParser(shared: shared, format: format,
                                        limitBytes: budget.remaining)
                        .parse(data, what: entry))
                let split = TextPagination.paginate(text, limit: limits.pageSplitChars)
                slots += split.isEmpty ? [""] : split
                if budget.isExhausted { break }
            }
            return slots
        }
    }

    static func wholeDocumentText(url: URL, entries: [String], entry: String,
                                  collector: XMLTextCollector) throws -> String {
        guard entries.contains(entry) else {
            throw FouineError.extraction(
                "container without \(entry) (\(url.lastPathComponent))")
        }
        let data = try Bsdtar.extract(archive: url, entry: entry)
        return try collector.parse(data, what: entry)
    }

    static func slideEntries(_ entries: [String]) -> [String] {
        EntrySort.sortedNaturally(entries.filter {
            $0.hasPrefix("ppt/slides/slide") && $0.hasSuffix(".xml")
                && !$0.contains("/_rels/")
        })
    }

    static func sheetEntries(_ entries: [String]) -> [String] {
        EntrySort.sortedNaturally(entries.filter {
            $0.hasPrefix("xl/worksheets/") && $0.hasSuffix(".xml")
                && !$0.contains("/_rels/")
        })
    }

    /// Type d'un conteneur dont le NOM ne dit rien — un `.docx` renommé `.doc`
    /// (D2-01) : tranché sur les ENTRÉES de l'archive, comme
    /// `RichTextExtractor` tranche sur les octets de tête. `nil` si l'archive
    /// n'est aucun des quatre conteneurs du §5.3 (un `.epub`, un `.cbz`, un zip
    /// quelconque).
    static func kind(ofEntries entries: [String]) -> OOXMLKind? {
        if entries.contains("word/document.xml") { return .docx }
        if entries.contains("xl/workbook.xml") { return .xlsx }
        if entries.contains("ppt/presentation.xml") { return .pptx }
        if entries.contains("content.xml") { return .odt }
        return nil
    }

    /// Résultat complet : pages de texte puis pages média (§5.3).
    ///
    /// `kind: nil` = « tranche sur les entrées » : c'est la voie du conteneur
    /// mal nommé, et elle ne coûte rien de plus (l'archive est listée une seule
    /// fois de toute façon).
    static func result(url: URL, kind requested: OOXMLKind?, limits: ExtractLimits)
        throws -> ExtractionResult {
        let entries = try Bsdtar.list(archive: url)
        guard let kind = requested ?? kind(ofEntries: entries) else {
            throw RichTextExtractor.unrecognised(url)
        }
        let slots = try textSlots(url: url, kind: kind, entries: entries, limits: limits)
        let media = mediaEntries(entries)

        var pages: [PageText] = []
        for (index, slot) in slots.enumerated() where !TextPagination.isBlank(slot) {
            pages.append(PageText(page: index + 1, text: slot, source: .native))
        }
        // Les images embarquées sont des pages sans texte, numérotées APRÈS.
        let ocrCandidates = media.isEmpty
            ? []
            : Array((slots.count + 1)...(slots.count + media.count))
        // DATE DU DOCUMENT (schéma v9, constat PR-07) : `docProps/core.xml`
        // (ou `meta.xml` pour l'ODF), lu à part. L'archive est déjà listée —
        // le surcoût est UNE entrée de quelques centaines d'octets, et la
        // lecture ne se tente même pas quand l'entrée n'existe pas.
        var meta: [String: String] = [:]
        if let date = MetadataReader.containerDate(url: url, entries: entries) {
            meta["date"] = date
        }
        return ExtractionResult(pages: pages,
                                pageCount: slots.count + media.count,
                                ocrCandidates: ocrCandidates,
                                meta: meta)
    }
}

public struct OOXMLExtractor: TextExtractor {
    public static let supportedExtensions: Set<String> = ["docx", "odt", "ods", "odp", "xlsx", "pptx"]

    public init() {}

    public func extract(url: URL, limits: ExtractLimits) throws -> ExtractionResult {
        try FileGuard.check(url, limits)
        let ext = url.pathExtension.lowercased()
        guard let kind = OOXMLKind.from(ext: ext) else {
            throw FouineError.unsupported(ext: ext)
        }
        return try OOXMLCore.result(url: url, kind: kind, limits: limits)
    }
}

/// API publique consommée par A-OCR (vague 2) : SIGNATURES IMPOSÉES.
public enum OOXMLMedia {
    /// (nombre de pages de TEXTE, entrées média triées) d'un docx/pptx/xlsx.
    /// Le découpage étant déterministe, `textPages + i + 1` est bien le numéro de
    /// page de la i-ème image, le même qu'à l'extraction.
    public static func mediaMap(url: URL, limits: ExtractLimits)
        throws -> (textPages: Int, media: [String]) {
        let ext = url.pathExtension.lowercased()
        guard let kind = OOXMLKind.from(ext: ext) else {
            throw FouineError.unsupported(ext: ext)
        }
        let entries = try Bsdtar.list(archive: url)
        let slots = try OOXMLCore.textSlots(url: url, kind: kind, entries: entries,
                                            limits: limits)
        return (textPages: slots.count, media: OOXMLCore.mediaEntries(entries))
    }

    /// Contenu brut d'une entrée média. Rien n'est écrit sur disque (§5.3).
    public static func extractEntry(url: URL, entry: String) throws -> Data {
        try Bsdtar.extract(archive: url, entry: entry)
    }
}
