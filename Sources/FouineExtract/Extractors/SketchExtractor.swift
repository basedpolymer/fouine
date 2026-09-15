// SketchExtractor.swift — .sketch (SPEC §5.3, lot INT-F2).
// SPDX-License-Identifier: LicenseRef-Fouine-Source-Available
// Propriété : A-Ingest.
//
// Un fichier Sketch est un ZIP de JSON — c'est le seul format de maquette qui
// publie sa structure, et c'est pourquoi il est le seul dont on lise vraiment
// le texte (Figma et InDesign n'ont droit qu'à leur aperçu, voir
// DesignPreviewExtractor).
//
//   document.json          la liste ORDONNÉE des pages (« pages/<uuid> »)
//   pages/<uuid>.json      une page, un arbre de `layers`
//   previews/preview.png   l'aperçu, une seule image pour tout le document
//
// UNE PAGE SKETCH = UNE PAGE FOUINE, dans l'ordre de document.json : c'est
// l'unité que l'utilisateur voit dans l'onglet de gauche de Sketch, donc la
// seule qui rende « page 3 » lisible dans un résultat de recherche.
//
// Le texte d'une page, dans cet ordre : son nom, les noms de ses planches
// (`artboard`, `symbolMaster`), puis chaque calque texte dans l'ordre du
// fichier — une ligne chacun. Un nom de planche vaut souvent autant que le
// texte : « Écran de connexion » ne figure nulle part ailleurs.
//
// L'aperçu ne devient une page à OCRiser que sous le réglage `extract.images`,
// comme les médias OOXML : sans lui, personne n'a demandé qu'on lise des
// images. Il est alors la DERNIÈRE page du document.
//
// Rien n'est déballé : `Bsdtar.list` puis l'extraction des SEULES entrées
// voulues, sur la sortie standard (garde-fou Zip Slip du §5.3 acquis par
// construction).

import Foundation
import FouineCore

public struct SketchExtractor: TextExtractor {
    public static let supportedExtensions: Set<String> = ["sketch"]

    /// Motif exact de `docs.err` quand l'archive n'est pas un document Sketch.
    public static let noDocumentReason =
        "sketch: no document.json — not a Sketch file"

    public static let documentEntry = "document.json"
    public static let previewEntry = "previews/preview.png"

    /// Les images ne sont lues que si l'utilisateur l'a demandé (`extract.images`).
    /// Injecté par `DefaultExtractorRegistry`, comme pour `ImageExtractor`.
    private let extractImages: Bool

    public init(extractImages: Bool = false) {
        self.extractImages = extractImages
    }

    public func extract(url: URL, limits: ExtractLimits) throws -> ExtractionResult {
        try FileGuard.check(url, limits)

        let entries = try Bsdtar.list(archive: url)
        guard entries.contains(Self.documentEntry) else {
            throw FouineError.extraction(Self.noDocumentReason)
        }

        let documentData = try Bsdtar.extract(archive: url, entry: Self.documentEntry)
        let pageEntries = Self.pageEntries(documentJSON: documentData,
                                           entries: entries)
        guard !pageEntries.isEmpty else {
            throw FouineError.extraction(Self.noDocumentReason)
        }

        // UNE invocation de bsdtar pour toutes les pages (A11.6) : une par page
        // re-balayerait l'archive entière à chaque fois.
        let bodies = try Bsdtar.extract(archive: url, entries: pageEntries)

        var budget = TextBudget(maxBytes: limits.maxTextBytes)
        var slots: [String] = []
        var meta: [String: String] = [:]
        for entry in pageEntries {
            guard let data = bodies[entry] else {
                slots.append("")            // page illisible : l'emplacement reste
                continue
            }
            let text = budget.take(Self.pageText(from: data))
            slots.append(text)
            if budget.isExhausted { break }
        }
        while slots.count < pageEntries.count { slots.append("") }

        if let name = Self.documentName(from: documentData) { meta["title"] = name }

        var pages: [PageText] = []
        for (index, slot) in slots.enumerated() where !TextPagination.isBlank(slot) {
            pages.append(PageText(page: index + 1, text: slot, source: .native))
        }
        var pageCount = slots.count
        var ocrCandidates: [Int] = []
        if extractImages, entries.contains(Self.previewEntry) {
            pageCount += 1
            ocrCandidates = [pageCount]
        }
        return ExtractionResult(pages: pages, pageCount: pageCount,
                                ocrCandidates: ocrCandidates, meta: meta)
    }

