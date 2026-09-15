// OCRTestSupport.swift — fabriques de fixtures SYNTHÉTIQUES. Propriété : A-OCR.
//
// Rien n'est lu ni écrit dans le corpus : chaque test construit ses propres PDF
// dans son propre dossier temporaire, et sa propre base SQLite. La seule fixture
// réelle du module est T6 (§8.1), en lecture stricte, et elle se saute si absente.

import Foundation
import XCTest
import CoreGraphics
import CoreText
import PDFKit
import FouineCore
@testable import FouineOCR

/// Dossier temporaire à soi, effacé à la fin du test.
final class TempDirectory {
    let url: URL

    init() throws {
        url = FileManager.default.temporaryDirectory
            .appendingPathComponent("fouine-ocr-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: url,
                                                withIntermediateDirectories: true)
    }

    deinit { try? FileManager.default.removeItem(at: url) }

    func file(_ name: String) -> URL { url.appendingPathComponent(name) }
}

/// Base SQLite temporaire, dans son propre dossier (donc son propre `fouine.lock`).
/// Aucune variable d'environnement, aucun chemin par défaut : la base par défaut de
/// l'utilisateur n'est JAMAIS touchée par les tests.
final class TempStore {
    let directory: TempDirectory
    let store: GRDBStore

    init() throws {
        directory = try TempDirectory()
        store = GRDBStore()
        try store.open(at: directory.file("fouine.db"))
    }
}

enum OCRTestSupport {

    // MARK: - Construction de PDF

    struct PageSpec {
        let width: Double
        let height: Double
        let draw: (CGContext) -> Void
    }

    /// Écrit un PDF synthétique. Chaque page est dessinée par sa clôture, dans le
    /// repère PDF habituel (origine EN BAS À GAUCHE, unité = point).
    static func writePDF(_ pages: [PageSpec], to url: URL) throws {
        var defaultBox = CGRect(x: 0, y: 0,
                                width: pages.first?.width ?? 595,
                                height: pages.first?.height ?? 842)
        guard let context = CGContext(url as CFURL, mediaBox: &defaultBox, nil) else {
            throw FouineError.ocr("contexte PDF impossible : \(url.path)")
        }
        for page in pages {
            let box = CGRect(x: 0, y: 0, width: page.width, height: page.height)
            // kCGPDFContextMediaBox attend une CFData portant un CGRect.
            let boxData = withUnsafeBytes(of: box) { Data($0) }
            let info = [kCGPDFContextMediaBox as String: boxData] as CFDictionary
            context.beginPDFPage(info)
            page.draw(context)
            context.endPDFPage()
        }
        context.closePDF()
    }

    /// Réécrit `source` avec la rotation demandée sur la page `page` (1-indexée).
    /// C'est le seul moyen d'obtenir un `PDFPage.rotation` non nul de façon fiable :
    /// CoreGraphics n'écrit pas la clé /Rotate.
    static func rotate(_ source: URL, page: Int, degrees: Int, to target: URL) throws {
        guard let document = PDFDocument(url: source),
              let pdfPage = document.page(at: page - 1) else {
            throw FouineError.ocr("PDF de test illisible : \(source.path)")
        }
        pdfPage.rotation = degrees
        guard document.write(to: target) else {
            throw FouineError.ocr("PDF de test non écrit : \(target.path)")
        }
    }

    // MARK: - Dessin

    /// Une ligne de texte noir, ancrée en bas à gauche du point donné.
    static func drawText(_ text: String, in context: CGContext,
                         at point: CGPoint, size: CGFloat = 36) {
        let font = CTFontCreateWithName("Helvetica" as CFString, size, nil)
        let attributes: [NSAttributedString.Key: Any] = [
            .init(rawValue: kCTFontAttributeName as String): font,
            .init(rawValue: kCTForegroundColorAttributeName as String):
                CGColor(gray: 0, alpha: 1),
        ]
        let line = CTLineCreateWithAttributedString(
            NSAttributedString(string: text, attributes: attributes))
        context.textPosition = point
        CTLineDraw(line, context)
    }

