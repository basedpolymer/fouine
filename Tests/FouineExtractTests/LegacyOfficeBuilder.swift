// LegacyOfficeBuilder.swift — fabrique de conteneurs OLE, de classeurs BIFF et
// de présentations PPT (lot INT-F1). Propriété : A-Recette, cible de test.
//
// DUPLIQUÉ, EXPRÈS, dans `Tools/make_fixtures.swift` : le générateur est un
// script `swift` autonome, il ne peut pas importer une cible de test, et
// `Package.swift` est gelé. Les deux copies doivent rester équivalentes — c'est
// la même raison, et la même règle, que pour `makeArchive`.
//
// Ce que l'écrivain SAIT faire, et ce qu'il ne sait pas : un seul secteur de
// FAT (128 secteurs, soit 64 Kio de fichier), version 3 (secteurs de 512
// octets), mini-flux pour les flux de moins de 4 096 octets. C'est tout ce
// qu'une fixture demande, et c'est ce qui rend le lecteur vérifiable sur ses
// DEUX chemins — mini-FAT et FAT ordinaire.

import Foundation

enum OLEWriter {

    static let sectorSize = 512
    static let miniSectorSize = 64
    static let miniCutoff = 4_096
    static let endOfChain: UInt32 = 0xFFFF_FFFE
    static let freeSector: UInt32 = 0xFFFF_FFFF
    static let fatSector: UInt32 = 0xFFFF_FFFD
    static let noStream: UInt32 = 0xFFFF_FFFF

