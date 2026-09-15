// ComicArchiveExtractor.swift — cbz cbr (SPEC §5.3, §2.4).
// Propriété : A-Ingest.
//
// « bsdtar (libarchive lit ZIP et RAR v4, vérifié sur fichiers réels) -> images
// triées -> toutes les pages en file OCR, priorité 3. 34 archives, 5 291 images
// (mesuré). »
//
// Aucun texte : `pages` est VIDE, `pageCount` = nombre d'images, et toutes les
// pages sont candidates à l'OCR. L'ordre de tri EST la numérotation des pages,
// d'où le tri naturel (img2 avant img10).

import Foundation
import FouineCore

public struct ComicArchiveExtractor: TextExtractor {
    public static let supportedExtensions: Set<String> = ["cbz", "cbr"]

    public init() {}

    public func extract(url: URL, limits: ExtractLimits) throws -> ExtractionResult {
        try FileGuard.check(url, limits)
        let images = try ArchiveImages.imageEntries(archiveURL: url)
        guard !images.isEmpty else {
            throw FouineError.extraction(
                "comic archive with no image (\(url.lastPathComponent))")
        }
        return ExtractionResult(pages: [],
                                pageCount: images.count,
                                ocrCandidates: Array(1...images.count),
                                meta: [:])
    }
}

/// API publique consommée par A-OCR (vague 2) : SIGNATURES IMPOSÉES.
public enum ArchiveImages {
    /// Entrées image triées d'un cbz/cbr (ordre = ordre des pages, 1-indexé).
    public static func imageEntries(archiveURL: URL) throws -> [String] {
        let entries = try Bsdtar.list(archive: archiveURL)
        return EntrySort.imageEntries(entries, allowed: EntrySort.comicImageExtensions)
    }

    /// Contenu brut d'une image. Rien n'est écrit sur disque (§5.3).
    public static func extractEntry(archiveURL: URL, entry: String) throws -> Data {
        try Bsdtar.extract(archive: archiveURL, entry: entry)
    }
}
