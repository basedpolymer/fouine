// PDFExtractor.swift — PDFKit, décision D2 (SPEC §5.3, §6.1, pièges §7.2 n°1-2).
// Propriété : A-Ingest.
//
// Deux règles mesurées, non négociables :
//   · RÉOUVRIR le PDFDocument toutes les 100 pages. PDFPage.string fait fuir la
//     mémoire DANS le document : 1 515 Mo de RSS pour UN fil sur un livre de
//     1 315 pages, et un autoreleasepool par page n'y change rien. À 400 pages de
//     fenêtre le RSS remonte à 610 Mo : 100 est LE réglage, pas un ordre de
//     grandeur. Avec : 279 Mo/fil, texte identique au caractère près (§7.2 n°1).
//   · PDFDocument(url:) == nil est un ÉCHEC SILENCIEUX sur PDF corrompu : il doit
//     devenir FouineError.extraction, jamais un document qui disparaît de l'index
//     sans trace (§7.2 n°2).
//
// Seuil OCR (§6.1) : une page dont le texte natif fait moins de
// limits.ocrThresholdChars (100) caractères part en file. Une page qui a ce texte
// n'y va JAMAIS — l'OCR perd sur toutes les pages natives mesurées.

import Foundation
import PDFKit
import FouineCore

public struct PDFExtractor: TextExtractor {
    public static let supportedExtensions: Set<String> = ["pdf"]

    /// D2 / §7.2 n°1. Ce nombre est un réglage mesuré, pas un ordre de grandeur.
    public static let reopenEveryPages = 100

    public init() {}

    public func extract(url: URL, limits: ExtractLimits) throws -> ExtractionResult {
        try FileGuard.check(url, limits)

        // DÉLAI DE GARDE sur l'OUVERTURE (audit F6). `PDFDocument(url:)` parse
        // l'en-tête et la table des objets ; sur un fichier construit pour piéger
        // l'analyseur, il peut ne jamais rendre la main — et il n'y a aucune
        // option pour lui imposer une durée.
        guard let document = try Deadline.extraction(
            seconds: Deadline.pdfOpenSeconds,
            label: "opening \(url.lastPathComponent)",
            body: { PDFDocument(url: url) })
        else {
            throw FouineError.extraction(
                "unreadable PDF: PDFDocument(url:) returned nil (\(url.lastPathComponent))")
        }
        guard !document.isLocked else {
            throw FouineError.extraction(
                "password-protected PDF: document is locked (\(url.lastPathComponent))")
        }
        let pageCount = document.pageCount
        // REFUS AVANT TRAVAIL (audit S2). Le rowid structuré ne porte que
        // `Schema.maxPage` pages par document ; au-delà, `replacePages`
        // refuserait de toute façon — mais après avoir payé `PDFPage.string` sur
        // 100 000 pages, soit des dizaines de minutes pour un document qui ne
        // sera pas indexé. Le motif est le même des deux côtés, pour que
        // `docs.err` dise la même chose quel que soit le chemin.
        guard pageCount <= Schema.maxPage else {
            throw FouineError.extraction(
                "document too long: \(pageCount) pages, limit \(Schema.maxPage) "
                + "per document (\(url.lastPathComponent))")
        }
        let meta = Self.metadata(of: document)

        // DÉLAI DE GARDE sur la BOUCLE DE PAGES (audit F6). `PDFPage.string` est
        // le second appel PDFKit sans échéance, et c'est celui qui tourne des
        // milliers de fois. Le budget est proportionnel au nombre de pages —
        // une facture d'une page et un traité de 1 315 ne peuvent pas partager
        // la même limite (voir `Deadline.pdfPagesSeconds`).
        //
        // La boucle ENTIÈRE est bornée d'un coup, et non chaque page : borner
        // page par page coûterait un fil par page (379 267 fils sur le corpus),
        // pour un gain nul — ce qu'on veut empêcher est un gel, pas une page
        // lente.
        let harvested = try Deadline.extraction(
            seconds: Deadline.pdfPagesSeconds(pageCount: pageCount),
            label: "extracting the text of \(url.lastPathComponent) "
                 + "(\(pageCount) page(s))",
            body: { try Self.readPages(url: url, first: document,
                                       pageCount: pageCount, limits: limits) })

        return ExtractionResult(pages: harvested.pages, pageCount: pageCount,
                                ocrCandidates: harvested.ocrCandidates, meta: meta)
    }

