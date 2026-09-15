// LegacyExcelExtractor.swift — xls (Excel 5 à 97-2003, BIFF5/BIFF8).
// SPDX-License-Identifier: LicenseRef-Fouine-Source-Available
// Propriété : A-Ingest. Lot INT-F1, SPEC §5.3 amendé le 08/09/2026.
//
// Un `.xls` est un conteneur OLE (`CompoundFile`) dont le flux `Workbook`
// (`Book` en BIFF5) est une SUITE D'ENREGISTREMENTS : deux octets de type, deux
// de longueur, les données. On n'en lit que ce qui porte du texte :
//
//   · `BOUNDSHEET` (0x0085) — le nom de chaque feuille et l'OFFSET de son
//     sous-flux dans le flux. C'est lui qui donne l'ordre des pages ;
//   · `SST` (0x00FC) — la table des chaînes partagées, où Excel range une fois
//     pour toutes le texte de tout le classeur. Elle déborde en `CONTINUE`
//     (0x003C), et chaque continuation REDÉCLARE si la suite des caractères est
//     compressée (un octet par caractère) ou en UTF-16 : c'est le piège du
//     format, et le seul endroit où un lecteur naïf rend du mojibake ;
//   · `LABELSST` (0x00FD), `LABEL` (0x0204) — une cellule de texte ;
//   · `NUMBER` (0x0203), `RK` (0x027E), `MULRK` (0x00BD) — une cellule de
//     nombre, rendue en texte court (`%g`) : « 12,5 » se cherche, pas la
//     représentation IEEE ;
//   · `FORMULA` (0x0006) suivi de `STRING` (0x0207) — le résultat TEXTE d'une
//     formule. La formule elle-même ne s'indexe pas : personne ne cherche
//     « =RECHERCHEV » ;
//   · `FILEPASS` (0x002F) — le classeur est chiffré. Refus NOMMÉ.
//
// UNE PAGE PAR FEUILLE (§5.3, comme `.xlsx`), cellules dans l'ordre ligne puis
// colonne, une tabulation entre cellules, un saut de ligne entre lignes.
//
// Le CONTRÔLE DE PLAUSIBILITÉ reste obligatoire : c'est de ce format que
// venaient les 316 411 caractères de mojibake du §7.2 n°3. Une page qui ne
// passe pas le contrôle n'est pas émise — mieux vaut une feuille en moins qu'un
// vocabulaire pollué.

import Foundation
import FouineCore

public struct LegacyExcelExtractor: TextExtractor {
    public static let supportedExtensions: Set<String> = ["xls"]

    /// Refus nommés, classés `.skipped` par `ExtractOutcome`.
    public static let passwordReason = "password-protected workbook"
    public static let noWorkbookReason = "OLE container without a workbook stream"

    public init() {}

    public func extract(url: URL, limits: ExtractLimits) throws -> ExtractionResult {
        try FileGuard.check(url, limits)
        // Même ceinture que `RichTextExtractor` et `PDFExtractor` : un fichier
        // tordu ne doit pas geler un fil de la pompe d'indexation (audit F6).
        let sheets = try Deadline.extraction(
            seconds: Deadline.renderSeconds,
            label: "reading \(url.lastPathComponent)",
            body: { try BIFFWorkbook.sheets(url: url, limits: limits) })

        var budget = TextBudget(maxBytes: limits.maxTextBytes)
        var slots: [String] = []
        for sheet in sheets {
            let text = budget.take(sheet)
            // Une feuille de mojibake n'entre pas dans l'index (§7.2 n°3) ;
            // les autres feuilles du classeur, elles, restent.
            let kept = Plausibility.isPlausible(text) ? text : ""
            let split = TextPagination.paginate(kept, limit: limits.pageSplitChars)
            slots += split.isEmpty ? [""] : split
            if budget.isExhausted { break }
        }
        return Assembler.result(slots: slots, meta: [:])
    }
}

/// La lecture du flux `Workbook`, séparée de l'extracteur pour être testable
/// sans passer par un fichier.
enum BIFFWorkbook {

    // MARK: - Types d'enregistrement

    static let bof: UInt16 = 0x0809
    static let eof: UInt16 = 0x000A
    static let filePass: UInt16 = 0x002F
    static let boundSheet: UInt16 = 0x0085
    static let sst: UInt16 = 0x00FC
    static let continueRecord: UInt16 = 0x003C
    static let labelSST: UInt16 = 0x00FD
    static let label: UInt16 = 0x0204
    static let number: UInt16 = 0x0203
    static let rk: UInt16 = 0x027E
    static let mulRK: UInt16 = 0x00BD
    static let formula: UInt16 = 0x0006
    static let stringRecord: UInt16 = 0x0207

