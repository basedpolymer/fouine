// DesignPreviewExtractor.swift — .fig (Figma) et .indd (InDesign), SPEC §5.3,
// lot INT-F2.
// SPDX-License-Identifier: LicenseRef-Fouine-Source-Available
// Propriété : A-Ingest.
//
// CE QU'ON NE FAIT PAS, ET POURQUOI
//
//   · Figma. Un `.fig` moderne est un ZIP (`meta.json`, `canvas.fig`,
//     `thumbnail.png`, `images/…`). Le canevas est un binaire compressé au
//     format « kiwi », dont le schéma n'est ni publié ni stable d'une version à
//     l'autre : l'analyser reviendrait à réécrire, et à réécrire à chaque mise
//     à jour de Figma, un format que son éditeur ne documente pas. On ne le
//     lit pas.
//   · InDesign. Un `.indd` est un conteneur propriétaire dont le texte est
//     stocké chiffré par flux ; IDML (le format d'échange XML) est ce qu'Adobe
//     propose pour le lire, et c'est un AUTRE fichier, que seul l'utilisateur
//     peut exporter. On ne le lit pas non plus.
//
// CE QU'ON FAIT. Les deux formats portent une IMAGE d'aperçu, et une image,
// Fouine sait la mettre en file d'OCR — c'est déjà ce qu'elle fait des médias
// OOXML et des images seules. Sous le réglage `extract.images`, le document
// vaut donc UNE page à OCRiser. Sans ce réglage, ou sans aperçu, refus NOMMÉ,
// classé `.skipped` : le document n'est pas cassé, il n'y a simplement rien à
// en tirer.
//
// Le refus dit le GESTE, pas le format : exporter en PDF, ou en SVG/IDML.
// C'est ce que l'utilisateur lit dans la carte « documents illisibles » de
// l'app — et c'est tout ce qu'il en obtient : Fouine n'indexe PAS les noms de
// fichiers (mesuré le 08/09/2026 : `fouine search dessin` ne trouve pas
// `dessin.ai`, même extrait). Un document sans page ne ressort donc d'aucune
// recherche ; le refus nommé est sa seule trace.

import Foundation
import CoreGraphics
import ImageIO
import FouineCore

public struct DesignPreviewExtractor: TextExtractor {
    public static let supportedExtensions: Set<String> = ["fig", "indd"]

    /// Motif exact de `docs.err` pour un `.fig`.
    public static let figNoTextReason =
        "fig: no text layer readable — export the frames as PDF or SVG"

    /// Motif exact de `docs.err` pour un `.indd`.
    public static let inddNoTextReason =
        "indd: no readable text — export as PDF or IDML"

    /// Entrée d'aperçu d'un `.fig` moderne.
    public static let figThumbnailEntry = "thumbnail.png"

    /// Fenêtre de tête où chercher l'aperçu intégré d'un `.indd` : 2 Mio.
    /// Au-delà, ce n'est plus un aperçu mais le contenu du document, qu'on ne
    /// sait de toute façon pas lire.
    public static let inddSniffBytes = 2 << 20

    private let extractImages: Bool

    public init(extractImages: Bool = false) {
        self.extractImages = extractImages
    }

    public func extract(url: URL, limits: ExtractLimits) throws -> ExtractionResult {
        try FileGuard.check(url, limits)
        let ext = url.pathExtension.lowercased()
        let reason = ext == "fig" ? Self.figNoTextReason : Self.inddNoTextReason

        // Le refus est le MÊME que le réglage soit éteint ou que l'aperçu
        // manque : dans les deux cas il n'y a rien à indexer, et l'utilisateur
        // n'a pas à distinguer les deux — le geste utile est le même.
        guard extractImages, (try? Self.previewData(of: url, ext: ext)) != nil else {
            throw FouineError.extraction(reason)
        }
        return ExtractionResult(pages: [], pageCount: 1,
                                ocrCandidates: [1], meta: [:])
    }

    // MARK: - L'aperçu, pour l'extraction ET pour le rendu

    /// Les octets d'une image d'aperçu décodable, ou une erreur nommée.
    /// `FouinePageRenderer` appelle la MÊME fonction : ce qui a été mis en file
    /// d'OCR est exactement ce qui sera rendu.
    public static func previewData(of url: URL, ext: String) throws -> Data {
        switch ext.lowercased() {
        case "fig":
            let entries = try Bsdtar.list(archive: url)
            guard entries.contains(figThumbnailEntry) else {
                throw FouineError.extraction(figNoTextReason)
            }
            let data = try Bsdtar.extract(archive: url, entry: figThumbnailEntry)
            guard decodes(data) else {
                throw FouineError.extraction(figNoTextReason)
            }
            return data
        case "indd":
            guard let handle = FileHandle(forReadingAtPath: url.path) else {
                throw FouineError.extraction(inddNoTextReason)
            }
            defer { try? handle.close() }
            let head = handle.readData(ofLength: inddSniffBytes)
            guard let offset = embeddedImageOffset(in: head) else {
                throw FouineError.extraction(inddNoTextReason)
            }
            let data = head.subdata(in: (head.startIndex + offset)..<head.endIndex)
            // Le décodage EST le test : une signature PNG ou JPEG peut tomber
            // par hasard dans un flux binaire, une image décodable non.
            guard decodes(data) else {
                throw FouineError.extraction(inddNoTextReason)
            }
            return data
        default:
            throw FouineError.unsupported(ext: ext)
        }
    }

    /// Position de la première image intégrée (PNG ou JPEG) dans ces octets.
    static func embeddedImageOffset(in data: Data) -> Int? {
        let png: [UInt8] = [0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A]
        let jpeg: [UInt8] = [0xFF, 0xD8, 0xFF]
        var best: Int?
        for signature in [png, jpeg] {
            if let offset = firstIndex(of: signature, in: data) {
                best = min(best ?? offset, offset)
            }
        }
        return best
    }

    static func firstIndex(of signature: [UInt8], in data: Data) -> Int? {
        guard data.count >= signature.count else { return nil }
        return data.withUnsafeBytes { raw -> Int? in
            let bytes = raw.bindMemory(to: UInt8.self)
            let last = bytes.count - signature.count
            var index = 0
            while index <= last {
                if bytes[index] == signature[0] {
                    var matched = true
                    for offset in 1..<signature.count
                    where bytes[index + offset] != signature[offset] {
                        matched = false
                        break
                    }
                    if matched { return index }
                }
                index += 1
            }
            return nil
        }
    }

    /// Vraie si ImageIO tire une image de ces octets. Les octets qui SUIVENT
    /// l'image sont ignorés par le décodeur : inutile de chercher la fin du
    /// flux dans le conteneur InDesign.
    static func decodes(_ data: Data) -> Bool {
        guard let source = CGImageSourceCreateWithData(data as CFData, nil),
              CGImageSourceGetCount(source) > 0,
              let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil)
                as? [CFString: Any],
              let width = (properties[kCGImagePropertyPixelWidth] as? NSNumber)?.intValue,
              let height = (properties[kCGImagePropertyPixelHeight] as? NSNumber)?.intValue
        else { return false }
        return width > 0 && height > 0
    }
}
