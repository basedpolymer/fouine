// ImageFixtureBuilder.swift — fabrique les images de test du lot INT-F2.
// SPDX-License-Identifier: LicenseRef-Fouine-Source-Available
// Propriété : A-Ingest.
//
// Deux voies, et la seconde existe parce que la première ne suffit pas :
//
//   · ImageIO ENCODE png, jpeg, tiff, gif, bmp, heic et psd — mesuré sur cette
//     machine par `CGImageDestinationCopyTypeIdentifiers()`. C'est
//     `RasterFixture` ;
//   · il n'encode NI webp NI avif (ils sont pourtant décodés). Un WebP sans
//     perte minimal se fabrique pourtant à la main en une trentaine d'octets :
//     `WebPFixture`. C'est ce qui permet de tester le webp partout, y compris
//     sur un runner sans le moindre fichier d'exemple. L'avif, lui, n'a pas
//     d'équivalent simple : les tests qui en auraient besoin se SAUTENT en
//     disant pourquoi.

import Foundation
import CoreGraphics
import CoreText
import ImageIO
import UniformTypeIdentifiers

enum ImageFixture {

    /// Types d'image qu'ImageIO sait ÉCRIRE ici.
    static let encodableTypes = Set(CGImageDestinationCopyTypeIdentifiers()
        as? [String] ?? [])

    /// Types d'image qu'ImageIO sait LIRE ici.
    static let decodableTypes = Set(CGImageSourceCopyTypeIdentifiers()
        as? [String] ?? [])

    /// Identifiants de type d'une extension, du plus au moins spécifique.
    static func typeIdentifiers(for ext: String) -> [String] {
        UTType.types(tag: ext, tagClass: .filenameExtension, conformingTo: nil)
            .map(\.identifier)
    }

    static func encodableType(for ext: String) -> String? {
        typeIdentifiers(for: ext).first { encodableTypes.contains($0) }
    }

    static func isDecodable(_ ext: String) -> Bool {
        typeIdentifiers(for: ext).contains { decodableTypes.contains($0) }
    }

    // MARK: - Images matricielles par ImageIO