    struct Record {
        let type: UInt16
        let offset: Int          // position de l'EN-TÊTE dans le flux
        let body: Data
    }

    /// Le texte de chaque feuille, dans l'ordre des `BOUNDSHEET`.
    static func sheets(url: URL, limits: ExtractLimits) throws -> [String] {
        let container = try CompoundFile(url: url, limits: limits)
        guard let stream = try container.stream(named: "Workbook")
                ?? container.stream(named: "Book") else {
            throw FouineError.extraction(LegacyExcelExtractor.noWorkbookReason)
        }
        return try sheets(inWorkbookStream: stream)
    }

    static func sheets(inWorkbookStream stream: Data) throws -> [String] {
        let records = split(stream)
        guard !records.isEmpty else {
            throw FouineError.extraction(LegacyExcelExtractor.noWorkbookReason)
        }
        if records.contains(where: { $0.type == filePass }) {
            throw FouineError.extraction(LegacyExcelExtractor.passwordReason)
        }

        // BIFF8 depuis Excel 97 ; BIFF5 (0x0500) et BIFF7 lisent leurs chaînes
        // en un octet par caractère, sans drapeau.
        let version = records.first(where: { $0.type == bof })
            .map { CompoundFile.u16($0.body, 0) } ?? 0x0600
        let isBIFF8 = version >= 0x0600

        // — Feuilles, et l'offset où commence chacune ————————————————
        var sheetOffsets: [Int] = []
        for record in records where record.type == boundSheet {
            sheetOffsets.append(Int(CompoundFile.u32(record.body, 0)))
        }
        var sheetIndexByOffset: [Int: Int] = [:]
        for (index, offset) in sheetOffsets.enumerated() {
            sheetIndexByOffset[offset] = index
        }
        let sheetCount = max(1, sheetOffsets.count)

        // — Table des chaînes partagées ——————————————————————————————
        var shared: [String] = []
        for (position, record) in records.enumerated() where record.type == sst {
            var blocks = [record.body]
            var next = position + 1
            while next < records.count, records[next].type == continueRecord {
                blocks.append(records[next].body)
                next += 1
            }
            shared = SSTReader.strings(in: blocks)
            break
        }

        // — Cellules ————————————————————————————————————————————————
        var cells = Array(repeating: [Int: [Int: String]](), count: sheetCount)
        var current = -1                      // -1 = sous-flux des globales
        var pendingFormula: (sheet: Int, row: Int, column: Int)?

        func put(_ sheet: Int, _ row: Int, _ column: Int, _ text: String) {
            guard sheet >= 0, sheet < cells.count, !text.isEmpty else { return }
            cells[sheet][row, default: [:]][column] = text
        }

        for record in records {
            switch record.type {
            case bof:
                if let known = sheetIndexByOffset[record.offset] {
                    current = known
                } else if current >= -1 && record.offset > 0 {
                    // Repli : un producteur qui n'aligne pas ses `BOUNDSHEET`
                    // sur les offsets réels. L'ordre du flux reste l'ordre des
                    // feuilles.
                    current += 1
                }
            case labelSST:
                let index = Int(CompoundFile.u32(record.body, 6))
                if index >= 0, index < shared.count {
                    put(current, Int(CompoundFile.u16(record.body, 0)),
                        Int(CompoundFile.u16(record.body, 2)), shared[index])
                }
            case label:
                let text = isBIFF8
                    ? SSTReader.unicodeString(record.body, at: 6)
                    : SSTReader.byteString(record.body, at: 6)
                put(current, Int(CompoundFile.u16(record.body, 0)),
                    Int(CompoundFile.u16(record.body, 2)), text)
            case number:
                let value = Double(bitPattern: CompoundFile.u64(record.body, 6))
                put(current, Int(CompoundFile.u16(record.body, 0)),
                    Int(CompoundFile.u16(record.body, 2)), format(value))
            case rk:
                let value = rkValue(CompoundFile.u32(record.body, 6))
                put(current, Int(CompoundFile.u16(record.body, 0)),
                    Int(CompoundFile.u16(record.body, 2)), format(value))
            case mulRK where record.body.count >= 12:
                let row = Int(CompoundFile.u16(record.body, 0))
                let first = Int(CompoundFile.u16(record.body, 2))
                var offset = 4
                var column = first
                while offset + 6 <= record.body.count - 2 {
                    let value = rkValue(CompoundFile.u32(record.body, offset + 2))
                    put(current, row, column, format(value))
                    offset += 6
                    column += 1
                }
            case formula:
                // Le résultat d'une formule tient sur huit octets. « Chaîne »
                // s'y écrit `00 … FF FF` : le texte arrive dans le `STRING` qui
                // suit, et lui seul nous intéresse.
                let row = Int(CompoundFile.u16(record.body, 0))
                let column = Int(CompoundFile.u16(record.body, 2))
                if record.body.count >= 14, record.body[6] == 0x00,
                   record.body[12] == 0xFF, record.body[13] == 0xFF {
                    pendingFormula = (current, row, column)
                } else if record.body.count >= 14 {
                    let value = Double(bitPattern: CompoundFile.u64(record.body, 6))
                    if value.isFinite { put(current, row, column, format(value)) }
                }
            case stringRecord:
                if let pending = pendingFormula {
                    let text = isBIFF8
                        ? SSTReader.unicodeString(record.body, at: 0)
                        : SSTReader.byteString(record.body, at: 0)
                    put(pending.sheet, pending.row, pending.column, text)
                    pendingFormula = nil
                }
            default:
                break
            }
        }

        return cells.map { rows in
            rows.keys.sorted().map { row in
                let line = rows[row] ?? [:]
                return line.keys.sorted().map { line[$0] ?? "" }
                    .joined(separator: "\t")
            }.joined(separator: "\n")
        }
    }

