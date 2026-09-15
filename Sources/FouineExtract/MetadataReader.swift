// MetadataReader.swift — LA SEULE DATE D'UN FICHIER, sans en extraire le texte
// (lot DD1, constat PR-07). Propriété : A-Ingest.
// SPDX-License-Identifier: LicenseRef-Fouine-Source-Available
//
// POURQUOI CE FICHIER EXISTE. La date du document (schéma v9) est écrite à
// l'EXTRACTION, depuis `ExtractionResult.meta["date"]`. Un fonds déjà indexé —
// 1 527 documents et des dizaines d'heures d'OCR sur la machine de référence —
// n'a donc aucune date, et tout ré-extraire pour une colonne serait exactement
// la perte que le lot K6 avait refusée pour `inode`.
//
// Ce lecteur ouvre le fichier et n'en lit QUE la métadonnée de date :
//   · PDF  : `PDFDocument` sans rendre une seule page ;
//   · OOXML/ODF : `docProps/core.xml` (ou `meta.xml`) SEUL, jamais le corps ;
//   · EPUB : l'OPF seul, pas un chapitre ;
//   · image : `CGImageSourceCopyPropertiesAtIndex` sans décoder les pixels ;
//   · courriel : les EN-TÊTES, sur les premiers kilo-octets du fichier.
//
// AUCUNE ERREUR NE REMONTE : un fichier illisible, un format qu'on ne sait pas
// dater, une archive tronquée rendent `nil`. Le rattrapage parcourt un fonds
// entier — il ne peut pas s'arrêter au premier PDF cassé, et « pas de date »
// est déjà le cas normal de la majorité des documents.

import Foundation
import PDFKit
import ImageIO
import CoreGraphics
import FouineCore

public enum MetadataReader {

    /// Combien d'octets de tête sont lus d'un courriel pour y trouver `Date:`.
    /// Les en-têtes d'un message ordinaire tiennent en deux ou trois kilo-octets ;
    /// 64 Kio couvrent les chaînes de `Received:` les plus bavardes sans jamais
    /// charger la pièce jointe qui suit.
    static let emailHeaderBytes = 64 * 1024

    /// La date brute inscrite dans le fichier, telle que son format l'écrit —
    /// c'est `DocumentDate.parse` qui l'analyse, à un seul endroit du dépôt.
    /// `nil` : format sans date, métadonnée absente, ou fichier illisible.
    public static func date(of url: URL) -> String? {
        let ext = url.pathExtension.lowercased()
        if PDFExtractor.supportedExtensions.contains(ext) { return pdfDate(url) }
        if OOXMLExtractor.supportedExtensions.contains(ext) { return containerDate(url) }
        if EPUBExtractor.supportedExtensions.contains(ext) { return epubDate(url) }
        if ImageExtractor.supportedExtensions.contains(ext) { return imageDate(url) }
        if EMLExtractor.supportedExtensions.contains(ext) { return emailDate(url) }
        return nil
    }

    // MARK: - Un format, une lecture

    /// PDF : `PDFDocument(url:)` lit le catalogue et le dictionnaire
    /// d'information, pas les flux de contenu ; aucune page n'est rendue.
    /// Mesuré le 11/09/2026 sur la base de production (voir le rapport du lot) :
    /// les 1 527 documents du fonds sont datés en moins de deux minutes, là où
    /// une ré-extraction demanderait des heures.
    static func pdfDate(_ url: URL) -> String? {
        guard let document = PDFDocument(url: url),
              let attributes = document.documentAttributes,
              let created = attributes[PDFDocumentAttribute.creationDateAttribute.rawValue] as? Date
        else { return nil }
        return DocumentDate.isoDay(created)
    }

    /// docx / xlsx / pptx : `docProps/core.xml`, élément `dcterms:created`.
    /// odt / ods / odp : `meta.xml`, élément `meta:creation-date` (et à défaut
    /// `dc:date`, que certains producteurs remplissent seuls).
    static func containerDate(_ url: URL) -> String? {
        guard let entries = try? Bsdtar.list(archive: url) else { return nil }
        return containerDate(url: url, entries: entries)
    }

    /// Variante pour l'EXTRACTION, où l'archive vient d'être listée : on ne la
    /// liste pas deux fois (`OOXMLCore.result`).
    static func containerDate(url: URL, entries: [String]) -> String? {
        for (entry, elements) in [
            ("docProps/core.xml", ["dcterms:created"]),
            ("meta.xml", ["meta:creation-date", "dc:date"]),
        ] {
            guard entries.contains(entry),
                  let data = try? Bsdtar.extract(archive: url, entry: entry)
            else { continue }
            for element in elements {
                let collector = XMLTextCollector(textElements: [element],
                                                 breakElements: [element])
                guard let raw = try? collector.parse(data, what: entry) else { continue }
                let value = raw.trimmingCharacters(in: .whitespacesAndNewlines)
                if !value.isEmpty { return value }
            }
        }
        return nil
    }

    /// EPUB : le premier `<dc:date>` de l'OPF. On passe par le même chemin que
    /// l'extraction (`container.xml` puis l'OPF), sans toucher au contenu.
    static func epubDate(_ url: URL) -> String? {
        guard let entries = try? Bsdtar.list(archive: url) else { return nil }
        var meta: [String: String] = [:]
        _ = try? EPUBExtractor.spineEntries(url: url, entries: entries, meta: &meta)
        return meta["date"]
    }

    /// Image : les propriétés EXIF de la première représentation, sans décoder
    /// les pixels (`kCGImageSourceShouldCache: false`).
    static func imageDate(_ url: URL) -> String? {
        let options: [CFString: Any] = [kCGImageSourceShouldCache: false]
        guard let source = CGImageSourceCreateWithURL(url as CFURL,
                                                      options as CFDictionary)
        else { return nil }
        return ImageExtractor.exifDate(of: source, options: options)
    }

    /// Courriel : l'en-tête `Date:` (RFC 5322). Seuls les premiers kilo-octets
    /// sont lus — un `.eml` de vingt mégaoctets est un message avec une pièce
    /// jointe, et sa date est dans les trois premières lignes.
    static func emailDate(_ url: URL) -> String? {
        guard let handle = try? FileHandle(forReadingFrom: url) else { return nil }
        defer { try? handle.close() }
        guard let head = try? handle.read(upToCount: emailHeaderBytes), !head.isEmpty
        else { return nil }
        let message = EMLXFraming.message(in: head)
        let (rawHeaders, _) = EMLParser.splitHeaderAndBody(message)
        return EMLParser.parseHeaders(rawHeaders)["date"]
            .map { EMLParser.decodeMIMEWords($0) }
    }
}
