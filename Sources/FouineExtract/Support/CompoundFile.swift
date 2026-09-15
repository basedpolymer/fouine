// CompoundFile.swift — lecteur OLE2 / Compound File Binary (lot INT-F1).
// SPDX-License-Identifier: LicenseRef-Fouine-Source-Available
// Propriété : A-Ingest.
//
// POURQUOI IL EXISTE. `.xls` et `.ppt` étaient refusés d'office (§5.3) parce que
// le seul lecteur disponible — `NSAttributedString` — rend un FAUX SUCCÈS :
// 316 411 caractères de mojibake sans lever d'erreur. Il n'y avait pas de
// troisième voie : ou bien on écrit le lecteur, ou bien on perd les documents.
// Le voici, en Swift, sans bibliothèque, en trois cents lignes — un conteneur
// OLE est un mini système de fichiers, et c'est tout ce qu'il est :
//
//   · un EN-TÊTE de 512 octets (signature `D0 CF 11 E0 A1 B1 1A E1`) ;
//   · des SECTEURS de 512 (version 3) ou 4 096 octets (version 4) ;
//   · une FAT — un tableau de « secteur suivant », comme la FAT de MS-DOS ;
//   · une DIFAT, la table qui dit où sont les secteurs de la FAT ;
//   · un RÉPERTOIRE d'entrées de 128 octets (nom UTF-16, taille, premier
//     secteur) ;
//   · une MINI-FAT pour les flux de moins de 4 096 octets, rangés bout à bout
//     dans un « mini-flux » que possède l'entrée racine.
//
// TROIS RÈGLES DE SÛRETÉ, parce que le fichier vient de l'extérieur :
//
//   1. RIEN N'EST ÉCRIT SUR DISQUE. Les données sont lues d'un `Data` mappé et
//      assemblées en mémoire, bornées par `limits.maxFileBytes`.
//   2. AUCUNE CHAÎNE DE SECTEURS N'EST SUIVIE INDÉFINIMENT. Un fichier
//      malveillant — ou simplement corrompu — peut faire pointer un secteur sur
//      lui-même : la boucle est bornée par le NOMBRE DE SECTEURS du fichier, et
//      un secteur déjà visité arrête la lecture avec une erreur nommée. C'est le
//      même raisonnement que le garde-fou Zip Slip du §5.3 : on ne fait pas
//      confiance au contenu.
//   3. TOUTE INCOHÉRENCE EST UN REFUS NOMMÉ, jamais un silence : signature
//      absente, taille de secteur impossible, répertoire hors du fichier.

import Foundation
import FouineCore

/// Un conteneur OLE2 ouvert en lecture seule.
struct CompoundFile {
    /// Signature OLE2 (« Compound File Binary »), imposée par la spécification.
    static let signature: [UInt8] = [0xD0, 0xCF, 0x11, 0xE0, 0xA1, 0xB1, 0x1A, 0xE1]

    /// Un flux nommé du répertoire.
    struct Entry {
        let name: String
        let type: UInt8              // 1 storage, 2 stream, 5 root
        let startSector: UInt32
        let size: UInt64
    }

    private let data: Data
    private let sectorSize: Int
    private let miniSectorSize: Int
    private let miniCutoff: Int
    private let fat: [UInt32]
    private let miniFAT: [UInt32]
    private let entries: [Entry]
    private let miniStream: Data

    /// Fin de chaîne, secteur libre, secteur de FAT, secteur de DIFAT.
    private static let endOfChain: UInt32 = 0xFFFF_FFFE
    private static let freeSector: UInt32 = 0xFFFF_FFFF

    static func isCompoundFile(_ head: Data) -> Bool { head.starts(with: signature) }

    /// Ouvre le conteneur. `maxBytes` borne ce qu'on accepte d'assembler en
    /// mémoire pour un flux (le plafond de `ExtractLimits`).
    init(url: URL, limits: ExtractLimits) throws {
        let raw: Data
        do {
            raw = try Data(contentsOf: url, options: [.mappedIfSafe])
        } catch {
            throw FouineError.extraction(
                "cannot read (\(url.lastPathComponent)): "
                + (error as NSError).localizedDescription)
        }
        try self.init(data: raw, label: url.lastPathComponent)
    }

