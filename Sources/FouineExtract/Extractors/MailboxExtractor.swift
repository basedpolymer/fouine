// MailboxExtractor.swift — mbox, fichier ou paquet `Nom.mbox/` (lot INT-F1,
// SPEC §5.3).
// SPDX-License-Identifier: LicenseRef-Fouine-Source-Available
// Propriété : A-Ingest.
//
// Une archive mbox est la forme d'export universelle du courrier : « Exporter
// la boîte aux lettres » d'Apple Mail, l'export de Thunderbird, l'archive
// Google Takeout. C'est une suite de messages RFC 822 séparés par une ligne
// « From » à la ligne — celle que le format appelle la ligne « From_ », et qui
// n'a rien à voir avec l'en-tête `From:`.
//
// LA SEULE SUBTILITÉ EST LÀ. Un corps de message peut lui aussi commencer une
// ligne par « From » : les variantes mboxo et mboxrd l'échappent en « >From ».
// La frontière est donc « une ligne qui COMMENCE par `From ` », jamais un
// `From ` trouvé n'importe où — une recherche naïve couperait un message en
// deux au milieu d'une citation, et les deux moitiés seraient illisibles.
//
// UNE PAGE PAR MESSAGE (§5.3, comme une diapositive de pptx) : c'est ce qui
// donne son sens à `NEAR`, aux extraits et à la navigation. Un message plus
// long que `pageSplitChars` est re-découpé comme le reste, à la frontière de
// paragraphe.
//
// Le PAQUET `Nom.mbox/` d'Apple Mail est un DOSSIER que le crawler traite comme
// un document (`CrawlExclusions.documentPackageExtensions`). Il porte un
// fichier `mbox` — c'est lui qu'on lit — et, quand il n'en porte pas, un
// dossier `Messages/` de `.emlx` numérotés.

import Foundation
import FouineCore

public struct MailboxExtractor: TextExtractor {
    public static let supportedExtensions: Set<String> = ["mbox"]

    /// Refus NOMMÉ, classé `.skipped` : le fichier porte l'extension d'une boîte
    /// aux lettres sans en être une. Ce n'est pas un échec d'extraction — il n'y
    /// a rien à extraire.
    public static let notAMailboxReason = "not a mailbox"

    /// Fichier de messages d'un paquet `Nom.mbox/` d'Apple Mail.
    static let packageMailbox = "mbox"
    /// Dossier des messages individuels d'un paquet `Nom.mbox/`.
    static let packageMessagesFolder = "Messages"

    public init() {}

    public func extract(url: URL, limits: ExtractLimits) throws -> ExtractionResult {
        try FileGuard.check(url, limits)

        var st = stat()
        guard stat(url.path, &st) == 0 else {
            throw FouineError.extraction(
                "unreadable file: \(String(cString: strerror(errno))) (\(url.path))")
        }
        let messages: [Data] = (st.st_mode & S_IFMT) == S_IFDIR
            ? try Self.packageMessages(at: url)
            : try Self.fileMessages(at: url)

        var budget = TextBudget(maxBytes: limits.maxTextBytes)
        var slots: [String] = []
        for message in messages {
            // PAS de pièces jointes ici (lot EX1) : une boîte aux lettres est une
            // suite de messages, et dix pièces par message feraient d'un export
            // Takeout de mille courriels un document de dix mille pages
            // extraites une à une. Un `.eml` isolé, lui, les lit.
            let rendered = EMLExtractor.render(
                EMLParser.parse(data: message, attachments: false))
            let text = budget.take(rendered.text)
            let split = TextPagination.paginate(text, limit: limits.pageSplitChars)
            slots += split.isEmpty ? [""] : split
            if budget.isExhausted { break }
        }
        return Assembler.result(slots: slots,
                                meta: ["messages": String(messages.count)])
    }

    // MARK: - Les deux formes

    static func fileMessages(at url: URL) throws -> [Data] {
        let data: Data
        do {
            data = try Data(contentsOf: url, options: [.mappedIfSafe])
        } catch {
            throw FouineError.extraction(
                "cannot read (\(url.lastPathComponent)): "
                + (error as NSError).localizedDescription)
        }
        let messages = split(data)
        guard !messages.isEmpty else {
            throw FouineError.extraction(notAMailboxReason)
        }
        return messages
    }

