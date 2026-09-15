// IWorkExtractor.swift — extraction iWork (.pages, .numbers, .key) via Preview.pdf (SPEC §5.3, audit D2 § 5.12).
// SPDX-License-Identifier: LicenseRef-Fouine-Source-Available
// Propriété : A-Ingest.
//
// Les documents iWork modernes sont soit des paquets (répertoires), soit des archives ZIP.
// Aucun parseur protobuf (.iwa) n'est embarqué : l'extraction s'appuie sur
// QuickLook/Preview.pdf, délégué à PDFExtractor qui porte déjà la réouverture
// /100 pages et les délais de garde de Deadline.
//
// Deux formes :
//   · paquet-répertoire : lecture directe de QuickLook/Preview.pdf ;
//   · archive ZIP : extraction de la SEULE entrée QuickLook/Preview.pdf par le
//     Bsdtar durci avec `--`, sans jamais déballer le reste de l'archive.
//
// En l'absence de QuickLook/Preview.pdf, refus explicite dans docs.err :
// « iWork document without a QuickLook preview — open it once in Pages to generate one ».

import Foundation
import FouineCore

public struct IWorkExtractor: TextExtractor {
    public static let supportedExtensions: Set<String> = ["pages", "numbers", "key"]

    /// Message exact exigé dans `docs.err` en l'absence d'aperçu QuickLook (audit D2 § 5.12).
    public static let missingPreviewReason =
        "iWork document without a QuickLook preview — open it once in Pages to generate one"

    public static let previewEntry = "QuickLook/Preview.pdf"

    public init() {}

    public func extract(url: URL, limits: ExtractLimits) throws -> ExtractionResult {
        try FileGuard.check(url, limits)

        var st = stat()
        guard stat(url.path, &st) == 0 else {
            throw FouineError.extraction(
                "unreadable file: \(String(cString: strerror(errno))) (\(url.path))")
        }

        let isDirectory = (st.st_mode & S_IFMT) == S_IFDIR

        if isDirectory {
            return try extractFromPackage(url: url, limits: limits)
        } else {
            return try extractFromZip(url: url, limits: limits)
        }
    }

    private func extractFromPackage(url: URL, limits: ExtractLimits) throws -> ExtractionResult {
        let previewURL = url.appendingPathComponent(Self.previewEntry)
        guard FileManager.default.fileExists(atPath: previewURL.path) else {
            throw FouineError.extraction(Self.missingPreviewReason)
        }
        return try PDFExtractor().extract(url: previewURL, limits: limits)
    }

    private func extractFromZip(url: URL, limits: ExtractLimits) throws -> ExtractionResult {
        // Liste les entrées pour vérifier la présence de QuickLook/Preview.pdf sans tout déballer
        let entries = try Bsdtar.list(archive: url)
        guard entries.contains(Self.previewEntry) else {
            throw FouineError.extraction(Self.missingPreviewReason)
        }

        let data = try Bsdtar.extract(archive: url, entry: Self.previewEntry)

        // Écriture du PDF extrait dans un sous-dossier temporaire pour réutiliser PDFExtractor
        // et son mécanisme de réouverture /100 pages sans fuite mémoire.
        let tempDir = URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
            .appendingPathComponent("fouine-iwork-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tempDir) }

        let tempPDF = tempDir.appendingPathComponent("Preview.pdf")
        try data.write(to: tempPDF)

        return try PDFExtractor().extract(url: tempPDF, limits: limits)
    }
}
