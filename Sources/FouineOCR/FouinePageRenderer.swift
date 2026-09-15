// FouinePageRenderer.swift — rendu d'UNE page en niveaux de gris (SPEC §6.2, §6.3).
// Propriété : A-OCR. NOM IMPOSÉ : la CLI se câble dessus.
//
// Trois voies, une seule sortie : un CGImage DeviceGray 8 bits plafonné à ~4 Mpx.
//   · pdf              -> PDFKit (méd. 0,140 s/page mesurée, seuil P2 : 0,6 s) ;
//   · cbz / cbr        -> ArchiveImages, entrées triées = pages 1-indexées ;
//   · docx/pptx/xlsx   -> OOXMLMedia, page = textPages + rang du média.
//
// Deux pièges tenus ici :
//   · n°1 (§7.2) : PDFDocument RETIENT tout ce qu'il analyse. Le document est donc
//     ROUVERT à chaque appel et relâché avant le retour — rien n'est conservé entre
//     deux rendus. C'est le pendant, côté rendu, de la réouverture /100 pages de D2.
//   · n°8 (§7.2) : une page peut porter une rotation propre (PDFPage.rotation).
//     `drawWithBox:toContext:` la prend en compte lui-même (en-tête PDFKit :
//     « takes into account page rotation ») ; ce qui nous revient, et que PDFKit ne
//     fait PAS, c'est de dimensionner la cible avec la largeur et la hauteur
//     ÉCHANGÉES à 90° et 270°. Sans cela la page sort tronquée, pas seulement
//     pivotée. Vérifié par test unitaire sur une page tournée à 90°.
//
// Nuance mesurée sur la fixture T6 (CamScanner, §8.1) : sa page 1 a
// `rotation == 0` et un mediaBox A4 debout — c'est le CONTENU photographié qui est
// couché de 90°. Aucun rendu ne peut le redresser à partir du PDF ; c'est Vision
// `.accurate` qui s'en charge, et qui y arrive (`RCPA :` reconnu, §8.1 T6).

import Foundation
import CoreGraphics
import ImageIO
import PDFKit
import FouineCore
import FouineExtract

public struct FouinePageRenderer: PageRenderer {

    /// Résolution imposée par la spec (§6.2). Exposée pour la CLI et l'export.
    public static let defaultDPI: Double = 150
    /// Plafond de surface (§6.3).
    public static let maxPixels: Double = GrayRaster.maxPixels

    /// Limites d'extraction utilisées pour renuméroter les médias OOXML.
    /// Elles DOIVENT être celles de l'extraction, sinon `textPages` ne correspond
    /// plus et la page média est décalée (§5.3).
    private let limits: ExtractLimits

    public init(limits: ExtractLimits = ExtractLimits()) {
        self.limits = limits
    }

    // MARK: - PageRenderer

    public func render(url: URL, page: Int, dpi: Double) throws -> CGImage {
        guard page >= 1 else {
            throw FouineError.ocr("invalid page number: \(page)")
        }
        let ext = url.pathExtension.lowercased()
        switch ext {
        case "pdf":
            return try Self.renderPDF(url: url, page: page, dpi: dpi)
        case "cbz", "cbr":
            return try Self.renderComic(url: url, page: page)
        case "docx", "pptx", "xlsx":
            return try renderOOXML(url: url, page: page)
        case "pages", "numbers", "key":
            return try Self.renderIWork(url: url, page: page, dpi: dpi)
        case "sketch":
            return try Self.renderSketchPreview(url: url)
        case "fig", "indd":
            return try Self.renderDesignPreview(url: url, ext: ext)
        default:
            // La liste des images n'est PAS retapée ici (INT-F2) : elle est
            // celle de l'extracteur, sans quoi une extension ajoutée d'un côté
            // mettrait en file d'OCR des pages que personne ne saurait rendre.
            if ImageExtractor.supportedExtensions.contains(ext) {
                return try Self.renderImage(url: url, page: page)
            }
            throw FouineError.unsupported(ext: ext)
        }
    }

    // MARK: - PDF

    /// DÉLAI DE GARDE (audit F6) : `PDFDocument(url:)` et `pdfPage.draw` sont
    /// tous deux des appels PDFKit synchrones et sans échéance, sur un fichier
    /// que personne n'a validé. Le rendu ENTIER est borné d'un coup — le
    /// découper en deux n'apporterait qu'un message plus précis pour un fil de
    /// plus. Un dépassement rend `.ocr` : la page repart en file avec
    /// `attempts + 1`, comme n'importe quel échec de page (§6.3, piège n°13).
    static func renderPDF(url: URL, page: Int, dpi: Double) throws -> CGImage {
        try Deadline.ocr(seconds: Deadline.renderSeconds,
                         label: "rendering page \(page) of \(url.lastPathComponent)") {
            try renderPDFNow(url: url, page: page, dpi: dpi)
        }
    }