    /// Une image en niveaux de gris, bruitée (pour ne pas passer sous le
    /// plancher de 64 Kio) et portant éventuellement un mot lisible à l'OCR.
    static func grayImage(width: Int, height: Int, noise: Bool,
                          text: String? = nil) -> CGImage? {
        let space = CGColorSpaceCreateDeviceGray()
        guard let context = CGContext(
            data: nil, width: width, height: height, bitsPerComponent: 8,
            bytesPerRow: width, space: space,
            bitmapInfo: CGImageAlphaInfo.none.rawValue) else { return nil }
        context.setFillColor(gray: 1, alpha: 1)
        context.fill(CGRect(x: 0, y: 0, width: width, height: height))
        if noise {
            // Bruit d'un générateur congruentiel, donc REPRODUCTIBLE : la
            // taille du fichier — et donc le plancher de 64 Kio que les tests
            // affirment — ne doit pas varier d'une exécution à l'autre.
            var raw = [UInt8](repeating: 0, count: width * height)
            var state: UInt64 = 0x2545_F491_4F6C_DD1D
            for index in 0..<raw.count {
                state = state &* 6_364_136_223_846_793_005 &+ 1_442_695_040_888_963_407
                raw[index] = UInt8((state >> 33) & 0xFF)
            }
            if let provider = CGDataProvider(data: Data(raw) as CFData),
               let noiseImage = CGImage(
                width: width, height: height, bitsPerComponent: 8, bitsPerPixel: 8,
                bytesPerRow: width, space: space,
                bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.none.rawValue),
                provider: provider, decode: nil, shouldInterpolate: false,
                intent: .defaultIntent) {
                context.draw(noiseImage,
                             in: CGRect(x: 0, y: 0, width: width, height: height))
            }
        }
        if let text {
            context.setFillColor(gray: 1, alpha: 1)
            context.fill(CGRect(x: 20, y: height / 2 - 40,
                                width: width - 40, height: 80))
            context.setFillColor(gray: 0, alpha: 1)
            let font = CTFontCreateWithName("Helvetica" as CFString, 36, nil)
            let attributed = NSAttributedString(string: text, attributes: [
                kCTFontAttributeName as NSAttributedString.Key: font,
                kCTForegroundColorAttributeName as NSAttributedString.Key:
                    CGColor(gray: 0, alpha: 1),
            ])
            context.textPosition = CGPoint(x: 30, y: height / 2 - 15)
            CTLineDraw(CTLineCreateWithAttributedString(attributed), context)
        }
        return context.makeImage()
    }

    /// Écrit une image de `width`×`height` dans `url`, au format déduit de son
    /// extension. Rend `nil` si ImageIO ne sait pas écrire ce format ici — au
    /// test de se sauter en le disant.
    @discardableResult
    static func write(width: Int, height: Int, noise: Bool = true,
                      text: String? = nil, to url: URL) throws -> String? {
        let ext = url.pathExtension.lowercased()
        if ext == "webp" {
            try webp(width: width, height: height).write(to: url)
            return "org.webmproject.webp"
        }
        guard let type = encodableType(for: ext),
              let image = grayImage(width: width, height: height,
                                    noise: noise, text: text)
        else { return nil }
        // Le HEIC refuse une image en NIVEAUX DE GRIS (`Finalize` rend false
        // sans rien dire) : on repasse en RVB pour lui. Mesuré ici, pas deviné.
        for candidate in [image, rgb(image)].compactMap({ $0 }) {
            guard let destination = CGImageDestinationCreateWithURL(
                url as CFURL, type as CFString, 1, nil) else { continue }
            CGImageDestinationAddImage(destination, candidate, nil)
            if CGImageDestinationFinalize(destination) { return type }
        }
        return nil
    }

    /// Un VRAI PNG en mémoire — pour les aperçus qu'on glisse dans un ZIP ou
    /// dans un conteneur InDesign, où la SIGNATURE compte autant que le
    /// contenu.
    static func pngData(width: Int, height: Int) -> Data {
        let out = NSMutableData()
        guard let image = grayImage(width: width, height: height, noise: false),
              let destination = CGImageDestinationCreateWithData(
                out as CFMutableData, "public.png" as CFString, 1, nil)
        else { return Data() }
        CGImageDestinationAddImage(destination, image, nil)
        CGImageDestinationFinalize(destination)
        return out as Data
    }

    /// La même image en RVB 8 bits.
    static func rgb(_ image: CGImage) -> CGImage? {
        guard let context = CGContext(
            data: nil, width: image.width, height: image.height,
            bitsPerComponent: 8, bytesPerRow: image.width * 4,
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue) else { return nil }
        context.draw(image, in: CGRect(x: 0, y: 0,
                                       width: image.width, height: image.height))
        return context.makeImage()
    }

    /// Un GIF ANIMÉ de deux images : la première porte le mot, la seconde non.
    /// Ce que Fouine doit en faire : une page, celle de la PREMIÈRE image.
    @discardableResult
    static func writeAnimatedGIF(width: Int, height: Int, text: String,
                                 to url: URL) -> Bool {
        guard let type = encodableType(for: "gif"),
              let first = grayImage(width: width, height: height,
                                    noise: true, text: text),
              let second = grayImage(width: width, height: height, noise: false),
              let destination = CGImageDestinationCreateWithURL(
                url as CFURL, type as CFString, 2, nil)
        else { return false }
        let frame: [CFString: Any] = [
            kCGImagePropertyGIFDictionary: [kCGImagePropertyGIFDelayTime: 0.2],
        ]
        CGImageDestinationSetProperties(destination, [
            kCGImagePropertyGIFDictionary: [kCGImagePropertyGIFLoopCount: 0],
        ] as CFDictionary)
        CGImageDestinationAddImage(destination, first, frame as CFDictionary)
        CGImageDestinationAddImage(destination, second, frame as CFDictionary)
        return CGImageDestinationFinalize(destination)
    }

    // MARK: - WebP sans perte, écrit à la main

    /// Un WebP VP8L d'une seule couleur, `width`×`height`, en une trentaine
    /// d'octets. `padTo` ajoute du remplissage APRÈS le conteneur RIFF — les
    /// décodeurs l'ignorent (vérifié : ImageIO décode encore) — pour franchir
    /// le plancher de 64 Kio sans avoir à encoder une vraie photo.
    static func webp(width: Int, height: Int, gray: Int = 200,
                     padTo: Int = 0) -> Data {
        var bits = BitWriter()
        bits.put(width - 1, 14)
        bits.put(height - 1, 14)
        bits.put(0, 1)                     // alpha_is_used
        bits.put(0, 3)                     // version
        bits.put(0, 1)                     // aucune transformation
        bits.put(0, 1)                     // pas de cache de couleurs
        bits.put(0, 1)                     // pas de méta-Huffman (niveau 0)
        // Cinq alphabets (vert, rouge, bleu, alpha, distance), chacun réduit à
        // UN symbole : un code de longueur nulle, donc zéro bit de données —
        // l'image entière tient dans son en-tête.
        for symbol in [gray, gray, gray, 255, 0] {
            bits.put(1, 1)                 // code « simple »
            bits.put(0, 1)                 // un seul symbole
            bits.put(1, 1)                 // symbole sur 8 bits
            bits.put(symbol, 8)
        }
        bits.flush()

        var chunk = Data([0x2F])           // signature VP8L
        chunk.append(contentsOf: bits.bytes)
        if chunk.count % 2 == 1 { chunk.append(0) }

        var out = Data("RIFF".utf8)
        out.append(littleEndian(UInt32(4 + 8 + chunk.count)))
        out.append(Data("WEBP".utf8))
        out.append(Data("VP8L".utf8))
        out.append(littleEndian(UInt32(chunk.count)))
        out.append(chunk)
        if padTo > out.count {
            out.append(Data(repeating: 0x20, count: padTo - out.count))
        }
        return out
    }

    private static func littleEndian(_ value: UInt32) -> Data {
        var little = value.littleEndian
        return Data(bytes: &little, count: 4)
    }

    /// Écriture de bits, poids faible en premier — c'est l'ordre de VP8L.
    struct BitWriter {
        private(set) var bytes: [UInt8] = []
        private var current: UInt8 = 0
        private var used = 0

        mutating func put(_ value: Int, _ count: Int) {
            for index in 0..<count {
                current |= UInt8((value >> index) & 1) << UInt8(used)
                used += 1
                if used == 8 { bytes.append(current); current = 0; used = 0 }
            }
        }

        mutating func flush() {
            if used > 0 { bytes.append(current); current = 0; used = 0 }
        }
    }
}
