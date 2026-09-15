// OCRGeometry.swift — projection des boîtes `ocr_layout` sur la page PDF.
// Propriété : A-App. SPEC §5.6.
//
// Les boîtes stockées sont NORMALISÉES 0..1, origine EN BAS À GAUCHE — convention
// Vision, identique à celle de PDFKit (Schema.swift). Elles ont été mesurées sur
// l'image RENDUE par FouinePageRenderer, qui applique `PDFPage.rotation`
// (largeur/hauteur échangées à 90° et 270°). Une `PDFAnnotation`, elle, vit dans
// l'espace NON tourné du mediaBox : à rotation non nulle il faut donc défaire la
// rotation avant de poser la boîte — PDFView la réappliquera à l'affichage.

import CoreGraphics
import FouineCore

enum OCRGeometry {

    /// Dénormalise une boîte `ocr_layout` vers l'espace du mediaBox de la page.
    /// - Parameters:
    ///   - line: boîte normalisée (0..1, origine bas-gauche, espace AFFICHÉ).
    ///   - mediaBox: `PDFPage.bounds(for: .mediaBox)`.
    ///   - rotation: `PDFPage.rotation`, en degrés (multiples de 90).
    static func denormalize(_ line: OCRLine, mediaBox: CGRect, rotation: Int) -> CGRect {
        let r = ((rotation % 360) + 360) % 360
        let w = mediaBox.width, h = mediaBox.height
        // Dimensions de la page telle qu'affichée (rotation appliquée).
        let displayW = (r == 90 || r == 270) ? h : w
        let displayH = (r == 90 || r == 270) ? w : h

        let d0 = CGPoint(x: line.x * displayW, y: line.y * displayH)
        let d1 = CGPoint(x: (line.x + line.w) * displayW,
                         y: (line.y + line.h) * displayH)

        // Inverse de la rotation d'affichage de PDFKit (90° = horaire) :
        //   90°  : affiché (dx, dy) = (y, w − x)   ⇒  (x, y) = (w − dy, dx)
        //   180° : affiché (dx, dy) = (w − x, h − y)
        //   270° : affiché (dx, dy) = (h − y, x)   ⇒  (x, y) = (dy, h − dx)
        func unrotate(_ p: CGPoint) -> CGPoint {
            switch r {
            case 90:  return CGPoint(x: w - p.y, y: p.x)
            case 180: return CGPoint(x: w - p.x, y: h - p.y)
            case 270: return CGPoint(x: p.y, y: h - p.x)
            default:  return p
            }
        }

        let p0 = unrotate(d0), p1 = unrotate(d1)
        return CGRect(x: min(p0.x, p1.x) + mediaBox.minX,
                      y: min(p0.y, p1.y) + mediaBox.minY,
                      width: abs(p1.x - p0.x),
                      height: abs(p1.y - p0.y))
    }
}
