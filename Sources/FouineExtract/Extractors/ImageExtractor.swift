// ImageExtractor.swift — extraction d'images seules pour OCR (SPEC §5.3, audit E4, D2 § 5.12).
// SPDX-License-Identifier: LicenseRef-Fouine-Source-Available
// Propriété : A-Ingest.
//
// Une image seule ne contient pas de couche texte native : elle déclare 0 texte,
// 1 page, et s'inscrit en file d'OCR (priorité 1 via OCRPriority.forDocument).
//
// La liste s'est élargie le 08/09/2026 (lot INT-F2) sans changer ce principe :
// tout ce qu'ImageIO sait décoder et que quelqu'un range dans ses documents —
// les formats modernes (heif, avif, webp), les anciens (gif, bmp), le PSD et
// les RAW d'appareil photo. Vérifié sur cette machine par
// `CGImageSourceCopyTypeIdentifiers()` : les onze types ajoutés y figurent tous.
// Sur une machine plus ancienne (macOS 13, cible minimale) un type peut manquer
// au décodeur : l'extension reste inscrite, `CGImageSourceCreateWithURL` rend
// nil, et le document est refusé sur le motif nommé « unreadable image ».
//
// Un GIF ANIMÉ n'est pas un cas particulier : `CGImageSourceCopyPropertiesAtIndex`
// et le rendu travaillent tous deux à l'index 0, donc sur la première image.
// Un TIFF MULTI-PAGES, si (constat C2-03) : c'est la sortie normale d'un
// scanner de bureau, et il vaut TOUTES ses images — `pageCount` les compte,
// chacune part en file d'OCR, et `FouinePageRenderer` rend l'image demandée.
// Sans cela, deux tiers d'un scan de trois pages disparaissaient sans erreur,
// sans motif et sans trace : Fouine n'indexe pas les noms de fichiers.
//
// Garde-fous (audit D2 § 5.12, revus par le constat C2-02) :
//   · plancher de POIDS : fichier < 8 Kio. Sous cette taille, aucun fichier ne
//     porte une page lisible à 300 px ;
//   · plancher de DIMENSIONS : largeur ou hauteur < 300 px. C'est lui qui fait
//     le vrai travail.
//
// Le plancher de poids valait 64 Kio, et c'était une erreur mesurée : la même
// page A4 de 945 × 1418 px, 2 291 caractères lisibles, passe en PNG (249 Ko),
// en JPEG (289 Ko), en HEIC (134 Ko), en WebP (125 Ko) — et se faisait REFUSER
// en AVIF (53 814 octets), format d'export par défaut de plusieurs appareils.
// Un plancher d'octets n'est pas une quantité d'information : les codecs
// modernes le franchissent par le bas sans rien perdre.
//
// DEUX MOTIFS, parce qu'ils n'appellent pas le même geste — l'un dit « cette
// image est trop petite », l'autre « ce fichier est trop léger pour porter un
// document ». Dire « trop petite » d'une page A4 envoyait l'utilisateur
// chercher une image qui n'existe pas.

import Foundation
import CoreGraphics
import ImageIO
import FouineCore

public struct ImageExtractor: TextExtractor {
    public static let supportedExtensions: Set<String> =
        rasterExtensions.union(rawExtensions)

    /// Images « ordinaires », toutes décodées par ImageIO.
    static let rasterExtensions: Set<String> = [
        "png", "jpg", "jpeg", "heic", "heif", "tif", "tiff",
        "avif", "webp", "gif", "bmp", "psd",
    ]

    /// RAW d'appareil photo (INT-F2). Ils passent par la MÊME voie que les
    /// autres : les dimensions viennent des propriétés ImageIO, et le rendu
    /// prend la vignette intégrée plutôt que de développer le négatif —
    /// `CIRAWFilter` coûterait des secondes par image pour une couleur dont
    /// Vision n'a que faire.
    static let rawExtensions: Set<String> = [
        "cr2", "nef", "raf", "dng", "arw", "rw2", "orf",
    ]

    /// Motif de refus quand l'image est sous le plancher de DIMENSIONS. Les
    /// dimensions mesurées suivent le motif (« …: 100x100 px ») : c'est le seul
    /// renseignement qui permette de comprendre le refus sans rouvrir l'image.
    public static let belowFloorReason = "image below the OCR size floor"

    /// Motif de refus quand le FICHIER est sous le plancher de poids. Le nombre
    /// d'octets suit (« …: 2048 bytes »).
    public static let belowWeightFloorReason =
        "image file below the OCR weight floor"

    /// Plancher de poids de fichier en octets : 8 Kio (constat C2-02 ; 64 Kio
    /// jusqu'au 10/09/2026, ce qui refusait des pages A4 bien compressées).
    public static let minFileBytes: Int64 = 8 * 1024

    /// Plancher de dimensions en pixels : 300 px de côté minimum.
    public static let minDimensionPixels: Int = 300

    /// Extensions dont un fichier peut porter PLUSIEURS pages (constat C2-03).
    /// Le GIF animé n'en est pas : ses images sont un mouvement, pas des pages.
    public static let multiPageExtensions: Set<String> = ["tif", "tiff"]

