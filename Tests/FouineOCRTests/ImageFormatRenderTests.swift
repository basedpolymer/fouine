// ImageFormatRenderTests.swift — rendu des formats ajoutés par INT-F2.
// SPDX-License-Identifier: LicenseRef-Fouine-Source-Available
// Propriété : A-OCR.
//
// Ce que ces tests protègent : la file d'OCR et le moteur de rendu partagent
// UNE seule liste d'extensions (`ImageExtractor.supportedExtensions`). Une
// extension ajoutée à l'extracteur sans que le rendu suive mettrait en file des
// pages que personne ne saurait produire — elles échoueraient une à une, avec
// `attempts + 1`, sans que rien ne le dise.

import XCTest
import CoreGraphics
import ImageIO
import UniformTypeIdentifiers
import FouineCore
import FouineExtract
@testable import FouineOCR

final class ImageFormatRenderTests: XCTestCase {

    private let renderer = FouinePageRenderer()

    /// Le moteur de rendu couvre EXACTEMENT les extensions de l'extracteur
    /// d'images : pas une de plus, pas une de moins.
    func testRendererCoversEveryImageExtension() throws {
        let directory = try TempDirectory()
        for ext in ImageExtractor.supportedExtensions {
            let url = directory.file("absent.\(ext)")
            // Le fichier n'existe pas : l'erreur attendue est une erreur de
            // LECTURE, jamais `.unsupported` — c'est ce dernier cas qui
            // signalerait une extension inconnue du rendu.
            XCTAssertThrowsError(try renderer.render(url: url, page: 1, dpi: 150)) {
                error in
                if case FouineError.unsupported = error {
                    XCTFail("« \(ext) » n'est pas rendue par FouinePageRenderer")
                }
            }
        }
    }

    /// Un WebP — qu'ImageIO décode mais n'encode pas : la fixture est un VP8L
    /// sans perte écrit à la main, une trentaine d'octets.
    func testWebPRendersToGray() throws {
        let directory = try TempDirectory()
        let url = directory.file("photo.webp")
        try Self.losslessWebP(width: 600, height: 400).write(to: url)

        let image = try renderer.render(url: url, page: 1, dpi: 150)
        XCTAssertEqual(image.width, 600)
        XCTAssertEqual(image.height, 400)
        XCTAssertEqual(image.bitsPerComponent, 8)
        XCTAssertEqual(image.colorSpace?.model, .monochrome)
    }

    /// Un PSD : ImageIO l'écrit ET le lit, donc la fixture est un vrai
    /// Photoshop, pas un fichier renommé.
    func testPSDRendersToGray() throws {
        let directory = try TempDirectory()
        let url = directory.file("calque.psd")
        try XCTSkipUnless(Self.write(width: 520, height: 380, to: url),
                          "ImageIO n'encode pas le PSD sur cette machine")

        let image = try renderer.render(url: url, page: 1, dpi: 150)
        XCTAssertEqual(image.width, 520)
        XCTAssertEqual(image.height, 380)
        XCTAssertEqual(image.colorSpace?.model, .monochrome)
    }

    /// Un GIF animé se rend sur sa PREMIÈRE image, et la page 2 n'existe pas.
    func testAnimatedGIFRendersItsFirstFrameOnly() throws {
        let directory = try TempDirectory()
        let url = directory.file("anime.gif")
        try XCTSkipUnless(Self.write(width: 420, height: 320, to: url, frames: 2),
                          "ImageIO n'encode pas le GIF sur cette machine")

        let image = try renderer.render(url: url, page: 1, dpi: 150)
        XCTAssertEqual(image.width, 420)
        XCTAssertThrowsError(try renderer.render(url: url, page: 2, dpi: 150))
    }

    // MARK: - Maquettes

    func testFigThumbnailIsWhatGetsRendered() throws {
        let directory = try TempDirectory()
        let url = directory.file("maquette.fig")
        let thumbnail = directory.file("thumbnail.png")
        try XCTSkipUnless(Self.write(width: 640, height: 480, to: thumbnail),
                          "ImageIO n'encode pas le PNG ?!")
        try Self.zip([("thumbnail.png", try Data(contentsOf: thumbnail)),
                      ("canvas.fig", Data(repeating: 0, count: 64))],
                     at: url, from: directory)

        let image = try renderer.render(url: url, page: 1, dpi: 150)
        XCTAssertEqual(image.width, 640)
        XCTAssertEqual(image.height, 480)
    }