    /// Les enregistrements du flux. Un type nul de longueur nulle est du
    /// REMPLISSAGE de fin de secteur : on s'arrête là plutôt que de tourner.
    static func split(_ stream: Data) -> [Record] {
        var records: [Record] = []
        var offset = 0
        while offset + 4 <= stream.count {
            let type = CompoundFile.u16(stream, offset)
            let length = Int(CompoundFile.u16(stream, offset + 2))
            if type == 0 && length == 0 { break }
            let start = offset + 4
            guard start + length <= stream.count else { break }
            records.append(Record(type: type, offset: offset,
                                  body: stream.subdata(in: start..<(start + length))))
            offset = start + length
        }
        return records
    }

    /// Un `RK` : un flottant IEEE amputé de sa mantisse basse, ou un entier
    /// signé sur 30 bits, éventuellement divisé par cent.
    static func rkValue(_ raw: UInt32) -> Double {
        var value: Double
        if raw & 0x02 != 0 {
            value = Double(Int32(bitPattern: raw) >> 2)
        } else {
            value = Double(bitPattern: UInt64(raw & 0xFFFF_FFFC) << 32)
        }
        if raw & 0x01 != 0 { value /= 100 }
        return value
    }

    /// Un nombre de cellule en texte COURT. `%g` rend « 42 » et « 12.5 », jamais
    /// « 42.000000 » : c'est ce qu'on cherche dans un tableur.
    static func format(_ value: Double) -> String {
        guard value.isFinite else { return "" }
        return String(format: "%g", value)
    }
}

/// Lecture des chaînes BIFF, y compris la table partagée éclatée en `CONTINUE`.
enum SSTReader {

    /// Les chaînes uniques de la `SST`, dans l'ordre : c'est l'index qu'utilise
    /// `LABELSST`.
    static func strings(in blocks: [Data]) -> [String] {
        var cursor = Cursor(blocks: blocks)
        guard cursor.u32() != nil, let unique = cursor.u32() else { return [] }
        var result: [String] = []
        // Plafond de sûreté : le compteur vient du fichier, il peut mentir.
        let wanted = min(Int(unique), 1 << 20)
        for _ in 0..<wanted {
            guard let text = cursor.richString() else { break }
            result.append(text)
        }
        return result
    }

    /// Chaîne BIFF8 (`XLUnicodeString`) à une position d'un enregistrement.
    static func unicodeString(_ body: Data, at offset: Int) -> String {
        var cursor = Cursor(blocks: [body.count > offset
                                     ? body.subdata(in: offset..<body.count)
                                     : Data()])
        return cursor.richString() ?? ""
    }

    /// Chaîne BIFF5 : longueur sur deux octets, un octet par caractère
    /// (Windows-1252).
    static func byteString(_ body: Data, at offset: Int) -> String {
        let count = Int(CompoundFile.u16(body, offset))
        let start = offset + 2
        guard count > 0, start + count <= body.count else { return "" }
        return windows1252(body.subdata(in: start..<(start + count)))
    }