    // MARK: - document.json

    /// Entrées `pages/<uuid>.json` DANS L'ORDRE de document.json. Les
    /// références qui ne correspondent à aucune entrée sont ignorées ; si
    /// document.json est illisible, on retombe sur toutes les entrées `pages/`
    /// triées — l'ordre est alors arbitraire, mais le texte est là.
    static func pageEntries(documentJSON: Data, entries: [String]) -> [String] {
        let available = Set(entries)
        var ordered: [String] = []
        if let root = (try? JSONSerialization.jsonObject(with: documentJSON))
            as? [String: Any],
           let references = root["pages"] as? [[String: Any]] {
            for reference in references {
                guard let ref = reference["_ref"] as? String else { continue }
                let candidate = ref.hasSuffix(".json") ? ref : ref + ".json"
                if available.contains(candidate) { ordered.append(candidate) }
            }
        }
        if ordered.isEmpty {
            ordered = EntrySort.sortedNaturally(entries.filter {
                $0.hasPrefix("pages/") && $0.lowercased().hasSuffix(".json")
            })
        }
        return ordered
    }

    static func documentName(from documentJSON: Data) -> String? {
        guard let root = (try? JSONSerialization.jsonObject(with: documentJSON))
                as? [String: Any] else { return nil }
        for key in ["name", "documentName"] {
            if let value = root[key] as? String, !value.isEmpty { return value }
        }
        return nil
    }

    // MARK: - Une page

    /// Le texte d'une page : son nom, les noms de ses planches, puis les
    /// calques texte dans l'ordre du fichier.
    static func pageText(from data: Data) -> String {
        guard let page = (try? JSONSerialization.jsonObject(with: data))
                as? [String: Any] else { return "" }
        var lines: [String] = []
        if let name = page["name"] as? String, !name.isEmpty { lines.append(name) }
        var boards: [String] = []
        var texts: [String] = []
        walk(page, boards: &boards, texts: &texts)
        return (lines + boards + texts).joined(separator: "\n")
    }

    /// Parcours récursif des `layers`. Un objet `_class == "text"` livre
    /// `attributedString.string` — et, à défaut, son `name` : Sketch y met le
    /// début du texte saisi, c'est mieux que rien.
    ///
    /// La profondeur est BORNÉE (64) : l'arbre vient d'un fichier que personne
    /// n'a validé, et une descente récursive sans borne se termine par un
    /// débordement de pile, pas par une erreur.
    static let maxDepth = 64

    static func walk(_ node: [String: Any], boards: inout [String],
                     texts: inout [String], depth: Int = 0) {
        guard depth < maxDepth else { return }
        let klass = node["_class"] as? String
        switch klass {
        case "artboard", "symbolMaster":
            if let name = node["name"] as? String, !name.isEmpty {
                boards.append(name)
            }
        case "text":
            if let attributed = node["attributedString"] as? [String: Any],
               let string = attributed["string"] as? String,
               !string.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                texts.append(string)
            } else if let name = node["name"] as? String, !name.isEmpty {
                texts.append(name)
            }
        default:
            break
        }
        guard let layers = node["layers"] as? [Any] else { return }
        for layer in layers {
            guard let child = layer as? [String: Any] else { continue }
            walk(child, boards: &boards, texts: &texts, depth: depth + 1)
        }
    }
}
