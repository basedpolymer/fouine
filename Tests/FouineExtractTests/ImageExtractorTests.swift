// ImageExtractorTests.swift — tests de l'extracteur d'images seules (SPEC §5.3, audit E4, D2 § 5.12).
// SPDX-License-Identifier: LicenseRef-Fouine-Source-Available
// Propriété : A-Ingest.

import XCTest
import CoreGraphics
import CoreText
import ImageIO
import UniformTypeIdentifiers
import FouineCore
@testable import FouineExtract
@testable import FouineOCR
@testable import FouineCrawl

final class ImageExtractorTests: XCTestCase {

    private var tempDir: URL!

    override func setUpWithError() throws {
        tempDir = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("fouine-img-test-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        if let tempDir {
            try? FileManager.default.removeItem(at: tempDir)
        }
    }

    // MARK: - Générateur d'images de test

    private func makePNG(width: Int, height: Int, randomNoise: Bool,
                         text: String? = nil, to url: URL) throws {
        var raw = [UInt8](repeating: 255, count: width * height)
        if randomNoise {
            arc4random_buf(&raw, raw.count)
        }
        let space = CGColorSpaceCreateDeviceGray()
        guard let provider = CGDataProvider(data: Data(raw) as CFData),
              let image = CGImage(width: width, height: height,
                                  bitsPerComponent: 8, bitsPerPixel: 8,
                                  bytesPerRow: width, space: space,
                                  bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.none.rawValue),
                                  provider: provider, decode: nil,
                                  shouldInterpolate: false, intent: .defaultIntent)
        else { throw FouineError.extraction("cannot create CGImage") }

        guard let context = CGContext(data: nil, width: width, height: height,
                                      bitsPerComponent: 8, bytesPerRow: width,
                                      space: space,
                                      bitmapInfo: CGImageAlphaInfo.none.rawValue)
        else { throw FouineError.extraction("cannot create CGContext") }