    static func renderPDFNow(url: URL, page: Int, dpi: Double) throws -> CGImage {
        // PDFDocument rouvert ET relâché à chaque appel : c'est le document qui
        // accumule, pas la page (piège n°1, mesuré à 1 515 Mo sur un fil).
        try autoreleasepool { () throws -> CGImage in
            guard let document = PDFDocument(url: url) else {
                throw FouineError.extraction(
                    "unreadable PDF: PDFDocument(url:) returned nil "
                    + "(\(url.lastPathComponent))")
            }
            guard page <= document.pageCount, let pdfPage = document.page(at: page - 1)
            else {
                throw FouineError.ocr(
                    "page \(page) out of range (\(document.pageCount) page(s)): "
                    + url.lastPathComponent)
            }

            let box = PDFDisplayBox.mediaBox
            let bounds = pdfPage.bounds(for: box)
            guard bounds.width > 0, bounds.height > 0 else {
                throw FouineError.ocr(
                    "empty mediaBox on page \(page): \(url.lastPathComponent)")
            }

            // Rotation : seules les DIMENSIONS de la cible nous reviennent.
            let quarterTurns = normalizedRotation(pdfPage.rotation)
            let upright = quarterTurns == 90 || quarterTurns == 270
            let widthPoints = upright ? Double(bounds.height) : Double(bounds.width)
            let heightPoints = upright ? Double(bounds.width) : Double(bounds.height)

            let scale = GrayRaster.fittedScale(widthPoints: widthPoints,
                                               heightPoints: heightPoints, dpi: dpi)
            let size = GrayRaster.pixelSize(widthPoints: widthPoints,
                                            heightPoints: heightPoints,
                                            scale: scale)
            // L'échelle effective tient compte de l'arrondi : sans cela la page
            // serait dessinée légèrement plus grande que sa cible et rognée.
            let drawScale = min(Double(size.width) / widthPoints,
                                Double(size.height) / heightPoints)
            let context = try GrayRaster.grayContext(width: size.width,
                                                     height: size.height)
            context.saveGState()
            context.scaleBy(x: drawScale, y: drawScale)
            // Applique lui-même rotation et décalage d'origine de la boîte.
            pdfPage.draw(with: box, to: context)
            context.restoreGState()

            guard let image = context.makeImage() else {
                throw FouineError.ocr(
                    "rendering failed on page \(page): \(url.lastPathComponent)")
            }
            return image
        }
    }

    /// 0, 90, 180 ou 270, y compris pour une rotation négative ou > 360.
    static func normalizedRotation(_ degrees: Int) -> Int {
        let wrapped = ((degrees % 360) + 360) % 360
        // PDFKit normalise déjà ; une valeur exotique est ramenée au quart de tour
        // le plus proche plutôt que rejetée.
        return ((wrapped + 45) / 90 % 4) * 90
    }

    // MARK: - Archives BD

    static func renderComic(url: URL, page: Int) throws -> CGImage {
        let entries = try ArchiveImages.imageEntries(archiveURL: url)
        guard page <= entries.count else {
            throw FouineError.ocr(
                "page \(page) out of range (\(entries.count) image(s)): "
                + url.lastPathComponent)
        }
        let entry = entries[page - 1]
        let data = try ArchiveImages.extractEntry(archiveURL: url, entry: entry)
        return try GrayRaster.decode(data, label: "\(url.lastPathComponent)!\(entry)")
    }

    // MARK: - Médias OOXML

    func renderOOXML(url: URL, page: Int) throws -> CGImage {
        let map = try OOXMLMedia.mediaMap(url: url, limits: limits)
        // Une page ≤ textPages est une page de TEXTE : elle n'a pas d'image et
        // n'aurait jamais dû entrer en file (§6.1). L'erreur est explicite plutôt
        // que silencieuse — sinon la page part en échec sans raison lisible.
        guard page > map.textPages else {
            throw FouineError.ocr(
                "page \(page) of \(url.lastPathComponent) is a text page "
                + "(\(map.textPages) text page(s)): no image to run OCR on")
        }
        let index = page - map.textPages
        guard index <= map.media.count else {
            throw FouineError.ocr(
                "page \(page) out of range (\(map.textPages) text page(s) + "
                + "\(map.media.count) media): \(url.lastPathComponent)")
        }
        let entry = map.media[index - 1]
        let data = try OOXMLMedia.extractEntry(url: url, entry: entry)
        return try GrayRaster.decode(data, label: "\(url.lastPathComponent)!\(entry)")
    }