    init(data raw: Data, label: String) throws {
        func fail(_ what: String) -> FouineError {
            .extraction("unreadable OLE container (\(label)): \(what)")
        }
        // `Data` mappé peut ne pas commencer à l'indice 0 : on le renumérote une
        // fois pour toutes, sans quoi chaque calcul d'offset serait faux.
        data = raw.startIndex == 0 ? raw : Data(raw)

        // DEUX GARDES, DEUX MOTIFS (constat MO-06). Les confondre faisait dire
        // « no OLE signature » d'un `.xls` de 208 octets qui PORTAIT la
        // signature : le motif finit dans `docs.err` et mentait sur la cause.
        // Le second motif contient « OLE container without », que la carte
        // « documents illisibles » range déjà en « fichier endommagé » — c'est
        // exactement ce qu'un fichier tronqué est.
        guard Self.isCompoundFile(data.prefix(8)) else {
            throw fail("no OLE signature")
        }
        guard data.count >= 512 else {
            throw FouineError.extraction(
                "\(label): OLE container without a full header "
                + "(truncated: \(data.count) bytes)")
        }
        let sectorShift = Int(Self.u16(data, 30))
        let miniShift = Int(Self.u16(data, 32))
        guard sectorShift == 9 || sectorShift == 12, miniShift == 6 else {
            throw fail("unexpected sector size (2^\(sectorShift) / 2^\(miniShift))")
        }
        sectorSize = 1 << sectorShift
        miniSectorSize = 1 << miniShift
        // 4 096 est la valeur imposée par la spécification ; un en-tête qui dit
        // autre chose est un en-tête faux, et on ne le suit pas.
        let declaredCutoff = Int(Self.u32(data, 56))
        miniCutoff = declaredCutoff > 0 ? declaredCutoff : 4_096

        // Le premier secteur commence APRÈS l'en-tête, qui occupe un secteur
        // entier : 512 octets en version 3, 4 096 en version 4.
        let sectorCount = max(0, data.count / sectorSize - 1)
        guard sectorCount > 0 else { throw fail("no sector") }

        // — DIFAT, puis FAT ————————————————————————————————————————————
        var fatSectors: [UInt32] = []
        for slot in 0..<109 {
            let value = Self.u32(data, 76 + slot * 4)
            if value >= Self.endOfChain { continue }
            fatSectors.append(value)
        }
        var difatSector = Self.u32(data, 68)
        var difatVisited = 0
        while difatSector < Self.endOfChain, difatVisited <= sectorCount {
            difatVisited += 1
            let base = try Self.sectorOffset(Int(difatSector), sectorSize: sectorSize,
                                             count: sectorCount, fail: fail)
            let slots = sectorSize / 4 - 1
            for slot in 0..<slots {
                let value = Self.u32(data, base + slot * 4)
                if value >= Self.endOfChain { continue }
                fatSectors.append(value)
            }
            difatSector = Self.u32(data, base + slots * 4)
        }
        guard difatVisited <= sectorCount else { throw fail("looping DIFAT chain") }

        var table: [UInt32] = []
        table.reserveCapacity(fatSectors.count * (sectorSize / 4))
        for sector in fatSectors {
            let base = try Self.sectorOffset(Int(sector), sectorSize: sectorSize,
                                             count: sectorCount, fail: fail)
            for slot in 0..<(sectorSize / 4) {
                table.append(Self.u32(data, base + slot * 4))
            }
        }
        guard !table.isEmpty else { throw fail("empty FAT") }
        fat = table

        // — Répertoire ————————————————————————————————————————————————
        let directoryStart = Int(Self.u32(data, 48))
        let directoryChain = try Self.chain(from: directoryStart, in: fat,
                                            sectorCount: sectorCount, fail: fail)
        var found: [Entry] = []
        for sector in directoryChain {
            let base = try Self.sectorOffset(sector, sectorSize: sectorSize,
                                             count: sectorCount, fail: fail)
            for slot in stride(from: 0, to: sectorSize, by: 128) {
                let offset = base + slot
                guard offset + 128 <= data.count else { break }
                let type = data[offset + 66]
                guard type == 1 || type == 2 || type == 5 else { continue }
                let nameLength = Int(Self.u16(data, offset + 64))
                let bytes = data.subdata(in: offset..<(offset + max(0, min(64, nameLength - 2))))
                let name = String(data: bytes, encoding: .utf16LittleEndian) ?? ""
                found.append(Entry(name: name, type: type,
                                   startSector: Self.u32(data, offset + 116),
                                   size: Self.u64(data, offset + 120)))
            }
        }
        guard let root = found.first(where: { $0.type == 5 }) else {
            throw fail("no root entry")
        }
        entries = found

        // — Mini-FAT et mini-flux —————————————————————————————————————
        var mini: [UInt32] = []
        let miniFATStart = Int(Self.u32(data, 60))
        if miniFATStart < Int(Self.endOfChain) {
            for sector in try Self.chain(from: miniFATStart, in: fat,
                                         sectorCount: sectorCount, fail: fail) {
                let base = try Self.sectorOffset(sector, sectorSize: sectorSize,
                                                 count: sectorCount, fail: fail)
                for slot in 0..<(sectorSize / 4) {
                    mini.append(Self.u32(data, base + slot * 4))
                }
            }
        }
        miniFAT = mini

        if root.size > 0, root.startSector < Self.endOfChain {
            var assembled = Data()
            for sector in try Self.chain(from: Int(root.startSector), in: fat,
                                         sectorCount: sectorCount, fail: fail) {
                let base = try Self.sectorOffset(sector, sectorSize: sectorSize,
                                                 count: sectorCount, fail: fail)
                assembled.append(data.subdata(
                    in: base..<min(base + sectorSize, data.count)))
                if assembled.count >= Int(root.size) { break }
            }
            miniStream = assembled.prefix(Int(root.size))
        } else {
            miniStream = Data()
        }
    }