    /// Windows-1252, la page de codes des `.xls` et des `.ppt` occidentaux.
    /// `isoLatin1` en diffère sur la plage 0x80-0x9F, où se trouvent les
    /// guillemets typographiques, le tiret cadratin et l'œ — c'est-à-dire
    /// exactement ce qui se voit dans un document français.
    static func windows1252(_ data: Data) -> String {
        String(data: data, encoding: .windowsCP1252)
            ?? String(data: data, encoding: .isoLatin1)
            ?? ""
    }

    /// Curseur sur une SUITE de blocs (l'enregistrement puis ses `CONTINUE`).
    /// Il connaît la seule règle qui compte : au passage d'un bloc à l'autre, le
    /// drapeau « compressé / UTF-16 » est REDÉCLARÉ pour les caractères qui
    /// restent.
    struct Cursor {
        let blocks: [Data]
        var block = 0
        var offset = 0

        init(blocks: [Data]) {
            self.blocks = blocks.filter { !$0.isEmpty }
        }

        var isExhausted: Bool { block >= blocks.count }

        private mutating func advanceIfNeeded() {
            while block < blocks.count, offset >= blocks[block].count {
                block += 1
                offset = 0
            }
        }

        mutating func byte() -> UInt8? {
            advanceIfNeeded()
            guard block < blocks.count else { return nil }
            let value = blocks[block][blocks[block].startIndex + offset]
            offset += 1
            return value
        }

        mutating func u16() -> UInt16? {
            guard let low = byte(), let high = byte() else { return nil }
            return UInt16(low) | (UInt16(high) << 8)
        }

        mutating func u32() -> UInt32? {
            guard let a = u16(), let b = u16() else { return nil }
            return UInt32(a) | (UInt32(b) << 16)
        }

        mutating func skip(_ count: Int) {
            var remaining = max(0, count)
            while remaining > 0, byte() != nil { remaining -= 1 }
        }

        /// Une chaîne complète : longueur, drapeaux, caractères, puis les
        /// données de mise en forme (runs de texte enrichi) et de phonétique,
        /// qu'on saute — elles ne portent pas de texte cherchable.
        mutating func richString() -> String? {
            guard let count = u16(), let flags = byte() else { return nil }
            var compressed = (flags & 0x01) == 0
            let rich = (flags & 0x08) != 0
            let extended = (flags & 0x04) != 0
            var runs = 0, extra = 0
            if rich { runs = Int(u16() ?? 0) }
            if extended { extra = Int(u32() ?? 0) }

            var scalars: [UInt16] = []
            scalars.reserveCapacity(Int(count))
            var remaining = Int(count)
            while remaining > 0 {
                advanceIfNeeded()
                guard block < blocks.count else { break }
                let available = blocks[block].count - offset
                if available <= 0 { continue }
                // Frontière de bloc : le drapeau est redéclaré pour la suite.
                if offset == 0, !scalars.isEmpty {
                    guard let again = byte() else { break }
                    compressed = (again & 0x01) == 0
                    continue
                }
                if compressed {
                    guard let value = byte() else { break }
                    scalars.append(UInt16(windows1252Scalar(value)))
                } else {
                    guard let value = u16() else { break }
                    scalars.append(value)
                }
                remaining -= 1
            }
            skip(runs * 4)
            skip(extra)
            return String(decoding: scalars, as: UTF16.self)
        }
    }

    /// Le scalaire Unicode d'un octet Windows-1252 : identité hors 0x80-0x9F,
    /// table pour cette plage.
    static func windows1252Scalar(_ byte: UInt8) -> UInt32 {
        guard byte >= 0x80, byte <= 0x9F else { return UInt32(byte) }
        let table: [UInt32] = [
            0x20AC, 0x0081, 0x201A, 0x0192, 0x201E, 0x2026, 0x2020, 0x2021,
            0x02C6, 0x2030, 0x0160, 0x2039, 0x0152, 0x008D, 0x017D, 0x008F,
            0x0090, 0x2018, 0x2019, 0x201C, 0x201D, 0x2022, 0x2013, 0x2014,
            0x02DC, 0x2122, 0x0161, 0x203A, 0x0153, 0x009D, 0x017E, 0x0178,
        ]
        return table[Int(byte) - 0x80]
    }
}