    /// Ce refus est-il l'un des deux planchers ? Les motifs portent une mesure
    /// variable, donc l'ensemble exact d'`ExtractOutcome.skippedReasons` ne peut
    /// pas les contenir : `ExtractOutcome.skipReason(for:)` pose la question.
    public static func isBelowFloor(_ message: String) -> Bool {
        message.hasPrefix(belowFloorReason)
            || message.hasPrefix(belowWeightFloorReason)
    }

    public init() {}

    public func extract(url: URL, limits: ExtractLimits) throws -> ExtractionResult {
        let size = try FileGuard.check(url, limits)
        if size < Self.minFileBytes {
            throw FouineError.extraction(
                "\(Self.belowWeightFloorReason): \(size) bytes")
        }

        let options: [CFString: Any] = [
            kCGImageSourceShouldCache: false
        ]
        guard let source = CGImageSourceCreateWithURL(url as CFURL, options as CFDictionary) else {
            throw FouineError.extraction("unreadable image: \(url.lastPathComponent)")
        }

        guard let (width, height) = Self.pixelSize(of: source, options: options) else {
            throw FouineError.extraction("unreadable image dimensions: \(url.lastPathComponent)")
        }

        if width < Self.minDimensionPixels || height < Self.minDimensionPixels {
            throw FouineError.extraction(
                "\(Self.belowFloorReason): \(width)x\(height) px")
        }

        let pageCount = Self.pageCount(of: source, ext: url.pathExtension)
        // Même refus qu'en PDF (audit S2) : le rowid structuré ne porte que
        // `Schema.maxPage` pages, et un TIFF de scanner peut être long.
        guard pageCount <= Schema.maxPage else {
            throw FouineError.extraction(
                "document too long: \(pageCount) pages, limit \(Schema.maxPage) "
                + "per document (\(url.lastPathComponent))")
        }

        // 0 caractère de texte natif, N pages, toutes en attente d'OCR (§6.1)
        var meta: [String: String] = [:]
        if let taken = Self.exifDate(of: source, options: options) {
            meta["date"] = taken
        }
        return ExtractionResult(
            pages: [],
            pageCount: pageCount,
            ocrCandidates: Array(1...pageCount),
            meta: meta
        )
    }

    /// La date de PRISE DE VUE, telle qu'EXIF l'écrit (« 2003:04:12 10:30:00 »,
    /// schéma v9 — constat PR-07). C'est la seule date d'une photo qui dise
    /// quelque chose : celle du fichier change au moindre déplacement d'un
    /// disque à l'autre.
    ///
    /// `DateTimeOriginal` d'abord — l'instant du déclenchement —, puis
    /// `DateTimeDigitized`, qui n'en diffère que pour un négatif numérisé
    /// après coup. La chaîne est rendue TELLE QUELLE : c'est `DocumentDate` qui
    /// l'analyse et la refuse le cas échéant, à un seul endroit du dépôt.
    ///
    /// Index 0 seulement : une photo n'a qu'une prise de vue, et les
    /// représentations suivantes d'un RAW portent la même.
    static func exifDate(of source: CGImageSource,
                         options: [CFString: Any]) -> String? {
        guard let properties = CGImageSourceCopyPropertiesAtIndex(
                source, 0, options as CFDictionary) as? [CFString: Any],
              let exif = properties[kCGImagePropertyExifDictionary] as? [CFString: Any]
        else { return nil }
        for key in [kCGImagePropertyExifDateTimeOriginal,
                    kCGImagePropertyExifDateTimeDigitized] {
            if let value = exif[key] as? String,
               !value.trimmingCharacters(in: .whitespaces).isEmpty {
                return value
            }
        }
        return nil
    }

    /// Nombre de pages : les images du fichier pour un TIFF, 1 pour tout le
    /// reste — un PSD à calques, un GIF animé ou une photo Live ne sont pas des
    /// documents à plusieurs pages.
    public static func pageCount(of source: CGImageSource, ext: String) -> Int {
        guard multiPageExtensions.contains(ext.lowercased()) else { return 1 }
        return max(1, CGImageSourceGetCount(source))
    }

    /// Dimensions en pixels, cherchées d'abord à l'index 0.
    ///
    /// Le repli sur les index suivants est là pour les RAW (INT-F2) : un `.cr2`
    /// ou un `.nef` porte plusieurs représentations (négatif, vignette JPEG), et
    /// rien ne garantit que la première réponde `PixelWidth` — la boucle est
    /// bornée à quelques index parce qu'un fichier d'appareil photo n'en a
    /// jamais davantage, et qu'un fichier piégé ne doit pas nous faire lire
    /// mille dictionnaires de propriétés.
    static func pixelSize(of source: CGImageSource,
                          options: [CFString: Any]) -> (Int, Int)? {
        let count = min(CGImageSourceGetCount(source), 4)
        guard count > 0 else { return nil }
        for index in 0..<count {
            guard let properties = CGImageSourceCopyPropertiesAtIndex(
                    source, index, options as CFDictionary) as? [CFString: Any],
                  let width = (properties[kCGImagePropertyPixelWidth] as? NSNumber)?.intValue,
                  let height = (properties[kCGImagePropertyPixelHeight] as? NSNumber)?.intValue,
                  width > 0, height > 0
            else { continue }
            return (width, height)
        }
        return nil
    }
}
