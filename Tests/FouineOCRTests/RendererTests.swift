// RendererTests.swift — FouinePageRenderer (SPEC §6.2, §6.3, pièges n°7 et n°8).
// Propriété : A-OCR.

import XCTest
import CoreGraphics
import ImageIO
import PDFKit
import FouineCore
@testable import FouineOCR

final class RendererTests: XCTestCase {

    private let renderer = FouinePageRenderer()

    // MARK: - Cas nominal

    /// A4 (595 × 842 pt) à 150 dpi = 1240 × 1754 px : le cas mesuré du §6.3,
    /// 2,2 Mo en niveaux de gris.
    func testA4RendersAtRequestedScale() throws {
        let directory = try TempDirectory()
        let url = directory.file("a4.pdf")
        try OCRTestSupport.writePDF([
            .init(width: 595, height: 842) { context in
                OCRTestSupport.drawText("Fouine", in: context,
                                        at: CGPoint(x: 60, y: 700))
            },
        ], to: url)

        let image = try renderer.render(url: url, page: 1, dpi: 150)
        XCTAssertEqual(image.width, 1240)
        XCTAssertEqual(image.height, 1754)
    }

    /// Piège n°7 : « 150 dpi » est un facteur d'échelle. Un mediaBox de 34 × 48 cm
    /// (964 × 1361 pt) rendrait 2008 × 2835 = 5,7 Mpx. Le plafond doit mordre.
    func testCapsAtFourMegapixels() throws {
        let directory = try TempDirectory()
        let url = directory.file("grand.pdf")
        try OCRTestSupport.writePDF([
            .init(width: 964, height: 1361) { context in
                context.setFillColor(gray: 0, alpha: 1)
                context.fill(CGRect(x: 100, y: 100, width: 300, height: 300))
            },
        ], to: url)

        let image = try renderer.render(url: url, page: 1, dpi: 150)
        let pixels = Double(image.width) * Double(image.height)
        XCTAssertLessThanOrEqual(pixels, GrayRaster.maxPixels,
                                 "surface \(pixels) px au-dessus du plafond")
        // Le plafond réduit l'échelle, il ne déforme pas la page.
        let sourceRatio = 964.0 / 1361.0
        let renderedRatio = Double(image.width) / Double(image.height)
        XCTAssertEqual(renderedRatio, sourceRatio, accuracy: 0.01)
        // Et il ne réduit pas plus que nécessaire : on reste tout près du plafond.
        XCTAssertGreaterThan(pixels, GrayRaster.maxPixels * 0.95)
    }

    /// Niveaux de gris 8 bits sans alpha, pour les trois voies.
    func testRendersInEightBitGray() throws {
        let directory = try TempDirectory()
        let url = directory.file("couleur.pdf")
        try OCRTestSupport.writePDF([
            .init(width: 300, height: 400) { context in
                context.setFillColor(red: 1, green: 0, blue: 0, alpha: 1)
                context.fill(CGRect(x: 20, y: 20, width: 200, height: 200))
            },
        ], to: url)

        let image = try renderer.render(url: url, page: 1, dpi: 150)
        XCTAssertEqual(image.bitsPerComponent, 8)
        XCTAssertEqual(image.bitsPerPixel, 8)
        XCTAssertEqual(image.colorSpace?.model, .monochrome)
        XCTAssertEqual(image.alphaInfo, .none)
    }

    // MARK: - Rotation (piège n°8)

    /// Une page paysage 400 × 200 pt portant une bande d'encre sur sa MOITIÉ
    /// GAUCHE. Sans rotation, l'encre est d'un côté en colonnes et répartie en
    /// rangées ; à 90°, les dimensions s'échangent ET l'encre bascule sur l'axe
    /// des rangées. C'est la preuve que la rotation est appliquée, pas seulement
    /// que la cible a été redimensionnée.
    func testRotationIsApplied() throws {
        let directory = try TempDirectory()
        let flat = directory.file("plat.pdf")
        let turned = directory.file("tourne.pdf")
        try OCRTestSupport.writePDF([
            .init(width: 400, height: 200) { context in
                context.setFillColor(gray: 0, alpha: 1)
                context.fill(CGRect(x: 0, y: 0, width: 200, height: 200))
            },
        ], to: flat)
        try OCRTestSupport.rotate(flat, page: 1, degrees: 90, to: turned)

        let straight = try renderer.render(url: flat, page: 1, dpi: 72)
        XCTAssertGreaterThan(straight.width, straight.height)
        let straightInk = OCRTestSupport.inkBalance(straight)
        // Encre entièrement d'un côté sur l'axe des colonnes…
        XCTAssertGreaterThan(abs(straightInk.columnsFirst - straightInk.columnsSecond),
                             0.8)
        // …et répartie sur l'axe des rangées.
        XCTAssertLessThan(abs(straightInk.rowsFirst - straightInk.rowsSecond), 0.2)

        let rotated = try renderer.render(url: turned, page: 1, dpi: 72)
        XCTAssertEqual(rotated.width, straight.height,
                       "les dimensions doivent s'échanger à 90°")
        XCTAssertEqual(rotated.height, straight.width)
        let rotatedInk = OCRTestSupport.inkBalance(rotated)
        // Les deux axes ont échangé leur rôle : c'est le contenu qui a tourné.
        XCTAssertLessThan(abs(rotatedInk.columnsFirst - rotatedInk.columnsSecond), 0.2)
        XCTAssertGreaterThan(abs(rotatedInk.rowsFirst - rotatedInk.rowsSecond), 0.8)
    }