    struct Harvest {
        let pages: [PageText]
        let ocrCandidates: [Int]
    }

    /// La boucle de pages, sortie de `extract` pour que `Deadline` puisse la
    /// porter sur un fil dédié. Le corps est INCHANGÉ, réouverture /100 pages
    /// comprise (D2, §7.2 n°1).
    static func readPages(url: URL, first: PDFDocument, pageCount: Int,
                          limits: ExtractLimits) throws -> Harvest {
        var document = first
        var pages: [PageText] = []
        var ocrCandidates: [Int] = []
        var budget = TextBudget(maxBytes: limits.maxTextBytes)

        for index in 0..<pageCount {
            // « Stop » se voit ENTRE DEUX PAGES (ST1) : un traité de 1 315
            // pages se lit en dizaines de secondes, et l'utilisateur n'a pas à
            // les attendre. Un appel de fermeture par page quand personne
            // n'annule — rien de mesurable à côté de `PDFPage.string`.
            if limits.shouldStop() { throw FouineError.cancelled }
            if index > 0, index % reopenEveryPages == 0 {
                guard let reopened = PDFDocument(url: url) else {
                    throw FouineError.extraction(
                        "unreadable PDF when reopening at page \(index + 1): "
                        + "PDFDocument(url:) returned nil (\(url.lastPathComponent))")
                }
                document = reopened
            }
            let raw: String = autoreleasepool {
                document.page(at: index)?.string ?? ""
            }
            let dense = raw.trimmingCharacters(in: .whitespacesAndNewlines).count
            if dense < limits.ocrThresholdChars {
                ocrCandidates.append(index + 1)
            } else {
                // Césures recollées (constat C2-10), AVANT le budget : un
                // document justifié perd sinon un mot sur quatre-vingts.
                let text = budget.take(Dehyphenation.rejoin(raw))
                if !TextPagination.isBlank(text) {
                    pages.append(PageText(page: index + 1, text: text, source: .native))
                }
                // Budget épuisé : les pages suivantes seraient toutes rendues
                // vides, donc jugées blanches, en payant PDFPage.string pour rien
                // (A11.5). On s'arrête comme les autres extracteurs paginés.
                if budget.isExhausted { break }
            }
        }
        return Harvest(pages: pages, ocrCandidates: ocrCandidates)
    }

    static func metadata(of document: PDFDocument) -> [String: String] {
        var meta: [String: String] = [:]
        guard let attributes = document.documentAttributes else { return meta }
        func put(_ key: PDFDocumentAttribute, _ name: String) {
            if let value = attributes[key.rawValue] as? String,
               !value.trimmingCharacters(in: .whitespaces).isEmpty {
                meta[name] = value
            }
        }
        put(.titleAttribute, "title")
        put(.authorAttribute, "author")
        put(.subjectAttribute, "subject")
        put(.creatorAttribute, "creator")
        // DATE DU DOCUMENT (schéma v9, constat PR-07). `creationDateAttribute`
        // est un `Date`, pas une chaîne : `put` ne la voit pas, et c'est
        // pourquoi elle manquait. La date de MODIFICATION, elle, n'est pas
        // reprise — ce serait `mtime` sous un autre nom, et la question posée
        // est « de quand est ce document », pas « quand a-t-il été retouché ».
        if let created = attributes[PDFDocumentAttribute.creationDateAttribute.rawValue] as? Date {
            meta["date"] = DocumentDate.isoDay(created)
        }
        return meta
    }
}
