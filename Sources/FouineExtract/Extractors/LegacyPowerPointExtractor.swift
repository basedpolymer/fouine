// LegacyPowerPointExtractor.swift — ppt (PowerPoint 97-2003).
// SPDX-License-Identifier: LicenseRef-Fouine-Source-Available
// Propriété : A-Ingest. Lot INT-F1, SPEC §5.3 amendé le 08/09/2026.
//
// Un `.ppt` est un conteneur OLE (`CompoundFile`) dont le flux
// `PowerPoint Document` est un ARBRE d'enregistrements : huit octets d'en-tête
// (version + instance sur deux octets, type sur deux, longueur sur quatre) puis
// les données — ou, quand la version vaut 0xF, d'autres enregistrements.
//
// LE TEXTE EST À DEUX ENDROITS, et il faut savoir lire les deux :
//
//   1. `SlideListWithText` (0x0FF0), la table que PowerPoint tient pour ses
//      recherches. Ses `SlidePersistAtom` (0x03F3) séparent les diapositives ;
//      son instance dit de quoi elle parle : 0 les diapositives, 1 les masques,
//      2 les NOTES du présentateur. C'est la voie normale ;
//   2. les conteneurs `Slide` (0x03EE) eux-mêmes, quand le producteur n'a pas
//      rempli la table. C'est le REPLI, et il existe parce qu'il se rencontre :
//      des exports d'outils tiers n'écrivent que les diapositives.
//
// Le texte lui-même est dans `TextCharsAtom` (0x0FA0, UTF-16LE),
// `TextBytesAtom` (0x0FA8, un octet par caractère, Windows-1252) et `CString`
// (0x0FBA, UTF-16LE — les titres de la table des matières).
//
// UNE PAGE PAR DIAPOSITIVE (§5.3, comme `.pptx`). Les notes du présentateur
// s'ajoutent à la page de LEUR diapositive : ce sont les mêmes idées, dites
// autrement, et les séparer ferait deux demi-résultats au lieu d'un bon.
//
// CHIFFREMENT : un `CryptSession10Container` (0x2F14), ou l'en-tête chiffré du
// flux `Current User`, valent refus NOMMÉ — il n'y a rien à lire sans la clé,
// et un lecteur qui insisterait rendrait du mojibake.
//
// HORS LOT : les images embarquées (flux `Pictures`) ne partent pas en OCR. Les
// médias des `.pptx`, eux, y vont déjà (§5.3) ; c'est un écart connu et noté.

import Foundation
import FouineCore

public struct LegacyPowerPointExtractor: TextExtractor {
    public static let supportedExtensions: Set<String> = ["ppt"]

    /// Refus nommés, classés `.skipped` par `ExtractOutcome`.
    public static let passwordReason = "password-protected presentation"
    public static let noDocumentStreamReason =
        "OLE container without a PowerPoint Document stream"

    public init() {}

    public func extract(url: URL, limits: ExtractLimits) throws -> ExtractionResult {
        try FileGuard.check(url, limits)
        let slides = try Deadline.extraction(
            seconds: Deadline.renderSeconds,
            label: "reading \(url.lastPathComponent)",
            body: { try PPTDocument.slides(url: url, limits: limits) })

        var budget = TextBudget(maxBytes: limits.maxTextBytes)
        var slots: [String] = []
        for slide in slides {
            let text = budget.take(slide)
            let kept = Plausibility.isPlausible(text) ? text : ""
            let split = TextPagination.paginate(kept, limit: limits.pageSplitChars)
            slots += split.isEmpty ? [""] : split
            if budget.isExhausted { break }
        }
        return Assembler.result(slots: slots, meta: [:])
    }
}

/// La lecture du flux `PowerPoint Document`, séparée pour être testable sans
/// passer par un fichier.
enum PPTDocument {

    // MARK: - Types d'enregistrement

    static let documentStream = "PowerPoint Document"
    static let currentUserStream = "Current User"

    static let slideListWithText: UInt16 = 0x0FF0
    static let slidePersistAtom: UInt16 = 0x03F3
    static let textCharsAtom: UInt16 = 0x0FA0
    static let textBytesAtom: UInt16 = 0x0FA8
    static let cString: UInt16 = 0x0FBA
    static let slideContainer: UInt16 = 0x03EE
    static let cryptSession10Container: UInt16 = 0x2F14

    /// Marqueur de l'atome `CurrentUser` d'un fichier CHIFFRÉ ; la valeur d'un
    /// fichier ordinaire est 0xE391C05F.
    static let encryptedToken: UInt32 = 0xF3D1_C4DF

    struct Record {
        let type: UInt16
        let instance: UInt16
        let isContainer: Bool
        let body: Data
    }

    /// Le texte de chaque diapositive, dans l'ordre.
    static func slides(url: URL, limits: ExtractLimits) throws -> [String] {
        let container = try CompoundFile(url: url, limits: limits)
        guard let stream = try container.stream(named: documentStream) else {
            throw FouineError.extraction(
                LegacyPowerPointExtractor.noDocumentStreamReason)
        }
        if let user = try container.stream(named: currentUserStream),
           user.count >= 12, CompoundFile.u32(user, 8) == encryptedToken {
            throw FouineError.extraction(LegacyPowerPointExtractor.passwordReason)
        }
        return try slides(inDocumentStream: stream)
    }