    /// Un conteneur OLE2 portant ces flux, dans cet ordre.
    static func compoundFile(streams: [(name: String, data: Data)]) -> Data {
        // — Mini-flux : les flux de moins de 4 096 octets, bout à bout ————
        var miniStream = Data()
        var miniStart: [Int: Int] = [:]          // index de flux -> mini-secteur
        for (index, stream) in streams.enumerated()
        where !stream.data.isEmpty && stream.data.count < miniCutoff {
            miniStart[index] = miniStream.count / miniSectorSize
            miniStream.append(stream.data)
            let padding = (miniSectorSize - miniStream.count % miniSectorSize)
                % miniSectorSize
            miniStream.append(Data(repeating: 0, count: padding))
        }

        // — Allocation des secteurs ————————————————————————————————————
        let entryCount = streams.count + 1                    // + l'entrée racine
        let directorySectors = (entryCount + 3) / 4
        let miniSectorCount = miniStream.count / miniSectorSize
        let miniFATSectors = miniSectorCount == 0
            ? 0 : (miniSectorCount * 4 + sectorSize - 1) / sectorSize
        let miniStreamSectors = (miniStream.count + sectorSize - 1) / sectorSize

        var next = 1                                          // le secteur 0 = FAT
        let directoryStart = next; next += directorySectors
        let miniFATStart = miniFATSectors > 0 ? next : Int(endOfChain)
        next += miniFATSectors
        let miniStreamStart = miniStreamSectors > 0 ? next : Int(endOfChain)
        next += miniStreamSectors

        var bigStart: [Int: Int] = [:]
        var bigSectors: [Int: Int] = [:]
        for (index, stream) in streams.enumerated() where stream.data.count >= miniCutoff {
            let count = (stream.data.count + sectorSize - 1) / sectorSize
            bigStart[index] = next
            bigSectors[index] = count
            next += count
        }
        let totalSectors = next
        precondition(totalSectors <= sectorSize / 4,
                     "fixture trop grosse pour un seul secteur de FAT")

        // — FAT ————————————————————————————————————————————————————————
        var fat = [UInt32](repeating: freeSector, count: sectorSize / 4)
        fat[0] = fatSector
        func chain(_ start: Int, _ count: Int) {
            guard count > 0 else { return }
            for offset in 0..<count {
                fat[start + offset] = offset + 1 < count
                    ? UInt32(start + offset + 1) : endOfChain
            }
        }
        chain(directoryStart, directorySectors)
        if miniFATSectors > 0 { chain(miniFATStart, miniFATSectors) }
        if miniStreamSectors > 0 { chain(miniStreamStart, miniStreamSectors) }
        for (index, start) in bigStart { chain(start, bigSectors[index] ?? 0) }

        // — Mini-FAT ————————————————————————————————————————————————————
        var miniFAT = [UInt32]()
        for (index, stream) in streams.enumerated() {
            guard let start = miniStart[index] else { continue }
            let count = (stream.data.count + miniSectorSize - 1) / miniSectorSize
            for offset in 0..<count {
                miniFAT.append(offset + 1 < count
                               ? UInt32(start + offset + 1) : endOfChain)
            }
        }

        // — Répertoire ——————————————————————————————————————————————————
        var directory = Data()
        directory.append(entry(name: "Root Entry", type: 5,
                               start: UInt32(miniStreamStart),
                               size: UInt64(miniStream.count),
                               child: streams.isEmpty ? noStream : 1,
                               right: noStream))
        for (index, stream) in streams.enumerated() {
            let start = miniStart[index].map { UInt32($0) }
                ?? bigStart[index].map { UInt32($0) } ?? endOfChain
            directory.append(entry(name: stream.name, type: 2, start: start,
                                   size: UInt64(stream.data.count),
                                   child: noStream,
                                   right: index + 2 <= streams.count
                                       ? UInt32(index + 2) : noStream))
        }

        // — En-tête ————————————————————————————————————————————————————
        var header = Data()
        header.append(contentsOf: [0xD0, 0xCF, 0x11, 0xE0, 0xA1, 0xB1, 0x1A, 0xE1])
        header.append(Data(repeating: 0, count: 16))          // CLSID
        header.append(u16(0x003E))                            // version mineure
        header.append(u16(0x0003))                            // version majeure
        header.append(u16(0xFFFE))                            // petit-boutien
        header.append(u16(9))                                 // secteurs de 512
        header.append(u16(6))                                 // mini-secteurs de 64
        header.append(Data(repeating: 0, count: 6))
        header.append(u32(0))                                 // secteurs de répertoire
        header.append(u32(1))                                 // secteurs de FAT
        header.append(u32(UInt32(directoryStart)))
        header.append(u32(0))                                 // signature de transaction
        header.append(u32(UInt32(miniCutoff)))
        header.append(u32(UInt32(miniFATStart)))
        header.append(u32(UInt32(miniFATSectors)))
        header.append(u32(endOfChain))                        // DIFAT
        header.append(u32(0))
        header.append(u32(0))                                 // DIFAT[0] = secteur 0
        for _ in 1..<109 { header.append(u32(freeSector)) }

        // — Assemblage ————————————————————————————————————————————————
        var file = header
        var body = Data()
        for value in fat { body.append(u32(value)) }           // secteur 0
        body.append(pad(directory, to: directorySectors * sectorSize))
        if miniFATSectors > 0 {
            var table = Data()
            for value in miniFAT { table.append(u32(value)) }
            body.append(pad(table, to: miniFATSectors * sectorSize))
        }
        if miniStreamSectors > 0 {
            body.append(pad(miniStream, to: miniStreamSectors * sectorSize))
        }
        for (index, stream) in streams.enumerated() where bigStart[index] != nil {
            body.append(pad(stream.data, to: (bigSectors[index] ?? 0) * sectorSize))
        }
        file.append(body)
        return file
    }

    /// Une entrée de répertoire de 128 octets.
    private static func entry(name: String, type: UInt8, start: UInt32,
                              size: UInt64, child: UInt32, right: UInt32) -> Data {
        var data = Data()
        var utf16 = Data()
        for unit in Array(name.utf16) { utf16.append(u16(unit)) }
        utf16.append(u16(0))                                   // terminateur
        data.append(pad(utf16, to: 64))
        data.append(u16(UInt16(utf16.count)))
        data.append(type)
        data.append(1)                                         // couleur : noir
        data.append(u32(noStream))                             // frère gauche
        data.append(u32(right))
        data.append(u32(child))
        data.append(Data(repeating: 0, count: 16))             // CLSID
        data.append(u32(0))                                    // drapeaux
        data.append(Data(repeating: 0, count: 16))             // horodatages
        data.append(u32(start))
        data.append(u64(size))
        return data
    }

