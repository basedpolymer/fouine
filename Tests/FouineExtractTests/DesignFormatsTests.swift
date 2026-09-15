// DesignFormatsTests.swift — Illustrator, Sketch, Figma, InDesign (lot INT-F2).
// SPDX-License-Identifier: LicenseRef-Fouine-Source-Available
// Propriété : A-Ingest.

import XCTest
import CoreGraphics
import FouineCore
import FouineCrawl
@testable import FouineExtract

final class IllustratorTests: XCTestCase {

    var directory: URL!

    override func setUpWithError() throws {
        directory = try Fixtures.temporaryDirectory("ai")
    }
    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: directory)
    }

    /// Le cas courant : un `.ai` est un PDF, et son texte se lit comme celui
    /// d'un PDF.
    func testIllustratorWithAPDFLayerIsReadAsAPDF() throws {
        let url = directory.appendingPathComponent("dessin.ai")
        try Fixtures.makePDF(
            pages: [["Plan de travail 1 chromatographie"]
                + Fixtures.filler(marker: "AI")], at: url)

        let result = try IllustratorExtractor().extract(url: url,
                                                        limits: ExtractLimits())
        XCTAssertEqual(result.pageCount, 1)
        XCTAssertTrue(result.pages.first?.text.contains("chromatographie") ?? false,
                      result.pages.first?.text ?? "aucune page")
    }

    /// Un `.ai` sauvegardé en compatibilité PostScript : « %!PS-Adobe » d'abord,
    /// « %PDF- » ensuite. PDFKit refuse le fichier tel quel — c'est la partie
    /// PDF qu'on lui donne.
    func testIllustratorWithAPostScriptPreambleIsStillRead() throws {
        let pdf = directory.appendingPathComponent("interne.pdf")
        try Fixtures.makePDF(
            pages: [["Calque enthalpie de sublimation"]
                + Fixtures.filler(marker: "PS")], at: pdf)
        let url = directory.appendingPathComponent("ancien.ai")
        var data = Data("%!PS-Adobe-3.0\n%%Creator: Adobe Illustrator\n".utf8)
        data.append(try Data(contentsOf: pdf))
        try data.write(to: url)

        XCTAssertNotNil(IllustratorExtractor.pdfOffset(in: data.prefix(1_024)))
        XCTAssertNotEqual(IllustratorExtractor.pdfOffset(in: data.prefix(1_024)), 0)

        let result = try IllustratorExtractor().extract(url: url,
                                                        limits: ExtractLimits())
        XCTAssertEqual(result.pageCount, 1)
        XCTAssertTrue(result.pages.first?.text.contains("enthalpie") ?? false,
                      result.pages.first?.text ?? "aucune page")
    }

    /// Sans couche PDF : refus NOMMÉ, classé `.skipped` — le fichier n'est pas
    /// cassé, il n'y a rien à lire.
    func testIllustratorWithoutAPDFLayerIsSkippedByName() throws {
        let url = directory.appendingPathComponent("vieux.ai")
        var data = Data("%!PS-Adobe-2.0 EPSF-1.2\n%%BoundingBox: 0 0 100 100\n".utf8)
        data.append(Data(repeating: 0x20, count: 4_096))
        try data.write(to: url)

        XCTAssertThrowsError(try IllustratorExtractor().extract(
            url: url, limits: ExtractLimits())) { error in
            guard case FouineError.extraction(let message) = error else {
                return XCTFail("attendu .extraction, obtenu \(error)")
            }
            XCTAssertEqual(message, IllustratorExtractor.noPDFLayerReason)
            XCTAssertEqual(ExtractOutcome.skipReason(for: .extraction(message)),
                           message, "ce refus doit se classer .skipped")
        }
    }
}

final class SketchTests: XCTestCase {

    var directory: URL!