    // MARK: - Flux

    /// Les noms des flux du conteneur, dans l'ordre du répertoire.
    var streamNames: [String] { entries.filter { $0.type == 2 }.map(\.name) }

    /// Le contenu d'un flux, par nom, insensible à la casse — les producteurs
    /// n'ont jamais été d'accord sur `Workbook` / `WORKBOOK` / `Book`.
    func stream(named name: String) throws -> Data? {
        let wanted = name.lowercased()
        guard let entry = entries.first(where: {
            $0.type == 2 && $0.name.lowercased() == wanted
        }) else { return nil }
        return try contents(of: entry)
    }

    func contents(of entry: Entry) throws -> Data {
        func fail(_ what: String) -> FouineError {
            .extraction("unreadable OLE container: \(what)")
        }
        let size = Int(min(entry.size, UInt64(Int.max)))
        guard size > 0 else { return Data() }
        let sectorCount = max(0, data.count / sectorSize - 1)

        if size < miniCutoff {
            var assembled = Data()
            var sector = Int(entry.startSector)
            var visited = 0
            let bound = max(1, miniStream.count / miniSectorSize + 1)
            while sector >= 0, sector < miniFAT.count, visited <= bound {
                visited += 1
                let base = sector * miniSectorSize
                guard base < miniStream.count else { break }
                assembled.append(miniStream.subdata(
                    in: base..<min(base + miniSectorSize, miniStream.count)))
                if assembled.count >= size { break }
                let next = miniFAT[sector]
                if next >= Self.endOfChain { break }
                sector = Int(next)
            }
            guard visited <= bound else { throw fail("looping mini-FAT chain") }
            return assembled.prefix(size)
        }

        var assembled = Data()
        for sector in try Self.chain(from: Int(entry.startSector), in: fat,
                                     sectorCount: sectorCount, fail: fail) {
            let base = try Self.sectorOffset(sector, sectorSize: sectorSize,
                                             count: sectorCount, fail: fail)
            assembled.append(data.subdata(in: base..<min(base + sectorSize, data.count)))
            if assembled.count >= size { break }
        }
        return assembled.prefix(size)
    }

    // MARK: - Chaînes de secteurs

    /// Suit une chaîne de la FAT. Un secteur DÉJÀ VU arrête tout : c'est la
    /// boucle infinie du fichier corrompu ou piégé, et elle doit se solder par
    /// un refus nommé, pas par un processus qui tourne jusqu'à la fin des temps.
    private static func chain(from start: Int, in fat: [UInt32], sectorCount: Int,
                              fail: (String) -> FouineError) throws -> [Int] {
        guard start >= 0, start < Int(endOfChain) else { return [] }
        var sectors: [Int] = []
        var seen = Set<Int>()
        var sector = start
        while sector >= 0, sector < fat.count, sector < sectorCount {
            if !seen.insert(sector).inserted {
                throw fail("looping sector chain at \(sector)")
            }
            sectors.append(sector)
            let next = fat[sector]
            if next >= endOfChain { break }
            sector = Int(next)
            if sectors.count > sectorCount {
                throw fail("sector chain longer than the file")
            }
        }
        return sectors
    }

    private static func sectorOffset(_ sector: Int, sectorSize: Int, count: Int,
                                     fail: (String) -> FouineError) throws -> Int {
        guard sector >= 0, sector < count else {
            throw fail("sector \(sector) is outside the file")
        }
        return (sector + 1) * sectorSize
    }

    // MARK: - Lectures brutes

    static func u16(_ data: Data, _ offset: Int) -> UInt16 {
        guard offset + 2 <= data.count else { return 0 }
        return UInt16(data[offset]) | (UInt16(data[offset + 1]) << 8)
    }

    static func u32(_ data: Data, _ offset: Int) -> UInt32 {
        guard offset + 4 <= data.count else { return 0 }
        var value: UInt32 = 0
        for byte in 0..<4 { value |= UInt32(data[offset + byte]) << (8 * byte) }
        return value
    }

    static func u64(_ data: Data, _ offset: Int) -> UInt64 {
        guard offset + 8 <= data.count else { return 0 }
        var value: UInt64 = 0
        for byte in 0..<8 { value |= UInt64(data[offset + byte]) << (8 * byte) }
        return value
    }
}