    func testRotationIsNormalized() {
        XCTAssertEqual(FouinePageRenderer.normalizedRotation(0), 0)
        XCTAssertEqual(FouinePageRenderer.normalizedRotation(90), 90)
        XCTAssertEqual(FouinePageRenderer.normalizedRotation(-90), 270)
        XCTAssertEqual(FouinePageRenderer.normalizedRotation(450), 90)
        XCTAssertEqual(FouinePageRenderer.normalizedRotation(360), 0)
    }

    // MARK: - Erreurs

    /// Piège n°2 : `PDFDocument(url:)` rend nil EN SILENCE sur un PDF corrompu.
    func testCorruptPDFBecomesExtractionError() throws {
        let directory = try TempDirectory()
        let url = directory.file("casse.pdf")
        try Data("%PDF-1.4 ceci n'est pas un PDF".utf8).write(to: url)

        XCTAssertThrowsError(try renderer.render(url: url, page: 1, dpi: 150)) { error in
            guard case FouineError.extraction = error else {
                return XCTFail("attendu .extraction, reçu \(error)")
            }
        }
    }

    func testPageOutOfRange() throws {
        let directory = try TempDirectory()
        let url = directory.file("une-page.pdf")
        try OCRTestSupport.writePDF([
            .init(width: 200, height: 200) { _ in },
        ], to: url)

        XCTAssertThrowsError(try renderer.render(url: url, page: 7, dpi: 150)) { error in
            guard case FouineError.ocr = error else {
                return XCTFail("attendu .ocr, reçu \(error)")
            }
        }
        XCTAssertThrowsError(try renderer.render(url: url, page: 0, dpi: 150))
    }

    func testUnsupportedExtension() throws {
        let directory = try TempDirectory()
        let url = directory.file("note.txt")
        try Data("bonjour".utf8).write(to: url)

        XCTAssertThrowsError(try renderer.render(url: url, page: 1, dpi: 150)) { error in
            guard case FouineError.unsupported(let ext) = error else {
                return XCTFail("attendu .unsupported, reçu \(error)")
            }
            XCTAssertEqual(ext, "txt")
        }
    }

    // MARK: - Échelle et décodage

    func testFittedScaleHonoursCap() {
        // Sous le plafond : l'échelle demandée est rendue telle quelle.
        XCTAssertEqual(GrayRaster.fittedScale(widthPoints: 595, heightPoints: 842,
                                              dpi: 150),
                       150.0 / 72.0, accuracy: 1e-9)
        // Au-dessus : la surface obtenue vaut exactement le plafond.
        let scale = GrayRaster.fittedScale(widthPoints: 964, heightPoints: 1361,
                                           dpi: 150)
        XCTAssertEqual(964 * 1361 * scale * scale, GrayRaster.maxPixels,
                       accuracy: 1.0)
        XCTAssertLessThan(scale, 150.0 / 72.0)
    }

    /// Le décodage des images d'archive passe par la même conversion : gris,
    /// plafonné. On l'exerce sur un PNG produit à la volée.
    func testDecodeConvertsAndCaps() throws {
        let directory = try TempDirectory()
        let png = directory.file("grande.png")
        let context = try GrayRaster.grayContext(width: 3000, height: 2400)
        context.setFillColor(gray: 0, alpha: 1)
        context.fill(CGRect(x: 0, y: 0, width: 1500, height: 2400))
        try OCRExportRender.writePNG(context.makeImage()!, to: png)

        let data = try Data(contentsOf: png)
        let image = try GrayRaster.decode(data, label: "grande.png")
        XCTAssertLessThanOrEqual(Double(image.width) * Double(image.height),
                                 GrayRaster.maxPixels)
        XCTAssertEqual(image.colorSpace?.model, .monochrome)
        XCTAssertEqual(image.bitsPerComponent, 8)
    }