    static func slides(inDocumentStream stream: Data) throws -> [String] {
        let top = records(in: stream)
        if contains(type: cryptSession10Container, in: top) {
            throw FouineError.extraction(LegacyPowerPointExtractor.passwordReason)
        }

        var pages = collectFromSlideList(top, instance: 0)
        if pages.allSatisfy({ $0.isEmpty }) {
            // Repli : la table n'a rien donné, on lit les conteneurs `Slide`.
            let fallback = collectFromSlideContainers(top)
            if !fallback.isEmpty { pages = fallback }
        }

        // Les notes du présentateur rejoignent LEUR diapositive.
        let notes = collectFromSlideList(top, instance: 2)
        for (index, note) in notes.enumerated() where !note.isEmpty {
            guard index < pages.count else { break }
            pages[index] = pages[index].isEmpty ? note : pages[index] + "\n" + note
        }
        return pages
    }

    // MARK: - Parcours

    /// Les enregistrements d'un niveau. Un en-tête tronqué ou une longueur qui
    /// sort du bloc arrêtent la lecture : on ne devine pas.
    static func records(in data: Data) -> [Record] {
        var found: [Record] = []
        var offset = 0
        while offset + 8 <= data.count {
            let versionAndInstance = CompoundFile.u16(data, offset)
            let type = CompoundFile.u16(data, offset + 2)
            let length = Int(CompoundFile.u32(data, offset + 4))
            let start = offset + 8
            guard length >= 0, start + length <= data.count else { break }
            found.append(Record(type: type,
                                instance: versionAndInstance >> 4,
                                isContainer: (versionAndInstance & 0x0F) == 0x0F,
                                body: data.subdata(in: start..<(start + length))))
            offset = start + length
        }
        return found
    }

    /// Descend l'arbre à la recherche d'un type. Profondeur bornée : un fichier
    /// tordu ne doit pas faire exploser la pile.
    static func contains(type wanted: UInt16, in records: [Record],
                         depth: Int = 0) -> Bool {
        guard depth < 32 else { return false }
        for record in records {
            if record.type == wanted { return true }
            if record.isContainer,
               contains(type: wanted, in: Self.records(in: record.body),
                        depth: depth + 1) { return true }
        }
        return false
    }

    /// Le texte des `SlideListWithText` d'une instance donnée, une entrée par
    /// diapositive. Les `SlidePersistAtom` sont les frontières.
    static func collectFromSlideList(_ records: [Record], instance: UInt16,
                                     depth: Int = 0) -> [String] {
        guard depth < 32 else { return [] }
        var pages: [String] = []
        for record in records {
            if record.type == slideListWithText, record.instance == instance {
                pages += slideListPages(record.body)
            } else if record.isContainer {
                pages += collectFromSlideList(Self.records(in: record.body),
                                              instance: instance, depth: depth + 1)
            }
        }
        return pages
    }

    private static func slideListPages(_ body: Data) -> [String] {
        var pages: [String] = []
        var current: [String] = []
        var started = false
        for record in records(in: body) {
            if record.type == slidePersistAtom {
                if started { pages.append(current.joined(separator: "\n")) }
                current = []
                started = true
                continue
            }
            current += texts(in: record)
        }
        if started { pages.append(current.joined(separator: "\n")) }
        return pages
    }

    /// Repli : un conteneur `Slide` par diapositive, dans l'ordre du flux.
    static func collectFromSlideContainers(_ records: [Record],
                                           depth: Int = 0) -> [String] {
        guard depth < 32 else { return [] }
        var pages: [String] = []
        for record in records {
            if record.type == slideContainer {
                let text = texts(in: record).joined(separator: "\n")
                pages.append(text)
            } else if record.isContainer {
                pages += collectFromSlideContainers(Self.records(in: record.body),
                                                    depth: depth + 1)
            }
        }
        return pages
    }

    /// Marqueur interne de PowerPoint, présent dans presque tous les fichiers
    /// réels — mesuré sur un `.ppt` de cours, où il ressortait en page 3. Ce
    /// n'est pas du texte de diapositive mais une étiquette de version
    /// d'animation : elle n'a rien à faire dans l'index.
    static let internalMarker = "___PPT"

    /// Tout le texte porté par un enregistrement et ses descendants.
    static func texts(in record: Record, depth: Int = 0) -> [String] {
        guard depth < 32 else { return [] }
        switch record.type {
        case textCharsAtom, cString:
            return [utf16Text(record.body)].compactMap(cleaned)
        case textBytesAtom:
            return [paragraphs(SSTReader.windows1252(record.body))]
                .compactMap(cleaned)
        default:
            guard record.isContainer else { return [] }
            return records(in: record.body).flatMap { texts(in: $0, depth: depth + 1) }
        }
    }

    /// Le texte utile d'un atome, ou `nil` : vide, ou marqueur interne.
    static func cleaned(_ text: String) -> String? {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, !trimmed.hasPrefix(internalMarker) else { return nil }
        return trimmed
    }

    /// Les deux séparateurs propres à PowerPoint : `\r` termine un paragraphe,
    /// `\v` (0x0B) une ligne dans un même paragraphe.
    static func paragraphs(_ text: String) -> String {
        text.replacingOccurrences(of: "\r", with: "\n")
            .replacingOccurrences(of: "\u{0B}", with: "\n")
    }

    /// UTF-16LE, séparateurs de PowerPoint compris.
    static func utf16Text(_ data: Data) -> String {
        var scalars: [UInt16] = []
        scalars.reserveCapacity(data.count / 2)
        var offset = 0
        while offset + 2 <= data.count {
            scalars.append(CompoundFile.u16(data, offset))
            offset += 2
        }
        return paragraphs(String(decoding: scalars, as: UTF16.self))
    }
}