        context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))

        if let text {
            context.setFillColor(gray: 1, alpha: 1)
            context.fill(CGRect(x: 30, y: height / 2 - 40, width: width - 60, height: 80))
            context.setFillColor(gray: 0, alpha: 1)
            let font = CTFontCreateWithName("Helvetica" as CFString, 36, nil)
            let attr = NSAttributedString(string: text, attributes: [
                kCTFontAttributeName as NSAttributedString.Key: font,
                kCTForegroundColorAttributeName as NSAttributedString.Key: CGColor(gray: 0, alpha: 1)
            ])
            let line = CTLineCreateWithAttributedString(attr)
            context.textPosition = CGPoint(x: 40, y: height / 2 - 15)
            CTLineDraw(line, context)
        }

        guard let finalImage = context.makeImage() else {
            throw FouineError.extraction("cannot render final image")
        }

        let data = NSMutableData()
        guard let dest = CGImageDestinationCreateWithData(
            data as CFMutableData, UTType.png.identifier as CFString, 1, nil)
        else { throw FouineError.extraction("cannot create destination") }
        CGImageDestinationAddImage(dest, finalImage, nil)
        CGImageDestinationFinalize(dest)
        try (data as Data).write(to: url)
    }

    // MARK: - Extensions et Registre

    func testImageExtractorSupportedExtensions() {
        // Élargi le 08/09/2026 (lot INT-F2) : formats modernes, anciens, PSD et
        // RAW d'appareil photo. Le littéral est LE contrat — une extension
        // ajoutée à l'extracteur sans être ajoutée ici casse ce test, et c'est
        // voulu : le rendu OCR et l'aperçu de l'app se câblent sur cet ensemble.
        let expected: Set<String> = [
            "png", "jpg", "jpeg", "heic", "heif", "tif", "tiff",
            "avif", "webp", "gif", "bmp", "psd",
            "cr2", "nef", "raf", "dng", "arw", "rw2", "orf",
        ]
        XCTAssertEqual(ImageExtractor.supportedExtensions, expected)
        XCTAssertEqual(DefaultExtractorRegistry.imageExtensions, expected)
        // Les images restent HORS du registre par défaut : c'est le réglage
        // `extract.images` qui les y met.
        XCTAssertTrue(DefaultExtractorRegistry.supportedExtensions
            .isDisjoint(with: expected))
    }

    /// Chaque extension déclarée est décodable par ImageIO SUR CETTE MACHINE.
    /// Le test ne l'exige pas — macOS 13, la cible minimale, en connaît moins —
    /// mais il NOMME celles qui manqueraient : un format non décodable ici
    /// produira le refus « unreadable image » chez l'utilisateur, et il vaut
    /// mieux le savoir en lisant un journal de test qu'en lisant `docs.err`.
    func testDeclaredImageTypesAreDecodableOnThisMachine() {
        var missing: [String] = []
        for ext in ImageExtractor.supportedExtensions.sorted()
        where !ImageFixture.isDecodable(ext) {
            missing.append(ext)
        }
        if !missing.isEmpty {
            print("INT-F2 : types non décodables sur cette machine : "
                  + missing.joined(separator: ", "))
        }
        // Les six formats d'avant INT-F2 et le webp sont exigés : ils sont
        // présents depuis macOS 11.
        for ext in ["png", "jpg", "jpeg", "heic", "tif", "tiff", "webp"] {
            XCTAssertTrue(ImageFixture.isDecodable(ext), ext)
        }
    }

    /// Le registre n'inscrit les nouvelles extensions QUE sous `extract.images`.
    func testNewImageExtensionsAreRegisteredOnlyUnderTheSetting() {
        let off = DefaultExtractorRegistry(extractImages: false)
        let on = DefaultExtractorRegistry(extractImages: true)
        for ext in ["webp", "avif", "gif", "bmp", "psd", "dng", "cr2", "heif"] {
            XCTAssertNil(off.extractor(for: ext), ext)
            XCTAssertNotNil(on.extractor(for: ext), ext)
            XCTAssertNotNil(on.extractor(for: ext.uppercased()), ext)
        }
    }

    // MARK: - Les formats ajoutés par INT-F2

    /// Chaque format qu'ImageIO sait ÉCRIRE ici est extrait comme une image :
    /// 0 texte natif, 1 page, la page en file d'OCR. Ceux qu'il ne sait pas
    /// écrire (avif, RAW) se sautent en le disant — c'est le seul cas où ce
    /// test ne prouve rien, et il le dit plutôt que de passer en silence.
    func testEveryEncodableImageFormatIsExtractedAsOnePage() throws {
        var covered: [String] = []
        var skipped: [String] = []
        for ext in ["heic", "gif", "bmp", "psd", "tiff", "webp"] {
            let url = tempDir.appendingPathComponent("image.\(ext)")
            if ext == "webp" {
                // Rembourré au-delà du plancher : un WebP sans perte d'une
                // seule couleur pèse trente octets.
                try ImageFixture.webp(width: 500, height: 400,
                                      padTo: 70_000).write(to: url)
            } else if try ImageFixture.write(width: 500, height: 400,
                                             to: url) == nil {
                skipped.append(ext)
                continue
            }
            let size = try FileManager.default
                .attributesOfItem(atPath: url.path)[.size] as? Int64 ?? 0
            XCTAssertGreaterThanOrEqual(size, 64 * 1024,
                                        "\(ext) : \(size) o, sous le plancher")

            let result = try ImageExtractor().extract(url: url,
                                                      limits: ExtractLimits())
            XCTAssertTrue(result.pages.isEmpty, ext)
            XCTAssertEqual(result.pageCount, 1, ext)
            XCTAssertEqual(result.ocrCandidates, [1], ext)
            covered.append(ext)
        }
        if !skipped.isEmpty {
            print("INT-F2 : formats non encodables ici, non couverts : "
                  + skipped.joined(separator: ", "))
        }
        XCTAssertTrue(covered.contains("webp"),
                      "le webp se fabrique sans encodeur : il doit être couvert")
        XCTAssertGreaterThanOrEqual(covered.count, 4,
                                    "couverts : \(covered)")
    }

    /// Un GIF ANIMÉ vaut UNE page — celle de sa première image — et non une par
    /// vignette : sans cela, une bannière de vingt images entrerait vingt fois
    /// en file d'OCR pour le même contenu.
    func testAnimatedGIFIsOnePage() throws {
        let url = tempDir.appendingPathComponent("anime.gif")
        try XCTSkipUnless(ImageFixture.writeAnimatedGIF(width: 500, height: 400,
                                                        text: "anemometre",
                                                        to: url),
                          "ImageIO n'encode pas le GIF sur cette machine")
        let source = try XCTUnwrap(CGImageSourceCreateWithURL(url as CFURL, nil))
        XCTAssertEqual(CGImageSourceGetCount(source), 2,
                       "la fixture doit bien porter deux images")

        let result = try ImageExtractor().extract(url: url, limits: ExtractLimits())
        XCTAssertEqual(result.pageCount, 1)
        XCTAssertEqual(result.ocrCandidates, [1])
    }

    /// Un fichier dont l'extension est inscrite mais dont le contenu n'est pas
    /// une image : refus NOMMÉ, et non un plantage ni un « format non pris en
    /// charge » qui ferait croire à une extension oubliée.
    func testUndecodableImageIsRefusedByName() throws {
        let url = tempDir.appendingPathComponent("faux.avif")
        try Data(repeating: 0x41, count: 80 * 1024).write(to: url)

        XCTAssertThrowsError(try ImageExtractor().extract(
            url: url, limits: ExtractLimits())) { error in
            guard case FouineError.extraction(let message) = error else {
                return XCTFail("attendu .extraction, obtenu \(error)")
            }
            XCTAssertTrue(message.hasPrefix("unreadable image"), message)
        }
    }

    // MARK: - Extraction nominale

    func testValidPNGExtractionEnqueuesForOCR() throws {
        let url = tempDir.appendingPathComponent("valide.png")
        try makePNG(width: 500, height: 500, randomNoise: true, text: "anemometre", to: url)

        let fileSize = try FileManager.default.attributesOfItem(atPath: url.path)[.size] as? Int64 ?? 0
        XCTAssertGreaterThanOrEqual(fileSize, 64 * 1024, "le fichier doit depasser le plancher de 64 Kio")

        let extractor = ImageExtractor()
        let result = try extractor.extract(url: url, limits: ExtractLimits())

        // 0 caractere de texte natif, 1 page, candidate OCR
        XCTAssertTrue(result.pages.isEmpty, "aucun texte natif produit")
        XCTAssertEqual(result.pageCount, 1)
        XCTAssertEqual(result.ocrCandidates, [1])
    }

    // MARK: - Garde-fous : deux planchers, deux motifs (constat C2-02)

    /// LE CAS DE L'AUDIT. Une page A4 de 945 × 1418 px portant 2 291 caractères
    /// lisibles, encodée en AVIF, pèse 53 814 octets : le plancher de 64 Kio la
    /// refusait — et l'app annonçait « Image trop petite ». Un plancher
    /// d'octets n'est pas une quantité d'information. Ici la même situation
    /// avec un PNG bien compressé, qu'ImageIO sait écrire partout.
    func testAWellCompressedPageIsRead() throws {
        let url = tempDir.appendingPathComponent("page-a4.png")
        try makePNG(width: 1_000, height: 1_400, randomNoise: false,
                    text: "anemometre", to: url)
        // Une page A4 blanche compresse à quelques kilo-octets, et le poids
        // exact dépend de l'encodeur : on le CALE à 20 Kio par du remplissage
        // après IEND, que tout décodeur ignore (même procédé que le webp de
        // `ImageFixture`). Sans cela, ce test affirmerait un poids qu'il ne
        // maîtrise pas.
        var bytes = try Data(contentsOf: url)
        if bytes.count < 20_000 {
            bytes.append(Data(repeating: 0x20, count: 20_000 - bytes.count))
            try bytes.write(to: url)
        }

        let size = try FileManager.default
            .attributesOfItem(atPath: url.path)[.size] as? Int64 ?? 0
        XCTAssertLessThan(size, 64 * 1024,
                          "la fixture doit passer SOUS l'ancien plancher : \(size) o")
        XCTAssertGreaterThanOrEqual(size, ImageExtractor.minFileBytes)

        let result = try ImageExtractor().extract(url: url, limits: ExtractLimits())
        XCTAssertEqual(result.pageCount, 1)
        XCTAssertEqual(result.ocrCandidates, [1])
    }

    func testFileBelowWeightFloorIsSkippedWithItsOwnReason() throws {
        let url = tempDir.appendingPathComponent("vignette.png")
        try Data(repeating: 0x89, count: 2 * 1024).write(to: url)

        XCTAssertThrowsError(try ImageExtractor().extract(
            url: url, limits: ExtractLimits())) { error in
            guard case FouineError.extraction(let message) = error else {
                return XCTFail("attendu .extraction, obtenu \(error)")
            }
            XCTAssertEqual(message,
                           "\(ImageExtractor.belowWeightFloorReason): 2048 bytes")
            XCTAssertTrue(ImageExtractor.isBelowFloor(message),
                          "ce refus doit rester un SAUT, pas un échec")
        }
    }

    func testDimensionsBelowFloorSayTheDimensions() throws {
        let url = tempDir.appendingPathComponent("petites-dimensions.png")
        // 100 × 100 (< 300 px), bruitée pour franchir le plancher de poids.
        try makePNG(width: 100, height: 100, randomNoise: true, to: url)
        let size = try FileManager.default
            .attributesOfItem(atPath: url.path)[.size] as? Int64 ?? 0
        XCTAssertGreaterThanOrEqual(size, ImageExtractor.minFileBytes,
                                    "la fixture doit passer le plancher de poids")

        XCTAssertThrowsError(try ImageExtractor().extract(
            url: url, limits: ExtractLimits())) { error in
            guard case FouineError.extraction(let message) = error else {
                return XCTFail("attendu .extraction, obtenu \(error)")
            }
            XCTAssertEqual(message,
                           "\(ImageExtractor.belowFloorReason): 100x100 px",
                           "le motif dit ce qui est VRAI : les dimensions")
            XCTAssertTrue(ImageExtractor.isBelowFloor(message))
        }
    }

    // MARK: - Un TIFF vaut ses pages (constat C2-03)

    /// Le TIFF multi-pages est la sortie normale d'un scanner de bureau.
    /// `pageCount: 1` en faisait disparaître deux tiers, sans erreur et sans
    /// trace — Fouine n'indexe pas les noms de fichiers.
    func testMultiPageTIFFIsWorthItsPages() throws {
        let url = tempDir.appendingPathComponent("scan-3-pages.tiff")
        try XCTSkipUnless(try writeMultiPageTIFF(to: url),
                          "ImageIO n'encode pas le TIFF sur cette machine")
        let source = try XCTUnwrap(CGImageSourceCreateWithURL(url as CFURL, nil))
        XCTAssertEqual(CGImageSourceGetCount(source), 3,
                       "la fixture doit bien porter trois images")

        let result = try ImageExtractor().extract(url: url, limits: ExtractLimits())
        XCTAssertEqual(result.pageCount, 3)
        XCTAssertEqual(result.ocrCandidates, [1, 2, 3])
        XCTAssertTrue(result.pages.isEmpty, "aucun texte natif dans une image")

        // Et le rendu suit : la page 3 n'est pas la page 1.
        let renderer = FouinePageRenderer()
        let first = try renderer.render(url: url, page: 1, dpi: 150)
        let third = try renderer.render(url: url, page: 3, dpi: 150)
        XCTAssertNotEqual(Self.raster(of: first), Self.raster(of: third),
                          "la page 3 rendue est encore la première image")
        XCTAssertThrowsError(try renderer.render(url: url, page: 4, dpi: 150))
    }

    /// Les autres formats restent à UNE page : un GIF animé est un mouvement,
    /// pas un document de vingt pages (décision INT-F2, inchangée).
    func testOtherImageFormatsStayAtOnePage() throws {
        let url = tempDir.appendingPathComponent("anime.gif")
        try XCTSkipUnless(ImageFixture.writeAnimatedGIF(width: 500, height: 400,
                                                        text: "anemometre",
                                                        to: url),
                          "ImageIO n'encode pas le GIF sur cette machine")
        let result = try ImageExtractor().extract(url: url, limits: ExtractLimits())
        XCTAssertEqual(result.pageCount, 1)
        XCTAssertThrowsError(try FouinePageRenderer()
            .render(url: url, page: 2, dpi: 150))
    }

    /// Trois images DIFFÉRENTES dans un seul TIFF. `nil` si ImageIO ne sait pas
    /// écrire le TIFF ici — au test de se sauter en le disant.
    private func writeMultiPageTIFF(to url: URL) throws -> Bool {
        guard let type = ImageFixture.encodableType(for: "tiff"),
              let destination = CGImageDestinationCreateWithURL(
                url as CFURL, type as CFString, 3, nil) else { return false }
        for word in ["anemometre", "barometre", "thermometre"] {
            guard let image = ImageFixture.grayImage(width: 600, height: 800,
                                                     noise: true, text: word)
            else { return false }
            CGImageDestinationAddImage(destination, image, nil)
        }
        return CGImageDestinationFinalize(destination)
    }

    /// Les octets d'une image rendue, pour comparer deux pages.
    private static func raster(of image: CGImage) -> Data {
        guard let data = image.dataProvider?.data else { return Data() }
        return Data(referencing: data as NSData)
    }

    // MARK: - Réglage extract.images

    func testSettingExtractImagesBehavior() {
        // Allumé par défaut depuis la 1.0.1 (DF1)
        let def = SettingsSnapshot(rows: [:], environment: [:])
        XCTAssertTrue(def.extractImages)

        // Éteint via snapshot
        let disabled = SettingsSnapshot(rows: [SettingKeys.extractImages.key: "false"])
        XCTAssertFalse(disabled.extractImages)

        // Valeurs invalides retombent sur false
        let invalid = SettingsSnapshot(rows: [SettingKeys.extractImages.key: "non"])
        XCTAssertFalse(invalid.extractImages)
    }

    // MARK: - Rendu et OCR réel

    func testRealOCRRecognizesTextOnStandaloneImage() throws {
        try XCTSkipIf(VisionOCREngine.supportedLanguages().isEmpty,
                      "Vision indisponible sur cette machine")

        let url = tempDir.appendingPathComponent("ocr-test.png")
        try makePNG(width: 600, height: 600, randomNoise: true, text: "anemometre", to: url)

        // 1. Rendu
        let renderer = FouinePageRenderer()
        let image = try renderer.render(url: url, page: 1, dpi: 150)
        XCTAssertEqual(image.bitsPerComponent, 8)
        XCTAssertEqual(image.colorSpace?.model, .monochrome)

        // 2. OCR via Vision
        let engine = VisionOCREngine()
        let recognized = try engine.recognize(image, level: .accurate,
                                              languages: ["fr-FR", "en-US"],
                                              customWords: [])
        let fullText = recognized.lines.map(\.text).joined(separator: " ")
        XCTAssertTrue(fullText.lowercased().contains("anemometre"),
                      "le texte reconnu doit contenir le terme temoin « anemometre » : \(fullText)")
    }
}
