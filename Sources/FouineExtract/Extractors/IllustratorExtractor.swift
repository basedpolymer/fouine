// IllustratorExtractor.swift — .ai (SPEC §5.3, lot INT-F2).
// SPDX-License-Identifier: LicenseRef-Fouine-Source-Available
// Propriété : A-Ingest.
//
// Un `.ai` enregistré par Illustrator 9 ou plus récent AVEC l'option « Créer un
// fichier compatible PDF » (cochée par défaut depuis vingt ans) EST un PDF :
// même en-tête, même table d'objets, et la même couche texte que celle que
// PDFKit sait lire. On ne réimplémente donc rien — on délègue à `PDFExtractor`,
// qui porte déjà la réouverture /100 pages, les délais de garde et le refus
// nommé sur PDF corrompu.
//
// Deux formes d'en-tête, mesurées sur les fichiers du commerce :
//   · « %PDF-1.5 … » dès l'octet 0 — le cas courant ;
//   · « %!PS-Adobe-3.0 … %%BoundingBox … » puis, plus loin, « %PDF- » — un
//     `.ai` sauvegardé en compatibilité PostScript. PDFKit refuse le fichier
//     tel quel : on lui recopie la PARTIE PDF dans un fichier temporaire.
//
// Sans « %PDF- » dans les 1 024 premiers octets, il n'y a pas de couche PDF du
// tout (`.ai` d'Illustrator 8, ou fichier tronqué) : refus NOMMÉ, classé
// `.skipped` — le fichier n'est pas cassé, il n'y a simplement rien à lire.
// Le motif dit le geste (recocher la case à l'enregistrement) : c'est la seule
// trace du document, puisque Fouine n'indexe pas les noms de fichiers.

import Foundation
import FouineCore

public struct IllustratorExtractor: TextExtractor {
    public static let supportedExtensions: Set<String> = ["ai"]

    /// Motif exact de `docs.err` quand le fichier ne porte aucune couche PDF.
    /// Le geste tient dans la phrase : c'est la case de la boîte de dialogue
    /// d'enregistrement d'Illustrator.
    public static let noPDFLayerReason =
        "ai: no PDF layer — save with “Create PDF Compatible File”"

    /// Fenêtre de reniflage : un en-tête PostScript d'Illustrator tient dans
    /// quelques centaines d'octets, « %PDF- » vient juste après.
    static let sniffBytes = 1_024

    public init() {}

    public func extract(url: URL, limits: ExtractLimits) throws -> ExtractionResult {
        try FileGuard.check(url, limits)

        guard let handle = FileHandle(forReadingAtPath: url.path) else {
            throw FouineError.extraction(
                "unreadable file: \(url.lastPathComponent)")
        }
        defer { try? handle.close() }
        let head = handle.readData(ofLength: Self.sniffBytes)

        guard let offset = Self.pdfOffset(in: head) else {
            throw FouineError.extraction(Self.noPDFLayerReason)
        }
        if offset == 0 {
            return try PDFExtractor().extract(url: url, limits: limits)
        }

        // En-tête PostScript devant le PDF : on ne réécrit pas le fichier de
        // l'utilisateur (§3, corpus en lecture seule stricte), on recopie la
        // partie PDF à côté, exactement comme IWorkExtractor recopie
        // QuickLook/Preview.pdf.
        let temporary = try Self.copyPDFPart(of: url, from: offset, handle: handle)
        defer { try? FileManager.default.removeItem(
            at: temporary.deletingLastPathComponent()) }
        return try PDFExtractor().extract(url: temporary, limits: limits)
    }

    /// Position de « %PDF- » dans les octets de tête, `nil` s'il n'y est pas.
    static func pdfOffset(in head: Data) -> Int? {
        let needle = Data("%PDF-".utf8)
        guard head.count >= needle.count else { return nil }
        for start in 0...(head.count - needle.count) {
            if head[head.startIndex + start ..< head.startIndex + start + needle.count]
                .elementsEqual(needle) {
                return start
            }
        }
        return nil
    }

    /// Recopie du fichier À PARTIR de `offset` dans un dossier temporaire, par
    /// tranches : un `.ai` de plusieurs centaines de mégaoctets ne doit pas
    /// tenir en mémoire pour être lu.
    static func copyPDFPart(of url: URL, from offset: Int,
                            handle: FileHandle) throws -> URL {
        let directory = URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
            .appendingPathComponent("fouine-ai-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory,
                                                withIntermediateDirectories: true)
        let destination = directory.appendingPathComponent("layer.pdf")
        guard FileManager.default.createFile(atPath: destination.path, contents: nil),
              let output = FileHandle(forWritingAtPath: destination.path) else {
            throw FouineError.extraction(
                "cannot stage the PDF layer of \(url.lastPathComponent)")
        }
        defer { try? output.close() }
        try handle.seek(toOffset: UInt64(offset))
        while true {
            let chunk = handle.readData(ofLength: 4 << 20)
            if chunk.isEmpty { break }
            output.write(chunk)
        }
        return destination
    }
}