    static func pad(_ data: Data, to length: Int) -> Data {
        var copy = data
        if copy.count < length {
            copy.append(Data(repeating: 0, count: length - copy.count))
        }
        return copy.prefix(length)
    }

    static func u16(_ value: UInt16) -> Data {
        Data([UInt8(value & 0xFF), UInt8(value >> 8)])
    }

    /// `truncatingIfNeeded` et non `UInt8(x & 0xFF)` : le masque forçait le
    /// vérificateur de types à départager les surcharges de `&` et de
    /// `UInt8.init` sur quatre termes à la fois — 1,8 s pour ces deux lignes
    /// (lot BT1). Les octets produits sont les mêmes.
    static func u32(_ value: UInt32) -> Data {
        let bytes: [UInt8] = [UInt8(truncatingIfNeeded: value),
                              UInt8(truncatingIfNeeded: value >> 8),
                              UInt8(truncatingIfNeeded: value >> 16),
                              UInt8(truncatingIfNeeded: value >> 24)]
        return Data(bytes)
    }

    static func u64(_ value: UInt64) -> Data {
        var data = Data(capacity: 8)
        for byte: UInt64 in 0..<8 {
            data.append(UInt8(truncatingIfNeeded: value >> (8 * byte)))
        }
        return data
    }
}

/// Un classeur BIFF8 minimal, mais VRAI : sous-flux des globales, table des
/// chaînes partagées, un sous-flux par feuille, offsets recalés.
enum BIFFBuilder {

    enum Cell {
        /// Texte, par la table des chaînes partagées. `wide` force l'UTF-16.
        case text(String, wide: Bool)
        case number(Double)
        /// Entier court, encodé en `RK`.
        case integer(Int32)
    }

    struct Sheet {
        let name: String
        /// (ligne, colonne, contenu), en base 0.
        let cells: [(row: Int, column: Int, cell: Cell)]
    }

    static func record(_ type: UInt16, _ body: Data) -> Data {
        var data = OLEWriter.u16(type)
        data.append(OLEWriter.u16(UInt16(body.count)))
        data.append(body)
        return data
    }

    static func bof(kind: UInt16) -> Data {
        var body = OLEWriter.u16(0x0600)          // BIFF8
        body.append(OLEWriter.u16(kind))
        body.append(Data(repeating: 0, count: 12))
        return record(0x0809, body)
    }

    static let eof = record(0x000A, Data())

    /// Chaîne BIFF8 : longueur en caractères, drapeaux, données.
    static func string(_ text: String, wide: Bool) -> Data {
        let units = Array(text.utf16)
        var data = OLEWriter.u16(UInt16(units.count))
        if wide || units.contains(where: { $0 > 0xFF }) {
            data.append(UInt8(0x01))
            for unit in units { data.append(OLEWriter.u16(unit)) }
        } else {
            data.append(UInt8(0x00))
            for unit in units { data.append(UInt8(unit & 0xFF)) }
        }
        return data
    }

