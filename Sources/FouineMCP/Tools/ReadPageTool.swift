// ReadPageTool.swift — `fouine_read_page` (D2 § 5.5 n° 2).
// SPDX-License-Identifier: LicenseRef-Fouine-Source-Available
//
// CE QUE CET OUTIL NE FAIT PAS, et c'est le premier point : il ne rend PAS le
// fichier d'origine. Il rend le TEXTE que Fouine a extrait ou OCRisé, c'est-à-
// dire ce qui est déjà dans sa base. `abs_path` est fourni ; ouvrir le PDF est
// l'affaire de l'utilisateur ou d'un outil de fichiers. Un serveur de recherche
// qui déverse des documents entiers est une fuite de contexte et un risque de
// droit d'auteur — le refus est délibéré, pas une limite technique.
//
// LES CHIFFRES QUI FIXENT LES DÉFAUTS. Sur un échantillon de 20 000 pages de la
// production : page moyenne 2 528 caractères, maximum 15 667. Le défaut de
// 8 000 couvre donc la quasi-totalité des pages EN UN APPEL, et `offset` /
// `next_offset` traitent le reste sans qu'il faille un second outil. Rendre
// systématiquement 40 000 caractères « au cas où » coûterait ~13 000 jetons par
// appel pour une page qui en fait 850 en moyenne.
//
// UNE SEULE IMPLÉMENTATION, PARTAGÉE AVEC `fouine read` (lot MC4, constat
// PM-18). La lecture, la découpe, le contexte et les clés sont dans
// `PageReading` (FouineCore) depuis le lot MC3 ; cet outil n'ajoute que ce qui
// lui est propre : le plafond de réponse, le geste de ses messages d'erreur, et
// les trois champs qui disent ce qu'une page DÉSIGNE (`slide`,
// `embedded_image`, `time_seconds`). Deux implémentations de la même lecture
// finiraient par diverger comme `score` et `bm25`.
//
// LA PAGE VIDE N'EST PAS UNE ERREUR. Une page qui existe (`page ≤ page_count`)
// mais dont `page_fts` ne porte rien est une page image en attente d'OCR : elle
// est rendue en SUCCÈS, texte vide, avec un `note` qui explique. Un `isError`
// ferait croire au modèle que la page n'existe pas, et il abandonnerait le
// document. Ce qui est une erreur, c'est de demander une page que le document
// n'a PAS — et le message le dit avec le nombre de pages qu'il a vraiment.

import Foundation
import FouineCore
import FouineMCPKit

public final class ReadPageTool: MCPTool {

    public let name = "fouine_read_page"
    public let title = "Read one indexed page"
    public let description =
        "Read the indexed TEXT of one page — the text Fouine extracted or OCRed, "
        + "not the original file. Use it after fouine_search to read a hit in "
        + "context. Long pages come back in slices: pass next_offset back as offset. "
        + "Before citing, read page_label (the number printed on the page), slide, "
        + "embedded_image and time_seconds: they say what \"page N\" really means."

    static let maxChars = 40_000
    static let minChars = 200
    static let defaultChars = 8_000

    private let store: ReadOnlyStore

    public init(store: ReadOnlyStore) {
        self.store = store
    }

    // MARK: - Schémas

    public var inputSchema: [String: Any] {
        [
            "$schema": "https://json-schema.org/draft/2020-12/schema",
            "type": "object",
            "additionalProperties": false,
            "required": ["doc_id", "page"],
            "properties": [
                "doc_id": ["type": "integer", "minimum": 1] as [String: Any],
                "page": [
                    "type": "integer", "minimum": 1, "maximum": Schema.maxPage,
                    "description": "1-indexed, as returned by fouine_search.",
                ] as [String: Any],
                "max_chars": [
                    "type": "integer", "minimum": Self.minChars,
                    "maximum": Self.maxChars, "default": Self.defaultChars,
                    "description": "Characters to read from this page, and from each "
                        + "context page.",
                ] as [String: Any],
                "offset": [
                    "type": "integer", "minimum": 0, "default": 0,
                    "description": "Start reading this many characters in. Pass back "
                        + "next_offset to continue a long page.",
                ] as [String: Any],
                "context_pages": [
                    "type": "integer", "minimum": 0, "maximum": 2, "default": 0,
                    "description": "Also return this many pages before and after.",
                ] as [String: Any],
            ] as [String: Any],
        ]
    }