    func testDecodeRejectsGarbage() {
        XCTAssertThrowsError(
            try GrayRaster.decode(Data("pas une image".utf8), label: "test")
        ) { error in
            guard case FouineError.extraction = error else {
                return XCTFail("attendu .extraction, reçu \(error)")
            }
        }
    }

    // MARK: - Export PNG (annexe B)

    func testExportRendersNamedPNGs() throws {
        let directory = try TempDirectory()
        let pdf = directory.file("export.pdf")
        try OCRTestSupport.writePDF([
            .init(width: 300, height: 400) { context in
                OCRTestSupport.drawText("A", in: context, at: CGPoint(x: 30, y: 300))
            },
            .init(width: 300, height: 400) { context in
                OCRTestSupport.drawText("B", in: context, at: CGPoint(x: 30, y: 300))
            },
        ], to: pdf)

        let store = try TempStore()
        let out = directory.file("png")
        let written = try OCRExportRender.renderPNGs(
            store: store.store,
            pages: [(docID: 42, page: 1, path: pdf.path),
                    (docID: 42, page: 2, path: pdf.path),
                    (docID: 42, page: 9, path: pdf.path)],   // hors limites : ignorée
            dpi: 150, to: out, renderer: renderer, log: { _ in })

        XCTAssertEqual(written, 2)
        XCTAssertTrue(FileManager.default.fileExists(
            atPath: out.appendingPathComponent("42_1.png").path))
        XCTAssertTrue(FileManager.default.fileExists(
            atPath: out.appendingPathComponent("42_2.png").path))
        XCTAssertFalse(FileManager.default.fileExists(
            atPath: out.appendingPathComponent("42_9.png").path))

        // Le PNG écrit est bien un gris relisible, à la taille attendue.
        let data = try Data(contentsOf: out.appendingPathComponent("42_1.png"))
        let reread = try GrayRaster.decode(data, label: "42_1.png")
        XCTAssertEqual(reread.width, 625)
        XCTAssertEqual(reread.height, 833)
    }

    func testIWorkRendersFromPreview() throws {
        let directory = try TempDirectory()
        let packageURL = directory.file("Rapport.pages")
        let qlDir = packageURL.appendingPathComponent("QuickLook", isDirectory: true)
        try FileManager.default.createDirectory(at: qlDir, withIntermediateDirectories: true)
        let pdfURL = qlDir.appendingPathComponent("Preview.pdf")
        try OCRTestSupport.writePDF([
            .init(width: 595, height: 842) { context in
                OCRTestSupport.drawText("iWork Page 1", in: context, at: CGPoint(x: 60, y: 700))
            }
        ], to: pdfURL)

        let image = try renderer.render(url: packageURL, page: 1, dpi: 150)
        XCTAssertEqual(image.width, 1240)
        XCTAssertEqual(image.height, 1754)
    }

    // MARK: - Images géantes bornées (audit a3-06, lot K3)

    func testRenderGiantStandaloneImageIsBounded() throws {
        let directory = try TempDirectory()
        let url = directory.file("giant_9000.png")
        let width = 9000
        let height = 9000
        let data = Data(count: width * height)
        guard let provider = CGDataProvider(data: data as CFData),
              let cgImage = CGImage(
                width: width, height: height, bitsPerComponent: 8, bitsPerPixel: 8,
                bytesPerRow: width, space: CGColorSpaceCreateDeviceGray(),
                bitmapInfo: CGBitmapInfo(rawValue: 0), provider: provider,
                decode: nil, shouldInterpolate: false, intent: .defaultIntent),
              let dest = CGImageDestinationCreateWithURL(url as CFURL, "public.png" as CFString, 1, nil)
        else {
            return XCTFail("impossible de créer l'image de test 9000×9000")
        }
        CGImageDestinationAddImage(dest, cgImage, nil)
        CGImageDestinationFinalize(dest)

        let rendered = try FouinePageRenderer.renderImage(url: url)
        XCTAssertLessThanOrEqual(rendered.width, 4096)
        XCTAssertLessThanOrEqual(rendered.height, 4096)
        XCTAssertEqual(rendered.width, 4096)
        XCTAssertEqual(rendered.height, 4096)
    }
}