    func testSketchPreviewIsWhatGetsRendered() throws {
        let directory = try TempDirectory()
        let url = directory.file("maquette.sketch")
        let preview = directory.file("preview.png")
        try XCTSkipUnless(Self.write(width: 320, height: 240, to: preview),
                          "ImageIO n'encode pas le PNG ?!")
        try Self.zip([("previews/preview.png", try Data(contentsOf: preview)),
                      ("document.json", Data("{}".utf8))],
                     at: url, from: directory)

        let image = try renderer.render(url: url, page: 1, dpi: 150)
        XCTAssertEqual(image.width, 320)
        XCTAssertEqual(image.height, 240)
    }

    // MARK: - Fabrication des fixtures

    /// Une image grise, éventuellement animée, écrite au format déduit de
    /// l'extension. Faux si ImageIO ne sait pas l'écrire ici.
    static func write(width: Int, height: Int, to url: URL,
                      frames: Int = 1) -> Bool {
        let ext = url.pathExtension.lowercased()
        guard let type = UTType.types(tag: ext, tagClass: .filenameExtension,
                                      conformingTo: nil).first(where: {
            (CGImageDestinationCopyTypeIdentifiers() as? [String] ?? [])
                .contains($0.identifier)
        }) else { return false }
        guard let context = CGContext(
            data: nil, width: width, height: height, bitsPerComponent: 8,
            bytesPerRow: width, space: CGColorSpaceCreateDeviceGray(),
            bitmapInfo: CGImageAlphaInfo.none.rawValue) else { return false }
        context.setFillColor(gray: 0.6, alpha: 1)
        context.fill(CGRect(x: 0, y: 0, width: width, height: height))
        guard let image = context.makeImage(),
              let destination = CGImageDestinationCreateWithURL(
                url as CFURL, type.identifier as CFString, frames, nil)
        else { return false }
        for _ in 0..<frames { CGImageDestinationAddImage(destination, image, nil) }
        return CGImageDestinationFinalize(destination)
    }

    /// Un WebP VP8L d'une seule couleur — même brique que
    /// `Tests/FouineExtractTests/ImageFixtureBuilder.swift`, recopiée parce que
    /// deux cibles de test ne partagent pas de code et que `Package.swift` est
    /// gelé.
    static func losslessWebP(width: Int, height: Int) -> Data {
        var bytes: [UInt8] = []
        var current: UInt8 = 0
        var used = 0
        func put(_ value: Int, _ count: Int) {
            for index in 0..<count {
                current |= UInt8((value >> index) & 1) << UInt8(used)
                used += 1
                if used == 8 { bytes.append(current); current = 0; used = 0 }
            }
        }
        put(width - 1, 14)
        put(height - 1, 14)
        put(0, 1)                       // alpha_is_used
        put(0, 3)                       // version
        put(0, 1)                       // aucune transformation
        put(0, 1)                       // pas de cache de couleurs
        put(0, 1)                       // pas de méta-Huffman
        for symbol in [200, 200, 200, 255, 0] {
            put(1, 1); put(0, 1); put(1, 1); put(symbol, 8)
        }
        if used > 0 { bytes.append(current) }

        var chunk = Data([0x2F])
        chunk.append(contentsOf: bytes)
        if chunk.count % 2 == 1 { chunk.append(0) }
        var out = Data("RIFF".utf8)
        var size = UInt32(4 + 8 + chunk.count).littleEndian
        out.append(Data(bytes: &size, count: 4))
        out.append(Data("WEBP".utf8))
        out.append(Data("VP8L".utf8))
        var chunkSize = UInt32(chunk.count).littleEndian
        out.append(Data(bytes: &chunkSize, count: 4))
        out.append(chunk)
        return out
    }

    /// Un ZIP aux noms d'entrée exacts, par /usr/bin/zip.
    static func zip(_ entries: [(name: String, data: Data)], at destination: URL,
                    from directory: TempDirectory) throws {
        let staging = directory.file("staging-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: staging,
                                                withIntermediateDirectories: true)
        for entry in entries {
            let file = staging.appendingPathComponent(entry.name)
            try FileManager.default.createDirectory(
                at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
            try entry.data.write(to: file)
        }
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/zip")
        process.arguments = ["-q", "-X", destination.path, "--"]
            + entries.map(\.name)
        process.currentDirectoryURL = staging
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        try process.run()
        process.waitUntilExit()
        guard process.terminationStatus == 0 else {
            throw FouineError.extraction("zip a échoué")
        }
    }
}