    // MARK: - iWork

    static func renderIWork(url: URL, page: Int, dpi: Double) throws -> CGImage {
        var st = stat()
        guard stat(url.path, &st) == 0 else {
            throw FouineError.extraction(
                "unreadable file: \(url.lastPathComponent)")
        }
        let isDirectory = (st.st_mode & S_IFMT) == S_IFDIR
        if isDirectory {
            let previewURL = url.appendingPathComponent(IWorkExtractor.previewEntry)
            guard FileManager.default.fileExists(atPath: previewURL.path) else {
                throw FouineError.ocr(
                    "iWork document without a QuickLook preview: \(url.lastPathComponent)")
            }
            return try renderPDF(url: previewURL, page: page, dpi: dpi)
        } else {
            let entries = try Bsdtar.list(archive: url)
            guard entries.contains(IWorkExtractor.previewEntry) else {
                throw FouineError.ocr(
                    "iWork document without a QuickLook preview: \(url.lastPathComponent)")
            }
            let data = try Bsdtar.extract(archive: url, entry: IWorkExtractor.previewEntry)
            let tempDir = URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
                .appendingPathComponent("fouine-render-iwork-\(UUID().uuidString)", isDirectory: true)
            try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
            defer { try? FileManager.default.removeItem(at: tempDir) }
            let tempPDF = tempDir.appendingPathComponent("Preview.pdf")
            try data.write(to: tempPDF)
            return try renderPDF(url: tempPDF, page: page, dpi: dpi)
        }
    }

    // MARK: - Maquettes (INT-F2)

    /// L'aperçu d'un document Sketch. Il n'y en a QU'UN pour tout le document :
    /// le numéro de page n'entre donc pas dans le choix de l'image — la seule
    /// page qu'un `.sketch` met en file d'OCR est celle de l'aperçu, les autres
    /// portent du texte natif et ne sont jamais candidates (§6.1).
    static func renderSketchPreview(url: URL) throws -> CGImage {
        let entries = try Bsdtar.list(archive: url)
        guard entries.contains(SketchExtractor.previewEntry) else {
            throw FouineError.ocr(
                "Sketch document without a preview image: \(url.lastPathComponent)")
        }
        let data = try Bsdtar.extract(archive: url,
                                      entry: SketchExtractor.previewEntry)
        return try GrayRaster.decode(
            data, label: "\(url.lastPathComponent)!\(SketchExtractor.previewEntry)")
    }

    /// L'aperçu d'un `.fig` ou d'un `.indd`, par la MÊME fonction que celle qui
    /// a décidé de le mettre en file.
    static func renderDesignPreview(url: URL, ext: String) throws -> CGImage {
        let data = try DesignPreviewExtractor.previewData(of: url, ext: ext)
        return try GrayRaster.decode(data, label: url.lastPathComponent)
    }

    // MARK: - Images seules (audit E4, D2 § 5.12, a3-06)

    /// Un TIFF vaut ses images (constat C2-03) : la page `n` est l'image
    /// d'index `n - 1`. Tout autre format d'image seule reste à une page — un
    /// GIF animé est un mouvement, pas un document de vingt pages.
    static func renderImage(url: URL, page: Int = 1) throws -> CGImage {
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil),
              CGImageSourceGetCount(source) > 0 else {
            throw FouineError.extraction("unreadable image: \(url.lastPathComponent)")
        }
        let pages = ImageExtractor.pageCount(of: source, ext: url.pathExtension)
        guard page >= 1, page <= pages else {
            throw FouineError.ocr(
                "page \(page) out of range: standalone image has only "
                + "\(pages) page(s) (\(url.lastPathComponent))")
        }
        let options: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceThumbnailMaxPixelSize: 4096,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceShouldCacheImmediately: false,
        ]
        guard let thumb = CGImageSourceCreateThumbnailAtIndex(
                source, page - 1, options as CFDictionary) else {
            throw FouineError.extraction("image cannot be decoded: \(url.lastPathComponent)")
        }
        return try GrayRaster.toGray(thumb, cap: 4096 * 4096)
    }

    static func renderImage(url: URL) throws -> CGImage {
        try renderImage(url: url, page: 1)
    }
}