    public var outputSchema: [String: Any] {
        [
            "$schema": "https://json-schema.org/draft/2020-12/schema",
            "type": "object",
            "required": ["doc_id", "page", "text", "chars", "truncated", "link"],
            "properties": [
                "doc_id": ["type": "integer"] as [String: Any],
                "page": ["type": "integer"] as [String: Any],
                "page_label": [
                    "type": ["string", "null"],
                    "description": "The number PRINTED on the page when it differs "
                        + "from its rank (a book with front matter: page 12 prints "
                        + "\"XII\"). Null when they agree, or for anything but a PDF.",
                ] as [String: Any],
                "slide": [
                    "type": ["integer", "null"],
                    "description": "Slide number, for a slideshow. Cite \"slide 12\".",
                ] as [String: Any],
                "embedded_image": [
                    "type": ["integer", "null"],
                    "description": "This page is a picture stored inside the file, not "
                        + "a slide: cite it as a picture, never as a page.",
                ] as [String: Any],
                "time_seconds": [
                    "type": ["integer", "null"],
                    "description": "Moment in the recording, for a transcript. Cite "
                        + "\"at 12 min 40\"; the link carries it.",
                ] as [String: Any],
                "path": ["type": "string"] as [String: Any],
                "abs_path": ["type": ["string", "null"]] as [String: Any],
                "folder": ["type": "string"] as [String: Any],
                "ext": ["type": "string"] as [String: Any],
                "link": [
                    "type": "string",
                    "description": "fouine:// link that reopens Fouine on this page.",
                ] as [String: Any],
                "page_count": ["type": "integer"] as [String: Any],
                "text": ["type": "string"] as [String: Any],
                "chars": ["type": "integer",
                          "description": "Characters returned in text."] as [String: Any],
                "total_chars": ["type": "integer",
                                "description": "Length of the whole page."] as [String: Any],
                "truncated": ["type": "boolean"] as [String: Any],
                "next_offset": [
                    "type": ["integer", "null"],
                    "description": "Pass back as offset to read the rest. Null when the "
                        + "page is complete.",
                ] as [String: Any],
                // Les valeurs ÉMISES (`GRDBStore.sourceLabel`), pas celles du
                // filtre d'entrée `ocr` de fouine_search.
                "source": ["enum": ["native", "ocr_accurate", "transcript"],
                           "description": "Origin of the page text."] as [String: Any],
                "engine": ["type": "string"] as [String: Any],
                "ocr_confidence": [
                    "type": ["number", "null"],
                    "description": "Mean OCR confidence, 0-1. Null for native text.",
                ] as [String: Any],
                "note": ["type": ["string", "null"]] as [String: Any],
                "context": [
                    "type": "array",
                    "description": "Neighbouring pages, same fields, nearest first.",
                    "items": ["type": "object"] as [String: Any],
                ] as [String: Any],
            ] as [String: Any],
        ]
    }

    // MARK: - Appel

    public func call(arguments: [String: Any]) throws -> ToolResult {
        let docID = Int64(ToolSupport.int(arguments, "doc_id", 0))
        let page = ToolSupport.int(arguments, "page", 1)
        let chars = min(Self.maxChars,
                        max(Self.minChars, ToolSupport.int(arguments, "max_chars",
                                                           Self.defaultChars)))
        let offset = max(0, ToolSupport.int(arguments, "offset", 0))
        let context = min(2, max(0, ToolSupport.int(arguments, "context_pages", 0)))

        do {
            let reading: PageReading
            do {
                reading = try store.pageReading(docID: docID, page: page,
                                                maxChars: chars, offset: offset,
                                                contextPages: context)
            } catch let failure as PageReading.Failure {
                // Les phrases sont celles de `PageReading` ; l'outil y ajoute le
                // geste qui lui est propre — un assistant relance
                // `fouine_list_documents`, un humain au terminal `fouine list`.
                if case .unknownDocument = failure {
                    return .failure("\(failure) — use fouine_list_documents to see "
                                    + "what is indexed")
                }
                return .failure("\(failure)")
            }

            // Ce que la page DÉSIGNE (lot MC2) : une requête pour la frontière
            // diapositives / images incorporées, rien pour un PDF.
            let ext = reading.page.ext.lowercased()
            let textPages = PageLayout.textThenMedia.contains(ext)
                ? try store.textPageCounts(forDocIDs: [docID])[docID] : nil

            let (payload, budgeted) = ToolBudget.fit(
                textChars: chars, count: reading.context.count + 1) {
                shortened, keptPages in
                var body = reading.json(textLimit: shortened,
                                        keptContext: max(0, keptPages - 1))
                self.decorate(&body, page: reading.page, textPages: textPages)
                if var context = body["context"] as? [[String: Any]] {
                    for index in context.indices where index < reading.context.count {
                        self.decorate(&context[index], page: reading.context[index],
                                      textPages: textPages)
                    }
                    body["context"] = context
                }
                return body
            }
            var out = payload
            if budgeted { out["truncated"] = true }
            return ToolResult(out)
        } catch {
            return .failure("cannot read this page: " + MCPText.describe(error))
        }
    }

    // MARK: - Ce que la page désigne vraiment

    /// `slide`, `embedded_image`, `time_seconds` — et le lien horodaté qui va
    /// avec. Les trois réserves de la table « Citing a page » (PM-19, PM-20,
    /// PM-22) : `fouine_search` les rend depuis le lot MC2, et c'est ICI que le
    /// modèle lit la page qu'il va citer.
    ///
    /// Le moment se lit sur le TEXTE RENDU, sans lecture de plus : une page de
    /// transcription commence par son marqueur (`[00:01] …`), et c'est
    /// celui-là qu'il faut — le PREMIER, puisqu'il n'y a pas ici d'extrait qui
    /// désignerait un paragraphe plus loin.
    private func decorate(_ body: inout [String: Any], page: PageReading.Page,
                          textPages: Int?) {
        let time = page.source == .transcript
            ? TranscriptTime.first(in: page.text) : nil
        body["time_seconds"] = time.map { $0 as Any } ?? NSNull()
        if let time {
            body["link"] = ToolSupport.link(absolutePath: page.absPath,
                                            docID: page.docID, page: page.number,
                                            time: time)
        }
        let label = PageLayout.page(page.number, ext: page.ext, textPages: textPages)
        body["slide"] = label.slide.map { $0 as Any } ?? NSNull()
        body["embedded_image"] = label.embeddedImage.map { $0 as Any } ?? NSNull()
    }
}