    /// Le paquet `Nom.mbox/` : son fichier `mbox` s'il en a un, sinon ses
    /// `Messages/*.emlx` triés naturellement (`5.emlx` avant `10.emlx`).
    static func packageMessages(at url: URL) throws -> [Data] {
        let inner = url.appendingPathComponent(packageMailbox)
        if FileManager.default.fileExists(atPath: inner.path) {
            return try fileMessages(at: inner)
        }
        let directory = url.appendingPathComponent(packageMessagesFolder)
        let names = (try? FileManager.default
            .contentsOfDirectory(atPath: directory.path)) ?? []
        let emlx = EntrySort.sortedNaturally(
            names.filter { ($0 as NSString).pathExtension.lowercased() == "emlx" })
        guard !emlx.isEmpty else {
            throw FouineError.extraction(notAMailboxReason)
        }
        return emlx.compactMap { name in
            guard let data = try? Data(
                contentsOf: directory.appendingPathComponent(name),
                options: [.mappedIfSafe]) else { return nil }
            return EMLXFraming.message(in: data)
        }
    }

    // MARK: - Découpage, PUR

    /// Les messages d'une archive mbox. Vide si ce ne sont ni un mbox ni un
    /// message RFC 822 isolé.
    ///
    /// Un fichier qui ne commence pas par « From » mais porte des en-têtes est
    /// traité comme UN message : c'est ce que produit un export partiel, et le
    /// refuser perdrait un courriel entier pour une ligne d'enveloppe absente.
    static func split(_ data: Data) -> [Data] {
        let bytes = [UInt8](data)
        guard !bytes.isEmpty else { return [] }

        var starts: [Int] = []
        var index = 0
        var atLineStart = true
        while index < bytes.count {
            if atLineStart, isFromLine(bytes, at: index) { starts.append(index) }
            atLineStart = bytes[index] == 0x0A
            index += 1
        }

        guard !starts.isEmpty else {
            return looksLikeMessage(bytes) ? [data] : []
        }
        var messages: [Data] = []
        for (position, start) in starts.enumerated() {
            let end = position + 1 < starts.count ? starts[position + 1] : bytes.count
            // La ligne « From_ » elle-même n'est pas un en-tête : elle porte
            // l'adresse d'enveloppe et une date au format `ctime`, que
            // `EMLParser` prendrait pour un en-tête sans deux-points.
            let bodyStart = lineEnd(bytes, from: start)
            if bodyStart < end {
                messages.append(Data(bytes[bodyStart..<end]))
            }
        }
        return messages
    }

    /// « From » suivi d'une espace, au début d'une ligne.
    private static func isFromLine(_ bytes: [UInt8], at index: Int) -> Bool {
        let pattern: [UInt8] = [0x46, 0x72, 0x6F, 0x6D, 0x20]      // "From "
        guard index + pattern.count <= bytes.count else { return false }
        for (offset, byte) in pattern.enumerated()
        where bytes[index + offset] != byte { return false }
        return true
    }

    private static func lineEnd(_ bytes: [UInt8], from index: Int) -> Int {
        var i = index
        while i < bytes.count, bytes[i] != 0x0A { i += 1 }
        return min(i + 1, bytes.count)
    }

    /// Assez d'en-têtes RFC 822 pour que ce soit un message. Quatre noms
    /// suffisent : un message sans aucun des quatre n'est pas un message.
    private static func looksLikeMessage(_ bytes: [UInt8]) -> Bool {
        let head = Data(bytes.prefix(8 << 10))
        guard let text = String(data: head, encoding: .utf8)
                ?? String(data: head, encoding: .isoLatin1) else { return false }
        let wanted = ["from:", "subject:", "to:", "date:", "received:",
                      "message-id:"]
        for line in text.split(separator: "\n", omittingEmptySubsequences: false) {
            let lower = line.lowercased()
            if lower.trimmingCharacters(in: .whitespaces).isEmpty { break }
            if wanted.contains(where: { lower.hasPrefix($0) }) { return true }
        }
        return false
    }
}