    override func setUpWithError() throws {
        directory = try Fixtures.temporaryDirectory("sketch")
    }
    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: directory)
    }

    /// Un document Sketch de deux pages, avec planches et calques texte.
    static func makeSketch(at url: URL, withPreview: Bool = false) throws {
        let document = """
        {"_class":"document","do_objectID":"D1","name":"Maquette",
         "pages":[{"_class":"MSJSONFileReference","_ref":"pages/A"},
                  {"_class":"MSJSONFileReference","_ref":"pages/B"}]}
        """
        let pageA = """
        {"_class":"page","do_objectID":"A","name":"Accueil","layers":[
          {"_class":"artboard","name":"Ecran de connexion","layers":[
            {"_class":"text","name":"titre",
             "attributedString":{"_class":"attributedString",
                                 "string":"Bienvenue sur Fouine"}},
            {"_class":"group","layers":[
              {"_class":"text","name":"sous-titre",
               "attributedString":{"_class":"attributedString",
                                   "string":"chromatographie sur colonne"}}]}]}]}
        """
        let pageB = """
        {"_class":"page","do_objectID":"B","name":"Reglages","layers":[
          {"_class":"symbolMaster","name":"Bouton principal","layers":[
            {"_class":"text","name":"etiquette",
             "attributedString":{"_class":"attributedString",
                                 "string":"Enregistrer les preferences"}}]}]}
        """
        var entries: [(name: String, data: Data)] = [
            ("document.json", Data(document.utf8)),
            ("pages/A.json", Data(pageA.utf8)),
            ("pages/B.json", Data(pageB.utf8)),
            ("meta.json", Data(#"{"app":"com.bohemiancoding.sketch3"}"#.utf8)),
        ]
        if withPreview {
            entries.append(("previews/preview.png",
                            ImageFixture.pngData(width: 320, height: 240)))
        }
        try Fixtures.makeArchive(entries, at: url)
    }

    /// Une page Sketch = une page Fouine, dans l'ordre de document.json, et le
    /// texte porte le nom de la page, celui des planches, puis les calques.
    func testSketchPagesAreExtractedInDocumentOrder() throws {
        let url = directory.appendingPathComponent("maquette.sketch")
        try Self.makeSketch(at: url)

        let result = try SketchExtractor().extract(url: url, limits: ExtractLimits())
        XCTAssertEqual(result.pageCount, 2)
        XCTAssertEqual(result.ocrCandidates, [], "sans aperçu : rien à OCRiser")
        XCTAssertEqual(result.meta["title"], "Maquette")

        let first = try XCTUnwrap(result.pages.first { $0.page == 1 }).text
        let second = try XCTUnwrap(result.pages.first { $0.page == 2 }).text
        XCTAssertEqual(first, """
        Accueil
        Ecran de connexion
        Bienvenue sur Fouine
        chromatographie sur colonne
        """)
        XCTAssertTrue(second.contains("Bouton principal"), second)
        XCTAssertTrue(second.contains("Enregistrer les preferences"), second)
        // Le texte de la page 2 ne doit PAS déborder sur la page 1.
        XCTAssertFalse(first.contains("Enregistrer"), first)
    }

    /// L'aperçu ne devient une page à OCRiser que sous `extract.images`, et
    /// c'est la DERNIÈRE page — comme les médias OOXML.
    func testSketchPreviewIsQueuedOnlyUnderTheImageSetting() throws {
        let url = directory.appendingPathComponent("avec-apercu.sketch")
        try Self.makeSketch(at: url, withPreview: true)

        let off = try SketchExtractor(extractImages: false)
            .extract(url: url, limits: ExtractLimits())
        XCTAssertEqual(off.pageCount, 2)
        XCTAssertEqual(off.ocrCandidates, [])

        let on = try SketchExtractor(extractImages: true)
            .extract(url: url, limits: ExtractLimits())
        XCTAssertEqual(on.pageCount, 3)
        XCTAssertEqual(on.ocrCandidates, [3])
    }

    /// Un ZIP qui n'est pas un Sketch : refus NOMMÉ, classé `.skipped`.
    func testArchiveWithoutDocumentJSONIsSkippedByName() throws {
        let url = directory.appendingPathComponent("faux.sketch")
        try Fixtures.makeArchive([("lisezmoi.txt", Data("rien".utf8))], at: url)

        XCTAssertThrowsError(try SketchExtractor().extract(
            url: url, limits: ExtractLimits())) { error in
            guard case FouineError.extraction(let message) = error else {
                return XCTFail("attendu .extraction, obtenu \(error)")
            }
            XCTAssertEqual(message, SketchExtractor.noDocumentReason)
            XCTAssertEqual(ExtractOutcome.skipReason(for: .extraction(message)),
                           message)
        }
    }
}

final class DesignPreviewTests: XCTestCase {

    var directory: URL!

    override func setUpWithError() throws {
        directory = try Fixtures.temporaryDirectory("design")
    }
    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: directory)
    }

    /// Une vignette PNG dans un `.fig` : une page à OCRiser, sous
    /// `extract.images` seulement.
    static func makeFig(at url: URL, withThumbnail: Bool) throws {
        var entries: [(name: String, data: Data)] = [
            ("meta.json", Data(#"{"client_meta":{}}"#.utf8)),
            ("canvas.fig", Data(repeating: 0x00, count: 512)),
        ]
        if withThumbnail {
            entries.append(("thumbnail.png",
                            ImageFixture.pngData(width: 640, height: 480)))
        }
        try Fixtures.makeArchive(entries, at: url)
    }

    func testFigWithAThumbnailIsOneOCRPageUnderTheSetting() throws {
        let url = directory.appendingPathComponent("maquette.fig")
        try Self.makeFig(at: url, withThumbnail: true)

        let on = try DesignPreviewExtractor(extractImages: true)
            .extract(url: url, limits: ExtractLimits())
        XCTAssertTrue(on.pages.isEmpty)
        XCTAssertEqual(on.pageCount, 1)
        XCTAssertEqual(on.ocrCandidates, [1])

        // Réglage éteint : rien à indexer, et un refus qui dit le geste.
        XCTAssertThrowsError(try DesignPreviewExtractor(extractImages: false)
            .extract(url: url, limits: ExtractLimits())) { error in
            guard case FouineError.extraction(let message) = error else {
                return XCTFail("attendu .extraction, obtenu \(error)")
            }
            XCTAssertEqual(message, DesignPreviewExtractor.figNoTextReason)
        }
    }

    func testFigWithoutAThumbnailIsSkippedByName() throws {
        let url = directory.appendingPathComponent("ancien.fig")
        try Self.makeFig(at: url, withThumbnail: false)

        XCTAssertThrowsError(try DesignPreviewExtractor(extractImages: true)
            .extract(url: url, limits: ExtractLimits())) { error in
            guard case FouineError.extraction(let message) = error else {
                return XCTFail("attendu .extraction, obtenu \(error)")
            }
            XCTAssertEqual(message, DesignPreviewExtractor.figNoTextReason)
            XCTAssertEqual(ExtractOutcome.skipReason(for: .extraction(message)),
                           message)
        }
    }

    /// Un `.fig` de l'ancien format (« fig-kiwi », pas un ZIP du tout) : même
    /// refus, et immédiat.
    func testLegacyFigIsSkippedByName() throws {
        let url = directory.appendingPathComponent("kiwi.fig")
        try Data("fig-kiwi\u{00}\u{01}".utf8).write(to: url)

        XCTAssertThrowsError(try DesignPreviewExtractor(extractImages: true)
            .extract(url: url, limits: ExtractLimits())) { error in
            guard case FouineError.extraction(let message) = error else {
                return XCTFail("attendu .extraction, obtenu \(error)")
            }
            XCTAssertEqual(message, DesignPreviewExtractor.figNoTextReason)
        }
    }

    /// Un `.indd` synthétique : en-tête InDesign, puis un PNG intégré.
    static func makeINDD(at url: URL, withPreview: Bool) throws {
        var data = Data("Adobe InDesign".utf8)
        data.append(Data(repeating: 0x00, count: 4_096))
        if withPreview {
            data.append(ImageFixture.pngData(width: 512, height: 384))
        }
        data.append(Data(repeating: 0x00, count: 1_024))
        try data.write(to: url)
    }

    func testINDDWithAnEmbeddedPreviewIsOneOCRPage() throws {
        let url = directory.appendingPathComponent("mise-en-page.indd")
        try Self.makeINDD(at: url, withPreview: true)

        let result = try DesignPreviewExtractor(extractImages: true)
            .extract(url: url, limits: ExtractLimits())
        XCTAssertEqual(result.pageCount, 1)
        XCTAssertEqual(result.ocrCandidates, [1])
    }

    func testINDDWithoutAPreviewIsSkippedByName() throws {
        let url = directory.appendingPathComponent("texte-seul.indd")
        try Self.makeINDD(at: url, withPreview: false)

        XCTAssertThrowsError(try DesignPreviewExtractor(extractImages: true)
            .extract(url: url, limits: ExtractLimits())) { error in
            guard case FouineError.extraction(let message) = error else {
                return XCTFail("attendu .extraction, obtenu \(error)")
            }
            XCTAssertEqual(message, DesignPreviewExtractor.inddNoTextReason)
            XCTAssertEqual(ExtractOutcome.skipReason(for: .extraction(message)),
                           message)
        }
    }

    /// Une signature JPEG qui tombe par hasard dans un flux binaire ne doit pas
    /// mettre une page en file d'OCR : c'est le DÉCODAGE qui tranche.
    func testRandomSignatureDoesNotCountAsAPreview() throws {
        let url = directory.appendingPathComponent("hasard.indd")
        var data = Data("Adobe InDesign".utf8)
        data.append(contentsOf: [0xFF, 0xD8, 0xFF])
        data.append(Data(repeating: 0x37, count: 8_192))
        try data.write(to: url)

        XCTAssertThrowsError(try DesignPreviewExtractor(extractImages: true)
            .extract(url: url, limits: ExtractLimits()))
    }
}

final class DesignRegistryTests: XCTestCase {

    /// Les quatre extensions sont dans le registre EN TOUTES CIRCONSTANCES —
    /// leur refus nommé vaut mieux que « format non pris en charge » — et le
    /// crawler en tient la copie.
    func testDesignExtensionsAreAlwaysRegistered() {
        let registry = DefaultExtractorRegistry(extractImages: false)
        for ext in ["ai", "sketch", "fig", "indd"] {
            XCTAssertNotNil(registry.extractor(for: ext), ext)
            XCTAssertTrue(DefaultExtractorRegistry.supportedExtensions.contains(ext),
                          ext)
            XCTAssertTrue(FouineCrawler.defaultIndexableExtensions.contains(ext),
                          ext)
        }
    }

    /// Chaque refus nommé du lot se classe `.skipped`, jamais `.failed` : la
    /// carte « documents illisibles » de l'app ne doit pas les y ranger.
    func testEveryNewRefusalIsClassifiedAsSkipped() {
        for reason in [IllustratorExtractor.noPDFLayerReason,
                       SketchExtractor.noDocumentReason,
                       DesignPreviewExtractor.figNoTextReason,
                       DesignPreviewExtractor.inddNoTextReason] {
            XCTAssertTrue(ExtractOutcome.skippedReasons.contains(reason), reason)
            XCTAssertEqual(ExtractOutcome.skipReason(for: .extraction(reason)),
                           reason)
        }
    }
}
