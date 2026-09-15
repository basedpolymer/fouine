// GrayRaster.swift — bitmaps en NIVEAUX DE GRIS, plafonnés à ~4 Mpx (SPEC §6.3).
// Propriété : A-OCR.
//
// Piège n°7, mesuré : « 150 dpi » n'est PAS une résolution, c'est un facteur
// d'échelle sur le mediaBox. Une page de 34 × 48 cm portant une image incorporée
// à 72 ppi produit 5,7 Mo de gris sans un pixel utile. Tout ce module existe pour
// que ce cas dégénéré soit borné, une fois, au même endroit, pour les trois voies
// de rendu (PDF, archive BD, média OOXML).
//
// Deux invariants tenus ici :
//   · l'image rendue est TOUJOURS DeviceGray 8 bits sans canal alpha — Vision
//     n'a que faire de la couleur et une page A4 à 150 dpi tient en 2,2 Mo
//     (mesuré) au lieu de 8,7 en RGBA ;
//   · sa surface ne dépasse JAMAIS `maxPixels`.

import Foundation
import CoreGraphics
import ImageIO
import FouineCore

enum GrayRaster {

    /// Plafond de surface, SPEC §6.3 (« ~4 Mpx »). Au-delà, l'échelle est réduite.
    static let maxPixels: Double = 4_000_000

    // MARK: - Échelle

    /// Facteur d'échelle effectif pour `dpi`, réduit si la surface dépasse le plafond.
    /// `widthPoints`/`heightPoints` sont les dimensions APRÈS rotation de la page.
    static func fittedScale(widthPoints: Double, heightPoints: Double,
                            dpi: Double, cap: Double = maxPixels) -> Double {
        guard widthPoints > 0, heightPoints > 0, dpi > 0 else { return 1 }
        let requested = dpi / 72.0
        let area = widthPoints * heightPoints * requested * requested
        guard area > cap else { return requested }
        return requested * (cap / area).squareRoot()
    }

    /// Dimensions en pixels, entières, jamais nulles, et JAMAIS au-dessus du
    /// plafond : l'arrondi d'un facteur d'échelle peut le repasser de quelques
    /// centaines de pixels, ce qui n'a aucune importance physique mais fait de
    /// « ≤ 4 Mpx » une promesse à moitié tenue. Ici elle l'est entièrement.
    static func pixelSize(widthPoints: Double, heightPoints: Double,
                          scale: Double,
                          cap: Double = maxPixels) -> (width: Int, height: Int) {
        var width = max(1, Int((widthPoints * scale).rounded()))
        var height = max(1, Int((heightPoints * scale).rounded()))
        let area = Double(width) * Double(height)
        if area > cap {
            let correction = (cap / area).squareRoot()
            width = max(1, Int((Double(width) * correction).rounded(.down)))
            height = max(1, Int((Double(height) * correction).rounded(.down)))
        }
        return (width, height)
    }

    // MARK: - Contexte

    /// Contexte DeviceGray 8 bits, sans alpha, initialisé en BLANC.
    /// Le fond blanc n'est pas cosmétique : `PDFPage.draw(with:to:)` « does not
    /// clear the background » et une page dessinée sur du noir est illisible.
    static func grayContext(width: Int, height: Int) throws -> CGContext {
        guard let context = CGContext(
            data: nil, width: width, height: height, bitsPerComponent: 8,
            bytesPerRow: 0, space: CGColorSpaceCreateDeviceGray(),
            bitmapInfo: CGImageAlphaInfo.none.rawValue) else {
            throw FouineError.ocr(
                "cannot create a \(width)×\(height) graphics context")
        }
        context.setFillColor(gray: 1, alpha: 1)
        context.fill(CGRect(x: 0, y: 0, width: width, height: height))
        context.interpolationQuality = .high
        return context
    }

    // MARK: - Conversion

    /// Recopie `image` en niveaux de gris, réduite si sa surface dépasse le plafond.
    static func toGray(_ image: CGImage, cap: Double = maxPixels) throws -> CGImage {
        let sourceWidth = Double(image.width), sourceHeight = Double(image.height)
        guard sourceWidth > 0, sourceHeight > 0 else {
            throw FouineError.ocr("zero-sized image")
        }
        var scale = 1.0
        let area = sourceWidth * sourceHeight
        if area > cap { scale = (cap / area).squareRoot() }

        let size = pixelSize(widthPoints: sourceWidth, heightPoints: sourceHeight,
                             scale: scale, cap: cap)
        // Déjà en gris 8 bits, sans alpha et sous le plafond : rien à faire.
        if size.width == image.width, size.height == image.height,
           image.bitsPerComponent == 8,
           image.colorSpace?.model == .monochrome,
           image.alphaInfo == .none {
            return image
        }
        let context = try grayContext(width: size.width, height: size.height)
        context.draw(image, in: CGRect(x: 0, y: 0,
                                       width: size.width, height: size.height))
        guard let out = context.makeImage() else {
            throw FouineError.ocr("grayscale conversion failed")
        }
        return out
    }

    // MARK: - Décodage d'une image encodée (cbz/cbr, médias OOXML)

    /// Décode des octets d'image (JPEG, PNG, TIFF…) en CGImage gris plafonné.
    /// Le sous-échantillonnage est demandé à ImageIO AVANT décodage complet :
    /// une planche de BD à 24 Mpx ne doit jamais être matérialisée en entier.
    static func decode(_ data: Data, label: String,
                       cap: Double = maxPixels) throws -> CGImage {
        guard let source = CGImageSourceCreateWithData(data as CFData, nil),
              CGImageSourceGetCount(source) > 0 else {
            throw FouineError.extraction("unreadable image: \(label)")
        }

        var image: CGImage?
        if let target = thumbnailMaxPixelSize(source, cap: cap) {
            image = CGImageSourceCreateThumbnailAtIndex(source, 0, [
                kCGImageSourceCreateThumbnailFromImageAlways: true,
                kCGImageSourceCreateThumbnailWithTransform: true,
                kCGImageSourceThumbnailMaxPixelSize: target,
            ] as CFDictionary)
        }
        if image == nil {
            image = CGImageSourceCreateImageAtIndex(source, 0, nil)
        }
        guard let decoded = image else {
            throw FouineError.extraction("image cannot be decoded: \(label)")
        }
        return try toGray(decoded, cap: cap)
    }

    /// Plus grande dimension acceptable pour que la surface reste sous le plafond,
    /// ou nil si l'image tient déjà (ou si ses dimensions sont inconnues).
    private static func thumbnailMaxPixelSize(_ source: CGImageSource,
                                              cap: Double) -> Int? {
        guard let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil)
                as? [CFString: Any],
              let width = (properties[kCGImagePropertyPixelWidth] as? NSNumber)?.doubleValue,
              let height = (properties[kCGImagePropertyPixelHeight] as? NSNumber)?.doubleValue,
              width > 0, height > 0 else { return nil }
        let area = width * height
        guard area > cap else { return nil }
        let scale = (cap / area).squareRoot()
        return max(1, Int((max(width, height) * scale).rounded()))
    }
}