    /// Une image de texte en niveaux de gris, sans passer par un fichier.
    static func textImage(width: Int, height: Int,
                          lines: [(String, CGPoint)],
                          size: CGFloat = 36) throws -> CGImage {
        let context = try GrayRaster.grayContext(width: width, height: height)
        for (text, point) in lines {
            drawText(text, in: context, at: point, size: size)
        }
        guard let image = context.makeImage() else {
            throw FouineError.ocr("image de test non produite")
        }
        return image
    }

    // MARK: - Mesure d'encre

    /// Répartition des pixels sombres, en fractions de l'encre totale.
    /// Les moitiés « A » et « B » de l'axe des lignes ne sont volontairement pas
    /// nommées « haut » et « bas » : l'ordre des rangées en mémoire n'est pas un
    /// contrat, et aucun test n'en dépend.
    static func inkBalance(_ image: CGImage)
        -> (columnsFirst: Double, columnsSecond: Double,
            rowsFirst: Double, rowsSecond: Double) {
        guard let data = image.dataProvider?.data,
              let bytes = CFDataGetBytePtr(data) else { return (0, 0, 0, 0) }
        let width = image.width, height = image.height
        let stride = image.bytesPerRow
        let components = max(1, image.bitsPerPixel / 8)
        var left = 0.0, right = 0.0, first = 0.0, second = 0.0
        for row in 0..<height {
            for column in 0..<width {
                let value = bytes[row * stride + column * components]
                guard value < 128 else { continue }
                if column < width / 2 { left += 1 } else { right += 1 }
                if row < height / 2 { first += 1 } else { second += 1 }
            }
        }
        let total = max(1, left + right)
        return (left / total, right / total, first / total, second / total)
    }

    // MARK: - Fixture réelle T6 (§8.1)

    /// Variable d'environnement qui désigne le PDF T6 : chemin COMPLET sur la
    /// machine qui lance les tests. Même idiome que `FOUINE_BIN` dans
    /// `Tests/Integration/IntegrationSupport.swift`.
    static let t6EnvironmentKey = "FOUINE_T6_FIXTURES"

    /// AUCUN chemin de fixture n'est écrit en dur ici, et c'est délibéré : la
    /// fixture T6 est un document personnel du mainteneur (audit B1-29 a). Son
    /// chemin vit dans `Tests/Fixtures/paths.json`, GITIGNORÉ (SPEC §9.3), ou
    /// dans `FOUINE_T6_FIXTURES`. Un littéral publierait le chemin — et donc
    /// l'intitulé de cours — dans les journaux publics de l'intégration
    /// continue, où ce test se saute de toute façon.
    static func t6PathFromFixtureFile() -> String? {
        let url = URL(fileURLWithPath: #filePath)          // Tests/FouineOCRTests
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appendingPathComponent("Fixtures/paths.json")
        guard let data = try? Data(contentsOf: url),
              let root = try? JSONSerialization.jsonObject(with: data)
                as? [String: Any],
              let fixtures = root["fixtures"] as? [String: Any],
              let entry = fixtures["T6"] as? [String: Any],
              let path = entry["path"] as? String
        else { return nil }
        return path
    }

    /// `FOUINE_T6_FIXTURES`, sinon `Tests/Fixtures/paths.json`.
    static var t6Path: String? {
        let override = ProcessInfo.processInfo.environment[t6EnvironmentKey]
        if let override, !override.isEmpty { return override }
        return t6PathFromFixtureFile()
    }

    static var t6URL: URL? {
        guard let path = t6Path,
              FileManager.default.isReadableFile(atPath: path) else { return nil }
        return URL(fileURLWithPath: path)
    }
}

extension XCTestCase {
    /// Saute le test si la fixture réelle est absente (CI, poste sans le corpus).
    /// Le motif ne cite JAMAIS le chemin : il partirait dans les journaux.
    func requireT6() throws -> URL {
        guard let url = OCRTestSupport.t6URL else {
            throw XCTSkip("fixture T6 illisible sur cette machine — la désigner "
                          + "par \(OCRTestSupport.t6EnvironmentKey)=<chemin du PDF> "
                          + "ou par la clé « fixtures.T6.path » de "
                          + "Tests/Fixtures/paths.json (gitignoré)")
        }
        return url
    }
}