    static func workbook(_ sheets: [Sheet]) -> Data {
        // Chaînes partagées, dans l'ordre de première rencontre.
        var shared: [(text: String, wide: Bool)] = []
        var indexOf: [String: Int] = [:]
        for sheet in sheets {
            for cell in sheet.cells {
                guard case .text(let text, let wide) = cell.cell else { continue }
                if indexOf[text] == nil {
                    indexOf[text] = shared.count
                    shared.append((text, wide))
                }
            }
        }

        // — Globales ————————————————————————————————————————————————————
        var globals = bof(kind: 0x0005)
        var sst = OLEWriter.u32(UInt32(shared.count))
        sst.append(OLEWriter.u32(UInt32(shared.count)))
        for entry in shared { sst.append(string(entry.text, wide: entry.wide)) }
        globals.append(record(0x00FC, sst))

        var boundsheetOffsets: [Int] = []
        for sheet in sheets {
            var body = OLEWriter.u32(0)                        // lbPlyPos, recalé
            body.append(OLEWriter.u16(0))                      // visible, feuille
            let name = Array(sheet.name.utf16)
            body.append(UInt8(name.count))
            body.append(UInt8(0))                              // non compressée : non
            for unit in name { body.append(UInt8(unit & 0xFF)) }
            boundsheetOffsets.append(globals.count + 4)        // corps du record
            globals.append(record(0x0085, body))
        }
        globals.append(eof)

        // — Sous-flux des feuilles ————————————————————————————————————
        var body = Data()
        var starts: [Int] = []
        for sheet in sheets {
            starts.append(globals.count + body.count)
            body.append(bof(kind: 0x0010))
            for cell in sheet.cells {
                let head = OLEWriter.u16(UInt16(cell.row))
                    + OLEWriter.u16(UInt16(cell.column)) + OLEWriter.u16(0)
                switch cell.cell {
                case .text(let text, _):
                    var record = head
                    record.append(OLEWriter.u32(UInt32(indexOf[text] ?? 0)))
                    body.append(Self.record(0x00FD, record))
                case .number(let value):
                    var record = head
                    record.append(OLEWriter.u64(value.bitPattern))
                    body.append(Self.record(0x0203, record))
                case .integer(let value):
                    var record = head
                    record.append(OLEWriter.u32(UInt32(bitPattern: (value << 2) | 0x02)))
                    body.append(Self.record(0x027E, record))
                }
            }
            body.append(eof)
        }

        // Recalage des offsets de feuille dans les `BOUNDSHEET`.
        var workbook = globals
        for (index, offset) in boundsheetOffsets.enumerated() {
            let value = OLEWriter.u32(UInt32(starts[index]))
            workbook.replaceSubrange(offset..<(offset + 4), with: value)
        }
        workbook.append(body)
        return workbook
    }

    /// Un classeur CHIFFRÉ : `FILEPASS` juste après le `BOF`.
    static func encryptedWorkbook() -> Data {
        var data = bof(kind: 0x0005)
        data.append(record(0x002F, Data([0x01, 0x00])))
        data.append(eof)
        return data
    }
}

/// Une présentation PPT minimale : une `SlideListWithText` dont les
/// `SlidePersistAtom` séparent les diapositives.
enum PPTBuilder {

    enum Text {
        /// `TextCharsAtom`, UTF-16LE.
        case chars(String)
        /// `TextBytesAtom`, un octet par caractère.
        case bytes(String)
    }

    static func atom(_ type: UInt16, instance: UInt16 = 0, _ body: Data) -> Data {
        var data = OLEWriter.u16(instance << 4)
        data.append(OLEWriter.u16(type))
        data.append(OLEWriter.u32(UInt32(body.count)))
        data.append(body)
        return data
    }

    static func container(_ type: UInt16, instance: UInt16 = 0, _ body: Data) -> Data {
        var data = OLEWriter.u16((instance << 4) | 0x0F)
        data.append(OLEWriter.u16(type))
        data.append(OLEWriter.u32(UInt32(body.count)))
        data.append(body)
        return data
    }

    static func text(_ item: Text) -> Data {
        switch item {
        case .chars(let value):
            var data = Data()
            for unit in Array(value.utf16) { data.append(OLEWriter.u16(unit)) }
            return atom(0x0FA0, data)
        case .bytes(let value):
            var data = Data()
            for unit in Array(value.utf16) { data.append(UInt8(unit & 0xFF)) }
            return atom(0x0FA8, data)
        }
    }

    /// Le flux `PowerPoint Document` : une entrée de liste par diapositive.
    static func document(slides: [[Text]], notes: [[Text]] = []) -> Data {
        var data = container(0x0FF0, instance: 0, list(slides))
        if !notes.isEmpty {
            data.append(container(0x0FF0, instance: 2, list(notes)))
        }
        return data
    }

    private static func list(_ pages: [[Text]]) -> Data {
        var body = Data()
        for (index, page) in pages.enumerated() {
            var persist = OLEWriter.u32(UInt32(index + 1))
            persist.append(Data(repeating: 0, count: 16))
            body.append(atom(0x03F3, persist))
            for item in page { body.append(text(item)) }
        }
        return body
    }

    /// Une présentation CHIFFRÉE : le conteneur de session de chiffrement.
    static func encryptedDocument() -> Data {
        container(0x2F14, Data(repeating: 0, count: 8))
    }
}
